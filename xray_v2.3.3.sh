#!/usr/bin/env bash
# ==============================================================
# VPS 一键管理脚本  v2.3.3 (终极大师版 - 补完版)
# 功能: Xray VLESS+Reality+Vision  本地直连 + 链式中转
# 架构: XTLS 官方内部 dokodemo-door 终极防偷流量 + 极客级健壮性
#
# 更新日志 v2.3.3:
#   1. 补完: 新增 edit_relay / delete_relay，中转落地支持完整增删改查
#   2. 修复: BBR 开启前先 modprobe tcp_bbr 并检测内核是否支持，避免静默失败
#   3. 统一: 落地序号计数逻辑对齐列表显示 (非空且非#开头行)
#   4. 继承: v2.3.2 全部特性 (全局端口避让、分隔符过滤、端口重复预检等)
# ==============================================================

SCRIPT_VERSION="v2.3.3"

# ── 颜色与日志 ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_success() { echo -e "${CYAN}[OK]${NC}    $*"; }
log_step()    { echo -e "${BLUE}[STEP]${NC}  $*"; }
log_title()   {
    echo -e "\n${MAGENTA}══════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}  $*${NC}"
    echo -e "${MAGENTA}══════════════════════════════════════════════${NC}\n"
}

# ── 全局变量 ──────────────────────────────────────────────────
XRAY_BIN="/usr/local/bin/xray"
XRAY_ETC="/usr/local/etc/xray"
XRAY_CONFIG="$XRAY_ETC/config.json"
XRAY_LOG_DIR="/var/log/xray"

DATA_DIR="/etc/vps_manager"
NODE_DB="$DATA_DIR/nodes.db"
RELAY_DB="$DATA_DIR/relay.db"
BACKUP_DIR="/root/vps_manager_backups"

# 内层防偷端口基数 (改用冷僻高位段)
GUARD_BASE_PORT=54321

OS_TYPE=""
PKG_MGR=""
SVC_MGR=""
TOTAL_MEM=0
TOTAL_DISK=0
PYTHON=""
PICKED_LINE=""
PICKED_RELAY_NUM=""
PICKED_RELAY_LINE=""
PARSED_PRIV=""
PARSED_PUB=""

UPGRADE_CHECKED=0

# ==============================================================
# 工具与基础函数
# ==============================================================
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

sanitize_db() {
    [ -f "$NODE_DB" ] && sed -i 's/\r//g' "$NODE_DB" 2>/dev/null || true
    [ -f "$RELAY_DB" ] && sed -i 's/\r//g' "$RELAY_DB" 2>/dev/null || true
}

# 过滤 DB 分隔符 |，防止字段错乱
sanitize_field() {
    echo "$1" | tr -d '|' | tr -d '\r' | tr -d '\n'
}

check_upgrade() {
    if [ "$UPGRADE_CHECKED" = "1" ]; then return 0; fi
    export UPGRADE_CHECKED=1

    if [ -s "$NODE_DB" ] || [ -s "$RELAY_DB" ]; then
        log_title "检测到历史节点数据"
        echo -e "${YELLOW}当前为新版防偷流量脚本(v$SCRIPT_VERSION)，请选择操作：${NC}"
        echo "  1) 保留原有节点并 平滑升级配置 (推荐)"
        echo "  2) 彻底清空旧数据并 全新安装 (危险)"
        echo "  0) 稍后决定 (返回主菜单)"
        read -rp "请选择 [1/2/0]: " ch
        case "$ch" in
            1)
                log_info "正在为您保留数据并平滑升级..."
                sanitize_db
                ensure_python
                if regen_config; then
                    start_xray
                    log_success "平滑升级完成！新架构已生效。"
                else
                    log_warn "配置重新生成失败，请在主菜单选[强制修复配置]。"
                fi
                sleep 2
                ;;
            2)
                read -rp "警告: 将删除所有历史节点和配置！确定吗？[y/N]: " confirm
                if [ "${confirm:-N}" = "y" ] || [ "${confirm:-N}" = "Y" ]; then
                    rm -rf "${DATA_DIR:?}" "${XRAY_ETC:?}"
                    mkdir -p "$DATA_DIR" "$BACKUP_DIR" "$XRAY_LOG_DIR" "$XRAY_ETC"
                    touch "$NODE_DB" "$RELAY_DB"
                    log_success "已彻底清理旧数据。"
                    sleep 1
                else
                    log_info "已取消清理"
                fi
                ;;
            *) return 0 ;;
        esac
    fi
}

detect_os() {
    if [ ! -f /etc/os-release ]; then log_error "无法识别操作系统"; exit 1; fi
    local os_id
    os_id=$(grep -E "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"' | tr -d "'" | tr '[:upper:]' '[:lower:]')
    case "$os_id" in
        ubuntu|debian) OS_TYPE="ubuntu"; PKG_MGR="apt"; SVC_MGR="systemd" ;;
        alpine)        OS_TYPE="alpine"; PKG_MGR="apk"; SVC_MGR="openrc" ;;
        *)             log_error "不支持的发行版: '${os_id}'"; exit 1 ;;
    esac
}

need_root() {
    local uid
    uid=$(id -u 2>/dev/null || echo "1")
    if [ "$uid" -ne 0 ]; then log_error "请以 root 权限运行：sudo bash $0"; exit 1; fi
}

