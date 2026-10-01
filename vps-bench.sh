#!/bin/sh
# ==============================================================================
# vps-bench.sh —— VPS 基础软件安装 + 网络体检（单文件 POSIX sh）
#
# 用途：在每台 VPS 上单独执行。自动识别发行版，安装 iperf3 / nexttrace，
#       测试到 www.apple.com 与 hon0.com 的 ICMP 延迟（v4/v6），
#       用 nexttrace 测试到国内三网节点的回程路由（v4/v6），
#       并追踪回当前 SSH 客户端（你本地出口 IP）的路由。
#       最后在终端输出一份整体汇总报告（不落盘）。
#
# 用法：
#   ./vps-bench.sh                 # 正常运行
#   ./vps-bench.sh > report.txt    # 重定向时自动关闭颜色
#   SKIP_INSTALL=1 ./vps-bench.sh  # 跳过装包，仅用已有工具测试
#
# 兼容：Alpine / Debian / Ubuntu / CentOS / RHEL / Rocky / Alma / Fedora /
#       Arch / openSUSE 等
# ==============================================================================

set -u

# ------------------------------------------------------------------ 默认配置 --
# 全部可用环境变量覆盖
: "${LATENCY_TARGETS:=www.apple.com hon0.com}"
: "${PING_COUNT:=10}"
: "${PING_TIMEOUT:=2}"          # -W，单包等待（秒）
: "${PING_DEADLINE:=10}"        # -w，整体上限（秒）
: "${PING_INTERVAL:=}"          # 留空则按 ping 实现自动选择

# 国内三网回程节点（空格分隔，按顺序预检，第一个通的才做追踪）
: "${TRACE_V4_CT:=202.96.209.133 202.96.128.86}"
: "${TRACE_V4_CU:=210.22.97.1 221.5.88.88}"
: "${TRACE_V4_CM:=211.136.192.6 120.196.165.24}"
: "${TRACE_V6_CT:=240e:4c:4008::1 240e:4c:4808::1}"
: "${TRACE_V6_CU:=2408:8899::8 2408:8888::8}"
: "${TRACE_V6_CM:=2409:8088::a 2409:8088::b}"

: "${NT_MAXHOPS:=20}"
: "${NT_QUERIES:=3}"
: "${NT_TIMEOUT:=1000}"         # nexttrace --timeout，单位 ms

: "${V6_PROBE_TARGETS:=2606:4700:4700::1111 2400:3200::1}"
: "${BASELINE_V4:=1.1.1.1}"
: "${SKIP_INSTALL:=0}"

# ------------------------------------------------------------------ 全局状态 --
SUMMARY_ROWS=""
NOTES=""
FAIL_COUNT=0

OS_KIND=$(uname -s 2>/dev/null || echo unknown)
HOSTNAME_S=$(hostname 2>/dev/null || echo unknown)

DISTRO_ID=unknown
DISTRO_LIKE=""
DISTRO_NAME=unknown
VER_MAJOR=""

PRIV_MODE=none
SUDO=""

PING_BIN=""
PING_IMPL=unknown
PING4_ARGS=""
PING6_BIN=""
PING6_FAMILY_ARG=""
PING_INTERVAL_USE=1

V6_ENABLED=no
V6_SKIP_REASON=""

NT_AVAILABLE=no
IPERF3_AVAILABLE=no
SSH_CLIENT_IP=""

C_RST=""; C_BOLD=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_GRY=""

# ------------------------------------------------------------------ 输出工具 --
init_colors() {
  if [ -n "${NO_COLOR:-}" ]; then
    _color=0
  elif [ -n "${FORCE_COLOR:-}" ]; then
    _color=1
  elif [ -t 1 ]; then
    _color=1
  else
    _color=0
  fi
  if [ "$_color" = 1 ]; then
    C_RST=$(printf '\033[0m');  C_BOLD=$(printf '\033[1m')
    C_RED=$(printf '\033[31m'); C_GRN=$(printf '\033[32m')
    C_YEL=$(printf '\033[33m'); C_CYN=$(printf '\033[36m')
    C_GRY=$(printf '\033[90m')
  else
    C_RST=""; C_BOLD=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_GRY=""
  fi
}

info() { printf '%s[INFO]%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_RST" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*"; }
skip() { printf '%s[SKIP]%s %s\n' "$C_GRY" "$C_RST" "$*"; }
hdr()  { printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_RST"; }

# 记录汇总表一行（9 字段，用 | 分隔）
record_row() {
  SUMMARY_ROWS="${SUMMARY_ROWS}${1}|${2}|${3}|${4}|${5}|${6}|${7}|${8}|${9}
"
}

add_note() { NOTES="${NOTES}  - ${1}
"; }

mark_fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); }

# ------------------------------------------------------ 显示宽度与等宽对齐 --
# 计算字符串的终端显示宽度：ASCII 字节算 1 列，非 ASCII 字节按 3 字节=2 列估算
disp_width() {
  _dw_bytes=$(printf '%s' "$1" | wc -c | tr -d ' \t')
  _dw_ascii=$(printf '%s' "$1" | LC_ALL=C tr -d '\200-\377' | wc -c | tr -d ' \t')
  _dw_non=$(( _dw_bytes - _dw_ascii ))
  printf '%s' $(( _dw_ascii + 2 * (_dw_non / 3) ))
}

# 右侧补空格到指定显示宽度
pad() {
  printf '%s' "$1"
  _pad_n=$(( $2 - $(disp_width "$1") ))
  while [ "$_pad_n" -gt 0 ]; do printf ' '; _pad_n=$(( _pad_n - 1 )); done
}

# 超宽则截断（仅用于 ASCII 列）
fit() {
  if [ "$(disp_width "$1")" -gt "$2" ]; then
    printf '%s~' "$(printf '%s' "$1" | cut -c "1-$(( $2 - 1 ))")"
  else
    printf '%s' "$1"
  fi
}

color_status() {
  case "$1" in
    OK)   printf '%s%s%s' "$C_GRN" "$1" "$C_RST" ;;
    FAIL) printf '%s%s%s' "$C_RED" "$1" "$C_RST" ;;
    SKIP) printf '%s%s%s' "$C_YEL" "$1" "$C_RST" ;;
    *)    printf '%s' "$1" ;;
  esac
}

