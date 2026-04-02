#!/usr/bin/env bash
# ==============================================================
# VPS 一键管理脚本
# 功能: Xray VLESS+Reality+Vision + Realm 端口转发 (443端口复用)
# 版本: v1.0.0
# 支持: Ubuntu/Debian/Alpine (IPv4 / IPv6-only / 双栈)
# 443端口复用方案: REALITY SNI分流 (无性能损耗, 零额外延迟)
# ==============================================================

SCRIPT_VERSION="v1.0.0"
set -euo pipefail

# ── 颜色 ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_success() { echo -e "${CYAN}[OK]${NC}    $*"; }
log_step()    { echo -e "${BLUE}[STEP]${NC}  $*"; }
log_title()   { echo -e "\n${MAGENTA}══════════════════════════════════════════════${NC}"; echo -e "${MAGENTA}  $*${NC}"; echo -e "${MAGENTA}══════════════════════════════════════════════${NC}\n"; }

# ── 全局路径 ──────────────────────────────────────────────────
XRAY_BIN="/usr/local/bin/xray"
XRAY_ETC="/usr/local/etc/xray"
XRAY_CONFIG_DIR="$XRAY_ETC/conf"          # 多节点：每节点一个 json
XRAY_MAIN_CONFIG="$XRAY_ETC/config.json"  # 主配置（合并所有节点）
XRAY_LOG_DIR="/var/log/xray"

REALM_BIN="/usr/local/bin/realm"
REALM_ETC="/etc/realm"
REALM_CFG="$REALM_ETC/config.toml"
REALM_EP_DB="$REALM_ETC/endpoints.db"    # 每行: listen_port remote_host remote_port label

DATA_DIR="/etc/vps_manager"              # 节点数据库
NODE_DB="$DATA_DIR/nodes.db"            # 每行: uuid port sni short_id private_key name
BACKUP_DIR="/root/vps_manager_backups"

# ── 系统变量（detect_os 填充）──────────────────────────────────
OS_TYPE=""      # ubuntu / alpine
PKG_MGR=""      # apt / apk
SVC_MGR=""      # systemd / openrc
TOTAL_MEM=0
TOTAL_DISK=0

# ==============================================================
# 环境检测
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
    log_info "OS: $OS_TYPE | 内存: ${TOTAL_MEM}MB | 磁盘: ${TOTAL_DISK}GB | 服务管理: $SVC_MGR"
}

need_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        log_error "请以 root 权限运行：sudo $0"
        exit 1
    fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# 安装缺失依赖（幂等）