ensure_python() {
    if cmd_exists python3; then PYTHON=python3; return 0; fi
    if cmd_exists python; then PYTHON=python; return 0; fi
    log_warn "未检测到 Python，正在安装..."
    if [ "$PKG_MGR" = "apt" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 2>/dev/null || true
    else
        apk add --no-cache -q python3 2>/dev/null || true
    fi
    if cmd_exists python3; then PYTHON=python3; else log_error "Python 安装失败"; PYTHON=""; fi
}

get_ipv4() {
    local ip url
    for url in https://api4.ipify.org https://ifconfig.me https://icanhazip.com; do
        ip=$(curl -s -4 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    done
}

get_ipv6() {
    local ip url
    for url in https://api6.ipify.org https://ifconfig.me https://icanhazip.com; do
        ip=$(curl -s -6 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    done
}

check_github() { curl -sI --max-time 6 https://api.github.com >/dev/null 2>&1; return $?; }

gh_download() {
    if check_github; then curl -fL --retry 3 --progress-bar -o "$2" "$1"
    else curl -fL --retry 3 --progress-bar -o "$2" "https://ghp.ci/$1"; fi
}

parse_xray_keys() {
    PARSED_PRIV=$(echo "$1" | grep -i "^private" | awk '{print $NF}' | tr -d ' \r\n')
    PARSED_PUB=$(echo "$1"  | grep -iE "(^public|publickey)" | awk '{print $NF}' | tr -d ' \r\n')
    if [ -z "$PARSED_PRIV" ] || [ -z "$PARSED_PUB" ]; then return 1; fi
    return 0
}

derive_pub() { "$XRAY_BIN" x25519 -i "$1" 2>&1 | grep -iE "(^public|publickey)" | awk '{print $NF}' | tr -d ' \r\n'; }

gen_uuid() {
    if cmd_exists uuidgen; then uuidgen | tr '[:upper:]' '[:lower:]'
    else od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}' | tr '[:upper:]' '[:lower:]'; fi
}

enable_bbr() {
    # 先尝试加载 tcp_bbr 内核模块 (精简版系统默认可能未挂载)
    if cmd_exists modprobe; then
        modprobe tcp_bbr 2>/dev/null || true
    fi
    # 检测内核是否真正支持 BBR，避免 sysctl -p 静默失败
    if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        log_warn "当前内核不支持 BBR，跳过开启 (可用: $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo '未知'))"
        return 0
    fi
    touch /etc/sysctl.conf 2>/dev/null || true
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
    # 真实验收
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -qw bbr; then
        log_success "BBR 已成功开启"
    else
        log_warn "BBR 开启失败，当前算法: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
    fi
}

# 检查外层端口是否已被其他节点占用 (排除指定 UUID)
port_in_use() {
    local check_port="$1" exclude_uuid="${2:-}"
    if [ -z "$exclude_uuid" ]; then
        awk -F'|' -v p="$check_port" '!/^#/ && NF>=7 && $2==p {exit 0} END{exit 1}' "$NODE_DB" 2>/dev/null
    else
        awk -F'|' -v p="$check_port" -v u="$exclude_uuid" '!/^#/ && NF>=7 && $2==p && $1!=u {exit 0} END{exit 1}' "$NODE_DB" 2>/dev/null
    fi
}

# 按物理行号替换文件中的某一行 (避免 awk -v 转义问题)
replace_line_by_num() {
    local file="$1" num="$2" newline="$3"
    local tmp
    tmp=$(mktemp)
    {
        head -n $((num - 1)) "$file" 2>/dev/null
        printf '%s\n' "$newline"
        tail -n +"$((num + 1))" "$file" 2>/dev/null
    } > "$tmp" && mv "$tmp" "$file"
}

# 按物理行号删除文件中的某一行
delete_line_by_num() {
    local file="$1" num="$2"
    local tmp
    tmp=$(mktemp)
    awk -v nr="$num" 'NR!=nr' "$file" > "$tmp" && mv "$tmp" "$file"
}

# ==============================================================
# 核心组件安装
# ==============================================================
system_init() {
    log_step "系统初始化..."
    if [ "$OS_TYPE" = "ubuntu" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl wget unzip openssl coreutils iproute2 net-tools iptables python3 2>/dev/null || true
    else
        apk update -q 2>/dev/null || true
        apk add --no-cache -q bash curl wget unzip openssl coreutils iproute2 iptables ip6tables python3 2>/dev/null || true
    fi
    enable_bbr
    mkdir -p "$DATA_DIR" "$BACKUP_DIR" "$XRAY_LOG_DIR" "$XRAY_ETC" 2>/dev/null || true
    touch "$NODE_DB" "$RELAY_DB" 2>/dev/null || true
    ensure_python
    log_success "系统初始化完成"
}

install_xray() {
    if [ -x "$XRAY_BIN" ]; then write_xray_service; return 0; fi
    log_step "安装 Xray-core..."
    if [ "$OS_TYPE" = "ubuntu" ]; then
        local dl_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
        check_github || dl_url="https://ghp.ci/$dl_url"
        local script_content
        script_content=$(curl -fsSL "$dl_url" 2>/dev/null)
        if [ -z "$script_content" ]; then log_error "Xray 安装脚本下载失败"; return 1; fi
        bash -c "$script_content" -- install || return 1
    else
        local tag
        tag=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"\(v[^"]*\)".*/\1/')
        [ -z "$tag" ] && tag="v1.8.4"
        local machine
        machine=$(uname -m)
        local arch="64"
        case "$machine" in
            x86_64)        arch="64" ;;
            aarch64|arm64) arch="arm64-v8a" ;;
            armv7l)        arch="arm32-v7a" ;;
            *)             log_error "不支持的架构: $machine"; return 1 ;;
        esac
        local tmp
        tmp=$(mktemp -d)
        if ! gh_download "https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-${arch}.zip" "$tmp/xray.zip"; then
            log_error "Xray 下载失败"
            rm -rf "$tmp"
            return 1
        fi
        if ! unzip -q -o "$tmp/xray.zip" -d "$tmp/xray" 2>/dev/null; then
            log_error "Xray 解压失败"
            rm -rf "$tmp"
            return 1
        fi
        install -m 755 "$tmp/xray/xray" "$XRAY_BIN"
        mkdir -p /usr/local/share/xray
        cp "$tmp/xray/"*.dat /usr/local/share/xray/ 2>/dev/null || true
        rm -rf "$tmp"
    fi
    if [ ! -x "$XRAY_BIN" ]; then log_error "Xray 安装后未找到二进制文件"; return 1; fi
    write_xray_service
    return 0
}

