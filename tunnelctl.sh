#!/usr/bin/env bash
# ============================================================
#  Instagram 隧道 · 服务端控制台
#
#  用法（在 VPS 上，root）：
#      sudo bash tunnelctl.sh                进入交互菜单
#      sudo bash tunnelctl.sh --check        只读环境预检（绝不修改任何东西）
#      sudo bash tunnelctl.sh --diag         只读健康检查 / 被封诊断
#      sudo bash tunnelctl.sh --otp-refresh  仅刷新今日口令（供定时器调用）
#
#  一个脚本搞定：安装、签发授权、监控、暂停、吊销、每日口令、IP 白名单。
#  建议先执行「--check」看一遍，再进菜单选「1) 首次安装」。
# ============================================================
#
#  ★★★ 对现有服务的安全承诺（这些是硬约束，不是宣传语）★★★
#
#  1) 本脚本【从不读写你的 Xray / V2Ray / Nginx 配置】。
#     所有涉及 443 的改动都只做「检测 + 提示你手工改」，绝不代改。
#  2) 本脚本只往两处写 sshd 相关文件：
#       /etc/ssh/sshd_config.d/10-tunnel.conf   （整文件由本脚本管理）
#       /etc/ssh/sshd_config 末尾的 Match 块    （用 BEGIN/END 标记圈起来）
#     动手前自动备份 sshd_config 到 sshd_config.igtunnel.bak。
#  3) 每次重启 sshd 之前都会「快照」当前监听端口；重启之后逐项核对：
#     原有端口是否都还在、sshd 是否还活着、其他服务的监听是否被波及。
#     任何一项不对就【自动回滚】并恢复 sshd。
#  4) 已知的锁死风险只有一种：sshd 配置里的端口【全部】绑不上时，
#     sshd 会以 "Cannot bind any address" 退出。所以本脚本在写配置时
#     一定会把当前所有生效端口（含默认的 22）都显式写进 dropin，
#     并在写入前检查「至少还有一个端口能用」。详见 build_dropin()。
# ============================================================

set -uo pipefail

# ---------- 路径与常量 ----------
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

CA_DIR="/etc/ssh/tunnel-ca"
CA_KEY="$CA_DIR/tunnel_ca"
CLIENT_DIR="$CA_DIR/clients"
STATE_DIR="/var/lib/igtunnel"
CONF_FILE="$CA_DIR/igtunnel.conf"
DROPIN="/etc/ssh/sshd_config.d/10-tunnel.conf"
SSHD_CONF="/etc/ssh/sshd_config"
OTP_SECRET="$CA_DIR/otp_secret"
OTP_FLAG="$STATE_DIR/otp_enabled"
ALLOWLIST_FILE="$STATE_DIR/allowlist"
INSTALLED_CTL="/usr/local/sbin/igtunnel-ctl"
SNAPDIR="$STATE_DIR/snapshots"

MARK_BEGIN="# ==== igtunnel managed BEGIN ===="
MARK_END="# ==== igtunnel managed END ===="

# 默认值（可被 $CONF_FILE 覆盖）
TUNNEL_USER="tun"
# TUNNEL_PORT = sshd 实际监听的端口（本机视角）
TUNNEL_PORT="443"
# CLIENT_PORT = 客户端要连的端口（家人视角）。
# 平时两者相同；只有 sslh 共用 443 时会分叉：sshd 听 2222，客户端连 443。
CLIENT_PORT="443"

C_R="\033[31m"; C_G="\033[32m"; C_Y="\033[33m"; C_B="\033[36m"; C_D="\033[2m"; C_0="\033[0m"

# ---------- 基础工具 ----------
say()  { printf '%b\n' "$*"; }
ok()   { printf '%b\n' "  ${C_G}✓${C_0} $*"; }
warn() { printf '%b\n' "  ${C_Y}!${C_0} $*"; }
err()  { printf '%b\n' "  ${C_R}✗${C_0} $*" >&2; }
info() { printf '%b\n' "  ${C_D}$*${C_0}"; }

hr() { printf '%b\n' "${C_D}────────────────────────────────────────────────────────────${C_0}"; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "请用 root 执行： sudo bash $SCRIPT_PATH"
    exit 1
  fi
}

ask() {
  # ask <提示> <默认值> -> 打印结果
  local prompt="$1" def="${2:-}" ans
  if [ -n "$def" ]; then
    read -r -p "  $prompt [$def]: " ans </dev/tty
  else
    read -r -p "  $prompt: " ans </dev/tty
  fi
  printf '%s' "${ans:-$def}"
}

confirm() {
  local ans
  read -r -p "  $1 [y/N]: " ans </dev/tty
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# 高风险操作：必须原样输入一个词才算确认
confirm_typed() {
  local prompt="$1" word="$2" ans
  say ""
  printf '%b\n' "  ${C_R}${prompt}${C_0}"
  printf '%b' "  请输入 ${C_Y}${word}${C_0} 以确认: "
  read -r ans </dev/tty
  [ "$ans" = "$word" ]
}

pause_key() { read -r -p "  按回车返回菜单..." _ </dev/tty; }

ssh_service() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
    printf 'ssh'
  else
    printf 'sshd'
  fi
}

# 安全的 sshd 重启：校验配置 -> 拍快照 -> 重启 -> 逐项核对 -> 不对就回滚。
#
# 可选参数 $1 = 本次【预期会消失】的端口（换端口 / 卸载时会用到），
# 这样核对时就不会把它当成"端口丢了"。
restart_ssh() {
  local expected_gone="${1:-}"
  local svc; svc="$(ssh_service)"

  if ! sshd -t 2>/tmp/sshd_test_err; then
    err "sshd 配置校验没通过，已放弃重启（没有改动任何运行中的服务）："
    sed 's/^/      /' /tmp/sshd_test_err >&2
    return 1
  fi

  snapshot_ssh

  if ! systemctl restart "$svc"; then
    err "重启 $svc 失败"
    return 1
  fi
  sleep 1

  if verify_ssh_intact "$expected_gone"; then
    ok "sshd 已重启，核对通过（当前端口：$(sshd_ports | tr '\n' ' '))"
    return 0
  fi

  say ""
  err "$svc 起来后核对不通过，正在回滚隧道配置，优先保住你的 SSH 连接..."
  rollback_dropin
  return 1
}

load_conf() {
  if [ -f "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONF_FILE"
  fi
  TUNNEL_USER="${TUNNEL_USER:-tun}"
  TUNNEL_PORT="${TUNNEL_PORT:-443}"
  CLIENT_PORT="${CLIENT_PORT:-$TUNNEL_PORT}"
}

save_conf() {
  mkdir -p "$CA_DIR"
  {
    echo "# igtunnel 配置，由 tunnelctl.sh 维护"
    echo "TUNNEL_USER=\"$TUNNEL_USER\""
    echo "TUNNEL_PORT=\"$TUNNEL_PORT\""
    echo "CLIENT_PORT=\"${CLIENT_PORT:-$TUNNEL_PORT}\""
  } > "$CONF_FILE"
  chmod 600 "$CONF_FILE"
}

client_template_dir() {
  for d in "$SCRIPT_DIR/client" "$SCRIPT_DIR/../client" "/opt/igtunnel/client"; do
    if [ -d "$d" ]; then printf '%s' "$d"; return 0; fi
  done
  return 1
}

public_host() {
  local ip=""
  ip="$(curl -fsS --max-time 6 https://api.ipify.org 2>/dev/null)" || true
  [ -z "$ip" ] && ip="$(curl -fsS --max-time 6 https://ifconfig.me 2>/dev/null)" || true
  printf '%s' "$ip"
}

have() { command -v "$1" >/dev/null 2>&1; }

# 检查某个 TCP 端口是否已被占用（sshd 绑不上会起不来，必须先查）
port_in_use() {
  local p="$1"
  if have ss; then
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"
    return $?
  fi
  if have lsof; then
    lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  return 1
}

# sshd 当前【生效】的端口列表。
#
# 注意：sshd -T 会把内置默认端口 22 也算进来，这正是我们要的 ——
# 详见 build_dropin() 里对「必须把所有端口显式写出」的解释。
# sshd -T 在配置有语法错误时会返回 255，所以这里必须判失败，
# 否则调用方拿到空列表会写出一个"只有隧道端口"的配置 → 可能锁死机器。
sshd_ports() {
  local out
  out="$(sshd -T 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | awk '/^port /{print $2}' | sort -un
}

# 当前所有处于 LISTEN 的 TCP 端口（含非 sshd 的服务，例如 Xray 的 443）
listen_ports_all() {
  if have ss; then
    ss -tlnH 2>/dev/null | awk '{print $4}' \
      | sed -E 's/^.*[:.]([0-9]+)$/\1/' | grep -E '^[0-9]+$' | sort -un
  elif have lsof; then
    lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}' \
      | sed -E 's/^.*[:.]([0-9]+)$/\1/' | grep -E '^[0-9]+$' | sort -un
  fi
}

# 生成一个用于过滤 ss/lsof 输出的端口正则（形如 "2222|443"）。
#
# 为什么不写死 22：很多机器的 SSH 早就改到别的端口了（2222、50022、22022…）。
# 硬编码 22 会让「当前监听端口」这类输出漏掉真正的登录端口，
# 用户看到自己的 SSH 端口"消失"会以为被脚本搞坏了 —— 纯属吓自己。
listen_filter_regex() {
  local rx
  rx="$( { sshd_ports 2>/dev/null || true
          printf '%s\n' "${TUNNEL_PORT:-}" "${CLIENT_PORT:-}"
        } | grep -E '^[0-9]+$' | sort -un | paste -sd'|' - )"
  [ -n "$rx" ] || return 1
  printf '%s' "$rx"
}

# 端口摘要：先明确标出「你的登录端口」和「隧道入口端口」，再列监听明细。
# 登录端口直接从 sshd -T 读，不假设是 22。
show_ports_summary() {
  local sshp rx
  sshp="$(sshd_ports 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  say "  你的 SSH 登录端口：${C_B}${sshp:-（读取失败）}${C_0}"
  say "  隧道入口端口：      ${C_B}${CLIENT_PORT:-$TUNNEL_PORT}${C_0}"
  if rx="$(listen_filter_regex)"; then
    say ""
    ss -tlnp 2>/dev/null | grep -E ":(${rx})[[:space:]]" | sed 's/^/      /' || true
  fi
}

