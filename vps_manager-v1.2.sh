#!/usr/bin/env bash
# ==============================================================
# VPS 一键管理脚本
# 功能: Xray VLESS+Reality+Vision + Realm 独立端口转发
# 版本: v1.2.0
# 支持: Ubuntu/Debian/Alpine | IPv4/IPv6/双栈 | 小磁盘/容器
#
# Realm 设计说明:
#   Realm 独立监听一个端口（如10443）对外，所有落地候选共用此端口。
#   内部维护多条"落地候选"，同一时刻只有一条"激活"生效。
#   切换落地：选择激活哪条 → 重新生成配置 → 重启 Realm，秒级切换。
#   对客户端：连 中转VPS:10443，流量转到当前激活的落地VPS。
# ==============================================================

SCRIPT_VERSION="v1.2.0"
set -euo pipefail

# ── 颜色 ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_success() { echo -e "${CYAN}[OK]${NC}    $*"; }
log_step()    { echo -e "${BLUE}[STEP]${NC}  $*"; }
log_title()   {
    echo ""
    echo -e "${MAGENTA}══════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}  $*${NC}"
    echo -e "${MAGENTA}══════════════════════════════════════════════${NC}"
    echo ""
}

# ── 全局路径 ──────────────────────────────────────────────────
XRAY_BIN="/usr/local/bin/xray"
XRAY_ETC="/usr/local/etc/xray"
XRAY_MAIN_CONFIG="$XRAY_ETC/config.json"
XRAY_LOG_DIR="/var/log/xray"

REALM_BIN="/usr/local/bin/realm"
REALM_ETC="/etc/realm"
REALM_CFG="$REALM_ETC/config.toml"

DATA_DIR="/etc/vps_manager"
# NODE_DB 每行: uuid|port|sni|short_id|private_key|name|fingerprint
NODE_DB="$DATA_DIR/nodes.db"
# REALM_DB 每行: label|listen_port|remote_host|remote_port|active(0/1)
REALM_DB="$DATA_DIR/realm.db"
BACKUP_DIR="/root/vps_manager_backups"

# ── 系统变量 ──────────────────────────────────────────────────
OS_TYPE=""
PKG_MGR=""
SVC_MGR=""
TOTAL_MEM=0
TOTAL_DISK=0
PYTHON=""
PICKED_NODE_LINE=""

# ==============================================================
# 系统检测
# ==============================================================
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "无法识别操作系统（缺少 /etc/os-release）"
        exit 1
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    case "${ID:-}" in
        ubuntu|debian)
            OS_TYPE="ubuntu"; PKG_MGR="apt"; SVC_MGR="systemd" ;;
        alpine)
            OS_TYPE="alpine"; PKG_MGR="apk"; SVC_MGR="openrc" ;;
        *)
            log_error "不支持的发行版: ${ID:-unknown}（仅支持 Ubuntu/Debian/Alpine）"
            exit 1 ;;
    esac
    TOTAL_MEM=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo 0)
    TOTAL_DISK=$(df -BG / 2>/dev/null | awk 'NR==2{print $2}' | tr -d 'G' || echo 0)
    log_info "OS: $OS_TYPE | 内存: ${TOTAL_MEM}MB | 磁盘: ${TOTAL_DISK}GB | 服务: $SVC_MGR"
}

need_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        log_error "请以 root 权限运行：sudo $0"
        exit 1
    fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

ensure_python() {
    if cmd_exists python3; then
        PYTHON=python3
    elif cmd_exists python; then
        PYTHON=python
    else
        log_warn "未检测到 Python，正在安装..."
        if [[ "$PKG_MGR" == "apt" ]]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 >/dev/null 2>&1
        else
            apk add --no-cache -q python3 >/dev/null 2>&1
        fi
        PYTHON=python3
    fi
}

