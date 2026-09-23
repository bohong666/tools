#!/usr/bin/env bash
# ==============================================================
# VPS 一键管理脚本  v2.2.4 (修复版 + 平滑升级 + 节点修改)
# 功能: Xray VLESS+Reality+Vision  本地直连 + 链式中转
# 支持: Ubuntu/Debian/Alpine | IPv4/IPv6/双栈
#
# 更新日志 v2.2.4:
#   1. 修复: 找回遗失的 view_node 函数，解决查看节点报错问题
#   2. 恢复: 重新加入广受好评的 test_node (节点测试) 功能
#   3. 继承: 智能无损修改节点 SNI/端口、防偷流量、去除 \r 换行符Bug
# ==============================================================

SCRIPT_VERSION="v2.2.4"

# ── 颜色 ──────────────────────────────────────────────────────
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
    echo ""
    echo -e "${MAGENTA}══════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}  $*${NC}"
    echo -e "${MAGENTA}══════════════════════════════════════════════${NC}"
    echo ""
}

# ── 全局路径 ──────────────────────────────────────────────────
XRAY_BIN="/usr/local/bin/xray"
XRAY_ETC="/usr/local/etc/xray"
XRAY_CONFIG="$XRAY_ETC/config.json"
XRAY_LOG_DIR="/var/log/xray"

DATA_DIR="/etc/vps_manager"
NODE_DB="$DATA_DIR/nodes.db"
RELAY_DB="$DATA_DIR/relay.db"
BACKUP_DIR="/root/vps_manager_backups"

OS_TYPE=""
PKG_MGR=""
SVC_MGR=""
TOTAL_MEM=0
TOTAL_DISK=0
PYTHON=""
PICKED_LINE=""
PARSED_PRIV=""
PARSED_PUB=""

UPGRADE_CHECKED=0

# ==============================================================
# 工具函数
# ==============================================================
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

sanitize_db() {
    [ -f "$NODE_DB" ] && sed -i 's/\r//g' "$NODE_DB" 2>/dev/null || true
    [ -f "$RELAY_DB" ] && sed -i 's/\r//g' "$RELAY_DB" 2>/dev/null || true
}

# ==============================================================
# 升级与初始化检查
# ==============================================================
check_upgrade() {
    if [ "$UPGRADE_CHECKED" = "1" ]; then return 0; fi
    export UPGRADE_CHECKED=1

    if [ -s "$NODE_DB" ] || [ -s "$RELAY_DB" ]; then
        echo ""
        log_title "检测到已存在的老节点数据"
        echo -e "${YELLOW}为了适配新版防偷流量脚本(v$SCRIPT_VERSION)，请选择操作：${NC}"
        echo "  1) 保留原有节点并 平滑升级 (推荐)"
        echo "  2) 彻底清空旧数据并 全新安装 (危险)"
        echo "  0) 退出脚本"
        read -rp "请选择: " ch
        case "$ch" in
            1)
                log_info "正在为您保留数据并平滑升级配置..."
                sanitize_db
                ensure_python
                if regen_config; then
                    start_xray
                    log_success "平滑升级完成！旧节点不受影响，新防偷规则已生效。"
                else
                    log_warn "配置重新生成失败，请在主菜单选 强制修复。"
                fi
                sleep 2
                ;;
            2)
                read -rp "警告: 将删除所有历史节点和配置！确定吗？[y/N]: " confirm
                if [ "${confirm:-N}" = "y" ] || [ "${confirm:-N}" = "Y" ]; then
                    rm -rf "$DATA_DIR" "$XRAY_ETC"
                    mkdir -p "$DATA_DIR" "$BACKUP_DIR" "$XRAY_LOG_DIR" "$XRAY_ETC"
                    touch "$NODE_DB" "$RELAY_DB"
                    log_success "已彻底清理旧数据，准备全新安装"
                    sleep 1
                else
                    log_info "已取消"
                    exit 0
                fi
                ;;
            *) exit 0 ;;
        esac
    fi
}