render_row() {
  printf '%s %s %s %s %s %s %s %s %s\n' \
    "$(pad "$1" 6)" \
    "$(pad "$(fit "$2" 22)" 22)" \
    "$(pad "$3" 4)" \
    "$(pad "$4" 9)" \
    "$(pad "$5" 9)" \
    "$(pad "$6" 6)" \
    "$(pad "$7" 5)" \
    "$(pad "$(fit "$8" 22)" 22)" \
    "$(color_status "$9")"
}

# ------------------------------------------------------------ 中断与退出码 --
on_interrupt() {
  printf '\n'
  warn "已被中断（Ctrl-C）。以下为已完成部分的汇总："
  print_summary
  exit 130
}

finish() {
  if [ "$FAIL_COUNT" -gt 0 ]; then
    printf '\n%s完成：存在 %s 项失败，请查看上方 [FAIL] 与汇总表。%s\n' \
      "$C_RED" "$FAIL_COUNT" "$C_RST"
    exit 2
  fi
  printf '\n%s完成：全部测试项执行结束（SKIP 表示前置条件不满足，非失败）。%s\n' \
    "$C_GRN" "$C_RST"
  exit 0
}

# -------------------------------------------------------------- 环境探测 --
detect_distro() {
  if [ -r /etc/os-release ]; then
    DISTRO_ID=$(sed -n 's/^ID=//p' /etc/os-release | head -n1 | tr -d '"')
    DISTRO_LIKE=$(sed -n 's/^ID_LIKE=//p' /etc/os-release | head -n1 | tr -d '"')
    DISTRO_NAME=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | head -n1 | tr -d '"')
    _v=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | head -n1 | tr -d '"')
    VER_MAJOR=$(printf '%s' "$_v" | sed -n 's/^\([0-9][0-9]*\).*/\1/p')
  fi
  [ -z "$DISTRO_ID" ] && DISTRO_ID=unknown
  if [ "$DISTRO_ID" = unknown ]; then
    if [ -r /etc/alpine-release ]; then
      DISTRO_ID=alpine; DISTRO_NAME="Alpine Linux $(cat /etc/alpine-release)"
    elif [ -r /etc/debian_version ]; then
      DISTRO_ID=debian; DISTRO_NAME="Debian $(cat /etc/debian_version)"
    elif [ -r /etc/redhat-release ]; then
      DISTRO_ID=rhel; DISTRO_NAME="$(cat /etc/redhat-release)"
    fi
  fi
  # PRETTY_NAME 缺失时逐级回退，避免报告里系统名称为空
  [ -z "$DISTRO_NAME" ] && DISTRO_NAME="$DISTRO_ID"
  [ -z "$DISTRO_NAME" ] && DISTRO_NAME=unknown
}

distro_family() {
  case "$DISTRO_ID" in
    debian|ubuntu|raspbian|linuxmint|pop|kali|deepin|devuan|elementary|zorin|neon|mx)
      echo deb ;;
    alpine|postmarketos) echo alpine ;;
    centos|rhel|rocky|almalinux|ol|oracle|scientific|cloudlinux|virtuozzo|amzn)
      echo rhel ;;
    fedora) echo fedora ;;
    arch|manjaro|endeavouros|garuda|artix) echo arch ;;
    opensuse*|sles|suse|sled) echo suse ;;
    *)
      case "$DISTRO_LIKE" in
        *debian*|*ubuntu*) echo deb ;;
        *rhel*|*fedora*|*centos*) echo rhel ;;
        *suse*) echo suse ;;
        *alpine*) echo alpine ;;
        *arch*) echo arch ;;
        *) echo unknown ;;
      esac ;;
  esac
}

map_arch() {
  case "$(uname -m 2>/dev/null)" in
    x86_64|amd64)            echo amd64 ;;
    aarch64|arm64)           echo arm64 ;;
    i386|i486|i586|i686)     echo 386 ;;
    armv7l|armv7ml|armv8l)   echo armv7 ;;
    armv6l)                  echo armv6 ;;
    armv5tel)                echo armv5 ;;
    mips)                    echo mips ;;
    mipsel|mipsle)           echo mipsle ;;
    mips64)                  echo mips64 ;;
    mips64el|mips64le)       echo mips64le ;;
    loongarch64|loong64)     echo loong64 ;;
    riscv64)                 echo riscv64 ;;
    ppc64)                   echo ppc64 ;;
    ppc64le)                 echo ppc64le ;;
    s390x)                   echo s390x ;;
    *)                       echo "" ;;
  esac
}