# ==============================================================
# 网络 / IP
# ==============================================================
get_ipv4() {
    local ip=""
    ip=$(curl -s -4 --max-time 8 https://api4.ipify.org 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
    ip=$(curl -s -4 --max-time 8 https://ifconfig.me 2>/dev/null)    && [[ -n "$ip" ]] && echo "$ip" && return
    ip=$(curl -s -4 --max-time 8 https://icanhazip.com 2>/dev/null)  && [[ -n "$ip" ]] && echo "$ip" && return
    echo ""
}

get_ipv6() {
    local ip=""
    ip=$(curl -s -6 --max-time 8 https://api6.ipify.org 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
    ip=$(curl -s -6 --max-time 8 https://ifconfig.me 2>/dev/null)    && [[ -n "$ip" ]] && echo "$ip" && return
    ip=$(curl -s -6 --max-time 8 https://icanhazip.com 2>/dev/null)  && [[ -n "$ip" ]] && echo "$ip" && return
    echo ""
}

check_github() {
    curl -sI --max-time 6 https://api.github.com >/dev/null 2>&1
}

gh_download() {
    local url="$1" output="$2"
    if check_github; then
        curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$output" "$url"
    else
        log_warn "GitHub 不可直连，切换 ghp.ci 代理..."
        curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$output" "https://ghp.ci/$url"
    fi
}

# ==============================================================
# 密钥解析（兼容 Xray v1.x / v26.x）
# ==============================================================
parse_xray_keys() {
    local out="$1"
    PARSED_PRIVATE=$(echo "$out" | grep -iE "^private" | awk '{print $NF}' | tr -d ' \r\n')
    PARSED_PUBLIC=$(echo "$out"  | grep -iE "(^public|publickey)" | awk '{print $NF}' | tr -d ' \r\n')
    if [[ -z "$PARSED_PRIVATE" || -z "$PARSED_PUBLIC" ]]; then
        log_error "密钥解析失败，原始输出:"
        echo "$out"
        return 1
    fi
}
PARSED_PRIVATE=""
PARSED_PUBLIC=""

derive_public_key() {
    local priv="$1"
    local out
    out=$("$XRAY_BIN" x25519 -i "$priv" 2>&1)
    echo "$out" | grep -iE "(^public|publickey)" | awk '{print $NF}' | tr -d ' \r\n'
}

gen_uuid() {
    if [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    elif cmd_exists uuidgen; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}' | tr '[:upper:]' '[:lower:]'
    fi
}

# ==============================================================
# Swap / BBR
# ==============================================================
setup_swap() {
    local target_mb="$1"
    [[ -f /swapfile ]] && { swapoff /swapfile 2>/dev/null || true; rm -f /swapfile; }
    local avail_kb
    avail_kb=$(df -k / | awk 'NR==2{print $4}')
    local need_kb=$(( target_mb * 1024 + 512 * 1024 ))
    if (( avail_kb < need_kb )); then
        log_warn "磁盘剩余 $((avail_kb/1024))MB 不足，跳过 Swap"
        return 0
    fi
    fallocate -l "${target_mb}M" /swapfile 2>/dev/null \
        || dd if=/dev/zero of=/swapfile bs=1M count="$target_mb" status=none 2>/dev/null \
        || { log_warn "Swap 文件创建失败"; return 0; }
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1 || { rm -f /swapfile; return 0; }
    if swapon /swapfile 2>/dev/null; then
        grep -q '/swapfile' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        log_success "Swap ${target_mb}MB 已启用"
    else
        log_warn "容器环境不支持 Swap，跳过"
        rm -f /swapfile
    fi
}

enable_bbr() {
    touch /etc/sysctl.conf
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf \
        || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf \
        || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 && log_success "BBR 已启用" || log_warn "容器环境，BBR 跳过"
}

# ==============================================================
# 系统初始化
# ==============================================================
system_init() {
    log_step "系统初始化..."
    if [[ "$OS_TYPE" == "ubuntu" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            curl wget unzip openssl coreutils iproute2 \
            net-tools iptables python3 2>/dev/null || true
        (( TOTAL_DISK >= 10 )) && setup_swap 1024 \
            || { (( TOTAL_DISK >= 5 )) && setup_swap 512 || log_warn "磁盘 <5GB，跳过 Swap"; }
    else
        apk update -q 2>/dev/null
        apk add --no-cache -q \
            bash curl wget unzip openssl coreutils \
            iproute2 iptables ip6tables python3 2>/dev/null || true
        (( TOTAL_DISK >= 3 )) && setup_swap 256 || log_warn "磁盘 <3GB，跳过 Swap"
    fi
    enable_bbr
    mkdir -p "$DATA_DIR" "$BACKUP_DIR" "$XRAY_LOG_DIR" "$XRAY_ETC" "$REALM_ETC"
    touch "$NODE_DB" "$REALM_DB"
    chmod 600 "$NODE_DB" "$REALM_DB"
    ensure_python
    log_success "系统初始化完成"
}

# ==============================================================
# Xray 安装 & 服务文件
# ==============================================================
install_xray() {
    if [[ -x "$XRAY_BIN" ]]; then
        log_info "Xray 已安装：$("$XRAY_BIN" version 2>&1 | head -1)"
        _ensure_xray_service
        return 0
    fi
    log_step "安装 Xray-core..."
    if [[ "$OS_TYPE" == "ubuntu" ]]; then
        _install_xray_ubuntu
    else
        _install_xray_alpine
    fi
    _ensure_xray_service
}

_install_xray_ubuntu() {
    local script_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
    local dl_url
    check_github && dl_url="$script_url" || dl_url="https://ghp.ci/$script_url"
    bash -c "$(curl -fsSL "$dl_url")" @ install
    [[ -x "$XRAY_BIN" ]] || { log_error "Xray 安装失败"; exit 1; }
    log_success "Xray 安装完成"
}

_install_xray_alpine() {
    local tag arch asset url tmp
    tag=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)
    [[ -z "$tag" ]] && { tag="v1.8.4"; log_warn "版本获取失败，使用 $tag"; }
    case "$(uname -m)" in
        x86_64)        arch="64" ;;
        aarch64|arm64) arch="arm64-v8a" ;;
        armv7l)        arch="arm32-v7a" ;;
        *) log_error "不支持的架构：$(uname -m)"; exit 1 ;;
    esac
    asset="Xray-linux-${arch}.zip"
    url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${asset}"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    gh_download "$url" "$tmp/$asset"
    unzip -q -o "$tmp/$asset" -d "$tmp/xray"
    install -m 755 "$tmp/xray/xray" "$XRAY_BIN"
    mkdir -p /usr/local/share/xray
    cp "$tmp/xray/"*.dat /usr/local/share/xray/ 2>/dev/null || true
    [[ -x "$XRAY_BIN" ]] || { log_error "Xray 安装失败"; exit 1; }
    log_success "Xray $tag 安装完成"
}

# 每次都写入最新的服务文件，防止路径错误
_ensure_xray_service() {
    if [[ "$SVC_MGR" == "systemd" ]]; then
        cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BIN} run -config ${XRAY_MAIN_CONFIG}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    else
        cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
name="xray"
description="Xray Service"
command="${XRAY_BIN}"
command_args="run -config ${XRAY_MAIN_CONFIG}"
command_background="yes"
pidfile="/run/xray.pid"
output_log="${XRAY_LOG_DIR}/access.log"
error_log="${XRAY_LOG_DIR}/error.log"
depend() { need net; }
start_pre() { checkpath --directory --mode 0755 ${XRAY_LOG_DIR}; }
EOF
        chmod +x /etc/init.d/xray
    fi
}

# ==============================================================
# Realm 安装 & 服务文件
# ==============================================================
install_realm() {
    if [[ -x "$REALM_BIN" ]]; then
        log_info "Realm 已安装"
        _ensure_realm_service
        return 0
    fi
    log_step "安装 Realm..."
    local tag arch asset url tmp
    tag=$(curl -fsSL "https://api.github.com/repos/zhboner/realm/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)
    [[ -z "$tag" ]] && { log_error "Realm 版本获取失败，请检查网络"; return 1; }
    case "$(uname -m)" in
        x86_64|amd64) arch="x86_64-unknown-linux-gnu" ;;
        aarch64|arm64) arch="aarch64-unknown-linux-gnu" ;;
        *) log_error "不支持架构：$(uname -m)"; return 1 ;;
    esac
    asset="realm-${arch}.tar.gz"
    url="https://github.com/zhboner/realm/releases/download/${tag}/${asset}"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    gh_download "$url" "$tmp/$asset"
    tar -xzf "$tmp/$asset" -C "$tmp"
    install -m 755 "$tmp/realm" "$REALM_BIN"
    log_success "Realm $tag 安装完成"
    _ensure_realm_service
}

_ensure_realm_service() {
    if [[ "$SVC_MGR" == "systemd" ]]; then
        cat > /etc/systemd/system/realm.service <<EOF
[Unit]
Description=Realm Relay Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${REALM_ETC}
ExecStart=${REALM_BIN} -c ${REALM_CFG}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    else
        cat > /etc/init.d/realm <<EOF
#!/sbin/openrc-run
name="realm"
description="Realm Relay Service"
command="${REALM_BIN}"
command_args="-c ${REALM_CFG}"
command_background="yes"
pidfile="/run/realm.pid"
depend() { need net; }
EOF
        chmod +x /etc/init.d/realm
    fi
}

