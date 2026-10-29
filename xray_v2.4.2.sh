#!/usr/bin/env bash
# ==============================================================
# VPS 一键管理脚本  v2.4.2 (终极大师版 - 版本感知版)
# 功能: Xray VLESS+Reality+Vision  本地直连 + 链式中转
#       + Hysteria2 (HY2) 节点管理 + 端口跳跃 + 带宽限制 + 伪装
# 架构: XTLS 官方内部 dokodemo-door 终极防偷流量 + 极客级健壮性
#
# 更新日志 v2.4.2:
#   1. 新增: Xray 内核版本感知。xray >= 26.9.8 的 REALITY 服务端按
#           ClientHello 判定: 必须带 X25519MLKEM768 key share 且排在
#           X25519 之前, 否则静默回落 dest (表现与被风控无异)。
#           生成的 vless 链接现按本机内核版本决定是否携带
#           support-x25519mlkem768=true 提示参数 (mihomo 导入时
#           自动启用); 内核更低或探测不到时链接与旧版逐字一致。
#           查看节点信息时另附 Mihomo (Clash Meta) 配置片段。
#   2. 新增: 指纹兼容警告。内核 >= 26.9.8 且节点指纹不是 chrome
#           时, 添加/修改节点会明确警告 (只有 chrome 指纹能发出
#           X25519MLKEM768, mihomo 握手将失败; sing-box 与
#           Shadowrocket 未更新的版本也连不上), 只警告不拦截;
#           节点检测新增“内核版本与客户端要求”一项。
#   3. 新增: 主菜单 [13] 升级 Xray 内核。可选锁定版或官方最新版;
#           旧内核自动备份到备份目录, 新内核验收失败自动回滚;
#           跨过 26.9.8 边界时打印客户端兼容提醒。
#   4. 改进: 安装版本锁。新装 Xray 全部发行版统一走官方 zip 安装
#           锁定版本 v26.10.21 (Debian 系不再用官方 install 脚本);
#           删掉下载失败回落 v1.8.4 的兜底, 失败明确报错。
#   5. 新增: 多发行版支持。在 Debian/Ubuntu (apt) 与 Alpine (apk)
#           之外新增 RHEL 系 (dnf, 缺失时 yum)、Arch 系 (pacman)、
#           openSUSE 系 (zypper), 按 /etc/os-release 的 ID 与
#           ID_LIKE 判定家族; systemd 判定加容器纠正 (systemd
#           不在位且有 OpenRC 时改判 openrc); 防火墙在 iptables
#           与 ufw 之外补 firewalld 等价放行/回收。
#   6. 继承: v2.4.1 全部功能，一个没删
#
# 更新日志 v2.4.1:
#   1. 修复: 端口段冲突检查假死。旧 hy2_range_conflict 对段内每个端口
#           都单独跑一次 ss, 30000-40000 这种万级段要查 10001 次,
#           在小机器上等于卡死。新版一次遍历 DB 做区间重叠判断,
#           再只跑一次 ss 取监听表比对, 段多大都瞬间完成。
#           顺带修正: 原 ss 取表用的是第 5 列 (Peer 列), 实际监听地址
#           在第 4 列, 不改则新版会漏检已监听端口。
#           (v2.4.0 其他内容一个没动, 仅此一处修复)
#
# 更新日志 v2.4.0:
#   1. 新增: Hysteria2 节点管理 (增删改查 + 状态检测)，与 Xray 节点
#           共存，互不干扰；每个 HY2 节点独立进程、独立配置、
#           独立证书、独立服务
#   2. 新增: 端口跳跃。非 NAT 机用服务端内置 listen 段 (:起-止)，
#           由 hysteria2 自动建/清防火墙重定向规则；NAT 机
#           (面板映射端口有限) 只用 1-3 个外网端口，内网端口
#           由脚本做 REDIRECT 落到 HY2 主端口，客户端用外网
#           端口段/列表跳跃
#   3. 新增: HY2 节点可设上/下行带宽 (Mbps)，写入服务端
#           bandwidth，封顶 Brutal 拥塞控制的抢占
#   4. 新增: 强密码 (自动生成 32 位) 与服务端伪装 Masquerade
#           (反代/本地文件/固定字符串三选一)；混淆 Obfs
#           (salamander) 默认关闭，可选开启并独立设密码
#   5. 修复: VPS 重启后 Xray/HY2 不自启。原因：旧脚本 OpenRC
#           分支从未执行 rc-update add，systemd 分支的
#           enable 失败被静默吞掉且无人校验。现每次启动与
#           每次服务重启都会校验并补齐自启，失败会明说
#   6. 继承: v2.3.5 全部功能，一个没删
#
# 更新日志 v2.3.5:
#   1. 修复: 查看节点时若公网 IP 自动检测失败，vless 链接不再消失
#           (之前检测不到 IP 就整段不打印，这是本次报障的根因)
#   2. 改进: IP 检测增加多个备用源 + 严格格式校验，防止错误页面污染
#   3. 改进: 检测成功的 IP 自动缓存，检测失败时用缓存兜底；
#           实在拿不到则用「你的服务器IP」占位符照常输出链接并提示替换
#   4. 继承: v2.3.4 全部功能，一个没删
# ==============================================================

SCRIPT_VERSION="v2.4.2"

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

# Xray 内核锁定版本 (v2.4.2): 新装统一走官方 zip 安装此版本, 不跟随
# 上游 latest, 避免 breaking change 在新装时无声引入 (26.9.8 的
# REALITY MLKEM 强制要求即为前车之鉴)。升级走主菜单 [13] 专门流程。
XRAY_VERSION_PIN="v26.10.21"

# 内核版本探测缓存 (v2.4.2): xray_kernel_version 首次探测后填充,
# XRAY_VER_STR 为纯数字版本串 (如 26.10.21), 探测失败为空串。
XRAY_VER_STR=""
XRAY_VER_CHECKED=0

DATA_DIR="/etc/vps_manager"
NODE_DB="$DATA_DIR/nodes.db"
RELAY_DB="$DATA_DIR/relay.db"
VERSION_FILE="$DATA_DIR/version"
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

# ── Hysteria2 全局变量 (v2.4.0 新增) ───────────────────────────
HY2_BIN="/usr/local/bin/hysteria"
HY2_ETC="/usr/local/etc/hysteria2"
HY2_CERT_DIR="$HY2_ETC/certs"
HY2_DB="$DATA_DIR/hy2.db"
HY2_LOG_DIR="/var/log/hysteria2"
HY2_VERSION_PIN="app/v2.13.0"
PICKED_HY2_NUM=""
PICKED_HY2_LINE=""

# ==============================================================
# 工具与基础函数
# ==============================================================
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

sanitize_db() {
    [ -f "$NODE_DB" ] && sed -i 's/\r//g' "$NODE_DB" 2>/dev/null || true
    [ -f "$RELAY_DB" ] && sed -i 's/\r//g' "$RELAY_DB" 2>/dev/null || true
    [ -f "$HY2_DB" ] && sed -i 's/\r//g' "$HY2_DB" 2>/dev/null || true
    # DB 里是密钥与密码，权限收紧到仅 root 可读写
    chmod 600 "$NODE_DB" "$RELAY_DB" "$HY2_DB" 2>/dev/null || true
}

# 过滤 DB 分隔符 |，防止字段错乱
sanitize_field() {
    echo "$1" | tr -d '|' | tr -d '\r' | tr -d '\n'
}

# 比较两个版本号 (格式 vX.Y.Z，可处理 v2.3.10 > v2.3.9)
# 返回值: 0 相等 | 1 第一个更大 | 2 第一个更小
ver_cmp() {
    local v1 v2
    v1=$(echo "${1#v}" | tr -cd '0-9.')
    v2=$(echo "${2#v}" | tr -cd '0-9.')
    [ -z "$v1" ] && v1="0.0.0"
    [ -z "$v2" ] && v2="0.0.0"
    local IFS='.'
    local -a a b
    read -ra a <<< "$v1"
    read -ra b <<< "$v2"
    local i x y
    for i in 0 1 2; do
        x="${a[$i]:-0}"; y="${b[$i]:-0}"
        x=$((10#$x)); y=$((10#$y))   # 10# 防止 08 被当成八进制
        (( x > y )) && return 1
        (( x < y )) && return 2
    done
    return 0
}

# 版本感知：低版本提示升级，无版本/版本相同直接进菜单
check_version() {
    if [ "$UPGRADE_CHECKED" = "1" ]; then return 0; fi
    UPGRADE_CHECKED=1

    local installed=""
    [ -f "$VERSION_FILE" ] && installed=$(tr -d ' \r\n' < "$VERSION_FILE" 2>/dev/null || true)

    # 无版本记录
    if [ -z "$installed" ]; then
        if [ -s "$NODE_DB" ] || [ -s "$RELAY_DB" ]; then
            installed="v0.0.0"   # 有老数据但无版本文件 → 视为远古版本，走升级流程
        else
            echo "$SCRIPT_VERSION" > "$VERSION_FILE" 2>/dev/null || true
            return 0             # 全新安装，直接进菜单
        fi
    fi

    ver_cmp "$installed" "$SCRIPT_VERSION"
    local cmp=$?

    if [ "$cmp" -eq 2 ]; then
        # ── 低版本 → 提示升级 ──
        log_title "检测到旧版本"
        echo -e " VPS 已安装版本: ${YELLOW}$installed${NC}"
        echo -e " 当前脚本版本: ${GREEN}$SCRIPT_VERSION${NC}"
        echo ""
        echo "  1) 平滑升级 (保留节点与落地，推荐)"
        echo "  2) 清空重装 (删除所有数据，危险)"
        echo "  0) 暂不升级，直接进入菜单"
        read -rp "请选择 [1/2/0]: " ch
        case "$ch" in
            1)
                log_info "正在平滑升级 $installed → $SCRIPT_VERSION ..."
                sanitize_db
                ensure_python
                if regen_config; then
                    start_xray
                    echo "$SCRIPT_VERSION" > "$VERSION_FILE" 2>/dev/null || true
                    ensure_autostart_all
                    log_success "升级完成！新版本已生效。"
                else
                    log_error "配置重新生成失败，版本未更新，下次启动会再次提示升级。"
                    log_warn "可尝试主菜单 [9) 强制修复配置]。"
                fi
                sleep 2
                ;;
            2)
                read -rp "警告: 将删除所有节点、落地和配置！确定吗？[y/N]: " confirm
                if [ "${confirm:-N}" = "y" ] || [ "${confirm:-N}" = "Y" ]; then
                    hy2_wipe_all
                    rm -rf "${DATA_DIR:?}" "${XRAY_ETC:?}"
                    mkdir -p "$DATA_DIR" "$BACKUP_DIR" "$XRAY_LOG_DIR" "$XRAY_ETC"
                    touch "$NODE_DB" "$RELAY_DB"
                    echo "$SCRIPT_VERSION" > "$VERSION_FILE" 2>/dev/null || true
                    log_success "已清空重装，当前版本 $SCRIPT_VERSION。"
                    sleep 1
                else
                    log_info "已取消清空，版本保持 $installed。"
                fi
                ;;
            *)
                log_info "已跳过升级，下次启动将再次提示。"
                return 0
                ;;
        esac
    elif [ "$cmp" -eq 1 ]; then
        # 版本记录比脚本还新 (极端情况) → 同步记录，直接进菜单
        log_warn "版本记录($installed)高于脚本($SCRIPT_VERSION)，已同步记录"
        echo "$SCRIPT_VERSION" > "$VERSION_FILE" 2>/dev/null || true
    fi
    # cmp == 0 → 版本相同，直接进菜单，什么都不做
    return 0
}

