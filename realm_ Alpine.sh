#!/usr/bin/env bash
set -euo pipefail

# ==============
# Realm Manager
# ==============
# v1.1 (2026-09-26)：支持 systemd 与 OpenRC 双 init 系统
#   - Debian/Ubuntu/CentOS（systemd）：沿用原有逻辑，行为不变
#   - Alpine（OpenRC）：写入 /etc/init.d/realm 服务，并自动下载 realm 官方 musl 构建
APP="realm"
BIN="/usr/local/bin/realm"
ETC_DIR="/etc/realm"
CFG="$ETC_DIR/config.toml"
EP_DB="$ETC_DIR/endpoints.db"
SERVICE="/etc/systemd/system/realm.service"
OPENRC_INIT="/etc/init.d/realm"
OPENRC_LOG="/var/log/realm.log"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

say()  { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
err()  { echo -e "${RED}$*${NC}" >&2; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "请使用 root 运行：sudo $0"
    exit 1
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

is_alpine() { [[ -f /etc/alpine-release ]]; }

# 检测 init 系统：systemd / openrc / unknown
# 注意：只看 systemctl 二进制是否存在不够（容器里也可能有），必须同时是 PID 1
detect_init() {
  if cmd_exists systemctl && [[ -d /run/systemd/system ]]; then
    echo "systemd"
  elif cmd_exists rc-service; then
    echo "openrc"
  else
    echo "unknown"
  fi
}
INIT="$(detect_init)"

# 当前 init 系统需要的服务管理命令
init_cmds() {
  if [[ "$INIT" == "systemd" ]]; then
    echo "systemctl"
  elif [[ "$INIT" == "openrc" ]]; then
    echo "rc-service rc-update"
  fi
}

require_cmds() {
  local missing=()
  for c in "$@"; do
    cmd_exists "$c" || missing+=("$c")
  done
  if ((${#missing[@]})); then
    err "缺少依赖命令：${missing[*]}"
    if is_alpine; then
      err "请先安装：apk add --no-cache ${missing[*]}"
    elif cmd_exists apt-get; then
      err "请先安装（Debian/Ubuntu）：apt-get update && apt-get install -y ${missing[*]}"
    elif cmd_exists yum; then
      err "请先安装（CentOS/RHEL）：yum install -y ${missing[*]}"
    elif cmd_exists dnf; then
      err "请先安装（Fedora）：dnf install -y ${missing[*]}"
    else
      err "请手动安装缺失命令对应的软件包：${missing[*]}"
    fi
    exit 1
  fi
}

os_pretty() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    echo "${PRETTY_NAME:-Linux}"
  else
    echo "Linux"
  fi
}

detect_arch_asset() {
  local arch libc
  arch="$(uname -m)"

  # Alpine 是 musl libc，必须用 musl 构建；glibc 系发行版用 gnu 构建
  if is_alpine; then
    libc="musl"
  else
    libc="gnu"
  fi

  case "$arch" in
    x86_64|amd64) echo "realm-x86_64-unknown-linux-${libc}.tar.gz" ;;
    aarch64|arm64) echo "realm-aarch64-unknown-linux-${libc}.tar.gz" ;;
    *)
      err "不支持或未适配的架构：$arch"
      err "你可以手动下载 realm 并放到：$BIN（chmod +x），然后用本脚本进行配置/管理"
      return 1
      ;;
  esac
}

get_primary_ipv4() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  if [[ -n "${ip:-}" ]]; then
    echo "$ip"
    return 0
  fi
  ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
  echo "${ip:-N/A}"
}

get_primary_ipv6() {
  local ip=""
  ip="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  if [[ -n "${ip:-}" ]]; then
    echo "$ip"
    return 0
  fi
  ip="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6 /{print $2}' | cut -d/ -f1 | head -n1 || true)"
  echo "${ip:-N/A}"
}

ensure_dirs() {
  mkdir -p "$ETC_DIR"
  touch "$EP_DB"
  chmod 600 "$EP_DB"
}

# ---------------- 服务管理抽象层（systemd / OpenRC） ----------------

svc_exists() {
  if [[ "$INIT" == "systemd" ]]; then
    systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "realm.service"
  else
    [[ -f "$OPENRC_INIT" ]]
  fi
}

svc_active() {
  if [[ "$INIT" == "systemd" ]]; then
    systemctl is-active --quiet realm.service
  else
    rc-service realm status >/dev/null 2>&1
  fi
}

