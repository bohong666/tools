#!/usr/bin/env bash
# ==============================================================
# VPS 一键管理脚本  v2.1.0
# 功能: Xray VLESS+Reality+Vision  本地直连 + 链式中转
# 支持: Ubuntu/Debian/Alpine | IPv4/IPv6/双栈 | 小磁盘/容器
#
# 架构:
#   本机 Xray 监听 443，两种路由模式：
#   [直连] 客户端→RFC:443→直接出网        （无需落地）
#   [中转] 客户端→RFC:443→IIJ:443→出网   （链式代理）
#   切换模式只需改 relay.db，重启 Xray，客户端参数不变
# ==============================================================

SCRIPT_VERSION="v2.1.0"

# 注意：故意不使用 set -e，防止子命令非零时脚本静默退出
# 所有错误通过返回值显式判断处理

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
NODE_DB="$DATA_DIR/nodes.db"    # uuid|port|sni|short_id|private_key|name|fingerprint
RELAY_DB="$DATA_DIR/relay.db"   # label|ip|port|uuid|pubkey|shortid|sni|fp|active(0/1)
BACKUP_DIR="/root/vps_manager_backups"

# ── 运行时变量 ────────────────────────────────────────────────
OS_TYPE=""
PKG_MGR=""
SVC_MGR=""
TOTAL_MEM=0
TOTAL_DISK=0
PYTHON=""
PICKED_LINE=""
PARSED_PRIV=""
PARSED_PUB=""

# ==============================================================
# 工具函数
# ==============================================================
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

press_enter() { read -rp "按回车键继续..." _dummy; }

# ==============================================================
# 系统检测（保护性写法，绝不静默退出）
# ==============================================================
detect_os() {
    if [ ! -f /etc/os-release ]; then
        log_error "无法识别操作系统（缺少 /etc/os-release）"
        exit 1
    fi

    local os_id=""
    os_id=$(grep -E "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"' | tr -d "'" | tr '[:upper:]' '[:lower:]')

    case "$os_id" in
        ubuntu|debian)
            OS_TYPE="ubuntu"; PKG_MGR="apt"; SVC_MGR="systemd"
            ;;
        alpine)
            OS_TYPE="alpine"; PKG_MGR="apk"; SVC_MGR="openrc"
            ;;
        *)
            log_error "不支持的发行版: '${os_id}'"
            log_error "目前支持: Ubuntu / Debian / Alpine"
            exit 1
            ;;
    esac

    TOTAL_MEM=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    TOTAL_MEM=${TOTAL_MEM:-0}
    TOTAL_DISK=$(df -BG / 2>/dev/null | awk 'NR==2{gsub(/G/,"",$2); print $2}')
    TOTAL_DISK=${TOTAL_DISK:-0}

    log_info "OS: $OS_TYPE | 内存: ${TOTAL_MEM}MB | 磁盘: ${TOTAL_DISK}GB | 服务管理: $SVC_MGR"
}

need_root() {
    local uid
    uid=$(id -u 2>/dev/null || echo "1")
    if [ "$uid" -ne 0 ]; then
        log_error "请以 root 权限运行：sudo bash $0"
        exit 1
    fi
}