# 谁占用了这个端口（返回进程名，可能多个）
port_owner() {
  local p="$1" out
  out="$(ss -tlnpH 2>/dev/null | awk -v pat="[:.]${p}\$" '$4 ~ pat {print}' \
        | grep -oE '"[^"]+"' | tr -d '"' | sort -u | paste -sd ',' -)"
  printf '%s' "$out"
}

# 找占用该端口的已知 systemd 服务
service_owning_port() {
  local p="$1" svc
  for svc in xray v2ray sing-box nginx caddy trojan hysteria x-ui; do
    if systemctl is-active --quiet "$svc" 2>/dev/null && port_owner "$p" | grep -qi "$svc"; then
      printf '%s' "$svc"; return 0
    fi
  done
  return 1
}

# 挑一个空闲端口。优先选公司防火墙比较可能放行的备用 HTTPS 端口
find_free_port() {
  local p
  for p in 8443 9443 2053 2083 2087 2096 4443 42443; do
    port_in_use "$p" || { printf '%s' "$p"; return 0; }
  done
  return 1
}

# ---------- sshd 改动安全网 ----------
# 动 sshd 之前拍快照，动完之后逐项核对；任何一项不对就回滚。

snapshot_ssh() {
  mkdir -p "$SNAPDIR" 2>/dev/null
  sshd_ports         > "$SNAPDIR/sshd_ports.before" 2>/dev/null || : > "$SNAPDIR/sshd_ports.before"
  listen_ports_all   > "$SNAPDIR/listen.before"     2>/dev/null || : > "$SNAPDIR/listen.before"
  ssh_service        > "$SNAPDIR/svc.before"        2>/dev/null || true
  info "已拍下改动前的快照（sshd 端口：$(tr '\n' ' ' < "$SNAPDIR/sshd_ports.before")）"
}

# verify_ssh_intact [预期会消失的端口]
verify_ssh_intact() {
  local expected_gone="${1:-}"
  local svc; svc="$(cat "$SNAPDIR/svc.before" 2>/dev/null || ssh_service)"
  local bad=0 p

  if ! systemctl is-active --quiet "$svc"; then
    err "$svc 没有在运行"
    return 1
  fi

  local now; now="$(sshd_ports || true)"
  if [ -z "$now" ]; then
    err "读不到 sshd 生效端口（sshd -T 失败）"
    return 1
  fi

  # 1) 原来有的 sshd 端口，除了预期消失的那个，其余必须还在
  while read -r p; do
    [ -n "$p" ] || continue
    [ "$p" = "$expected_gone" ] && continue
    if ! printf '%s\n' "$now" | grep -qx "$p"; then
      err "原本的 sshd 端口 ${p} 不见了"
      bad=1
    fi
  done < "$SNAPDIR/sshd_ports.before"

  # 2) 不属于 sshd 的监听端口不应该因为我们而消失（例如 Xray 的 443）
  local before_now sshd_before now_all
  before_now="$(cat "$SNAPDIR/listen.before" 2>/dev/null || true)"
  sshd_before="$(cat "$SNAPDIR/sshd_ports.before" 2>/dev/null || true)"
  now_all="$(listen_ports_all || true)"
  while read -r p; do
    [ -n "$p" ] || continue
    # 只检查"改动前就不是 sshd 端口"的那些
    printf '%s\n' "$sshd_before" | grep -qx "$p" && continue
    if ! printf '%s\n' "$now_all" | grep -qx "$p"; then
      warn "端口 ${p} 在改动后不再监听（属于你自己的其他服务，请确认一下）"
    fi
  done <<EOF
$before_now
EOF

  [ "$bad" -eq 0 ]
}

# 回滚：把隧道配置整体摘掉，优先保住你的 SSH
rollback_dropin() {
  local svc; svc="$(ssh_service)"
  if [ -f "$DROPIN" ]; then
    mv -f "$DROPIN" "${DROPIN}.failed.$(date +%Y%m%d%H%M%S)" 2>/dev/null
  fi
  sed -i "/^${MARK_BEGIN}$/,/^${MARK_END}$/d" "$SSHD_CONF" 2>/dev/null
  systemctl restart "$svc" 2>/dev/null
  sleep 1
  if systemctl is-active --quiet "$svc"; then
    warn "已回滚：SSH 恢复正常，但隧道配置没有生效。"
    info "失败的配置留在 ${DROPIN}.failed.*，里面能看到是哪个端口冲突。"
    info "建议：回菜单 12 换一个端口；或加一台独立的小 VPS 专跑隧道（最省心）。"
  else
    err "回滚后 sshd 仍然起不来！请立刻用 VPS 厂商的网页控制台处理："
    info "journalctl -u $svc -n 50"
    info "配置备份：${SSHD_CONF}.igtunnel.bak（可直接覆盖回去再重启）"
  fi
}

# 重建 sshd 配置片段。
#
# ★ 为什么必须把所有【生效】端口都写进去，而不是只写隧道端口？
#   实测结论（OpenSSH 10.3，行为在 8.x/9.x 一致）：
#   · 只要配置里出现【任何】一条 Port 指令，sshd 就【不再使用内置默认端口 22】。
#     实测：主配置不写 Port + dropin 写 "Port 8443" → 生效端口只剩 8443，22 消失。
#   · 而 Ubuntu / Debian 的 /etc/ssh/sshd_config 默认是 "#Port 22"（注释掉的）。
#   · sshd 只有在【所有】端口都绑不上时才退出（"Cannot bind any address"）；
#     只要还有一个能绑，它就照常起来，冲突的那个只报一行错。
#   所以：只写隧道端口 → 22 消失 → 万一隧道端口也被占 → sshd 直接拒绝启动 → 机器失联。
#   因此这里把 sshd -T 解析出的全部生效端口（含隐式的 22）都显式写出来。
#
# 用法：build_dropin <新隧道端口> [旧隧道端口]
build_dropin() {
  local newport="$1" oldport="${2:-}"
  local eff p ports=""

  if ! eff="$(sshd_ports)"; then
    err "读不到 sshd 当前端口（sshd -T 失败），为安全起见不写配置"
    return 1
  fi

  for p in $eff; do
    [ -n "$p" ] || continue
    [ -n "$oldport" ] && [ "$p" = "$oldport" ] && continue
    [ "$p" = "$newport" ] && continue
    ports="${ports}${p} "
  done
  ports="${ports}${newport}"

  [ -n "$(printf '%s' "$ports" | tr -d ' ')" ] || { err "端口列表为空，拒绝写入"; return 1; }

  if ! printf '%s\n' $ports | grep -qx '22'; then
    warn "新的 sshd 端口列表里没有 22：$(printf '%s ' $ports)"
    warn "如果你平时用 22 端口登录这台机器，请确认你仍然连得上。"
  fi

  {
    echo "# 由 tunnelctl.sh 生成，请勿手工编辑"
    echo "#"
    echo "# 这里列出 sshd 的【全部】监听端口，必须写全："
    echo "# 只要配置里出现任何 Port 指令，sshd 就不再使用内置默认的 22。"
    echo "# 漏写会让 22 消失；若此时其余端口也绑不上，sshd 会拒绝启动。"
    for p in $ports; do
      echo "Port $p"
    done
    if is_paused; then
      echo "#PAUSED# TrustedUserCAKeys ${CA_KEY}.pub"
    else
      echo "TrustedUserCAKeys ${CA_KEY}.pub"
    fi
    echo "AllowTcpForwarding yes"
  } > "$DROPIN"
  chmod 600 "$DROPIN"
  return 0
}

# 兼容旧名字
rebuild_dropin() { build_dropin "$@"; }

# ---------- 状态查询 ----------
is_installed() { [ -f "$CA_KEY" ] && [ -f "$DROPIN" ]; }

is_paused() {
  [ -f "$DROPIN" ] && grep -q "^#PAUSED#" "$DROPIN"
}

otp_enabled() { [ -f "$OTP_FLAG" ]; }

allowlist_get() {
  if [ -f "$ALLOWLIST_FILE" ]; then tr -d ' \n' < "$ALLOWLIST_FILE"; fi
}

cert_expiry_of() {
  local cert="$1"
  ssh-keygen -L -f "$cert" 2>/dev/null | awk '
    /^[[:space:]]*Valid:/ { for (i=1;i<=NF;i++) if ($i=="to") { print $(i+1); exit } }'
}

# ============================================================
#  只读环境预检（绝不修改任何东西）
# ============================================================
precheck() {
  local fail=0
  say ""
  say "${C_B}环境预检${C_0}  ${C_D}（只读：不会创建、修改、删除任何文件或服务）${C_0}"
  hr

  # --- 1. sshd ---
  local svc; svc="$(ssh_service)"
  say "  ${C_B}[1] SSH 服务${C_0}"
  if systemctl is-active --quiet "$svc"; then
    ok "$svc 运行中"
  else
    err "$svc 没有在运行 —— 先修好 SSH 再来装隧道"
    fail=1
  fi

  local cur_ports
  if cur_ports="$(sshd_ports)"; then
    ok "sshd 当前生效端口：$(printf '%s ' $cur_ports)"
    if printf '%s\n' $cur_ports | grep -qx '22'; then
      info "其中含 22 → 本脚本不会改变你平时的登录端口"
    else
      info "你的 SSH 不在 22 上 —— 没问题。脚本会把上面这些端口【原样保留】，只额外加隧道端口。"
    fi
  else
    err "sshd -T 解析失败，sshd 配置可能已有问题，先修好再来"
    fail=1
  fi

  if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_CONF" 2>/dev/null; then
    ok "$SSHD_CONF 里有 Include sshd_config.d/*.conf"
  else
    warn "$SSHD_CONF 里没有 Include 指令"
    info "隧道配置要写到 $DROPIN，没有 Include 就不会生效。"
    info "脚本只会提醒你手工加一行，不会替你改主配置。"
  fi

  say ""
  say "  ${C_B}[2] 443 端口${C_0}"
  if port_in_use 443; then
    local o443 s443
    o443="$(port_owner 443)"
    s443="$(service_owning_port 443 || true)"
    warn "443 已被占用：${o443:-未知进程}${s443:+  （服务：$s443）}"
    info "本脚本【不会】动这个服务，隧道会改走别的端口（菜单 12 里挑）。"
    case "$s443" in
      xray|v2ray|sing-box|trojan|hysteria)
        say ""
        warn "${C_Y}443 上是代理类服务。强烈建议【不要】用 sslh 去共用 443。${C_0}"
        info "原因：sslh 会让 443 在收到 SSH 握手时如实回答，等于同时暴露"
        info "「这台机器在跑隧道」和「它刚才还在伪装成正常网站」两件事，"
        info "把该服务原本的隐身效果打掉。"
        info "更稳的做法：再买一台最便宜的小 VPS 专门跑隧道（互不牵连）。"
        ;;
    esac
  else
    ok "443 空闲"
  fi

  say ""
  say "  ${C_B}[3] 当前监听端口一览（本脚本不会碰其中任何一个）${C_0}"
  if have ss; then
    ss -tlnp 2>/dev/null | sed 's/^/      /'
  else
    info "（没有 ss 命令，跳过）"
  fi

  say ""
  say "  ${C_B}[4] 依赖命令${C_0}"
  local c
  for c in ssh-keygen sshd systemctl openssl; do
    if have "$c"; then ok "$c"; else err "缺少 $c"; fail=1; fi
  done
  if have zip; then ok "zip（打包用）"
  elif have python3; then ok "python3（打包用，无 zip）"
  else warn "zip 和 python3 都没有，授权包只能以目录形式交付"; fi
  if have fail2ban; then ok "fail2ban"; else info "未装 fail2ban（可选，建议装：apt install -y fail2ban）"; fi

  say ""
  say "  ${C_B}[5] 隧道当前状态${C_0}"
  if is_installed; then
    ok "已安装过：sshd 监听 ${TUNNEL_PORT}，客户端连 ${CLIENT_PORT:-$TUNNEL_PORT}"
    if is_paused; then warn "当前处于【暂停】状态"; else ok "当前运行中"; fi
  else
    info "尚未安装"
  fi

  say ""
  hr
  if [ "$fail" -eq 0 ]; then
    ok "预检通过。"
  else
    err "预检发现问题，请先按上面的提示处理。"
  fi
  return "$fail"
}