check_privilege() {
  if [ "$(id -u 2>/dev/null)" = 0 ]; then
    PRIV_MODE=root; SUDO=""
  elif command -v sudo >/dev/null 2>&1; then
    PRIV_MODE=sudo; SUDO="sudo"
  else
    PRIV_MODE=none; SUDO=""
  fi
}

# -------------------------------------------------------------- 软件安装 --
dl_fetch_to() {   # $1=url $2=dest
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 180 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=30 -O "$2" "$1"
  else
    return 1
  fi
}

pkg_install_base() {
  _fam=$(distro_family)
  case "$_fam" in
    deb)
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        ca-certificates curl iputils-ping iperf3 >/dev/null 2>&1
      ;;
    alpine)
      # Alpine 基础系统无 curl 也无 ca-certificates，必须一起装
      $SUDO apk add --no-cache ca-certificates curl iputils-ping iperf3 >/dev/null 2>&1
      ;;
    rhel)
      if [ "${VER_MAJOR:-}" = 7 ]; then
        $SUDO yum install -y epel-release >/dev/null 2>&1
        $SUDO yum install -y iputils iperf3 curl ca-certificates >/dev/null 2>&1
      else
        $SUDO dnf install -y iputils iperf3 curl ca-certificates >/dev/null 2>&1 \
          || $SUDO yum install -y iputils iperf3 curl ca-certificates >/dev/null 2>&1
      fi
      ;;
    fedora)
      $SUDO dnf install -y iputils iperf3 curl ca-certificates >/dev/null 2>&1
      ;;
    arch)
      $SUDO pacman -Sy --noconfirm iputils iperf3 curl ca-certificates >/dev/null 2>&1
      ;;
    suse)
      # openSUSE 包名是 iperf，但提供 /usr/bin/iperf3
      $SUDO zypper -n install iputils iperf curl ca-certificates >/dev/null 2>&1
      ;;
    *)
      return 1 ;;
  esac
}

# 下载 nexttrace 裸二进制并校验：$1=url $2=目标目录
nt_try_download() {
  _nt_tmp="$2/nexttrace.tmp.$$"
  if dl_fetch_to "$1" "$_nt_tmp" 2>/dev/null && [ -s "$_nt_tmp" ]; then
    chmod 0755 "$_nt_tmp" 2>/dev/null
    if "$_nt_tmp" --version >/dev/null 2>&1; then
      mv -f "$_nt_tmp" "$2/nexttrace" 2>/dev/null || $SUDO mv -f "$_nt_tmp" "$2/nexttrace"
      return 0
    fi
  fi
  rm -f "$_nt_tmp" 2>/dev/null
  return 1
}

install_nexttrace() {
  command -v nexttrace >/dev/null 2>&1 && return 0

  _arch=$(map_arch)
  _dest_dir=/usr/local/bin
  [ "$PRIV_MODE" = none ] && _dest_dir="$HOME/.local/bin"

  # --- 1) 官方一键脚本（已核实 shebang 为 #!/bin/sh，Alpine 可跑） ---
  info "尝试通过官方一键脚本安装 nexttrace ..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 120 https://nxtrace.org/nt 2>/dev/null | $SUDO sh >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --timeout=60 https://nxtrace.org/nt 2>/dev/null | $SUDO sh >/dev/null 2>&1
  fi
  command -v nexttrace >/dev/null 2>&1 && return 0

  # --- 2) 直接下载预编译二进制 ---
  [ -z "$_arch" ] && return 1
  _asset="nexttrace_linux_${_arch}"
  $SUDO mkdir -p "$_dest_dir" 2>/dev/null || mkdir -p "$_dest_dir" 2>/dev/null

  info "一键脚本未成功，回退到直接下载二进制：$_asset"
  if nt_try_download "https://github.com/nxtrace/NTrace-core/releases/latest/download/${_asset}" "$_dest_dir"; then
    :
  else
    # 镜像 API 返回候选 URL 列表（| 分隔）
    _cands=$(curl -fsSL --connect-timeout 10 --max-time 25 \
      "https://www.nxtrace.org/api/dist/core/${_asset}" 2>/dev/null | tr '|' '\n')
    for _u in $_cands; do
      nt_try_download "$_u" "$_dest_dir" && break
    done
  fi

  # --- 3) 非 root 场景：装到 ~/.local/bin ---
  if [ "$PRIV_MODE" = none ] && [ -x "$_dest_dir/nexttrace" ]; then
    PATH="$HOME/.local/bin:$PATH"
    export PATH
    add_note "nexttrace 已安装到 ~/.local/bin，请执行 export PATH=\"\$HOME/.local/bin:\$PATH\" 后使用"
  fi

  command -v nexttrace >/dev/null 2>&1
}