write_xray_service() {
    if [ "$SVC_MGR" = "systemd" ]; then
        rm -rf "/etc/systemd/system/xray.service.d" 2>/dev/null || true
        cat > /etc/systemd/system/xray.service <<SVCEOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network-online.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SVCEOF
        systemctl daemon-reload 2>/dev/null || true
    else
        cat > /etc/init.d/xray <<ORCEOF
#!/sbin/openrc-run
name="xray"
command="${XRAY_BIN}"
command_args="run -config ${XRAY_CONFIG}"
command_background="yes"
pidfile="/run/xray.pid"
output_log="${XRAY_LOG_DIR}/access.log"
error_log="${XRAY_LOG_DIR}/error.log"
ORCEOF
        chmod +x /etc/init.d/xray
    fi
}

fix_log_perms() {
    mkdir -p "$XRAY_LOG_DIR"
    chmod 755 "$XRAY_LOG_DIR"
    touch "$XRAY_LOG_DIR/access.log" "$XRAY_LOG_DIR/error.log"
}

# ==============================================================
# 配置生成引擎 (100% 对齐官方防偷架构 + 全局端口避让)
# ==============================================================
gen_config_python() {
    "$PYTHON" - "$1" "$2" "$3" "$4" <<'PYEOF'
import sys, json

node_db = sys.argv[1]
relay_db = sys.argv[2]
log_dir = sys.argv[3]
guard_base = int(sys.argv[4])

def read_db(path):
    rows = []
    try:
        with open(path, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    rows.append(line)
    except: pass
    return rows

# ── 第一遍：解析并收集所有外层端口，用于内层避让 ──
nodes = []          # (uuid, port_int, port_str, sni, sid, priv, name, fp)
outer_ports = set()

for line in read_db(node_db):
    p = line.split('|')
    if len(p) < 7:
        continue
    uuid, port, sni, sid, priv, name, fp = [x.strip() for x in p[:7]]

    # 健壮性校验
    if not uuid or not port.isdigit():
        continue
    port_int = int(port)
    if not 1 <= port_int <= 65535:
        continue
    if not sni or not priv or not sid:
        continue

    outer_ports.add(port_int)
    nodes.append((uuid, port_int, port, sni, sid, priv, name, fp))

inbounds = []
anti_steal_rules = []
used_inner = set()

def alloc_guard_port(preferred):
    """分配一个不与任何外层端口、已用内层端口冲突的端口"""
    candidate = preferred
    tries = 0
    while tries < 1000:
        if candidate < 1 or candidate > 65535:
            candidate = 40000
        if candidate not in outer_ports and candidate not in used_inner:
            return candidate
        candidate += 1
        tries += 1
    # 极端兜底：顺序找空位
    for c in range(40000, 65536):
        if c not in outer_ports and c not in used_inner:
            return c
    return None

for idx, (uuid, port_int, port_str, sni, sid, priv, name, fp) in enumerate(nodes):
    inner_port = alloc_guard_port(guard_base + idx)
    if inner_port is None:
        # 端口耗尽时跳过该节点，避免生成无效配置
        continue
    used_inner.add(inner_port)

    outer_tag = "in-{}-{}".format(port_str, uuid[:8])
    inner_tag = "guard-{}-{}".format(port_str, uuid[:8])

    # 外层：100% 对齐官方。非法握手 fallback 至本地内层看门狗
    inbounds.append({
        "tag": outer_tag,
        "port": port_int,
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
                "dest": "127.0.0.1:{}".format(inner_port),
                "serverNames": [sni],
                "privateKey": priv,
                "shortIds": [sid]
            }
        },
        "sniffing": {
            "enabled": True,
            "destOverride": ["http", "tls", "quic"],
            "routeOnly": True
        }
    })

    # 内层：严格只监听本地，嗅探真实目标 SNI
    inbounds.append({
        "tag": inner_tag,
        "port": inner_port,
        "listen": "127.0.0.1",
        "protocol": "dokodemo-door",
        "settings": {
            "address": sni,
            "port": 443,
            "network": "tcp"
        },
        "sniffing": {
            "enabled": True,
            "destOverride": ["tls"],
            "routeOnly": True
        }
    })

    # 路由规则1：内层 + 域名合法 -> 去真实网站 (防火墙探测)
    anti_steal_rules.append({
        "type": "field",
        "inboundTag": [inner_tag],
        "domain": [sni],
        "outboundTag": "direct"
    })
    # 路由规则2：内层 + 域名非法 -> 黑洞阻断 (偷流量)
    anti_steal_rules.append({
        "type": "field",
        "inboundTag": [inner_tag],
        "outboundTag": "block"
    })