ensure_python() {
    if cmd_exists python3; then
        PYTHON=python3
        return 0
    fi
    if cmd_exists python; then
        PYTHON=python
        return 0
    fi
    log_warn "未检测到 Python，正在安装..."
    if [ "$PKG_MGR" = "apt" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 2>/dev/null || true
    else
        apk add --no-cache -q python3 2>/dev/null || true
    fi
    if cmd_exists python3; then
        PYTHON=python3
    else
        log_error "Python 安装失败，配置生成功能不可用"
        PYTHON=""
    fi
}

# ==============================================================
# 网络
# ==============================================================
get_ipv4() {
    local ip=""
    local url
    for url in https://api4.ipify.org https://ifconfig.me https://icanhazip.com; do
        ip=$(curl -s -4 --max-time 8 "$url" 2>/dev/null || true)
        ip=$(echo "$ip" | tr -d '[:space:]')
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
    done
    echo ""
}

get_ipv6() {
    local ip=""
    local url
    for url in https://api6.ipify.org https://ifconfig.me https://icanhazip.com; do
        ip=$(curl -s -6 --max-time 8 "$url" 2>/dev/null || true)
        ip=$(echo "$ip" | tr -d '[:space:]')
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
    done
    echo ""
}

check_github() {
    curl -sI --max-time 6 https://api.github.com >/dev/null 2>&1
    return $?
}

gh_download() {
    local url="$1"
    local output="$2"
    if check_github; then
        curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$output" "$url"
    else
        log_warn "GitHub 不可直连，使用 ghp.ci 代理..."
        curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$output" "https://ghp.ci/$url"
    fi
}

# ==============================================================
# 密钥工具
# ==============================================================
parse_xray_keys() {
    local out="$1"
    PARSED_PRIV=$(echo "$out" | grep -i "^private" | awk '{print $NF}' | tr -d ' \r\n')
    PARSED_PUB=$(echo "$out"  | grep -iE "(^public|publickey)" | awk '{print $NF}' | tr -d ' \r\n')
    if [ -z "$PARSED_PRIV" ] || [ -z "$PARSED_PUB" ]; then
        log_error "密钥解析失败，原始输出:"
        echo "$out"
        return 1
    fi
    return 0
}

derive_pub() {
    local priv="$1"
    local out
    out=$("$XRAY_BIN" x25519 -i "$priv" 2>&1)
    echo "$out" | grep -iE "(^public|publickey)" | awk '{print $NF}' | tr -d ' \r\n'
}

gen_uuid() {
    if [ -f /proc/sys/kernel/random/uuid ]; then
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
    local mb="$1"
    if [ -f /swapfile ]; then
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
    fi
    local avail_kb
    avail_kb=$(df -k / 2>/dev/null | awk 'NR==2{print $4}')
    avail_kb=${avail_kb:-0}
    local need_kb=$(( mb * 1024 + 512 * 1024 ))
    if [ "$avail_kb" -lt "$need_kb" ]; then
        log_warn "磁盘空间不足（剩余 $((avail_kb/1024))MB），跳过 Swap"
        return 0
    fi
    if fallocate -l "${mb}M" /swapfile 2>/dev/null; then
        true
    elif dd if=/dev/zero of=/swapfile bs=1M count="$mb" status=none 2>/dev/null; then
        true
    else
        log_warn "Swap 文件创建失败，跳过"
        return 0
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1 || { rm -f /swapfile; return 0; }
    if swapon /swapfile 2>/dev/null; then
        grep -q '/swapfile' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        log_success "Swap ${mb}MB 已启用"
    else
        log_warn "容器环境不支持 Swap，跳过"
        rm -f /swapfile
    fi
}

enable_bbr() {
    touch /etc/sysctl.conf 2>/dev/null || true
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    if sysctl -p >/dev/null 2>&1; then
        log_success "BBR 已启用"
    else
        log_warn "容器环境，BBR 跳过（不影响功能）"
    fi
}

# ==============================================================
# 系统初始化
# ==============================================================
system_init() {
    log_step "系统初始化..."

    if [ "$OS_TYPE" = "ubuntu" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            curl wget unzip openssl coreutils iproute2 \
            net-tools iptables python3 2>/dev/null || true

        if [ "$TOTAL_DISK" -ge 10 ]; then
            setup_swap 1024
        elif [ "$TOTAL_DISK" -ge 5 ]; then
            setup_swap 512
        else
            log_warn "磁盘 <5GB，跳过 Swap"
        fi
    else
        apk update -q 2>/dev/null || true
        apk add --no-cache -q \
            bash curl wget unzip openssl coreutils \
            iproute2 iptables ip6tables python3 2>/dev/null || true

        if [ "$TOTAL_DISK" -ge 3 ]; then
            setup_swap 256
        else
            log_warn "磁盘 <3GB，跳过 Swap"
        fi
    fi

    enable_bbr

    mkdir -p "$DATA_DIR" "$BACKUP_DIR" "$XRAY_LOG_DIR" "$XRAY_ETC" 2>/dev/null || true
    touch "$NODE_DB" "$RELAY_DB" 2>/dev/null || true
    chmod 600 "$NODE_DB" "$RELAY_DB" 2>/dev/null || true

    ensure_python
    log_success "系统初始化完成"
}

# ==============================================================
# Xray 安装
# ==============================================================
install_xray() {
    if [ -x "$XRAY_BIN" ]; then
        log_info "Xray 已安装：$("$XRAY_BIN" version 2>&1 | head -1)"
        write_xray_service
        return 0
    fi

    log_step "安装 Xray-core..."

    if [ "$OS_TYPE" = "ubuntu" ]; then
        _install_xray_ubuntu || return 1
    else
        _install_xray_alpine || return 1
    fi

    write_xray_service
    return 0
}

_install_xray_ubuntu() {
    local script_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
    local dl_url="$script_url"
    check_github || dl_url="https://ghp.ci/$script_url"

    local script_content
    script_content=$(curl -fsSL "$dl_url" 2>/dev/null) || {
        log_error "下载 Xray 安装脚本失败"
        return 1
    }
    bash -c "$script_content" -- install || {
        log_error "Xray 安装脚本执行失败"
        return 1
    }
    if [ ! -x "$XRAY_BIN" ]; then
        log_error "Xray 安装失败，二进制文件不存在"
        return 1
    fi
    log_success "Xray 安装完成"
}

_install_xray_alpine() {
    local tag arch asset url tmp

    tag=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"\(v[^"]*\)".*/\1/' || true)
    if [ -z "$tag" ]; then
        tag="v1.8.4"
        log_warn "无法获取最新版本，使用默认 $tag"
    fi

    local machine
    machine=$(uname -m)
    case "$machine" in
        x86_64)             arch="64" ;;
        aarch64|arm64)      arch="arm64-v8a" ;;
        armv7l)             arch="arm32-v7a" ;;
        *)
            log_error "不支持的架构: $machine"
            return 1
            ;;
    esac

    asset="Xray-linux-${arch}.zip"
    url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${asset}"

    tmp=$(mktemp -d)
    log_step "下载 Xray $tag..."
    gh_download "$url" "$tmp/$asset" || {
        rm -rf "$tmp"
        log_error "Xray 下载失败"
        return 1
    }

    unzip -q -o "$tmp/$asset" -d "$tmp/xray" || {
        rm -rf "$tmp"
        log_error "解压失败"
        return 1
    }

    install -m 755 "$tmp/xray/xray" "$XRAY_BIN"
    mkdir -p /usr/local/share/xray
    cp "$tmp/xray/"*.dat /usr/local/share/xray/ 2>/dev/null || true
    rm -rf "$tmp"

    if [ ! -x "$XRAY_BIN" ]; then
        log_error "Xray 安装失败"
        return 1
    fi
    log_success "Xray $tag 安装完成"
}

# 每次都重写服务文件，确保 ExecStart 路径和配置路径正确
write_xray_service() {
    if [ "$SVC_MGR" = "systemd" ]; then
        # 删除官方安装脚本的 drop-in（会覆盖 ExecStart 导致路径错误）
        local drop_dir="/etc/systemd/system/xray.service.d"
        if [ -d "$drop_dir" ]; then
            log_warn "移除 xray.service.d drop-in（避免配置路径冲突）..."
            rm -rf "$drop_dir"
        fi

        cat > /etc/systemd/system/xray.service <<SVCEOF
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
description="Xray Service"
command="${XRAY_BIN}"
command_args="run -config ${XRAY_CONFIG}"
command_background="yes"
pidfile="/run/xray.pid"
output_log="${XRAY_LOG_DIR}/access.log"
error_log="${XRAY_LOG_DIR}/error.log"
depend() { need net; }
start_pre() { checkpath --directory --mode 0755 ${XRAY_LOG_DIR}; }
ORCEOF
        chmod +x /etc/init.d/xray
    fi
}

fix_log_perms() {
    mkdir -p "$XRAY_LOG_DIR" 2>/dev/null || true
    chown root:root "$XRAY_LOG_DIR" 2>/dev/null || true
    chmod 755 "$XRAY_LOG_DIR"
    touch "$XRAY_LOG_DIR/access.log" "$XRAY_LOG_DIR/error.log" 2>/dev/null || true
    chmod 644 "$XRAY_LOG_DIR/access.log" "$XRAY_LOG_DIR/error.log" 2>/dev/null || true
}