# ==============================================================
# 用 Python 生成 Xray 合法 JSON（彻底杜绝拼接 bug）
# ==============================================================
regen_xray_config() {
    log_step "重新生成 Xray 主配置..."
    mkdir -p "$XRAY_ETC"
    ensure_python

    local cfg
    cfg=$($PYTHON - "$NODE_DB" "$XRAY_LOG_DIR" <<'PYEOF'
import sys, json, os

node_db = sys.argv[1]
log_dir = sys.argv[2]

def read_db(path):
    rows = []
    if not os.path.isfile(path):
        return rows
    with open(path, 'r') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line or line.startswith('#'):
                continue
            rows.append(line)
    return rows

inbounds = []
outbounds = [
    {"protocol": "freedom",   "tag": "direct", "settings": {}},
    {"protocol": "blackhole", "tag": "block",  "settings": {}}
]
rules = [
    {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}
]

for line in read_db(node_db):
    parts = line.split('|')
    if len(parts) < 7:
        continue
    uuid        = parts[0].strip()
    port        = parts[1].strip()
    sni         = parts[2].strip()
    short_id    = parts[3].strip()
    private_key = parts[4].strip()
    name        = parts[5].strip()
    fp          = parts[6].strip() or 'chrome'

    if not uuid or not port.isdigit():
        continue

    tag = "vless-in-{}-{}".format(port, uuid[:8])
    inbounds.append({
        "tag": tag,
        "port": int(port),
        "listen": "::",
        "protocol": "vless",
        "settings": {
            "clients": [{"id": uuid, "flow": "xtls-rprx-vision"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": False,
                "dest": "{}:443".format(sni),
                "serverNames": [sni],
                "privateKey": private_key,
                "shortIds": [short_id]
            }
        },
        "sniffing": {
            "enabled": True,
            "destOverride": ["http", "tls", "quic"]
        }
    })

config = {
    "log": {
        "loglevel": "warning",
        "access": "{}/access.log".format(log_dir),
        "error":  "{}/error.log".format(log_dir)
    },
    "inbounds":  inbounds,
    "outbounds": outbounds,
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": rules
    }
}
print(json.dumps(config, indent=2, ensure_ascii=False))
PYEOF
)

    if [[ -z "$cfg" ]]; then
        log_error "Python 配置生成失败（输出为空）"
        return 1
    fi

    echo "$cfg" > "$XRAY_MAIN_CONFIG"

    local test_out
    if ! test_out=$("$XRAY_BIN" run -test -config "$XRAY_MAIN_CONFIG" 2>&1); then
        log_error "Xray 配置验证失败:"
        echo "$test_out"
        log_error "生成的配置文件内容:"
        cat "$XRAY_MAIN_CONFIG"
        return 1
    fi
    log_success "Xray 配置验证通过"
}

# ==============================================================
# 服务控制
# ==============================================================
svc_do() {
    local svc="$1" action="$2"
    if [[ "$SVC_MGR" == "systemd" ]]; then
        systemctl "$action" "$svc" 2>/dev/null || true
    else
        /etc/init.d/"$svc" "$action" 2>/dev/null || true
    fi
}

xray_is_active() {
    if [[ "$SVC_MGR" == "systemd" ]]; then
        systemctl is-active --quiet xray 2>/dev/null
    else
        /etc/init.d/xray status 2>/dev/null | grep -q "started"
    fi
}

realm_is_active() {
    if [[ "$SVC_MGR" == "systemd" ]]; then
        systemctl is-active --quiet realm 2>/dev/null
    else
        /etc/init.d/realm status 2>/dev/null | grep -q "started"
    fi
}

enable_and_start_xray() {
    _ensure_xray_service
    if [[ "$SVC_MGR" == "systemd" ]]; then
        systemctl daemon-reload
        systemctl enable xray >/dev/null 2>&1 || true
        systemctl restart xray
        sleep 2
        if systemctl is-active --quiet xray; then
            log_success "Xray 服务运行中"
        else
            log_error "Xray 启动失败，错误日志："
            journalctl -u xray -n 30 --no-pager 2>/dev/null || true
        fi
    else
        rc-update add xray default >/dev/null 2>&1 || true
        /etc/init.d/xray restart
        sleep 2
        if /etc/init.d/xray status 2>/dev/null | grep -q "started"; then
            log_success "Xray 服务运行中"
        else
            log_error "Xray 启动失败，错误日志："
            tail -n 30 "$XRAY_LOG_DIR/error.log" 2>/dev/null || true
        fi
    fi
}

enable_and_start_realm() {
    _ensure_realm_service
    if [[ "$SVC_MGR" == "systemd" ]]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable realm >/dev/null 2>&1 || true
        systemctl restart realm
        sleep 1
        if systemctl is-active --quiet realm; then
            log_success "Realm 服务运行中"
        else
            log_warn "Realm 启动可能失败："
            journalctl -u realm -n 20 --no-pager 2>/dev/null || true
        fi
    else
        rc-update add realm default >/dev/null 2>&1 || true
        /etc/init.d/realm restart
        sleep 1
        log_success "Realm 服务重启完成"
    fi
}

