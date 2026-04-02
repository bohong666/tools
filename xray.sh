#!/usr/bin/env bash
# ==============================================================
# VPS 一键管理脚本  v2.0.0
# 功能: Xray VLESS+Reality+Vision  本地直连 + 链式中转
# 支持: Ubuntu/Debian/Alpine | IPv4/IPv6/双栈 | 小磁盘/容器
#
# ── 架构说明 ────────────────────────────────────────────────
#
#  本机(RFC) Xray 同时承担两个角色，共用一个 443 入站：
#
#  模式A 【直连】（默认）:
#    客户端 ──VLESS+Reality──▶ RFC:443 (Xray inbound)
#                                  │ outbound: freedom
#                                  ▼
#                               直接出网
#
#  模式B 【中转】:
#    客户端 ──VLESS+Reality──▶ RFC:443 (Xray inbound)
#                                  │ outbound: vless-to-iij
#                                  ▼
#                          IIJ:443 (Xray VLESS 落地节点)
#                                  │ outbound: freedom
#                                  ▼
#                               目标网站
#
#  两种模式 443 端口只有本机 Xray 一个进程，不存在冲突。
#  切换模式：修改 relay.db 中的 active 字段，重新生成
#            Xray config.json，重启 Xray，秒级生效。
#  客户端连接参数永远不变（RFC_IP:443），对客户端透明。
#
#  relay.db 字段:
#    label | iij_ip | iij_port | iij_uuid | iij_public_key |
#    iij_short_id | iij_sni | iij_fp | active(0/1)
# ==============================================================

SCRIPT_VERSION="v2.0.0"
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

DATA_DIR="/etc/vps_manager"
# nodes.db  每行: uuid|port|sni|short_id|private_key|name|fingerprint
NODE_DB="$DATA_DIR/nodes.db"
# relay.db  每行: label|iij_ip|iij_port|iij_uuid|iij_pubkey|iij_shortid|iij_sni|iij_fp|active
RELAY_DB="$DATA_DIR/relay.db"
BACKUP_DIR="/root/vps_manager_backups"

# ── 系统变量 ──────────────────────────────────────────────────
OS_TYPE=""; PKG_MGR=""; SVC_MGR=""
TOTAL_MEM=0; TOTAL_DISK=0
PYTHON=""
PICKED_NODE_LINE=""
PARSED_PRIVATE=""; PARSED_PUBLIC=""

# ==============================================================
# 系统检测
# ==============================================================
detect_os() {
    [[ ! -f /etc/os-release ]] && { log_error "缺少 /etc/os-release"; exit 1; }
    source /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) OS_TYPE="ubuntu"; PKG_MGR="apt";  SVC_MGR="systemd" ;;
        alpine)        OS_TYPE="alpine"; PKG_MGR="apk";  SVC_MGR="openrc"  ;;
        *) log_error "不支持的发行版: ${ID:-unknown}（仅支持 Ubuntu/Debian/Alpine）"; exit 1 ;;
    esac
    TOTAL_MEM=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo 0)
    TOTAL_DISK=$(df -BG / 2>/dev/null | awk 'NR==2{print $2}' | tr -d 'G' || echo 0)
    log_info "OS: $OS_TYPE | 内存: ${TOTAL_MEM}MB | 磁盘: ${TOTAL_DISK}GB | 服务: $SVC_MGR"
}