detect_os() {
    # v2.4.2: 多发行版家族判定。读 ID 与 ID_LIKE 两项: 先按 ID 精确
    # 命中, 未命中再按 ID_LIKE 归家族 (衍生发行版)。os-release 路径
    # 可用环境变量 OS_RELEASE_FILE 覆盖 (测试用), 默认 /etc/os-release。
    local osrel="${OS_RELEASE_FILE:-/etc/os-release}"
    if [ ! -f "$osrel" ]; then log_error "无法识别操作系统"; exit 1; fi
    local os_id os_like
    os_id=$(grep -E "^ID=" "$osrel" | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'" | tr '[:upper:]' '[:lower:]')
    os_like=$(grep -E "^ID_LIKE=" "$osrel" | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'" | tr '[:upper:]' '[:lower:]')
    OS_TYPE=""; PKG_MGR=""; SVC_MGR=""
    case "$os_id" in
        ubuntu|debian) OS_TYPE="debian"; PKG_MGR="apt"; SVC_MGR="systemd" ;;
        alpine)        OS_TYPE="alpine"; PKG_MGR="apk"; SVC_MGR="openrc" ;;
        centos|rhel|rocky|almalinux|fedora|oraclelinux|ol)
                       OS_TYPE="rhel"; PKG_MGR="dnf"; SVC_MGR="systemd" ;;
        arch|manjaro|endeavouros|garuda|artix)
                       OS_TYPE="arch"; PKG_MGR="pacman"; SVC_MGR="systemd" ;;
        opensuse-leap|opensuse-tumbleweed|opensuse|sles|sled)
                       OS_TYPE="suse"; PKG_MGR="zypper"; SVC_MGR="systemd" ;;
    esac
    if [ -z "$OS_TYPE" ]; then
        case " $os_like " in
            *" debian "*|*" ubuntu "*) OS_TYPE="debian"; PKG_MGR="apt"; SVC_MGR="systemd" ;;
            *" rhel "*|*" fedora "*|*" centos "*) OS_TYPE="rhel"; PKG_MGR="dnf"; SVC_MGR="systemd" ;;
            *" arch "*)   OS_TYPE="arch"; PKG_MGR="pacman"; SVC_MGR="systemd" ;;
            *" suse "*)   OS_TYPE="suse"; PKG_MGR="zypper"; SVC_MGR="systemd" ;;
        esac
    fi
    if [ -z "$OS_TYPE" ]; then log_error "不支持的发行版: '${os_id}' (ID_LIKE='${os_like}')"; exit 1; fi
    # RHEL 系老版本 (如 CentOS 7) 没有 dnf, 回落 yum (其余不变)
    if [ "$PKG_MGR" = "dnf" ] && ! cmd_exists dnf && cmd_exists yum; then PKG_MGR="yum"; fi
    # 容器纠正: 家族默认 systemd, 但 systemd 实际不在位
    # (/run/systemd/system 不存在) 且机器上有 OpenRC 时改判 openrc,
    # 避免把容器里的伪 systemd 当真 (沿用 realm 脚本的教训);
    # 其余情况一律不改判。
    if [ "$SVC_MGR" = "systemd" ] && [ ! -d /run/systemd/system ] && cmd_exists rc-update; then
        SVC_MGR="openrc"
    fi
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
    case "$PKG_MGR" in
        apt)     DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 2>/dev/null || true ;;
        apk)     apk add --no-cache -q python3 2>/dev/null || true ;;
        dnf|yum) "$PKG_MGR" install -y -q python3 2>/dev/null || true ;;
        pacman)  pacman -Sy --noconfirm -q python 2>/dev/null || true ;;
        zypper)  zypper --non-interactive --quiet install python3 2>/dev/null || true ;;
        *)       apk add --no-cache -q python3 2>/dev/null || true ;;
    esac
    if cmd_exists python3; then PYTHON=python3; else log_error "Python 安装失败"; PYTHON=""; fi
}

get_ipv4() {
    local ip url
    for url in https://api4.ipify.org https://ipv4.icanhazip.com https://ifconfig.me https://api.ip.sb https://icanhazip.com; do
        ip=$(curl -s -4 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        # 严格校验确为 IPv4，防止错误页面污染
        if echo "$ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
            echo "$ip"; return 0
        fi
    done
    return 1
}

get_ipv6() {
    local ip url
    for url in https://api6.ipify.org https://ipv6.icanhazip.com https://ifconfig.me https://icanhazip.com; do
        ip=$(curl -s -6 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        if echo "$ip" | grep -q ':' && echo "$ip" | grep -Eq '^[0-9a-fA-F:]{2,}$'; then
            echo "$ip"; return 0
        fi
    done
    return 1
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
# Xray 内核版本感知 (v2.4.2 新增)
# 背景: xray >= 26.9.8 的 REALITY 服务端按 ClientHello 判定,
# 必须含 X25519MLKEM768 key share 且排在 X25519 之前, 否则静默
# 回落 dest; minClientVer 对此无效, 服务端也没有放宽开关。
# 链接里的 MLKEM 提示参数因此必须按本机内核版本决定, 不能无条件加
# (< 26.9.8 两者都收, 2025-05 之前的远古服务端会拒绝 MLKEM)。
# ==============================================================
# 探测本机内核版本, 结果写入全局 XRAY_VER_STR (如 "26.10.21"),
# 探测失败为空串。首次探测后缓存, 后续调用不重复执行二进制;
# 更换二进制后须把 XRAY_VER_CHECKED 复位为 0 再重新探测。
xray_kernel_version() {
    if [ "$XRAY_VER_CHECKED" = "1" ]; then return 0; fi
    XRAY_VER_CHECKED=1
    XRAY_VER_STR=""
    if [ -x "$XRAY_BIN" ]; then
        local out
        out=$("$XRAY_BIN" version 2>/dev/null | head -1)
        # 输出首行形如: Xray 26.10.21 (Xray, Penetrates Everything.) ...
        XRAY_VER_STR=$(echo "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    return 0
}

# 内核版本是否 >= 目标版本 ($1 为 x.y.z); 探测不到版本返回 1
xray_kernel_ge() {
    xray_kernel_version
    [ -z "$XRAY_VER_STR" ] && return 1
    ver_cmp "v$XRAY_VER_STR" "v$1"
    local c=$?
    [ "$c" -eq 0 ] || [ "$c" -eq 1 ]
}

# 内核是否强制要求客户端发送 X25519MLKEM768 (>= 26.9.8)
xray_needs_mlkem() {
    xray_kernel_ge "26.9.8"
}

# 指纹兼容警告: 内核 >= 26.9.8 且指纹不是 chrome 时调用。
# 只警告不拦截 (老服务端场景下非 chrome 指纹仍然合法)。
warn_fp_mlkem() {
    local fp="$1"
    [ "$fp" = "chrome" ] && return 0
    xray_needs_mlkem || return 0
    log_warn "注意: 本机 Xray 内核为 ${XRAY_VER_STR}, >= 26.9.8 的 REALITY 要求客户端在 ClientHello 里发送 X25519MLKEM768, 而只有 chrome 指纹能发出该 key share。"
    log_warn "当前指纹 '${fp}': 用 mihomo/Clash 连此节点将握手失败 (静默回落, 极像被风控); sing-box / Shadowrocket 未更新到支持 MLKEM 的版本也连不上。"
    log_warn "强烈建议把指纹改回 chrome。服务端本身不受影响, 只是这类客户端连不上。"
}

# xray 官方 zip 的架构映射, 不支持的架构返回 1
xray_arch() {
    local machine
    machine=$(uname -m)
    case "$machine" in
        x86_64)        echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        armv7l)        echo "arm32-v7a" ;;
        *)             return 1 ;;
    esac
}

# 下载并解压指定版本 xray 官方 zip 到目标目录:
# 成功后 $2/unzipped/ 内含 xray 二进制与 .dat 文件; 失败返回 1。
xray_fetch_zip() {
    local ver="$1" dest="$2"
    local arch
    arch=$(xray_arch) || { log_error "不支持的架构: $(uname -m)"; return 1; }
    if ! gh_download "https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-${arch}.zip" "$dest/xray.zip"; then
        return 1
    fi
    if ! unzip -q -o "$dest/xray.zip" -d "$dest/unzipped" 2>/dev/null; then
        return 1
    fi
    [ -f "$dest/unzipped/xray" ] || return 1
    return 0
}

# ==============================================================
# 核心组件安装
# ==============================================================
system_init() {
    log_step "系统初始化..."
    case "$PKG_MGR" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl wget unzip openssl coreutils iproute2 net-tools iptables nftables python3 2>/dev/null || true
            ;;
        apk)
            apk update -q 2>/dev/null || true
            apk add --no-cache -q bash curl wget unzip openssl coreutils iproute2 iptables ip6tables nftables python3 2>/dev/null || true
            ;;
        dnf|yum)
            "$PKG_MGR" install -y -q curl wget unzip openssl coreutils iproute net-tools iptables nftables python3 2>/dev/null || true
            ;;
        pacman)
            pacman -Sy --noconfirm -q curl wget unzip openssl coreutils iproute2 net-tools iptables nftables python 2>/dev/null || true
            ;;
        zypper)
            zypper --non-interactive --quiet install curl wget unzip openssl coreutils iproute2 net-tools iptables nftables python3 2>/dev/null || true
            ;;
        *)
            log_warn "未知包管理器 '${PKG_MGR}', 跳过依赖安装, 请手动确认 curl/wget/unzip/openssl/python3 已就位"
            ;;
    esac
    enable_bbr
    mkdir -p "$DATA_DIR" "$BACKUP_DIR" "$XRAY_LOG_DIR" "$XRAY_ETC" 2>/dev/null || true
    touch "$NODE_DB" "$RELAY_DB" 2>/dev/null || true
    ensure_python
    log_success "系统初始化完成"
}

install_xray() {
    # 语义不变: 二进制已存在则只补 service 文件并返回, 绝不在此偷偷
    # 更换版本 (升级走主菜单 [13] upgrade_xray 专门流程)。
    if [ -x "$XRAY_BIN" ]; then write_xray_service; return 0; fi
    log_step "安装 Xray-core ${XRAY_VERSION_PIN} (版本锁定, 官方 zip)..."
    local tmp
    tmp=$(mktemp -d)
    if ! xray_fetch_zip "$XRAY_VERSION_PIN" "$tmp"; then
        log_error "Xray ${XRAY_VERSION_PIN} 下载或解压失败 (版本已锁定, 不做降级兜底, 请检查网络后重试)"
        rm -rf "$tmp"
        return 1
    fi
    install -m 755 "$tmp/unzipped/xray" "$XRAY_BIN"
    mkdir -p /usr/local/share/xray
    cp "$tmp/unzipped/"*.dat /usr/local/share/xray/ 2>/dev/null || true
    rm -rf "$tmp"
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
    # 每次重启都顺带校验自启是否在位 (静默，失败由启动检查明说)
    ensure_xray_autostart >/dev/null 2>&1 || true
}