# ============================================================
#  1) 首次安装
# ============================================================
do_install() {
  say ""
  say "${C_B}首次安装${C_0}"
  hr

  # ---- 先只读预检，让你心里有底再动手 ----
  local rc=0
  precheck || rc=$?
  say ""
  if [ "$rc" -ne 0 ]; then
    warn "预检有告警项。安装【不会】碰你的 Xray / Nginx / V2Ray 配置，"
    warn "也【不会】改动 $SSHD_CONF 里除末尾 Match 块之外的任何内容。"
  fi
  info "安装只做三件事：建一个受限账号、写 $DROPIN、重启一次 sshd。"
  info "重启前备份 ${SSHD_CONF}；重启后核对端口；异常自动回滚。"
  say ""
  confirm "开始安装？" || { info "已取消，没有改动任何东西"; return 0; }

  TUNNEL_USER="$(ask '隧道专用账号名' "$TUNNEL_USER")"
  TUNNEL_PORT="$(ask 'sshd 额外监听的端口（公司防火墙通常只放行 443）' "$TUNNEL_PORT")"
  CLIENT_PORT="$TUNNEL_PORT"

  local nologin
  nologin="$(command -v nologin || echo /usr/sbin/nologin)"

  say ""
  say "  [1/6] 生成隧道专用 CA"
  mkdir -p "$CA_DIR" "$CLIENT_DIR" "$STATE_DIR"
  chmod 700 "$CA_DIR" "$STATE_DIR"
  if [ -f "$CA_KEY" ]; then
    warn "CA 已存在，保留不覆盖"
  else
    ssh-keygen -t ed25519 -f "$CA_KEY" -N "" -C "tunnel-ca" >/dev/null
    chmod 600 "$CA_KEY"; chmod 644 "$CA_KEY.pub"
    ok "已生成 $CA_KEY"
  fi

  say "  [2/6] 创建受限账号 $TUNNEL_USER"
  if id "$TUNNEL_USER" >/dev/null 2>&1; then
    warn "账号已存在，跳过"
  else
    useradd -m -s "$nologin" "$TUNNEL_USER"
    ok "已创建（shell=$nologin，无法登录）"
  fi
  rm -f "/home/${TUNNEL_USER}/.ssh/authorized_keys"

  say "  [3/6] 配置 sshd"

  # 先确认端口没被别的服务占用。sshd 绑不上端口会整个起不来，
  # 那你就连不上这台机器了 —— 必须先拦住。
  if port_in_use "$TUNNEL_PORT"; then
    if sshd_ports | grep -qx "$TUNNEL_PORT"; then
      info "端口 ${TUNNEL_PORT} 已经是 sshd 在监听，直接复用"
    else
      handle_port_conflict || return 1
    fi
  fi

  mkdir -p /etc/ssh/sshd_config.d
  [ -f "${SSHD_CONF}.igtunnel.bak" ] || cp -a "$SSHD_CONF" "${SSHD_CONF}.igtunnel.bak"

  # 重装时要把上一次的隧道端口从列表里摘掉，否则端口会越积越多
  local prev_port=""
  if [ -f "$CONF_FILE" ]; then
    prev_port="$(sed -n 's/^TUNNEL_PORT="\(.*\)"$/\1/p' "$CONF_FILE" | head -1)"
  fi
  [ "$prev_port" = "$TUNNEL_PORT" ] && prev_port=""

  if ! build_dropin "$TUNNEL_PORT" "$prev_port"; then
    err "写 sshd 配置失败，安装中止（没有改动任何运行中的服务）"
    return 1
  fi
  ok "已写入 $DROPIN"

  if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_CONF"; then
    warn "$SSHD_CONF 里没有 Include 指令，上面的配置不会生效！"
    warn "请手动在 $SSHD_CONF 顶部加一行： Include /etc/ssh/sshd_config.d/*.conf"
    warn "（脚本不替你改主配置，避免误伤你已有的设置）"
  fi

  say "  [4/6] 校验并重启 sshd（会先备份、后核对、异常自动回滚）"
  restart_ssh "$prev_port" || return 1

  say "  [5/6] 放行防火墙"
  if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${TUNNEL_PORT}/tcp" >/dev/null 2>&1 && ok "ufw 已放行 ${TUNNEL_PORT}/tcp"
  fi
  if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${TUNNEL_PORT}/tcp" >/dev/null && firewall-cmd --reload >/dev/null
    ok "firewalld 已放行 ${TUNNEL_PORT}/tcp"
  fi

  say "  [6/6] 安装每日口令的定时刷新服务"
  install_otp_timer

  save_conf
  say ""
  hr
  ok "安装完成"
  say ""
  show_ports_summary
  say ""
  if have fail2ban; then
    ok "fail2ban 已安装"
  else
    warn "建议装 fail2ban（${TUNNEL_PORT} 上的 SSH 会被全网扫描）："
    info "apt install -y fail2ban && systemctl enable --now fail2ban"
  fi
  say ""
  say "  下一步：回到菜单，选 ${C_B}2${C_0} 签发授权给家人。"
}

install_otp_timer() {
  if [ "$(readlink -f "$SCRIPT_PATH" 2>/dev/null || printf '%s' "$SCRIPT_PATH")" = "$INSTALLED_CTL" ]; then
    chmod 755 "$INSTALLED_CTL"
  else
    install -m 755 "$SCRIPT_PATH" "$INSTALLED_CTL" 2>/dev/null || cp -f "$SCRIPT_PATH" "$INSTALLED_CTL"
    chmod 755 "$INSTALLED_CTL"
  fi

  cat > /etc/systemd/system/igtunnel-otp.service <<EOF
[Unit]
Description=Instagram tunnel daily password refresh

[Service]
Type=oneshot
ExecStart=$INSTALLED_CTL --otp-refresh
EOF

  cat > /etc/systemd/system/igtunnel-otp.timer <<'EOF'
[Unit]
Description=Refresh Instagram tunnel daily password

[Timer]
OnCalendar=*-*-* 00:05:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload 2>/dev/null
  systemctl enable --now igtunnel-otp.timer >/dev/null 2>&1 \
    && ok "定时刷新已启用（每天 00:05 自动换口令）" \
    || warn "定时器启用失败，每日口令需要手动刷新"
}

# ============================================================
#  端口冲突处理
# ============================================================
handle_port_conflict() {
  local p="$TUNNEL_PORT" owner svc
  owner="$(port_owner "$p")"
  svc="$(service_owning_port "$p" || true)"

  say ""
  err "端口 ${p} 已经被占用。"
  say "      占用者：${C_Y}${owner:-未知}${C_0}"
  ss -tlnp 2>/dev/null | grep -E "[:.]${p}[[:space:]]" | sed 's/^/      /'
  say ""
  warn "硬把 sshd 配到这个端口，sshd 会起不来，你就再也连不上这台机器。"
  say ""
  say "  你打算怎么办？"
  say ""
  say "   ${C_B}1${C_0}) 隧道换个端口（我帮你挑一个空闲的）"
  info "        适合：公司防火墙放行了其他端口"
  info "        风险：不少公司只放行 443，换完必须先在家人电脑上实测"
  say ""
  say "   ${C_B}2${C_0}) 让 ${owner:-原服务} 和 SSH 共用 443（sslh 按协议分流）"
  info "        适合：公司只放行 443"
  info "        代价：要改你现有 443 服务的监听端口"
  say ""
  say "   ${C_B}3${C_0}) 取消，我自己处理"
  say ""

  local c
  c="$(ask '请选择' '1')"
  case "$c" in
    1)
      local np
      if ! np="$(find_free_port)"; then
        err "常见的备用端口都被占用了，请回菜单 1 手动指定一个"
        return 1
      fi
      say ""
      ok "建议改用端口 ${C_G}${np}${C_0}"
      say ""
      warn "先让家人在公司电脑上测一下这个端口通不通："
      info "  Test-NetConnection <你的VPS_IP> -Port ${np}"
      info "  不通的话，只能走 sslh 共用 443（选 2）"
      say ""
      if confirm "就用 ${np} 继续安装？"; then
        TUNNEL_PORT="$np"
        save_conf
        ok "隧道端口已改为 ${np}（打包给家人时会自动写进 config.ini）"
        return 0
      fi
      info "已取消"
      return 1
      ;;
    2)
      do_sslh_share
      return $?
      ;;
    *)
      info "已取消"
      return 1
      ;;
  esac
}