svc_enable_start() {
  if [[ "$INIT" == "systemd" ]]; then
    systemctl daemon-reload
    systemctl enable --now realm.service
  else
    rc-update add realm default >/dev/null
    rc-service realm start
  fi
}

svc_restart() {
  if [[ "$INIT" == "systemd" ]]; then
    systemctl restart realm.service
  else
    rc-service realm restart
  fi
}

svc_start() {
  if [[ "$INIT" == "systemd" ]]; then
    systemctl start realm.service
  else
    rc-service realm start
  fi
}

svc_stop() {
  if [[ "$INIT" == "systemd" ]]; then
    systemctl stop realm.service
  else
    rc-service realm stop
  fi
}

svc_uninstall() {
  if [[ "$INIT" == "systemd" ]]; then
    systemctl disable --now realm.service || true
    rm -f "$SERVICE"
    systemctl daemon-reload || true
  else
    rc-service realm stop || true
    rc-update del realm default || true
    rm -f "$OPENRC_INIT"
  fi
}

svc_status() {
  if [[ "$INIT" == "systemd" ]]; then
    systemctl --no-pager -l status realm.service || true
  else
    rc-service realm status || true
  fi
}

is_installed() {
  [[ -x "$BIN" ]] && svc_exists
}

write_service() {
  if [[ "$INIT" == "systemd" ]]; then
    cat >"$SERVICE" <<EOF
[Unit]
Description=Realm Relay Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$ETC_DIR
ExecStart=$BIN -c $CFG
Restart=on-failure
RestartSec=2s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  else
    cat >"$OPENRC_INIT" <<EOF
#!/sbin/openrc-run
# Auto-generated by realm.sh (OpenRC)

name="realm"
description="Realm Relay Service"
command="$BIN"
command_args="-c $CFG"
command_background=true
pidfile="/run/realm.pid"
directory="$ETC_DIR"
output_log="$OPENRC_LOG"
error_log="$OPENRC_LOG"

depend() {
    need net
    after net
}
EOF
    chmod +x "$OPENRC_INIT"
  fi
}

regen_config_from_db() {
  ensure_dirs

  cat >"$CFG" <<'EOF'
# Auto-generated by realm.sh
# Do not edit manually unless you know what you're doing.

[log]
level = "info"

[network]
no_tcp = false
use_udp = true

EOF

  local line listen_port remote_host remote_port config_rh
  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    [[ -z "${line// /}" ]] && continue
    [[ "${line:0:1}" == "#" ]] && continue

    listen_port="$(awk '{print $1}' <<<"$line")"
    remote_host="$(awk '{print $2}' <<<"$line")"
    remote_port="$(awk '{print $3}' <<<"$line")"

    if [[ -z "${listen_port:-}" || -z "${remote_host:-}" || -z "${remote_port:-}" ]]; then
      warn "跳过无效行：$line"
      continue
    fi

    if ! [[ "$listen_port" =~ ^[0-9]+$ ]] || ((listen_port < 1 || listen_port > 65535)); then
      warn "跳过非法本地端口：$line"
      continue
    fi
    if ! [[ "$remote_port" =~ ^[0-9]+$ ]] || ((remote_port < 1 || remote_port > 65535)); then
      warn "跳过非法目标端口：$line"
      continue
    fi

    # 针对 IPv6 地址的格式化处理：包含冒号且未被中括号包裹的，自动加上中括号
    config_rh="$remote_host"
    if [[ "$config_rh" =~ : ]] && [[ ! "$config_rh" =~ ^\[.*\]$ ]]; then
      config_rh="[${config_rh}]"
    fi

    cat >>"$CFG" <<EOF
[[endpoints]]
listen = "[::]:${listen_port}"
remote = "${config_rh}:${remote_port}"

EOF
  done <"$EP_DB"

  if ! grep -q '^\[\[endpoints\]\]' "$CFG"; then
    cat >>"$CFG" <<'EOF'
# No endpoints configured yet.
# Use realm.sh -> 配置管理 -> 添加转发
EOF
  fi
}