# ==============================================================
# 核心：用 Python 生成 Xray config.json
# ==============================================================
regen_config() {
    log_step "生成 Xray 配置文件..."
    mkdir -p "$XRAY_ETC" 2>/dev/null || true
    fix_log_perms

    if [ -z "$PYTHON" ]; then
        ensure_python
    fi
    if [ -z "$PYTHON" ]; then
        log_error "Python 不可用，无法生成配置"
        return 1
    fi

    local cfg
    cfg=$("$PYTHON" - "$NODE_DB" "$RELAY_DB" "$XRAY_LOG_DIR" 2>/dev/null) || {
        log_error "Python 配置生成时出错"
        return 1
    }

    if [ -z "$cfg" ]; then
        log_error "配置生成失败（Python 无输出）"
        return 1
    fi

    echo "$cfg" > "$XRAY_CONFIG" || {
        log_error "无法写入配置文件 $XRAY_CONFIG"
        return 1
    }

    local test_out
    test_out=$("$XRAY_BIN" run -test -config "$XRAY_CONFIG" 2>&1)
    if [ $? -ne 0 ]; then
        log_error "Xray 配置验证失败:"
        echo "$test_out"
        log_error "生成的配置内容:"
        cat "$XRAY_CONFIG"
        return 1
    fi

    log_success "Xray 配置验证通过"
    return 0
}

# Python 脚本内联（heredoc 方式调用）
gen_config_python() {
    local node_db="$1"
    local relay_db="$2"
    local log_dir="$3"

    "$PYTHON" <<PYEOF
import sys, json, os

node_db  = "$node_db"
relay_db = "$relay_db"
log_dir  = "$log_dir"

def read_db(path):
    rows = []
    try:
        with open(path, 'r') as f:
            for line in f:
                line = line.rstrip('\\n')
                if not line or line.startswith('#'):
                    continue
                rows.append(line)
    except:
        pass
    return rows

# ── inbounds: 本机 VLESS 入站 ────────────────────────────────
inbounds = []
for line in read_db(node_db):
    p = line.split('|')
    if len(p) < 7:
        continue
    uuid, port, sni, sid, priv, name, fp = [x.strip() for x in p[:7]]
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
                "shortIds": [sid]
            }
        },
        "sniffing": {
            "enabled": True,
            "destOverride": ["http", "tls", "quic"]
        }
    })

# ── outbounds ─────────────────────────────────────────────────
outbounds = [
    {"protocol": "freedom",   "tag": "direct",  "settings": {}},
    {"protocol": "blackhole", "tag": "block",   "settings": {}}
]
rules = [
    {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}
]
default_out = "direct"

# ── relay: 读取激活的落地 ────────────────────────────────────
for line in read_db(relay_db):
    p = line.split('|')
    if len(p) < 9:
        continue
    label, ip, rport, ruuid, pubkey, shortid, sni, fp, active = [x.strip() for x in p[:9]]
    if active != '1':
        continue
    if not ip or not rport.isdigit() or not ruuid or not pubkey:
        continue
    fp = fp or 'chrome'
    relay_tag = "relay-out"
    outbounds.insert(0, {
        "tag":      relay_tag,
        "protocol": "vless",
        "settings": {
            "vnext": [{
                "address": ip,
                "port":    int(rport),
                "users": [{
                    "id":         ruuid,
                    "flow":       "xtls-rprx-vision",
                    "encryption": "none"
                }]
            }]
        },
        "streamSettings": {
            "network":  "tcp",
            "security": "reality",
            "realitySettings": {
                "fingerprint": fp,
                "serverName":  sni,
                "publicKey":   pubkey,
                "shortId":     shortid
            }
        }
    })
    rules.append({
        "type":        "field",
        "network":     "tcp,udp",
        "outboundTag": relay_tag
    })
    default_out = relay_tag
    break  # 只用第一条激活的

config = {
    "log": {
        "loglevel": "warning",
        "access":   "{}/access.log".format(log_dir),
        "error":    "{}/error.log".format(log_dir)
    },
    "inbounds":  inbounds,
    "outbounds": outbounds,
    "routing": {
        "domainStrategy":     "IPIfNonMatch",
        "defaultOutboundTag": default_out,
        "rules":              rules
    }
}

print(json.dumps(config, indent=2, ensure_ascii=False))
PYEOF
}

# 重写 regen_config 使用新的 heredoc 方式
regen_config() {
    log_step "生成 Xray 配置文件..."
    mkdir -p "$XRAY_ETC" 2>/dev/null || true
    fix_log_perms

    if [ -z "$PYTHON" ]; then
        ensure_python
    fi
    if [ -z "$PYTHON" ]; then
        log_error "Python 不可用，无法生成配置"
        return 1
    fi

    local cfg
    cfg=$(gen_config_python "$NODE_DB" "$RELAY_DB" "$XRAY_LOG_DIR")
    local py_exit=$?

    if [ $py_exit -ne 0 ] || [ -z "$cfg" ]; then
        log_error "配置生成失败（Python 退出码: $py_exit）"
        return 1
    fi

    printf '%s\n' "$cfg" > "$XRAY_CONFIG" || {
        log_error "无法写入 $XRAY_CONFIG"
        return 1
    }

    local test_out
    test_out=$("$XRAY_BIN" run -test -config "$XRAY_CONFIG" 2>&1)
    if [ $? -ne 0 ]; then
        log_error "Xray 配置验证失败:"
        echo "$test_out"
        log_error "生成的配置:"
        cat "$XRAY_CONFIG"
        return 1
    fi

    log_success "Xray 配置验证通过"
    return 0
}

# ==============================================================
# 服务控制
# ==============================================================
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
    fix_log_perms

    if [ "$SVC_MGR" = "systemd" ]; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable xray >/dev/null 2>&1 || true
        systemctl restart xray 2>/dev/null || true
        sleep 2
        if systemctl is-active --quiet xray 2>/dev/null; then
            log_success "Xray 服务运行中"
            return 0
        else
            log_error "Xray 启动失败，错误日志："
            journalctl -u xray -n 40 --no-pager 2>/dev/null || \
                cat "$XRAY_LOG_DIR/error.log" 2>/dev/null || true
            return 1
        fi
    else
        rc-update add xray default >/dev/null 2>&1 || true
        /etc/init.d/xray restart 2>/dev/null || true
        sleep 2
        if /etc/init.d/xray status 2>/dev/null | grep -q "started"; then
            log_success "Xray 服务运行中"
            return 0
        else
            log_error "Xray 启动失败，错误日志："
            tail -n 30 "$XRAY_LOG_DIR/error.log" 2>/dev/null || true
            return 1
        fi
    fi
}