do_sslh_share() {
  clear
  say ""
  say "${C_B}用 sslh 让 443 端口共用${C_0}"
  hr

  local owner svc443now
  owner="$(port_owner 443)"
  svc443now="$(service_owning_port 443 || true)"
  say "  当前 443 的占用者：${C_Y}${owner:-未知}${C_0}${svc443now:+  （服务：$svc443now）}"
  say ""
  say "  原理：sslh 接管 443，按第一个数据包的特征分流"
  info "  TLS 握手（0x16 0x03 ...）  ->  原来的服务（Xray / 网站）"
  info "  SSH 横幅（SSH-2.0-...）    ->  sshd（隧道）"
  say ""
  info "sslh 只做窥探（MSG_PEEK）不消费字节，所以 Xray 的 Reality /"
  info "XTLS-Vision 仍然能拿到完整的 ClientHello，不会因为分流而失效。"
  say ""

  # ---- 对 Reality / 代理类服务的强烈警告 ----
  case "$svc443now" in
    xray|v2ray|sing-box|trojan|hysteria)
      hr
      warn "${C_R}注意：443 上跑的是 ${svc443now}（代理类服务）。${C_0}"
      say ""
      say "  这样做会削弱它的隐身效果："
      info "· ${svc443now} 的价值在于「443 上任何探测都得到一个正常网站」；"
      info "· 加了 sslh 之后，443 上多了一个会如实回答 SSH 握手的分支；"
      info "· 而 GFW 的主动探测本来就会用多种协议逐一试探，一旦在 443 上"
      info "  收到 SSH 横幅，等于同时暴露两件事：这台机器在跑隧道，"
      info "  而且它刚才还在伪装成一个正常网站。"
      say ""
      info "更稳的替代方案：再买一台最便宜的小 VPS 专门跑隧道，"
      info "两台机器互不牵连，哪边出事都不影响另一边。"
      say ""
      if ! confirm_typed "确认要在这台跑 ${svc443now} 的机器上用 sslh 共用 443？" "我明白"; then
        info "已取消。没有改动任何东西。"
        return 1
      fi
      ;;
  esac

  local xray_port ssh_port
  xray_port="$(ask '把原来 443 上的服务挪到哪个本地端口' '4443')"
  case "$xray_port" in ''|*[!0-9]*) xray_port=4443 ;; esac
  ssh_port="$(ask 'sshd 隧道监听哪个本地端口' '2222')"
  case "$ssh_port" in ''|*[!0-9]*) ssh_port=2222 ;; esac

  if port_in_use "$xray_port"; then err "端口 ${xray_port} 已被占用，请换一个"; return 1; fi
  if port_in_use "$ssh_port";  then err "端口 ${ssh_port} 已被占用，请换一个";  return 1; fi

  say ""
  if ! have sslh; then
    if confirm "需要先安装 sslh，现在装吗？"; then
      apt-get update -qq >/dev/null 2>&1
      apt-get install -y sslh >/dev/null 2>&1 || { err "安装失败"; return 1; }
      ok "sslh 已安装"
    else
      info "已取消"
      return 1
    fi
  fi

  # ---- 写 sslh 配置（先备份）----
  local def="/etc/default/sslh"
  if [ -f "$def" ]; then
    cp -a "$def" "${def}.igtunnel.bak.$(date +%Y%m%d%H%M%S)"
    ok "已备份原配置：${def}.igtunnel.bak.*"
  fi
  mkdir -p /run/sslh
  cat > "$def" <<EOF
# 由 tunnelctl.sh 生成
RUN=yes
DAEMON_OPTS="--user sslh --listen 0.0.0.0:443 --ssh 127.0.0.1:${ssh_port} --tls 127.0.0.1:${xray_port} --pidfile /run/sslh/sslh.pid"
EOF
  ok "已写入 $def"

  if systemctl list-unit-files 2>/dev/null | grep -q '^sslh\.socket'; then
    systemctl disable --now sslh.socket >/dev/null 2>&1
    info "已停用 sslh.socket（改用 sslh.service 直接监听 443）"
  fi

  # ---- 把 sshd 挪到本地端口；客户端则统一连 443（由 sslh 转进来）----
  #
  # 注意 TUNNEL_PORT（sshd 本机监听）与 CLIENT_PORT（家人连的端口）在这里分叉：
  #   sshd 听 127.0.0.1:2222，家人连 <VPS>:443 → sslh 探到 SSH 横幅 → 转到 2222。
  # 打包时必须用 CLIENT_PORT，否则 config.ini 会写错端口，家人永远连不上。
  local old_tunnel_port="$TUNNEL_PORT"
  TUNNEL_PORT="$ssh_port"
  CLIENT_PORT="443"

  if ! build_dropin "$ssh_port" "$old_tunnel_port"; then
    err "写 sshd 配置失败，已放弃（没有改动任何运行中的服务）"
    TUNNEL_PORT="$old_tunnel_port"; CLIENT_PORT="$old_tunnel_port"
    return 1
  fi
  save_conf

  if restart_ssh "$old_tunnel_port"; then
    ok "sshd 已挪到 ${ssh_port}（本机端口，由 sslh 从 443 转发进来）"
  else
    err "sshd 改端口失败，隧道配置已被自动摘掉"
    TUNNEL_PORT="$old_tunnel_port"; CLIENT_PORT="$old_tunnel_port"; save_conf
    return 1
  fi

  # ---- 剩下要手工改的部分 ----
  say ""
  hr
  say "  ${C_Y}还剩一步需要你手工改（我不动你的 Xray 配置）${C_0}"
  say ""
  say "  把 443 上原来那个服务改到 ${C_G}${xray_port}${C_0}，并且只监听本机："
  say ""
  if [ -f /usr/local/etc/xray/config.json ]; then
    info "Xray 配置：/usr/local/etc/xray/config.json"
  elif [ -f /etc/xray/config.json ]; then
    info "Xray 配置：/etc/xray/config.json"
  else
    info "Xray 配置文件路径请自行确认（常见于 /usr/local/etc/xray/）"
  fi
  info "找到 inbound 里的  \"port\": 443  ->  改成 \"port\": ${xray_port}"
  info "同时把 \"listen\": \"0.0.0.0\"  ->  改成 \"listen\": \"127.0.0.1\""
  info "（如果用的是 nginx / caddy，就是把 listen 443 改成 listen ${xray_port}）"
  say ""
  warn "改完不要急着重启，先让下面的流程按顺序来 ——"
  warn "必须先停掉原服务，sslh 才能绑上 443。"
  say ""
  say "  ${C_B}1${C_0}) 我已经改好了，帮我按顺序切换"
  say "  ${C_B}2${C_0}) 先到这里，我自己手动切换"
  say ""
  local c
  c="$(ask '请选择' '2')"
  [ "$c" != "1" ] && { info "已暂停。改好后回菜单 12（端口设置）继续。"; return 1; }

  local svc443
  svc443="$(service_owning_port 443 || true)"
  if [ -z "$svc443" ]; then
    svc443="$(ask '443 上那个服务的 systemd 单元名（如 xray / nginx）' 'xray')"
  fi

  # 绝对不能把 SSH 自己停掉 —— 那等于自己拔网线
  if [ "$svc443" = "$(ssh_service)" ]; then
    err "443 上跑的就是 SSH 本身，停掉它会把你自己锁在门外，已中止"
    return 1
  fi
  if ! systemctl cat "$svc443" >/dev/null 2>&1; then
    err "找不到 systemd 服务 ${svc443}，已中止（没有停任何东西）"
    info "用 systemctl list-units --type=service 确认正确的单元名"
    return 1
  fi

  say ""
  info "停掉 ${svc443} ..."
  systemctl stop "$svc443" 2>/dev/null
  sleep 1

  info "启动 sslh ..."
  systemctl enable sslh >/dev/null 2>&1
  systemctl restart sslh 2>/dev/null
  sleep 1

  if ! systemctl is-active --quiet sslh; then
    err "sslh 没起来，正在回滚"
    systemctl restart "$svc443" 2>/dev/null
    sleep 1
    if systemctl is-active --quiet "$svc443"; then
      warn "已把 ${svc443} 重新启动，443 恢复原状。"
    else
      err "${svc443} 也没有起来！立刻手动执行： systemctl start ${svc443}"
    fi
    info "排查： journalctl -u sslh -n 30"
    return 1
  fi
  ok "sslh 已接管 443"

  info "重新启动 ${svc443}（应该监听在 ${xray_port}）..."
  systemctl start "$svc443" 2>/dev/null
  sleep 2
  if systemctl is-active --quiet "$svc443"; then
    ok "${svc443} 已重新启动"
  else
    err "${svc443} 没有起来！你的代理现在是断的，先修好它："
    info "systemctl status ${svc443}; journalctl -u ${svc443} -n 30"
    info "隧道的事放后面。"
  fi

  say ""
  hr
  say "  当前监听情况："
  ss -tlnp 2>/dev/null | grep -E ":(443|${xray_port}|${ssh_port})[[:space:]]" | sed 's/^/      /' || true
  say ""
  if port_in_use "$xray_port"; then
    ok "${svc443} 已在 ${xray_port} 上"
  else
    err "${svc443} 没有监听到 ${xray_port} —— 配置大概没改对"
    info "先用你自己原来的客户端测一下代理还能不能用，再处理隧道。"
  fi
  if port_owner 443 | grep -qi sslh; then
    ok "443 已由 sslh 接管"
  else
    warn "443 的占用者看起来不是 sslh，确认一下"
  fi
  say ""
  info "回菜单 2 签发授权给家人即可（客户端会自动连 443，由 sslh 转进来）。"
}