outbounds = [
    {"protocol": "freedom",   "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
]

rules = []
rules.extend(anti_steal_rules)
rules.append({"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"})

default_out = "direct"

for line in read_db(relay_db):
    p = line.split('|')
    if len(p) < 9:
        continue
    label, ip, rport, ruuid, pubkey, shortid, rsni, fp, active = [x.strip() for x in p[:9]]
    if active != '1':
        continue
    if not ip or not rport.isdigit() or not ruuid:
        continue
    rport_int = int(rport)
    if not 1 <= rport_int <= 65535:
        continue
    if not pubkey or not rsni:
        continue

    relay_tag = "relay-out"
    outbounds.insert(0, {
        "tag": relay_tag,
        "protocol": "vless",
        "settings": {
            "vnext": [{
                "address": ip,
                "port": rport_int,
                "users": [{"id": ruuid, "flow": "xtls-rprx-vision", "encryption": "none"}]
            }]
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "fingerprint": fp or 'chrome',
                "serverName": rsni,
                "publicKey": pubkey,
                "shortId": shortid
            }
        }
    })
    # 中转规则：在防偷规则之后，确保合法用户才被路由
    rules.append({"type": "field", "network": "tcp,udp", "outboundTag": relay_tag})
    default_out = relay_tag
    break

config = {
    "log": {"loglevel": "warning", "access": "{}/access.log".format(log_dir), "error": "{}/error.log".format(log_dir)},
    "inbounds": inbounds,
    "outbounds": outbounds,
    "routing": {"domainStrategy": "IPIfNonMatch", "defaultOutboundTag": default_out, "rules": rules}
}
print(json.dumps(config, indent=2, ensure_ascii=False))
PYEOF
}

regen_config() {
    log_step "生成 Xray 配置文件..."
    fix_log_perms
    sanitize_db
    ensure_python || return 1

    local cfg
    cfg=$(gen_config_python "$NODE_DB" "$RELAY_DB" "$XRAY_LOG_DIR" "$GUARD_BASE_PORT")
    if [ $? -ne 0 ] || [ -z "$cfg" ]; then
        log_error "配置生成失败"
        return 1
    fi
    printf '%s\n' "$cfg" > "$XRAY_CONFIG"

    local tout
    tout=$("$XRAY_BIN" run -test -config "$XRAY_CONFIG" 2>&1)
    if [ $? -ne 0 ]; then
        log_error "配置文件验证失败: \n$tout"
        return 1
    fi
    return 0
}

xray_is_active() {
    if [ "$SVC_MGR" = "systemd" ]; then
        systemctl is-active --quiet xray 2>/dev/null
        return $?
    else
        /etc/init.d/xray status 2>/dev/null | grep -q "started"
        return $?
    fi
}

start_xray() {
    write_xray_service
    if [ "$SVC_MGR" = "systemd" ]; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable xray >/dev/null 2>&1 || true
        systemctl restart xray 2>/dev/null || true
    else
        /etc/init.d/xray restart >/dev/null 2>&1 || true
    fi
}

allow_port() {
    if cmd_exists iptables; then
        iptables -C INPUT -p tcp --dport "$1" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$1" -j ACCEPT 2>/dev/null
    fi
    if cmd_exists ufw; then ufw allow "$1"/tcp >/dev/null 2>&1 || true; fi
}