need_root() {
    [[ "${EUID:-$(id -u)}" -ne 0 ]] && { log_error "请以 root 权限运行：sudo $0"; exit 1; }
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

ensure_python() {
    if cmd_exists python3;  then PYTHON=python3; return; fi
    if cmd_exists python;   then PYTHON=python;  return; fi
    log_warn "未检测到 Python，正在安装..."
    [[ "$PKG_MGR" == "apt" ]] \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 >/dev/null 2>&1 \
        || apk add --no-cache -q python3 >/dev/null 2>&1
    PYTHON=python3
}

# ==============================================================
# 网络
# ==============================================================
get_ipv4() {
    local ip
    for url in https://api4.ipify.org https://ifconfig.me https://icanhazip.com; do
        ip=$(curl -s -4 --max-time 8 "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
    done; echo ""
}
get_ipv6() {
    local ip
    for url in https://api6.ipify.org https://ifconfig.me https://icanhazip.com; do
        ip=$(curl -s -6 --max-time 8 "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
    done; echo ""
}
check_github() { curl -sI --max-time 6 https://api.github.com >/dev/null 2>&1; }
gh_download() {
    local url="$1" out="$2"
    check_github \
        && curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$out" "$url" \
        || { log_warn "GitHub 不可直连，使用 ghp.ci 代理..."; \
             curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$out" "https://ghp.ci/$url"; }
}

# ==============================================================
# 密钥工具
# ==============================================================
parse_xray_keys() {
    local out="$1"
    PARSED_PRIVATE=$(echo "$out" | grep -iE "^private"          | awk '{print $NF}' | tr -d ' \r\n')
    PARSED_PUBLIC=$( echo "$out" | grep -iE "(^public|publickey)"| awk '{print $NF}' | tr -d ' \r\n')
    if [[ -z "$PARSED_PRIVATE" || -z "$PARSED_PUBLIC" ]]; then
        log_error "密钥解析失败，原始输出:"; echo "$out"; return 1
    fi
}
derive_public_key() {
    local priv="$1" out
    out=$("$XRAY_BIN" x25519 -i "$priv" 2>&1)
    echo "$out" | grep -iE "(^public|publickey)" | awk '{print $NF}' | tr -d ' \r\n'
}
gen_uuid() {
    if [[ -f /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
    elif cmd_exists uuidgen;                  then uuidgen | tr '[:upper:]' '[:lower:]'
    else od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}' | tr '[:upper:]' '[:lower:]'
    fi
}

# ==============================================================
# Swap / BBR
# ==============================================================
setup_swap() {
    local mb="$1"
    [[ -f /swapfile ]] && { swapoff /swapfile 2>/dev/null || true; rm -f /swapfile; }
    local avail_kb; avail_kb=$(df -k / | awk 'NR==2{print $4}')
    (( avail_kb < mb*1024 + 512*1024 )) && { log_warn "磁盘空间不足，跳过 Swap"; return 0; }
    fallocate -l "${mb}M" /swapfile 2>/dev/null \
        || dd if=/dev/zero of=/swapfile bs=1M count="$mb" status=none 2>/dev/null \
        || { log_warn "Swap 文件创建失败"; return 0; }
    chmod 600 /swapfile; mkswap /swapfile >/dev/null 2>&1
    if swapon /swapfile 2>/dev/null; then
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        log_success "Swap ${mb}MB 已启用"
    else
        log_warn "容器环境不支持 Swap，跳过"; rm -f /swapfile
    fi
}
enable_bbr() {
    touch /etc/sysctl.conf
    grep -q "net.core.default_qdisc=fq"            /etc/sysctl.conf || echo "net.core.default_qdisc=fq"            >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr"  /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr"  >> /etc/sysctl.conf
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
            curl wget unzip openssl coreutils iproute2 net-tools iptables python3 2>/dev/null || true
        (( TOTAL_DISK >= 10 )) && setup_swap 1024 \
            || { (( TOTAL_DISK >= 5 )) && setup_swap 512 || log_warn "磁盘 <5GB，跳过 Swap"; }
    else
        apk update -q 2>/dev/null
        apk add --no-cache -q bash curl wget unzip openssl coreutils iproute2 iptables ip6tables python3 2>/dev/null || true
        (( TOTAL_DISK >= 3 )) && setup_swap 256 || log_warn "磁盘 <3GB，跳过 Swap"
    fi
    enable_bbr
    mkdir -p "$DATA_DIR" "$BACKUP_DIR" "$XRAY_LOG_DIR" "$XRAY_ETC"
    touch "$NODE_DB" "$RELAY_DB"
    chmod 600 "$NODE_DB" "$RELAY_DB"
    ensure_python
    log_success "系统初始化完成"
}

# ==============================================================
# Xray 安装
# ==============================================================
install_xray() {
    if [[ -x "$XRAY_BIN" ]]; then
        log_info "Xray 已安装：$("$XRAY_BIN" version 2>&1 | head -1)"
        _ensure_xray_service; return 0
    fi
    log_step "安装 Xray-core..."
    [[ "$OS_TYPE" == "ubuntu" ]] && _install_xray_ubuntu || _install_xray_alpine
    _ensure_xray_service
}

_install_xray_ubuntu() {
    local url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
    check_github || url="https://ghp.ci/$url"
    bash -c "$(curl -fsSL "$url")" @ install
    [[ -x "$XRAY_BIN" ]] || { log_error "Xray 安装失败"; exit 1; }
    log_success "Xray 安装完成"
}

_install_xray_alpine() {
    local tag arch asset url tmp
    tag=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)
    [[ -z "$tag" ]] && { tag="v1.8.4"; log_warn "版本获取失败，使用 $tag"; }
    case "$(uname -m)" in
        x86_64)        arch="64"        ;;
        aarch64|arm64) arch="arm64-v8a" ;;
        armv7l)        arch="arm32-v7a" ;;
        *) log_error "不支持的架构：$(uname -m)"; exit 1 ;;
    esac
    asset="Xray-linux-${arch}.zip"
    url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${asset}"
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    gh_download "$url" "$tmp/$asset"
    unzip -q -o "$tmp/$asset" -d "$tmp/xray"
    install -m 755 "$tmp/xray/xray" "$XRAY_BIN"
    mkdir -p /usr/local/share/xray
    cp "$tmp/xray/"*.dat /usr/local/share/xray/ 2>/dev/null || true
    [[ -x "$XRAY_BIN" ]] || { log_error "Xray 安装失败"; exit 1; }
    log_success "Xray $tag 安装完成"
}

# 强制写入最新服务文件（每次都覆盖，确保路径正确）
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
        # 删除官方安装脚本留下的 drop-in 覆盖（会影响 ExecStart 路径）
        local dropin_dir="/etc/systemd/system/xray.service.d"
        if [[ -d "$dropin_dir" ]]; then
            log_warn "检测到 xray.service.d drop-in 目录，正在移除（避免路径冲突）..."
            rm -rf "$dropin_dir"
        fi
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
# 修复日志目录权限
# ==============================================================
fix_log_perms() {
    mkdir -p "$XRAY_LOG_DIR"
    chown -R root:root "$XRAY_LOG_DIR" 2>/dev/null || true
    chmod 755 "$XRAY_LOG_DIR"
    touch "$XRAY_LOG_DIR/access.log" "$XRAY_LOG_DIR/error.log" 2>/dev/null || true
    chmod 644 "$XRAY_LOG_DIR/access.log" "$XRAY_LOG_DIR/error.log" 2>/dev/null || true
}

# ==============================================================
# 核心：Python 生成 Xray config.json
#
# 逻辑：
#   1. 读取 NODE_DB → 生成 inbounds（本机 VLESS 入站节点）
#   2. 读取 RELAY_DB → 找 active=1 的那条落地信息
#   3. 若有激活落地：
#      - 生成 outbound "relay-out"（vless 协议，指向 IIJ）
#      - routing: 所有入站流量 → relay-out
#   4. 若无激活落地（直连模式）：
#      - routing: 所有入站流量 → freedom（直接出网）
# ==============================================================
regen_xray_config() {
    log_step "重新生成 Xray 主配置..."
    mkdir -p "$XRAY_ETC"
    fix_log_perms
    ensure_python

    local cfg
    cfg=$($PYTHON - "$NODE_DB" "$RELAY_DB" "$XRAY_LOG_DIR" <<'PYEOF'
import sys, json, os

node_db   = sys.argv[1]
relay_db  = sys.argv[2]
log_dir   = sys.argv[3]

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

# ── inbounds: 本机 VLESS 入站节点 ────────────────────────────
inbounds = []
for line in read_db(node_db):
    p = line.split('|')
    if len(p) < 7:
        continue
    uuid, port, sni, short_id, priv, name, fp = [x.strip() for x in p[:7]]
    if not uuid or not port.isdigit():
        continue
    fp = fp or 'chrome'
    tag = "in-{}-{}".format(port, uuid[:8])
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
                "privateKey": priv,
                "shortIds": [short_id]
            }
        },
        "sniffing": {"enabled": True, "destOverride": ["http","tls","quic"]}
    })