do_install() {
  hdr "依赖安装"
  if [ "$PRIV_MODE" = none ]; then
    warn "当前用户非 root 且无 sudo，跳过软件安装（仅使用系统已有工具）"
    add_note "无 root/sudo 权限：已跳过 iperf3 / nexttrace 安装，相关测试项会缺失"
    return
  fi
  if [ "$SKIP_INSTALL" = "1" ]; then
    warn "SKIP_INSTALL=1，跳过软件安装"
    return
  fi
  info "发行版家族：$(distro_family)，开始安装 ca-certificates / curl / ping / iperf3"
  if pkg_install_base; then
    ok "基础软件安装命令执行完成"
  else
    warn "基础软件安装返回非 0（该发行版可能不在支持列表内），继续校验实际可用性"
  fi

  if install_nexttrace; then
    ok "nexttrace 安装完成"
  else
    warn "nexttrace 安装失败（回程路由测试将被跳过）"
    add_note "nexttrace 安装失败：可手动安装，见 https://www.nxtrace.org/downloads"
  fi
}

verify_tools() {
  hdr "软件校验"
  if command -v iperf3 >/dev/null 2>&1; then
    IPERF3_AVAILABLE=yes
    ok "iperf3 可用：$(iperf3 --version 2>&1 | head -n1)"
  else
    warn "iperf3 不可用"
    add_note "iperf3 未安装成功（不影响延迟与路由测试）"
  fi

  if command -v nexttrace >/dev/null 2>&1; then
    NT_AVAILABLE=yes
    ok "nexttrace 可用：$(nexttrace --version 2>&1 | head -n1)"
  else
    warn "nexttrace 不可用"
  fi

  if command -v ping >/dev/null 2>&1; then
    ok "ping：$(command -v ping)"
  else
    warn "ping 不可用"
  fi
}

# --------------------------------------------------------- ping 命令准备 --
is_invalid_option() {
  case "$1" in
    *[Ii]nvalid*option*|*[Uu]nknown*option*|*[Uu]nrecognized*option*|\
    *[Ii]llegal*option*|*[Bb]ad*option*|*usage:*) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_ping() {
  if command -v ping >/dev/null 2>&1; then
    PING_BIN=$(command -v ping)
  elif [ -x /bin/ping ]; then
    PING_BIN=/bin/ping
  elif [ -x /usr/bin/ping ]; then
    PING_BIN=/usr/bin/ping
  else
    PING_BIN=""
    return 1
  fi

  # 判定实现：iputils 支持 -V 且输出含 "iputils"
  _pv=$("$PING_BIN" -V 2>&1 | head -n1)
  case "$_pv" in
    *iputils*) PING_IMPL=iputils ;;
    *)         PING_IMPL=busybox ;;
  esac

  # -4 是否被支持
  _o=$("$PING_BIN" -4 -c 1 -W 1 127.0.0.1 2>&1)
  if is_invalid_option "$_o"; then PING4_ARGS=""; else PING4_ARGS="-4"; fi

  # 间隔：busybox 只支持整数秒；iputils 支持 0.2
  if [ -n "$PING_INTERVAL" ]; then
    PING_INTERVAL_USE="$PING_INTERVAL"
  elif [ "$PING_IMPL" = iputils ]; then
    PING_INTERVAL_USE=0.2
  else
    PING_INTERVAL_USE=1
  fi
  [ "$OS_KIND" = Darwin ] && PING_INTERVAL_USE=1
  return 0
}

detect_ping6() {
  PING6_BIN=""; PING6_FAMILY_ARG=""
  [ -z "$PING_BIN" ] && return 1
  _o=$("$PING_BIN" -6 -c 1 -W 1 ::1 2>&1)
  if is_invalid_option "$_o"; then
    if command -v ping6 >/dev/null 2>&1; then
      PING6_BIN=$(command -v ping6); PING6_FAMILY_ARG=""
    else
      return 1
    fi
  else
    PING6_BIN="$PING_BIN"; PING6_FAMILY_ARG="-6"
  fi
  return 0
}

ping_exec() {   # $1=family(4|6) $2=target $3=count  → 原始输出到 stdout
  if [ "$1" = 6 ]; then
    _bin=$PING6_BIN; _farg=$PING6_FAMILY_ARG
  else
    _bin=$PING_BIN;  _farg=$PING4_ARGS
  fi
  [ -z "$_bin" ] && return 1

  if [ "$OS_KIND" = Darwin ]; then
    # macOS：-W 单位是毫秒，且没有 -w
    _w=$(( PING_TIMEOUT * 1000 ))
    "$_bin" $_farg -n -c "$3" -i "$PING_INTERVAL_USE" -W "$_w" "$2" 2>&1
  else
    "$_bin" $_farg -n -c "$3" -i "$PING_INTERVAL_USE" -W "$PING_TIMEOUT" -w "$PING_DEADLINE" "$2" 2>&1
  fi
}

# 轻量预检：是否有回包（0=有回包）。
# 用"输出里是否出现 time=" 判定，比依赖 ping 退出码可靠（部分实现丢包时退出码不确定）
ping_has_reply() {   # $1=family $2=target $3=count（默认 2）
  _phr=$(ping_exec "$1" "$2" "${3:-2}" 2>/dev/null)
  printf '%s' "$_phr" | grep -q 'time[=<]'
}

# 从 ping 原始输出提取 RTT 样本（兼容 busybox 的 time= 与 iputils 的 time</=）
extract_rtts() {
  sed -n 's/.*[[:space:]]time[=<][[:space:]]*\([0-9][0-9.]*\)[[:space:]]*ms.*/\1/p'
}