ensure_deps() {
    local pkgs=("$@")
    local missing=()
    for p in "${pkgs[@]}"; do
        cmd_exists "$p" || missing+=("$p")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0

    log_info "安装依赖: ${missing[*]}"
    if [[ "$PKG_MGR" == "apt" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
    else
        apk add --no-cache -q "${missing[@]}"
    fi
}

# ==============================================================
# 网络 / IP 检测
# ==============================================================
get_ipv4() {
    local ip
    ip=$(curl -s -4 --max-time 8 https://api4.ipify.org 2>/dev/null \
      || curl -s -4 --max-time 8 https://ifconfig.me 2>/dev/null \
      || curl -s -4 --max-time 8 https://icanhazip.com 2>/dev/null || true)
    echo "${ip:-}"
}

get_ipv6() {
    local ip
    ip=$(curl -s -6 --max-time 8 https://api6.ipify.org 2>/dev/null \
      || curl -s -6 --max-time 8 https://ifconfig.me 2>/dev/null \
      || curl -s -6 --max-time 8 https://icanhazip.com 2>/dev/null || true)
    echo "${ip:-}"
}

check_github_reachable() {
    curl -sI --max-time 6 https://api.github.com >/dev/null 2>&1
}

# GitHub 下载（自动 fallback 到 ghp.ci 代理）
gh_download() {
    local url="$1" output="$2"
    if check_github_reachable; then
        curl -fL --retry 3 --retry-delay 2 -o "$output" "$url"
    else
        log_warn "GitHub 不可直连，切换代理下载..."
        curl -fL --retry 3 --retry-delay 2 -o "$output" "https://ghp.ci/$url"
    fi
}

# ==============================================================
# 密钥解析（兼容 Xray v1.x / v26.x 所有已知输出格式）
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

derive_public_key() {
    local priv="$1"
    local out
    out=$("$XRAY_BIN" x25519 -i "$priv" 2>&1)
    echo "$out" | grep -iE "(^public|publickey)" | awk '{print $NF}' | tr -d ' \r\n'
}

# ==============================================================
# UUID 生成
# ==============================================================
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
# Swap / BBR（系统优化，容器友好）
# ==============================================================
setup_swap() {
    local target_mb="$1"
    [[ -f /swapfile ]] && { swapoff /swapfile 2>/dev/null || true; rm -f /swapfile; }
    local avail_kb
    avail_kb=$(df -k / | awk 'NR==2{print $4}')
    local need_kb=$(( target_mb * 1024 ))
    if (( avail_kb < need_kb + 512*1024 )); then
        log_warn "磁盘空间不足（剩余 $((avail_kb/1024))MB），跳过 Swap 创建"
        return
    fi
    fallocate -l "${target_mb}M" /swapfile 2>/dev/null \
      || dd if=/dev/zero of=/swapfile bs=1M count="$target_mb" 2>/dev/null || { log_warn "Swap 文件创建失败，跳过"; return; }
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1 || { rm -f /swapfile; return; }
    if swapon /swapfile 2>/dev/null; then
        grep -q '/swapfile' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        log_success "Swap ${target_mb}MB 已启用"
    else
        log_warn "当前环境（LXC/容器）不支持 Swap，已跳过"
        rm -f /swapfile
    fi
}

enable_bbr() {
    touch /etc/sysctl.conf
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    if sysctl -p >/dev/null 2>&1; then
        log_success "BBR 已启用"
    else
        log_warn "容器环境，BBR 无法修改内核参数，已跳过"
    fi
}

# ==============================================================
# 系统初始化
# ==============================================================
system_init() {
    log_step "系统初始化..."
    if [[ "$OS_TYPE" == "ubuntu" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            curl wget unzip openssl coreutils iproute2 iptables \
            net-tools grep sed awk util-linux || true
        # 按磁盘大小决定 swap
        if (( TOTAL_DISK >= 10 )); then
            setup_swap 1024
        elif (( TOTAL_DISK >= 5 )); then
            setup_swap 512
        else
            log_warn "磁盘 <5GB，跳过 Swap"
        fi
    else
        apk update -q
        apk add --no-cache -q bash curl wget unzip openssl coreutils \
            iproute2 iptables ip6tables grep sed util-linux
        (( TOTAL_DISK >= 3 )) && setup_swap 256 || log_warn "磁盘 <3GB，跳过 Swap"
    fi
    enable_bbr
    mkdir -p "$DATA_DIR" "$BACKUP_DIR" "$XRAY_LOG_DIR" "$XRAY_CONFIG_DIR" "$REALM_ETC"
    touch "$NODE_DB" "$REALM_EP_DB"
    chmod 600 "$NODE_DB" "$REALM_EP_DB"
    log_success "系统初始化完成"
}

# ==============================================================
# ── XRAY 安装 ─────────────────────────────────────────────────
# ==============================================================
install_xray() {
    if [[ -x "$XRAY_BIN" ]]; then
        log_info "Xray 已安装：$($XRAY_BIN version 2>&1 | head -1)"
        return 0
    fi
    log_step "安装 Xray-core..."
    if [[ "$OS_TYPE" == "ubuntu" ]]; then
        _install_xray_ubuntu
    else
        _install_xray_alpine
    fi
}

_install_xray_ubuntu() {
    local script_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
    if check_github_reachable; then
        bash -c "$(curl -fsSL "$script_url")" @ install
    else
        bash -c "$(curl -fsSL "https://ghp.ci/$script_url")" @ install
    fi
    [[ -x "$XRAY_BIN" ]] || { log_error "Xray 安装失败"; exit 1; }
}

_install_xray_alpine() {
    local tag arch asset url tmp
    tag=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)
    [[ -z "$tag" ]] && tag="v1.8.4" && log_warn "版本获取失败，使用 $tag"

    case "$(uname -m)" in
        x86_64)        arch="64" ;;
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

    # OpenRC 服务
    cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run
name="xray"
description="Xray Service"
command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/run/xray.pid"
output_log="/var/log/xray/access.log"
error_log="/var/log/xray/error.log"
depend() { need net; }
start_pre() { checkpath --directory --mode 0755 /var/log/xray; }
EOF
    chmod +x /etc/init.d/xray
}

# ── Xray systemd 服务（Ubuntu，官方脚本已创建，此处确保正确）──
ensure_xray_service_ubuntu() {
    if [[ ! -f /etc/systemd/system/xray.service ]] && [[ ! -f /lib/systemd/system/xray.service ]]; then
        cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$XRAY_BIN run -config $XRAY_MAIN_CONFIG
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi
}

# ==============================================================
# ── REALM 安装 ────────────────────────────────────────────────
# ==============================================================
install_realm() {
    if [[ -x "$REALM_BIN" ]]; then
        log_info "Realm 已安装"
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
        *) log_error "不支持的架构：$(uname -m)"; return 1 ;;
    esac
    asset="realm-${arch}.tar.gz"
    url="https://github.com/zhboner/realm/releases/download/${tag}/${asset}"

    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    gh_download "$url" "$tmp/$asset"
    tar -xzf "$tmp/$asset" -C "$tmp"
    install -m 755 "$tmp/realm" "$REALM_BIN"
    log_success "Realm $tag 安装完成"

    _write_realm_service
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable realm.service 2>/dev/null || rc-update add realm default 2>/dev/null || true
}

_write_realm_service() {
    if [[ "$SVC_MGR" == "systemd" ]]; then
        cat > /etc/systemd/system/realm.service <<EOF
[Unit]
Description=Realm Relay Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$REALM_ETC
ExecStart=$REALM_BIN -c $REALM_CFG
Restart=on-failure
RestartSec=2s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    else
        cat > /etc/init.d/realm <<'EOF'
#!/sbin/openrc-run
name="realm"
description="Realm Relay Service"
command="/usr/local/bin/realm"
command_args="-c /etc/realm/config.toml"
command_background="yes"
pidfile="/run/realm.pid"
depend() { need net; }
EOF
        chmod +x /etc/init.d/realm
        rc-update add realm default 2>/dev/null || true
    fi
}

# ==============================================================
# ══ 核心：443 端口复用架构 ══════════════════════════════════════
#
# 方案：Xray 监听 443，通过 REALITY 的 dest（目标）字段将非代理
#       流量直接回落到真实目标（如 www.cloudflare.com:443）。
#       Realm 监听非 443 端口（如 10443），内部转发到落地机器。
#
# 端口复用策略（入站统一 443）：
#   - VLESS+Reality 节点: Xray 直接监听 443，多节点通过 UUID 区分
#   - Realm 转发入站 443 方案: 用 Xray 的 routing + outbound 实现
#     将特定 SNI 的流量路由到 Realm 的本地端口（内部 loopback）
#     Realm 再转发到落地机器，这样对客户端而言只需要 443 端口
#
# 实现细节：
#   Xray 作为唯一的 443 监听者。
#   "Realm转发入站" = Xray routing 识别 SNI → outbound 发到
#   本地 Realm 监听端口（127.0.0.1:REALM_LOCAL_PORT）→ Realm 转出。
#
# ==============================================================

# 节点数据库字段: uuid|port|sni|short_id|private_key|name|fingerprint
# Realm数据库字段: listen_port|remote_host|remote_port|label|xray_sni|xray_local_port
# （当 listen_port=443 时，由 Xray routing + Realm 实现 443 复用）

# ── 重新生成 Xray 主配置（合并所有节点 + Realm 路由）──────────
regen_xray_config() {
    log_step "重新生成 Xray 主配置..."
    mkdir -p "$XRAY_ETC"

    # 收集节点
    local inbounds="[]"
    local outbounds='[{"protocol":"freedom","tag":"direct","settings":{}},{"protocol":"blackhole","tag":"block"}]'
    local routing_rules='[{"type":"field","protocol":["bittorrent"],"outboundTag":"block"}]'

    local inbounds_arr=()
    local realm_outbounds=()
    local realm_rules=()

    # ── 从 NODE_DB 读取所有 VLESS 节点 ──────────────────────────
    if [[ -s "$NODE_DB" ]]; then
        while IFS='|' read -r uuid port sni short_id private_key name fingerprint || [[ -n "$uuid" ]]; do
            [[ -z "$uuid" ]] && continue
            [[ "${uuid:0:1}" == "#" ]] && continue
            local fp="${fingerprint:-firefox}"
            inbounds_arr+=("$(cat <<EOF
    {
      "tag": "vless-in-${port}-$(echo "$uuid" | cut -c1-8)",
      "port": ${port},
      "listen": "::",
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${uuid}", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${sni}:443",
          "serverNames": ["${sni}"],
          "privateKey": "${private_key}",
          "shortIds": ["${short_id}"]
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
    }
EOF
)")
        done < "$NODE_DB"
    fi

    # ── 从 REALM_EP_DB 读取 443 复用的 Realm 转发 ───────────────
    # 字段: listen_port|remote_host|remote_port|label|xray_sni|xray_local_port
    # 当 xray_sni 非空时 → 443复用模式：Xray 用 SNI 分流到 xray_local_port，Realm 监听 xray_local_port
    local ob_idx=0
    if [[ -s "$REALM_EP_DB" ]]; then
        while IFS='|' read -r listen_port remote_host remote_port label xray_sni xray_local_port || [[ -n "$listen_port" ]]; do
            [[ -z "$listen_port" ]] && continue
            [[ "${listen_port:0:1}" == "#" ]] && continue
            if [[ -n "$xray_sni" && "$listen_port" == "443" ]]; then
                ob_idx=$(( ob_idx + 1 ))
                local ob_tag="realm-out-${ob_idx}"
                realm_outbounds+=("$(cat <<EOF
    {
      "tag": "${ob_tag}",
      "protocol": "freedom",
      "settings": {
        "redirect": "127.0.0.1:${xray_local_port}"
      }
    }
EOF
)")
                realm_rules+=("$(cat <<EOF
    {
      "type": "field",
      "inboundTag": ["vless-in-443-*"],
      "domain": ["${xray_sni}"],
      "outboundTag": "${ob_tag}"
    }
EOF
)")
            fi
        done < "$REALM_EP_DB"
    fi

    # ── 组装 JSON ────────────────────────────────────────────────
    # 使用 Python 或 jq 拼接（更可靠），fallback 到 heredoc
    local inbounds_json
    if (( ${#inbounds_arr[@]} > 0 )); then
        inbounds_json=$(printf '%s\n' "${inbounds_arr[@]}" | paste -sd ',' -)
        inbounds_json="[${inbounds_json}]"
    else
        inbounds_json="[]"
    fi

    local extra_outbounds=""
    if (( ${#realm_outbounds[@]} > 0 )); then
        extra_outbounds=",$(printf '%s\n' "${realm_outbounds[@]}" | paste -sd ',' -)"
    fi

    local extra_rules=""
    if (( ${#realm_rules[@]} > 0 )); then
        extra_rules=",$(printf '%s\n' "${realm_rules[@]}" | paste -sd ',' -)"
    fi

    cat > "$XRAY_MAIN_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${XRAY_LOG_DIR}/access.log",
    "error":  "${XRAY_LOG_DIR}/error.log"
  },
  "inbounds": ${inbounds_json},
  "outbounds": [
    {"protocol":"freedom","tag":"direct","settings":{}},
    {"protocol":"blackhole","tag":"block"}
    ${extra_outbounds}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type":"field","protocol":["bittorrent"],"outboundTag":"block"}
      ${extra_rules}
    ]
  }
}
EOF

    # 验证配置
    if ! "$XRAY_BIN" run -test -config "$XRAY_MAIN_CONFIG" >/dev/null 2>&1; then
        log_error "Xray 配置验证失败，详细信息:"
        "$XRAY_BIN" run -test -config "$XRAY_MAIN_CONFIG" 2>&1 | head -20
        return 1
    fi
    log_success "Xray 配置生成并验证通过"
}

# ── 重新生成 Realm 配置 ──────────────────────────────────────────
regen_realm_config() {
    log_step "重新生成 Realm 配置..."
    mkdir -p "$REALM_ETC"
    cat > "$REALM_CFG" <<'EOF'
# Auto-generated by vps_manager.sh

[log]
level = "warn"

[network]
no_tcp  = false
use_udp = true

EOF

    if [[ ! -s "$REALM_EP_DB" ]]; then
        echo "# No endpoints configured." >> "$REALM_CFG"
        return 0
    fi

    local listen_port remote_host remote_port label xray_sni xray_local_port
    while IFS='|' read -r listen_port remote_host remote_port label xray_sni xray_local_port || [[ -n "$listen_port" ]]; do
        [[ -z "$listen_port" ]] && continue
        [[ "${listen_port:0:1}" == "#" ]] && continue

        local local_listen
        if [[ -n "$xray_sni" && "$listen_port" == "443" ]]; then
            # 443复用：Realm 监听本地 xray_local_port（仅 loopback）
            local_listen="127.0.0.1:${xray_local_port}"
        else
            # 非443：直接监听指定端口
            local_listen="[::]:${listen_port}"
        fi

        # IPv6 目标地址处理
        local config_rh="$remote_host"
        if [[ "$config_rh" =~ : ]] && [[ ! "$config_rh" =~ ^\[.*\]$ ]]; then
            config_rh="[${config_rh}]"
        fi

        cat >> "$REALM_CFG" <<EOF
[[endpoints]]
# $label
listen = "${local_listen}"
remote = "${config_rh}:${remote_port}"

EOF
    done < "$REALM_EP_DB"
    log_success "Realm 配置生成完成"
}

# ── 服务控制 ─────────────────────────────────────────────────────
svc_action() {
    local svc="$1" action="$2"
    if [[ "$SVC_MGR" == "systemd" ]]; then
        systemctl "$action" "$svc" 2>/dev/null || true
    else
        /etc/init.d/"$svc" "$action" 2>/dev/null || true
    fi
}

restart_xray()  { svc_action xray restart;  sleep 1; }
restart_realm() { svc_action realm restart; sleep 1; }
start_xray()    { svc_action xray start;    sleep 1; }
start_realm()   { svc_action realm start;   sleep 1; }
stop_xray()     { svc_action xray stop; }
stop_realm()    { svc_action realm stop; }

enable_and_start_xray() {
    if [[ "$SVC_MGR" == "systemd" ]]; then
        ensure_xray_service_ubuntu
        systemctl daemon-reload
        systemctl enable xray >/dev/null 2>&1 || true
        systemctl restart xray
        sleep 2
        if systemctl is-active --quiet xray; then
            log_success "Xray 服务已启动"
        else
            log_error "Xray 启动失败:"
            journalctl -u xray -n 20 --no-pager 2>/dev/null || true
        fi
    else
        rc-update add xray default >/dev/null 2>&1 || true
        /etc/init.d/xray restart
        sleep 2
        /etc/init.d/xray status | grep -q "started" && log_success "Xray 服务已启动" || {
            log_error "Xray 启动失败"
            tail -n 20 "$XRAY_LOG_DIR/error.log" 2>/dev/null || true
        }
    fi
}

enable_and_start_realm() {
    if [[ "$SVC_MGR" == "systemd" ]]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable realm >/dev/null 2>&1 || true
        systemctl restart realm
        sleep 1
        systemctl is-active --quiet realm && log_success "Realm 服务已启动" || log_warn "Realm 启动可能失败，请检查配置"
    else
        rc-update add realm default >/dev/null 2>&1 || true
        /etc/init.d/realm restart
        sleep 1
        log_success "Realm 服务重启完成"
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

# ==============================================================
# URL 编码
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

# ==============================================================
# 生成 VLESS URI
# ==============================================================
make_vless_uri() {
    local uuid="$1" ip="$2" port="$3" sni="$4" public_key="$5" short_id="$6" name="$7" is_ipv6="${8:-0}"
    local enc_name; enc_name=$(urlencode "$name")
    local host="$ip"
    [[ "$is_ipv6" == "1" ]] && host="[${ip}]"
    echo "vless://${uuid}@${host}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=firefox&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#${enc_name}"
}

# ==============================================================
# ══ VLESS 节点管理 ═════════════════════════════════════════════
# ==============================================================

# ── 添加 VLESS 节点 ──────────────────────────────────────────
add_vless_node() {
    log_title "添加 VLESS+Reality+Vision 节点"

    # 确保 Xray 已安装
    if [[ ! -x "$XRAY_BIN" ]]; then
        log_warn "Xray 未安装，正在自动安装..."
        system_init
        install_xray
    fi

    # 节点名称
    local name; read -rp "节点名称 (回车使用日期): " name
    [[ -z "$name" ]] && name="VLESS-$(date +%Y%m%d-%H%M%S)"

    # 端口
    local port
    while true; do
        read -rp "监听端口 [回车=443]: " port
        [[ -z "$port" ]] && port=443
        if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            log_error "端口无效"; continue
        fi
        # 检查 443 端口是否已有非 Xray 进程占用
        if [[ "$port" == "443" ]] && ss -tlnp 2>/dev/null | grep ':443 ' | grep -qv xray; then
            log_warn "端口 443 已被其他进程占用，继续可能导致冲突"
            read -rp "仍要继续? [y/N]: " cc
            [[ "${cc:-N}" != "y" ]] && continue
        fi
        break
    done

    # SNI（伪装域名）
    local sni
    read -rp "SNI 伪装域名 [回车=www.cloudflare.com]: " sni
    [[ -z "$sni" ]] && sni="www.cloudflare.com"

    # 客户端指纹
    echo "客户端指纹选项: chrome firefox safari ios android edge"
    local fp; read -rp "Fingerprint [回车=firefox]: " fp
    [[ -z "$fp" ]] && fp="firefox"

    # 生成密钥
    log_step "生成 X25519 密钥对..."
    local key_out
    key_out=$("$XRAY_BIN" x25519 2>&1)
    parse_xray_keys "$key_out"
    local private_key="$PARSED_PRIVATE" public_key="$PARSED_PUBLIC"

    local uuid; uuid=$(gen_uuid)
    local short_id; short_id=$(openssl rand -hex 8)

    log_info "UUID:        $uuid"
    log_info "Public Key:  $public_key"
    log_info "Short ID:    $short_id"
    log_info "SNI:         $sni"
    log_info "Port:        $port"

    # 写入节点数据库
    echo "${uuid}|${port}|${sni}|${short_id}|${private_key}|${name}|${fp}" >> "$NODE_DB"

    # 防火墙放行
    _allow_port_fw "$port"

    # 重新生成并应用配置
    regen_xray_config || { log_error "配置生成失败，节点已回滚"; sed -i "\|^${uuid}|d" "$NODE_DB"; return 1; }
    enable_and_start_xray

    echo ""
    log_success "节点 '$name' 添加成功！"
    _show_node_info "$uuid" "$port" "$sni" "$short_id" "$private_key" "$public_key" "$name" "$fp"
}

_allow_port_fw() {
    local port="$1"
    if cmd_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$port"/tcp >/dev/null 2>&1 || true
        ufw allow "$port"/udp >/dev/null 2>&1 || true
    fi
    if cmd_exists iptables; then
        iptables  -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables  -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        ip6tables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
    fi
    if cmd_exists firewall-cmd; then
        firewall-cmd --permanent --add-port="$port"/tcp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

# ── 显示单个节点信息 ─────────────────────────────────────────
_show_node_info() {
    local uuid="$1" port="$2" sni="$3" short_id="$4" private_key="$5" public_key="$6" name="$7" fp="${8:-firefox}"

    local ipv4 ipv6
    ipv4=$(get_ipv4); ipv6=$(get_ipv6)

    echo ""
    echo -e "${CYAN}══════════ 节点信息：$name ══════════${NC}"
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
        local uri; uri=$(make_vless_uri "$uuid" "$ipv4" "$port" "$sni" "$public_key" "$short_id" "$name" "0")
        echo -e "${GREEN}━━ VLESS URI (IPv4) ━━${NC}"
        echo -e "${YELLOW}$uri${NC}"
        echo ""
    fi
    if [[ -n "$ipv6" ]]; then
        local uri6; uri6=$(make_vless_uri "$uuid" "$ipv6" "$port" "$sni" "$public_key" "$short_id" "${name}-v6" "1")
        echo -e "${GREEN}━━ VLESS URI (IPv6) ━━${NC}"
        echo -e "${YELLOW}$uri6${NC}"
        echo ""
    fi

    # Clash Meta 格式
    local server="${ipv4:-$ipv6}"
    echo -e "${GREEN}━━ Clash Meta 配置片段 ━━${NC}"
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
    echo -e "${CYAN}════════════════════════════════════${NC}"
}

# ── 列出所有节点 ─────────────────────────────────────────────
list_vless_nodes() {
    log_title "当前 VLESS 节点列表"
    if [[ ! -s "$NODE_DB" ]]; then
        echo "  (无节点)"
        return
    fi
    local idx=0
    while IFS='|' read -r uuid port sni short_id private_key name fp || [[ -n "$uuid" ]]; do
        [[ -z "$uuid" || "${uuid:0:1}" == "#" ]] && continue
        idx=$(( idx + 1 ))
        echo "  [$idx] $name  端口:$port  SNI:$sni  UUID:${uuid:0:8}..."
    done < "$NODE_DB"
    [[ $idx -eq 0 ]] && echo "  (无节点)"
}

# ── 选择节点（返回行号）─────────────────────────────────────
_pick_node() {
    list_vless_nodes
    [[ ! -s "$NODE_DB" ]] && return 1
    local n; read -rp "请输入序号: " n
    n="${n// /}"
    if ! [[ "$n" =~ ^[0-9]+$ ]]; then return 1; fi
    PICKED_NODE_LINE=$(awk -v n="$n" 'NR==n' "$NODE_DB")
    [[ -z "$PICKED_NODE_LINE" ]] && { log_error "序号不存在"; return 1; }
    return 0
}

# ── 显示选中节点信息 ─────────────────────────────────────────
show_vless_node() {
    log_title "查看节点信息"
    _pick_node || return
    IFS='|' read -r uuid port sni short_id private_key name fp <<< "$PICKED_NODE_LINE"
    local public_key; public_key=$(derive_public_key "$private_key")
    _show_node_info "$uuid" "$port" "$sni" "$short_id" "$private_key" "$public_key" "$name" "$fp"
}

# ── 显示所有节点信息 ─────────────────────────────────────────
show_all_vless_nodes() {
    log_title "所有节点信息"
    if [[ ! -s "$NODE_DB" ]]; then echo "  (无节点)"; return; fi
    local ipv4 ipv6
    ipv4=$(get_ipv4); ipv6=$(get_ipv6)
    while IFS='|' read -r uuid port sni short_id private_key name fp || [[ -n "$uuid" ]]; do
        [[ -z "$uuid" || "${uuid:0:1}" == "#" ]] && continue
        local public_key; public_key=$(derive_public_key "$private_key")
        _show_node_info "$uuid" "$port" "$sni" "$short_id" "$private_key" "$public_key" "$name" "${fp:-firefox}"
        echo ""
    done < "$NODE_DB"
}

# ── 导出节点到文件 ──────────────────────────────────────────
export_vless_nodes() {
    log_title "导出节点连接信息"
    local outfile="$BACKUP_DIR/vless_export_$(date +%Y%m%d_%H%M%S).txt"
    mkdir -p "$BACKUP_DIR"
    local ipv4 ipv6
    ipv4=$(get_ipv4); ipv6=$(get_ipv6)
    {
        echo "# VPS Manager - VLESS 节点导出"
        echo "# 导出时间: $(date)"
        echo "# 服务器 IPv4: ${ipv4:-N/A}"
        echo "# 服务器 IPv6: ${ipv6:-N/A}"
        echo ""
        if [[ -s "$NODE_DB" ]]; then
            while IFS='|' read -r uuid port sni short_id private_key name fp || [[ -n "$uuid" ]]; do
                [[ -z "$uuid" || "${uuid:0:1}" == "#" ]] && continue
                local public_key; public_key=$(derive_public_key "$private_key")
                echo "## $name"
                [[ -n "$ipv4" ]] && echo "$(make_vless_uri "$uuid" "$ipv4" "$port" "$sni" "$public_key" "$short_id" "$name" "0")"
                [[ -n "$ipv6" ]] && echo "$(make_vless_uri "$uuid" "$ipv6" "$port" "$sni" "$public_key" "$short_id" "${name}-v6" "1")"
                echo ""
            done < "$NODE_DB"
        else
            echo "(无节点)"
        fi
    } > "$outfile"
    log_success "已导出到: $outfile"
    cat "$outfile"
}

# ── 删除节点 ────────────────────────────────────────────────
delete_vless_node() {
    log_title "删除 VLESS 节点"
    _pick_node || return
    IFS='|' read -r uuid port sni short_id private_key name fp <<< "$PICKED_NODE_LINE"
    read -rp "确认删除节点 '$name'? [y/N]: " confirm
    [[ "${confirm:-N}" != "y" ]] && { log_info "已取消"; return; }

    local tmp; tmp=$(mktemp)
    grep -v "^${uuid}|" "$NODE_DB" > "$tmp" || true
    cat "$tmp" > "$NODE_DB"; rm -f "$tmp"

    regen_xray_config && restart_xray
    log_success "节点 '$name' 已删除"
}

# ── 测试 VLESS 节点 ──────────────────────────────────────────
test_vless_node() {
    log_title "测试 VLESS 节点"
    _pick_node || return
    IFS='|' read -r uuid port sni short_id private_key name fp <<< "$PICKED_NODE_LINE"

    echo ""
    log_step "1. 检查 Xray 服务状态..."
    xray_is_active && log_success "Xray 运行中" || log_error "Xray 未运行"

    log_step "2. 检查端口 $port 监听..."
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        log_success "端口 $port 正在监听"
    else
        log_warn "端口 $port 未检测到监听（可能在容器内显示异常）"
    fi

    log_step "3. 验证 Xray 配置文件..."
    if "$XRAY_BIN" run -test -config "$XRAY_MAIN_CONFIG" >/dev/null 2>&1; then
        log_success "配置文件验证通过"
    else
        log_error "配置文件验证失败:"
        "$XRAY_BIN" run -test -config "$XRAY_MAIN_CONFIG" 2>&1 | head -10
    fi

    log_step "4. 测试 SNI 目标可达性 ($sni)..."
    if curl -sI --max-time 5 "https://${sni}" -o /dev/null -w "%{http_code}" | grep -qE "^[23]"; then
        log_success "SNI 目标 $sni 可达"
    else
        log_warn "SNI 目标 $sni 可能不可达（不影响节点本身工作）"
    fi

    log_step "5. 检查防火墙端口 $port..."
    if cmd_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw status | grep "$port" && log_success "UFW 规则存在" || log_warn "UFW 中未发现端口 $port 规则"
    else
        log_info "（跳过 UFW 检查）"
    fi

    echo ""
    log_success "测试完成。节点 '$name' 基础检查结束。"
}

# ==============================================================
# ══ Xray 服务管理 ══════════════════════════════════════════════
# ==============================================================

xray_service_menu() {
    while true; do
        log_title "Xray 服务管理"
        echo "1) 查看 Xray 状态"
        echo "2) 重启 Xray"
        echo "3) 停止 Xray"
        echo "4) 启动 Xray"
        echo "5) 查看 Xray 日志（最近50行）"
        echo "6) 实时日志"
        echo "7) 返回上级"
        read -rp "请选择: " c
        case "${c:-}" in
            1) _show_xray_status ;;
            2) restart_xray; _show_xray_status ;;
            3) stop_xray ;;
            4) start_xray ;;
            5) tail -n 50 "$XRAY_LOG_DIR/error.log" 2>/dev/null || journalctl -u xray -n 50 --no-pager 2>/dev/null || log_warn "日志不可读" ;;
            6) journalctl -u xray -f 2>/dev/null || tail -f "$XRAY_LOG_DIR/error.log" 2>/dev/null || log_warn "日志不可读" ;;
            7) break ;;
            *) log_warn "无效选项" ;;
        esac
    done
}

_show_xray_status() {
    echo ""
    echo -e "${CYAN}══ Xray 状态 ══${NC}"
    local ver; ver=$("$XRAY_BIN" version 2>&1 | head -1 || echo "未知")
    echo "版本: $ver"
    if [[ "$SVC_MGR" == "systemd" ]]; then
        systemctl --no-pager -l status xray 2>/dev/null || echo "（服务未安装）"
    else
        /etc/init.d/xray status 2>/dev/null || echo "（服务未安装）"
    fi
    echo ""
    echo "端口监听情况:"
    ss -tlnp 2>/dev/null | grep -E "xray|443|8443" || echo "（未检测到监听）"
}

# ==============================================================
# ══ Realm 端口转发管理 ═════════════════════════════════════════
# ==============================================================

# Realm DB 字段: listen_port|remote_host|remote_port|label|xray_sni|xray_local_port
# 443 复用模式: listen_port=443, xray_sni=<sni>, xray_local_port=<内部loopback端口>
# 普通模式:    listen_port=<非443>, xray_sni="", xray_local_port=""

add_realm_endpoint() {
    log_title "新增 Realm 端口转发"

    # 确保 Realm 已安装
    if [[ ! -x "$REALM_BIN" ]]; then
        log_warn "Realm 未安装，正在自动安装..."
        install_realm
    fi

    echo ""
    echo "入站端口模式："
    echo "  1) 使用 443 端口（与 Xray 共用 443，通过 SNI 分流，推荐）"
    echo "  2) 使用自定义端口（Realm 独占该端口）"
    local mode; read -rp "请选择 [1/2]: " mode

    local listen_port xray_sni xray_local_port label

    if [[ "${mode:-1}" == "1" ]]; then
        # 443 复用模式
        listen_port="443"
        read -rp "SNI 分流域名（客户端连此域名时路由到本条转发）: " xray_sni
        [[ -z "$xray_sni" ]] && { log_error "SNI 不能为空（复用443时必须填写）"; return 1; }

        # 自动分配内部 loopback 端口 (10000-19999)
        local used_ports
        used_ports=$(awk -F'|' '$6 != "" {print $6}' "$REALM_EP_DB" 2>/dev/null || true)
        xray_local_port=10000
        while echo "$used_ports" | grep -qx "$xray_local_port"; do
            xray_local_port=$(( xray_local_port + 1 ))
        done
        log_info "内部 loopback 端口自动分配: $xray_local_port"
    else
        # 普通模式
        while true; do
            read -rp "本地监听端口: " listen_port
            listen_port="${listen_port// /}"
            if ! [[ "$listen_port" =~ ^[0-9]+$ ]] || (( listen_port < 1 || listen_port > 65535 )); then
                log_error "端口无效"; continue
            fi
            if awk -F'|' '{print $1}' "$REALM_EP_DB" 2>/dev/null | grep -qx "$listen_port"; then
                log_warn "端口 $listen_port 已被 Realm 使用，请更换"
                continue
            fi
            break
        done
        xray_sni=""
        xray_local_port=""
    fi

    read -rp "落地节点地址（IP 或域名）: " remote_host
    read -rp "落地节点端口: " remote_port
    read -rp "备注名称: " label

    remote_host="${remote_host// /}"
    remote_port="${remote_port// /}"
    label="${label:-realm-$(date +%s)}"

    if ! [[ "$remote_port" =~ ^[0-9]+$ ]] || (( remote_port < 1 || remote_port > 65535 )); then
        log_error "落地端口无效"; return 1
    fi

    echo "${listen_port}|${remote_host}|${remote_port}|${label}|${xray_sni}|${xray_local_port}" >> "$REALM_EP_DB"

    # 更新 Realm 配置
    regen_realm_config
    enable_and_start_realm

    # 若是 443 复用模式，还需更新 Xray 配置
    if [[ "${mode:-1}" == "1" ]]; then
        regen_xray_config
        restart_xray
    else
        _allow_port_fw "$listen_port"
    fi

    log_success "Realm 转发已添加: 入站:$listen_port → ${remote_host}:${remote_port} ($label)"
    if [[ "${mode:-1}" == "1" ]]; then
        log_info "443 复用模式：客户端 SNI='$xray_sni' 时，流量将经由 Xray→Realm 转发到 ${remote_host}:${remote_port}"
    fi
}

list_realm_endpoints() {
    log_title "Realm 转发规则列表"
    if [[ ! -s "$REALM_EP_DB" ]]; then echo "  (无规则)"; return; fi
    local idx=0
    while IFS='|' read -r listen_port remote_host remote_port label xray_sni xray_local_port || [[ -n "$listen_port" ]]; do
        [[ -z "$listen_port" || "${listen_port:0:1}" == "#" ]] && continue
        idx=$(( idx + 1 ))
        local mode_info
        if [[ -n "$xray_sni" ]]; then
            mode_info="[443复用 SNI=$xray_sni 内部端口=$xray_local_port]"
        else
            mode_info="[独立端口 $listen_port]"
        fi
        echo "  [$idx] $label  $mode_info → ${remote_host}:${remote_port}"
    done < "$REALM_EP_DB"
    [[ $idx -eq 0 ]] && echo "  (无规则)"
}

delete_realm_endpoint() {
    log_title "删除 Realm 转发规则"
    list_realm_endpoints
    [[ ! -s "$REALM_EP_DB" ]] && return
    local n; read -rp "请输入要删除的序号: " n
    n="${n// /}"
    [[ ! "$n" =~ ^[0-9]+$ ]] && { log_error "序号无效"; return 1; }

    local old_line; old_line=$(awk -v n="$n" 'NR==n' "$REALM_EP_DB" || true)
    [[ -z "$old_line" ]] && { log_error "序号不存在"; return 1; }

    local tmp; tmp=$(mktemp)
    awk -v n="$n" 'NR!=n' "$REALM_EP_DB" > "$tmp"
    cat "$tmp" > "$REALM_EP_DB"; rm -f "$tmp"

    regen_realm_config
    regen_xray_config  # 可能有 443 复用路由需要更新
    enable_and_start_realm
    restart_xray

    log_success "规则已删除"
}

# 链路测试
test_realm_endpoints() {
    log_title "Realm 转发链路测试"
    if [[ ! -s "$REALM_EP_DB" ]]; then echo "无规则"; return; fi

    while IFS='|' read -r listen_port remote_host remote_port label xray_sni xray_local_port || [[ -n "$listen_port" ]]; do
        [[ -z "$listen_port" || "${listen_port:0:1}" == "#" ]] && continue
        echo ""
        echo "── 规则: $label ──"
        # 解析目标 IP
        local resolved=""
        if [[ "$remote_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$remote_host" =~ : ]]; then
            resolved="$remote_host"
            echo "目标地址: $remote_host (IP)"
        else
            resolved=$(getent ahosts "$remote_host" 2>/dev/null | awk '{print $1}' | head -1 || true)
            if [[ -n "$resolved" ]]; then
                echo "目标地址: $remote_host → $resolved"
            else
                echo "目标地址: $remote_host (DNS 解析失败)"
            fi
        fi

        # TCP 探测落地
        if [[ -n "$resolved" ]]; then
            if timeout 4 bash -c "cat < /dev/null > /dev/tcp/${resolved}/${remote_port}" >/dev/null 2>&1; then
                log_success "落地 TCP 连通: ${resolved}:${remote_port} OK"
            else
                log_error  "落地 TCP 连通: ${resolved}:${remote_port} FAIL"
            fi
        fi

        # 本地端口检测
        if [[ -n "$xray_sni" ]]; then
            log_info "模式: 443复用 (SNI=$xray_sni, 内部端口=$xray_local_port)"
            if ss -tlnp 2>/dev/null | grep -q "127.0.0.1:${xray_local_port}"; then
                log_success "内部 Realm 监听端口 $xray_local_port: OK"
            else
                log_warn "内部端口 $xray_local_port 未检测到监听"
            fi
        else
            if ss -tlnp 2>/dev/null | grep -q ":${listen_port} "; then
                log_success "本地端口 $listen_port 监听: OK"
            else
                log_warn "本地端口 $listen_port 未检测到监听"
            fi
        fi
    done < "$REALM_EP_DB"
    echo ""
}

realm_service_menu() {
    while true; do
        log_title "Realm 服务管理"
        echo "1) 查看 Realm 状态"
        echo "2) 重启 Realm"
        echo "3) 停止 Realm"
        echo "4) 启动 Realm"
        echo "5) 查看 Realm 日志"
        echo "6) 返回上级"
        read -rp "请选择: " c
        case "${c:-}" in
            1) _show_realm_status ;;
            2) restart_realm; _show_realm_status ;;
            3) stop_realm ;;
            4) start_realm ;;
            5) journalctl -u realm -n 50 --no-pager 2>/dev/null || log_warn "日志不可读" ;;
            6) break ;;
            *) log_warn "无效选项" ;;
        esac
    done
}