urlencode() {
    local str="$1" encoded="" i c
    for i in $(seq 0 $(( ${#str} - 1 ))); do
        c="${str:$i:1}"
        case "$c" in [-_.~a-zA-Z0-9]) encoded="${encoded}${c}" ;; *) encoded="${encoded}$(printf '%%%02X' "'$c")" ;; esac
    done
    echo "$encoded"
}

make_uri() {
    local uuid="$1" ip="$2" port="$3" sni="$4" pbk="$5" sid="$6" name="$7" fp="$8" is_v6="${9:-0}"
    local host="$ip"
    [ "$is_v6" = "1" ] && host="[${ip}]"
    echo "vless://${uuid}@${host}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=${fp}&pbk=${pbk}&sid=${sid}&type=tcp&headerType=none#$(urlencode "$name")"
}

# ==============================================================
# 本机节点管理
# ==============================================================
add_node() {
    log_title "添加本机 VLESS+Reality 节点"
    [ ! -x "$XRAY_BIN" ] && { system_init; install_xray || return 1; }

    local name
    read -rp "节点名称 [回车=自动]: " name
    [ -z "$name" ] && name="VLESS-$(date +%m%d-%H%M)"
    name=$(sanitize_field "$name")
    [ -z "$name" ] && name="VLESS-$(date +%m%d-%H%M)"

    local port
    while true; do
        read -rp "监听端口 [回车=443]: " port
        [ -z "$port" ] && port=443
        case "$port" in ''|*[!0-9]*) log_error "端口必须是数字"; continue ;; esac
        if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then log_error "端口范围 1-65535"; continue; fi
        if port_in_use "$port"; then log_error "端口 $port 已被其他节点占用，请换一个"; continue; fi
        break
    done

    echo -e "${GREEN}提示: 现已启用防偷白名单拦截机制，域名可自由选择 (包括 CF 等大站)${NC}"
    local sni
    read -rp "SNI 伪装域名 [回车=www.yahoo.com]: " sni
    [ -z "$sni" ] && sni="www.yahoo.com"
    sni=$(sanitize_field "$sni")
    [ -z "$sni" ] && sni="www.yahoo.com"

    local fp
    read -rp "Fingerprint [回车=chrome]: " fp
    [ -z "$fp" ] && fp="chrome"
    fp=$(sanitize_field "$fp")
    [ -z "$fp" ] && fp="chrome"

    local key_out priv pub uuid sid
    key_out=$("$XRAY_BIN" x25519 2>&1)
    parse_xray_keys "$key_out" || return 1
    priv="$PARSED_PRIV"; pub="$PARSED_PUB"
    uuid=$(gen_uuid); sid=$(openssl rand -hex 8 2>/dev/null || od -An -tx1 /dev/urandom | head -c 8 | tr -d ' \n')

    printf '%s|%s|%s|%s|%s|%s|%s\n' "$uuid" "$port" "$sni" "$sid" "$priv" "$name" "$fp" >> "$NODE_DB"
    allow_port "$port"

    if regen_config; then
        start_xray
        log_success "节点添加成功！"
        show_node_info "$uuid" "$port" "$sni" "$sid" "$priv" "$pub" "$name" "$fp"
    else
        log_error "配置生成失败，已回滚"
        local tmp
        tmp=$(mktemp)
        grep -v "^${uuid}|" "$NODE_DB" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$NODE_DB"
    fi
}

edit_node() {
    log_title "修改节点 (无损生效)"
    pick_node || return
    local uuid port sni sid priv name fp
    IFS='|' read -r uuid port sni sid priv name fp <<< "$PICKED_LINE"

    echo -e "${CYAN}当前节点信息:${NC}"
    echo " 名称: $name"
    echo " 端口: $port"
    echo " SNI:  $sni"
    echo " 指纹: $fp"
    echo -e "${YELLOW}提示: 下面输入新值，如果直接按回车则保持旧值不变。${NC}"
    echo ""

    local nn np ns nf
    read -rp "新名称 [$name]: " nn; [ -z "$nn" ] && nn="$name"
    nn=$(sanitize_field "$nn"); [ -z "$nn" ] && nn="$name"

    read -rp "新端口 [$port]: " np; [ -z "$np" ] && np="$port"
    case "$np" in ''|*[!0-9]*) log_error "端口必须是数字"; return 1;; esac
    if [ "$np" -lt 1 ] || [ "$np" -gt 65535 ]; then log_error "端口范围 1-65535"; return 1; fi
    if [ "$np" != "$port" ] && port_in_use "$np" "$uuid"; then
        log_error "端口 $np 已被其他节点占用"
        return 1
    fi

    read -rp "新 SNI [$sni]: " ns; [ -z "$ns" ] && ns="$sni"
    ns=$(sanitize_field "$ns"); [ -z "$ns" ] && ns="$sni"

    read -rp "新指纹 [$fp]: " nf; [ -z "$nf" ] && nf="$fp"
    nf=$(sanitize_field "$nf"); [ -z "$nf" ] && nf="$fp"

    local tmp
    tmp=$(mktemp)
    awk -F'|' -v u="$uuid" -v nn="$nn" -v np="$np" -v ns="$ns" -v nf="$nf" 'BEGIN{OFS="|"}
        /^#/{print; next}
        { if($1==u){ $2=np; $3=ns; $6=nn; $7=nf; } print }' "$NODE_DB" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$NODE_DB"

    if regen_config; then
        allow_port "$np"
        start_xray
        log_success "修改成功！Xray已重载新配置。"
        local pub
        pub=$(derive_pub "$priv")
        show_node_info "$uuid" "$np" "$ns" "$sid" "$priv" "$pub" "$nn" "$nf"
    else
        log_error "修改失败，可能端口被占用或配置格式错误"
    fi
}

view_node() {
    log_title "查看单个节点信息"
    pick_node || return
    local uuid port sni sid priv name fp
    IFS='|' read -r uuid port sni sid priv name fp <<< "$PICKED_LINE"
    local pub
    pub=$(derive_pub "$priv")
    show_node_info "$uuid" "$port" "$sni" "$sid" "$priv" "$pub" "$name" "$fp"
}

view_all_nodes() {
    log_title "所有节点信息"
    if [ ! -s "$NODE_DB" ]; then
        echo "  (无节点)"
        return
    fi
    while IFS='|' read -r uuid port sni sid priv name fp; do
        [ -z "$uuid" ] && continue
        case "$uuid" in '#'*) continue ;; esac
        local pub
        pub=$(derive_pub "$priv")
        show_node_info "$uuid" "$port" "$sni" "$sid" "$priv" "$pub" "$name" "${fp:-chrome}"
    done < <(cat "$NODE_DB" | tr -d '\r')
}

show_node_info() {
    local uuid="$1" port="$2" sni="$3" sid="$4" priv="$5" pub="$6" name="$7" fp="${8:-chrome}"
    local ipv4 ipv6; ipv4=$(get_ipv4); ipv6=$(get_ipv6)
    echo -e "\n${CYAN}════ 节点: $name ════${NC}"
    echo "UUID:        $uuid"
    echo "Port:        $port"
    echo "SNI:         $sni"
    echo "Public Key:  $pub"
    echo "Short ID:    $sid"
    [ -n "$ipv4" ] && echo -e "\n${GREEN}── VLESS URI (IPv4) ──${NC}\n${YELLOW}$(make_uri "$uuid" "$ipv4" "$port" "$sni" "$pub" "$sid" "$name" "$fp" "0")${NC}"
    [ -n "$ipv6" ] && echo -e "\n${GREEN}── VLESS URI (IPv6) ──${NC}\n${YELLOW}$(make_uri "$uuid" "$ipv6" "$port" "$sni" "$pub" "$sid" "${name}-v6" "$fp" "1")${NC}"
    echo -e "${CYAN}═════════════════════${NC}\n"
}