# ==============================================================
# 工具函数
# ==============================================================
urlencode() {
    local str="$1" encoded="" pos c
    for (( pos=0; pos<${#str}; pos++ )); do
        c="${str:$pos:1}"
        case "$c" in
            [-_.~a-zA-Z0-9]) encoded+="$c" ;;
            *) printf -v c '%%%02X' "'$c"; encoded+="$c" ;;
        esac
    done
    echo "$encoded"
}

make_vless_uri() {
    local uuid="$1" ip="$2" port="$3" sni="$4" pbk="$5" sid="$6" name="$7" fp="$8" is_v6="${9:-0}"
    local enc_name host
    enc_name=$(urlencode "$name")
    host="$ip"
    [[ "$is_v6" == "1" ]] && host="[${ip}]"
    echo "vless://${uuid}@${host}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=${fp}&pbk=${pbk}&sid=${sid}&type=tcp&headerType=none#${enc_name}"
}

_allow_port() {
    local port="$1"
    if cmd_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$port"/tcp >/dev/null 2>&1 || true
        ufw allow "$port"/udp >/dev/null 2>&1 || true
    fi
    if cmd_exists iptables; then
        iptables  -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
            || iptables  -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        ip6tables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
            || ip6tables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
    fi
    if cmd_exists firewall-cmd; then
        firewall-cmd --permanent --add-port="$port"/tcp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

# ==============================================================
# ══ VLESS 节点管理 ═════════════════════════════════════════════
# ==============================================================

add_vless_node() {
    log_title "添加 VLESS+Reality+Vision 节点"

    if [[ ! -x "$XRAY_BIN" ]]; then
        log_warn "Xray 未安装，自动安装..."
        system_init
        install_xray
    fi

    local name
    read -rp "节点名称 [回车=自动]: " name
    [[ -z "$name" ]] && name="VLESS-$(date +%Y%m%d-%H%M%S)"

    local port
    while true; do
        read -rp "监听端口 [回车=443]: " port
        [[ -z "$port" ]] && port=443
        if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            log_error "端口无效"; continue
        fi
        break
    done

    local sni
    read -rp "SNI 伪装域名 [回车=www.cloudflare.com]: " sni
    [[ -z "$sni" ]] && sni="www.cloudflare.com"

    echo "可用指纹: chrome  firefox  safari  ios  android  edge  360  qq"
    local fp
    read -rp "Fingerprint [回车=chrome]: " fp
    [[ -z "$fp" ]] && fp="chrome"

    log_step "生成 X25519 密钥对..."
    local key_out
    key_out=$("$XRAY_BIN" x25519 2>&1)
    parse_xray_keys "$key_out"
    local private_key="$PARSED_PRIVATE" public_key="$PARSED_PUBLIC"

    local uuid short_id
    uuid=$(gen_uuid)
    short_id=$(openssl rand -hex 8)

    log_info "UUID:        $uuid"
    log_info "Public Key:  $public_key"
    log_info "Short ID:    $short_id"

    # 写入节点 DB
    echo "${uuid}|${port}|${sni}|${short_id}|${private_key}|${name}|${fp}" >> "$NODE_DB"

    _allow_port "$port"

    if ! regen_xray_config; then
        log_error "配置生成失败，回滚"
        local tmp; tmp=$(mktemp)
        grep -v "^${uuid}|" "$NODE_DB" > "$tmp" || true
        cat "$tmp" > "$NODE_DB"; rm -f "$tmp"
        return 1
    fi

    enable_and_start_xray

    echo ""
    log_success "节点 '$name' 添加成功！"
    _show_node_detail "$uuid" "$port" "$sni" "$short_id" "$private_key" "$public_key" "$name" "$fp"
}

_show_node_detail() {
    local uuid="$1" port="$2" sni="$3" short_id="$4" \
          private_key="$5" public_key="$6" name="$7" fp="${8:-chrome}"
    local ipv4 ipv6
    ipv4=$(get_ipv4); ipv6=$(get_ipv6)

    echo ""
    echo -e "${CYAN}══════════ 节点：$name ══════════${NC}"
    echo "名称:        $name"
    echo "UUID:        $uuid"
    echo "Private Key: $private_key"
    echo "Public Key:  $public_key"
    echo "Short ID:    $short_id"
    echo "SNI:         $sni"
    echo "Port:        $port"
    echo "Fingerprint: $fp"
    [[ -n "$ipv4" ]] && echo "Server IPv4: $ipv4"
    [[ -n "$ipv6" ]] && echo "Server IPv6: $ipv6"
    echo ""

    if [[ -n "$ipv4" ]]; then
        local uri; uri=$(make_vless_uri "$uuid" "$ipv4" "$port" "$sni" "$public_key" "$short_id" "$name" "$fp" "0")
        echo -e "${GREEN}━━ VLESS URI (IPv4) ━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}${uri}${NC}"
        echo ""
    fi
    if [[ -n "$ipv6" ]]; then
        local uri6; uri6=$(make_vless_uri "$uuid" "$ipv6" "$port" "$sni" "$public_key" "$short_id" "${name}-v6" "$fp" "1")
        echo -e "${GREEN}━━ VLESS URI (IPv6) ━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}${uri6}${NC}"
        echo ""
    fi

    local server="${ipv4:-$ipv6}"
    echo -e "${GREEN}━━ Clash Meta 配置片段 ━━━━━━━━━━━━━━━━━━━━${NC}"
    cat <<EOF
  - name: "$name"
    type: vless
    server: $server
    port: $port
    uuid: $uuid
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $sni
    reality-opts:
      public-key: $public_key
      short-id: $short_id
    client-fingerprint: $fp
EOF
    echo -e "${CYAN}════════════════════════════════════════════${NC}"
}

list_vless_nodes() {
    echo ""
    echo -e "${CYAN}── VLESS 节点列表 ──────────────────────────${NC}"
    if [[ ! -s "$NODE_DB" ]]; then echo "  (无节点)"; return 0; fi
    local idx=0
    while IFS='|' read -r uuid port sni short_id private_key name fp || [[ -n "$uuid" ]]; do
        [[ -z "$uuid" || "${uuid:0:1}" == "#" ]] && continue
        idx=$(( idx + 1 ))
        echo "  [$idx] $name  端口:$port  SNI:$sni  UUID:${uuid:0:8}..."
    done < "$NODE_DB"
    [[ $idx -eq 0 ]] && echo "  (无节点)"
    return 0
}

_pick_node() {
    list_vless_nodes
    [[ ! -s "$NODE_DB" ]] && return 1
    local n; read -rp "请输入序号: " n
    n="${n// /}"
    [[ ! "$n" =~ ^[0-9]+$ ]] && { log_error "序号无效"; return 1; }
    PICKED_NODE_LINE=$(awk -F'|' '!/^#/ && NF>=7' "$NODE_DB" | awk -v n="$n" 'NR==n')
    [[ -z "$PICKED_NODE_LINE" ]] && { log_error "序号不存在"; return 1; }
    return 0
}

show_vless_node() {
    log_title "查看节点信息"
    _pick_node || return
    IFS='|' read -r uuid port sni short_id private_key name fp <<< "$PICKED_NODE_LINE"
    local public_key; public_key=$(derive_public_key "$private_key")
    _show_node_detail "$uuid" "$port" "$sni" "$short_id" "$private_key" "$public_key" "$name" "$fp"
}

show_all_vless_nodes() {
    log_title "所有节点连接信息"
    if [[ ! -s "$NODE_DB" ]]; then echo "  (无节点)"; return; fi
    while IFS='|' read -r uuid port sni short_id private_key name fp || [[ -n "$uuid" ]]; do
        [[ -z "$uuid" || "${uuid:0:1}" == "#" ]] && continue
        local public_key; public_key=$(derive_public_key "$private_key")
        _show_node_detail "$uuid" "$port" "$sni" "$short_id" "$private_key" "$public_key" "$name" "${fp:-chrome}"
    done < "$NODE_DB"
}

export_vless_nodes() {
    log_title "导出节点连接信息"
    local outfile="$BACKUP_DIR/vless_export_$(date +%Y%m%d_%H%M%S).txt"
    mkdir -p "$BACKUP_DIR"
    local ipv4 ipv6
    ipv4=$(get_ipv4); ipv6=$(get_ipv6)
    {
        echo "# VPS Manager ${SCRIPT_VERSION} - VLESS 节点导出"
        echo "# 时间: $(date)"
        echo "# IPv4: ${ipv4:-N/A}  IPv6: ${ipv6:-N/A}"
        echo ""
        if [[ -s "$NODE_DB" ]]; then
            while IFS='|' read -r uuid port sni short_id private_key name fp || [[ -n "$uuid" ]]; do
                [[ -z "$uuid" || "${uuid:0:1}" == "#" ]] && continue
                local public_key; public_key=$(derive_public_key "$private_key")
                echo "## $name"
                [[ -n "$ipv4" ]] && make_vless_uri "$uuid" "$ipv4" "$port" "$sni" "$public_key" "$short_id" "$name" "${fp:-chrome}" "0"
                [[ -n "$ipv6" ]] && make_vless_uri "$uuid" "$ipv6" "$port" "$sni" "$public_key" "$short_id" "${name}-v6" "${fp:-chrome}" "1"
                echo ""
            done < "$NODE_DB"
        else
            echo "(无节点)"
        fi
    } > "$outfile"
    log_success "已导出到: $outfile"
    cat "$outfile"
}

delete_vless_node() {
    log_title "删除 VLESS 节点"
    _pick_node || return
    IFS='|' read -r uuid port sni short_id private_key name fp <<< "$PICKED_NODE_LINE"
    read -rp "确认删除节点 '$name'? [y/N]: " confirm
    [[ "${confirm:-N}" != "y" ]] && { log_info "已取消"; return; }
    local tmp; tmp=$(mktemp)
    grep -v "^${uuid}|" "$NODE_DB" > "$tmp" || true
    cat "$tmp" > "$NODE_DB"; rm -f "$tmp"
    regen_xray_config && enable_and_start_xray
    log_success "节点 '$name' 已删除"
}

test_vless_node() {
    log_title "检测 VLESS 节点"
    _pick_node || return
    IFS='|' read -r uuid port sni short_id private_key name fp <<< "$PICKED_NODE_LINE"
    echo ""

    log_step "1. 检查 Xray 服务状态..."
    if xray_is_active; then
        log_success "Xray 运行中"
    else
        log_error "Xray 未运行，尝试自动启动..."
        enable_and_start_xray
        if xray_is_active; then
            log_success "Xray 已成功启动"
        else
            log_error "Xray 仍无法启动，请查看菜单 → Xray服务管理 → 查看日志"
        fi
    fi

    log_step "2. 验证配置文件..."
    local test_out
    if test_out=$("$XRAY_BIN" run -test -config "$XRAY_MAIN_CONFIG" 2>&1); then
        log_success "配置文件验证通过"
    else
        log_error "配置文件验证失败:"
        echo "$test_out" | head -10
    fi

    log_step "3. 检查端口 $port 监听..."
    if ss -tlnp 2>/dev/null | grep -q ":${port}[[:space:]]"; then
        log_success "端口 $port 正在监听"
    else
        log_warn "端口 $port 未检测到监听（若 Xray 已运行，可能是容器网络特性，请从客户端实际连接测试）"
    fi

    log_step "4. 测试 SNI 目标可达性 ($sni)..."
    local http_code
    http_code=$(curl -sI --max-time 5 "https://${sni}" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "0")
    if [[ "$http_code" =~ ^[23] ]]; then
        log_success "SNI 目标 $sni 可达 (HTTP $http_code)"
    else
        log_warn "SNI 目标 $sni 返回 $http_code，建议更换伪装域名"
    fi

    log_step "5. 防火墙检查 (端口 $port)..."
    if cmd_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ufw status | grep -q "$port"; then
            log_success "UFW 已放行端口 $port"
        else
            log_warn "UFW 中未发现端口 $port 规则，自动添加..."
            ufw allow "$port"/tcp >/dev/null 2>&1 && log_success "已添加 UFW 规则"
        fi
    else
        log_info "UFW 未启用，跳过"
    fi

    echo ""
    log_success "检测完成 - 节点: $name"
}

# ==============================================================
# ══ Xray 服务管理菜单 ══════════════════════════════════════════
# ==============================================================

xray_service_menu() {
    while true; do
        log_title "Xray 服务管理"
        echo "  1) 查看状态"
        echo "  2) 重启"
        echo "  3) 停止"
        echo "  4) 启动"
        echo "  5) 查看日志（最近50行）"
        echo "  6) 实时日志（Ctrl+C 退出）"
        echo "  7) 强制修复并重启（重写服务文件+重启）"
        echo "  0) 返回"
        read -rp "请选择: " c
        case "${c:-}" in
            1) _show_xray_status ;;
            2) enable_and_start_xray ;;
            3) svc_do xray stop && log_info "Xray 已停止" ;;
            4) enable_and_start_xray ;;
            5) _xray_log_tail 50 ;;
            6) _xray_log_follow ;;
            7) _ensure_xray_service; regen_xray_config; enable_and_start_xray ;;
            0) break ;;
            *) log_warn "无效选项" ;;
        esac
    done
}

