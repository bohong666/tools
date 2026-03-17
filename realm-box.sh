#!/usr/bin/env bash
set -euo pipefail

# =================
# Sing-box Manager
# =================
APP="sing-box"
BIN="/usr/local/bin/sing-box"
ETC_DIR="/etc/sing-box"
CFG="$ETC_DIR/config.json"
EP_DB="$ETC_DIR/endpoints.db"
SERVICE="/etc/systemd/system/sing-box.service"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

say()  { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
err()  { echo -e "${RED}$*${NC}" >&2; }
info() { echo -e "${CYAN}$*${NC}"; }

# ── 权限检查 ──────────────────────────────────────────────
need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "请使用 root 运行：sudo $0"
    exit 1
  fi
}

# ── 命令检测 ──────────────────────────────────────────────
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

require_cmds() {
  local missing=()
  for c in "$@"; do
    cmd_exists "$c" || missing+=("$c")
  done
  if (( ${#missing[@]} )); then
    err "缺少依赖命令：${missing[*]}"
    err "请先安装（Debian/Ubuntu）：apt-get update && apt-get install -y ${missing[*]}"
    err "请先安装（CentOS/RHEL）：yum install -y ${missing[*]}"
    exit 1
  fi
}

# ── 系统信息 ──────────────────────────────────────────────
os_pretty() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    echo "${PRETTY_NAME:-Linux}"
  else
    echo "Linux"
  fi
}

# ── 架构检测（sing-box 官方命名规则） ─────────────────────
detect_arch_asset() {
  local arch
  arch="$(uname -m)"
  local os_type
  os_type="$(uname -s | tr '[:upper:]' '[:lower:]')"

  case "$arch" in
    x86_64|amd64)   echo "linux-amd64" ;;
    aarch64|arm64)  echo "linux-arm64" ;;
    armv7l)         echo "linux-armv7" ;;
    armv6l)         echo "linux-armv6" ;;
    i386|i686)      echo "linux-386" ;;
    s390x)          echo "linux-s390x" ;;
    *)
      err "不支持或未适配的架构：$arch"
      err "可手动下载 sing-box 放至 $BIN（chmod +x），再使用本脚本管理配置"
      return 1
      ;;
  esac
}

# ── 网络出口 IP ───────────────────────────────────────────
get_primary_ipv4() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if ($i=="src"){print $(i+1); exit}}' || true)"
  [[ -z "${ip:-}" ]] && \
    ip="$(ip -4 addr show scope global 2>/dev/null \
      | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
  echo "${ip:-N/A}"
}

get_primary_ipv6() {
  local ip=""
  ip="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if ($i=="src"){print $(i+1); exit}}' || true)"
  [[ -z "${ip:-}" ]] && \
    ip="$(ip -6 addr show scope global 2>/dev/null \
      | awk '/inet6 /{print $2}' | cut -d/ -f1 | head -n1 || true)"
  echo "${ip:-N/A}"
}

# ── 目录初始化 ────────────────────────────────────────────
ensure_dirs() {
  mkdir -p "$ETC_DIR"
  touch "$EP_DB"
  chmod 600 "$EP_DB"
}

# ── 服务状态检测 ──────────────────────────────────────────
is_installed() {
  [[ -x "$BIN" ]] && [[ -f "$SERVICE" ]]
}

svc_exists() {
  systemctl list-unit-files 2>/dev/null \
    | awk '{print $1}' | grep -qx "sing-box.service"
}

svc_active() {
  systemctl is-active --quiet sing-box.service 2>/dev/null
}