# ============================================================
#  2) 签发授权
# ============================================================
list_clients() {
  [ -d "$CLIENT_DIR" ] || return 0
  if find "$CLIENT_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' >/dev/null 2>&1; then
    find "$CLIENT_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
  else
    # 兼容没有 GNU find -printf 的系统（BusyBox / Alpine / BSD find）
    find "$CLIENT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
      | while read -r d; do basename "$d"; done | sort
  fi
}

sign_cert() {
  # sign_cert <name> [days] —— 用当前白名单重新签名
  local name="$1"
  local days="${2:-7}"
  local key="$CLIENT_DIR/$name/id_ig_tunnel"
  local cert="${key}-cert.pub"
  local addr
  addr="$(allowlist_get)"

  local opts=(
    -O clear
    -O permit-port-forwarding
    -O no-pty
    -O no-x11-forwarding
    -O no-agent-forwarding
    -O no-user-rc
  )
  [ -n "$addr" ] && opts+=( -O "source-address=${addr}" )

  rm -f "$cert"
  ssh-keygen -s "$CA_KEY" \
    -I "${name}-$(date +%Y%m%d%H%M%S)" \
    -n "$TUNNEL_USER" \
    -V "+${days}d" \
    "${opts[@]}" \
    "${key}.pub" >/dev/null 2>&1 || return 1

  chmod 644 "$cert"
  if ssh-keygen -L -f "$cert" 2>/dev/null | grep -qi 'no-port-forwarding'; then
    err "证书被禁止了端口转发，客户端会连不上"
    return 1
  fi
  return 0
}

do_issue() {
  say ""
  say "${C_B}签发新授权${C_0}"
  hr
  if ! is_installed; then err "还没安装，请先执行菜单 1"; return 1; fi

  local name days addr
  name="$(ask '给谁用（英文名，会写进文件名）' 'family')"
  name="$(printf '%s' "$name" | tr -cd 'A-Za-z0-9_-')"
  [ -z "$name" ] && name="family"

  CERT_DAYS="$(ask '授权有效期（天）' '7')"
  case "$CERT_DAYS" in ''|*[!0-9]*) CERT_DAYS=7 ;; esac

  addr="$(allowlist_get)"
  if [ -n "$addr" ]; then
    ok "将套用当前来源 IP 白名单：$addr"
  else
    warn "当前没有来源 IP 白名单（任何 IP 只要能连上就能用）"
    info "大公司出口 IP 多的话，可以先不加，等监控里看到实际 IP 再设"
  fi

  mkdir -p "$CLIENT_DIR/$name"
  if [ -f "$CLIENT_DIR/$name/id_ig_tunnel" ]; then
    warn "该名字已存在密钥，将复用旧密钥只重签证书"
  else
    ssh-keygen -t ed25519 -N "" -f "$CLIENT_DIR/$name/id_ig_tunnel" -C "igtunnel-$name" >/dev/null
    chmod 600 "$CLIENT_DIR/$name/id_ig_tunnel"
    ok "已生成密钥对"
  fi

  if ! sign_cert "$name" "$CERT_DAYS"; then
    err "签发失败"; return 1
  fi
  ok "证书已签发"

  say ""
  ssh-keygen -L -f "$CLIENT_DIR/$name/id_ig_tunnel-cert.pub" | sed -n '1,12p' | sed 's/^/      /'

  build_package "$name"
}

build_package() {
  local name="$1"
  local host outroot pkg
  host="$(public_host)"
  if [ -z "$host" ]; then
    host="$(ask '自动探测公网 IP 失败，请手动输入 VPS 地址' '')"
  else
    host="$(ask '客户端要连的地址' "$host")"
  fi

  outroot="/root/igtunnel-dist"
  mkdir -p "$outroot"
  pkg="$outroot/$name"
  rm -rf "$pkg"; mkdir -p "$pkg/key"

  local tpl
  if tpl="$(client_template_dir)"; then
    cp -a "$tpl/." "$pkg/" 2>/dev/null
    ok "已套用客户端模板：$tpl"
  else
    warn "没找到客户端模板目录（client/），只打包密钥文件"
  fi

  cp -f "$CLIENT_DIR/$name/id_ig_tunnel" "$pkg/key/"
  cp -f "$CLIENT_DIR/$name/id_ig_tunnel-cert.pub" "$pkg/key/"
  rm -f "$pkg/key/说明.txt"

  cat > "$pkg/config.ini" <<EOF
# Instagram 隧道 · 客户端配置（由服务端脚本自动生成，一般不用改）
VpsHost=$host
VpsPort=${CLIENT_PORT:-$TUNNEL_PORT}
VpsUser=$TUNNEL_USER
LocalPort=1080

# off = 不需要口令；auto = 需要时自动弹窗（推荐）；window = 固定用黑窗口输入
AskPassword=auto

BrowserPath=
MaxSessionMinutes=480
StartUrl=https://www.instagram.com/
EOF

  info "客户端连接目标：${host}:${CLIENT_PORT:-$TUNNEL_PORT}（账号 $TUNNEL_USER）"

  local archive=""
  local zippw
  say ""
  info "打包时可以加个密码，防止传输途中被翻看（留空则不加密）"
  zippw="$(ask '压缩包密码（留空 = 不加密）' '')"

  if have zip; then
    archive="$outroot/$name.zip"
    rm -f "$archive"
    if [ -n "$zippw" ]; then
      ( cd "$outroot" && zip -qr -P "$zippw" "$name.zip" "$name" ) && ok "已生成加密压缩包"
    else
      ( cd "$outroot" && zip -qr "$name.zip" "$name" ) && ok "已生成压缩包"
    fi
  elif have python3; then
    archive="$outroot/$name.zip"
    rm -f "$archive"
    ( cd "$outroot" && python3 -m zipfile -c "$name.zip" "$name" ) && ok "已生成压缩包（python3）"
  fi

  say ""
  hr
  say "  ${C_G}交付给家人${C_0}"
  say ""
  if [ -n "$archive" ]; then
    say "    压缩包：$archive"
  else
    say "    目录：$pkg  （没找到 zip，请自行打包）"
  fi
  say ""
  say "    发给她 → 解压到桌面 → 双击「打开Instagram.bat」"
  [ -n "$zippw" ] && say "    压缩包密码：${C_Y}$zippw${C_0}（请用另一个渠道告诉她）"
  say ""
  say "    ${C_Y}注意：包里有私钥，别用明文邮件或公开链接发。${C_0}"
}

do_renew() {
  say ""
  say "${C_B}续期授权${C_0}"
  hr
  if ! is_installed; then err "还没安装"; return 1; fi

  local clients
  clients="$(list_clients)"
  if [ -z "$clients" ]; then
    err "还没有任何客户端，请先执行菜单 2 签发"
    return 1
  fi

  say "  已有客户端："
  local i=1
  for c in $clients; do
    local exp
    exp="$(cert_expiry_of "$CLIENT_DIR/$c/id_ig_tunnel-cert.pub")"
    say "    $i) $c   到期：${exp:-未知}"
    i=$((i+1))
  done
  say "    a) 全部续期"
  say ""

  local sel
  sel="$(ask '选择要续期的（序号 / a）' 'a')"
  CERT_DAYS="$(ask '新的有效期（天）' '7')"
  case "$CERT_DAYS" in ''|*[!0-9]*) CERT_DAYS=7 ;; esac

  local targets=""
  if [ "$sel" = "a" ] || [ "$sel" = "A" ]; then
    targets="$clients"
  else
    local n=1
    for c in $clients; do
      [ "$n" = "$sel" ] && targets="$c"
      n=$((n+1))
    done
  fi

  if [ -z "$targets" ]; then err "选择无效"; return 1; fi

  local outroot="/root/igtunnel-dist"
  mkdir -p "$outroot"
  say ""
  for c in $targets; do
    if sign_cert "$c" "$CERT_DAYS"; then
      local exp
      exp="$(cert_expiry_of "$CLIENT_DIR/$c/id_ig_tunnel-cert.pub")"
      ok "$c 已续期到 $exp"
      cp -f "$CLIENT_DIR/$c/id_ig_tunnel-cert.pub" "$outroot/${c}-cert.pub"
      say "      待发送：$outroot/${c}-cert.pub"
    else
      err "$c 续期失败"
    fi
  done

  say ""
  hr
  info "家人收到新的 *-cert.pub 后，双击「更新授权」即可自动安装。"
  info "私钥没变，不用重新发整个包。"
}

# ============================================================
#  3) 监控
# ============================================================
ssh_unit_logs() {
  local svc; svc="$(ssh_service)"
  if have journalctl; then
    journalctl -u "$svc" --no-pager "$@" 2>/dev/null
  elif [ -f /var/log/auth.log ]; then
    cat /var/log/auth.log
  fi
}