_show_xray_status() {
    echo ""
    echo -e "${CYAN}── Xray 状态 ──────────────────────────────${NC}"
    if [[ -x "$XRAY_BIN" ]]; then
        echo "版本: $("$XRAY_BIN" version 2>&1 | head -1)"
    else
        echo "Xray: 未安装"
    fi
    echo "配置: $XRAY_MAIN_CONFIG $([[ -f "$XRAY_MAIN_CONFIG" ]] && echo '(存在)' || echo '(缺失)')"
    local sf_status="缺失"
    [[ -f /etc/systemd/system/xray.service || -f /etc/init.d/xray ]] && sf_status="存在"
    echo "服务文件: $sf_status"
    echo ""
    if [[ "$SVC_MGR" == "systemd" ]]; then
        systemctl --no-pager status xray 2>/dev/null || echo "（服务未安装）"
    else
        /etc/init.d/xray status 2>/dev/null || echo "（服务未安装）"
    fi
    echo ""
    echo "端口监听:"
    ss -tlnp 2>/dev/null | awk 'NR==1 || /xray/' || echo "（无）"
}

_xray_log_tail() {
    local n="${1:-50}"
    if [[ "$SVC_MGR" == "systemd" ]]; then
        journalctl -u xray -n "$n" --no-pager 2>/dev/null \
            || tail -n "$n" "$XRAY_LOG_DIR/error.log" 2>/dev/null \
            || log_warn "日志不可读"
    else
        tail -n "$n" "$XRAY_LOG_DIR/error.log" 2>/dev/null || log_warn "日志不可读"
    fi
}