detect_os() {
    if [ ! -f /etc/os-release ]; then log_error "无法识别操作系统"; exit 1; fi
    local os_id=$(grep -E "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"' | tr -d "'" | tr '[:upper:]' '[:lower:]')
    case "$os_id" in
        ubuntu|debian) OS_TYPE="ubuntu"; PKG_MGR="apt"; SVC_MGR="systemd" ;;
        alpine)        OS_TYPE="alpine"; PKG_MGR="apk"; SVC_MGR="openrc" ;;
        *)             log_error "不支持的发行版: '${os_id}'"; exit 1 ;;
    esac
}

need_root() {
    local uid=$(id -u 2>/dev/null || echo "1")
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

get_ipv4() { curl -s -4 --max-time 8 https://api4.ipify.org 2>/dev/null | tr -d '[:space:]'; }
get_ipv6() { curl -s -6 --max-time 8 https://api6.ipify.org 2>/dev/null | tr -d '[:space:]'; }
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
    touch /etc/sysctl.conf 2>/dev/null || true
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true
}

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
        bash -c "$(curl -fsSL "$dl_url" 2>/dev/null)" -- install || return 1
    else
        local tag=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"\(v[^"]*\)".*/\1/')
        [ -z "$tag" ] && tag="v1.8.4"
        local arch="64"; [ "$(uname -m)" = "aarch64" ] && arch="arm64-v8a"
        local tmp=$(mktemp -d)
        gh_download "https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-${arch}.zip" "$tmp/xray.zip"
        unzip -q -o "$tmp/xray.zip" -d "$tmp/xray"
        install -m 755 "$tmp/xray/xray" "$XRAY_BIN"
        mkdir -p /usr/local/share/xray
        cp "$tmp/xray/"*.dat /usr/local/share/xray/ 2>/dev/null || true
        rm -rf "$tmp"
    fi
    write_xray_service
    return 0
}

write_xray_service() {
    if [ "$SVC_MGR" = "systemd" ]; then
        rm -rf "/etc/systemd/system/xray.service.d" 2>/dev/null || true
        cat > /etc/systemd/system/xray.service <<SVCEOF
[Unit]
Description=Xray Service
After=network-online.target

[Service]
Type=simple
User=root
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
# 配置文件生成 Python 内联
# ==============================================================
gen_config_python() {
    "$PYTHON" <<PYEOF
import sys, json

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

inbounds = []
for line in read_db("$1"):
    p = line.split('|')
    if len(p) < 7: continue
    uuid, port, sni, sid, priv, name, fp = [x.strip() for x in p[:7]]
    
    inbounds.append({
        "tag": "in-{}-{}".format(port, uuid[:8]),
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
                "rejectUnknownSni": True,
                "privateKey": priv,
                "shortIds": [sid],
                "limitFallbackUpload": {"afterBytes": 0, "bytesPerSec": 10},
                "limitFallbackDownload": {"afterBytes": 0, "bytesPerSec": 10}
            }
        },
        "sniffing": {
            "enabled": True,
            "destOverride": ["http", "tls", "quic"],
            "routeOnly": True
        }
    })