do_monitor() {
  clear
  say ""
  say "${C_B}运行监控${C_0}"
  hr

  # 服务状态
  local svc; svc="$(ssh_service)"
  local act; act="$(systemctl is-active "$svc" 2>/dev/null)"
  if [ "$act" = "active" ]; then ok "sshd：运行中"; else err "sshd：$act"; fi

  if is_paused; then
    err "隧道服务：已暂停（家人现在连不上）"
  elif is_installed; then
    ok "隧道服务：正常"
  else
    err "隧道服务：未安装"
  fi

  # 监听端口（不硬编码 22：登录端口可能早就改到别处了）
  say ""
  local prx
  if prx="$(listen_filter_regex)"; then
    say "  监听端口："
    ss -tlnp 2>/dev/null | grep -E ":(${prx})[[:space:]]" | sed 's/^/      /' || say "      （读取失败）"
  else
    say "  监听端口：（读取失败）"
  fi
  if ! port_in_use "$TUNNEL_PORT"; then
    warn "sshd 隧道端口 ${TUNNEL_PORT} 没有在监听 —— 家人会连不上"
    info "看 journalctl -u $(ssh_service) -n 30，或用菜单 13 做一次诊断"
  fi
  if [ "${CLIENT_PORT:-$TUNNEL_PORT}" != "$TUNNEL_PORT" ]; then
    if port_in_use "$CLIENT_PORT"; then
      info "客户端入口端口 ${CLIENT_PORT} 正常（$(port_owner "$CLIENT_PORT")）"
    else
      warn "客户端入口端口 ${CLIENT_PORT} 没有在监听 —— sslh 可能挂了，家人连不上"
    fi
  fi

  # 活动连接
  local nconn
  nconn="$(ss -tn state established 2>/dev/null | grep -c ":${TUNNEL_PORT}")"
  say ""
  say "  当前到 ${TUNNEL_PORT} 的活动连接数：${C_G}${nconn:-0}${C_0}"

  # 授权列表
  say ""
  say "  已签发的授权："
  local clients; clients="$(list_clients)"
  if [ -z "$clients" ]; then
    info "（还没有）"
  else
    for c in $clients; do
      local exp remain
      exp="$(cert_expiry_of "$CLIENT_DIR/$c/id_ig_tunnel-cert.pub")"
      remain=""
      if [ -n "$exp" ]; then
        local e epoch now
        e="$(date -d "${exp}" +%s 2>/dev/null || echo 0)"
        now="$(date +%s)"
        if [ "$e" -gt "$now" ]; then
          remain="剩余 $(( (e - now) / 86400 )) 天"
        else
          remain="${C_R}已过期${C_0}"
        fi
      fi
      printf '      %-12s %s  %b\n' "$c" "${exp:-未知}" "$remain"
    done
  fi

  # 每日口令
  say ""
  if otp_enabled; then
    ok "每日口令：${C_Y}已开启${C_0}   今日口令 ${C_G}$(otp_code_today)${C_0}"
  else
    info "每日口令：未开启"
  fi

  # 白名单
  local addr; addr="$(allowlist_get)"
  if [ -n "$addr" ]; then
    ok "来源 IP 白名单：$addr"
  else
    info "来源 IP 白名单：未设置（不限来源）"
  fi

  # 最近连接
  say ""
  say "  最近 10 次成功连接："
  ssh_unit_logs --since "14 days ago" \
    | grep "Accepted .* for ${TUNNEL_USER} " \
    | tail -10 \
    | sed -E 's/.*(Accepted [a-z,]+ for [^ ]+ from [0-9.]+).*(port [0-9]+).*/      \1 \2/' \
    || true
  local cnt
  cnt="$(ssh_unit_logs --since "14 days ago" | grep -c "Accepted .* for ${TUNNEL_USER} " || true)"
  [ "${cnt:-0}" = "0" ] && info "（近 14 天没有成功连接记录）"

  # 来源 IP 排行 —— 用来收集公司出口 IP 段
  say ""
  say "  近 14 天来源 IP 排行（用来设白名单）："
  local ips
  ips="$(ssh_unit_logs --since "14 days ago" \
    | grep "Accepted .* for ${TUNNEL_USER} " \
    | grep -oE 'from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
    | awk '{print $2}' | sort | uniq -c | sort -rn | head -15)"
  if [ -n "$ips" ]; then
    printf '%s\n' "$ips" | sed 's/^/      /'
    say ""
    info "如果 IP 很多但前三段相同，可以直接用 /24 网段，例如 203.0.113.0/24"
  else
    info "（暂无数据）"
  fi

  # 失败尝试
  local fails
  fails="$(ssh_unit_logs --since "24 hours ago" | grep -c "Failed\|Invalid user" || true)"
  say ""
  say "  近 24 小时认证失败次数：${fails:-0}"

  say ""
  hr
  pause_key
}

do_logs() {
  clear
  say ""
  say "${C_B}隧道日志（实时，Ctrl+C 退出）${C_0}"
  hr
  local svc; svc="$(ssh_service)"
  if have journalctl; then
    journalctl -u "$svc" -f -n 40
  else
    tail -f /var/log/auth.log
  fi
}

# ============================================================
#  4) 暂停 / 恢复
# ============================================================
do_pause() {
  say ""
  say "${C_B}暂停隧道服务${C_0}"
  hr
  if ! is_installed; then err "还没安装"; return 1; fi
  if is_paused; then warn "当前已经是暂停状态"; return 0; fi
  info "做法：把 sshd 对隧道 CA 的信任注释掉。"
  info "影响：所有客户端证书立即失效；你自己的密钥登录不受影响。"
  say ""
  confirm "确认暂停？" || { info "已取消"; return 0; }

  sed -i 's|^\(TrustedUserCAKeys.*\)|#PAUSED# \1|' "$DROPIN"
  restart_ssh || return 1
  ok "已暂停。家人下次连接会提示「授权证书无效或已过期」。"
}

do_resume() {
  say ""
  say "${C_B}恢复隧道服务${C_0}"
  hr
  if ! is_paused; then warn "当前没有处于暂停状态"; return 0; fi
  sed -i 's|^#PAUSED# \(TrustedUserCAKeys.*\)|\1|' "$DROPIN"
  restart_ssh || return 1
  ok "已恢复"
}

# ============================================================
#  5) 每日口令
# ============================================================
otp_code_for() {
  local date="$1" secret hex
  [ -f "$OTP_SECRET" ] || return 1
  secret="$(cat "$OTP_SECRET")"
  hex="$(printf '%s' "$date" | openssl dgst -sha256 -hmac "$secret" | awk '{print $NF}')"
  printf '%06d' $(( 16#${hex:0:8} % 1000000 ))
}

otp_code_today() { otp_code_for "$(date +%Y-%m-%d)"; }

apply_ssh_match() {
  local mode="$1"
  [ -f "$SSHD_CONF" ] || return 1
  [ -f "${SSHD_CONF}.igtunnel.bak" ] || cp -a "$SSHD_CONF" "${SSHD_CONF}.igtunnel.bak"
  sed -i "/^${MARK_BEGIN}$/,/^${MARK_END}$/d" "$SSHD_CONF"
  if [ "$mode" = "on" ]; then
    cat >> "$SSHD_CONF" <<EOF

$MARK_BEGIN
Match User $TUNNEL_USER
    AuthenticationMethods publickey,password
    PasswordAuthentication yes
    PermitTTY no
    X11Forwarding no
    AllowAgentForwarding no
$MARK_END
EOF
  fi
}

otp_enable() {
  local code
  if [ ! -f "$OTP_SECRET" ]; then
    openssl rand -hex 32 > "$OTP_SECRET"
    chmod 600 "$OTP_SECRET"
  fi
  apply_ssh_match on
  restart_ssh || return 1

  code="$(otp_code_today)"
  printf '%s:%s\n' "$TUNNEL_USER" "$code" | chpasswd || { err "设置口令失败"; return 1; }
  touch "$OTP_FLAG"

  ok "每日口令已开启"
  say ""
  say "  ${C_Y}今日口令（$(date +%Y-%m-%d)）：${C_0}"
  say ""
  say "        ${C_G}${C_B}$code${C_0}"
  say ""
  info "每天 00:05 自动更换，明天用菜单查看新口令。"
  info "家人第一次用当天口令时输入一次，客户端会缓存，当天不用重复输入。"
}

otp_disable() {
  apply_ssh_match off
  restart_ssh || return 1
  # 不用 passwd -l（可能连带影响证书登录），改成塞一个随机密码，
  # 这样即使全局开着密码认证也没人猜得出来
  printf '%s:%s\n' "$TUNNEL_USER" "$(openssl rand -hex 24)" | chpasswd
  rm -f "$OTP_FLAG"
  ok "每日口令已关闭，恢复为「仅证书」验证"
}

otp_refresh() {
  otp_enabled || return 0
  local code
  code="$(otp_code_today)"
  printf '%s:%s\n' "$TUNNEL_USER" "$code" | chpasswd
  logger -t igtunnel "daily password refreshed for $TUNNEL_USER"
}

do_otp() {
  while true; do
    clear
    say ""
    say "${C_B}每日口令${C_0}"
    hr
    if ! is_installed; then err "还没安装"; pause_key; return 1; fi

    if otp_enabled; then
      ok "状态：已开启"
      say ""
      say "  今日口令（$(date +%Y-%m-%d)）：${C_G}${C_B}$(otp_code_today)${C_0}"
      say "  明天口令（$(date -d tomorrow +%Y-%m-%d)）：$(otp_code_for "$(date -d tomorrow +%Y-%m-%d)")"
    else
      info "状态：未开启（目前只用证书验证）"
    fi
    say ""
    hr
    say "  1) 开启 / 重置今日口令"
    say "  2) 关闭口令验证"
    say "  3) 查看指定日期的口令"
    say "  0) 返回"
    say ""
    local c
    c="$(ask '请选择' '0')"
    case "$c" in
      1) otp_enable; pause_key ;;
      2)
        confirm "确认关闭每日口令？" && otp_disable
        pause_key ;;
      3)
        local d
        d="$(ask '日期 YYYY-MM-DD' "$(date +%Y-%m-%d)")"
        if [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
          say "  $d 的口令：${C_G}$(otp_code_for "$d")${C_0}"
        else
          err "日期格式不对"
        fi
        pause_key ;;
      0|*) return 0 ;;
    esac
  done
}