# ── relay: 读取激活的落地配置 ─────────────────────────────────
active_relay = None
for line in read_db(relay_db):
    p = line.split('|')
    if len(p) < 9:
        continue
    label, ip, port, uuid, pubkey, shortid, sni, fp, active = [x.strip() for x in p[:9]]
    if active == '1':
        active_relay = {
            "label":   label,
            "ip":      ip,
            "port":    int(port),
            "uuid":    uuid,
            "pubkey":  pubkey,
            "shortid": shortid,
            "sni":     sni,
            "fp":      fp or 'chrome'
        }
        break  # 只取第一条激活

# ── outbounds ─────────────────────────────────────────────────
outbounds = [
    {"protocol": "freedom",   "tag": "direct",  "settings": {}},
    {"protocol": "blackhole", "tag": "block",   "settings": {}}
]

relay_ob_tag = None
if active_relay:
    relay_ob_tag = "relay-out"
    # IIJ 的 IP 若是 IPv6 需要加中括号
    iij_addr = active_relay["ip"]
    if ':' in iij_addr and not iij_addr.startswith('['):
        iij_addr = "[{}]".format(iij_addr)
    outbounds.insert(0, {
        "tag":      relay_ob_tag,
        "protocol": "vless",
        "settings": {
            "vnext": [{
                "address": active_relay["ip"],
                "port":    active_relay["port"],
                "users": [{
                    "id":         active_relay["uuid"],
                    "flow":       "xtls-rprx-vision",
                    "encryption": "none"
                }]
            }]
        },
        "streamSettings": {
            "network":  "tcp",
            "security": "reality",
            "realitySettings": {
                "fingerprint": active_relay["fp"],
                "serverName":  active_relay["sni"],
                "publicKey":   active_relay["pubkey"],
                "shortId":     active_relay["shortid"]
            }
        }
    })

# ── routing ──────────────────────────────────────────────────
rules = [
    {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}
]
if relay_ob_tag:
    # 中转模式：所有非BT流量走 relay-out
    rules.append({
        "type":        "field",
        "network":     "tcp,udp",
        "outboundTag": relay_ob_tag
    })
# 直连模式：没有额外规则，默认走 direct（由 defaultOutboundTag 控制）

config = {
    "log": {
        "loglevel": "warning",
        "access":   "{}/access.log".format(log_dir),
        "error":    "{}/error.log".format(log_dir)
    },
    "inbounds":  inbounds,
    "outbounds": outbounds,
    "routing": {
        "domainStrategy":    "IPIfNonMatch",
        "defaultOutboundTag": relay_ob_tag if relay_ob_tag else "direct",
        "rules":             rules
    }
}

# 模式注释输出到 stderr，方便调试
mode = "中转模式 → {}:{}".format(active_relay["ip"], active_relay["port"]) if active_relay else "直连模式"
print("[MODE] {}".format(mode), file=sys.stderr)

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
        log_error "生成的配置文件:"
        cat "$XRAY_MAIN_CONFIG"
        return 1
    fi
    log_success "Xray 配置验证通过"
}

# ==============================================================
# 服务控制
# ==============================================================
svc_do() {
    local svc="$1" act="$2"
    [[ "$SVC_MGR" == "systemd" ]] \
        && systemctl "$act" "$svc" 2>/dev/null || true \
        || /etc/init.d/"$svc" "$act" 2>/dev/null || true
}

xray_is_active() {
    [[ "$SVC_MGR" == "systemd" ]] \
        && systemctl is-active --quiet xray 2>/dev/null \
        || /etc/init.d/xray status 2>/dev/null | grep -q "started"
}

enable_and_start_xray() {
    _ensure_xray_service
    fix_log_perms
    if [[ "$SVC_MGR" == "systemd" ]]; then
        systemctl daemon-reload
        systemctl enable xray >/dev/null 2>&1 || true
        systemctl restart xray
        sleep 2
        if systemctl is-active --quiet xray; then
            log_success "Xray 服务运行中"
        else
            log_error "Xray 启动失败，错误日志："
            journalctl -u xray -n 40 --no-pager 2>/dev/null || true
        fi
    else
        rc-update add xray default >/dev/null 2>&1 || true
        /etc/init.d/xray restart; sleep 2
        /etc/init.d/xray status 2>/dev/null | grep -q "started" \
            && log_success "Xray 服务运行中" \
            || { log_error "Xray 启动失败:"; tail -n 30 "$XRAY_LOG_DIR/error.log" 2>/dev/null || true; }
    fi
}