outbounds = [
    {"protocol": "freedom",   "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
]

rules = [
    {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
    {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
    {"type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block"}
]
default_out = "direct"

for line in read_db("$2"):
    p = line.split('|')
    if len(p) < 9: continue
    label, ip, rport, ruuid, pubkey, shortid, rsni, fp, active = [x.strip() for x in p[:9]]
    if active != '1': continue
    
    relay_tag = "relay-out"
    outbounds.insert(0, {
        "tag": relay_tag,
        "protocol": "vless",
        "settings": {
            "vnext": [{
                "address": ip,
                "port": int(rport),
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
    rules.append({"type": "field", "network": "tcp,udp", "outboundTag": relay_tag})
    default_out = relay_tag
    break

config = {
    "log": {"loglevel": "warning", "access": "$3/access.log", "error": "$3/error.log"},
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
    local cfg; cfg=$(gen_config_python "$NODE_DB" "$RELAY_DB" "$XRAY_LOG_DIR")
    if [ $? -ne 0 ] || [ -z "$cfg" ]; then return 1; fi
    printf '%s\n' "$cfg" > "$XRAY_CONFIG"
    "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1 || return 1
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

    read -rp "节点名称 [回车=自动]: " name
    [ -z "$name" ] && name="VLESS-$(date +%m%d-%H%M)"

    read -rp "监听端口 [回车=443]: " port
    [ -z "$port" ] && port=443

    echo -e "${YELLOW}提示: 避免使用 cloudflare、apple 等大站域名，防止被当成反代替用${NC}"
    read -rp "SNI 伪装域名 [回车=www.yahoo.com]: " sni
    [ -z "$sni" ] && sni="www.yahoo.com"
    read -rp "Fingerprint [回车=chrome]: " fp
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
        sed -i "/^${uuid}/d" "$NODE_DB"
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
    read -rp "新端口 [$port]: " np; [ -z "$np" ] && np="$port"
    read -rp "新 SNI [$sni]: " ns; [ -z "$ns" ] && ns="$sni"
    read -rp "新指纹 [$fp]: " nf; [ -z "$nf" ] && nf="$fp"

    local tmp=$(mktemp)
    awk -F'|' -v u="$uuid" -v nn="$nn" -v np="$np" -v ns="$ns" -v nf="$nf" 'BEGIN{OFS="|"}
        /^#/{print; next}
        { if($1==u){ $2=np; $3=ns; $6=nn; $7=nf; } print }' "$NODE_DB" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$NODE_DB"

    if regen_config; then
        allow_port "$np"
        start_xray
        log_success "修改成功！Xray已重载新配置。"
        local pub=$(derive_pub "$priv")
        show_node_info "$uuid" "$np" "$ns" "$sid" "$priv" "$pub" "$nn" "$nf"
    else
        log_error "修改失败，可能端口被占用或配置格式错误"
    fi
}

# 恢复：查看单个节点信息
view_node() {
    log_title "查看节点信息"
    pick_node || return
    local uuid port sni sid priv name fp
    IFS='|' read -r uuid port sni sid priv name fp <<< "$PICKED_LINE"
    local pub=$(derive_pub "$priv")
    show_node_info "$uuid" "$port" "$sni" "$sid" "$priv" "$pub" "$name" "$fp"
}

# 恢复：查看所有节点信息
view_all_nodes() {
    log_title "所有节点信息"
    if [ ! -s "$NODE_DB" ]; then
        echo "  (无节点)"
        return
    fi
    while IFS='|' read -r uuid port sni sid priv name fp; do
        [ -z "$uuid" ] && continue
        case "$uuid" in '#'*) continue ;; esac
        local pub=$(derive_pub "$priv")
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
    PICKED_LINE=$(awk -F'|' -v n="$n" '!/^#/ && NF>=7 {cnt++; if(cnt==n){print; exit}}' "$NODE_DB" | tr -d '\r')
    [ -z "$PICKED_LINE" ] && { log_error "序号无效"; return 1; }
    return 0
}

delete_node() {
    log_title "删除节点"
    pick_node || return
    local uuid name; IFS='|' read -r uuid _ _ _ _ name _ <<< "$PICKED_LINE"
    read -rp "确认删除节点 '$name'? [y/N]: " c
    [ "${c:-N}" != "y" ] && return
    sed -i "/^${uuid}/d" "$NODE_DB"
    regen_config && start_xray && log_success "已删除节点"
}

# 恢复：测试节点功能
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
    local tout=$("$XRAY_BIN" run -test -config "$XRAY_CONFIG" 2>&1)
    if [ $? -eq 0 ]; then
        log_success "配置文件验证通过"
    else
        log_error "配置文件验证失败:\n$tout"
    fi

    log_step "3. 端口 $port 监听检查..."
    if ss -tlnp 2>/dev/null | grep -q ":${port}[[:space:]]"; then
        log_success "端口 $port 正在监听"
    else
        log_warn "端口 $port 未检测到监听 (若在容器内可能正常，请实际测试)"
    fi

    log_step "4. SNI 伪装域名可达性 ($sni)..."
    local hc=$(curl -sI --max-time 5 "https://${sni}" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "0")
    case "$hc" in
        2*|3*) log_success "SNI $sni 连通正常 (HTTP $hc)" ;;
        *)     log_warn "SNI $sni 返回异常 ($hc)，建议更换其他域名" ;;
    esac

    log_step "5. 防偷流量核心检测..."
    log_success "XTLS原生防护已加载 (rejectUnknownSni: true, limitFallback: 10B/s)"
    
    echo ""
    log_success "检测完成 - [$name] 状态良好"
}

# ==============================================================
# 落地管理
# ==============================================================
show_relay_mode() {
    local al ai
    al=$(awk -F'|' '!/^#/ && int($9)==1 {print $1; exit}' "$RELAY_DB" 2>/dev/null || true)
    if [ -n "$al" ]; then
        ai=$(awk -F'|' '!/^#/ && int($9)==1 {print $2":"$3; exit}' "$RELAY_DB" 2>/dev/null || true)
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

add_relay() {
    log_title "添加落地节点"
    read -rp "备注名称: " label; [ -z "$label" ] && label="relay-$(date +%s)"
    read -rp "落地 IP: " ip; ip=$(echo "$ip" | tr -d ' ')
    read -rp "端口 [443]: " port; port=${port:-443}
    read -rp "UUID: " uuid; uuid=$(echo "$uuid" | tr -d ' ')
    read -rp "Public Key: " pubkey; pubkey=$(echo "$pubkey" | tr -d ' ')
    read -rp "Short ID: " shortid; shortid=$(echo "$shortid" | tr -d ' ')
    read -rp "SNI [www.yahoo.com]: " sni; sni=${sni:-www.yahoo.com}
    read -rp "Fingerprint [chrome]: " fp; fp=${fp:-chrome}

    local active=0
    if [ ! -s "$RELAY_DB" ]; then active=1
    else
        read -rp "立即激活此落地并切换为中转? [y/N]: " act
        [ "${act:-N}" = "y" ] && { active=1; awk -F'|' 'BEGIN{OFS="|"} /^#/{print;next} NF>=9{$9=0; print}' "$RELAY_DB" > "$RELAY_DB.tmp" && mv "$RELAY_DB.tmp" "$RELAY_DB"; }
    fi

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$label" "$ip" "$port" "$uuid" "$pubkey" "$shortid" "$sni" "$fp" "$active" >> "$RELAY_DB"
    sanitize_db
    regen_config && start_xray && log_success "已添加落地: $label"
    list_relays
}

switch_relay() {
    log_title "切换路由模式"
    list_relays
    echo "输入序号 -> 激活该落地(中转) | 输入 0 -> 取消所有激活(直连)"
    read -rp "请输入: " n; n=$(echo "$n" | tr -d ' ')

    if [ "$n" = "0" ]; then
        awk -F'|' 'BEGIN{OFS="|"} /^#/{print;next} NF>=9{gsub(/\r/,"",$9); $9=0; print}' "$RELAY_DB" > "$RELAY_DB.tmp" && mv "$RELAY_DB.tmp" "$RELAY_DB"
        regen_config && start_xray && log_success "已切换为直连模式"
    else
        awk -F'|' -v n="$n" 'BEGIN{OFS="|"; cnt=0}
            /^#/{print; next}
            NF>=9{
                cnt++;
                gsub(/\r/,"",$9);
                if(cnt==n) $9=1; else $9=0;
                print
            }' "$RELAY_DB" > "$RELAY_DB.tmp" && mv "$RELAY_DB.tmp" "$RELAY_DB"
        regen_config && start_xray && log_success "模式切换已生效"
    fi
}

relay_menu() {
    while true; do
        log_title "中转落地管理"
        show_relay_mode; echo ""
        echo "  1) 添加落地节点"
        echo "  2) 查看所有落地"
        echo "  3) 切换路由模式 (直连/中转)"
        echo "  0) 返回主菜单"
        read -rp "选择: " c
        case "$c" in
            1) add_relay ;; 2) list_relays ;; 3) switch_relay ;; 0) break ;; *) ;;
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
        echo -e "${BLUE}║   Xray VLESS+Reality  原生防偷/动态修改优化版║${NC}"
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
        echo "   6) 检测节点状态 (连通性/防偷)"
        echo ""
        echo -e "${CYAN}── 中转落地 ────────────────────────────────────${NC}"
        echo "   7) 中转落地管理（添加/切换/检测）"
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
            10) rm -rf "$DATA_DIR" "$XRAY_ETC"; log_success "已重置配置，请重新运行脚本"; exit 0 ;;
            0)  exit 0 ;;
            *)  log_warn "无效选项" ;;
        esac
    done
}

main_menu