allow_port() {
    if cmd_exists iptables; then
        iptables -C INPUT -p tcp --dport "$1" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$1" -j ACCEPT 2>/dev/null
    fi
    if cmd_exists ufw; then ufw allow "$1"/tcp >/dev/null 2>&1 || true; fi
    # v2.4.2: firewalld 正在运行时同步放行 (RHEL 系常见)
    if cmd_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="$1"/tcp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
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
    # v2.4.2: 内核 >= 26.9.8 时链接带上 MLKEM 提示参数, mihomo 导入
    # 时会自动开启 support-x25519mlkem768; 内核更低或探测不到时
    # 不带此参数, 链接与 v2.4.1 逐字一致。
    local mlkem_param=""
    if xray_needs_mlkem; then mlkem_param="&support-x25519mlkem768=true"; fi
    echo "vless://${uuid}@${host}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=${fp}&pbk=${pbk}&sid=${sid}${mlkem_param}&type=tcp&headerType=none#$(urlencode "$name")"
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
    warn_fp_mlkem "$fp"

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
    warn_fp_mlkem "$nf"

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
    local ipv4 ipv6
    ipv4=$(get_ipv4); ipv6=$(get_ipv6)

    # 检测成功就缓存 IP，检测失败则用缓存兜底
    [ -n "$ipv4" ] && echo "$ipv4" > "$DATA_DIR/server_ip" 2>/dev/null
    if [ -z "$ipv4" ] && [ -f "$DATA_DIR/server_ip" ]; then
        ipv4=$(tr -d ' \r\n' < "$DATA_DIR/server_ip" 2>/dev/null)
    fi

    echo -e "\n${CYAN}════ 节点: $name ════${NC}"
    echo "UUID:        $uuid"
    echo "Port:        $port"
    echo "SNI:         $sni"
    echo "Public Key:  $pub"
    echo "Short ID:    $sid"

    # IPv4 链接永远输出：拿不到 IP 就用占位符，保证链接可见
    local host4="$ipv4"
    if [ -z "$host4" ]; then
        host4="你的服务器IP"
        echo -e "${YELLOW}提示: 未能自动检测公网 IP，已用占位符生成链接，请把「你的服务器IP」替换为实际 IP${NC}"
    fi
    echo -e "\n${GREEN}── VLESS URI (IPv4) ──${NC}\n${YELLOW}$(make_uri "$uuid" "$host4" "$port" "$sni" "$pub" "$sid" "$name" "$fp" "0")${NC}"
    if [ -n "$ipv6" ]; then
        echo -e "\n${GREEN}── VLESS URI (IPv6) ──${NC}\n${YELLOW}$(make_uri "$uuid" "$ipv6" "$port" "$sni" "$pub" "$sid" "${name}-v6" "$fp" "1")${NC}"
    fi
    echo -e "\n${GREEN}── Mihomo (Clash Meta) 配置片段 ──${NC}"
    echo "  - name: \"$name\""
    echo "    type: vless"
    echo "    server: ${host4}"
    echo "    port: ${port}"
    echo "    uuid: ${uuid}"
    echo "    network: tcp"
    echo "    tls: true"
    echo "    udp: true"
    echo "    flow: xtls-rprx-vision"
    echo "    servername: ${sni}"
    echo "    client-fingerprint: ${fp}"
    echo "    reality-opts:"
    echo "      public-key: ${pub}"
    echo "      short-id: \"${sid}\""
    if xray_needs_mlkem; then
        echo "      support-x25519mlkem768: true"
    fi
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

    log_step "6. Xray 内核版本与客户端要求..."
    xray_kernel_version
    local kver="$XRAY_VER_STR"
    if [ -n "$kver" ]; then
        echo "    内核版本: Xray $kver"
        if xray_needs_mlkem; then
            log_warn "内核 >= 26.9.8: REALITY 客户端必须在 ClientHello 中发送 X25519MLKEM768, 否则会被静默回落到伪装站 (极像被风控)。"
            log_warn "mihomo/Clash 需在 reality-opts 开启 support-x25519mlkem768 (本脚本生成的链接已自动带提示参数) 且指纹须为 chrome; sing-box / Shadowrocket 未更新到支持 MLKEM 的版本将连不上。"
        else
            log_success "内核 < 26.9.8: 客户端无 X25519MLKEM768 强制要求, 两种 ClientHello 均可连接。"
        fi
    else
        log_warn "未能探测内核版本 (Xray 二进制缺失?), 已跳过 MLKEM 要求检查"
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
# Hysteria2 管理 (v2.4.0 新增)
# DB 格式 (hy2.db, | 分隔, 文本字段已过滤 |):
# svc_id|名称|主端口|跳跃类型(none/range/nat)|段起|段止|内网端口列表|外网端口串|
# 密码|SNI|伪装类型(proxy/file/string)|伪装值|混淆开关(0/1)|混淆密码|
# 上行Mbps|下行Mbps|忽略客户端带宽(0/1)
# 约定:
#   none : 单端口, 无跳跃
#   range: 非 NAT 机, listen 写成 :起-止, hysteria2 自动建/清重定向规则
#   nat  : NAT 机, listen 为单个内网主端口, 其余内网端口由脚本做
#          REDIRECT 落到主端口; 客户端用外网端口串跳跃 (总数<=3)
# 注意: hysteria2 没有 --test 校验模式, 本节用“启动服务 + 查 UDP
#       监听 + 查进程”作为验收, 失败时打日志尾巴并回滚。
# ==============================================================
yaml_quote() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

hy2_is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

hy2_valid_port() {
    hy2_is_uint "$1" || return 1
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# 统计外网端口串里的端口总数 ("40001-40003,40005" -> 4), 非法返回 1
hy2_count_ports() {
    local spec="$1" total=0 part a b
    [ -z "$spec" ] && return 1
    local old_ifs="$IFS"; IFS=','
    for part in $spec; do
        IFS="$old_ifs"
        case "$part" in
            *-*)
                a="${part%%-*}"; b="${part##*-}"
                hy2_valid_port "$a" && hy2_valid_port "$b" && [ "$a" -le "$b" ] || return 1
                total=$((total + b - a + 1))
                ;;
            *)
                hy2_valid_port "$part" || return 1
                total=$((total + 1))
                ;;
        esac
        IFS=','
    done
    IFS="$old_ifs"
    echo "$total"
    return 0
}

# 判断端口串是否全部为数字/逗号/横杠组成
hy2_valid_port_spec() {
    case "$1" in ''|*[!0-9,\-]*) return 1 ;; *) hy2_count_ports "$1" >/dev/null 2>&1 ;; esac
}

hy2_gen_hex() {
    openssl rand -hex "$1" 2>/dev/null || od -An -tx1 /dev/urandom | tr -d ' \n' | head -c "$(( $1 * 2 ))"
}

hy2_new_svc_id() {
    local id
    while true; do
        id="hy2-$(hy2_gen_hex 4)"
        grep -q "^${id}|" "$HY2_DB" 2>/dev/null || { echo "$id"; return 0; }
    done
}

install_hysteria() {
    if [ -x "$HY2_BIN" ]; then return 0; fi
    log_step "安装 Hysteria2..."
    local tag
    tag=$(curl -fsSL "https://api.github.com/repos/apernet/hysteria/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"\(app\/v[^"]*\)".*/\1/')
    [ -z "$tag" ] && tag="$HY2_VERSION_PIN"
    local machine arch
    machine=$(uname -m)
    case "$machine" in
        x86_64)        arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l)        arch="arm" ;;
        *)             log_error "不支持的架构: $machine"; return 1 ;;
    esac
    local tmp
    tmp=$(mktemp -d)
    if ! gh_download "https://github.com/apernet/hysteria/releases/download/${tag}/hysteria-linux-${arch}" "$tmp/hysteria"; then
        log_error "Hysteria2 下载失败 (版本 $tag)"
        rm -rf "$tmp"
        return 1
    fi
    install -m 755 "$tmp/hysteria" "$HY2_BIN"
    rm -rf "$tmp"
    if [ ! -x "$HY2_BIN" ]; then log_error "Hysteria2 安装后未找到二进制文件"; return 1; fi
    log_success "Hysteria2 已安装: $("$HY2_BIN" version 2>/dev/null | grep -i "version" | head -1 || echo "$tag")"
    return 0
}

write_hy2_service() {
    local svc="$1"
    local unit="hysteria2-${svc}"
    mkdir -p "$HY2_ETC" "$HY2_LOG_DIR"
    if [ "$SVC_MGR" = "systemd" ]; then
        cat > "/etc/systemd/system/${unit}.service" <<HY2SVCEOF
[Unit]
Description=Hysteria2 Service (${svc})
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStartPre=/bin/sh ${HY2_ETC}/${svc}.fw.sh
ExecStart=${HY2_BIN} server -c ${HY2_ETC}/${svc}.yaml
Restart=on-failure
RestartSec=3
LimitNPROC=10000
LimitNOFILE=1000000
StandardOutput=append:${HY2_LOG_DIR}/${svc}.log
StandardError=append:${HY2_LOG_DIR}/${svc}.log

[Install]
WantedBy=multi-user.target
HY2SVCEOF
        systemctl daemon-reload 2>/dev/null || true
    else
        cat > "/etc/init.d/${unit}" <<HY2ORCEOF
#!/sbin/openrc-run
name="${unit}"
command="${HY2_BIN}"
command_args="server -c ${HY2_ETC}/${svc}.yaml"
command_background="yes"
pidfile="/run/${unit}.pid"
output_log="${HY2_LOG_DIR}/${svc}.log"
error_log="${HY2_LOG_DIR}/${svc}.log"

start_pre() {
    [ -f "${HY2_ETC}/${svc}.fw.sh" ] && sh "${HY2_ETC}/${svc}.fw.sh" >/dev/null 2>&1
    return 0
}
HY2ORCEOF
        chmod +x "/etc/init.d/${unit}"
    fi
}

hy2_svc_ctl() {
    local svc="$1" act="$2"
    if [ "$SVC_MGR" = "systemd" ]; then
        systemctl "$act" "hysteria2-${svc}" >/dev/null 2>&1 || true
    else
        "/etc/init.d/hysteria2-${svc}" "$act" >/dev/null 2>&1 || true
    fi
}

hy2_svc_enable() {
    local svc="$1"
    if [ "$SVC_MGR" = "systemd" ]; then
        systemctl enable "hysteria2-${svc}" >/dev/null 2>&1 || true
    else
        rc-update add "hysteria2-${svc}" default >/dev/null 2>&1 || true
    fi
}

hy2_svc_enabled() {
    local svc="$1"
    if [ "$SVC_MGR" = "systemd" ]; then
        systemctl is-enabled "hysteria2-${svc}" 2>/dev/null | grep -qx "enabled"
    else
        rc-update show default 2>/dev/null | grep -qw "hysteria2-${svc}"
    fi
}

hy2_svc_disable() {
    local svc="$1"
    if [ "$SVC_MGR" = "systemd" ]; then
        systemctl disable "hysteria2-${svc}" >/dev/null 2>&1 || true
    else
        rc-update del "hysteria2-${svc}" default >/dev/null 2>&1 || true
    fi
}

hy2_is_active() {
    local svc="$1"
    if [ "$SVC_MGR" = "systemd" ]; then
        systemctl is-active --quiet "hysteria2-${svc}" 2>/dev/null
    else
        "/etc/init.d/hysteria2-${svc}" status 2>/dev/null | grep -q "started"
    fi
}

hy2_show_log() {
    local svc="$1"
    local logf="$HY2_LOG_DIR/${svc}.log"
    if [ -s "$logf" ]; then
        tail -n 20 "$logf"
    elif [ "$SVC_MGR" = "systemd" ] && cmd_exists journalctl; then
        journalctl -u "hysteria2-${svc}" --no-pager -n 20 2>/dev/null || echo "(无日志)"
    else
        echo "(无日志)"
    fi
}

# 生成自签证书 (hysteria2 必须配 tls 或 acme, 不配会直接拒绝启动)。
# CN 与 SAN 都写 SNI, 客户端 insecure=1 跳过校验, sniGuard 默认 dns-san
# 下 SNI 与 SAN 一致才能握手, 所以证书必须跟着 SNI 走。
hy2_gen_cert() {
    local svc="$1" sni="$2"
    local crt="$HY2_CERT_DIR/${svc}.crt" key="$HY2_CERT_DIR/${svc}.key"
    mkdir -p "$HY2_CERT_DIR"
    if [ -f "$crt" ] && [ -f "$key" ]; then return 0; fi
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$key" -out "$crt" -days 3650 \
        -subj "/CN=${sni}" -addext "subjectAltName=DNS:${sni}" 2>/dev/null || return 1
    chmod 600 "$key" 2>/dev/null || true
    chmod 644 "$crt" 2>/dev/null || true
    return 0
}