_xray_log_follow() {
    echo "按 Ctrl+C 退出..."
    if [[ "$SVC_MGR" == "systemd" ]]; then
        journalctl -u xray -f 2>/dev/null \
            || tail -f "$XRAY_LOG_DIR/error.log" 2>/dev/null \
            || log_warn "日志不可读"
    else
        tail -f "$XRAY_LOG_DIR/error.log" 2>/dev/null || log_warn "日志不可读"
    fi
}

# ==============================================================
# ══ Realm 端口转发管理 ═════════════════════════════════════════
#
# REALM_DB 每行: label|listen_port|remote_host|remote_port|active(0/1)
#
# 架构说明:
#   所有落地候选共用同一个对外入站端口（如 10443）。
#   active=1 的那条是当前生效的落地。
#   切换落地只需把 active 字段改一改，重启 Realm 即可，秒级生效。
#   对客户端而言连接参数永远不变（中转IP:10443），换落地无感知。
# ==============================================================

_realm_listen_port() {
    awk -F'|' '!/^#/ && NF>=5 {print $2; exit}' "$REALM_DB" 2>/dev/null || echo ""
}

regen_realm_config() {
    log_step "重新生成 Realm 配置..."
    mkdir -p "$REALM_ETC"
    cat > "$REALM_CFG" <<'TOMLEOF'
# Auto-generated by vps_manager.sh

[log]
level = "warn"

[network]
no_tcp  = false
use_udp = true

TOMLEOF

    local found=0
    while IFS='|' read -r label listen_port remote_host remote_port active || [[ -n "$label" ]]; do
        [[ -z "$label" || "${label:0:1}" == "#" ]] && continue
        [[ "${active:-0}" != "1" ]] && continue

        local rh="$remote_host"
        if [[ "$rh" =~ : ]] && [[ ! "$rh" =~ ^\[.*\]$ ]]; then
            rh="[${rh}]"
        fi

        cat >> "$REALM_CFG" <<EOF
[[endpoints]]
# $label
listen = "[::]:${listen_port}"
remote = "${rh}:${remote_port}"

EOF
        found=1
        break  # 只写激活的一条
    done < "$REALM_DB"

    if [[ $found -eq 0 ]]; then
        echo "# No active endpoint." >> "$REALM_CFG"
        log_warn "没有激活的 Realm 转发条目"
    else
        log_success "Realm 配置生成完成"
    fi
}

list_realm_entries() {
    echo ""
    echo -e "${CYAN}── Realm 落地候选列表 ──────────────────────${NC}"
    echo "  （对外入站端口: $(_realm_listen_port || echo '未配置')）"
    echo ""
    if [[ ! -s "$REALM_DB" ]]; then
        echo "  (空)"
        return 0
    fi
    local idx=0
    while IFS='|' read -r label listen_port remote_host remote_port active || [[ -n "$label" ]]; do
        [[ -z "$label" || "${label:0:1}" == "#" ]] && continue
        idx=$(( idx + 1 ))
        local mark="      "
        [[ "${active:-0}" == "1" ]] && mark="${GREEN}[激活]${NC}"
        echo -e "  [$idx] ${mark} $label  落地:${remote_host}:${remote_port}"
    done < "$REALM_DB"
    [[ $idx -eq 0 ]] && echo "  (空)"
    echo ""
    return 0
}

add_realm_entry() {
    log_title "新增 Realm 落地候选"

    if [[ ! -x "$REALM_BIN" ]]; then
        log_warn "Realm 未安装，自动安装..."
        install_realm
    fi

    # 对外入站端口，所有候选共用
    local listen_port
    local existing_port; existing_port=$(_realm_listen_port)
    if [[ -n "$existing_port" ]]; then
        log_info "当前对外入站端口: $existing_port（新候选将共用此端口）"
        read -rp "是否更改对外端口? [回车保持 $existing_port / 输入新端口]: " new_lp
        new_lp="${new_lp// /}"
        if [[ -n "$new_lp" ]]; then
            if ! [[ "$new_lp" =~ ^[0-9]+$ ]] || (( new_lp < 1 || new_lp > 65535 )); then
                log_error "端口无效"; return 1
            fi
            listen_port="$new_lp"
        else
            listen_port="$existing_port"
        fi
    else
        while true; do
            read -rp "Realm 对外入站端口 [回车=10443]: " listen_port
            listen_port="${listen_port// /}"
            [[ -z "$listen_port" ]] && listen_port=10443
            if ! [[ "$listen_port" =~ ^[0-9]+$ ]] || (( listen_port < 1 || listen_port > 65535 )); then
                log_error "端口无效"; continue
            fi
            break
        done
    fi

    read -rp "落地 VPS IP（或域名）: " remote_host
    remote_host="${remote_host// /}"
    [[ -z "$remote_host" ]] && { log_error "地址不能为空"; return 1; }

    local remote_port
    while true; do
        read -rp "落地 VPS 端口: " remote_port
        remote_port="${remote_port// /}"
        if ! [[ "$remote_port" =~ ^[0-9]+$ ]] || (( remote_port < 1 || remote_port > 65535 )); then
            log_error "端口无效"; continue
        fi
        break
    done

    local label
    read -rp "备注名称 [回车=自动]: " label
    [[ -z "$label" ]] && label="${remote_host}-${remote_port}"

    # 第一条自动激活，否则询问
    local active=0
    if [[ ! -s "$REALM_DB" ]]; then
        active=1
        log_info "首条候选，自动激活"
    else
        read -rp "是否立即激活此条? [y/N]: " act_choice
        [[ "${act_choice:-N}" == "y" ]] && active=1
    fi

    if [[ $active -eq 1 ]]; then
        _deactivate_all_realm
    fi

    echo "${label}|${listen_port}|${remote_host}|${remote_port}|${active}" >> "$REALM_DB"
    _allow_port "$listen_port"
    regen_realm_config
    enable_and_start_realm

    log_success "已添加: [$( [[ $active -eq 1 ]] && echo '激活' || echo '候选')] $label → ${remote_host}:${remote_port}  入站:$listen_port"
    list_realm_entries
}