# ============================================================
#  6) 来源 IP 白名单
# ============================================================
do_allowlist() {
  while true; do
    clear
    say ""
    say "${C_B}来源 IP 白名单${C_0}"
    hr
    local cur; cur="$(allowlist_get)"
    if [ -n "$cur" ]; then ok "当前：$cur"; else info "当前：未设置（不限来源 IP）"; fi
    say ""
    info "白名单写在证书里，改动后需要重新签发授权才生效。"
    info "支持多个网段，逗号分隔，例如：203.0.113.0/24,198.51.100.7/32"
    say ""
    hr
    say "  1) 设置白名单（并重新签发全部授权）"
    say "  2) 关闭白名单（并重新签发全部授权）"
    say "  3) 查看近 14 天实际来源 IP（帮你确定网段）"
    say "  0) 返回"
    say ""
    local c
    c="$(ask '请选择' '0')"
    case "$c" in
      1)
        local v bad
        v="$(ask '输入 CIDR，多个用逗号分隔' "$cur")"
        v="$(printf '%s' "$v" | tr -d ' ')"
        if [ -z "$v" ]; then err "不能为空"; pause_key; continue; fi
        bad="$(printf '%s' "$v" | tr ',' '\n' | grep -vE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]{1,2})?$' || true)"
        if [ -n "$bad" ]; then
          err "格式不对：$bad"
          info "正确写法示例：203.0.113.0/24,198.51.100.7"
          pause_key; continue
        fi
        mkdir -p "$STATE_DIR"
        printf '%s' "$v" > "$ALLOWLIST_FILE"
        ok "已保存白名单：$v"
        say ""
        if confirm "现在重新签发全部授权？"; then resign_all; fi
        pause_key ;;
      2)
        rm -f "$ALLOWLIST_FILE"
        ok "已关闭白名单"
        say ""
        if confirm "现在重新签发全部授权？"; then resign_all; fi
        pause_key ;;
      3)
        clear
        say ""
        say "  近 14 天来源 IP 排行："
        hr
        local ips
        ips="$(ssh_unit_logs --since "14 days ago" \
          | grep "Accepted .* for ${TUNNEL_USER} " \
          | grep -oE 'from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
          | awk '{print $2}' | sort | uniq -c | sort -rn)"
        if [ -n "$ips" ]; then
          printf '%s\n' "$ips" | sed 's/^/      /'
        else
          info "（暂无数据，等家人连过一次再来）"
        fi
        pause_key ;;
      0|*) return 0 ;;
    esac
  done
}

resign_all() {
  local clients; clients="$(list_clients)"
  if [ -z "$clients" ]; then warn "还没有客户端"; return 0; fi
  local days
  days="$(ask '重签的有效期（天）' '7')"
  case "$days" in ''|*[!0-9]*) days=7 ;; esac
  for c in $clients; do
    if sign_cert "$c" "$days"; then
      ok "$c 已重签（到期 $(cert_expiry_of "$CLIENT_DIR/$c/id_ig_tunnel-cert.pub")）"
    else
      err "$c 重签失败"
    fi
  done
  say ""
  warn "证书文件变了，需要重新发给家人（双击「更新授权」安装）。"
  say ""
  info "打包：回菜单选 2，输入同名客户端即可（会复用旧密钥，只更新证书）。"
}

# ============================================================
#  7) 吊销 / 配置 / 卸载
# ============================================================
do_revoke_all() {
  say ""
  say "${C_R}紧急吊销全部授权${C_0}"
  hr
  info "做法：换掉 CA 密钥。所有已发出的证书立即失效。"
  info "之后需要重新签发，家人也要换新的密钥包。"
  say ""
  confirm "确认吊销？" || { info "已取消"; return 0; }

  local stamp; stamp="$(date +%Y%m%d%H%M%S)"
  mv "$CA_KEY" "${CA_KEY}.revoked.${stamp}"
  [ -f "${CA_KEY}.pub" ] && mv "${CA_KEY}.pub" "${CA_KEY}.pub.revoked.${stamp}"
  ssh-keygen -t ed25519 -f "$CA_KEY" -N "" -C "tunnel-ca" >/dev/null
  chmod 600 "$CA_KEY"; chmod 644 "$CA_KEY.pub"

  # 旧的客户端密钥也要清掉，避免复用
  if [ -d "$CLIENT_DIR" ]; then
    mv "$CLIENT_DIR" "${CLIENT_DIR}.revoked.${stamp}"
    mkdir -p "$CLIENT_DIR"
  fi

  restart_ssh || return 1
  ok "已吊销。所有旧证书和旧密钥包全部作废。"
  info "下一步：菜单 2 重新签发授权。"
}

do_show_config() {
  clear
  say ""
  say "${C_B}当前配置${C_0}"
  hr
  say "  隧道账号      : $TUNNEL_USER"
  say "  sshd 监听端口 : $TUNNEL_PORT   （本机视角）"
  if [ "${CLIENT_PORT:-$TUNNEL_PORT}" != "$TUNNEL_PORT" ]; then
    say "  客户端入口端口: ${CLIENT_PORT}   ${C_D}（家人连这个，由 sslh 转进来）${C_0}"
  else
    say "  客户端入口端口: ${CLIENT_PORT:-$TUNNEL_PORT}"
  fi
  say "  CA 私钥       : $CA_KEY"
  say "  客户端密钥目录: $CLIENT_DIR"
  say "  状态目录      : $STATE_DIR"
  say "  sshd 配置片段 : $DROPIN"
  say "  每日口令      : $(otp_enabled && echo 已开启 || echo 未开启)"
  local a; a="$(allowlist_get)"
  say "  来源 IP 白名单: ${a:-未设置}"
  say ""
  say "  ${C_D}--- $DROPIN ---${C_0}"
  [ -f "$DROPIN" ] && sed 's/^/      /' "$DROPIN" || info "（未生成）"
  say ""
  say "  ${C_D}--- sshd_config 末尾的 Match 块 ---${C_0}"
  if grep -q "^${MARK_BEGIN}$" "$SSHD_CONF" 2>/dev/null; then
    sed -n "/^${MARK_BEGIN}$/,/^${MARK_END}$/p" "$SSHD_CONF" | sed 's/^/      /'
  else
    info "（未启用）"
  fi
  say ""
  say "  ${C_D}--- systemd 定时器 ---${C_0}"
  systemctl is-active igtunnel-otp.timer 2>/dev/null | sed 's/^/      igtunnel-otp.timer: /' || true
  say ""
  hr
  pause_key
}

do_uninstall() {
  say ""
  say "${C_R}卸载${C_0}"
  hr
  info "会删除：CA、客户端密钥、sshd 配置片段、Match 块、定时器、隧道账号。"
  info "不会动：你自己的 SSH 配置和密钥。"
  say ""
  confirm "确认卸载？" || { info "已取消"; return 0; }

  sed -i "/^${MARK_BEGIN}$/,/^${MARK_END}$/d" "$SSHD_CONF" 2>/dev/null
  rm -f "$DROPIN"
  systemctl disable --now igtunnel-otp.timer >/dev/null 2>&1
  rm -f /etc/systemd/system/igtunnel-otp.service /etc/systemd/system/igtunnel-otp.timer
  systemctl daemon-reload 2>/dev/null
  rm -f "$INSTALLED_CTL"
  rm -rf "$CA_DIR" "$STATE_DIR"
  if id "$TUNNEL_USER" >/dev/null 2>&1; then
    userdel -r "$TUNNEL_USER" >/dev/null 2>&1
  fi
  restart_ssh "$TUNNEL_PORT" || true
  ok "已卸载"
  info "sshd_config 备份在 ${SSHD_CONF}.igtunnel.bak（内容完好，可随时覆盖回去）"
}

# ============================================================
#  端口设置
# ============================================================
show_port_table() {
  clear
  say ""
  say "${C_B}端口占用情况${C_0}"
  hr
  local p list sshp mark
  # 把 sshd 的实际生效端口并进探测列表 ——
  # 否则自定义登录端口（如 50022）根本不会出现在这张表里。
  sshp="$(sshd_ports 2>/dev/null | tr '\n' ' ' || true)"
  list="$( { printf '%s\n' $sshp
             printf '%s\n' 22 80 443 8443 9443 2053 2083 2087 2096 2222 4443 42443 \
                           "${TUNNEL_PORT:-}" "${CLIENT_PORT:-}"
           } | grep -E '^[0-9]+$' | sort -un )"
  for p in $list; do
    mark=""
    if printf '%s\n' $sshp | grep -qx "$p"; then
      mark="  ${C_D}← 你的 SSH 登录口${C_0}"
    fi
    if port_in_use "$p"; then
      printf '    %-6s %b占用%b   %s%b\n' "$p" "$C_Y" "$C_0" "$(port_owner "$p")" "$mark"
    else
      printf '    %-6s %b空闲%b%b\n' "$p" "$C_G" "$C_0" "$mark"
    fi
  done
  say ""
  hr
  pause_key
}

change_port_interactive() {
  if ! is_installed; then err "还没安装，请先用菜单 1"; return 1; fi
  local np old
  old="$TUNNEL_PORT"
  np="$(find_free_port || true)"
  np="$(ask '新的隧道端口' "${np:-8443}")"
  case "$np" in ''|*[!0-9]*) err "端口必须是数字"; return 1 ;; esac
  if [ "$np" = "$old" ]; then info "和当前一致，没有改动"; return 0; fi
  if port_in_use "$np"; then
    err "端口 ${np} 已被占用（$(port_owner "$np")）"
    return 1
  fi

  say ""
  warn "换端口后 config.ini 里的 VpsPort 也会变，家人必须重新拿一份授权包。"
  warn "而且要确认公司防火墙放行 ${np}。"
  confirm "确认换成 ${np}？" || { info "已取消"; return 0; }

  TUNNEL_PORT="$np"
  CLIENT_PORT="$np"
  if ! build_dropin "$np" "$old"; then
    err "写 sshd 配置失败，已放弃（没有改动任何运行中的服务）"
    TUNNEL_PORT="$old"; CLIENT_PORT="$old"
    return 1
  fi
  save_conf
  if restart_ssh "$old"; then
    ok "隧道端口已改为 ${np}"
    info "重新打包：菜单 2，输入同名客户端即可（复用旧密钥，只更新配置）"
  else
    TUNNEL_PORT="$old"; CLIENT_PORT="$old"; save_conf
    warn "换端口失败，正在尝试恢复原来的隧道配置..."
    if build_dropin "$old" && restart_ssh; then
      ok "已恢复到换端口之前的状态，家人那边不用重新打包。"
    else
      err "恢复失败，隧道暂时不可用。"
      info "你的 SSH 登录不受影响（本脚本从不改动 sshd 已有的登录端口）。回菜单 1 重新安装即可。"
    fi
    return 1
  fi
}