# 从 DB 读出指定 svc 的行并生成 YAML 配置 (文件扩展名必须是 .yaml，
# hysteria2 不读无后缀/错后缀的配置文件名逻辑与 xray 类似)。
hy2_gen_config() {
    local svc="$1"
    local line
    line=$(awk -F'|' -v s="$svc" '$1==s {print; exit}' "$HY2_DB" | tr -d '\r')
    [ -n "$line" ] || return 1
    local _id name port hop_type hop_start hop_end int_ports ext_ports password sni masq_type masq_value obfs obfs_pw up down ignore_bw
    IFS='|' read -r _id name port hop_type hop_start hop_end int_ports ext_ports password sni masq_type masq_value obfs obfs_pw up down ignore_bw <<< "$line"

    local listen_spec=":${port}"
    [ "$hop_type" = "range" ] && listen_spec=":${hop_start}-${hop_end}"

    mkdir -p "$HY2_ETC"
    {
        echo "listen: ${listen_spec}"
        echo "auth:"
        echo "  type: password"
        echo "  password: $(yaml_quote "$password")"
        echo "tls:"
        echo "  cert: ${HY2_CERT_DIR}/${svc}.crt"
        echo "  key: ${HY2_CERT_DIR}/${svc}.key"
        if { [ -n "$up" ] && [ "$up" != "0" ]; } || { [ -n "$down" ] && [ "$down" != "0" ]; }; then
            echo "bandwidth:"
            [ -n "$up" ] && [ "$up" != "0" ] && echo "  up: ${up} mbps"
            [ -n "$down" ] && [ "$down" != "0" ] && echo "  down: ${down} mbps"
        fi
        if [ "$ignore_bw" = "1" ]; then
            echo "ignoreClientBandwidth: true"
        else
            echo "ignoreClientBandwidth: false"
        fi
        if [ "$obfs" = "1" ]; then
            echo "obfs:"
            echo "  type: salamander"
            echo "  salamander:"
            echo "    password: $(yaml_quote "$obfs_pw")"
        fi
        echo "masquerade:"
        case "$masq_type" in
            proxy)
                echo "  type: proxy"
                echo "  proxy:"
                echo "    url: $(yaml_quote "$masq_value")"
                echo "    rewriteHost: true"
                ;;
            file)
                echo "  type: file"
                echo "  file:"
                echo "    dir: $(yaml_quote "$masq_value")"
                ;;
            string)
                echo "  type: string"
                echo "  string:"
                echo "    content: $(yaml_quote "$masq_value")"
                echo "    statusCode: 200"
                ;;
        esac
    } > "$HY2_ETC/${svc}.yaml"
    return 0
}

# 生成防火墙脚本 (每次服务启动前都会重跑, 规则已存在则跳过, 不重复)。
# 只写 UDP 规则; 端口变量全部经过校验, 空变量绝不写规则。
# v2.4.2: 生成时若 firewalld 在运行, 额外写入 firewalld 等价放行;
# 但 NAT 模式的 REDIRECT 重定向只走 iptables/ip6tables,
# firewalld 不做等价重定向 (逐端口 REDIRECT 与其 rich rule 语义
# 不等价, 强行映射容易出错), 代码里以注释标明。
hy2_gen_fw_script() {
    local svc="$1"
    local line
    line=$(awk -F'|' -v s="$svc" '$1==s {print; exit}' "$HY2_DB" | tr -d '\r')
    [ -n "$line" ] || return 1
    local _id name port hop_type hop_start hop_end int_ports ext_ports
    IFS='|' read -r _id name port hop_type hop_start hop_end int_ports ext_ports _rest <<< "$line"
    hy2_valid_port "$port" || return 1

    local fw="$HY2_ETC/${svc}.fw.sh"
    {
        echo "#!/bin/sh"
        echo "# vps_manager 自动生成: hy2 节点 ${svc} 的防火墙规则, 服务启动前重跑"
        if [ "$hop_type" = "range" ]; then
            echo "iptables -C INPUT -p udp --dport ${hop_start}:${hop_end} -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport ${hop_start}:${hop_end} -j ACCEPT 2>/dev/null"
            echo "ip6tables -C INPUT -p udp --dport ${hop_start}:${hop_end} -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport ${hop_start}:${hop_end} -j ACCEPT 2>/dev/null"
        else
            echo "iptables -C INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null"
            echo "ip6tables -C INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null"
        fi
        if [ "$hop_type" = "nat" ] && [ -n "$int_ports" ]; then
            local old_ifs="$IFS" p
            IFS=','
            for p in $int_ports; do
                IFS="$old_ifs"
                hy2_valid_port "$p" || continue
                [ "$p" = "$port" ] && continue
                echo "iptables -C INPUT -p udp --dport ${p} -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport ${p} -j ACCEPT 2>/dev/null"
                echo "ip6tables -C INPUT -p udp --dport ${p} -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport ${p} -j ACCEPT 2>/dev/null"
                echo "iptables -t nat -C PREROUTING -p udp --dport ${p} -j REDIRECT --to-ports ${port} 2>/dev/null || iptables -t nat -A PREROUTING -p udp --dport ${p} -j REDIRECT --to-ports ${port} 2>/dev/null"
                echo "ip6tables -t nat -C PREROUTING -p udp --dport ${p} -j REDIRECT --to-ports ${port} 2>/dev/null || ip6tables -t nat -A PREROUTING -p udp --dport ${p} -j REDIRECT --to-ports ${port} 2>/dev/null"
                IFS=','
            done
            IFS="$old_ifs"
        fi
        if cmd_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
            if [ "$hop_type" = "range" ]; then
                echo "ufw allow ${hop_start}:${hop_end}/udp >/dev/null 2>&1 || true"
            else
                echo "ufw allow ${port}/udp >/dev/null 2>&1 || true"
            fi
        fi
        # firewalld: 按生成时刻的状态决定是否写入, 与 ufw 处理方式一致
        if cmd_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
            if [ "$hop_type" = "range" ]; then
                echo "firewall-cmd --permanent --add-port=${hop_start}-${hop_end}/udp >/dev/null 2>&1 || true"
            else
                echo "firewall-cmd --permanent --add-port=${port}/udp >/dev/null 2>&1 || true"
            fi
            if [ "$hop_type" = "nat" ] && [ -n "$int_ports" ]; then
                local old_ifs_fw="$IFS" pf
                IFS=','
                for pf in $int_ports; do
                    IFS="$old_ifs_fw"
                    hy2_valid_port "$pf" || continue
                    echo "firewall-cmd --permanent --add-port=${pf}/udp >/dev/null 2>&1 || true"
                    IFS=','
                done
                IFS="$old_ifs_fw"
            fi
            echo "firewall-cmd --reload >/dev/null 2>&1 || true"
        fi
        echo "exit 0"
    } > "$fw"
    chmod +x "$fw"
    return 0
}

# 删除某行配置对应的防火墙规则 (删除节点 / 改端口前调用)
hy2_remove_fw() {
    local line="$1"
    [ -n "$line" ] || return 0
    local _id name port hop_type hop_start hop_end int_ports
    IFS='|' read -r _id name port hop_type hop_start hop_end int_ports _rest <<< "$line"
    hy2_valid_port "$port" || return 0
    if [ "$hop_type" = "range" ]; then
        iptables -D INPUT -p udp --dport "${hop_start}:${hop_end}" -j ACCEPT 2>/dev/null || true
        ip6tables -D INPUT -p udp --dport "${hop_start}:${hop_end}" -j ACCEPT 2>/dev/null || true
    else
        iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
        ip6tables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
    fi
    if [ "$hop_type" = "nat" ] && [ -n "$int_ports" ]; then
        local old_ifs="$IFS" p
        IFS=','
        for p in $int_ports; do
            IFS="$old_ifs"
            hy2_valid_port "$p" || continue
            [ "$p" = "$port" ] && continue
            iptables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
            ip6tables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
            iptables -t nat -D PREROUTING -p udp --dport "$p" -j REDIRECT --to-ports "$port" 2>/dev/null || true
            ip6tables -t nat -D PREROUTING -p udp --dport "$p" -j REDIRECT --to-ports "$port" 2>/dev/null || true
            IFS=','
        done
        IFS="$old_ifs"
    fi
    # v2.4.2: firewalld 正在运行时同步回收放行 (REDIRECT 部分仍只走
    # 上面的 iptables/ip6tables, firewalld 不做等价重定向回收)
    if cmd_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        if [ "$hop_type" = "range" ]; then
            firewall-cmd --permanent --remove-port="${hop_start}-${hop_end}/udp" >/dev/null 2>&1 || true
        else
            firewall-cmd --permanent --remove-port="${port}/udp" >/dev/null 2>&1 || true
        fi
        if [ "$hop_type" = "nat" ] && [ -n "$int_ports" ]; then
            local old_ifs_r="$IFS" pr
            IFS=','
            for pr in $int_ports; do
                IFS="$old_ifs_r"
                hy2_valid_port "$pr" || continue
                [ "$pr" = "$port" ] && continue
                firewall-cmd --permanent --remove-port="${pr}/udp" >/dev/null 2>&1 || true
                IFS=','
            done
            IFS="$old_ifs_r"
        fi
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    return 0
}

hy2_udp_listening() {
    ss -uln 2>/dev/null | grep -qE ":$1[[:space:]]"
}

# 启动并验收: 服务活着 + UDP 主端口在听。失败返回 1 并打日志尾巴。
hy2_start_verify() {
    local svc="$1" port="$2"
    local i
    hy2_svc_ctl "$svc" restart
    for i in 1 2 3 4 5 6; do
        sleep 1
        if hy2_is_active "$svc" && hy2_udp_listening "$port"; then
            return 0
        fi
    done
    log_error "HY2 服务启动验收失败，日志尾巴："
    hy2_show_log "$svc" | sed 's/^/    /'
    return 1
}

# 端口冲突检查: 与其他 HY2 节点的端口/段/内网端口重叠, 或已被 UDP 监听。
# exclude_svc 为空表示不排除 (新增时用)。
hy2_port_conflict() {
    local port="$1" exclude_svc="${2:-}"
    local line svc2 _n port2 hop2 start2 end2 ints2
    while IFS='|' read -r svc2 _n port2 hop2 start2 end2 ints2 _rest; do
        [ -z "$svc2" ] && continue
        case "$svc2" in '#'*) continue ;; esac
        [ -n "$exclude_svc" ] && [ "$svc2" = "$exclude_svc" ] && continue
        if [ "$hop2" = "range" ]; then
            if [ "$port" -ge "$start2" ] && [ "$port" -le "$end2" ]; then return 0; fi
        else
            [ "$port" = "$port2" ] && return 0
            if [ -n "$ints2" ]; then
                local old_ifs="$IFS" p
                IFS=','
                for p in $ints2; do
                    IFS="$old_ifs"
                    [ "$port" = "$p" ] && return 0
                    IFS=','
                done
                IFS="$old_ifs"
            fi
        fi
    done < <(cat "$HY2_DB" 2>/dev/null | tr -d '\r')
    hy2_udp_listening "$port" && return 0
    return 1
}

# 段冲突检查: [start,end] 与其他 HY2 节点端口/段重叠, 或段内已有 UDP 监听。
hy2_range_conflict() {
    local start="$1" end="$2" exclude_svc="${3:-}"
    # 注意: 绝不能逐个端口循环查 (旧写法对 30000-40000 这种万级端口段
    # 会跑 10001 次 ss, 在小机器上等于假死)。这里一次遍历 DB 做区间
    # 重叠算术判断, 再只跑一次 ss 取监听表比对, 段多大都一样快。
    local line svc2 _n port2 hop2 start2 end2 ints2
    while IFS='|' read -r svc2 _n port2 hop2 start2 end2 ints2 _rest; do
        [ -z "$svc2" ] && continue
        case "$svc2" in '#'*) continue ;; esac
        [ -n "$exclude_svc" ] && [ "$svc2" = "$exclude_svc" ] && continue
        if [ "$hop2" = "range" ]; then
            # 区间重叠: start <= end2 && start2 <= end (空字段先跳过, 防脏数据)
            case "$start2" in ''|*[!0-9]*) continue ;; esac
            case "$end2" in ''|*[!0-9]*) continue ;; esac
            if [ "$start" -le "$end2" ] && [ "$start2" -le "$end" ]; then return 0; fi
        else
            case "$port2" in ''|*[!0-9]*) ;; *) [ "$port2" -ge "$start" ] && [ "$port2" -le "$end" ] && return 0 ;; esac
            if [ -n "$ints2" ]; then
                local old_ifs="$IFS" p
                IFS=','
                for p in $ints2; do
                    IFS="$old_ifs"
                    case "$p" in ''|*[!0-9]*) ;; *) [ "$p" -ge "$start" ] && [ "$p" -le "$end" ] && return 0 ;; esac
                    IFS=','
                done
                IFS="$old_ifs"
            fi
        fi
    done < <(cat "$HY2_DB" 2>/dev/null | tr -d '\r')
    # 段内已有 UDP 监听: 一次性取表比对
    local lp
    while read -r lp; do
        case "$lp" in ''|*[!0-9]*) continue ;; esac
        if [ "$lp" -ge "$start" ] && [ "$lp" -le "$end" ]; then return 0; fi
    done < <(ss -uln 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -un)
    return 1
}