# ==============================================================
# 工具
# ==============================================================
urlencode() {
    local str="$1" enc="" pos c
    for (( pos=0; pos<${#str}; pos++ )); do
        c="${str:$pos:1}"
        case "$c" in [-_.~a-zA-Z0-9]) enc+="$c" ;;
            *) printf -v c '%%%02X' "'$c"; enc+="$c" ;;
        esac
    done
    echo "$enc"
}

make_vless_uri() {
    local uuid="$1" ip="$2" port="$3" sni="$4" pbk="$5" sid="$6" name="$7" fp="$8" is_v6="${9:-0}"
    local enc_name host
    enc_name=$(urlencode "$name")
    host="$ip"; [[ "$is_v6" == "1" ]] && host="[${ip}]"
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
    cmd_exists firewall-cmd && {
        firewall-cmd --permanent --add-port="$port"/tcp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    }
}

# ==============================================================
# ══ 本机 VLESS 节点管理 ════════════════════════════════════════
# ==============================================================

add_vless_node() {
    log_title "添加本机 VLESS+Reality 节点"
    if [[ ! -x "$XRAY_BIN" ]]; then
        log_warn "Xray 未安装，自动安装..."
        system_init; install_xray
    fi

    local name; read -rp "节点名称 [回车=自动]: " name
    [[ -z "$name" ]] && name="VLESS-$(date +%Y%m%d-%H%M%S)"

    local port
    while true; do
        read -rp "监听端口 [回车=443]: " port
        [[ -z "$port" ]] && port=443
        [[ "$port" =~ ^[0-9]+$ ]] && (( port>=1 && port<=65535 )) && break
        log_error "端口无效"
    done

    local sni; read -rp "SNI 伪装域名 [回车=www.cloudflare.com]: " sni
    [[ -z "$sni" ]] && sni="www.cloudflare.com"

    echo "可用指纹: chrome  firefox  safari  ios  android  edge"
    local fp; read -rp "Fingerprint [回车=chrome]: " fp
    [[ -z "$fp" ]] && fp="chrome"

    log_step "生成 X25519 密钥对..."
    local key_out; key_out=$("$XRAY_BIN" x25519 2>&1)
    parse_xray_keys "$key_out"
    local priv="$PARSED_PRIVATE" pub="$PARSED_PUBLIC"
    local uuid; uuid=$(gen_uuid)
    local sid;  sid=$(openssl rand -hex 8)

    log_info "UUID:       $uuid"
    log_info "Public Key: $pub"
    log_info "Short ID:   $sid"

    echo "${uuid}|${port}|${sni}|${sid}|${priv}|${name}|${fp}" >> "$NODE_DB"
    _allow_port "$port"

    if ! regen_xray_config; then
        log_error "配置生成失败，已回滚"
        local tmp; tmp=$(mktemp)
        grep -v "^${uuid}|" "$NODE_DB" > "$tmp" || true
        cat "$tmp" > "$NODE_DB"; rm -f "$tmp"
        return 1
    fi

    enable_and_start_xray
    echo ""
    log_success "节点 '$name' 添加成功！"
    _show_node_detail "$uuid" "$port" "$sni" "$sid" "$priv" "$pub" "$name" "$fp"
}

_show_node_detail() {
    local uuid="$1" port="$2" sni="$3" sid="$4" priv="$5" pub="$6" name="$7" fp="${8:-chrome}"
    local ipv4 ipv6; ipv4=$(get_ipv4); ipv6=$(get_ipv6)

    echo ""
    echo -e "${CYAN}════════ 本机节点：$name ════════${NC}"
    echo "UUID:        $uuid"
    echo "Private Key: $priv"
    echo "Public Key:  $pub"
    echo "Short ID:    $sid"
    echo "SNI:         $sni"
    echo "Port:        $port"
    echo "Fingerprint: $fp"
    [[ -n "$ipv4" ]] && echo "本机 IPv4:   $ipv4"
    [[ -n "$ipv6" ]] && echo "本机 IPv6:   $ipv6"
    echo ""
    if [[ -n "$ipv4" ]]; then
        local uri; uri=$(make_vless_uri "$uuid" "$ipv4" "$port" "$sni" "$pub" "$sid" "$name" "$fp" "0")
        echo -e "${GREEN}━━ VLESS URI (IPv4) ━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}${uri}${NC}"
        echo ""
    fi
    if [[ -n "$ipv6" ]]; then
        local uri6; uri6=$(make_vless_uri "$uuid" "$ipv6" "$port" "$sni" "$pub" "$sid" "${name}-v6" "$fp" "1")
        echo -e "${GREEN}━━ VLESS URI (IPv6) ━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}${uri6}${NC}"
        echo ""
    fi
    local server="${ipv4:-$ipv6}"
    echo -e "${GREEN}━━ Clash Meta ━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
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
      public-key: $pub
      short-id: $sid
    client-fingerprint: $fp
EOF
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
}

list_vless_nodes() {
    echo ""
    echo -e "${CYAN}── 本机 VLESS 节点列表 ─────────────────────${NC}"
    if [[ ! -s "$NODE_DB" ]]; then echo "  (无节点)"; return 0; fi
    local idx=0
    while IFS='|' read -r uuid port sni sid priv name fp || [[ -n "$uuid" ]]; do
        [[ -z "$uuid" || "${uuid:0:1}" == "#" ]] && continue
        idx=$(( idx+1 ))
        echo "  [$idx] $name  端口:$port  SNI:$sni  UUID:${uuid:0:8}..."
    done < "$NODE_DB"
    [[ $idx -eq 0 ]] && echo "  (无节点)"
    return 0
}

_pick_node() {
    list_vless_nodes
    [[ ! -s "$NODE_DB" ]] && return 1
    local n; read -rp "请输入序号: " n; n="${n// /}"
    [[ ! "$n" =~ ^[0-9]+$ ]] && { log_error "序号无效"; return 1; }
    PICKED_NODE_LINE=$(awk -F'|' '!/^#/ && NF>=7' "$NODE_DB" | awk -v n="$n" 'NR==n')
    [[ -z "$PICKED_NODE_LINE" ]] && { log_error "序号不存在"; return 1; }
    return 0
}

show_vless_node() {
    log_title "查看本机节点信息"
    _pick_node || return
    IFS='|' read -r uuid port sni sid priv name fp <<< "$PICKED_NODE_LINE"
    local pub; pub=$(derive_public_key "$priv")
    _show_node_detail "$uuid" "$port" "$sni" "$sid" "$priv" "$pub" "$name" "$fp"
}

show_all_vless_nodes() {
    log_title "所有本机节点信息"
    [[ ! -s "$NODE_DB" ]] && { echo "  (无节点)"; return; }
    while IFS='|' read -r uuid port sni sid priv name fp || [[ -n "$uuid" ]]; do
        [[ -z "$uuid" || "${uuid:0:1}" == "#" ]] && continue
        local pub; pub=$(derive_public_key "$priv")
        _show_node_detail "$uuid" "$port" "$sni" "$sid" "$priv" "$pub" "$name" "${fp:-chrome}"
    done < "$NODE_DB"
}

export_vless_nodes() {
    log_title "导出本机节点连接信息"
    local outfile="$BACKUP_DIR/vless_export_$(date +%Y%m%d_%H%M%S).txt"
    mkdir -p "$BACKUP_DIR"
    local ipv4 ipv6; ipv4=$(get_ipv4); ipv6=$(get_ipv6)
    {
        echo "# VPS Manager ${SCRIPT_VERSION} - 节点导出  $(date)"
        echo "# IPv4: ${ipv4:-N/A}  IPv6: ${ipv6:-N/A}"
        echo ""
        if [[ -s "$NODE_DB" ]]; then
            while IFS='|' read -r uuid port sni sid priv name fp || [[ -n "$uuid" ]]; do
                [[ -z "$uuid" || "${uuid:0:1}" == "#" ]] && continue
                local pub; pub=$(derive_public_key "$priv")
                echo "## $name"
                [[ -n "$ipv4" ]] && make_vless_uri "$uuid" "$ipv4" "$port" "$sni" "$pub" "$sid" "$name"       "$fp" "0"
                [[ -n "$ipv6" ]] && make_vless_uri "$uuid" "$ipv6" "$port" "$sni" "$pub" "$sid" "${name}-v6"  "$fp" "1"
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
    log_title "删除本机 VLESS 节点"
    _pick_node || return
    IFS='|' read -r uuid port sni sid priv name fp <<< "$PICKED_NODE_LINE"
    read -rp "确认删除节点 '$name'? [y/N]: " c
    [[ "${c:-N}" != "y" ]] && { log_info "已取消"; return; }
    local tmp; tmp=$(mktemp)
    grep -v "^${uuid}|" "$NODE_DB" > "$tmp" || true
    cat "$tmp" > "$NODE_DB"; rm -f "$tmp"
    regen_xray_config && enable_and_start_xray
    log_success "节点 '$name' 已删除"
}

test_vless_node() {
    log_title "检测本机 VLESS 节点"
    _pick_node || return
    IFS='|' read -r uuid port sni sid priv name fp <<< "$PICKED_NODE_LINE"
    echo ""

    log_step "1. 检查 Xray 服务状态..."
    if xray_is_active; then
        log_success "Xray 运行中"
    else
        log_error "Xray 未运行，尝试自动启动..."
        enable_and_start_xray
        xray_is_active && log_success "Xray 已启动" || log_error "Xray 仍无法启动，请查看菜单 → Xray服务管理 → 查看日志"
    fi

    log_step "2. 验证配置文件..."
    local tout
    if tout=$("$XRAY_BIN" run -test -config "$XRAY_MAIN_CONFIG" 2>&1); then
        log_success "配置文件验证通过"
    else
        log_error "配置文件验证失败:"; echo "$tout" | head -10
    fi

    log_step "3. 检查端口 $port 监听..."
    if ss -tlnp 2>/dev/null | grep -q ":${port}[[:space:]]"; then
        log_success "端口 $port 正在监听"
    else
        log_warn "端口 $port 未检测到监听（若 Xray 运行中，可能是容器网络特性）"
    fi

    log_step "4. 测试 SNI 目标可达性 ($sni)..."
    local hc; hc=$(curl -sI --max-time 5 "https://${sni}" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "0")
    [[ "$hc" =~ ^[23] ]] && log_success "SNI $sni 可达 (HTTP $hc)" || log_warn "SNI $sni 返回 $hc，建议更换伪装域名"

    log_step "5. 当前路由模式..."
    local active_label; active_label=$(awk -F'|' '!/^#/ && $9=="1" {print $1; exit}' "$RELAY_DB" 2>/dev/null || echo "")
    if [[ -n "$active_label" ]]; then
        local active_ip; active_ip=$(awk -F'|' '!/^#/ && $9=="1" {print $2":"$3; exit}' "$RELAY_DB" 2>/dev/null || echo "")
        echo -e "  ${YELLOW}中转模式${NC} → 落地: $active_label ($active_ip)"
        echo "  客户端流量: RFC:$port → IIJ:$active_ip"
    else
        echo -e "  ${GREEN}直连模式${NC} → 流量从本机直接出网"
    fi

    echo ""; log_success "检测完成 - 节点: $name"
}

# ==============================================================
# ══ Xray 服务管理 ══════════════════════════════════════════════
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
        echo "  7) 强制修复并重启（重写服务文件+修复权限+重启）"
        echo "  0) 返回"
        read -rp "请选择: " c
        case "${c:-}" in
            1) _show_xray_status ;;
            2) enable_and_start_xray ;;
            3) svc_do xray stop; log_info "Xray 已停止" ;;
            4) enable_and_start_xray ;;
            5) _xray_log 50 ;;
            6) echo "按 Ctrl+C 退出..."
               [[ "$SVC_MGR" == "systemd" ]] \
                   && journalctl -u xray -f 2>/dev/null \
                   || tail -f "$XRAY_LOG_DIR/error.log" 2>/dev/null || true ;;
            7) _ensure_xray_service; fix_log_perms; regen_xray_config; enable_and_start_xray ;;
            0) break ;;
            *) log_warn "无效选项" ;;
        esac
    done
}