# ── systemd 服务单元 ──────────────────────────────────────
write_service() {
  cat >"$SERVICE" <<EOF
[Unit]
Description=Sing-box Relay Service
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$ETC_DIR
ExecStart=$BIN run -c $CFG
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=2s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

# ── 从 endpoints.db 生成 sing-box JSON 配置 ───────────────
#
# 每条 DB 记录格式：
#   <本地端口> <目标地址> <目标端口> [协议]
#   协议缺省为 tcp+udp，可填：tcp / udp / both
#
regen_config_from_db() {
  ensure_dirs

  # 收集所有有效规则，构造 inbounds JSON 数组
  local inbounds_json=""
  local first=1
  local line lp rh rp proto tag

  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    [[ -z "${line// /}" ]] && continue
    [[ "${line:0:1}" == "#" ]] && continue

    lp="$(awk '{print $1}' <<<"$line")"
    rh="$(awk '{print $2}' <<<"$line")"
    rp="$(awk '{print $3}' <<<"$line")"
    proto="$(awk '{print $4}' <<<"$line")"
    proto="${proto:-both}"

    # 基本合法性校验（保持健壮性，生成时跳过非法行）
    if [[ -z "${lp:-}" || -z "${rh:-}" || -z "${rp:-}" ]]; then
      warn "跳过无效行：$line"
      continue
    fi
    if ! [[ "$lp" =~ ^[0-9]+$ ]] || (( lp < 1 || lp > 65535 )); then
      warn "跳过非法本地端口：$line"; continue
    fi
    if ! [[ "$rp" =~ ^[0-9]+$ ]] || (( rp < 1 || rp > 65535 )); then
      warn "跳过非法目标端口：$line"; continue
    fi

    # IPv6 地址加方括号
    local rh_fmt="$rh"
    if [[ "$rh_fmt" =~ : ]] && [[ ! "$rh_fmt" =~ ^\[.*\]$ ]]; then
      rh_fmt="[${rh_fmt}]"
    fi

    # 根据协议类型决定 network 字段
    local net_val
    case "$proto" in
      tcp)  net_val='"tcp"' ;;
      udp)  net_val='"udp"' ;;
      *)    net_val='"tcp"'  ;;   # sing-box redirect 默认 tcp；UDP 用 tun 或 direct 更合适
    esac

    # UDP 中转：sing-box 使用 direct outbound 的 override，需要特殊处理
    # 这里使用 redirect inbound（TCP）+ direct outbound 实现中转
    # 对 UDP 同样支持：network 字段控制
    tag="relay-${lp}"

    [[ "$first" -eq 1 ]] || inbounds_json+=","$'\n'
    first=0

    inbounds_json+=$(cat <<ENDJSON
    {
      "type": "direct",
      "tag": "${tag}",
      "listen": "::",
      "listen_port": ${lp},
      "network": "tcp",
      "override_address": "${rh_fmt}",
      "override_port": ${rp}
    }
ENDJSON
)

    # 如果协议包含 UDP，追加一个 UDP inbound
    if [[ "$proto" == "udp" || "$proto" == "both" ]]; then
      inbounds_json+=","$'\n'
      inbounds_json+=$(cat <<ENDJSON
    {
      "type": "direct",
      "tag": "${tag}-udp",
      "listen": "::",
      "listen_port": ${lp},
      "network": "udp",
      "override_address": "${rh_fmt}",
      "override_port": ${rp}
    }
ENDJSON
)
    fi

  done <"$EP_DB"

  # 若无任何规则，写一个占位空 inbound 避免 JSON 报错
  if [[ -z "${inbounds_json:-}" ]]; then
    inbounds_json=$(cat <<'ENDJSON'
    {
      "type": "direct",
      "tag": "placeholder",
      "listen": "127.0.0.1",
      "listen_port": 10000,
      "network": "tcp",
      "override_address": "127.0.0.1",
      "override_port": 10000
    }
ENDJSON
)
  fi

  cat >"$CFG" <<ENDCFG
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
${inbounds_json}
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
ENDCFG

  # 格式化验证（若 sing-box 已安装）
  if [[ -x "$BIN" ]]; then
    if ! "$BIN" check -c "$CFG" >/dev/null 2>&1; then
      warn "配置文件校验未通过，请检查 $CFG"
    fi
  fi
}