# 从 ping 原始输出（stdin）提取 tx|rx
# 兼容 iputils 的 "3 received" 与 busybox 的 "3 packets received"
# 注意：stdin 只能读一次，必须先整体读入变量再分别匹配
extract_txrx() {
  _in=$(cat)
  _etx=$(printf '%s\n' "$_in" | sed -n 's/.*\([0-9][0-9]*\) packets transmitted.*/\1/p' | tail -n1)
  _erx=$(printf '%s\n' "$_in" | sed -n 's/.*\([0-9][0-9]*\) \(packets \)\{0,1\}received.*/\1/p' | tail -n1)
  printf '%s|%s\n' "$_etx" "$_erx"
}

# 自算统计：min|avg|max|mdev|n
calc_stats() {
  _cs=$(awk '
    { n++; s+=$1; if(n==1||$1<mn)mn=$1; if(n==1||$1>mx)mx=$1; v[n]=$1 }
    END{
      if(n==0){ print "NA|NA|NA|NA|0"; exit }
      avg=s/n; for(i=1;i<=n;i++){d=v[i]-avg; ss+=d*d}
      printf "%.3f|%.3f|%.3f|%.3f|%d\n", mn, avg, mx, sqrt(ss/n), n
    }' 2>/dev/null)
  if [ -z "$_cs" ]; then
    # awk 无 sqrt（部分 busybox 精简编译）：退化为不算 mdev
    _cs=$(awk '
      { n++; s+=$1; if(n==1||$1<mn)mn=$1; if(n==1||$1>mx)mx=$1 }
      END{
        if(n==0){ print "NA|NA|NA|NA|0"; exit }
        printf "%.3f|%.3f|%.3f|NA|%d\n", mn, s/n, mx, n
      }' 2>/dev/null)
  fi
  printf '%s\n' "$_cs"
}

# ---------------------------------------------------------------- IPv6 判定 --
check_ipv6() {
  V6_ENABLED=no
  V6_SKIP_REASON=""

  if [ -z "$PING6_BIN" ]; then
    V6_SKIP_REASON="无可用 IPv6 ping 命令"
    return
  fi

  # L1 地址层：排除 link-local(fe80) 与 loopback(::1)
  _l1=no
  if command -v ip >/dev/null 2>&1; then
    _addr6=$(ip -6 addr show 2>/dev/null | grep 'inet6 ' | grep -v ' fe80' | grep -v '::1/')
    [ -n "$_addr6" ] && _l1=yes
  else
    _l1=unknown
  fi

  # L2 路由层
  _l2=no
  if command -v ip >/dev/null 2>&1; then
    if [ -n "$(ip -6 route show default 2>/dev/null)" ]; then _l2=yes; fi
  else
    _l2=unknown
  fi

  # L3 连通层（决定性）
  _l3=no
  for _t in $V6_PROBE_TARGETS; do
    if ping_has_reply 6 "$_t" 2; then _l3=yes; break; fi
  done

  if [ "$_l3" = yes ]; then
    V6_ENABLED=yes
    return
  fi

  if [ "$_l1" = no ]; then
    V6_SKIP_REASON="L1 未发现全局 IPv6 地址"
  elif [ "$_l2" = no ]; then
    V6_SKIP_REASON="L2 无 IPv6 默认路由"
  elif [ "$_l1" = yes ] && [ "$_l2" = yes ]; then
    V6_SKIP_REASON="L3 IPv6 连通性探测不通（有地址与默认路由，但无 IPv6 出口）"
  else
    V6_SKIP_REASON="L3 IPv6 连通性探测不通（未装 ip 命令，无法确认地址/路由层）"
  fi
}

# ------------------------------------------------------------ 延迟测试 --
do_latency_test() {   # $1=target $2=family
  _tgt=$1; _fam=$2
  _proto="v$_fam"

  if [ "$_fam" = 6 ] && [ "$V6_ENABLED" != yes ]; then
    skip "$_tgt ${_proto}：跳过（${V6_SKIP_REASON}）"
    record_row "延迟" "$_tgt" "$_proto" "-" "-" "-" "-" "-" "SKIP"
    add_note "$_tgt ${_proto}：$V6_SKIP_REASON"
    return
  fi

  info "延迟测试 $_tgt ($_proto) ..."
  _out=$(ping_exec "$_fam" "$_tgt" "$PING_COUNT")
  if [ -z "$_out" ]; then
    err "$_tgt ${_proto}：ping 无输出"
    record_row "延迟" "$_tgt" "$_proto" "-" "-" "-" "-" "-" "FAIL"
    mark_fail
    return
  fi

  # DNS 解析失败
  case "$_out" in
    *[Uu]nknown*host*|*[Nn]ame*or*service*not*known*|*[Bb]ad*address*|*cannot*resolve*|*[Tt]emporary*failure*in*name*resolution*)
      err "$_tgt ${_proto}：DNS 解析失败"
      record_row "延迟" "$_tgt" "$_proto" "-" "-" "-" "-" "-" "FAIL"
      add_note "$_tgt ${_proto}：DNS 解析失败"
      mark_fail
      return ;;
  esac

  _resolved=$(printf '%s\n' "$_out" | sed -n '1s/.*(\([0-9a-fA-F:.]*\)).*/\1/p')
  _rtts=$(printf '%s\n' "$_out" | extract_rtts)
  # grep -c 无匹配时退出码为 1 但会正常输出 0，故不能再接 || echo 0（会拼出 "0\n0"）
  _n=$(printf '%s\n' "$_rtts" | grep -c '[0-9]')

  _txrx=$(printf '%s\n' "$_out" | extract_txrx)
  _tx=$(printf '%s' "$_txrx" | cut -d'|' -f1)
  _rx=$(printf '%s' "$_txrx" | cut -d'|' -f2)
  [ -z "$_tx" ] && _tx=$PING_COUNT
  [ -z "$_rx" ] && _rx=$_n
  if [ "$_tx" -gt 0 ] 2>/dev/null; then
    _loss=$(( (_tx - _rx) * 100 / _tx ))
  else
    _loss=100
  fi

  _stats=$(printf '%s\n' "$_rtts" | calc_stats)
  _min=$(printf '%s' "$_stats" | cut -d'|' -f1)
  _avg=$(printf '%s' "$_stats" | cut -d'|' -f2)
  _max=$(printf '%s' "$_stats" | cut -d'|' -f3)
  _mdev=$(printf '%s' "$_stats" | cut -d'|' -f4)

  if [ "$_rx" -gt 0 ] 2>/dev/null; then
    ok "$_tgt ${_proto}：avg ${_avg}ms  抖动 ${_mdev}ms  丢包 ${_loss}%  (${_rx}/${_tx}${_resolved:+ @$_resolved})"
    record_row "延迟" "$_tgt" "$_proto" "${_avg}ms" "${_mdev}ms" "${_loss}%" "-" "-" "OK"
    if [ "$_loss" -gt 0 ] 2>/dev/null; then
      add_note "$_tgt ${_proto}：存在 ${_loss}% 丢包"
    fi
  else
    err "$_tgt ${_proto}：${_loss}% 丢包，无有效 RTT"
    record_row "延迟" "$_tgt" "$_proto" "-" "-" "${_loss}%" "-" "-" "FAIL"
    add_note "$_tgt ${_proto}：全部丢包（目标不可达或 ICMP 被屏蔽）"
    mark_fail
  fi
}

run_latency_tests() {
  hdr "延迟测试（ICMP ping，目标：${LATENCY_TARGETS}）"
  for _t in $LATENCY_TARGETS; do
    do_latency_test "$_t" 4
    do_latency_test "$_t" 6
  done
}

# ------------------------------------------------------------ 回程路由 --
nt_run() {   # $1=family(4|6) $2=target
  if [ "$1" = 6 ]; then _fa="-6"; else _fa="-4"; fi
  _o=$(NO_COLOR=1 nexttrace $_fa -m "$NT_MAXHOPS" -q "$NT_QUERIES" --timeout "$NT_TIMEOUT" "$2" 2>&1)
  case "$_o" in
    *[Uu]nknown*flag*|*[Uu]nknown*shorthand*|*[Ii]ncorrect*usage*|*invalid*argument*)
      # 参数不被该版本支持 → 用最小参数集重试
      _o=$(NO_COLOR=1 nexttrace $_fa "$2" 2>&1) ;;
  esac
  printf '%s\n' "$_o"
}