install_realm() {
  need_root
  require_cmds curl tar ip awk grep sed uname head cut $(init_cmds)

  # Alpine 自带的 busybox ip 不支持 `ip route get`，状态显示与链路测试会降级；
  # 提示安装完整版 iproute2（含 ss）以获得完整功能
  if is_alpine && ! ip route get 1.1.1.1 >/dev/null 2>&1; then
    warn "检测到 busybox ip（不支持 route get），建议安装完整版 iproute2"
    read -r -p "是否现在安装 iproute2（含 ss）？[y/N]: " ans
    case "${ans:-N}" in
      y|Y) apk add --no-cache iproute2 ;;
      *) warn "已跳过：IP 显示将回退到 ip addr 解析，ss 相关检测不可用" ;;
    esac
  fi

  ensure_dirs

  local asset tag url tmp
  asset="$(detect_arch_asset)"

  tag="$(curl -fsSL "https://api.github.com/repos/zhboner/realm/releases/latest" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n1 || true)"

  if [[ -z "${tag:-}" ]]; then
    err "获取最新版本失败（GitHub API）。你可以："
    err "1) 检查网络 / DNS（纯 IPv6 机器请确保可通过 NAT64 或 Warp 访问 GitHub）"
    err "2) 手动下载 realm 放到 $BIN，然后继续使用本脚本管理配置"
    exit 1
  fi

  url="https://github.com/zhboner/realm/releases/download/${tag}/${asset}"
  say "即将安装 Realm：${tag}（${asset}）"
  say "下载：${url}"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  curl -fL "$url" -o "$tmp/realm.tar.gz"
  tar -xzf "$tmp/realm.tar.gz" -C "$tmp"

  if [[ ! -f "$tmp/realm" ]]; then
    err "解压后未找到 realm 二进制：$tmp/realm"
    exit 1
  fi

  install -m 0755 "$tmp/realm" "$BIN"

  regen_config_from_db
  write_service
  svc_enable_start

  say "安装完成。"
  show_status
}

uninstall_realm() {
  need_root
  require_cmds $(init_cmds) rm ip

  svc_uninstall

  rm -f "$BIN"

  echo
  read -r -p "是否删除配置目录 $ETC_DIR ？（会删 endpoints 配置）[y/N]: " ans
  case "${ans:-N}" in
    y|Y)
      rm -rf "$ETC_DIR"
      say "已删除配置目录。"
      ;;
    *)
      say "保留配置目录：$ETC_DIR"
      ;;
  esac

  if [[ "$INIT" == "openrc" ]] && [[ -f "$OPENRC_LOG" ]]; then
    echo
    read -r -p "是否删除日志文件 $OPENRC_LOG ？[y/N]: " ans
    case "${ans:-N}" in
      y|Y)
        rm -f "$OPENRC_LOG"
        say "已删除日志文件。"
        ;;
      *)
        say "保留日志文件：$OPENRC_LOG"
        ;;
    esac
  fi

  say "卸载完成。"
}

add_endpoint() {
  need_root
  ensure_dirs

  echo
  read -r -p "请输入本地监听端口（中转端口）： " lp
  read -r -p "请输入落地节点地址（IP 或域名）： " rh
  read -r -p "请输入落地节点端口： " rp

  lp="${lp// /}"
  rp="${rp// /}"
  rh="${rh// /}"

  if [[ -z "${lp:-}" || -z "${rh:-}" || -z "${rp:-}" ]]; then
    err "输入不能为空。"
    return 1
  fi
  if ! [[ "$lp" =~ ^[0-9]+$ ]] || ((lp < 1 || lp > 65535)); then
    err "本地端口非法：$lp"
    return 1
  fi
  if ! [[ "$rp" =~ ^[0-9]+$ ]] || ((rp < 1 || rp > 65535)); then
    err "目标端口非法：$rp"
    return 1
  fi

  if awk '{print $1}' "$EP_DB" | grep -qx "$lp"; then
    err "本地端口 $lp 已存在。请用“修改/删除”功能。"
    return 1
  fi

  echo "${lp} ${rh} ${rp}" >>"$EP_DB"
  regen_config_from_db
  say "已添加：[::]:${lp} -> ${rh}:${rp}"

  svc_restart || true
  show_status
}

list_endpoints() {
  ensure_dirs
  echo
  echo "当前转发列表（格式：本地端口  目标地址  目标端口）："
  if [[ ! -s "$EP_DB" ]]; then
    echo "(空)"
    return 0
  fi

  # 注：原用 nl -ba，busybox 无 nl，改用 cat -n（显示效果等价）
  cat -n "$EP_DB" | sed 's/^/  /'
}