list_hy2() {
    echo -e "\n${CYAN}── Hysteria2 节点列表 ────────────────────────${NC}"
    [ ! -s "$HY2_DB" ] && { echo "  (无节点)"; return 0; }
    local idx=0
    while IFS='|' read -r svc name port hop_type hop_start hop_end int_ports ext_ports _rest; do
        [ -z "$svc" ] && continue
        case "$svc" in '#'*) continue ;; esac
        idx=$((idx + 1))
        local mode="单端口:$port"
        [ "$hop_type" = "range" ] && mode="跳跃段:${hop_start}-${hop_end}"
        [ "$hop_type" = "nat" ] && mode="NAT 外网:${ext_ports} -> 内网主端口:$port"
        local st="停止"
        hy2_is_active "$svc" && st="${GREEN}运行中${NC}"
        echo -e "  [$idx] $name  $mode  状态:$st"
    done < <(cat "$HY2_DB" 2>/dev/null | tr -d '\r')
    [ "$idx" -eq 0 ] && echo "  (无节点)"
    return 0
}

pick_hy2() {
    list_hy2
    [ ! -s "$HY2_DB" ] && return 1
    local n
    read -rp "请输入序号: " n
    n=$(echo "$n" | tr -d ' ')
    case "$n" in ''|*[!0-9]*) log_error "输入无效"; return 1;; esac
    PICKED_HY2_NUM=$(awk -v n="$n" '!/^#/ && NF {cnt++; if(cnt==n){print NR; exit}}' "$HY2_DB" | tr -d '\r')
    [ -z "$PICKED_HY2_NUM" ] && { log_error "找不到该序号"; return 1; }
    PICKED_HY2_LINE=$(sed -n "${PICKED_HY2_NUM}p" "$HY2_DB" | tr -d '\r')
    [ -z "$PICKED_HY2_LINE" ] && { log_error "读取节点数据失败"; return 1; }
    return 0
}

# 客户端地址串: range -> "起-止", nat -> 外网端口串, none -> 主端口
hy2_client_ports() {
    local hop_type="$1" port="$2" hop_start="$3" hop_end="$4" ext_ports="$5"
    case "$hop_type" in
        range) echo "${hop_start}-${hop_end}" ;;
        nat)   echo "$ext_ports" ;;
        *)     echo "$port" ;;
    esac
}

show_hy2_info() {
    local line="$1"
    local svc name port hop_type hop_start hop_end int_ports ext_ports password sni masq_type masq_value obfs obfs_pw up down ignore_bw
    IFS='|' read -r svc name port hop_type hop_start hop_end int_ports ext_ports password sni masq_type masq_value obfs obfs_pw up down ignore_bw <<< "$line"
    local cports
    cports=$(hy2_client_ports "$hop_type" "$port" "$hop_start" "$hop_end" "$ext_ports")

    local ipv4 ipv6
    ipv4=$(get_ipv4); ipv6=$(get_ipv6)
    [ -n "$ipv4" ] && echo "$ipv4" > "$DATA_DIR/server_ip" 2>/dev/null
    if [ -z "$ipv4" ] && [ -f "$DATA_DIR/server_ip" ]; then
        ipv4=$(tr -d ' \r\n' < "$DATA_DIR/server_ip" 2>/dev/null)
    fi

    local qpw qsni qname qobfs
    qpw=$(urlencode "$password")
    qsni=$(urlencode "$sni")
    qname=$(urlencode "$name")
    qobfs=$(urlencode "$obfs_pw")

    local obfs_q=""
    [ "$obfs" = "1" ] && obfs_q="&obfs=salamander&obfs-password=${qobfs}"

    echo -e "\n${CYAN}════ HY2 节点: $name ════${NC}"
    echo "服务:        hysteria2-${svc}"
    echo "主端口(UDP): $port"
    [ "$hop_type" = "range" ] && echo "跳跃段:     ${hop_start}-${hop_end} (服务端自动重定向, 客户端默认 30 秒一跳)"
    [ "$hop_type" = "nat" ] && echo "NAT 映射:   外网 ${ext_ports} -> 内网主端口 $port (内网端口: ${int_ports})"
    echo "SNI:         $sni"
    echo "密码:        $password"
    [ "$obfs" = "1" ] && echo "混淆:        salamander (密码与认证密码不同)"
    [ "$obfs" != "1" ] && echo "混淆:        未开启"
    echo "伪装:        $masq_type ($masq_value)"
    echo "带宽:        上行 ${up:-不限} Mbps / 下行 ${down:-不限} Mbps (0=不限, 服务端封顶)"
    [ "$ignore_bw" = "1" ] && echo "忽略客户端带宽: 是 (强制 BBR, 不用 Brutal)"
    echo -e "${YELLOW}注意: 本节点用自签证书, 客户端必须 insecure=1 (跳过校验)。${NC}"

    local host4="$ipv4"
    if [ -z "$host4" ]; then
        host4="你的服务器IP"
        echo -e "${YELLOW}提示: 未能自动检测公网 IP，已用占位符生成链接，请把「你的服务器IP」替换为实际 IP${NC}"
    fi
    echo -e "\n${GREEN}── HY2 URI (IPv4) ──${NC}\n${YELLOW}hysteria2://${qpw}@${host4}:${cports}?sni=${qsni}&insecure=1${obfs_q}#${qname}${NC}"
    if [ -n "$ipv6" ]; then
        echo -e "\n${GREEN}── HY2 URI (IPv6) ──${NC}\n${YELLOW}hysteria2://${qpw}@[${ipv6}]:${cports}?sni=${qsni}&insecure=1${obfs_q}#${qname}-v6${NC}"
    fi
    echo -e "\n${GREEN}── Mihomo (Clash Meta) 配置片段 ──${NC}"
    echo "  - name: \"$name\""
    echo "    type: hysteria2"
    echo "    server: ${host4}"
    if [ "$hop_type" = "none" ]; then
        echo "    port: ${port}"
    else
        echo "    ports: \"${cports}\""
    fi
    echo "    password: \"$password\""
    echo "    sni: $sni"
    echo "    skip-cert-verify: true"
    if [ "$obfs" = "1" ]; then
        echo "    obfs: salamander"
        echo "    obfs-password: \"$obfs_pw\""
    fi
    [ -n "$up" ] && [ "$up" != "0" ] && echo "    up: $up"
    [ -n "$down" ] && [ "$down" != "0" ] && echo "    down: $down"
    echo -e "${CYAN}═════════════════════${NC}\n"
}