# ── 自动安装依赖（jq / curl / tar / systemctl 等） ────────
auto_install_deps() {
  local pkgs=()

  cmd_exists curl  || pkgs+=("curl")
  cmd_exists tar   || pkgs+=("tar")
  cmd_exists ip    || pkgs+=("iproute2")
  cmd_exists ss    || pkgs+=("iproute2")
  cmd_exists getent || pkgs+=("libc-bin")

  if (( ${#pkgs[@]} == 0 )); then
    return 0
  fi

  info "检测到缺少依赖，正在自动安装：${pkgs[*]}"

  if cmd_exists apt-get; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
  elif cmd_exists yum; then
    yum install -y -q "${pkgs[@]}"
  elif cmd_exists dnf; then
    dnf install -y -q "${pkgs[@]}"
  elif cmd_exists apk; then
    apk add --no-cache "${pkgs[@]}"
  else
    err "无法自动安装依赖，请手动安装：${pkgs[*]}"
    exit 1
  fi
}

# ── 获取 sing-box 最新版本号 ──────────────────────────────
get_latest_tag() {
  local tag=""

  # 方式1：GitHub API
  tag="$(curl -fsSL --connect-timeout 10 \
    "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
    2>/dev/null \
    | grep '"tag_name"' \
    | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' \
    | head -n1 || true)"

  # 方式2：重定向跟随
  if [[ -z "${tag:-}" ]]; then
    tag="$(curl -fsSL --connect-timeout 10 -o /dev/null -w '%{url_effective}' \
      "https://github.com/SagerNet/sing-box/releases/latest" \
      2>/dev/null | sed 's|.*/tag/||' || true)"
  fi

  echo "${tag:-}"
}

# ── 安装 sing-box ─────────────────────────────────────────
install_singbox() {
  need_root
  auto_install_deps
  require_cmds curl tar systemctl ip awk grep sed uname head cut

  ensure_dirs

  local arch_str tag asset_name url tmp ver_num

  arch_str="$(detect_arch_asset)"

  info "正在获取最新版本信息..."
  tag="$(get_latest_tag)"

  if [[ -z "${tag:-}" ]]; then
    err "获取最新版本失败（GitHub API 不可用）。你可以："
    err "1) 检查网络连通性（curl https://api.github.com/repos/SagerNet/sing-box/releases/latest）"
    err "2) 手动下载 sing-box 放到 $BIN，然后使用本脚本管理配置"
    exit 1
  fi

  # tag 格式可能为 "v1.x.x"，去掉 v 前缀用于文件名
  ver_num="${tag#v}"
  asset_name="sing-box-${ver_num}-${arch_str}.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/${tag}/${asset_name}"

  say "即将安装 Sing-box：${tag}（${arch_str}）"
  say "下载地址：${url}"

  tmp="$(mktemp -d)"
  # 确保退出时清理临时目录
  trap 'rm -rf "$tmp"' EXIT

  if ! curl -fL --connect-timeout 30 --retry 3 --retry-delay 3 \
       "$url" -o "$tmp/singbox.tar.gz"; then
    err "下载失败，请检查网络或手动下载：$url"
    exit 1
  fi

  tar -xzf "$tmp/singbox.tar.gz" -C "$tmp"

  # sing-box 解压后目录格式：sing-box-<ver>-<arch>/sing-box
  local extracted_bin
  extracted_bin="$(find "$tmp" -type f -name "sing-box" ! -name "*.tar.gz" | head -n1 || true)"

  if [[ -z "${extracted_bin:-}" || ! -f "$extracted_bin" ]]; then
    err "解压后未找到 sing-box 二进制文件，目录内容："
    ls -la "$tmp/" || true
    exit 1
  fi

  install -m 0755 "$extracted_bin" "$BIN"

  # 验证安装
  local installed_ver
  installed_ver="$("$BIN" version 2>/dev/null | head -n1 || echo "unknown")"
  say "安装成功：$installed_ver"

  regen_config_from_db
  write_service
  systemctl daemon-reload
  systemctl enable --now sing-box.service

  trap - EXIT
  rm -rf "$tmp"

  say "安装完成。"
  show_status
}

# ── 卸载 sing-box ─────────────────────────────────────────
uninstall_singbox() {
  need_root
  require_cmds systemctl

  if svc_exists; then
    systemctl disable --now sing-box.service 2>/dev/null || true
  fi

  rm -f "$SERVICE"
  systemctl daemon-reload 2>/dev/null || true

  rm -f "$BIN"

  echo
  read -r -p "是否删除配置目录 $ETC_DIR ？（会删除所有 endpoints 配置）[y/N]: " ans
  case "${ans:-N}" in
    y|Y)
      rm -rf "$ETC_DIR"
      say "已删除配置目录。"
      ;;
    *)
      say "保留配置目录：$ETC_DIR"
      ;;
  esac

  say "卸载完成。"
}