delete_endpoint() {
  need_root
  ensure_dirs
  list_endpoints

  if [[ ! -s "$EP_DB" ]]; then
    return 0
  fi

  echo
  read -r -p "请输入要删除的序号： " n
  n="${n// /}"
  if ! [[ "$n" =~ ^[0-9]+$ ]] || ((n < 1)); then
    err "序号非法：$n"
    return 1
  fi

  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN

  awk -v n="$n" 'NR!=n' "$EP_DB" >"$tmp"
  if cmp -s "$EP_DB" "$tmp"; then
    err "未删除任何行（可能序号不存在）。"
    return 1
  fi

  cat "$tmp" >"$EP_DB"
  regen_config_from_db
  say "已删除序号：$n"
  svc_restart || true
  show_status
}

edit_endpoint() {
  need_root
  ensure_dirs
  list_endpoints

  if [[ ! -s "$EP_DB" ]]; then
    return 0
  fi

  echo
  read -r -p "请输入要修改的序号： " n
  n="${n// /}"
  if ! [[ "$n" =~ ^[0-9]+$ ]] || ((n < 1)); then
    err "序号非法：$n"
    return 1
  fi

  local old lp rh rp
  old="$(awk -v n="$n" 'NR==n{print; exit}' "$EP_DB" || true)"
  if [[ -z "${old:-}" ]]; then
    err "序号不存在：$n"
    return 1
  fi

  lp="$(awk '{print $1}' <<<"$old")"
  rh="$(awk '{print $2}' <<<"$old")"
  rp="$(awk '{print $3}' <<<"$old")"

  echo
  echo "当前：$old"
  read -r -p "新的本地端口（回车保留 $lp）： " nlp
  read -r -p "新的目标地址（回车保留 $rh）： " nrh
  read -r -p "新的目标端口（回车保留 $rp）： " nrp

  nlp="${nlp// /}"
  nrh="${nrh// /}"
  nrp="${nrp// /}"

  [[ -z "${nlp:-}" ]] && nlp="$lp"
  [[ -z "${nrh:-}" ]] && nrh="$rh"
  [[ -z "${nrp:-}" ]] && nrp="$rp"

  if ! [[ "$nlp" =~ ^[0-9]+$ ]] || ((nlp < 1 || nlp > 65535)); then
    err "本地端口非法：$nlp"
    return 1
  fi
  if ! [[ "$nrp" =~ ^[0-9]+$ ]] || ((nrp < 1 || nrp > 65535)); then
    err "目标端口非法：$nrp"
    return 1
  fi

  if [[ "$nlp" != "$lp" ]]; then
    if awk -v n="$n" 'NR!=n{print $1}' "$EP_DB" | grep -qx "$nlp"; then
      err "本地端口 $nlp 已被其他规则使用。"
      return 1
    fi
  fi

  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN

  awk -v n="$n" -v lp="$nlp" -v rh="$nrh" -v rp="$nrp" 'BEGIN{OFS=" "} NR==n{$1=lp;$2=rh;$3=rp} {print}' "$EP_DB" >"$tmp"
  cat "$tmp" >"$EP_DB"

  regen_config_from_db
  say "已修改：${nlp} ${nrh} ${nrp}"
  svc_restart || true
  show_status
}

restart_service() { need_root; svc_restart; show_status; }
stop_service()    { need_root; svc_stop; show_status; }
start_service()   { need_root; svc_start; show_status; }

show_logs() {
  echo
  echo "按 Ctrl+C 退出日志查看。"
  if [[ "$INIT" == "systemd" ]]; then
    require_cmds journalctl
    journalctl -u realm.service -f --no-hostname -o cat
  else
    if [[ -f "$OPENRC_LOG" ]]; then
      tail -n 100 -f "$OPENRC_LOG"
    else
      err "日志文件不存在：$OPENRC_LOG（服务可能尚未启动过）"
      return 1
    fi
  fi
}

show_status() {
  require_cmds $(init_cmds) ip uname hostname awk

  local v4 v6
  v4="$(get_primary_ipv4)"
  v6="$(get_primary_ipv6)"

  echo
  echo "==================== 状态 ===================="
  echo "系统：$(os_pretty) [$INIT]"
  echo "主机：$(hostname)"
  echo "内核：$(uname -r)"
  echo "出口 IPv4：$v4"
  echo "出口 IPv6：$v6"
  echo "二进制：$BIN $([[ -x "$BIN" ]] && echo "(ok)" || echo "(missing)")"
  echo "配置：$CFG $([[ -f "$CFG" ]] && echo "(ok)" || echo "(missing)")"
  if [[ "$INIT" == "systemd" ]]; then
    echo "服务：realm.service"
  else
    echo "服务：$OPENRC_INIT"
  fi
  if svc_exists; then
    svc_status
  else
    echo "realm 服务未安装"
  fi

  echo
  echo "==================== 转发规则 ===================="
  if [[ -s "$EP_DB" ]]; then
    cat -n "$EP_DB" | sed 's/^/  /'
  else
    echo "  (空)"
  fi
  echo "=================================================="
}