add_hy2() {
    log_title "添加 Hysteria2 节点"
    [ ! -x "$HY2_BIN" ] && { system_init; install_hysteria || return 1; }
    mkdir -p "$HY2_ETC" "$HY2_CERT_DIR" "$HY2_LOG_DIR"
    touch "$HY2_DB" 2>/dev/null || true

    local name
    read -rp "节点名称 [回车=自动]: " name
    [ -z "$name" ] && name="HY2-$(date +%m%d-%H%M)"
    name=$(sanitize_field "$name")
    [ -z "$name" ] && name="HY2-$(date +%m%d-%H%M)"

    echo ""
    echo "  服务器类型 (决定端口跳跃怎么做):"
    echo "  1) 非 NAT 机: 公网 IP 直接在网卡上，端口段可大范围跳跃"
    echo "  2) NAT 机: 面板只映射了少量端口，外网端口最多用 3 个"
    local nat_choice
    read -rp "请选择 [1/2, 回车=1]: " nat_choice
    nat_choice=${nat_choice:-1}

    local port hop_type="none" hop_start="" hop_end="" int_ports="" ext_ports=""
    if [ "$nat_choice" = "2" ]; then
        hop_type="nat"
        echo -e "${YELLOW}请先在面板把外网端口映射到内网端口，再填下面两项。${NC}"
        while true; do
            read -rp "外网端口串 (如 40001-40003 或 40001,40002，最多 3 个端口): " ext_ports
            ext_ports=$(echo "$ext_ports" | tr -d ' ')
            local cnt
            cnt=$(hy2_count_ports "$ext_ports" 2>/dev/null || echo "0")
            if [ "$cnt" -ge 1 ] && [ "$cnt" -le 3 ]; then break; fi
            log_error "外网端口串无效或超过 3 个端口 (当前算出 $cnt 个)，请重填"
        done
        read -rp "内网端口串 (与外网一一对应，逗号分隔；回车=与外网端口相同): " int_ports
        int_ports=$(echo "$int_ports" | tr -d ' ')
        [ -z "$int_ports" ] && int_ports="$ext_ports"
        # 内网串若是范围先展开成列表 (REDIRECT 只能逐个端口写)
        if echo "$int_ports" | grep -q '-'; then
            local expanded="" part a b p
            local old_ifs="$IFS"; IFS=','
            for part in $int_ports; do
                IFS="$old_ifs"
                case "$part" in
                    *-* )
                        a="${part%%-*}"; b="${part##*-}"
                        for p in $(seq "$a" "$b" 2>/dev/null); do expanded="${expanded}${expanded:+,}${p}"; done
                        ;;
                    * ) expanded="${expanded}${expanded:+,}${part}" ;;
                esac
                IFS=','
            done
            IFS="$old_ifs"
            int_ports="$expanded"
        fi
        # 校验: 内网端口数 = 外网端口数, 或内网只有 1 个 (全部外网端口都映射到它)
        local int_cnt ext_cnt
        int_cnt=$(echo "$int_ports" | awk -F',' '{print NF}')
        ext_cnt=$(hy2_count_ports "$ext_ports")
        if [ "$int_cnt" != "$ext_cnt" ] && [ "$int_cnt" != "1" ]; then
            log_error "内网端口数 ($int_cnt) 既不等于外网端口数 ($ext_cnt) 也不为 1，请重填"
            return 1
        fi
        # 内网端口逐个校验为数字 (范围已在上面展开，残留非法 token 在此拦下)
        local tok
        local old_ifs2="$IFS"; IFS=','
        for tok in $int_ports; do
            IFS="$old_ifs2"
            hy2_valid_port "$tok" || { log_error "内网端口串含非法端口: $tok"; return 1; }
            IFS=','
        done
        IFS="$old_ifs2"
        port=$(echo "$int_ports" | cut -d',' -f1)
        if ! hy2_valid_port "$port"; then log_error "内网主端口无效"; return 1; fi
        if hy2_port_conflict "$port"; then log_error "内网主端口 $port 已被其他 HY2 节点占用或已被 UDP 监听"; return 1; fi
    else
        echo ""
        echo "  1) 单端口 (默认)"
        echo "  2) 端口段跳跃 (服务端自动重定向，客户端默认 30 秒一跳)"
        local hop_choice
        read -rp "请选择 [1/2, 回车=1]: " hop_choice
        hop_choice=${hop_choice:-1}
        while true; do
            read -rp "主端口 (UDP) [回车=443]: " port
            [ -z "$port" ] && port=443
            hy2_valid_port "$port" || { log_error "端口必须是 1-65535 的数字"; continue; }
            hy2_port_conflict "$port" && { log_error "端口 $port 已被其他 HY2 节点占用或已被 UDP 监听"; continue; }
            break
        done
        if [ "$hop_choice" = "2" ]; then
            hop_type="range"
            hop_start="$port"
            while true; do
                read -rp "跳跃段结束端口 (必须大于 $hop_start，如 50000): " hop_end
                hy2_valid_port "$hop_end" || { log_error "端口必须是 1-65535 的数字"; continue; }
                [ "$hop_end" -le "$hop_start" ] && { log_error "结束端口必须大于起始端口"; continue; }
                hy2_range_conflict "$hop_start" "$hop_end" && { log_error "该端口段与已有 HY2 节点或 UDP 监听冲突"; continue; }
                break
            done
            ext_ports="${hop_start}-${hop_end}"
        fi
    fi

    local password
    read -rp "认证密码 [回车=自动生成 32 位强密码]: " password
    password=$(echo "$password" | tr -d ' ')
    if [ -z "$password" ]; then
        password=$(hy2_gen_hex 16)
    elif [ "${#password}" -lt 12 ]; then
        log_error "自定义密码太短，至少 12 位 (建议直接回车自动生成)"
        return 1
    fi

    local sni
    read -rp "SNI 域名 [回车=www.bing.com]: " sni
    [ -z "$sni" ] && sni="www.bing.com"
    sni=$(sanitize_field "$sni")
    [ -z "$sni" ] && sni="www.bing.com"

    echo ""
    echo "  服务端伪装 Masquerade (非 HY2 客户端访问时看到的内容):"
    echo "  1) 反代真实网站 (默认)"
    echo "  2) 本地文件目录"
    echo "  3) 固定字符串"
    local masq_choice masq_type masq_value
    read -rp "请选择 [1/2/3, 回车=1]: " masq_choice
    masq_choice=${masq_choice:-1}
    case "$masq_choice" in
        2)
            masq_type="file"
            read -rp "本地目录 [回车=/var/www/masq]: " masq_value
            [ -z "$masq_value" ] && masq_value="/var/www/masq"
            mkdir -p "$masq_value" 2>/dev/null || true
            if [ ! -f "$masq_value/index.html" ]; then
                printf '<html><head><title>Welcome</title></head><body><h1>Welcome to nginx!</h1></body></html>\n' > "$masq_value/index.html" 2>/dev/null || true
            fi
            ;;
        3)
            masq_type="string"
            read -rp "固定返回内容 [回车=Hello World]: " masq_value
            [ -z "$masq_value" ] && masq_value="Hello World"
            ;;
        *)
            masq_type="proxy"
            read -rp "反代目标 URL [回车=https://www.bing.com]: " masq_value
            [ -z "$masq_value" ] && masq_value="https://www.bing.com"
            ;;
    esac
    masq_value=$(sanitize_field "$masq_value")

    echo ""
    echo -e "${YELLOW}关于混淆 Obfs 的权衡:${NC}"
    echo "  salamander 会把每个包打乱成无规律字节，能绕过只针对 QUIC/HTTP3"
    echo "  特征的封锁；但它不防 UDP 整体封锁、会增加 CPU 开销、且开启后"
    echo "  不再兼容标准 QUIC 探测。网络本身没针对性封锁时，不开更快更稳。"
    local obfs="0" obfs_pw=""
    read -rp "是否开启 salamander 混淆? [y/N]: " obfs_ans
    if [ "${obfs_ans:-N}" = "y" ] || [ "${obfs_ans:-N}" = "Y" ]; then
        obfs="1"
        read -rp "混淆密码 [回车=自动生成，必须与认证密码不同]: " obfs_pw
        obfs_pw=$(echo "$obfs_pw" | tr -d ' ')
        if [ -z "$obfs_pw" ]; then
            obfs_pw=$(hy2_gen_hex 16)
        elif [ "${#obfs_pw}" -lt 12 ]; then
            log_error "混淆密码太短，至少 12 位"
            return 1
        elif [ "$obfs_pw" = "$password" ]; then
            log_error "混淆密码不能与认证密码相同"
            return 1
        fi
    fi

    local up down
    echo ""
    echo "  带宽限制 (写进服务端，封顶 Brutal 的发送速率；服务端上行=客户端下行，反之亦然；"
    echo "  不要高于线路真实速度，否则反而变慢不稳定；0 = 不限，走 BBR 自适应)"
    read -rp "上行 Mbps [回车=0 不限]: " up; up=${up:-0}
    read -rp "下行 Mbps [回车=0 不限]: " down; down=${down:-0}
    hy2_is_uint "$up" || { log_error "上行必须是数字"; return 1; }
    hy2_is_uint "$down" || { log_error "下行必须是数字"; return 1; }

    local ignore_bw="0"
    read -rp "是否忽略客户端带宽 (强制 BBR，不用 Brutal，适合求公平不抢占)? [y/N]: " ig_ans
    if [ "${ig_ans:-N}" = "y" ] || [ "${ig_ans:-N}" = "Y" ]; then ignore_bw="1"; fi

    local svc
    svc=$(hy2_new_svc_id)
    local newline
    newline=$(printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
        "$svc" "$name" "$port" "$hop_type" "$hop_start" "$hop_end" "$int_ports" "$ext_ports" \
        "$password" "$sni" "$masq_type" "$masq_value" "$obfs" "$obfs_pw" "$up" "$down" "$ignore_bw")
    printf '%s\n' "$newline" >> "$HY2_DB"
    sanitize_db

    if ! hy2_gen_cert "$svc" "$sni"; then
        log_error "证书生成失败"
        grep -v "^${svc}|" "$HY2_DB" > "$HY2_DB.tmp" && mv "$HY2_DB.tmp" "$HY2_DB"
        return 1
    fi
    if ! hy2_gen_config "$svc" || ! hy2_gen_fw_script "$svc"; then
        log_error "HY2 配置生成失败"
        grep -v "^${svc}|" "$HY2_DB" > "$HY2_DB.tmp" && mv "$HY2_DB.tmp" "$HY2_DB"
        return 1
    fi
    sh "$HY2_ETC/${svc}.fw.sh" >/dev/null 2>&1 || true
    write_hy2_service "$svc"
    hy2_svc_enable "$svc"

    if hy2_start_verify "$svc" "$port"; then
        log_success "HY2 节点添加成功！"
        show_hy2_info "$newline"
    else
        # 段跳跃失败时，常见原因是内核缺 NAT 支持：自动降级为单端口
        if [ "$hop_type" = "range" ]; then
            log_warn "端口段模式启动失败 (常见原因：内核缺 NAT 模块，hysteria2 建不了重定向规则)，自动降级为单端口重试..."
            # 先清掉段模式那次 fw 脚本已写入的段 INPUT 规则，否则残留的段规则会一直留在防火墙里
            local old_line
            old_line=$(awk -F'|' -v s="$svc" '$1==s {print; exit}' "$HY2_DB" | tr -d '\r')
            hy2_remove_fw "$old_line"
            local tmp
            tmp=$(mktemp)
            awk -F'|' -v s="$svc" 'BEGIN{OFS="|"} $1==s{$4="none"; $5=""; $6=""; $8="";} {print}' "$HY2_DB" > "$tmp" && mv "$tmp" "$HY2_DB"
            sanitize_db
            hy2_gen_config "$svc" && hy2_gen_fw_script "$svc" && sh "$HY2_ETC/${svc}.fw.sh" >/dev/null 2>&1 || true
            if hy2_start_verify "$svc" "$port"; then
                log_success "已降级为单端口模式并启动成功 (跳跃段在此机上不可用)。"
                local new_line
                new_line=$(awk -F'|' -v s="$svc" '$1==s {print; exit}' "$HY2_DB" | tr -d '\r')
                show_hy2_info "$new_line"
                return 0
            fi
        fi
        log_error "HY2 节点启动失败，已回滚删除该节点"
        hy2_svc_ctl "$svc" stop
        hy2_svc_disable "$svc"
        hy2_remove_fw "$newline"
        rm -f "$HY2_ETC/${svc}.yaml" "$HY2_ETC/${svc}.fw.sh" "$HY2_CERT_DIR/${svc}.crt" "$HY2_CERT_DIR/${svc}.key"
        [ "$SVC_MGR" = "systemd" ] && rm -f "/etc/systemd/system/hysteria2-${svc}.service" && systemctl daemon-reload 2>/dev/null || true
        [ "$SVC_MGR" != "systemd" ] && rm -f "/etc/init.d/hysteria2-${svc}"
        grep -v "^${svc}|" "$HY2_DB" > "$HY2_DB.tmp" && mv "$HY2_DB.tmp" "$HY2_DB"
        return 1
    fi
}