# ── 更新 sing-box 二进制 ──────────────────────────────────
update_singbox() {
  need_root

  if [[ ! -x "$BIN" ]]; then
    err "sing-box 未安装，请先选择安装。"
    return 1
  fi

  local current_ver
  current_ver="$("$BIN" version 2>/dev/null | grep -oP 'sing-box version \K\S+' || echo "unknown")"
  info "当前版本：${current_ver}"
  info "正在检查最新版本..."

  local arch_str tag ver_num asset_name url tmp extracted_bin

  arch_str="$(detect_arch_asset)"
  tag="$(get_latest_tag)"

  if [[ -z "${tag:-}" ]]; then
    err "获取最新版本失败。"
    return 1
  fi

  ver_num="${tag#v}"

  if [[ "$current_ver" == "$ver_num" ]]; then
    say "已经是最新版本：$ver_num，无需更新。"
    return 0
  fi

  say "发现新版本：$ver_num（当前：$current_ver），开始更新..."

  asset_name="sing-box-${ver_num}-${arch_str}.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/${tag}/${asset_name}"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  curl -fL --connect-timeout 30 --retry 3 --retry-delay 3 \
    "$url" -o "$tmp/singbox.tar.gz"

  tar -xzf "$tmp/singbox.tar.gz" -C "$tmp"

  extracted_bin="$(find "$tmp" -type f -name "sing-box" ! -name "*.tar.gz" | head -n1 || true)"

  if [[ -z "${extracted_bin:-}" || ! -f "$extracted_bin" ]]; then
    err "解压后未找到 sing-box 二进制。"
    exit 1
  fi

  install -m 0755 "$extracted_bin" "$BIN"

  trap - EXIT
  rm -rf "$tmp"

  systemctl restart sing-box.service || true
  say "更新完成：$("$BIN" version 2>/dev/null | head -n1 || echo "unknown")"
}

# ── 添加转发规则 ──────────────────────────────────────────
add_endpoint() {
  need_root
  ensure_dirs

  echo
  read -r -p "请输入本地监听端口（中转端口）：" lp
  read -r -p "请输入落地节点地址（IP 或域名）：" rh
  read -r -p "请输入落地节点端口：" rp

  lp="${lp// /}"
  rp="${rp// /}"
  rh="${rh// /}"

  if [[ -z "${lp:-}" || -z "${rh:-}" || -z "${rp:-}" ]]; then
    err "输入不能为空。"
    return 1
  fi
  if ! [[ "$lp" =~ ^[0-9]+$ ]] || (( lp < 1 || lp > 65535 )); then
    err "本地端口非法：$lp"
    return 1
  fi
  if ! [[ "$rp" =~ ^[0-9]+$ ]] || (( rp < 1 || rp > 65535 )); then
    err "目标端口非法：$rp"
    return 1
  fi

  # 检查本地端口是否已存在
  if grep -qP "^${lp}\s" "$EP_DB" 2>/dev/null; then
    err "本地端口 $lp 已存在，请使用"修改/删除"功能。"
    return 1
  fi

  echo
  echo "请选择转发协议："
  echo "  1) TCP + UDP（推荐，高速中转）"
  echo "  2) 仅 TCP"
  echo "  3) 仅 UDP"
  read -r -p "请选择 [1-3]（默认 1）：" proto_choice

  local proto
  case "${proto_choice:-1}" in
    2) proto="tcp" ;;
    3) proto="udp" ;;
    *) proto="both" ;;
  esac

  echo "${lp} ${rh} ${rp} ${proto}" >>"$EP_DB"
  regen_config_from_db
  say "已添加：[::]:${lp} -> ${rh}:${rp}（${proto}）"

  if svc_exists; then
    systemctl restart sing-box.service || true
  fi
  show_status
}