_show_xray_status() {
    echo ""
    echo -e "${CYAN}── Xray 状态 ──────────────────────────────${NC}"
    [[ -x "$XRAY_BIN" ]] && echo "版本: $("$XRAY_BIN" version 2>&1 | head -1)" || echo "Xray: 未安装"
    echo "配置: $XRAY_MAIN_CONFIG $([[ -f "$XRAY_MAIN_CONFIG" ]] && echo '(存在)' || echo '(缺失)')"
    local dropin_dir="/etc/systemd/system/xray.service.d"
    [[ -d "$dropin_dir" ]] && echo -e "${YELLOW}警告: 存在 drop-in 目录 $dropin_dir，可能影响启动，建议选 7 强制修复${NC}"
    echo ""
    [[ "$SVC_MGR" == "systemd" ]] \
        && systemctl --no-pager status xray 2>/dev/null || echo "（服务未安装）" \
        || /etc/init.d/xray status 2>/dev/null || echo "（服务未安装）"
    echo ""
    echo "当前路由模式:"
    local al; al=$(awk -F'|' '!/^#/ && $9=="1" {print $1; exit}' "$RELAY_DB" 2>/dev/null || echo "")
    if [[ -n "$al" ]]; then
        local ai; ai=$(awk -F'|' '!/^#/ && $9=="1" {print $2":"$3; exit}' "$RELAY_DB" 2>/dev/null || echo "")
        echo -e "  ${YELLOW}中转模式${NC} → $al ($ai)"
    else
        echo -e "  ${GREEN}直连模式${NC}"
    fi
    echo ""
    echo "端口监听:"; ss -tlnp 2>/dev/null | awk 'NR==1 || /xray/' || echo "（无）"
}