edit_hy2() {
    log_title "修改 HY2 节点 (无损生效，端口/跳跃结构也可改)"
    pick_hy2 || return
    local old_line="$PICKED_HY2_LINE"
    local svc name port hop_type hop_start hop_end int_ports ext_ports password sni masq_type masq_value obfs obfs_pw up down ignore_bw
    IFS='|' read -r svc name port hop_type hop_start hop_end int_ports ext_ports password sni masq_type masq_value obfs obfs_pw up down ignore_bw <<< "$old_line"

    echo -e "${CYAN}当前节点信息:${NC}"
    echo " 名称: $name / 主端口: $port / 类型: $hop_type"
    echo " SNI: $sni / 伪装: $masq_type ($masq_value)"
    echo " 带宽: 上行 ${up} / 下行 ${down} Mbps / 混淆: $obfs"
    echo -e "${YELLOW}提示: 下面输入新值，直接回车保持不变。端口与跳跃结构改动会重建防火墙规则。${NC}\n"

    local nn np nhop nhs nhe nint next npw nsni nmasq_type nmasq_value nobfs nobfs_pw nup ndown nig
    read -rp "新名称 [$name]: " nn; [ -z "$nn" ] && nn="$name"
    nn=$(sanitize_field "$nn"); [ -z "$nn" ] && nn="$name"

    read -rp "新主端口 [$port]: " np; [ -z "$np" ] && np="$port"
    hy2_valid_port "$np" || { log_error "端口必须是 1-65535 的数字"; return 1; }
    if [ "$np" != "$port" ] && hy2_port_conflict "$np" "$svc"; then log_error "端口 $np 已被占用"; return 1; fi

    echo "  跳跃类型: 1) 单端口 2) 端口段 (非 NAT) 3) NAT 映射 (当前: $hop_type)"
    read -rp "新跳跃类型 [回车=不变]: " nhop
    local nhop_type="$hop_type" nhop_start="$hop_start" nhop_end="$hop_end" nint_ports="$int_ports" next_ports="$ext_ports"
    case "$nhop" in
        1) nhop_type="none"; nhop_start=""; nhop_end=""; nint_ports=""; next_ports="" ;;
        2)
            nhop_type="range"; nhop_start="$np"; nint_ports=""
            read -rp "新跳跃段结束端口 [当前 ${hop_end:-无}]: " nhe
            [ -z "$nhe" ] && nhe="$hop_end"
            hy2_valid_port "$nhe" || { log_error "结束端口无效"; return 1; }
            [ "$nhe" -le "$np" ] && { log_error "结束端口必须大于起始端口"; return 1; }
            hy2_range_conflict "$np" "$nhe" "$svc" && { log_error "该端口段与已有 HY2 节点或 UDP 监听冲突"; return 1; }
            nhop_end="$nhe"; next_ports="${np}-${nhe}"
            ;;
        3)
            nhop_type="nat"
            read -rp "新外网端口串 (最多 3 个端口): " next_ports
            next_ports=$(echo "$next_ports" | tr -d ' ')
            local cnt
            cnt=$(hy2_count_ports "$next_ports" 2>/dev/null || echo "0")
            if [ "$cnt" -lt 1 ] || [ "$cnt" -gt 3 ]; then log_error "外网端口串无效或超过 3 个端口"; return 1; fi
            read -rp "新内网端口串 (逗号分隔，回车=与外网相同): " nint_ports
            nint_ports=$(echo "$nint_ports" | tr -d ' ')
            [ -z "$nint_ports" ] && nint_ports="$next_ports"
            ;;
        *) ;;
    esac
    if [ "$nhop_type" = "nat" ]; then
        # 内网串若是范围先展开成列表 (与添加时一致, REDIRECT 只能逐个端口写)
        if echo "$nint_ports" | grep -q '-'; then
            local nexpanded="" npart na nb npt
            local old_ifs_n="$IFS"; IFS=','
            for npart in $nint_ports; do
                IFS="$old_ifs_n"
                case "$npart" in
                    *-* )
                        na="${npart%%-*}"; nb="${npart##*-}"
                        for npt in $(seq "$na" "$nb" 2>/dev/null); do nexpanded="${nexpanded}${nexpanded:+,}${npt}"; done
                        ;;
                    * ) nexpanded="${nexpanded}${nexpanded:+,}${npart}" ;;
                esac
                IFS=','
            done
            IFS="$old_ifs_n"
            nint_ports="$nexpanded"
        fi
        # 内网端口逐个校验为数字 (残留非法 token 在此拦下, 与添加时一致)
        local ntok old_ifs_t="$IFS"; IFS=','
        for ntok in $nint_ports; do
            IFS="$old_ifs_t"
            hy2_valid_port "$ntok" || { log_error "内网端口串含非法端口: $ntok"; return 1; }
            IFS=','
        done
        IFS="$old_ifs_t"
        local np_first
        np_first=$(echo "$nint_ports" | cut -d',' -f1)
        if [ "$np_first" != "$np" ]; then
            # 内网首端口即主端口，保持一致
            np="$np_first"
            hy2_valid_port "$np" || { log_error "内网主端口无效"; return 1; }
            if [ "$np" != "$port" ] && hy2_port_conflict "$np" "$svc"; then log_error "内网主端口 $np 已被占用"; return 1; fi
        fi
        local nint_cnt next_cnt
        nint_cnt=$(echo "$nint_ports" | awk -F',' '{print NF}')
        next_cnt=$(hy2_count_ports "$next_ports" 2>/dev/null || echo "0")
        if [ "$nint_cnt" != "$next_cnt" ] && [ "$nint_cnt" != "1" ]; then
            log_error "内网端口数 ($nint_cnt) 既不等于外网端口数 ($next_cnt) 也不为 1"
            return 1
        fi
    fi

    read -rp "新认证密码 (回车保持，输入新值则更换): " npw
    [ -z "$npw" ] && npw="$password"
    npw=$(echo "$npw" | tr -d ' ')
    if [ "${#npw}" -lt 12 ]; then log_error "密码至少 12 位"; return 1; fi

    read -rp "新 SNI [$sni]: " nsni; [ -z "$nsni" ] && nsni="$sni"
    nsni=$(sanitize_field "$nsni"); [ -z "$nsni" ] && nsni="$sni"

    echo "  伪装: 1) 反代 2) 本地文件 3) 固定字符串 (当前: $masq_type)"
    read -rp "新伪装类型 [回车=不变]: " nmasq_type
    nmasq_value="$masq_value"
    case "$nmasq_type" in
        1) masq_type="proxy"; read -rp "新反代 URL [$masq_value]: " nmasq_value; [ -z "$nmasq_value" ] && nmasq_value="$masq_value" ;;
        2) masq_type="file"; read -rp "新本地目录 [$masq_value]: " nmasq_value; [ -z "$nmasq_value" ] && nmasq_value="$masq_value"; mkdir -p "$nmasq_value" 2>/dev/null || true ;;
        3) masq_type="string"; read -rp "新固定内容 [$masq_value]: " nmasq_value; [ -z "$nmasq_value" ] && nmasq_value="$masq_value" ;;
        *) ;;
    esac
    nmasq_value=$(sanitize_field "$nmasq_value"); [ -z "$nmasq_value" ] && nmasq_value="$masq_value"

    read -rp "混淆开关 (当前 $obfs，输入 1 开启 / 0 关闭，回车=不变): " nobfs
    [ -z "$nobfs" ] && nobfs="$obfs"
    nobfs_pw="$obfs_pw"
    if [ "$nobfs" = "1" ] && [ -z "$nobfs_pw" ]; then
        read -rp "混淆密码 [回车=自动生成]: " nobfs_pw
        nobfs_pw=$(echo "$nobfs_pw" | tr -d ' ')
        [ -z "$nobfs_pw" ] && nobfs_pw=$(hy2_gen_hex 16)
    fi
    if [ "$nobfs" = "1" ] && [ "$nobfs_pw" = "$npw" ]; then log_error "混淆密码不能与认证密码相同"; return 1; fi
    [ "$nobfs" != "1" ] && nobfs="0"

    read -rp "新上行 Mbps [$up]: " nup; [ -z "$nup" ] && nup="$up"
    read -rp "新下行 Mbps [$down]: " ndown; [ -z "$ndown" ] && ndown="$down"
    hy2_is_uint "$nup" && hy2_is_uint "$ndown" || { log_error "带宽必须是数字"; return 1; }

    read -rp "忽略客户端带宽 (当前 $ignore_bw，输入 1/0，回车=不变): " nig
    [ -z "$nig" ] && nig="$ignore_bw"
    [ "$nig" != "1" ] && nig="0"

    local newline
    newline=$(printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
        "$svc" "$nn" "$np" "$nhop_type" "$nhop_start" "$nhop_end" "$nint_ports" "$next_ports" \
        "$npw" "$nsni" "$masq_type" "$nmasq_value" "$nobfs" "$nobfs_pw" "$nup" "$ndown" "$nig")
    replace_line_by_num "$HY2_DB" "$PICKED_HY2_NUM" "$newline"
    sanitize_db

    # 先清旧防火墙规则，再按新配置重建 (SNI 变了则证书重建)
    hy2_remove_fw "$old_line"
    if [ "$nsni" != "$sni" ]; then
        rm -f "$HY2_CERT_DIR/${svc}.crt" "$HY2_CERT_DIR/${svc}.key"
    fi
    if ! hy2_gen_cert "$svc" "$nsni" || ! hy2_gen_config "$svc" || ! hy2_gen_fw_script "$svc"; then
        log_error "配置生成失败，正在恢复旧配置"
        replace_line_by_num "$HY2_DB" "$PICKED_HY2_NUM" "$old_line"
        hy2_gen_config "$svc" && hy2_gen_fw_script "$svc"
        hy2_svc_ctl "$svc" restart
        return 1
    fi
    sh "$HY2_ETC/${svc}.fw.sh" >/dev/null 2>&1 || true
    write_hy2_service "$svc"
    hy2_svc_enable "$svc"
    if hy2_start_verify "$svc" "$np"; then
        log_success "HY2 节点修改成功，已重载生效"
        show_hy2_info "$newline"
    else
        log_error "新配置启动失败，正在恢复旧配置"
        hy2_remove_fw "$newline"
        replace_line_by_num "$HY2_DB" "$PICKED_HY2_NUM" "$old_line"
        hy2_gen_config "$svc" && hy2_gen_fw_script "$svc"
        sh "$HY2_ETC/${svc}.fw.sh" >/dev/null 2>&1 || true
        hy2_svc_ctl "$svc" restart
    fi
}

delete_hy2() {
    log_title "删除 HY2 节点"
    pick_hy2 || return
    local svc name
    IFS='|' read -r svc name _rest <<< "$PICKED_HY2_LINE"
    read -rp "确认删除 HY2 节点 '$name'? [y/N]: " c
    [ "${c:-N}" != "y" ] && [ "${c:-N}" != "Y" ] && return

    hy2_svc_ctl "$svc" stop
    hy2_svc_disable "$svc"
    hy2_remove_fw "$PICKED_HY2_LINE"
    rm -f "$HY2_ETC/${svc}.yaml" "$HY2_ETC/${svc}.fw.sh" "$HY2_CERT_DIR/${svc}.crt" "$HY2_CERT_DIR/${svc}.key"
    if [ "$SVC_MGR" = "systemd" ]; then
        rm -f "/etc/systemd/system/hysteria2-${svc}.service"
        systemctl daemon-reload 2>/dev/null || true
    else
        rm -f "/etc/init.d/hysteria2-${svc}"
    fi
    delete_line_by_num "$HY2_DB" "$PICKED_HY2_NUM"
    sanitize_db
    log_success "已删除 HY2 节点: $name"
}

view_hy2() {
    log_title "查看单个 HY2 节点信息"
    pick_hy2 || return
    show_hy2_info "$PICKED_HY2_LINE"
}

view_all_hy2() {
    log_title "所有 HY2 节点信息"
    if [ ! -s "$HY2_DB" ]; then
        echo "  (无节点)"
        return
    fi
    while IFS='|' read -r line; do
        [ -z "$line" ] && continue
        case "$line" in '#'*) continue ;; esac
        show_hy2_info "$line"
    done < <(cat "$HY2_DB" | tr -d '\r')
}

test_hy2() {
    log_title "检测 HY2 节点状态"
    pick_hy2 || return
    local svc name port hop_type hop_start hop_end int_ports ext_ports password sni masq_type masq_value
    IFS='|' read -r svc name port hop_type hop_start hop_end int_ports ext_ports password sni masq_type masq_value _rest <<< "$PICKED_HY2_LINE"
    echo ""

    log_step "1. HY2 服务状态..."
    if hy2_is_active "$svc"; then
        log_success "HY2 运行中"
    else
        log_error "HY2 未运行，尝试启动..."
        hy2_svc_ctl "$svc" start
        hy2_is_active "$svc" && log_success "已成功启动" || log_error "启动失败，请查看日志"
    fi

    log_step "2. UDP 主端口 $port 监听检查..."
    if hy2_udp_listening "$port"; then
        log_success "UDP 端口 $port 正在监听"
    else
        log_warn "UDP 端口 $port 未检测到监听"
    fi

    log_step "3. 证书有效期..."
    local crt="$HY2_CERT_DIR/${svc}.crt"
    if [ -f "$crt" ]; then
        openssl x509 -noout -enddate -in "$crt" 2>/dev/null | sed 's/^/    /'
        openssl x509 -noout -checkend 0 -in "$crt" >/dev/null 2>&1 && log_success "证书未过期" || log_warn "证书已过期，请修改节点 (换 SNI) 重建证书"
    else
        log_warn "证书文件缺失"
    fi

    log_step "4. 伪装目标可达性..."
    if [ "$masq_type" = "proxy" ]; then
        local hc
        hc=$(curl -sI --max-time 5 "$masq_value" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "0")
        case "$hc" in
            2*|3*) log_success "伪装目标 $masq_value 连通正常 (HTTP $hc)" ;;
            *)     log_warn "伪装目标 $masq_value 返回异常 ($hc)" ;;
        esac
    else
        log_info "伪装类型 $masq_type 无需外网可达性检查"
    fi

    log_step "5. 配置文件..."
    if [ -f "$HY2_ETC/${svc}.yaml" ]; then
        log_success "配置文件存在: $HY2_ETC/${svc}.yaml"
    else
        log_error "配置文件缺失"
    fi
    echo ""
    log_success "检测完成 - [$name] 状态检查结束"
}

hy2_menu() {
    [ ! -x "$HY2_BIN" ] && { system_init; install_hysteria || return 1; }
    mkdir -p "$HY2_ETC" "$HY2_CERT_DIR" "$HY2_LOG_DIR"
    touch "$HY2_DB" 2>/dev/null || true
    sanitize_db
    while true; do
        log_title "Hysteria2 节点管理"
        list_hy2; echo ""
        echo "  1) 添加 HY2 节点"
        echo "  2) 查看单个 HY2 节点信息 & URI"
        echo "  3) 查看所有 HY2 节点信息 & URI"
        echo "  4) 修改 HY2 节点"
        echo "  5) 删除 HY2 节点"
        echo "  6) 检测 HY2 节点状态"
        echo "  0) 返回主菜单"
        read -rp "选择: " c
        case "$c" in
            1) add_hy2 ;; 2) view_hy2 ;; 3) view_all_hy2 ;; 4) edit_hy2 ;; 5) delete_hy2 ;; 6) test_hy2 ;; 0) break ;; *) ;;
        esac
    done
}