# ── 查看转发列表 ──────────────────────────────────────────
list_endpoints() {
  ensure_dirs
  echo
  echo "当前转发列表（格式：本地端口  目标地址  目标端口  协议）："
  if [[ ! -s "$EP_DB" ]]; then
    echo "  （空）"
    return 0
  fi
  nl -ba "$EP_DB" | sed 's/^/  /'
}

# ── 删除转发规则 ──────────────────────────────────────────
delete_endpoint() {
  need_root
  ensure_dirs
  list_endpoints

  if [[ ! -s "$EP_DB" ]]; then
    return 0
  fi

  echo
  read -r -p "请输入要删除的序号：" n
  n="${n// /}"
  if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 )); then
    err "序号非法：$n"
    return 1
  fi

  local total
  total="$(wc -l <"$EP_DB")"
  if (( n > total )); then
    err "序号超出范围（共 $total 条）。"
    return 1
  fi

  local tmp
  tmp="$(mktemp)"
  # 利用 RETURN 陷阱确保临时文件清理
  trap 'rm -f "$tmp"' RETURN

  awk -v n="$n" 'NR!=n' "$EP_DB" >"$tmp"
  cat "$tmp" >"$EP_DB"

  regen_config_from_db
  say "已删除第 $n 条规则。"

  if svc_exists; then
    systemctl restart sing-box.service || true
  fi
  show_status
}

# ── 修改转发规则 ──────────────────────────────────────────
edit_endpoint() {
  need_root
  ensure_dirs
  list_endpoints

  if [[ ! -s "$EP_DB" ]]; then
    return 0
  fi

  echo
  read -r -p "请输入要修改的序号：" n
  n="${n// /}"
  if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 )); then
    err "序号非法：$n"
    return 1
  fi

  local old lp rh rp proto
  old="$(awk -v n="$n" 'NR==n{print; exit}' "$EP_DB" 2>/dev/null || true)"
  if [[ -z "${old:-}" ]]; then
    err "序号不存在：$n"
    return 1
  fi

  lp="$(awk '{print $1}' <<<"$old")"
  rh="$(awk '{print $2}' <<<"$old")"
  rp="$(awk '{print $3}' <<<"$old")"
  proto="$(awk '{print $4}' <<<"$old")"
  proto="${proto:-both}"

  echo
  echo "当前规则：$old"
  read -r -p "新的本地端口（回车保留 $lp）：" nlp
  read -r -p "新的目标地址（回车保留 $rh）：" nrh
  read -r -p "新的目标端口（回车保留 $rp）：" nrp

  nlp="${nlp// /}"; nrh="${nrh// /}"; nrp="${nrp// /}"
  [[ -z "${nlp:-}" ]] && nlp="$lp"
  [[ -z "${nrh:-}" ]] && nrh="$rh"
  [[ -z "${nrp:-}" ]] && nrp="$rp"

  if ! [[ "$nlp" =~ ^[0-9]+$ ]] || (( nlp < 1 || nlp > 65535 )); then
    err "本地端口非法：$nlp"; return 1
  fi
  if ! [[ "$nrp" =~ ^[0-9]+$ ]] || (( nrp < 1 || nrp > 65535 )); then
    err "目标端口非法：$nrp"; return 1
  fi

  # 检查新端口是否与其他条目冲突
  if [[ "$nlp" != "$lp" ]]; then
    if awk -v n="$n" 'NR!=n{print $1}' "$EP_DB" | grep -qx "$nlp"; then
      err "本地端口 $nlp 已被其他规则使用。"
      return 1
    fi
  fi

  echo
  echo "请选择转发协议（当前：$proto）："
  echo "  1) TCP + UDP"
  echo "  2) 仅 TCP"
  echo "  3) 仅 UDP"
  read -r -p "请选择 [1-3]（回车保留）：" proto_choice

  local nproto
  case "${proto_choice:-}" in
    1) nproto="both" ;;
    2) nproto="tcp" ;;
    3) nproto="udp" ;;
    *) nproto="$proto" ;;
  esac

  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN

  awk -v n="$n" \
      -v lp="$nlp" -v rh="$nrh" -v rp="$nrp" -v pr="$nproto" \
      'BEGIN{OFS=" "} NR==n{$1=lp; $2=rh; $3=rp; $4=pr} {print}' \
      "$EP_DB" >"$tmp"
  cat "$tmp" >"$EP_DB"

  regen_config_from_db
  say "已修改：${nlp} ${nrh} ${nrp} ${nproto}"

  if svc_exists; then
    systemctl restart sing-box.service || true
  fi
  show_status
}