stop_xray() {
    if [ "$SVC_MGR" = "systemd" ]; then
        systemctl stop xray 2>/dev/null || true
    else
        /etc/init.d/xray stop 2>/dev/null || true
    fi
    log_info "Xray 已停止"
}

# ==============================================================
# 防火墙
# ==============================================================
allow_port() {
    local port="$1"
    if cmd_exists ufw; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw allow "$port"/tcp >/dev/null 2>&1 || true
            ufw allow "$port"/udp >/dev/null 2>&1 || true
        fi
    fi
    if cmd_exists iptables; then
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        ip6tables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
            ip6tables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
    fi
    if cmd_exists firewall-cmd; then
        firewall-cmd --permanent --add-port="$port"/tcp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

# ==============================================================
# URL 编码 / URI 生成
# ==============================================================
urlencode() {
    local str="$1"
    local encoded=""
    local i c
    for i in $(seq 0 $(( ${#str} - 1 ))); do
        c="${str:$i:1}"
        case "$c" in
            [-_.~a-zA-Z0-9]) encoded="${encoded}${c}" ;;
            *) encoded="${encoded}$(printf '%%%02X' "'$c")" ;;
        esac
    done
    echo "$encoded"
}

make_uri() {
    local uuid="$1" ip="$2" port="$3" sni="$4" pbk="$5" sid="$6" name="$7" fp="$8" is_v6="${9:-0}"
    local enc_name host
    enc_name=$(urlencode "$name")
    host="$ip"
    [ "$is_v6" = "1" ] && host="[${ip}]"
    echo "vless://${uuid}@${host}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=${fp}&pbk=${pbk}&sid=${sid}&type=tcp&headerType=none#${enc_name}"
}

# ==============================================================
# ══ 本机节点管理 ═══════════════════════════════════════════════
# ==============================================================

add_node() {
    log_title "添加本机 VLESS+Reality 节点"

    if [ ! -x "$XRAY_BIN" ]; then
        log_warn "Xray 未安装，开始自动安装..."
        system_init
        install_xray || { log_error "Xray 安装失败，无法继续"; return 1; }
    fi

    local name
    read -rp "节点名称 [回车=自动]: " name
    [ -z "$name" ] && name="VLESS-$(date +%Y%m%d-%H%M%S)"

    local port
    while true; do
        read -rp "监听端口 [回车=443]: " port
        [ -z "$port" ] && port=443
        case "$port" in
            ''|*[!0-9]*) log_error "端口必须是数字"; continue ;;
        esac
        if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            log_error "端口范围 1-65535"; continue
        fi
        break
    done

    local sni
    read -rp "SNI 伪装域名 [回车=www.cloudflare.com]: " sni
    [ -z "$sni" ] && sni="www.cloudflare.com"

    echo "可用指纹: chrome  firefox  safari  ios  android  edge"
    local fp
    read -rp "Fingerprint [回车=chrome]: " fp
    [ -z "$fp" ] && fp="chrome"

    log_step "生成 X25519 密钥对..."
    local key_out
    key_out=$("$XRAY_BIN" x25519 2>&1)
    parse_xray_keys "$key_out" || return 1
    local priv="$PARSED_PRIV" pub="$PARSED_PUB"

    local uuid sid
    uuid=$(gen_uuid)
    sid=$(openssl rand -hex 8 2>/dev/null || head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')

    log_info "UUID:       $uuid"
    log_info "Public Key: $pub"
    log_info "Short ID:   $sid"

    printf '%s|%s|%s|%s|%s|%s|%s\n' "$uuid" "$port" "$sni" "$sid" "$priv" "$name" "$fp" >> "$NODE_DB"

    allow_port "$port"

    if ! regen_config; then
        log_error "配置生成失败，已回滚"
        # 删除刚写入的行
        local tmp; tmp=$(mktemp)
        grep -v "^${uuid}|" "$NODE_DB" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$NODE_DB"
        return 1
    fi

    start_xray
    echo ""
    log_success "节点 '$name' 添加成功！"
    show_node_info "$uuid" "$port" "$sni" "$sid" "$priv" "$pub" "$name" "$fp"
}

show_node_info() {
    local uuid="$1" port="$2" sni="$3" sid="$4" priv="$5" pub="$6" name="$7" fp="${8:-chrome}"
    local ipv4 ipv6
    ipv4=$(get_ipv4)
    ipv6=$(get_ipv6)

    echo ""
    echo -e "${CYAN}════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  节点: $name${NC}"
    echo -e "${CYAN}════════════════════════════════════════════${NC}"
    echo "UUID:        $uuid"
    echo "Private Key: $priv"
    echo "Public Key:  $pub"
    echo "Short ID:    $sid"
    echo "SNI:         $sni"
    echo "Port:        $port"
    echo "Fingerprint: $fp"
    [ -n "$ipv4" ] && echo "本机 IPv4:   $ipv4"
    [ -n "$ipv6" ] && echo "本机 IPv6:   $ipv6"
    echo ""

    if [ -n "$ipv4" ]; then
        echo -e "${GREEN}── VLESS URI (IPv4) ────────────────────────${NC}"
        echo -e "${YELLOW}$(make_uri "$uuid" "$ipv4" "$port" "$sni" "$pub" "$sid" "$name" "$fp" "0")${NC}"
        echo ""
    fi
    if [ -n "$ipv6" ]; then
        echo -e "${GREEN}── VLESS URI (IPv6) ────────────────────────${NC}"
        echo -e "${YELLOW}$(make_uri "$uuid" "$ipv6" "$port" "$sni" "$pub" "$sid" "${name}-v6" "$fp" "1")${NC}"
        echo ""
    fi

    local server="${ipv4:-$ipv6}"
    if [ -n "$server" ]; then
        echo -e "${GREEN}── Clash Meta ──────────────────────────────${NC}"
        cat <<CLASH
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
CLASH
        echo ""
    fi
    echo -e "${CYAN}════════════════════════════════════════════${NC}"
}

list_nodes() {
    echo ""
    echo -e "${CYAN}── 本机节点列表 ────────────────────────────${NC}"
    if [ ! -s "$NODE_DB" ]; then
        echo "  (无节点)"
        return 0
    fi
    local idx=0
    while IFS='|' read -r uuid port sni sid priv name fp; do
        [ -z "$uuid" ] && continue
        case "$uuid" in '#'*) continue ;; esac
        idx=$(( idx + 1 ))
        echo "  [$idx] $name  端口:$port  SNI:$sni  UUID:${uuid:0:8}..."
    done < "$NODE_DB"
    [ "$idx" -eq 0 ] && echo "  (无节点)"
    return 0
}

pick_node() {
    list_nodes
    if [ ! -s "$NODE_DB" ]; then
        return 1
    fi
    local n
    read -rp "请输入序号: " n
    n=$(echo "$n" | tr -d ' ')
    case "$n" in
        ''|*[!0-9]*) log_error "序号无效"; return 1 ;;
    esac
    PICKED_LINE=$(awk -F'|' -v n="$n" '!/^#/ && NF>=7 {cnt++; if(cnt==n){print; exit}}' "$NODE_DB" 2>/dev/null || true)
    if [ -z "$PICKED_LINE" ]; then
        log_error "序号不存在"
        return 1
    fi
    return 0
}

view_node() {
    log_title "查看节点信息"
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
    done < "$NODE_DB"
}

export_nodes() {
    log_title "导出节点连接信息"
    mkdir -p "$BACKUP_DIR"
    local outfile="$BACKUP_DIR/export_$(date +%Y%m%d_%H%M%S).txt"
    local ipv4 ipv6
    ipv4=$(get_ipv4)
    ipv6=$(get_ipv6)
    {
        echo "# VPS Manager $SCRIPT_VERSION - 导出时间: $(date)"
        echo "# IPv4: ${ipv4:-N/A}  IPv6: ${ipv6:-N/A}"
        echo ""
        if [ -s "$NODE_DB" ]; then
            while IFS='|' read -r uuid port sni sid priv name fp; do
                [ -z "$uuid" ] && continue
                case "$uuid" in '#'*) continue ;; esac
                local pub
                pub=$(derive_pub "$priv")
                echo "## $name"
                [ -n "$ipv4" ] && make_uri "$uuid" "$ipv4" "$port" "$sni" "$pub" "$sid" "$name" "${fp:-chrome}" "0"
                [ -n "$ipv6" ] && make_uri "$uuid" "$ipv6" "$port" "$sni" "$pub" "$sid" "${name}-v6" "${fp:-chrome}" "1"
                echo ""
            done < "$NODE_DB"
        else
            echo "(无节点)"
        fi
    } > "$outfile"
    log_success "已导出到: $outfile"
    cat "$outfile"
}