# ==============================================================
# 开机自启修复 (v2.4.0 新增)
# 旧脚本的问题定位:
#   OpenRC 分支的 start_xray 只 restart，从未 rc-update add，
#   所以 Alpine 机重启后 xray 不自启；systemd 分支的 enable
#   失败被重定向吞掉且从未校验。本节补齐 + 校验 + 明说。
# ==============================================================
ensure_xray_autostart() {
    [ -x "$XRAY_BIN" ] || return 0
    if [ "$SVC_MGR" = "systemd" ]; then
        if systemctl is-enabled xray 2>/dev/null | grep -qx "enabled"; then return 0; fi
        systemctl enable xray >/dev/null 2>&1 || true
        if systemctl is-enabled xray 2>/dev/null | grep -qx "enabled"; then
            log_success "Xray 开机自启已补齐 (systemctl enable)"
            return 0
        fi
        log_error "Xray 开机自启开启失败：systemctl enable 未生效 (若为无 systemd 的容器，请改用宿主或其他启动方式)"
        return 1
    else
        if rc-update show default 2>/dev/null | grep -qw "xray"; then return 0; fi
        rc-update add xray default >/dev/null 2>&1 || true
        if rc-update show default 2>/dev/null | grep -qw "xray"; then
            log_success "Xray 开机自启已补齐 (rc-update add xray default)"
            return 0
        fi
        log_error "Xray 开机自启开启失败：rc-update add 未生效"
        return 1
    fi
}

ensure_hy2_autostart() {
    [ -x "$HY2_BIN" ] || return 0
    [ ! -s "$HY2_DB" ] && return 0
    local svc line
    while IFS='|' read -r line; do
        [ -z "$line" ] && continue
        case "$line" in '#'*) continue ;; esac
        svc=$(echo "$line" | cut -d'|' -f1)
        [ -z "$svc" ] && continue
        if hy2_svc_enabled "$svc"; then continue; fi
        hy2_svc_enable "$svc"
        if hy2_svc_enabled "$svc"; then
            log_success "HY2 节点 $svc 开机自启已补齐"
        else
            log_error "HY2 节点 $svc 开机自启开启失败"
        fi
    done < <(cat "$HY2_DB" | tr -d '\r')
    return 0
}

ensure_autostart_all() {
    ensure_xray_autostart || true
    ensure_hy2_autostart || true
    return 0
}

# 清空全部 HY2 足迹 (仅用于“清空重装 / 一键全新初始化”)
hy2_wipe_all() {
    [ ! -s "$HY2_DB" ] && [ ! -d "$HY2_ETC" ] && return 0
    local line svc
    while IFS='|' read -r line; do
        [ -z "$line" ] && continue
        case "$line" in '#'*) continue ;; esac
        svc=$(echo "$line" | cut -d'|' -f1)
        [ -z "$svc" ] && continue
        hy2_svc_ctl "$svc" stop
        hy2_svc_disable "$svc"
        hy2_remove_fw "$line"
        if [ "$SVC_MGR" = "systemd" ]; then
            rm -f "/etc/systemd/system/hysteria2-${svc}.service"
        else
            rm -f "/etc/init.d/hysteria2-${svc}"
        fi
    done < <(cat "$HY2_DB" 2>/dev/null | tr -d '\r')
    [ "$SVC_MGR" = "systemd" ] && systemctl daemon-reload 2>/dev/null || true
    rm -rf "$HY2_ETC" "$HY2_LOG_DIR"
    rm -f "$HY2_DB"
    return 0
}

# ==============================================================
# Xray 内核升级 (v2.4.2 新增, 主菜单 13)
# 与 install_xray 分工: install 只负责“无 → 有”且锁版本; 升级走
# 这里。旧二进制先备份, 新内核验收不过自动回滚, 全程菜单操作。
# ==============================================================
upgrade_xray() {
    log_title "升级 Xray 内核"
    if [ ! -x "$XRAY_BIN" ]; then
        log_warn "本机尚未安装 Xray, 请先用主菜单 [1) 添加节点] 完成安装 (将安装锁定版本 ${XRAY_VERSION_PIN})。"
        return 1
    fi
    xray_kernel_version
    local cur="$XRAY_VER_STR"
    echo -e " 当前内核版本: ${CYAN}Xray ${cur:-未知}${NC}"
    echo -e " 锁定版本 (推荐): ${GREEN}${XRAY_VERSION_PIN}${NC}"
    echo ""
    echo "  1) 升级到锁定版本 ${XRAY_VERSION_PIN} (推荐, 已验证)"
    echo "  2) 升级到官方最新版 (版本未知, 可能引入未验证的协议变更)"
    echo "  0) 取消"
    local ch target=""
    read -rp "请选择 [1/2/0]: " ch
    case "$ch" in
        1) target="$XRAY_VERSION_PIN" ;;
        2)
            target=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"\(v[^"]*\)".*/\1/')
            if [ -z "$target" ]; then log_error "获取官方最新版本失败, 已取消"; return 1; fi
            log_warn "目标为官方最新版 ${target}: 未经本脚本验证, 升级后请第一时间用客户端实测各节点连通性。"
            ;;
        *) log_info "已取消升级"; return 0 ;;
    esac

    local target_num="${target#v}"
    if [ -n "$cur" ] && [ "$cur" = "$target_num" ]; then
        log_success "当前已是 ${target}, 无需升级。"
        return 0
    fi

    local tmp
    tmp=$(mktemp -d)
    log_step "下载 Xray ${target}..."
    if ! xray_fetch_zip "$target" "$tmp"; then
        log_error "下载或解压失败, 内核未做任何更换。"
        rm -rf "$tmp"
        return 1
    fi

    # 备份旧二进制与 .dat (目录名带旧版本号与时间戳)
    local ts bakdir
    ts=$(date +%Y%m%d-%H%M%S)
    bakdir="$BACKUP_DIR/xray-core-${cur:-unknown}-${ts}"
    mkdir -p "$bakdir"
    cp -a "$XRAY_BIN" "$bakdir/xray" 2>/dev/null || true
    cp -a /usr/local/share/xray/*.dat "$bakdir/" 2>/dev/null || true
    log_info "旧内核已备份到: $bakdir"

    # 是否跨过 26.9.8 边界 (旧 < 26.9.8 且 新 >= 26.9.8)
    local crossed=0 cc tc
    if [ -n "$cur" ]; then
        ver_cmp "v$cur" "v26.9.8"; cc=$?
        ver_cmp "$target" "v26.9.8"; tc=$?
        if [ "$cc" -eq 2 ] && [ "$tc" -ne 2 ]; then crossed=1; fi
    fi

    log_step "替换内核并重启服务..."
    if [ "$SVC_MGR" = "systemd" ]; then systemctl stop xray >/dev/null 2>&1 || true
    else /etc/init.d/xray stop >/dev/null 2>&1 || true; fi
    install -m 755 "$tmp/unzipped/xray" "$XRAY_BIN"
    mkdir -p /usr/local/share/xray
    cp "$tmp/unzipped/"*.dat /usr/local/share/xray/ 2>/dev/null || true
    rm -rf "$tmp"
    XRAY_VER_CHECKED=0; XRAY_VER_STR=""
    write_xray_service

    local ok=0
    if regen_config; then
        start_xray
        sleep 1
        xray_kernel_version
        if xray_is_active && [ "$XRAY_VER_STR" = "$target_num" ]; then ok=1; fi
    fi

    if [ "$ok" = "1" ]; then
        log_success "内核升级成功: ${cur:-未知} → ${target_num}"
        if [ "$crossed" = "1" ]; then
            log_warn "注意: 本次升级跨过了 26.9.8 边界, 新内核要求客户端 ClientHello 带 X25519MLKEM768:"
            log_warn "  - 本脚本之后生成的 vless 链接会自动带 support-x25519mlkem768=true 提示, 用主菜单 [4/5] 重新查看节点即可拿到新链接;"
            log_warn "  - sing-box / Shadowrocket 等未更新到支持 MLKEM 的客户端将连不上, 属上游兼容问题, 不是节点故障。"
        fi
        return 0
    fi

    log_error "新内核启动验收失败, 正在回滚到旧内核 (${cur:-未知})..."
    if [ "$SVC_MGR" = "systemd" ]; then systemctl stop xray >/dev/null 2>&1 || true
    else /etc/init.d/xray stop >/dev/null 2>&1 || true; fi
    install -m 755 "$bakdir/xray" "$XRAY_BIN"
    cp "$bakdir/"*.dat /usr/local/share/xray/ 2>/dev/null || true
    XRAY_VER_CHECKED=0; XRAY_VER_STR=""
    write_xray_service
    if regen_config; then
        start_xray
        if xray_is_active; then
            xray_kernel_version
            log_warn "已回滚到旧内核并恢复运行 (当前版本: ${XRAY_VER_STR:-未知})。本次升级未生效, 原有节点与配置未受影响。"
        else
            log_error "回滚后服务仍未运行, 请查看日志 $XRAY_LOG_DIR/error.log, 旧内核备份在 $bakdir"
        fi
    else
        log_error "回滚时配置重新生成失败, 请手动检查 $XRAY_CONFIG, 旧内核备份在 $bakdir"
    fi
    return 1
}

# ==============================================================
# 菜单入口
# ==============================================================
main_menu() {
    need_root
    detect_os
    # 管道下载 (bash <(curl...)) 时把交互输入切回终端，否则菜单读不到按键。
    # 用 -r 而不用 -e 判断：无控制终端时 /dev/tty 存在但打不开，-e 会误判导致 exec 失败退出。
    if [ ! -t 0 ] && [ -r /dev/tty ]; then exec </dev/tty; fi

    mkdir -p "$DATA_DIR" "$BACKUP_DIR" "$XRAY_LOG_DIR" "$XRAY_ETC" "$HY2_ETC" "$HY2_CERT_DIR" "$HY2_LOG_DIR" 2>/dev/null || true
    touch "$NODE_DB" "$RELAY_DB" "$HY2_DB" "$VERSION_FILE" 2>/dev/null || true
    sanitize_db
    check_version
    # 启动时顺带校验开机自启 (已在位则静默，补齐或失败才各说一行)
    ensure_autostart_all

    while true; do
        echo ""
        echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║   VPS 一键管理  ${SCRIPT_VERSION}                     ║${NC}"
        echo -e "${BLUE}║   Xray VLESS+Reality 严谨加固防偷优化版      ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
        echo ""
        show_relay_mode
        if [ -s "$HY2_DB" ]; then
            local hy2_cnt
            hy2_cnt=$(grep -vc '^#\|^$' "$HY2_DB" 2>/dev/null || echo "0")
            echo -e "  HY2 节点: ${hy2_cnt} 个"
        fi
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
        echo -e "${CYAN}── Hysteria2 ───────────────────────────────────${NC}"
        echo "  11) Hysteria2 节点管理（增删改查/端口跳跃/带宽/伪装/混淆）"
        echo ""
        echo -e "${CYAN}── Xray 服务 ───────────────────────────────────${NC}"
        echo "   8) 重启 Xray 服务"
        echo "   9) 强制修复配置 (解决部分启动失败)"
        echo "  10) 一键全新初始化 (危险操作)"
        echo "  12) 修复开机自启 (VPS 重启后自动启动 Xray/HY2)"
        xray_kernel_version
        local kver_disp="${XRAY_VER_STR:-未安装}"
        echo "  13) 升级 Xray 内核 (当前版本: ${kver_disp}, 锁定版 ${XRAY_VERSION_PIN})"
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
            10) hy2_wipe_all; rm -rf "${DATA_DIR:?}" "${XRAY_ETC:?}"; log_success "已重置配置，请重新运行脚本"; exit 0 ;;
            11) hy2_menu ;;
            12) ensure_autostart_all && log_success "开机自启检查完成" ;;
            13) upgrade_xray ;;
            0)  exit 0 ;;
            *)  log_warn "无效选项" ;;
        esac
    done
}

main_menu
