#!/usr/bin/env bash
# ==============================================================
# sing-box VPS 管理脚本（RFC 专用）
# 功能：
#   - 安装 / 管理 sing-box
#   - 单 443 端口：本机 Reality 落地 + 中转多个 Reality 落地
#   - 多本机节点、多中转目标
#   - 导出 VLESS 连接
#   - 服务状态 / 重启
#
# 数据结构：
#   /etc/sb_manager
#     local.db  每行：uuid|port|sni|private_key|public_key|short_id|name|fingerprint
#     relay.db  每行：label|sni|remote_host|remote_port|uuid|public_key|short_id|fingerprint
#
# 入口：
#   sing-box 监听 443（mixed + fallback）
#   - SNI 命中 local.db → 转发到本机对应 port（Reality 入站）
#   - SNI 命中 relay.db → 透明 TCP 转发到 remote_host:remote_port
# ==============================================================

set -euo pipefail

SCRIPT_VERSION="v1.0.0"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_err()   { echo -e "${RED}[ERR]${NC}   $*" >&2; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }
log_title() {
  echo ""
  echo -e "${MAGENTA}══════════════════════════════════════════════${NC}"
  echo -e "${MAGENTA}  $*${NC}"
  echo -e "${MAGENTA}══════════════════════════════════════════════${NC}"
  echo ""
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log_err "请用 root 运行：sudo $0"
    exit 1
  fi
}

# ── 全局路径 ──────────────────────────────────────────────────
SB_BIN="/usr/local/bin/sing-box"
SB_ETC="/etc/sing-box"
SB_CFG="$SB_ETC/config.json"

DATA_DIR="/etc/sb_manager"
LOCAL_DB="$DATA_DIR/local.db"
RELAY_DB="$DATA_DIR/relay.db"

PKG_MGR=""

detect_os() {
  if [[ ! -f /etc/os-release ]]; then
    log_err "无法识别系统（缺少 /etc/os-release）"
    exit 1
  fi
  # shellcheck source=/dev/null
  source /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) PKG_MGR="apt" ;;
    alpine)        PKG_MGR="apk" ;;
    *) log_err "不支持的发行版：${ID:-unknown}（仅支持 Ubuntu/Debian/Alpine）"; exit 1 ;;
  esac
  log_info "检测到系统：$ID"
}

install_deps() {
  log_step "安装依赖..."
  if [[ "$PKG_MGR" == "apt" ]]; then
    apt-get update -qq
    apt-get install -y -qq curl wget unzip jq >/dev/null 2>&1 || true
  else
    apk update -q
    apk add --no-cache curl wget unzip jq >/dev/null 2>&1 || true
  fi
}

install_singbox() {
  if [[ -x "$SB_BIN" ]]; then
    log_info "已检测到 sing-box：$("$SB_BIN" version 2>/dev/null | head -1)"
    return
  fi
  log_step "安装 sing-box..."
  local arch tag url tmp
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) log_err "不支持架构：$(uname -m)"; exit 1 ;;
  esac
  tag=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [[ -z "$tag" ]] && { log_err "获取 sing-box 版本失败"; exit 1; }
  url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${tag#v}-linux-${arch}.tar.gz"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  curl -fL --retry 3 --retry-delay 2 -o "$tmp/sb.tgz" "$url"
  tar -xzf "$tmp/sb.tgz" -C "$tmp"
  install -m 755 "$tmp"/sing-box-*/sing-box "$SB_BIN"
  mkdir -p "$SB_ETC"
  log_info "sing-box 安装完成：$("$SB_BIN" version 2>/dev/null | head -1)"
}

ensure_dirs() {
  mkdir -p "$DATA_DIR" "$SB_ETC"
  touch "$LOCAL_DB" "$RELAY_DB"
  chmod 600 "$LOCAL_DB" "$RELAY_DB"
}