_deactivate_all_realm() {
    [[ ! -s "$REALM_DB" ]] && return
    local tmp; tmp=$(mktemp)
    awk -F'|' 'BEGIN{OFS="|"} /^#/{print;next} NF>=5{$5=0; print}' "$REALM_DB" > "$tmp"
    cat "$tmp" > "$REALM_DB"; rm -f "$tmp"
}

switch_realm_active() {
    log_title "切换激活落地（一键切换）"
    list_realm_entries
    [[ ! -s "$REALM_DB" ]] && return

    local n; read -rp "请输入要激活的序号: " n
    n="${n// /}"
    [[ ! "$n" =~ ^[0-9]+$ ]] && { log_error "序号无效"; return 1; }

    local target_line
    target_line=$(awk -F'|' '!/^#/ && NF>=5' "$REALM_DB" | awk -v n="$n" 'NR==n')
    [[ -z "$target_line" ]] && { log_error "序号不存在"; return 1; }

    IFS='|' read -r label listen_port remote_host remote_port active <<< "$target_line"

    local tmp; tmp=$(mktemp)
    awk -F'|' -v n="$n" 'BEGIN{OFS="|"; cnt=0}
        /^#/{print; next}
        NF>=5{
            cnt++
            if(cnt==n) $5=1
            else $5=0
            print
        }' "$REALM_DB" > "$tmp"
    cat "$tmp" > "$REALM_DB"; rm -f "$tmp"

    regen_realm_config
    enable_and_start_realm
    log_success "已切换激活到: $label (${remote_host}:${remote_port})"
    list_realm_entries
}

delete_realm_entry() {
    log_title "删除 Realm 落地候选"
    list_realm_entries
    [[ ! -s "$REALM_DB" ]] && return

    local n; read -rp "请输入要删除的序号: " n
    n="${n// /}"
    [[ ! "$n" =~ ^[0-9]+$ ]] && { log_error "序号无效"; return 1; }

    local tmp; tmp=$(mktemp)
    awk -F'|' '!/^#/ && NF>=5' "$REALM_DB" | awk -v n="$n" 'NR!=n' > "$tmp"
    cat "$tmp" > "$REALM_DB"; rm -f "$tmp"

    regen_realm_config
    enable_and_start_realm
    log_success "已删除序号 $n"
    list_realm_entries
}

edit_realm_entry() {
    log_title "修改 Realm 落地候选"
    list_realm_entries
    [[ ! -s "$REALM_DB" ]] && return

    local n; read -rp "请输入要修改的序号: " n
    n="${n// /}"
    [[ ! "$n" =~ ^[0-9]+$ ]] && { log_error "序号无效"; return 1; }

    local old_line
    old_line=$(awk -F'|' '!/^#/ && NF>=5' "$REALM_DB" | awk -v n="$n" 'NR==n')
    [[ -z "$old_line" ]] && { log_error "序号不存在"; return 1; }

    IFS='|' read -r old_label old_lp old_rh old_rp old_act <<< "$old_line"
    echo "当前: $old_label | 入站:$old_lp | 落地:${old_rh}:${old_rp}"

    local new_label new_lp new_rh new_rp
    read -rp "新名称     [回车保持 $old_label]: " new_label; [[ -z "$new_label" ]] && new_label="$old_label"
    read -rp "新入站端口 [回车保持 $old_lp]: "   new_lp;    [[ -z "$new_lp" ]]    && new_lp="$old_lp"
    read -rp "新落地地址 [回车保持 $old_rh]: "   new_rh;    [[ -z "$new_rh" ]]    && new_rh="$old_rh"
    read -rp "新落地端口 [回车保持 $old_rp]: "   new_rp;    [[ -z "$new_rp" ]]    && new_rp="$old_rp"

    local tmp; tmp=$(mktemp)
    awk -F'|' -v n="$n" -v nl="$new_label" -v lp="$new_lp" -v rh="$new_rh" -v rp="$new_rp" \
        'BEGIN{OFS="|"; cnt=0}
         /^#/{print; next}
         NF>=5{
             cnt++
             if(cnt==n){$1=nl; $2=lp; $3=rh; $4=rp}
             print
         }' "$REALM_DB" > "$tmp"
    cat "$tmp" > "$REALM_DB"; rm -f "$tmp"

    regen_realm_config
    enable_and_start_realm
    log_success "已修改"
    list_realm_entries
}

test_realm() {
    log_title "Realm 链路检测"
    if [[ ! -s "$REALM_DB" ]]; then echo "  无规则"; return; fi

    while IFS='|' read -r label listen_port remote_host remote_port active || [[ -n "$label" ]]; do
        [[ -z "$label" || "${label:0:1}" == "#" ]] && continue
        local mark=""; [[ "${active:-0}" == "1" ]] && mark="${GREEN}[激活]${NC}"
        echo ""
        echo -e "── $label $mark  入站:$listen_port → ${remote_host}:${remote_port}"

        # DNS 解析
        local resolved="$remote_host"
        if [[ ! "$remote_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ ! "$remote_host" =~ : ]]; then
            local r; r=$(getent ahosts "$remote_host" 2>/dev/null | awk '{print $1}' | head -1 || true)
            if [[ -n "$r" ]]; then
                log_info "  DNS: $remote_host → $r"
                resolved="$r"
            else
                log_warn "  DNS 解析失败: $remote_host"
            fi
        fi

        # TCP 探测落地
        if [[ -n "$resolved" ]]; then
            if timeout 4 bash -c "cat < /dev/null > /dev/tcp/${resolved}/${remote_port}" >/dev/null 2>&1; then
                log_success "  落地 TCP: ${resolved}:${remote_port} OK"
            else
                log_error   "  落地 TCP: ${resolved}:${remote_port} FAIL"
            fi
        fi

        # 本地入站端口（只检测激活条目）
        if [[ "${active:-0}" == "1" ]]; then
            if ss -tlnp 2>/dev/null | grep -q ":${listen_port}[[:space:]]"; then
                log_success "  本地入站端口 $listen_port 监听: OK"
            else
                log_warn "  本地入站端口 $listen_port 未检测到监听"
            fi
        fi
    done < "$REALM_DB"
    echo ""
}

realm_service_menu() {
    while true; do
        log_title "Realm 服务管理"
        echo "  1) 查看状态"
        echo "  2) 重启"
        echo "  3) 停止"
        echo "  4) 启动"
        echo "  5) 查看日志（最近50行）"
        echo "  0) 返回"
        read -rp "请选择: " c
        case "${c:-}" in
            1) _show_realm_status ;;
            2) enable_and_start_realm ;;
            3) svc_do realm stop && log_info "Realm 已停止" ;;
            4) enable_and_start_realm ;;
            5) journalctl -u realm -n 50 --no-pager 2>/dev/null \
                   || tail -n 50 /var/log/realm.log 2>/dev/null \
                   || log_warn "日志不可读" ;;
            0) break ;;
            *) log_warn "无效选项" ;;
        esac
    done
}