# ── 服务控制 ──────────────────────────────────────────────
restart_service() { need_root; systemctl restart sing-box.service; show_status; }
stop_service()    { need_root; systemctl stop    sing-box.service; show_status; }
start_service()   { need_root; systemctl start   sing-box.service; show_status; }

reload_config() {
  need_root
  regen_config_from_db
  if svc_exists; then
    systemctl reload-or-restart sing-box.service || true
  fi
  say "配置已重新加载。"
}

# ── 日志查看 ──────────────────────────────────────────────
show_logs() {
  require_cmds journalctl
  echo
  echo "按 Ctrl+C 退出日志查看。"
  journalctl -u sing-box.service -f --no-hostname -o cat
}

# ── 状态总览 ──────────────────────────────────────────────
show_status() {
  require_cmds systemctl ip uname hostname awk

  local v4 v6 bin_ver
  v4="$(get_primary_ipv4)"
  v6="$(get_primary_ipv6)"
  bin_ver="$([[ -x "$BIN" ]] && "$BIN" version 2>/dev/null | head -n1 || echo "未安装")"

  echo
  echo "==================== 状态 ===================="
  echo "系统：$(os_pretty)"
  echo "主机：$(hostname)"
  echo "内核：$(uname -r)"
  echo "出口 IPv4：$v4"
  echo "出口 IPv6：$v6"
  echo "程序版本：$bin_ver"
  echo "二进制：$BIN $([[ -x "$BIN" ]] && echo "(ok)" || echo "(missing)")"
  echo "配置：$CFG $([[ -f "$CFG" ]] && echo "(ok)" || echo "(missing)")"
  echo "服务：sing-box.service"

  if svc_exists; then
    systemctl --no-pager -l status sing-box.service 2>/dev/null || true
  else
    echo "sing-box.service 未安装"
  fi

  echo
  echo "==================== 转发规则 ===================="
  if [[ -s "$EP_DB" ]]; then
    printf "  %-6s %-22s %-12s %s\n" "序号" "本地端口" "目标地址" "协议"
    echo "  --------------------------------------------------"
    local n=1
    while IFS= read -r line || [[ -n "${line:-}" ]]; do
      [[ -z "${line// /}" ]] && continue
      [[ "${line:0:1}" == "#" ]] && continue
      local lp rh rp pr
      lp="$(awk '{print $1}' <<<"$line")"
      rh="$(awk '{print $2}' <<<"$line")"
      rp="$(awk '{print $3}' <<<"$line")"
      pr="$(awk '{print $4}' <<<"$line")"; pr="${pr:-both}"
      printf "  %-6s [::]:%-16s %s:%-6s %s\n" "$n" "$lp" "$rh" "$rp" "$pr"
      (( n++ ))
    done <"$EP_DB"
  else
    echo "  （空）"
  fi
  echo "=================================================="
}

# ── TCP 连通性测试工具函数 ────────────────────────────────
tcp_connect_test() {
  local host="$1" port="$2" timeout_s="${3:-3}"
  if cmd_exists timeout; then
    timeout "${timeout_s}" bash -c \
      "cat < /dev/null > /dev/tcp/${host}/${port}" >/dev/null 2>&1
  else
    bash -c \
      "cat < /dev/null > /dev/tcp/${host}/${port}" >/dev/null 2>&1
  fi
}