_show_realm_status() {
    echo ""
    echo -e "${CYAN}══ Realm 状态 ══${NC}"
    [[ -x "$REALM_BIN" ]] && echo "二进制: $REALM_BIN (已安装)" || echo "二进制: 未安装"
    if [[ "$SVC_MGR" == "systemd" ]]; then
        systemctl --no-pager -l status realm 2>/dev/null || echo "（服务未安装）"
    else
        /etc/init.d/realm status 2>/dev/null || echo "（服务未安装）"
    fi
    echo ""
    echo "当前转发规则:"
    list_realm_endpoints
}

# ==============================================================
# ══ 系统总览 ═══════════════════════════════════════════════════
# ==============================================================
show_overview() {
    log_title "系统总览"
    local ipv4 ipv6
    ipv4=$(get_ipv4); ipv6=$(get_ipv6)

    echo "━━ 服务器信息 ━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "OS:     $OS_TYPE | $(uname -r)"
    echo "内存:   ${TOTAL_MEM}MB | 磁盘:${TOTAL_DISK}GB"
    echo "IPv4:   ${ipv4:-N/A}"
    echo "IPv6:   ${ipv6:-N/A}"
    echo ""

    echo "━━ Xray 状态 ━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ -x "$XRAY_BIN" ]]; then
        echo "版本: $("$XRAY_BIN" version 2>&1 | head -1)"
        xray_is_active && echo -e "服务: ${GREEN}运行中${NC}" || echo -e "服务: ${RED}已停止${NC}"
    else
        echo -e "Xray: ${RED}未安装${NC}"
    fi

    echo ""
    echo "━━ Realm 状态 ━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ -x "$REALM_BIN" ]]; then
        realm_is_active && echo -e "服务: ${GREEN}运行中${NC}" || echo -e "服务: ${RED}已停止${NC}"
    else
        echo -e "Realm: ${RED}未安装${NC}"
    fi

    echo ""
    echo "━━ VLESS 节点 ━━━━━━━━━━━━━━━━━━━━━━━"
    list_vless_nodes

    echo ""
    echo "━━ Realm 转发 ━━━━━━━━━━━━━━━━━━━━━━━"
    list_realm_endpoints

    echo ""
    echo "━━ 端口监听 ━━━━━━━━━━━━━━━━━━━━━━━━━"
    ss -tlnp 2>/dev/null | grep -E "^LISTEN" | awk '{print "  "$4}' | head -20 || echo "  (无法获取)"
    echo ""
}