_xray_log() {
    local n="${1:-50}"
    [[ "$SVC_MGR" == "systemd" ]] \
        && journalctl -u xray -n "$n" --no-pager 2>/dev/null \
        || tail -n "$n" "$XRAY_LOG_DIR/error.log" 2>/dev/null \
        || log_warn "日志不可读"
}

# ==============================================================
# ══ 落地中转管理（Xray 链式代理）══════════════════════════════
#
# relay.db 每行:
#   label|iij_ip|iij_port|iij_uuid|iij_pubkey|iij_shortid|iij_sni|iij_fp|active
#
# active=1: 当前激活的落地，Xray outbound 指向此节点
# active=0: 备用落地，不生效
# 全部 active=0: 直连模式，流量从本机直接出网
# ==============================================================

_show_relay_mode() {
    local al; al=$(awk -F'|' '!/^#/ && $9=="1" {print $1; exit}' "$RELAY_DB" 2>/dev/null || echo "")
    if [[ -n "$al" ]]; then
        local ai; ai=$(awk -F'|' '!/^#/ && $9=="1" {print $2":"$3; exit}' "$RELAY_DB" 2>/dev/null || echo "")
        echo -e "  当前模式: ${YELLOW}中转${NC} → $al ($ai)"
    else
        echo -e "  当前模式: ${GREEN}直连${NC}（流量从本机直接出网）"
    fi
}

list_relay_entries() {
    echo ""
    echo -e "${CYAN}── 落地节点列表 ────────────────────────────${NC}"
    _show_relay_mode
    echo ""
    if [[ ! -s "$RELAY_DB" ]]; then echo "  (无落地节点)"; return 0; fi
    local idx=0
    while IFS='|' read -r label ip port uuid pubkey shortid sni fp active || [[ -n "$label" ]]; do
        [[ -z "$label" || "${label:0:1}" == "#" ]] && continue
        idx=$(( idx+1 ))
        local mark="      "
        [[ "${active:-0}" == "1" ]] && mark="${GREEN}[激活]${NC}"
        echo -e "  [$idx] ${mark} $label  ${ip}:${port}  SNI:$sni"
    done < "$RELAY_DB"
    [[ $idx -eq 0 ]] && echo "  (无落地节点)"
    echo ""
    return 0
}

add_relay_entry() {
    log_title "添加落地节点（IIJ 端的 VLESS 信息）"
    echo ""
    echo "请输入 IIJ(落地VPS) 上的 VLESS+Reality 节点信息："
    echo "（这些信息在 IIJ 上运行本脚本 → 查看节点信息 中可以找到）"
    echo ""

    local label; read -rp "备注名称 [如: IIJ-Tokyo]: " label
    [[ -z "$label" ]] && label="relay-$(date +%s)"

    local ip; read -rp "IIJ 的 IP 地址: " ip
    ip="${ip// /}"; [[ -z "$ip" ]] && { log_error "IP 不能为空"; return 1; }

    local port
    while true; do
        read -rp "IIJ 的 VLESS 端口 [回车=443]: " port
        [[ -z "$port" ]] && port=443
        [[ "$port" =~ ^[0-9]+$ ]] && (( port>=1 && port<=65535 )) && break
        log_error "端口无效"
    done

    local uuid; read -rp "IIJ 节点的 UUID: " uuid
    uuid="${uuid// /}"; [[ -z "$uuid" ]] && { log_error "UUID 不能为空"; return 1; }

    local pubkey; read -rp "IIJ 节点的 Public Key: " pubkey
    pubkey="${pubkey// /}"; [[ -z "$pubkey" ]] && { log_error "Public Key 不能为空"; return 1; }

    local shortid; read -rp "IIJ 节点的 Short ID: " shortid
    shortid="${shortid// /}"; [[ -z "$shortid" ]] && { log_error "Short ID 不能为空"; return 1; }

    local sni; read -rp "IIJ 节点的 SNI [如: ascii.jp]: " sni
    sni="${sni// /}"; [[ -z "$sni" ]] && sni="www.cloudflare.com"

    echo "可用指纹: chrome  firefox  safari  ios  android  edge"
    local fp; read -rp "Fingerprint [回车=chrome]: " fp
    [[ -z "$fp" ]] && fp="chrome"

    # 测试连通性
    log_step "测试到 IIJ (${ip}:${port}) 的 TCP 连通性..."
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${ip}/${port}" >/dev/null 2>&1; then
        log_success "TCP 连通正常"
    else
        log_warn "TCP 连通失败，请检查 IIJ 的防火墙或节点是否运行"
        read -rp "仍要继续添加? [y/N]: " cc
        [[ "${cc:-N}" != "y" ]] && return 0
    fi

    # 第一条自动激活，否则询问
    local active=0
    if [[ ! -s "$RELAY_DB" ]]; then
        active=1; log_info "首条落地，自动激活（切换为中转模式）"
    else
        read -rp "立即激活此落地（切换为中转模式）? [y/N]: " act
        [[ "${act:-N}" == "y" ]] && active=1
        [[ $active -eq 1 ]] && _deactivate_all_relay
    fi

    echo "${label}|${ip}|${port}|${uuid}|${pubkey}|${shortid}|${sni}|${fp}|${active}" >> "$RELAY_DB"

    regen_xray_config && enable_and_start_xray

    if [[ $active -eq 1 ]]; then
        log_success "已添加并激活: $label → ${ip}:${port}"
        echo ""
        echo -e "${YELLOW}━━ 中转已生效 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo "客户端连接: 本机节点（不变）"
        echo "流量路径:   客户端 → RFC:$(awk -F'|' '!/^#/ && NF>=7 {print $2; exit}' "$NODE_DB" 2>/dev/null || echo '443') → IIJ:${ip}:${port} → 目标网站"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        log_success "已添加（未激活）: $label → ${ip}:${port}"
    fi
    list_relay_entries
}