# 从 nexttrace 输出（stdin）提取 "跳数|末跳IP|AS号"
# 注意：全部使用 POSIX BRE，不用 \+ （GNU 扩展，busybox/toybox sed 不支持）
summarize_route() {
  _in=$(cat)
  # 跳数 = 到达的最大跳号
  _hops=$(printf '%s\n' "$_in" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\)[[:space:]].*/\1/p' | tail -n1)
  # 末跳 = 最后一个「有 IP 响应」的跳（比取最后一跳更有信息量）
  _last=$(printf '%s\n' "$_in" | sed -n '/^[[:space:]]*[0-9][0-9]*[[:space:]][[:space:]]*[0-9a-fA-F:.]/p' | tail -n1)
  _ip=$(printf '%s' "$_last" | sed -n 's/^[[:space:]]*[0-9][0-9]*[[:space:]]*\([0-9a-fA-F:.]*\)[[:space:]].*/\1/p')
  _as=$(printf '%s' "$_last" | sed -n 's/.*\(AS[0-9][0-9]*\).*/\1/p')
  [ -z "$_hops" ] && _hops="-"
  [ -z "$_ip" ] && _ip=""
  printf '%s|%s|%s\n' "$_hops" "$_ip" "$_as"
}

# 预检：目标是否可达
precheck_target() {   # $1=target $2=family
  ping_has_reply "$2" "$1" 2
}

pick_reachable() {   # $1=候选列表 $2=family → 输出第一个可达目标
  for _c in $1; do
    if precheck_target "$_c" "$2"; then printf '%s' "$_c"; return 0; fi
  done
  return 1
}