delete_node() {
    log_title "删除节点"
    pick_node || return
    local uuid port sni sid priv name fp
    IFS='|' read -r uuid port sni sid priv name fp <<< "$PICKED_LINE"
    read -rp "确认删除节点 '$name'? [y/N]: " c
    [ "${c:-N}" != "y" ] && { log_info "已取消"; return; }
    local tmp; tmp=$(mktemp)
    grep -v "^${uuid}|" "$NODE_DB" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$NODE_DB"
    if regen_config; then
        start_xray
        log_success "节点 '$name' 已删除"
    else
        log_warn "节点已从数据库删除，但配置重新生成失败，请手动重启 Xray"
    fi
}

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
        log_error "Xray 未运行"
        read -rp "  尝试自动启动? [Y/n]: " yn
        if [ "${yn:-Y}" != "n" ]; then
            start_xray
            if xray_is_active; then
                log_success "Xray 已启动"
            else
                log_error "Xray 无法启动，请查看日志"
            fi
        fi
    fi

    log_step "2. 配置文件验证..."
    local tout
    tout=$("$XRAY_BIN" run -test -config "$XRAY_CONFIG" 2>&1)
    if [ $? -eq 0 ]; then
        log_success "配置文件验证通过"
    else
        log_error "配置文件验证失败:"
        echo "$tout" | head -10
    fi

    log_step "3. 端口 $port 监听检查..."
    if ss -tlnp 2>/dev/null | grep -q ":${port}[[:space:]]"; then
        log_success "端口 $port 正在监听"
    else
        log_warn "端口 $port 未检测到监听（容器环境可能正常，建议实际连接测试）"
    fi

    log_step "4. SNI 可达性测试 ($sni)..."
    local hc
    hc=$(curl -sI --max-time 5 "https://${sni}" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "0")
    case "$hc" in
        2*|3*) log_success "SNI $sni 可达 (HTTP $hc)" ;;
        *)     log_warn "SNI $sni 返回 $hc，建议更换伪装域名" ;;
    esac

    log_step "5. 当前路由模式..."
    local al
    al=$(awk -F'|' '!/^#/ && $9=="1" {print $1; exit}' "$RELAY_DB" 2>/dev/null || true)
    if [ -n "$al" ]; then
        local ai
        ai=$(awk -F'|' '!/^#/ && $9=="1" {print $2":"$3; exit}' "$RELAY_DB" 2>/dev/null || true)
        echo -e "  ${YELLOW}中转模式${NC}: 流量 → RFC:$port → IIJ:$ai"
    else
        echo -e "  ${GREEN}直连模式${NC}: 流量从本机直接出网"
    fi

    echo ""
    log_success "检测完成 - 节点: $name"
}

# ==============================================================
# ══ Xray 服务菜单 ══════════════════════════════════════════════
# ==============================================================
xray_menu() {
    while true; do
        log_title "Xray 服务管理"
        echo "  1) 查看状态"
        echo "  2) 重启"
        echo "  3) 停止"
        echo "  4) 启动"
        echo "  5) 查看日志（最近50行）"
        echo "  6) 实时日志（Ctrl+C 退出）"
        echo "  7) 强制修复（重写服务文件 + 修复权限 + 重启）"
        echo "  0) 返回"
        read -rp "请选择: " c
        case "${c:-}" in
            1) xray_status ;;
            2) start_xray ;;
            3) stop_xray ;;
            4) start_xray ;;
            5) xray_log 50 ;;
            6)
                echo "按 Ctrl+C 退出..."
                if [ "$SVC_MGR" = "systemd" ]; then
                    journalctl -u xray -f 2>/dev/null || true
                else
                    tail -f "$XRAY_LOG_DIR/error.log" 2>/dev/null || true
                fi
                ;;
            7)
                write_xray_service
                fix_log_perms
                regen_config && start_xray || true
                ;;
            0) break ;;
            *) log_warn "无效选项" ;;
        esac
    done
}