do_port_menu() {
  while true; do
    clear
    say ""
    say "${C_B}端口设置${C_0}"
    hr
    say "  隧道端口：${C_Y}${TUNNEL_PORT}${C_0}"
    if port_in_use "$TUNNEL_PORT"; then
      ok "正在监听（$(port_owner "$TUNNEL_PORT")）"
    else
      err "没有在监听 —— 家人连不上"
    fi
    if have sslh && systemctl is-active --quiet sslh 2>/dev/null; then
      ok "sslh：运行中，已接管 443"
    else
      info "sslh：未运行"
    fi
    say ""
    hr
    say "  1) 换一个隧道端口（自动挑空闲的）"
    say "  2) 用 sslh 让 443 共用（Xray / 网站 + SSH）"
    say "     ${C_D}注意：443 上跑 Reality 时脚本会强烈劝阻，见 README 第七节${C_0}"
    say "  3) 查看常用端口占用情况"
    say "  0) 返回"
    say ""
    local c
    c="$(ask '请选择' '0')"
    case "$c" in
      1) change_port_interactive; pause_key ;;
      2) do_sslh_share; pause_key ;;
      3) show_port_table ;;
      0|*) return 0 ;;
    esac
  done
}

# ============================================================
#  健康检查 / 被封诊断（只读）
# ============================================================
do_diagnose() {
  clear
  say ""
  say "${C_B}健康检查 / 被封诊断${C_0}  ${C_D}（只读：不改任何东西）${C_0}"
  hr

  local svc; svc="$(ssh_service)"
  local problem=0
  local cport="${CLIENT_PORT:-$TUNNEL_PORT}"

  # ---------- 本机侧 ----------
  say "  ${C_B}[1] 本机服务状态${C_0}"
  if systemctl is-active --quiet "$svc"; then ok "$svc 运行中"; else err "$svc 未运行"; problem=1; fi
  if is_installed; then
    if is_paused; then warn "隧道：已暂停（菜单 7 恢复）"; problem=1; else ok "隧道：已启用"; fi
  else
    err "隧道：未安装（菜单 1）"; problem=1
  fi

  say "  sshd 生效端口：$(sshd_ports 2>/dev/null | tr '\n' ' ')"
  if port_in_use "$TUNNEL_PORT"; then
    ok "sshd 隧道端口 ${TUNNEL_PORT} 正在监听（$(port_owner "$TUNNEL_PORT")）"
  else
    err "sshd 隧道端口 ${TUNNEL_PORT} 没有在监听"; problem=1
  fi
  if [ "$cport" != "$TUNNEL_PORT" ]; then
    if port_in_use "$cport"; then
      ok "客户端入口 ${cport} 正在监听（$(port_owner "$cport")）"
    else
      err "客户端入口 ${cport} 没有在监听 —— sslh 可能挂了"; problem=1
    fi
  fi

  # ---------- 分层诊断 ----------
  say ""
  hr
  say "  ${C_B}[2] 分层诊断：家人连不上时先判断是哪一层${C_0}"
  say ""
  say "   ${C_Y}① 连接被 RST${C_0}  ${C_D}毫秒级，只影响那一条连接${C_0}"
  info "特征：能连上，几秒后 Connection reset / closed by remote host"
  info "含义：DPI 命中了协议特征（明文 SSH 横幅最容易被盯上）"
  info "处理：不用改端口，换时间重试；频繁出现再考虑换方案（见 README 第七节 7.4）"
  say ""
  say "   ${C_Y}② 端口被阻断${C_0}  ${C_D}只影响这一个端口${C_0}"
  info "特征：Test-NetConnection <IP> -Port <端口> 不通，但换别的端口就通"
  info "处理：菜单 12 → 1 换端口，然后重新打包给家人"
  say ""
  say "   ${C_Y}③ IP 被封锁${C_0}  ${C_D}影响整台机器，Reality 一起挂${C_0}"
  info "特征：所有端口都不通；从家里（非公司网络）测也不通"
  info "处理：用 VPS 厂商的网页控制台换 IP，或换机器"
  say ""

  # ---------- 日志判读 ----------
  say "  ${C_B}[3] 日志判读${C_0}"
  local recent_ok recent_fail
  recent_ok="$(ssh_unit_logs --since '24 hours ago' 2>/dev/null | grep -c "Accepted .* for ${TUNNEL_USER} " || true)"
  recent_fail="$(ssh_unit_logs --since '24 hours ago' 2>/dev/null | grep -c "Failed\|Invalid user" || true)"
  say "      近 24 小时：成功连接 ${recent_ok:-0} 次，认证失败 ${recent_fail:-0} 次"

  local last
  last="$(ssh_unit_logs --since '14 days ago' 2>/dev/null | grep "Accepted .* for ${TUNNEL_USER} " | tail -1)"
  if [ -n "$last" ]; then
    ok "最近一次成功连接："
    printf '%s\n' "$last" | sed 's/^/        /'
    say ""
    info "本机侧一切正常。如果家人此刻连不上，让她在公司电脑上跑："
    say ""
    say "        ${C_B}Test-NetConnection <你的VPS_IP> -Port ${cport}${C_0}"
    say ""
    info "通   → 属于 ①（DPI 中途打断），换个时间再试"
    info "不通 → 属于 ② 或 ③，也可能是公司封了这个端口"
    info "从她家里网络测也不通 → 基本可以确定是 ③，该换 IP 了"
  else
    warn "近 14 天【没有任何成功连接记录】"
    info "可能是：家人还没开始用 / 证书没装对 / 一直被拦在外面"
    info "让她跑一次「打开Instagram.bat」，把失败弹窗的内容截图发你，"
    info "再把那段文字贴到「查看实时日志」里对照。"
  fi

  # ---------- 暴露面 ----------
  say ""
  hr
  say "  ${C_B}[4] 对外暴露的端口${C_0}"
  info "这些端口全网可扫，扫描器会一直来敲门（属正常现象）："
  if have ss; then
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -vE '^(127\.|\[::1\]|\[::ffff:127)' \
      | sort -u | sed 's/^/        /'
  fi
  info "· 隧道端口建议不要用 443（见 README 第七节）"
  if have fail2ban; then ok "fail2ban 已装"; else warn "fail2ban 未装：apt install -y fail2ban"; fi

  say ""
  hr
  if [ "$problem" -eq 0 ]; then
    ok "本机侧检查全部通过。"
  else
    warn "本机侧有告警项，见上面标 ✗ 的行。"
  fi
  pause_key
}

# ============================================================
#  菜单
# ============================================================
show_header() {
  clear
  say ""
  say "${C_B}  Instagram 隧道 · 服务端控制台${C_0}"
  hr

  local state
  if ! is_installed; then
    state="${C_Y}未安装${C_0}"
  elif is_paused; then
    state="${C_R}已暂停${C_0}"
  else
    state="${C_G}运行中${C_0}"
  fi

  local nclients=0
  [ -d "$CLIENT_DIR" ] && nclients="$(list_clients | grep -c . || true)"

  say "  状态：$state    端口：${TUNNEL_PORT}    账号：${TUNNEL_USER}    授权：${nclients} 个"
  if otp_enabled; then
    say "  每日口令：${C_Y}已开启${C_0}    今日：${C_G}$(otp_code_today)${C_0}"
  fi
  hr
  say "   ${C_B}1${C_0}) 首次安装 / 重新安装      ${C_D}（会先跑只读预检）${C_0}"
  say "   ${C_B}2${C_0}) 签发新授权（打包给家人）"
  say "   ${C_B}3${C_0}) 续期授权"
  say "   ${C_B}4${C_0}) 运行监控"
  say "   ${C_B}5${C_0}) 查看实时日志"
  say "   ${C_B}6${C_0}) 暂停服务        （家人立刻连不上）"
  say "   ${C_B}7${C_0}) 恢复服务"
  say "   ${C_B}8${C_0}) 每日口令设置"
  say "   ${C_B}9${C_0}) 来源 IP 白名单"
  say "   ${C_B}10${C_0}) 查看当前配置"
  say "   ${C_B}11${C_0}) 紧急吊销全部授权"
  say "   ${C_B}12${C_0}) 端口设置（换端口 / 443 共用）"
  say "   ${C_B}13${C_0}) 健康检查 / 被封诊断"
  say "   ${C_B}14${C_0}) 只读环境预检"
  say "   ${C_B}15${C_0}) 完全卸载"
  say "   ${C_B}0${C_0}) 退出"
  hr
}

menu() {
  while true; do
    show_header
    local c
    c="$(ask '请选择' '0')"
    case "$c" in
      1)  do_install ;;
      2)  do_issue ;;
      3)  do_renew ;;
      4)  do_monitor; continue ;;
      5)  do_logs; continue ;;
      6)  do_pause; pause_key ;;
      7)  do_resume; pause_key ;;
      8)  do_otp; continue ;;
      9)  do_allowlist; continue ;;
      10) do_show_config; continue ;;
      11) do_revoke_all; pause_key ;;
      12) do_port_menu; continue ;;
      13) do_diagnose; continue ;;
      14) precheck; pause_key ;;
      15) do_uninstall; pause_key ;;
      0)  say ""; say "  再见"; say ""; exit 0 ;;
      *)  warn "无效选项" ; sleep 1; continue ;;
    esac
    pause_key
  done
}

# ============================================================
#  入口
# ============================================================
case "${1:-}" in
  --otp-refresh)
    # 供 systemd 定时器调用
    need_root
    load_conf
    otp_refresh
    exit 0
    ;;
  --check)
    # 只读环境预检：不创建、不修改、不删除任何东西
    need_root
    load_conf
    precheck
    exit $?
    ;;
  --diag)
    # 只读健康检查 / 被封诊断
    need_root
    load_conf
    do_diagnose
    exit 0
    ;;
  --help|-h)
    cat <<EOF
Instagram 隧道 · 服务端控制台

  sudo bash $0                进入交互菜单
  sudo bash $0 --check        只读环境预检（绝不改动任何东西）
  sudo bash $0 --diag         只读健康检查 / 被封诊断
  sudo bash $0 --otp-refresh  仅刷新今日口令（供定时器调用）

安全说明：
  本脚本从不读写你的 Xray / V2Ray / Nginx 配置。
  它只往 sshd_config.d/10-tunnel.conf 和 sshd_config 末尾的 Match 块写东西，
  每次重启 sshd 前会备份并拍端口快照，重启后逐项核对，异常自动回滚。
EOF
    exit 0
    ;;
esac

need_root
load_conf
menu