do_route_test() {   # $1=运营商标签 $2=候选列表 $3=family
  _label=$1; _cands=$2; _fam=$3
  _proto="v$_fam"
  # 表格里显示"标签 + 首选节点"，便于对照
  _first=$(printf '%s' "$_cands" | awk '{print $1}')
  _row_target="$_label $_first"

  if [ "$NT_AVAILABLE" != yes ]; then
    record_row "回程" "$_row_target" "$_proto" "-" "-" "-" "-" "-" "SKIP"
    return
  fi
  if [ "$_fam" = 6 ] && [ "$V6_ENABLED" != yes ]; then
    skip "回程 $_label ${_proto}：跳过（${V6_SKIP_REASON}）"
    record_row "回程" "$_row_target" "$_proto" "-" "-" "-" "-" "-" "SKIP"
    add_note "回程 $_label ${_proto}：$V6_SKIP_REASON"
    return
  fi

  _tgt=$(pick_reachable "$_cands" "$_fam")
  if [ -z "$_tgt" ]; then
    skip "回程 $_label ${_proto}：全部候选节点不可达，已跳过"
    record_row "回程" "$_row_target" "$_proto" "-" "-" "-" "-" "-" "SKIP"
    add_note "回程 $_label ${_proto}：候选节点全部预检不通（${_cands}）"
    return
  fi

  info "回程路由 $_label → $_tgt ($_proto) ..."
  _out=$(nt_run "$_fam" "$_tgt")
  if [ -z "$_out" ]; then
    err "回程 $_label ${_proto}：nexttrace 无输出"
    record_row "回程" "$_label $_tgt" "$_proto" "-" "-" "-" "-" "-" "FAIL"
    mark_fail
    return
  fi

  printf '%s\n' "$_out" | sed 's/^/    /'

  _sum=$(printf '%s\n' "$_out" | summarize_route)
  _hops=$(printf '%s' "$_sum" | cut -d'|' -f1)
  _ip=$(printf '%s' "$_sum" | cut -d'|' -f2)
  _as=$(printf '%s' "$_sum" | cut -d'|' -f3)

  # nexttrace 失败时会输出错误文本（非空），必须靠"是否解析到跳"来判定成败
  if [ "$_hops" = "-" ]; then
    err "回程 $_label ${_proto}：nexttrace 未返回有效跳（可能缺少 CAP_NET_RAW 权限或网络受限）"
    record_row "回程" "$_label $_tgt" "$_proto" "-" "-" "-" "-" "-" "FAIL"
    add_note "回程 $_label ${_proto}：nexttrace 无有效跳输出（检查是否以 root 运行）"
    mark_fail
    return
  fi

  _tail="$_ip"
  [ -n "$_as" ] && _tail="$_ip $_as"
  [ -z "$_tail" ] && _tail="-"

  ok "回程 $_label ($_tgt) ${_proto}：跳数 ${_hops}，末跳 $_tail"
  record_row "回程" "$_label $_tgt" "$_proto" "-" "-" "-" "$_hops" "$_tail" "OK"
}

run_route_tests() {
  hdr "回程路由测试（nexttrace，国内三网）"
  if [ "$NT_AVAILABLE" != yes ]; then
    warn "nexttrace 不可用，回程路由测试整体跳过"
    add_note "回程路由测试整体跳过：nexttrace 不可用"
    record_row "回程" "CT/CU/CM" "v4" "-" "-" "-" "-" "-" "SKIP"
    record_row "回程" "CT/CU/CM" "v6" "-" "-" "-" "-" "-" "SKIP"
    return
  fi
  do_route_test "CT" "$TRACE_V4_CT" 4
  do_route_test "CU" "$TRACE_V4_CU" 4
  do_route_test "CM" "$TRACE_V4_CM" 4
  do_route_test "CT" "$TRACE_V6_CT" 6
  do_route_test "CU" "$TRACE_V6_CU" 6
  do_route_test "CM" "$TRACE_V6_CM" 6
}

# ------------------------------------------------------- SSH 客户端附加项 --
get_ssh_client_ip() {
  SSH_CLIENT_IP=""
  if [ -n "${SSH_CONNECTION:-}" ]; then
    SSH_CLIENT_IP=$(printf '%s' "$SSH_CONNECTION" | awk '{print $1}')
  elif [ -n "${SSH_CLIENT:-}" ]; then
    SSH_CLIENT_IP=$(printf '%s' "$SSH_CLIENT" | awk '{print $1}')
  fi
  [ -n "$SSH_CLIENT_IP" ]
}