xray_status() {
    echo ""
    echo -e "${CYAN}── Xray 状态 ──────────────────────────────${NC}"
    if [ -x "$XRAY_BIN" ]; then
        echo "版本: $("$XRAY_BIN" version 2>&1 | head -1)"
    else
        echo -e "${RED}Xray 未安装${NC}"
    fi
    echo "配置: $XRAY_CONFIG"
    [ -f "$XRAY_CONFIG" ] && echo "  → 文件存在" || echo -e "  → ${RED}文件缺失${NC}"

    local drop_dir="/etc/systemd/system/xray.service.d"
    if [ -d "$drop_dir" ]; then
        echo -e "${YELLOW}警告: 存在 drop-in 目录 $drop_dir，可能导致启动失败，建议选7强制修复${NC}"
    fi

    echo ""
    if [ "$SVC_MGR" = "systemd" ]; then
        systemctl --no-pager status xray 2>/dev/null || echo "（服务未安装或已停止）"
    else
        /etc/init.d/xray status 2>/dev/null || echo "（服务未安装或已停止）"
    fi

    echo ""
    echo "当前路由模式:"
    local al
    al=$(awk -F'|' '!/^#/ && $9=="1" {print $1; exit}' "$RELAY_DB" 2>/dev/null || true)
    if [ -n "$al" ]; then
        local ai
        ai=$(awk -F'|' '!/^#/ && $9=="1" {print $2":"$3; exit}' "$RELAY_DB" 2>/dev/null || true)
        echo -e "  ${YELLOW}中转模式${NC} → $al ($ai)"
    else
        echo -e "  ${GREEN}直连模式${NC}"
    fi

    echo ""
    echo "端口监听:"
    ss -tlnp 2>/dev/null | grep -E "xray|443" || echo "  （无相关监听）"
}

xray_log() {
    local n="${1:-50}"
    if [ "$SVC_MGR" = "systemd" ]; then
        journalctl -u xray -n "$n" --no-pager 2>/dev/null || \
            tail -n "$n" "$XRAY_LOG_DIR/error.log" 2>/dev/null || \
            log_warn "日志不可读"
    else
        tail -n "$n" "$XRAY_LOG_DIR/error.log" 2>/dev/null || log_warn "日志不可读"
    fi
}

# ==============================================================
# ══ 中转落地管理 ═══════════════════════════════════════════════
# ==============================================================

show_relay_mode() {
    local al
    al=$(awk -F'|' '!/^#/ && $9=="1" {print $1; exit}' "$RELAY_DB" 2>/dev/null || true)
    if [ -n "$al" ]; then
        local ai
        ai=$(awk -F'|' '!/^#/ && $9=="1" {print $2":"$3; exit}' "$RELAY_DB" 2>/dev/null || true)
        echo -e "  当前模式: ${YELLOW}中转${NC} → $al ($ai)"
    else
        echo -e "  当前模式: ${GREEN}直连${NC}（流量从本机直接出网）"
    fi
}

list_relays() {
    echo ""
    echo -e "${CYAN}── 落地节点列表 ────────────────────────────${NC}"
    show_relay_mode
    echo ""
    if [ ! -s "$RELAY_DB" ]; then
        echo "  (无落地节点)"
        return 0
    fi
    local idx=0
    while IFS='|' read -r label ip port uuid pubkey shortid sni fp active; do
        [ -z "$label" ] && continue
        case "$label" in '#'*) continue ;; esac
        idx=$(( idx + 1 ))
        local mark="      "
        [ "${active:-0}" = "1" ] && mark="${GREEN}[激活]${NC}"
        echo -e "  [$idx] ${mark} $label  ${ip}:${port}  SNI:$sni"
    done < "$RELAY_DB"
    [ "$idx" -eq 0 ] && echo "  (无落地节点)"
    echo ""
}

add_relay() {
    log_title "添加落地节点"
    echo ""
    echo "请填入 IIJ(落地VPS) 上的 VLESS+Reality 节点信息"
    echo "（在 IIJ 上运行本脚本 → 查看节点信息 可以找到这些值）"
    echo ""

    local label
    read -rp "备注名称 [如: IIJ-Tokyo]: " label
    [ -z "$label" ] && label="relay-$(date +%s)"

    local ip
    read -rp "IIJ 的 IP 地址: " ip
    ip=$(echo "$ip" | tr -d ' ')
    [ -z "$ip" ] && { log_error "IP 不能为空"; return 1; }

    local port
    while true; do
        read -rp "IIJ VLESS 端口 [回车=443]: " port
        [ -z "$port" ] && port=443
        case "$port" in ''|*[!0-9]*) log_error "端口必须是数字"; continue ;; esac
        [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && break
        log_error "端口范围 1-65535"
    done

    local uuid
    read -rp "IIJ 节点 UUID: " uuid
    uuid=$(echo "$uuid" | tr -d ' ')
    [ -z "$uuid" ] && { log_error "UUID 不能为空"; return 1; }

    local pubkey
    read -rp "IIJ 节点 Public Key: " pubkey
    pubkey=$(echo "$pubkey" | tr -d ' ')
    [ -z "$pubkey" ] && { log_error "Public Key 不能为空"; return 1; }

    local shortid
    read -rp "IIJ 节点 Short ID: " shortid
    shortid=$(echo "$shortid" | tr -d ' ')
    [ -z "$shortid" ] && { log_error "Short ID 不能为空"; return 1; }

    local sni
    read -rp "IIJ 节点 SNI [如: ascii.jp]: " sni
    sni=$(echo "$sni" | tr -d ' ')
    [ -z "$sni" ] && sni="www.cloudflare.com"

    echo "可用指纹: chrome  firefox  safari  ios  android  edge"
    local fp
    read -rp "Fingerprint [回车=chrome]: " fp
    [ -z "$fp" ] && fp="chrome"

    # 连通性测试
    log_step "测试 TCP 连通性 → ${ip}:${port}..."
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${ip}/${port}" >/dev/null 2>&1; then
        log_success "TCP 连通正常"
    else
        log_warn "TCP 连通失败，请确认 IIJ 防火墙和节点是否正常运行"
        read -rp "仍要继续? [y/N]: " cc
        [ "${cc:-N}" != "y" ] && return 0
    fi

    # 首条自动激活，否则询问
    local active=0
    if [ ! -s "$RELAY_DB" ]; then
        active=1
        log_info "首条落地，自动激活 → 切换为中转模式"
    else
        read -rp "立即激活此落地（切换中转模式）? [y/N]: " act
        [ "${act:-N}" = "y" ] && active=1
        [ "$active" = "1" ] && _deactivate_all
    fi

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$label" "$ip" "$port" "$uuid" "$pubkey" "$shortid" "$sni" "$fp" "$active" \
        >> "$RELAY_DB"

    if regen_config; then
        start_xray
    else
        log_warn "配置生成失败，节点已保存但未生效，请稍后手动重试"
    fi

    if [ "$active" = "1" ]; then
        log_success "已添加并激活: $label → ${ip}:${port}"
        echo ""
        echo -e "${YELLOW}流量路径: 客户端 → 本机:$(awk -F'|' '!/^#/ && NF>=7 {print $2; exit}' "$NODE_DB" 2>/dev/null || echo 443) → ${ip}:${port} → 目标网站${NC}"
    else
        log_success "已添加（未激活）: $label"
    fi
    list_relays
}