_deactivate_all_relay() {
    [[ ! -s "$RELAY_DB" ]] && return
    local tmp; tmp=$(mktemp)
    awk -F'|' 'BEGIN{OFS="|"} /^#/{print;next} NF>=9{$9=0; print}' "$RELAY_DB" > "$tmp"
    cat "$tmp" > "$RELAY_DB"; rm -f "$tmp"
}

# 切换模式：激活某个落地 = 中转模式；取消所有 = 直连模式
switch_relay() {
    log_title "切换路由模式"
    list_relay_entries
    echo ""
    echo "操作选项:"
    echo "  输入序号  → 激活该落地节点（切换为中转模式）"
    echo "  输入 0   → 取消所有激活（切换为直连模式）"
    echo ""
    read -rp "请输入: " n; n="${n// /}"

    if [[ "$n" == "0" ]]; then
        _deactivate_all_relay
        regen_xray_config && enable_and_start_xray
        log_success "已切换为直连模式"
        _show_relay_mode
        return
    fi

    [[ ! "$n" =~ ^[0-9]+$ ]] && { log_error "序号无效"; return 1; }
    local target_line
    target_line=$(awk -F'|' '!/^#/ && NF>=9' "$RELAY_DB" | awk -v n="$n" 'NR==n')
    [[ -z "$target_line" ]] && { log_error "序号不存在"; return 1; }

    IFS='|' read -r label ip port uuid pubkey shortid sni fp active <<< "$target_line"

    local tmp; tmp=$(mktemp)
    awk -F'|' -v n="$n" 'BEGIN{OFS="|"; cnt=0}
        /^#/{print; next}
        NF>=9{cnt++; if(cnt==n) $9=1; else $9=0; print}' "$RELAY_DB" > "$tmp"
    cat "$tmp" > "$RELAY_DB"; rm -f "$tmp"

    regen_xray_config && enable_and_start_xray
    log_success "已切换为中转模式 → $label (${ip}:${port})"

    echo ""
    echo -e "${YELLOW}━━ 流量路径 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    local local_port; local_port=$(awk -F'|' '!/^#/ && NF>=7 {print $2; exit}' "$NODE_DB" 2>/dev/null || echo "443")
    echo "客户端 → RFC:${local_port} → IIJ:${ip}:${port} → 目标网站"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    list_relay_entries
}

delete_relay_entry() {
    log_title "删除落地节点"
    list_relay_entries
    [[ ! -s "$RELAY_DB" ]] && return
    local n; read -rp "请输入要删除的序号: " n; n="${n// /}"
    [[ ! "$n" =~ ^[0-9]+$ ]] && { log_error "序号无效"; return 1; }
    local tmp; tmp=$(mktemp)
    awk -F'|' '!/^#/ && NF>=9' "$RELAY_DB" | awk -v n="$n" 'NR!=n' > "$tmp"
    cat "$tmp" > "$RELAY_DB"; rm -f "$tmp"
    regen_xray_config && enable_and_start_xray
    log_success "已删除序号 $n"
    list_relay_entries
}

edit_relay_entry() {
    log_title "修改落地节点"
    list_relay_entries
    [[ ! -s "$RELAY_DB" ]] && return
    local n; read -rp "请输入要修改的序号: " n; n="${n// /}"
    [[ ! "$n" =~ ^[0-9]+$ ]] && { log_error "序号无效"; return 1; }
    local old_line
    old_line=$(awk -F'|' '!/^#/ && NF>=9' "$RELAY_DB" | awk -v n="$n" 'NR==n')
    [[ -z "$old_line" ]] && { log_error "序号不存在"; return 1; }

    IFS='|' read -r ol oi op ou opk osi os of oa <<< "$old_line"
    echo "当前: $ol | ${oi}:${op} | SNI:$os"

    local nl ni np nu npk nsi ns nf
    read -rp "备注名称     [回车保持 $ol]: " nl;  [[ -z "$nl"  ]] && nl="$ol"
    read -rp "IIJ IP       [回车保持 $oi]: " ni;  [[ -z "$ni"  ]] && ni="$oi"
    read -rp "IIJ 端口     [回车保持 $op]: " np;  [[ -z "$np"  ]] && np="$op"
    read -rp "UUID         [回车保持 $ou]: " nu;  [[ -z "$nu"  ]] && nu="$ou"
    read -rp "Public Key   [回车保持 $opk]: " npk; [[ -z "$npk" ]] && npk="$opk"
    read -rp "Short ID     [回车保持 $osi]: " nsi; [[ -z "$nsi" ]] && nsi="$osi"
    read -rp "SNI          [回车保持 $os]: " ns;  [[ -z "$ns"  ]] && ns="$os"
    read -rp "Fingerprint  [回车保持 $of]: " nf;  [[ -z "$nf"  ]] && nf="$of"

    local tmp; tmp=$(mktemp)
    awk -F'|' -v n="$n" \
        -v a1="$nl" -v a2="$ni" -v a3="$np" -v a4="$nu" \
        -v a5="$npk" -v a6="$nsi" -v a7="$ns" -v a8="$nf" \
        'BEGIN{OFS="|"; cnt=0}
         /^#/{print; next}
         NF>=9{cnt++; if(cnt==n){$1=a1;$2=a2;$3=a3;$4=a4;$5=a5;$6=a6;$7=a7;$8=a8} print}' \
        "$RELAY_DB" > "$tmp"
    cat "$tmp" > "$RELAY_DB"; rm -f "$tmp"

    regen_xray_config && enable_and_start_xray
    log_success "已修改"
    list_relay_entries
}