list_nodes() {
    echo -e "\n${CYAN}── 本机节点列表 ────────────────────────────${NC}"
    [ ! -s "$NODE_DB" ] && { echo "  (无节点)"; return 0; }
    local idx=0
    while IFS='|' read -r uuid port sni sid priv name fp; do
        [ -z "$uuid" ] && continue
        case "$uuid" in '#'*) continue ;; esac
        idx=$((idx + 1))
        echo "  [$idx] $name  端口:$port  SNI:$sni  UUID:${uuid:0:8}..."
    done < <(cat "$NODE_DB" | tr -d '\r')
    [ "$idx" -eq 0 ] && echo "  (无节点)"
    return 0
}

pick_node() {
    list_nodes
    [ ! -s "$NODE_DB" ] && return 1
    read -rp "请输入序号: " n
    n=$(echo "$n" | tr -d ' ')
    case "$n" in ''|*[!0-9]*) log_error "输入无效"; return 1;; esac

    PICKED_LINE=$(awk -F'|' -v n="$n" '!/^#/ && NF>=7 {cnt++; if(cnt==n){print; exit}}' "$NODE_DB" | tr -d '\r')
    [ -z "$PICKED_LINE" ] && { log_error "找不到该序号"; return 1; }
    return 0
}

delete_node() {
    log_title "删除节点"
    pick_node || return
    local uuid name; IFS='|' read -r uuid _ _ _ _ name _ <<< "$PICKED_LINE"
    read -rp "确认删除节点 '$name'? [y/N]: " c
    [ "${c:-N}" != "y" ] && [ "${c:-N}" != "Y" ] && return

    local tmp
    tmp=$(mktemp)
    grep -v "^${uuid}|" "$NODE_DB" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$NODE_DB"

    regen_config && start_xray && log_success "已删除节点"
}

# 真实解析配置的验配版测试
test_node() {
    log_title "检测节点状态"
    pick_node || return
    local uuid port sni sid priv name fp
    IFS='|' read -r uuid port sni sid priv name fp <<< "$PICKED_LINE"
    echo ""

    log_step "1. Xray 服务状态..."
    if xray_is_active; then
        log_success "Xray 运行中"
    else
        log_error "Xray 未运行，尝试自动启动..."
        start_xray
        if xray_is_active; then log_success "已成功启动"; else log_error "启动失败，请查看日志"; fi
    fi

    log_step "2. 配置文件验证..."
    local tout
    tout=$("$XRAY_BIN" run -test -config "$XRAY_CONFIG" 2>&1)
    if [ $? -eq 0 ]; then
        log_success "配置文件内部验证通过"
    else
        log_error "配置文件内部验证失败:\n$tout"
    fi

    log_step "3. 端口 $port 监听检查..."
    if ss -tlnp 2>/dev/null | grep -q ":${port}[[:space:]]"; then
        log_success "端口 $port 正在监听"
    else
        log_warn "端口 $port 未检测到监听 (若在容器内可能正常)"
    fi

    log_step "4. SNI 伪装域名可达性 ($sni)..."
    local hc
    hc=$(curl -sI --max-time 5 "https://${sni}" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "0")
    case "$hc" in
        2*|3*) log_success "SNI $sni 连通正常 (HTTP $hc)" ;;
        *)     log_warn "SNI $sni 返回异常 ($hc)" ;;
    esac

    log_step "5. 防偷流量架构检测..."
    if [ -f "$XRAY_CONFIG" ] && grep -q '"dest": "127.0.0.1:' "$XRAY_CONFIG" && grep -q 'dokodemo-door' "$XRAY_CONFIG"; then
        log_success "XTLS 官方 Dokodemo-door 防偷架构已完全加载！(域前置免疫)"
    else
        log_error "未检测到完整的防偷架构配置，请执行 [强制修复配置] 以重建。"
    fi

    echo ""
    log_success "检测完成 - [$name] 状态检查结束"
}

# ==============================================================
# 落地管理 (完整增删改查)
# ==============================================================
show_relay_mode() {
    local al ai
    al=$(awk -F'|' '!/^#/ && NF && $9=="1" {print $1; exit}' "$RELAY_DB" 2>/dev/null || true)
    if [ -n "$al" ]; then
        ai=$(awk -F'|' '!/^#/ && NF && $9=="1" {print $2":"$3; exit}' "$RELAY_DB" 2>/dev/null || true)
        echo -e "  当前模式: ${YELLOW}中转${NC} → $al ($ai)"
    else
        echo -e "  当前模式: ${GREEN}直连${NC} (流量从本机直接出网)"
    fi
}

list_relays() {
    echo -e "\n${CYAN}── 落地节点列表 ────────────────────────────${NC}"
    show_relay_mode; echo ""
    [ ! -s "$RELAY_DB" ] && { echo "  (无)"; return 0; }
    local idx=0
    while IFS='|' read -r label ip port uuid pubkey shortid sni fp active; do
        [ -z "$label" ] && continue
        case "$label" in '#'*) continue ;; esac
        idx=$((idx + 1))
        local mark="      "
        [ "$(echo "$active" | tr -d '\r')" = "1" ] && mark="${GREEN}[激活]${NC}"
        echo -e "  [$idx] ${mark} $label  ${ip}:${port}  SNI:$sni"
    done < "$RELAY_DB"
}