_show_realm_status() {
    echo ""
    echo -e "${CYAN}── Realm 状态 ──────────────────────────────${NC}"
    [[ -x "$REALM_BIN" ]] && echo "二进制: 已安装" || echo "二进制: 未安装"
    echo "配置: $REALM_CFG $([[ -f "$REALM_CFG" ]] && echo '(存在)' || echo '(缺失)')"
    echo ""
    if [[ "$SVC_MGR" == "systemd" ]]; then
        systemctl --no-pager status realm 2>/dev/null || echo "（服务未安装）"
    else
        /etc/init.d/realm status 2>/dev/null || echo "（服务未安装）"
    fi
    list_realm_entries
}

# ==============================================================
# ══ Realm 菜单 ════════════════════════════════════════════════
# ==============================================================
realm_menu() {
    while true; do
        log_title "Realm 端口转发管理"
        local lp; lp=$(_realm_listen_port)
        if [[ -n "$lp" ]]; then
            echo -e "  对外入站端口: ${CYAN}${lp}${NC}（客户端连接此端口）"
        else
            echo "  尚未配置入站端口"
        fi
        echo ""
        echo "  1) 新增落地候选"
        echo "  2) 查看所有落地候选"
        echo "  3) 切换激活落地（一键切换，秒级生效）"
        echo "  4) 修改落地候选"
        echo "  5) 删除落地候选"
        echo "  6) 链路检测"
        echo "  7) Realm 服务管理"
        echo "  0) 返回主菜单"
        read -rp "请选择: " c
        case "${c:-}" in
            1) add_realm_entry ;;
            2) list_realm_entries ;;
            3) switch_realm_active ;;
            4) edit_realm_entry ;;
            5) delete_realm_entry ;;
            6) test_realm ;;
            7) realm_service_menu ;;
            0) break ;;
            *) log_warn "无效选项" ;;
        esac
    done
}

# ==============================================================
# ══ 系统总览 ═══════════════════════════════════════════════════
# ==============================================================
show_overview() {
    log_title "系统总览"
    local ipv4 ipv6
    ipv4=$(get_ipv4); ipv6=$(get_ipv6)

    echo "━━ 服务器 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "OS:    $OS_TYPE | 内核: $(uname -r)"
    echo "内存:  ${TOTAL_MEM}MB  磁盘: ${TOTAL_DISK}GB"
    echo "IPv4:  ${ipv4:-N/A}"
    echo "IPv6:  ${ipv6:-N/A}"
    echo ""
    echo "━━ Xray ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ -x "$XRAY_BIN" ]]; then
        echo "版本: $("$XRAY_BIN" version 2>&1 | head -1)"
        xray_is_active \
            && echo -e "服务: ${GREEN}运行中${NC}" \
            || echo -e "服务: ${RED}已停止${NC}"
    else
        echo -e "${RED}未安装${NC}"
    fi
    echo ""
    echo "━━ Realm ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ -x "$REALM_BIN" ]]; then
        realm_is_active \
            && echo -e "服务: ${GREEN}运行中${NC}" \
            || echo -e "服务: ${RED}已停止${NC}"
    else
        echo -e "${RED}未安装${NC}"
    fi
    echo ""
    echo "━━ VLESS 节点 ━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    list_vless_nodes
    echo ""
    echo "━━ Realm 落地 ━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    list_realm_entries
    echo ""
    echo "━━ 端口监听 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ss -tlnp 2>/dev/null | awk 'NR==1 || /LISTEN/' | head -15 || echo "  无法获取"
    echo ""
}

# ==============================================================
# ══ 一键初始化 ═════════════════════════════════════════════════
# ==============================================================
full_install() {
    log_title "一键初始化（安装 Xray + Realm）"
    system_init
    install_xray
    install_realm
    log_success "基础安装完成！请通过菜单添加节点和转发规则。"
}

# ==============================================================
# ══ 主菜单 ═════════════════════════════════════════════════════
# ==============================================================
main_menu() {
    need_root
    detect_os
    ensure_python
    mkdir -p "$DATA_DIR" "$BACKUP_DIR" "$XRAY_LOG_DIR" "$XRAY_ETC" "$REALM_ETC"
    touch "$NODE_DB" "$REALM_DB" 2>/dev/null || true

    while true; do
        echo ""
        echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║  VPS 一键管理 ${SCRIPT_VERSION}                       ║${NC}"
        echo -e "${BLUE}║  Xray VLESS+Reality+Vision + Realm 转发       ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${CYAN}── VLESS 节点 ──────────────────────────────────${NC}"
        echo "   1) 添加节点"
        echo "   2) 删除节点"
        echo "   3) 查看指定节点信息 & URI"
        echo "   4) 查看所有节点信息 & URI"
        echo "   5) 导出所有节点到文件"
        echo "   6) 检测节点状态"
        echo ""
        echo -e "${CYAN}── Xray 服务 ───────────────────────────────────${NC}"
        echo "   7) Xray 服务管理"
        echo ""
        echo -e "${CYAN}── Realm 端口转发 ──────────────────────────────${NC}"
        echo "   8) Realm 转发管理（增/删/改/切换/检测）"
        echo ""
        echo -e "${CYAN}── 系统 ────────────────────────────────────────${NC}"
        echo "   9) 系统总览"
        echo "  10) 一键初始化安装（Xray + Realm）"
        echo "   0) 退出"
        echo ""
        read -rp "请选择 [0-10]: " choice
        case "${choice:-}" in
            1)  add_vless_node ;;
            2)  delete_vless_node ;;
            3)  show_vless_node ;;
            4)  show_all_vless_nodes ;;
            5)  export_vless_nodes ;;
            6)  test_vless_node ;;
            7)  xray_service_menu ;;
            8)  realm_menu ;;
            9)  show_overview ;;
            10) full_install ;;
            0)  log_info "退出。"; exit 0 ;;
            *)  log_warn "无效选项" ;;
        esac
    done
}

# ── 入口 ──────────────────────────────────────────────────────
main_menu