_deactivate_all() {
    [ ! -s "$RELAY_DB" ] && return
    local tmp; tmp=$(mktemp)
    awk -F'|' 'BEGIN{OFS="|"} /^#/{print;next} NF>=9{$9=0; print}' "$RELAY_DB" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$RELAY_DB"
}

switch_relay() {
    log_title "切换路由模式"
    list_relays

    echo "输入序号 → 激活该落地（切换为中转模式）"
    echo "输入 0   → 取消所有激活（切换为直连模式）"
    echo ""
    read -rp "请输入: " n
    n=$(echo "$n" | tr -d ' ')

    if [ "$n" = "0" ]; then
        _deactivate_all
        if regen_config; then
            start_xray
            log_success "已切换为直连模式"
        fi
        show_relay_mode
        return
    fi

    case "$n" in ''|*[!0-9]*) log_error "序号无效"; return 1 ;; esac

    local target
    target=$(awk -F'|' -v n="$n" '!/^#/ && NF>=9 {cnt++; if(cnt==n){print; exit}}' "$RELAY_DB" 2>/dev/null || true)
    [ -z "$target" ] && { log_error "序号不存在"; return 1; }

    local label ip port
    IFS='|' read -r label ip port _ _ _ _ _ _ <<< "$target"

    local tmp; tmp=$(mktemp)
    awk -F'|' -v n="$n" 'BEGIN{OFS="|"; cnt=0}
        /^#/{print; next}
        NF>=9{cnt++; if(cnt==n) $9=1; else $9=0; print}' \
        "$RELAY_DB" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$RELAY_DB"

    if regen_config; then
        start_xray
        log_success "已切换为中转模式 → $label (${ip}:${port})"
        local lp
        lp=$(awk -F'|' '!/^#/ && NF>=7 {print $2; exit}' "$NODE_DB" 2>/dev/null || echo "443")
        echo -e "${YELLOW}流量: 客户端 → 本机:${lp} → ${ip}:${port} → 目标网站${NC}"
    fi
    list_relays
}

delete_relay() {
    log_title "删除落地节点"
    list_relays
    [ ! -s "$RELAY_DB" ] && return

    local n
    read -rp "请输入要删除的序号: " n
    n=$(echo "$n" | tr -d ' ')
    case "$n" in ''|*[!0-9]*) log_error "序号无效"; return 1 ;; esac

    local tmp; tmp=$(mktemp)
    awk -F'|' -v n="$n" '!/^#/ && NF>=9 {cnt++; if(cnt!=n) print}' \
        "$RELAY_DB" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$RELAY_DB"

    if regen_config; then
        start_xray
    fi
    log_success "已删除序号 $n"
    list_relays
}

edit_relay() {
    log_title "修改落地节点"
    list_relays
    [ ! -s "$RELAY_DB" ] && return

    local n
    read -rp "请输入要修改的序号: " n
    n=$(echo "$n" | tr -d ' ')
    case "$n" in ''|*[!0-9]*) log_error "序号无效"; return 1 ;; esac

    local old
    old=$(awk -F'|' -v n="$n" '!/^#/ && NF>=9 {cnt++; if(cnt==n){print; exit}}' "$RELAY_DB" 2>/dev/null || true)
    [ -z "$old" ] && { log_error "序号不存在"; return 1; }

    local ol oi op ou opk osi os of oa
    IFS='|' read -r ol oi op ou opk osi os of oa <<< "$old"
    echo "当前: $ol | ${oi}:${op} | UUID:${ou:0:8}... | SNI:$os"
    echo ""

    local nl ni np nu npk nsi ns nf
    read -rp "名称       [保持: $ol]: " nl;  [ -z "$nl"  ] && nl="$ol"
    read -rp "IIJ IP     [保持: $oi]: " ni;  [ -z "$ni"  ] && ni="$oi"
    read -rp "端口       [保持: $op]: " np;  [ -z "$np"  ] && np="$op"
    read -rp "UUID       [保持: ...]: " nu;  [ -z "$nu"  ] && nu="$ou"
    read -rp "Public Key [保持: ...]: " npk; [ -z "$npk" ] && npk="$opk"
    read -rp "Short ID   [保持: $osi]: " nsi; [ -z "$nsi" ] && nsi="$osi"
    read -rp "SNI        [保持: $os]: " ns;  [ -z "$ns"  ] && ns="$os"
    read -rp "Fingerprint[保持: $of]: " nf;  [ -z "$nf"  ] && nf="$of"

    local tmp; tmp=$(mktemp)
    awk -F'|' -v n="$n" \
        -v a1="$nl" -v a2="$ni" -v a3="$np" -v a4="$nu" \
        -v a5="$npk" -v a6="$nsi" -v a7="$ns" -v a8="$nf" \
        'BEGIN{OFS="|"; cnt=0}
         /^#/{print; next}
         NF>=9{
             cnt++
             if(cnt==n){$1=a1;$2=a2;$3=a3;$4=a4;$5=a5;$6=a6;$7=a7;$8=a8}
             print
         }' "$RELAY_DB" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$RELAY_DB"

    if regen_config; then
        start_xray
        log_success "已修改"
    fi
    list_relays
}