tcp_connect_test() {
  local host="$1" port="$2" timeout_s="${3:-3}"
  if cmd_exists timeout; then
    timeout "${timeout_s}" bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" >/dev/null 2>&1
  else
    bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" >/dev/null 2>&1
  fi
}

link_test() {
  require_cmds ip getent awk sed head

  ensure_dirs
  if [[ ! -s "$EP_DB" ]]; then
    err "当前没有任何转发规则，无法测试。"
    return 1
  fi

  echo
  echo "将对每条规则进行："
  echo "1) 解析落地地址（如为域名）"
  echo "2) TCP 连通性探测（到 落地地址:落地端口）"
  echo "3) 本地端口占用情况提示"
  echo

  local line lp rh rp resolved ok
  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    [[ -z "${line// /}" ]] && continue
    [[ "${line:0:1}" == "#" ]] && continue

    lp="$(awk '{print $1}' <<<"$line")"
    rh="$(awk '{print $2}' <<<"$line")"
    rp="$(awk '{print $3}' <<<"$line")"

    echo "---- 规则：[::]:${lp} -> ${rh}:${rp}"

    resolved=""
    if [[ "$rh" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$rh" =~ : ]]; then
      resolved="$rh"
      echo "解析：IP（无需解析）"
    else
      resolved="$(getent ahosts "$rh" 2>/dev/null | awk '{print $1}' | head -n1 || true)"
      if [[ -n "${resolved:-}" ]]; then
        echo "解析：$rh -> $resolved"
      else
        echo "解析：失败（DNS/hosts）"
      fi
    fi

    if cmd_exists ss; then
      if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$lp$"; then
        echo "本地端口：$lp 已有 TCP 监听（可能冲突，也可能是 realm）"
      else
        echo "本地端口：$lp 未发现 TCP 监听（若服务运行中仍显示无监听，检查配置/权限）"
      fi
    else
      echo "本地端口：未检测（缺少 ss 命令，可安装 iproute2）"
    fi

    ok="FAIL"
    if [[ -n "${resolved:-}" ]]; then
      if tcp_connect_test "$resolved" "$rp" 3; then
        ok="OK"
      fi
    fi
    echo "落地 TCP 探测：$ok"
    echo
  done <"$EP_DB"
}

config_menu() {
  while true; do
    echo
    echo "========== 配置管理 =========="
    echo "1) 添加转发"
    echo "2) 查看转发列表"
    echo "3) 修改转发"
    echo "4) 删除转发"
    echo "5) 返回上级"
    read -r -p "请选择 [1-5]: " c
    case "${c:-}" in
      1) add_endpoint ;;
      2) list_endpoints ;;
      3) edit_endpoint ;;
      4) delete_endpoint ;;
      5) break ;;
      *) warn "无效选择" ;;
    esac
  done
}

main_menu() {
  need_root

  if [[ "$INIT" == "unknown" ]]; then
    err "不支持的 init 系统：未检测到 systemd（/run/systemd/system）或 OpenRC（rc-service）"
    err "当前系统：$(os_pretty)，请手动安装 realm 二进制并自行管理进程"
    exit 1
  fi

  require_cmds $(init_cmds) ip awk sed grep

  while true; do
    echo
    echo "============== Realm 一键管理 [$INIT] =============="
    echo "1) 安装 Realm"
    echo "2) 配置管理（添加/修改/删除转发）"
    echo "3) 启动服务"
    echo "4) 停止服务"
    echo "5) 重启服务"
    echo "6) 查看状态与信息"
    echo "7) 查看日志（实时）"
    echo "8) 中转网络链路测试"
    echo "9) 卸载 Realm"
    echo "0) 退出"
    read -r -p "请选择 [0-9]: " n

    case "${n:-}" in
      1) install_realm ;;
      2) config_menu ;;
      3) start_service ;;
      4) stop_service ;;
      5) restart_service ;;
      6) show_status ;;
      7) show_logs ;;
      8) link_test ;;
      9) uninstall_realm ;;
      0) exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

main_menu
realm.sh