# 按列表序号选中落地，序号口径与 list_relays 显示一致 (非空且非#开头行)
pick_relay() {
    list_relays
    [ ! -s "$RELAY_DB" ] && return 1
    local n
    read -rp "请输入序号: " n
    n=$(echo "$n" | tr -d ' ')
    case "$n" in ''|*[!0-9]*) log_error "输入无效"; return 1;; esac

    PICKED_RELAY_NUM=$(awk -v n="$n" '!/^#/ && NF {cnt++; if(cnt==n){print NR; exit}}' "$RELAY_DB" | tr -d '\r')
    [ -z "$PICKED_RELAY_NUM" ] && { log_error "找不到该序号"; return 1; }
    PICKED_RELAY_LINE=$(sed -n "${PICKED_RELAY_NUM}p" "$RELAY_DB" | tr -d '\r')
    [ -z "$PICKED_RELAY_LINE" ] && { log_error "读取落地数据失败"; return 1; }
    return 0
}

add_relay() {
    log_title "添加落地节点"
    local label ip port uuid pubkey shortid sni fp
    read -rp "备注名称: " label; [ -z "$label" ] && label="relay-$(date +%s)"
    label=$(sanitize_field "$label"); [ -z "$label" ] && label="relay-$(date +%s)"

    while true; do
        read -rp "落地 IP: " ip
        ip=$(echo "$ip" | tr -d ' ')
        [ -n "$ip" ] && break
        log_error "IP 不能为空"
    done

    while true; do
        read -rp "端口 [443]: " port; port=${port:-443}
        case "$port" in ''|*[!0-9]*) log_error "端口必须为数字"; continue;; esac
        if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then log_error "端口范围 1-65535"; continue; fi
        break
    done

    while true; do
        read -rp "UUID: " uuid
        uuid=$(echo "$uuid" | tr -d ' ')
        [ -n "$uuid" ] && break
        log_error "UUID 不能为空"
    done

    read -rp "Public Key: " pubkey; pubkey=$(echo "$pubkey" | tr -d ' ')
    read -rp "Short ID: " shortid; shortid=$(echo "$shortid" | tr -d ' ')
    read -rp "SNI [www.yahoo.com]: " sni; sni=${sni:-www.yahoo.com}
    sni=$(sanitize_field "$sni"); [ -z "$sni" ] && sni="www.yahoo.com"
    read -rp "Fingerprint [chrome]: " fp; fp=${fp:-chrome}
    fp=$(sanitize_field "$fp"); [ -z "$fp" ] && fp="chrome"

    local active=0
    if [ ! -s "$RELAY_DB" ]; then active=1
    else
        read -rp "立即激活此落地并切换为中转? [y/N]: " act
        if [ "${act:-N}" = "y" ] || [ "${act:-N}" = "Y" ]; then
            active=1
            awk -F'|' 'BEGIN{OFS="|"} /^#/{print;next} NF{$9=0; print}' "$RELAY_DB" > "$RELAY_DB.tmp" && mv "$RELAY_DB.tmp" "$RELAY_DB"
        fi
    fi

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$label" "$ip" "$port" "$uuid" "$pubkey" "$shortid" "$sni" "$fp" "$active" >> "$RELAY_DB"
    sanitize_db
    regen_config && start_xray && log_success "已添加落地: $label"
    list_relays
}

edit_relay() {
    log_title "修改落地节点 (无损生效)"
    pick_relay || return
    local label ip port uuid pubkey shortid sni fp active
    IFS='|' read -r label ip port uuid pubkey shortid sni fp active <<< "$PICKED_RELAY_LINE"

    echo -e "${CYAN}当前落地信息:${NC}"
    echo " 备注名称: $label"
    echo " 落地 IP: $ip"
    echo " 端口: $port"
    echo " UUID: ${uuid:0:8}..."
    echo " SNI: $sni"
    echo " 指纹: $fp"
    echo -e "${YELLOW}提示: 下面输入新值，直接回车保持不变${NC}\n"

    local nl nip np nuuid npub nshort nsni nfp
    read -rp "新备注 [$label]: " nl; [ -z "$nl" ] && nl="$label"
    nl=$(sanitize_field "$nl"); [ -z "$nl" ] && nl="$label"

    read -rp "新 IP [$ip]: " nip; [ -z "$nip" ] && nip="$ip"
    nip=$(echo "$nip" | tr -d ' '); [ -z "$nip" ] && nip="$ip"

    read -rp "新端口 [$port]: " np; [ -z "$np" ] && np="$port"
    case "$np" in ''|*[!0-9]*) log_error "端口必须是数字"; return 1;; esac
    if [ "$np" -lt 1 ] || [ "$np" -gt 65535 ]; then log_error "端口范围 1-65535"; return 1; fi

    read -rp "新 UUID (回车保持): " nuuid; [ -z "$nuuid" ] && nuuid="$uuid"
    nuuid=$(echo "$nuuid" | tr -d ' '); [ -z "$nuuid" ] && nuuid="$uuid"

    read -rp "新 Public Key (回车保持): " npub; [ -z "$npub" ] && npub="$pubkey"
    npub=$(echo "$npub" | tr -d ' ')

    read -rp "新 Short ID [$shortid]: " nshort; [ -z "$nshort" ] && nshort="$shortid"
    nshort=$(echo "$nshort" | tr -d ' ')

    read -rp "新 SNI [$sni]: " nsni; [ -z "$nsni" ] && nsni="$sni"
    nsni=$(sanitize_field "$nsni"); [ -z "$nsni" ] && nsni="$sni"

    read -rp "新指纹 [$fp]: " nfp; [ -z "$nfp" ] && nfp="$fp"
    nfp=$(sanitize_field "$nfp"); [ -z "$nfp" ] && nfp="$fp"

    local newline
    newline=$(printf '%s|%s|%s|%s|%s|%s|%s|%s|%s' "$nl" "$nip" "$np" "$nuuid" "$npub" "$nshort" "$nsni" "$nfp" "$active")
    replace_line_by_num "$RELAY_DB" "$PICKED_RELAY_NUM" "$newline"
    sanitize_db

    if regen_config; then
        start_xray
        log_success "落地修改成功，已重载生效"
    else
        log_error "配置生成失败，请检查输入"
    fi
}