test_relay() {
    log_title "落地链路检测"
    if [ ! -s "$RELAY_DB" ]; then
        echo "  (无落地节点)"
        return
    fi

    while IFS='|' read -r label ip port uuid pubkey shortid sni fp active; do
        [ -z "$label" ] && continue
        case "$label" in '#'*) continue ;; esac
        local mark=""
        [ "${active:-0}" = "1" ] && mark="${GREEN}[激活]${NC}"
        echo ""
        echo -e "── $label $mark  ${ip}:${port}  SNI:$sni"

        if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${ip}/${port}" >/dev/null 2>&1; then
            log_success "  TCP 连通: ${ip}:${port} OK"
        else
            log_error   "  TCP 连通: ${ip}:${port} FAIL"
        fi

        local hc
        hc=$(curl -sI --max-time 5 "https://${sni}" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "0")
        case "$hc" in
            2*|3*) log_success "  SNI $sni 可达 (HTTP $hc)" ;;
            *)     log_warn    "  SNI $sni 返回 $hc" ;;
        esac
    done < "$RELAY_DB"
    echo ""
}

relay_menu() {
    while true; do
        log_title "中转落地管理"
        show_relay_mode
        echo ""
        echo "  1) 添加落地节点（填入 IIJ 的 VLESS 信息）"
        echo "  2) 查看所有落地节点"
        echo "  3) 切换模式（输入序号=中转 / 输入0=直连）"
        echo "  4) 修改落地节点"
        echo "  5) 删除落地节点"
        echo "  6) 落地链路检测"
        echo "  0) 返回主菜单"
        read -rp "请选择: " c
        case "${c:-}" in
            1) add_relay ;;
            2) list_relays ;;
            3) switch_relay ;;
            4) edit_relay ;;
            5) delete_relay ;;
            6) test_relay ;;
            0) break ;;
            *) log_warn "无效选项" ;;
        esac
    done
}

# ==============================================================
# 系统总览
# ==============================================================
overview() {
    log_title "系统总览"
    local ipv4 ipv6
    ipv4=$(get_ipv4)
    ipv6=$(get_ipv6)

    echo "━━ 服务器 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "OS:   $OS_TYPE | 内核: $(uname -r 2>/dev/null || echo N/A)"
    echo "内存: ${TOTAL_MEM}MB  磁盘: ${TOTAL_DISK}GB"
    echo "IPv4: ${ipv4:-N/A}"
    echo "IPv6: ${ipv6:-N/A}"
    echo ""
    echo "━━ Xray ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ -x "$XRAY_BIN" ]; then
        echo "版本: $("$XRAY_BIN" version 2>&1 | head -1)"
        xray_is_active \
            && echo -e "服务: ${GREEN}运行中${NC}" \
            || echo -e "服务: ${RED}已停止${NC}"
    else
        echo -e "${RED}Xray 未安装${NC}"
    fi
    echo ""
    echo "━━ 路由模式 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    show_relay_mode
    echo ""
    echo "━━ 本机节点 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    list_nodes
    echo ""
    echo "━━ 落地节点 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    list_relays
    echo ""
    echo "━━ 端口监听 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ss -tlnp 2>/dev/null | grep -E "LISTEN" | head -10 || echo "  无法获取"
    echo ""
}

# ==============================================================
# 一键安装
# ==============================================================
full_install() {
    log_title "一键初始化安装"
    system_init
    install_xray || true
    log_success "初始化完成！请通过菜单添加节点。"
    echo ""
    echo "快速开始："
    echo "  选 1 → 添加本机 VLESS 节点（直连模式）"
    echo "  选 8 → 添加落地节点并激活（切换中转模式）"
}

# ==============================================================
# ══ 主菜单 ═════════════════════════════════════════════════════
# ==============================================================
main_menu() {
    need_root
    detect_os
    ensure_python

    mkdir -p "$DATA_DIR" "$BACKUP_DIR" "$XRAY_LOG_DIR" "$XRAY_ETC" 2>/dev/null || true
    touch "$NODE_DB" "$RELAY_DB" 2>/dev/null || true

    while true; do
        echo ""
        echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║   VPS 一键管理  ${SCRIPT_VERSION}                      ║${NC}"
        echo -e "${BLUE}║   Xray VLESS+Reality  直连 / 链式中转         ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
        echo ""
        show_relay_mode
        echo ""
        echo -e "${CYAN}── 本机节点 ────────────────────────────────────${NC}"
        echo "   1) 添加节点"
        echo "   2) 删除节点"
        echo "   3) 查看节点信息 & URI"
        echo "   4) 查看所有节点信息 & URI"
        echo "   5) 导出节点到文件"
        echo "   6) 检测节点状态"
        echo ""
        echo -e "${CYAN}── Xray 服务 ───────────────────────────────────${NC}"
        echo "   7) Xray 服务管理（状态/重启/日志/修复）"
        echo ""
        echo -e "${CYAN}── 中转落地 ────────────────────────────────────${NC}"
        echo "   8) 中转落地管理（添加/切换/检测）"
        echo "      ↑ 不配置落地则为纯直连模式，配置后可随时切换"
        echo ""
        echo -e "${CYAN}── 系统 ────────────────────────────────────────${NC}"
        echo "   9) 系统总览"
        echo "  10) 一键初始化安装"
        echo "   0) 退出"
        echo ""
        read -rp "请选择 [0-10]: " choice
        choice=$(echo "${choice:-}" | tr -d ' ')
        case "$choice" in
            1)  add_node ;;
            2)  delete_node ;;
            3)  view_node ;;
            4)  view_all_nodes ;;
            5)  export_nodes ;;
            6)  test_node ;;
            7)  xray_menu ;;
            8)  relay_menu ;;
            9)  overview ;;
            10) full_install ;;
            0)  log_info "退出。"; exit 0 ;;
            *)  log_warn "无效选项，请输入 0-10" ;;
        esac
    done
}

# ── 入口 ──────────────────────────────────────────────────────
main_menu