test_relay() {
    log_title "落地链路检测"
    [[ ! -s "$RELAY_DB" ]] && { echo "  无落地节点"; return; }

    while IFS='|' read -r label ip port uuid pubkey shortid sni fp active || [[ -n "$label" ]]; do
        [[ -z "$label" || "${label:0:1}" == "#" ]] && continue
        local mark=""; [[ "${active:-0}" == "1" ]] && mark="${GREEN}[激活]${NC}"
        echo ""
        echo -e "── $label $mark  ${ip}:${port}  SNI:$sni"

        # TCP 连通
        if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${ip}/${port}" >/dev/null 2>&1; then
            log_success "  TCP 连通: ${ip}:${port} OK"
        else
            log_error   "  TCP 连通: ${ip}:${port} FAIL"
        fi

        # SNI 测试
        local hc; hc=$(curl -sI --max-time 5 "https://${sni}" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "0")
        [[ "$hc" =~ ^[23] ]] && log_success "  SNI $sni 可达 (HTTP $hc)" || log_warn "  SNI $sni 返回 $hc"
    done < "$RELAY_DB"
    echo ""
}

relay_menu() {
    while true; do
        log_title "中转落地管理"
        _show_relay_mode
        echo ""
        echo "  1) 添加落地节点（填入 IIJ 的 VLESS 信息）"
        echo "  2) 查看所有落地节点"
        echo "  3) 切换模式（激活落地=中转 / 取消=直连）"
        echo "  4) 修改落地节点信息"
        echo "  5) 删除落地节点"
        echo "  6) 落地链路检测"
        echo "  0) 返回主菜单"
        read -rp "请选择: " c
        case "${c:-}" in
            1) add_relay_entry  ;;
            2) list_relay_entries ;;
            3) switch_relay ;;
            4) edit_relay_entry ;;
            5) delete_relay_entry ;;
            6) test_relay ;;
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
    local ipv4 ipv6; ipv4=$(get_ipv4); ipv6=$(get_ipv6)

    echo "━━ 服务器 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "OS:   $OS_TYPE | 内核: $(uname -r)"
    echo "内存: ${TOTAL_MEM}MB  磁盘: ${TOTAL_DISK}GB"
    echo "IPv4: ${ipv4:-N/A}"
    echo "IPv6: ${ipv6:-N/A}"
    echo ""
    echo "━━ Xray ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ -x "$XRAY_BIN" ]]; then
        echo "版本: $("$XRAY_BIN" version 2>&1 | head -1)"
        xray_is_active && echo -e "服务: ${GREEN}运行中${NC}" || echo -e "服务: ${RED}已停止${NC}"
    else
        echo -e "${RED}Xray 未安装${NC}"
    fi
    echo ""
    echo "━━ 路由模式 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    _show_relay_mode
    echo ""
    echo "━━ 本机 VLESS 节点 ━━━━━━━━━━━━━━━━━━━━━━"
    list_vless_nodes
    echo ""
    echo "━━ 落地节点 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    list_relay_entries
    echo ""
    echo "━━ 端口监听 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ss -tlnp 2>/dev/null | awk 'NR==1 || /LISTEN/' | head -15 || echo "  无法获取"
    echo ""
}

# ==============================================================
# ══ 一键初始化 ═════════════════════════════════════════════════
# ==============================================================
full_install() {
    log_title "一键初始化（安装 Xray）"
    system_init
    install_xray
    log_success "Xray 安装完成！请通过菜单添加本机节点，再根据需要配置中转落地。"
}

# ==============================================================
# ══ 主菜单 ═════════════════════════════════════════════════════
# ==============================================================
main_menu() {
    need_root
    detect_os
    ensure_python
    mkdir -p "$DATA_DIR" "$BACKUP_DIR" "$XRAY_LOG_DIR" "$XRAY_ETC"
    touch "$NODE_DB" "$RELAY_DB" 2>/dev/null || true

    while true; do
        echo ""
        echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║  VPS 一键管理 ${SCRIPT_VERSION}                       ║${NC}"
        echo -e "${BLUE}║  Xray VLESS+Reality+Vision  直连/链式中转     ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
        echo ""
        # 显示当前模式
        _show_relay_mode
        echo ""
        echo -e "${CYAN}── 本机 VLESS 节点 ─────────────────────────────${NC}"
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
        echo -e "${CYAN}── 中转落地管理 ────────────────────────────────${NC}"
        echo "   8) 中转落地管理（添加/切换/检测落地节点）"
        echo ""
        echo -e "${CYAN}── 系统 ────────────────────────────────────────${NC}"
        echo "   9) 系统总览"
        echo "  10) 一键初始化安装"
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
            8)  relay_menu ;;
            9)  show_overview ;;
            10) full_install ;;
            0)  log_info "退出。"; exit 0 ;;
            *)  log_warn "无效选项" ;;
        esac
    done
}

# ── 入口 ──────────────────────────────────────────────────────
main_menu