gen_uuid() {
  if [[ -f /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid
  fi
}

gen_short_id() {
  openssl rand -hex 8
}

gen_reality_keys() {
  local out
  out=$("$SB_BIN" generate reality-keypair)
  REAL_PRIV=$(echo "$out" | awk '/PrivateKey/{print $2}')
  REAL_PUB=$(echo "$out"  | awk '/PublicKey/{print $2}')
}

create_service() {
  if [[ -f /etc/systemd/system/sing-box.service ]]; then
    systemctl daemon-reload
    return
  fi
  cat >/etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box Service
After=network-online.target
Wants=network-online.target

[Service]
User=root
ExecStart=${SB_BIN} run -c ${SB_CFG}
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sing-box >/dev/null 2>&1 || true
}

sb_status() {
  systemctl status sing-box --no-pager -n 5 2>/dev/null || log_warn "sing-box 服务不存在"
}

sb_restart() {
  systemctl restart sing-box 2>/dev/null || log_warn "无法重启 sing-box"
  sleep 1
  if systemctl is-active --quiet sing-box 2>/dev/null; then
    log_info "sing-box 已运行"
  else
    log_err "sing-box 启动失败，请检查日志：journalctl -u sing-box -n 50"
  fi
}

# ── URL 编码 & VLESS URI ──────────────────────────────────────
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
  local uuid="$1" host="$2" port="$3" sni="$4" pbk="$5" sid="$6" name="$7" fp="$8"
  local enc_name; enc_name=$(urlencode "$name")
  echo "vless://${uuid}@${host}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=${fp}&pbk=${pbk}&sid=${sid}&type=tcp&headerType=none#${enc_name}"
}

# ── 获取本机 IP（用于导出）────────────────────────────────────
get_ipv4() {
  curl -s -4 --max-time 6 https://api4.ipify.org 2>/dev/null || echo ""
}
get_ipv6() {
  curl -s -6 --max-time 6 https://api6.ipify.org 2>/dev/null || echo ""
}

# ── 生成 sing-box 配置（核心：443 + fallback + 本机 Reality）──
regen_config() {
  log_step "重新生成 sing-box 配置..."

  local ipv4 ipv6
  ipv4=$(get_ipv4); ipv6=$(get_ipv6)

  # 构造 JSON：用 jq 简化
  local tmp; tmp=$(mktemp)
  cat >"$tmp" <<'EOF'
{
  "log": {
    "level": "warn"
  },
  "inbounds": [],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block",  "tag": "block"  }
  ]
}
EOF

  # 1) mixed 443 inbound + fallbacks
  local fb_json="[]"
  # local.db → fallback 到本机端口
  while IFS='|' read -r uuid port sni priv pub sid name fp || [[ -n "${uuid:-}" ]]; do
    [[ -z "${uuid:-}" || "${uuid:0:1}" == "#" ]] && continue
    fb_json=$(echo "$fb_json" | jq --arg s "$sni" --arg d "127.0.0.1:${port}" '. + [{sni:$s, dest:$d}]')
  done < "$LOCAL_DB"

  # relay.db → fallback 到远程
  while IFS='|' read -r label sni rhost rport uuid pub sid fp || [[ -n "${label:-}" ]]; do
    [[ -z "${label:-}" || "${label:0:1}" == "#" ]] && continue
    local dest="$rhost:$rport"
    fb_json=$(echo "$fb_json" | jq --arg s "$sni" --arg d "$dest" '. + [{sni:$s, dest:$d}]')
  done < "$RELAY_DB"

  # mixed inbound
  local in_mixed
  in_mixed=$(jq -n --argjson fb "$fb_json" '{
    "type": "mixed",
    "tag": "in-443",
    "listen": "::",
    "listen_port": 443,
    "sniff": true,
    "sniff_override_destination": true,
    "fallbacks": ($fb | map({sni:.sni, dest:.dest}))
  }')

  # 2) 本机 Reality inbounds
  local in_local="[]"
  while IFS='|' read -r uuid port sni priv pub sid name fp || [[ -n "${uuid:-}" ]]; do
    [[ -z "${uuid:-}" || "${uuid:0:1}" == "#" ]] && continue
    local one
    one=$(jq -n \
      --arg uuid "$uuid" \
      --arg port "$port" \
      --arg sni "$sni" \
      --arg priv "$priv" \
      --arg sid "$sid" \
      --arg name "$name" \
      --arg fp "${fp:-chrome}" '
      {
        "type": "vless",
        "tag": ("local-" + $port),
        "listen": "::",
        "listen_port": ($port|tonumber),
        "users": [
          { "uuid": $uuid, "flow": "xtls-rprx-vision" }
        ],
        "tls": {
          "enabled": true,
          "server_name": $sni,
          "reality": {
            "enabled": true,
            "private_key": $priv,
            "short_id": $sid
          }
        },
        "transport": { "type": "tcp" }
      }')
    in_local=$(echo "$in_local" | jq --argjson o "$one" '. + [$o]')
  done < "$LOCAL_DB"

  # 合并 inbounds
  local final
  final=$(jq \
    --argjson in_m "$in_mixed" \
    --argjson in_l "$in_local" \
    '.inbounds = ([$in_m] + $in_l)' "$tmp")

  echo "$final" > "$SB_CFG"

  log_info "配置已写入：$SB_CFG"
  log_step "校验配置..."
  if ! "$SB_BIN" check -c "$SB_CFG"; then
    log_err "配置校验失败，请检查 $SB_CFG"
    return 1
  fi
  log_info "配置校验通过"
}

# ── 添加本机 Reality 节点 ─────────────────────────────────────
add_local_node() {
  log_title "添加本机 Reality 节点（RFC 落地）"

  read -rp "节点名称（例如 RFC-KEIO）: " name
  [[ -z "$name" ]] && name="RFC-$(date +%Y%m%d-%H%M%S)"

  local port
  while true; do
    read -rp "监听端口 [默认 10000]: " port
    [[ -z "$port" ]] && port=10000
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
      log_err "端口无效"; continue
    fi
    if [[ "$port" == "443" ]]; then
      log_err "本机 Reality 禁止使用 443（443 由 mixed 入口统一管理）"
      continue
    fi
    break
  done

  read -rp "本机落地 SNI（例如 keio.ac.jp）[默认 keio.ac.jp]: " sni
  [[ -z "$sni" ]] && sni="keio.ac.jp"

  echo "可用指纹：chrome firefox safari ios android edge 360 qq"
  read -rp "client-fingerprint [默认 chrome]: " fp
  [[ -z "$fp" ]] && fp="chrome"

  local uuid sid
  uuid=$(gen_uuid)
  sid=$(gen_short_id)
  gen_reality_keys
  local priv="$REAL_PRIV" pub="$REAL_PUB"

  echo "${uuid}|${port}|${sni}|${priv}|${pub}|${sid}|${name}|${fp}" >> "$LOCAL_DB"
  log_info "本机节点已写入 local.db"

  regen_config
  sb_restart

  log_info "本机节点添加完成"
  show_local_node_detail "$uuid" "$port" "$sni" "$priv" "$pub" "$sid" "$name" "$fp"
}

show_local_node_detail() {
  local uuid="$1" port="$2" sni="$3" priv="$4" pub="$5" sid="$6" name="$7" fp="$8"
  local ipv4 ipv6 host
  ipv4=$(get_ipv4); ipv6=$(get_ipv6)
  host="${ipv4:-$ipv6}"

  echo -e "${CYAN}════════ 本机节点：$name ════════${NC}"
  echo "UUID:        $uuid"
  echo "Port:        443（对外） → 本机实际监听 $port"
  echo "SNI:         $sni"
  echo "Reality 公钥: $pub"
  echo "Reality 私钥: $priv"
  echo "short_id:    $sid"
  echo "Fingerprint: $fp"
  [[ -n "$host" ]] && echo "Server:      $host"
  echo ""

  if [[ -n "$host" ]]; then
    local uri
    uri=$(make_vless_uri "$uuid" "$host" "443" "$sni" "$pub" "$sid" "$name" "$fp")
    echo -e "${GREEN}VLESS URI（本机落地）:${NC}"
    echo -e "${YELLOW}${uri}${NC}"
  fi
  echo -e "${CYAN}══════════════════════════════════${NC}"
}

list_local_nodes() {
  echo -e "${CYAN}── 本机 Reality 节点列表 ───────────────${NC}"
  if [[ ! -s "$LOCAL_DB" ]]; then
    echo "  (无本机节点)"
    return
  fi
  local idx=0
  while IFS='|' read -r uuid port sni priv pub sid name fp || [[ -n "${uuid:-}" ]]; do
    [[ -z "${uuid:-}" || "${uuid:0:1}" == "#" ]] && continue
    idx=$((idx+1))
    echo "  [$idx] $name  SNI:$sni  端口:$port  UUID:${uuid:0:8}..."
  done < "$LOCAL_DB"
  [[ $idx -eq 0 ]] && echo "  (无本机节点)"
}

# ── 添加中转目标（IIJ 等）─────────────────────────────────────
add_relay_target() {
  log_title "添加中转目标（IIJ / 其他 VPS Reality）"

  read -rp "中转标签（例如 IIJ-ASCII）: " label
  [[ -z "$label" ]] && label="Relay-$(date +%Y%m%d-%H%M%S)"

  read -rp "中转目标 SNI（例如 ascii.jp）: " sni
  [[ -z "$sni" ]] && { log_err "SNI 不能为空"; return; }

  read -rp "远程 Reality 服务器 IP（可填 IPv4 或 IPv6）: " rhost
  [[ -z "$rhost" ]] && { log_err "远程 IP 不能为空"; return; }

  read -rp "远程 Reality 端口 [默认 443]: " rport
  [[ -z "$rport" ]] && rport=443

  read -rp "远程 Reality UUID: " uuid
  [[ -z "$uuid" ]] && { log_err "UUID 不能为空"; return; }

  read -rp "远程 Reality 公钥（pbk）: " pub
  [[ -z "$pub" ]] && { log_err "公钥不能为空"; return; }

  read -rp "远程 Reality short_id: " sid
  [[ -z "$sid" ]] && { log_err "short_id 不能为空"; return; }

  echo "可用指纹：chrome firefox safari ios android edge 360 qq"
  read -rp "client-fingerprint [默认 chrome]: " fp
  [[ -z "$fp" ]] && fp="chrome"

  # IPv6 目标加 []
  if [[ "$rhost" == *:* ]]; then
    rhost="[$rhost]"
  fi

  echo "${label}|${sni}|${rhost}|${rport}|${uuid}|${pub}|${sid}|${fp}" >> "$RELAY_DB"
  log_info "中转目标已写入 relay.db"

  regen_config
  sb_restart

  log_info "中转目标添加完成"
  show_relay_detail "$label" "$sni" "$rhost" "$rport" "$uuid" "$pub" "$sid" "$fp"
}

show_relay_detail() {
  local label="$1" sni="$2" rhost="$3" rport="$4" uuid="$5" pub="$6" sid="$7" fp="$8"
  local ipv4 ipv6 host
  ipv4=$(get_ipv4); ipv6=$(get_ipv6)
  host="${ipv4:-$ipv6}"

  echo -e "${CYAN}════════ 中转目标：$label ════════${NC}"
  echo "中转 SNI:      $sni"
  echo "远程地址:      $rhost:$rport"
  echo "远程 UUID:     $uuid"
  echo "远程 公钥:     $pub"
  echo "远程 short_id: $sid"
  echo "Fingerprint:   $fp"
  [[ -n "$host" ]] && echo "入口服务器:   $host:443"
  echo ""

  if [[ -n "$host" ]]; then
    local uri
    uri=$(make_vless_uri "$uuid" "$host" "443" "$sni" "$pub" "$sid" "$label" "$fp")
    echo -e "${GREEN}VLESS URI（通过 RFC 中转到远程）:${NC}"
    echo -e "${YELLOW}${uri}${NC}"
  fi
  echo -e "${CYAN}══════════════════════════════════${NC}"
}

list_relay_targets() {
  echo -e "${CYAN}── 中转目标列表 ─────────────────────${NC}"
  if [[ ! -s "$RELAY_DB" ]]; then
    echo "  (无中转目标)"
    return
  fi
  local idx=0
  while IFS='|' read -r label sni rhost rport uuid pub sid fp || [[ -n "${label:-}" ]]; do
    [[ -z "${label:-}" || "${label:0:1}" == "#" ]] && continue
    idx=$((idx+1))
    echo "  [$idx] $label  SNI:$sni  远程:${rhost}:${rport}"
  done < "$RELAY_DB"
  [[ $idx -eq 0 ]] && echo "  (无中转目标)"
}

# ── 导出所有 VLESS 连接 ──────────────────────────────────────
export_all_vless() {
  log_title "导出所有 VLESS 连接"
  local ipv4 ipv6 host
  ipv4=$(get_ipv4); ipv6=$(get_ipv6)
  host="${ipv4:-$ipv6}"
  if [[ -z "$host" ]]; then
    log_warn "无法获取公网 IP，导出仍会生成（请手动替换 host）"
    host="YOUR_RFC_IP"
  fi

  local out="/root/sb_vless_export_$(date +%Y%m%d_%H%M%S).txt"
  {
    echo "# sing-box Manager ${SCRIPT_VERSION} - VLESS 导出"
    echo "# 时间: $(date)"
    echo "# 入口服务器: $host:443"
    echo ""

    if [[ -s "$LOCAL_DB" ]]; then
      echo "## 本机 Reality 节点"
      while IFS='|' read -r uuid port sni priv pub sid name fp || [[ -n "${uuid:-}" ]]; do
        [[ -z "${uuid:-}" || "${uuid:0:1}" == "#" ]] && continue
        echo "### $name"
        make_vless_uri "$uuid" "$host" "443" "$sni" "$pub" "$sid" "$name" "${fp:-chrome}"
        echo ""
      done < "$LOCAL_DB"
    else
      echo "## 本机节点：无"
      echo ""
    fi

    if [[ -s "$RELAY_DB" ]]; then
      echo "## 中转目标"
      while IFS='|' read -r label sni rhost rport uuid pub sid fp || [[ -n "${label:-}" ]]; do
        [[ -z "${label:-}" || "${label:0:1}" == "#" ]] && continue
        echo "### $label"
        make_vless_uri "$uuid" "$host" "443" "$sni" "$pub" "$sid" "$label" "${fp:-chrome}"
        echo ""
      done < "$RELAY_DB"
    else
      echo "## 中转目标：无"
      echo ""
    fi
  } > "$out"

  log_info "已导出到：$out"
  cat "$out"
}

# ── 删除节点 / 中转（简单版）──────────────────────────────────
delete_local_node() {
  list_local_nodes
  [[ ! -s "$LOCAL_DB" ]] && return
  read -rp "输入要删除的本机节点序号: " n
  n="${n// /}"
  [[ ! "$n" =~ ^[0-9]+$ ]] && { log_err "序号无效"; return; }
  local line; line=$(awk -F'|' '!/^#/ && NF>=8' "$LOCAL_DB" | awk -v n="$n" 'NR==n')
  [[ -z "$line" ]] && { log_err "序号不存在"; return; }
  local uuid name; uuid=$(echo "$line" | cut -d'|' -f1); name=$(echo "$line" | cut -d'|' -f7)
  read -rp "确认删除本机节点 '$name'? [y/N]: " c
  [[ "${c:-N}" != "y" ]] && { log_info "已取消"; return; }
  local tmp; tmp=$(mktemp)
  grep -v "^${uuid}|" "$LOCAL_DB" > "$tmp" || true
  cat "$tmp" > "$LOCAL_DB"; rm -f "$tmp"
  regen_config
  sb_restart
  log_info "本机节点 '$name' 已删除"
}

delete_relay_target() {
  list_relay_targets
  [[ ! -s "$RELAY_DB" ]] && return
  read -rp "输入要删除的中转目标序号: " n
  n="${n// /}"
  [[ ! "$n" =~ ^[0-9]+$ ]] && { log_err "序号无效"; return; }
  local line; line=$(awk -F'|' '!/^#/ && NF>=8' "$RELAY_DB" | awk -v n="$n" 'NR==n')
  [[ -z "$line" ]] && { log_err "序号不存在"; return; }
  local label; label=$(echo "$line" | cut -d'|' -f1)
  read -rp "确认删除中转目标 '$label'? [y/N]: " c
  [[ "${c:-N}" != "y" ]] && { log_info "已取消"; return; }
  local tmp; tmp=$(mktemp)
  grep -v "^${label}|" "$RELAY_DB" > "$tmp" || true
  cat "$tmp" > "$RELAY_DB"; rm -f "$tmp"
  regen_config
  sb_restart
  log_info "中转目标 '$label' 已删除"
}

# ── 主菜单 ────────────────────────────────────────────────────
main_menu() {
  while true; do
    echo ""
    echo -e "${MAGENTA}===== sing-box VPS 管理器 ${SCRIPT_VERSION} =====${NC}"
    echo -e "${CYAN}1.${NC} 初始化 / 安装 sing-box"
    echo -e "${CYAN}2.${NC} 添加本机 Reality 节点（RFC 落地）"
    echo -e "${CYAN}3.${NC} 添加中转目标（IIJ / 其他 VPS）"
    echo -e "${CYAN}4.${NC} 列出本机节点 / 中转目标"
    echo -e "${CYAN}5.${NC} 删除本机节点 / 中转目标"
    echo -e "${CYAN}6.${NC} 重新生成配置并重启 sing-box"
    echo -e "${CYAN}7.${NC} 查看 sing-box 状态"
    echo -e "${CYAN}8.${NC} 导出所有 VLESS 连接"
    echo -e "${CYAN}0.${NC} 退出"
    read -rp "请选择: " choice
    case "$choice" in
      1)
        log_title "初始化 / 安装 sing-box"
        need_root
        detect_os
        install_deps
        install_singbox
        ensure_dirs
        create_service
        regen_config
        sb_restart
        ;;
      2)
        need_root
        ensure_dirs
        add_local_node
        ;;
      3)
        need_root
        ensure_dirs
        add_relay_target
        ;;
      4)
        list_local_nodes
        list_relay_targets
        ;;
      5)
        echo "1) 删除本机节点"
        echo "2) 删除中转目标"
        read -rp "选择: " d
        case "$d" in
          1) need_root; delete_local_node ;;
          2) need_root; delete_relay_target ;;
          *) log_warn "无效选择" ;;
        esac
        ;;
      6)
        need_root
        regen_config
        sb_restart
        ;;
      7)
        sb_status
        ;;
      8)
        need_root
        export_all_vless
        ;;
      0)
        exit 0 ;;
      *)
        log_warn "无效选择" ;;
    esac
  done
}

need_root
main_menu