# ==============================================================
# ══ 一键初始化安装 ═════════════════════════════════════════════
# ==============================================================
full_install() {
    log_title "一键初始化（安装 Xray + Realm）"
    system_init
    install_xray
    install_realm
    log_success "基础软件安装完成！请通过菜单添加节点和转发规则。"
}

# ==============================================================
# ══ 主菜单 ═════════════════════════════════════════════════════
# ==============================================================
main_menu() {
    need_root
    detect_os

    while true; do
        echo ""
        echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║   VPS 一键管理脚本 ${SCRIPT_VERSION}                   ║${NC}"
        echo -e "${BLUE}║   Xray VLESS+Reality+Vision + Realm 转发      ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${CYAN}── VLESS 节点 ──────────────────────────────────${NC}"
        echo "  1) 添加 VLESS 节点（可指定端口/SNI）"
        echo "  2) 删除 VLESS 节点"
        echo "  3) 查看指定节点信息 & 连接 URI"
        echo "  4) 显示所有节点信息"
        echo "  5) 导出所有节点连接信息到文件"
        echo "  6) 测试 VLESS 节点"
        echo ""
        echo -e "${CYAN}── Xray 服务 ───────────────────────────────────${NC}"
        echo "  7) Xray 服务管理（状态/重启/日志）"
        echo ""
        echo -e "${CYAN}── Realm 端口转发（支持 443 复用）──────────────${NC}"
        echo "  8) 新增 Realm 转发（443复用 或 独立端口）"
        echo "  9) 查看 Realm 转发规则"
        echo " 10) 删除 Realm 转发规则"
        echo " 11) 测试 Realm 转发链路"
        echo " 12) Realm 服务管理（状态/重启/日志）"
        echo ""
        echo -e "${CYAN}── 系统 ────────────────────────────────────────${NC}"
        echo " 13) 系统总览"
        echo " 14) 一键初始化安装（Xray + Realm）"
        echo "  0) 退出"
        echo ""
        read -rp "请选择 [0-14]: " choice

        case "${choice:-}" in
            1)  add_vless_node ;;
            2)  delete_vless_node ;;
            3)  show_vless_node ;;
            4)  show_all_vless_nodes ;;
            5)  export_vless_nodes ;;
            6)  test_vless_node ;;
            7)  xray_service_menu ;;
            8)  add_realm_endpoint ;;
            9)  list_realm_endpoints ;;
            10) delete_realm_endpoint ;;
            11) test_realm_endpoints ;;
            12) realm_service_menu ;;
            13) show_overview ;;
            14) full_install ;;
            0)  log_info "退出。"; exit 0 ;;
            *)  log_warn "无效选项，请重新选择" ;;
        esac
    done
}

# ── 入口 ──────────────────────────────────────────────────────
echo -e "${BLUE}VPS Manager ${SCRIPT_VERSION}${NC}"
main_menu