delete_relay() {
    log_title "删除落地节点"
    pick_relay || return
    local label active
    IFS='|' read -r label _ _ _ _ _ _ _ active <<< "$PICKED_RELAY_LINE"
    if [ "$active" = "1" ]; then
        log_warn "该落地当前处于激活(中转)状态，删除后将自动切回直连模式"
    fi
    read -rp "确认删除落地 '$label'? [y/N]: " c
    [ "${c:-N}" != "y" ] && [ "${c:-N}" != "Y" ] && return

    delete_line_by_num "$RELAY_DB" "$PICKED_RELAY_NUM"
    sanitize_db
    regen_config && start_xray && log_success "已删除落地: $label"
}

switch_relay() {
    log_title "切换路由模式"
    list_relays
    echo "输入序号 -> 激活该落地(中转) | 输入 0 -> 取消所有激活(直连)"
    read -rp "请输入: " n; n=$(echo "$n" | tr -d ' ')
    case "$n" in ''|*[!0-9]*) log_error "输入无效"; return 1;; esac

    if [ "$n" = "0" ]; then
        awk -F'|' 'BEGIN{OFS="|"} /^#/{print;next} NF{gsub(/\r/,"",$9); $9=0; print}' "$RELAY_DB" > "$RELAY_DB.tmp" && mv "$RELAY_DB.tmp" "$RELAY_DB"
        regen_config && start_xray && log_success "已切换为直连模式"
    else
        # 计数口径与 list_relays 一致
        local target_num
        target_num=$(awk -v n="$n" '!/^#/ && NF {cnt++; if(cnt==n){print NR; exit}}' "$RELAY_DB" | tr -d '\r')
        [ -z "$target_num" ] && { log_error "找不到该序号"; return 1; }
        awk -F'|' -v tn="$target_num" 'BEGIN{OFS="|"}
            /^#/{print; next}
            NF{gsub(/\r/,"",$9); $9=(NR==tn?1:0); print}' "$RELAY_DB" > "$RELAY_DB.tmp" && mv "$RELAY_DB.tmp" "$RELAY_DB"
        regen_config && start_xray && log_success "模式切换已生效"
    fi
}

relay_menu() {
    while true; do
        log_title "中转落地管理"
        show_relay_mode; echo ""
        echo "  1) 添加落地节点"
        echo "  2) 查看所有落地"
        echo "  3) 修改落地节点"
        echo "  4) 删除落地节点"
        echo "  5) 切换路由模式 (直连/中转)"
        echo "  0) 返回主菜单"
        read -rp "选择: " c
        case "$c" in
            1) add_relay ;; 2) list_relays ;; 3) edit_relay ;; 4) delete_relay ;; 5) switch_relay ;; 0) break ;; *) ;;
        esac
    done
}

# ==============================================================
# 菜单入口
# ==============================================================
main_menu() {
    need_root
    detect_os

    sanitize_db
    check_upgrade

    mkdir -p "$DATA_DIR" "$BACKUP_DIR" "$XRAY_LOG_DIR" "$XRAY_ETC" 2>/dev/null || true
    touch "$NODE_DB" "$RELAY_DB" 2>/dev/null || true

    while true; do
        echo ""
        echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║   VPS 一键管理  ${SCRIPT_VERSION}                     ║${NC}"
        echo -e "${BLUE}║   Xray VLESS+Reality 严谨加固防偷优化版      ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
        echo ""
        show_relay_mode
        echo ""
        echo -e "${CYAN}── 本机节点 ────────────────────────────────────${NC}"
        echo "   1) 添加节点"
        echo "   2) 修改节点 (SNI/端口等，无损生效)"
        echo "   3) 删除节点"
        echo "   4) 查看单个节点信息 & URI"
        echo "   5) 查看所有节点信息 & URI"
        echo "   6) 检测节点状态 (真实解析验配)"
        echo ""
        echo -e "${CYAN}── 中转落地 ────────────────────────────────────${NC}"
        echo "   7) 中转落地管理（增删改查/切换）"
        echo ""
        echo -e "${CYAN}── Xray 服务 ───────────────────────────────────${NC}"
        echo "   8) 重启 Xray 服务"
        echo "   9) 强制修复配置 (解决部分启动失败)"
        echo "  10) 一键全新初始化 (危险操作)"
        echo "   0) 退出"
        echo ""
        read -rp "请选择: " choice
        choice=$(echo "${choice:-}" | tr -d ' ')
        case "$choice" in
            1)  add_node ;;
            2)  edit_node ;;
            3)  delete_node ;;
            4)  view_node ;;
            5)  view_all_nodes ;;
            6)  test_node ;;
            7)  relay_menu ;;
            8)  start_xray && log_success "已重启" ;;
            9)  regen_config && start_xray && log_success "修复成功" ;;
            10) rm -rf "${DATA_DIR:?}" "${XRAY_ETC:?}"; log_success "已重置配置，请重新运行脚本"; exit 0 ;;
            0)  exit 0 ;;
            *)  log_warn "无效选项" ;;
        esac
    done
}

main_menu