run_ssh_test() {
  hdr "附加：回本地 SSH 客户端路由"
  if get_ssh_client_ip; then
    ok "检测到 SSH 客户端 IP：$SSH_CLIENT_IP"
    add_note "SSH 客户端 IP ${SSH_CLIENT_IP}（若经跳板机/堡垒机，此 IP 为跳板机地址）"
  else
    if [ -n "${SUDO_USER:-}" ]; then
      warn "未获取到 SSH 客户端 IP：疑似使用了 sudo（会清空 SSH_CONNECTION 环境变量）"
      add_note "未获取 SSH 客户端 IP：请改用 sudo -E ./vps-bench.sh 或直接用 root 执行"
    else
      warn "未获取到 SSH 客户端 IP：非 SSH 交互会话（如 cron / nohup / 本地终端）"
      add_note "未获取 SSH 客户端 IP：非 SSH 交互会话，跳过该项"
    fi
    record_row "附加" "SSH 客户端" "-" "-" "-" "-" "-" "-" "SKIP"
    return
  fi

  # 判断客户端 IP 属于哪个协议族
  case "$SSH_CLIENT_IP" in
    *:*) _fam=6 ;;
    *)   _fam=4 ;;
  esac
  _proto="v$_fam"

  if [ "$_fam" = 6 ] && [ "$V6_ENABLED" != yes ]; then
    record_row "附加" "SSH $SSH_CLIENT_IP" "$_proto" "-" "-" "-" "-" "-" "SKIP"
    return
  fi
  if [ "$NT_AVAILABLE" != yes ]; then
    record_row "附加" "SSH $SSH_CLIENT_IP" "$_proto" "-" "-" "-" "-" "-" "SKIP"
    return
  fi

  info "追踪回 SSH 客户端 $SSH_CLIENT_IP ($_proto) ..."
  _out=$(nt_run "$_fam" "$SSH_CLIENT_IP")
  if [ -z "$_out" ]; then
    record_row "附加" "SSH $SSH_CLIENT_IP" "$_proto" "-" "-" "-" "-" "-" "FAIL"
    mark_fail
    return
  fi
  printf '%s\n' "$_out" | sed 's/^/    /'
  _sum=$(printf '%s\n' "$_out" | summarize_route)
  _hops=$(printf '%s' "$_sum" | cut -d'|' -f1)
  _ip=$(printf '%s' "$_sum" | cut -d'|' -f2)
  _as=$(printf '%s' "$_sum" | cut -d'|' -f3)
  if [ "$_hops" = "-" ]; then
    err "回 SSH 客户端：nexttrace 未返回有效跳"
    record_row "附加" "SSH $SSH_CLIENT_IP" "$_proto" "-" "-" "-" "-" "-" "FAIL"
    mark_fail
    return
  fi
  _tail="$_ip"; [ -n "$_as" ] && _tail="$_ip $_as"; [ -z "$_tail" ] && _tail="-"
  ok "回 SSH 客户端：跳数 ${_hops}，末跳 $_tail"
  record_row "附加" "SSH $SSH_CLIENT_IP" "$_proto" "-" "-" "-" "$_hops" "$_tail" "OK"
}

# ------------------------------------------------------------ 基线连通性 --
baseline_check() {
  hdr "基线连通性检查"
  if ping_has_reply 4 "$BASELINE_V4" 2; then
    ok "ICMP 出站正常（$BASELINE_V4 可达）"
  else
    warn "ICMP 出站可能被限制（$BASELINE_V4 不可达）"
    add_note "基线 $BASELINE_V4 不可达：本机可能禁止 ICMP 出站，延迟测试的失败未必是目标问题"
  fi
}

# ---------------------------------------------------------------- 汇总表 --
print_summary() {
  printf '\n%s============================== 测试汇总 ==============================%s\n' "$C_BOLD" "$C_RST"
  render_row "类别" "目标" "协议" "平均" "抖动" "丢包" "跳数" "末跳/归属" "状态"
  printf '%s\n' "------ ---------------------- ---- --------- --------- ------ ----- ---------------------- ------"

  printf '%s\n' "$SUMMARY_ROWS" | while IFS='|' read -r _c1 _c2 _c3 _c4 _c5 _c6 _c7 _c8 _c9; do
    [ -z "${_c1:-}" ] && continue
    render_row "$_c1" "$_c2" "$_c3" "$_c4" "$_c5" "$_c6" "$_c7" "$_c8" "$_c9"
  done

  if [ -n "$NOTES" ]; then
    printf '\n%s说明：%s\n' "$C_BOLD" "$C_RST"
    printf '%s' "$NOTES"
  fi
  printf '\n%s主机：%s   系统：%s   时间：%s%s\n' \
    "$C_GRY" "$HOSTNAME_S" "$DISTRO_NAME" "$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)" "$C_RST"
}

# ------------------------------------------------------------------- 主体 --
print_banner() {
  printf '%s' "$C_BOLD"
  printf '==========================================================\n'
  printf '  VPS 初始化 + 网络体检\n'
  printf '  主机: %s\n' "$HOSTNAME_S"
  printf '==========================================================\n'
  printf '%s' "$C_RST"
}

main() {
  init_colors
  trap on_interrupt INT TERM

  print_banner

  hdr "环境探测"
  detect_distro
  check_privilege
  info "系统：${DISTRO_NAME}（ID=${DISTRO_ID}，家族=$(distro_family)，版本主号=${VER_MAJOR:-未知}）"
  info "架构：$(uname -m) → nexttrace 资产名后缀 $(map_arch)"
  info "权限：$PRIV_MODE${SUDO:+（将使用 sudo）}"

  do_install
  verify_tools

  hdr "ping 准备"
  if resolve_ping; then
    ok "ping：${PING_BIN}（实现：${PING_IMPL}，间隔：${PING_INTERVAL_USE}s）"
  else
    err "未找到可用的 ping 命令，延迟测试无法进行"
    add_note "未找到 ping 命令，延迟测试全部跳过"
  fi
  if detect_ping6; then
    ok "IPv6 ping：$PING6_BIN ${PING6_FAMILY_ARG:-(独立 ping6)}"
  else
    warn "未找到可用的 IPv6 ping 命令"
  fi

  hdr "IPv6 可用性判定"
  check_ipv6
  if [ "$V6_ENABLED" = yes ]; then
    ok "IPv6 可用，将执行 IPv6 测试"
  else
    warn "IPv6 不可用：$V6_SKIP_REASON"
  fi

  baseline_check
  run_latency_tests
  run_route_tests
  run_ssh_test

  print_summary
  finish
}

# 允许测试脚本以 VPS_BENCH_SOURCED=1 的方式 source 本文件而只加载函数
case "${VPS_BENCH_SOURCED:-0}" in
  1) ;;
  *) main "$@" ;;
esac