# ── 链路测试 ──────────────────────────────────────────────
link_test() {
  require_cmds ip awk sed head

  ensure_dirs
  if [[ ! -s "$EP_DB" ]]; then
    err "当前没有任何转发规则，无法测试。"
    return 1
  fi

  echo
  echo "将对每条规则进行："
  echo "  1) DNS 解析（如为域名）"
  echo "  2) TCP 连通性探测（到落地地址:落地端口）"
  echo "  3) 本地端口占用情况提示"
  echo

  local line lp rh rp proto resolved ok
  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    [[ -z "${line// /}" ]] && continue
    [[ "${line:0:1}" == "#" ]] && continue

    lp="$(awk '{print $1}' <<<"$line")"
    rh="$(awk '{print $2}' <<<"$line")"
    rp="$(awk '{print $3}' <<<"$line")"
    proto="$(awk '{print $4}' <<<"$line")"; proto="${proto:-both}"

    echo "---- 规则：[::]:${lp} -> ${rh}:${rp}（${proto}）"

    # DNS 解析
    resolved=""
    if [[ "$rh" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$rh" =~ : ]]; then
      resolved="$rh"
      echo "  解析：IP（无需解析）"
    else
      if cmd_exists getent; then
        resolved="$(getent ahosts "$rh" 2>/dev/null \
          | awk '{print $1}' | head -n1 || true)"
      elif cmd_exists nslookup; then
        resolved="$(nslookup "$rh" 2>/dev/null \
          | awk '/^Address: /{print $2}' | head -n1 || true)"
      fi
      if [[ -n "${resolved:-}" ]]; then
        echo "  解析：$rh -> $resolved"
      else
        echo "  解析：失败（DNS/hosts 不可用）"
        resolved=""
      fi
    fi

    # 本地端口占用检测
    if cmd_exists ss; then
      if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "(^|:)${lp}$"; then
        echo "  本地端口：$lp 已有 TCP 监听（sing-box 运行中或端口冲突）"
      else
        echo "  本地端口：$lp 未发现 TCP 监听（服务未运行或配置有误）"
      fi
    else
      echo "  本地端口：未检测（缺少 ss 命令）"
    fi

    # TCP 连通性探测
    ok="FAIL"
    if [[ -n "${resolved:-}" ]]; then
      if tcp_connect_test "$resolved" "$rp" 5; then
        ok="OK"
      fi
    fi
    echo "  落地 TCP 探测：$ok"
    echo
  done <"$EP_DB"
}

# ── 配置管理子菜单 ────────────────────────────────────────
config_menu() {
  while true; do
    echo
    echo "========== 配置管理 =========="
    echo "1) 添加转发"
    echo "2) 查看转发列表"
    echo "3) 修改转发"
    echo "4) 删除转发"
    echo "5) 重新生成配置（不重启）"
    echo "6) 返回上级"
    read -r -p "请选择 [1-6]：" c
    case "${c:-}" in
      1) add_endpoint ;;
      2) list_endpoints ;;
      3) edit_endpoint ;;
      4) delete_endpoint ;;
      5) regen_config_from_db && say "配置已重新生成：$CFG" ;;
      6) break ;;
      *) warn "无效选择" ;;
    esac
  done
}

# ── 主菜单 ────────────────────────────────────────────────
main_menu() {
  need_root
  auto_install_deps

  while true; do
    echo
    echo "========== Sing-box 一键中转管理 =========="
    if is_installed; then
      local ver
      ver="$("$BIN" version 2>/dev/null | grep -oP 'sing-box version \K\S+' || echo "?")"
      echo "  当前版本：sing-box ${ver}"
    else
      echo "  sing-box：未安装"
    fi
    echo
    echo " 1) 安装 Sing-box"
    echo " 2) 更新 Sing-box"
    echo " 3) 配置管理（添加/修改/删除转发）"
    echo " 4) 启动服务"
    echo " 5) 停止服务"
    echo " 6) 重启服务"
    echo " 7) 重载配置（热重启）"
    echo " 8) 查看状态与信息"
    echo " 9) 查看日志（实时）"
    echo "10) 中转链路测试"
    echo "11) 卸载 Sing-box"
    echo " 0) 退出"
    echo
    read -r -p "请选择 [0-11]：" n

    case "${n:-}" in
       1) install_singbox ;;
       2) update_singbox ;;
       3) config_menu ;;
       4) start_service ;;
       5) stop_service ;;
       6) restart_service ;;
       7) reload_config ;;
       8) show_status ;;
       9) show_logs ;;
      10) link_test ;;
      11) uninstall_singbox ;;
       0) exit 0 ;;
       *) warn "无效选择" ;;
    esac
  done
}

main_menu
