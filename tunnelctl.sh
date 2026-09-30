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
# systemd 单元目录。做成变量是为了让测试能把整个卸载流程关进沙盒 ——
# 否则测试会去动真实的 /etc/systemd/system。
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
SNAPDIR="$STATE_DIR/snapshots"
DIST_DIR="${DIST_DIR:-/root/igtunnel-dist}"   # 授权包输出目录（可用环境变量覆盖，便于测试）

# 本脚本自己的目录（客户端模板还原在这里）。卸载时整体删除。
# 单独定义成一个变量、而不是从 TEMPLATE_DIR 反推父目录，是为了让测试能安全覆盖：
# 如果写成 dirname "$TEMPLATE_DIR"，测试里覆盖 TEMPLATE_DIR 之后，
# 卸载就会去删真实的 /opt/igtunnel（甚至更糟）。
IGT_OPT_DIR="${IGT_OPT_DIR:-/opt/igtunnel}"
TEMPLATE_DIR="${TEMPLATE_DIR:-$IGT_OPT_DIR/client}"  # 内嵌模板还原位置（同样可覆盖）

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
  DOWNLOAD_PORT="${DOWNLOAD_PORT:-}"
}

save_conf() {
  mkdir -p "$CA_DIR"
  {
    echo "# igtunnel 配置，由 tunnelctl.sh 维护"
    echo "TUNNEL_USER=\"$TUNNEL_USER\""
    echo "TUNNEL_PORT=\"$TUNNEL_PORT\""
    echo "CLIENT_PORT=\"${CLIENT_PORT:-$TUNNEL_PORT}\""
    echo "DOWNLOAD_PORT=\"${DOWNLOAD_PORT:-}\""
  } > "$CONF_FILE"
  chmod 600 "$CONF_FILE"
}

# base64 解码（stdin -> stdout）。GNU 用 -d，BSD/老系统退回 openssl。
b64_decode() {
  if printf '' | base64 -d >/dev/null 2>&1; then base64 -d; return $?; fi
  if have openssl; then openssl base64 -d; return $?; fi
  return 1
}

# 内嵌的客户端模板（client/ 目录的 tar.gz + base64）。
#
# 为什么要内嵌：这是一个"单文件"服务端脚本。如果只把 tunnelctl.sh 传上 VPS，
# 脚本就找不到同级的 client/ 目录，打包出来的 zip 里只有密钥、没有 .bat 和
# tunnel.ps1，家人拿到手根本没法用。内嵌之后，单文件也能自给自足。
client_payload_b64() {
  cat <<'__IGTUNNEL_CLIENT_TEMPLATE_B64__'
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
atzFeB7GZeu7e/m4fGwCZs1GQX0O6CjFI4P9Crm9aP6iXpCKqeg4okU3qsdqcLkFKq4MFE80480W
T+cfL7AEH8rQEEAfJvigYR3FDF7LBRKtkB7BHogLgTwdJUw8EQeNLYHFCvhI/u5p+UQfl/WeTAok
d7AECSs6ZWH9L9xQiSGHzhUsxVE7OX7hTGFq/i0l+BpMkUUbsBal+IDPqLgcqJYopkQpR+fDTjYg
M5C2eXQWIDaAWJrHBVZAHriMWbZY8lAVsaNCR006y4R45elNYP5Nce3yyFOAf1zGlap5tKGodywc
N21VUWNtUW1w2XvDOzjfLz+6wNRWPKa5uJUYz/fCeZg0xp3MPM5fvwNnl1+4IFhkLeMze1oxmy4m
zRkY26rvb5nWZSFlojxwAoYopknUPD3EhHxuvHbATa2c4p0B7Ky70cXa8JH6R/OPzCfYrX/k7rxa
XfQ/cot1qUMS/4yGbEPT1LiMF1RtWOaJxGPAnG0+KPVsbg4f3gkCgJTe7N3PUgZ4s4ezG3764/P5
amtqCP6sqw3Rn74A+5s9dbXEHwqE6nx1/qAvRHwBXygU2EAOb1iHpwtjsWAoHfH2rmSJclCsra30
JOEh2s8/kicYIKlwtqNeOAfi7lcEfaQTGdd6f90WX10w5KsJeYO1wZq6QF3QX7HBef7InyL7vqp9
LAf/gZqgEf79taG60Abic+B/7Z8/+5s/3/DrDRt2hyOkqQUZTfbguw1/Af8C8O8P8A//vlVekw2t
rXv5r1jjIvz7S1ORX+nv/zqS7PSGU6m45E2lk4ekRDgRkTb86tcbXi/+1/H//sN/5h0gXR/41+n/
KuOB5eHfQv+DwRqH/q8L/fdZ6H/Z1D9UR3Y1ftSwd9vOxk93eA+Hs9m01w6Y6xv+qbHhUDr4afuh
jsO+pkhFzRbSApV2/UupSgIGcPiM9YD/NaL+y8K/3x/wm+l/MFTj0P/1eMRgNPn23FL/sDx/tjB9
R5kYzM3e1j79+OoyN62L1z8Znv/t4Q6SGJrw7XnMCkDTxtGbSh4x3zW8HvLsPWXkpprT3/4OJt6c
0YN9QG/l1WWqw5+heXEHKyp+6B1jPaI3r6rYEIePGhh6rxO1eh6nNVhzqDXSL4W8j+l8R8f53SC0
A6KHdBK8cWXxhphfjwUxymOnmE5DvRpkiCkooLrJG1H3lteawFDIV5dZ2obcwikxJlPcFubWJs+9
YDc2MTU5LiaLjj75svDsqjo1ZXRs6cRpmJruRqiGa9HMfqiSxTRlxjgtMUyLpTXG1H+WZL6mK4zY
MmqqKQdVO4/zOI/zOI/zOI/zOI/zOI/zOI/zOI/zOI/zOI/zOI/zOI/zOI/zOI/zOI/zOI/zOI/z
OI/zOI/zrP3z/wEnnnWUAGgBAA==
__IGTUNNEL_CLIENT_TEMPLATE_B64__
}

# 把内嵌模板解到 dest（tar 里顶层是 client/）
materialize_client_template() {
  local dest="$1" tmp
  tmp="$(mktemp -d 2>/dev/null)" || return 1
  if client_payload_b64 | b64_decode > "$tmp/p.tgz" 2>/dev/null && [ -s "$tmp/p.tgz" ] \
     && tar -xzf "$tmp/p.tgz" -C "$tmp" 2>/dev/null && [ -d "$tmp/client" ]; then
    mkdir -p "$dest" 2>/dev/null
    if cp -a "$tmp/client/." "$dest/" 2>/dev/null; then
      rm -rf "$tmp"
      # 注意：本函数的调用方是 tpl="$(client_template_dir)"，stdout 会被捕获。
      # 所以这条提示必须走 stderr，否则会混进路径变量里把 cp 搞崩。
      ok "已从脚本内嵌模板还原客户端文件 → $dest" >&2
      return 0
    fi
  fi
  rm -rf "$tmp"
  return 1
}

client_template_dir() {
  local d
  for d in "$SCRIPT_DIR/client" "$SCRIPT_DIR/../client" "$TEMPLATE_DIR"; do
    if [ -d "$d" ]; then printf '%s' "$d"; return 0; fi
  done
  # 全都找不到 → 从脚本自身内嵌的模板还原一份（保证单文件脚本也能打包）
  if materialize_client_template "$TEMPLATE_DIR"; then printf '%s' "$TEMPLATE_DIR"; return 0; fi
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

# ============================================================
#  防火墙：放行 / 收回端口
# ============================================================
# ★ 必须同时处理 ufw / firewalld / iptables 三套。
#
# 为什么 iptables 不能漏：Oracle Cloud、以及不少云厂商的镜像
# （Oracle Linux、OCI 上的 Ubuntu）默认用 iptables，并且 INPUT 链里
# 有一条 "除 22 外全 REJECT" 的规则。只调 ufw / firewalld 的话，
# 在这些机器上端口根本没放开 —— 你会以为脚本没生效。

# 放行一个 TCP 端口。stdout 输出"放行了哪些"，返回 0 表示至少放行了一处。
fw_open_port() {
  local port="$1" did=0

  if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 && { printf 'ufw '; did=1; }
  fi

  if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    # 不加 --permanent：只改运行时，reload/重启后自动消失，正好用于临时端口
    firewall-cmd --add-port="${port}/tcp" >/dev/null 2>&1 && { printf 'firewalld '; did=1; }
  fi

  if have iptables; then
    if iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
      printf 'iptables(已存在) '; did=1
    elif iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
      printf 'iptables '; did=1
    fi
  fi

  if have ip6tables; then
    ip6tables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 \
      || ip6tables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
  fi

  [ "$did" = 1 ]
}

# 收回之前放行的端口（三套都清一遍，清干净为止）
fw_close_port() {
  local port="$1"
  if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
  fi
  if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --remove-port="${port}/tcp" >/dev/null 2>&1 || true
  fi
  if have iptables; then
    local n=0
    while [ "$n" -lt 10 ] && iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; do
      iptables -D INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || break
      n=$((n + 1))
    done
  fi
  if have ip6tables; then
    local m=0
    while [ "$m" -lt 10 ] && ip6tables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; do
      ip6tables -D INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || break
      m=$((m + 1))
    done
  fi
  return 0
}

# 让 iptables 的运行时规则落盘，重启后仍生效（隧道端口需要，临时端口不需要）
fw_persist() {
  if have netfilter-persistent; then
    netfilter-persistent save >/dev/null 2>&1 && { printf 'netfilter-persistent'; return 0; }
  fi
  if have service && service iptables save >/dev/null 2>&1; then
    printf 'service iptables save'; return 0
  fi
  if have iptables-save && [ -f /etc/sysconfig/iptables ]; then
    iptables-save > /etc/sysconfig/iptables 2>/dev/null && { printf '/etc/sysconfig/iptables'; return 0; }
  fi
  if have iptables-save && [ -d /etc/iptables ]; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null && { printf '/etc/iptables/rules.v4'; return 0; }
  fi
  return 1
}

# 是不是 Oracle Cloud（OCI）。OCI 的"安全列表/NSG"在云侧，
# 机器内部改不了，只能去控制台加规则。
is_oracle_cloud() {
  local tag=""
  if [ -r /sys/class/dmi/id/chassis_asset_tag ]; then
    tag="$(cat /sys/class/dmi/id/chassis_asset_tag 2>/dev/null)"
    [ "$tag" = "OracleCloud" ] && return 0
  fi
  if have curl; then
    curl -fsS --max-time 3 -H 'Authorization: Bearer Oracle' \
      http://169.254.169.254/opc/v2/instance/ >/dev/null 2>&1 && return 0
  fi
  return 1
}

# 打印"云侧安全组还得手动开"的提示（只在真的检测到时才提）
fw_cloud_hint() {
  local port="$1"
  is_oracle_cloud || return 0
  say ""
  warn "${C_Y}检测到这是 Oracle Cloud${C_0} —— 还有一层防火墙我改不了："
  say "     OCI 控制台的 ${C_B}安全列表 / NSG${C_0} 是云侧的，机器内部无法修改。"
  say "     如果下面这个端口连不上，去控制台加一条入站规则："
  say ""
  say "       实例 → 主 VNIC → 子网 → 安全列表 → 添加入站规则"
  say "       源 CIDR: ${C_B}0.0.0.0/0${C_0}   协议: ${C_B}TCP${C_0}   目标端口: ${C_B}${port}${C_0}"
  say ""
  say "     ${C_D}（或者回菜单 16 选第 2 种方式：SSH 命令。走已经放行的端口，一个新端口都不用开）${C_0}"
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
    info "隧道配置要写到 ${DROPIN}，没有 Include 就不会生效。"
    info "脚本只会提醒你手工加一行，不会替你改主配置。"
  fi

  say ""
  say "  ${C_B}[2] 443 端口${C_0}"
  if port_in_use 443; then
    local o443 s443
    o443="$(port_owner 443)"
    s443="$(service_owning_port 443 || true)"
    warn "443 已被占用：${o443:-未知进程}${s443:+  （服务：${s443}）}"
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
  info "安装只做三件事：建一个受限账号、写 ${DROPIN}、重启一次 sshd。"
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
    ok "已创建（shell=${nologin}，无法登录）"
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

  # 把 tun 账号的认证方式钉死，不依赖全局设置。
  # 口令关闭时必须显式写 PasswordAuthentication no —— 否则 tun 仍然接受密码认证，
  # 客户端证书一旦不被接受就会莫名弹出「请输入口令」。详见 apply_ssh_match()。
  if otp_enabled; then
    apply_ssh_match on
  else
    apply_ssh_match off
  fi
  if grep -q "^${MARK_BEGIN}$" "$SSHD_CONF"; then
    ok "已写入 ${TUNNEL_USER} 账号的 Match 块（认证方式：$(otp_enabled && echo '证书+每日口令' || echo '仅证书'))"
  else
    warn "Match 块写入失败 —— tun 账号会沿用全局认证设置"
  fi

  say "  [4/6] 校验并重启 sshd（会先备份、后核对、异常自动回滚）"
  restart_ssh "$prev_port" || return 1

  say "  [5/6] 放行防火墙"
  local fwdid
  if fwdid="$(fw_open_port "$TUNNEL_PORT")"; then
    ok "已放行 ${TUNNEL_PORT}/tcp（${fwdid}）"
    # firewalld 是运行时的，要永久生效得单独加；iptables 要落盘
    if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
      firewall-cmd --permanent --add-port="${TUNNEL_PORT}/tcp" >/dev/null 2>&1 \
        && firewall-cmd --reload >/dev/null 2>&1 && ok "firewalld 已设为永久放行"
    fi
    if have iptables; then
      local pdid
      if pdid="$(fw_persist)"; then
        ok "iptables 规则已落盘（${pdid}），重启后仍生效"
      else
        warn "iptables 规则只是运行时的，重启后会丢。建议装 netfilter-persistent 后执行 save"
      fi
    fi
  else
    warn "没检测到活动的本机防火墙（ufw/firewalld/iptables 都没有）—— 如果连不上，多半是云侧安全组没放行"
  fi
  fw_cloud_hint "$TUNNEL_PORT"

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

  cat > "$SYSTEMD_DIR/igtunnel-otp.service" <<EOF
[Unit]
Description=Instagram tunnel daily password refresh

[Service]
Type=oneshot
ExecStart=$INSTALLED_CTL --otp-refresh
EOF

  cat > "$SYSTEMD_DIR/igtunnel-otp.timer" <<'EOF'
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
  say "  当前 443 的占用者：${C_Y}${owner:-未知}${C_0}${svc443now:+  （服务：${svc443now}）}"
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

# 检查 zip 里的非 ASCII 文件名是否带了 UTF-8 标志（general purpose bit 11）。
#
# 不带标志时，Windows 会按本地代码页（简中是 GBK）去解释那串 UTF-8 字节，
# 于是 "更新授权.bat" 显示成 "µ¢┤µû░µÄêµ¥â.bat" —— 家人完全认不出。
# 返回 0 = 正常；返回非 0 时 stdout 给一个坏文件名的例子。
check_zip_utf8() {
  have python3 || return 0
  python3 - "$1" <<'IGT_PY_EOF'
import sys, zipfile
try:
    zf = zipfile.ZipFile(sys.argv[1])
except Exception:
    sys.exit(0)
for info in zf.infolist():
    name = info.orig_filename
    if any(ord(ch) > 127 for ch in name) and not (info.flag_bits & 0x800):
        print(name)
        sys.exit(1)
sys.exit(0)
IGT_PY_EOF
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

  outroot="$DIST_DIR"
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

  # ★ 这个值必须跟着「每日口令」的真实状态走，不能写死。
  #   写死 auto 的后果：客户端永远保留"要不要问口令"的余地，
  #   一旦证书没被接受（或网络不通），它就会弹窗要口令 ——
  #   而管理员明明没开口令，用户根本无口令可输，只能一脸茫然。
  local askpw
  if otp_enabled; then
    askpw="auto"    # 开了口令：先试免口令，服务器表示要口令时再问
  else
    askpw="off"     # 没开口令：只走证书，永不询问
  fi

  cat > "$pkg/config.ini" <<EOF
# Instagram 隧道 · 客户端配置（由服务端脚本自动生成，一般不用改）
VpsHost=$host
VpsPort=${CLIENT_PORT:-$TUNNEL_PORT}
VpsUser=$TUNNEL_USER
LocalPort=1080

# off = 不需要口令（只走证书）；auto = 需要时自动弹窗；window = 固定用黑窗口输入
# 本包生成时的服务端状态：$(otp_enabled && echo '每日口令已开启' || echo '每日口令未开启')
AskPassword=$askpw

BrowserPath=
MaxSessionMinutes=480
StartUrl=https://www.instagram.com/
EOF

  if otp_enabled; then
    info "客户端口令模式：auto（服务端已开启每日口令）"
  else
    info "客户端口令模式：off（服务端未开启每日口令，家人不需要输任何口令）"
  fi

  info "客户端连接目标：${host}:${CLIENT_PORT:-$TUNNEL_PORT}（账号 ${TUNNEL_USER}）"

  local archive=""
  local zippw
  say ""
  info "打包时可以加个密码，防止传输途中被翻看（留空则不加密）"
  zippw="$(ask '压缩包密码（留空 = 不加密）' '')"

  # 打包。
  #
  # ★ 为什么优先用 python3 而不是 zip：
  #   包里的文件名是中文（打开Instagram.bat 等）。zip 命令（尤其是 macOS 自带
  #   的那版 Info-ZIP 3.0）不会给非 ASCII 文件名设置 UTF-8 标志位，
  #   Windows 解压时就会按本地代码页解释 → 变成 "µ¢┤µû░µÄêµ¥â.bat" 这种乱码，
  #   家人根本认不出该双击哪个。python3 的 zipfile 会正确设置该标志。
  #   代价：python3 的 zipfile 不支持写加密包，所以"要密码"时只能用 zip。
  archive="$outroot/$name.zip"
  rm -f "$archive"
  local packer="" badname=""

  # 第 1 步：想要密码 → 只能用 zip（python3 的 zipfile 写不了加密包）
  if [ -n "$zippw" ]; then
    if have zip; then
      ( cd "$outroot" && zip -qr -P "$zippw" "$name.zip" "$name" ) && packer="zip（含密码）"
    else
      warn "你设了密码，但系统没有 zip 命令（python3 无法加密）→ 改为不加密打包"
      zippw=""
    fi
  fi

  # 第 2 步：zip 打的包要自检中文文件名；不合格就丢弃，走第 3 步重打
  if [ -n "$packer" ]; then
    if ! badname="$(check_zip_utf8 "$archive")"; then
      warn "压缩包里的中文文件名没带 UTF-8 标志，Windows 上会显示成乱码："
      warn "  例如：${badname}"
      warn "家人会认不出该双击哪个文件 → 自动改为【不加密】重打一次"
      rm -f "$archive"; packer=""; badname=""; zippw=""
    fi
  fi

  # 第 3 步：打一个不加密的包（优先 python3，文件名一定正确）
  if [ -z "$packer" ]; then
    if have python3; then
      ( cd "$outroot" && python3 -m zipfile -c "$name.zip" "$name" ) && packer="python3"
    elif have zip; then
      ( cd "$outroot" && zip -qr "$name.zip" "$name" ) && packer="zip"
    fi
  fi

  if [ -z "$packer" ]; then
    err "打包失败：系统里既没有 zip 也没有 python3"
  elif [ "$packer" = "zip" ]; then
    ok "已生成压缩包（zip）"
    warn "系统里没有 python3，无法自检中文文件名是否正常。"
    warn "若家人在 Windows 上看到一堆乱码文件名，装个 python3 重打即可：apt install -y python3"
  else
    ok "已生成压缩包（${packer}）"
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
  say "    ${C_D}（想把包拿到自己电脑上：菜单 16 —— 可选 HTTP 链接或一条 SSH 命令）${C_0}"
}

# ============================================================
#  16) 把授权包传给自己
# ============================================================
# 两种方式：
#   1) 一次性 HTTP 链接 —— 随机令牌 + 限时 + 下载一次即关。
#      需要额外放行一个端口；云服务器（如 Oracle Cloud）还得去控制台
#      的安全列表加规则，机器内部改不了。
#   2) 一条 SSH 命令 —— 走已经放行的 SSH 端口，一个新端口都不用开。
#      端口不能随便开的机器（Oracle Cloud 免费机是典型）推荐这个。
#
# ⚠ 方式 1 是【明文 HTTP】。令牌只防"被扫到/被猜到"，不防"被中途嗅探"。
#   因为包里含私钥，只适合"自己下载给自己"的短窗口场景，不适合发给家人。
#   给家人请用私钥加密后的 zip + 另一个渠道传密码。

# 挑一个空闲的高位端口
find_free_high_port() {
  local i p
  for i in 1 2 3 4 5 6 7 8 9 10; do
    p=$(( 30000 + (RANDOM % 15000) ))
    port_in_use "$p" || { printf '%s' "$p"; return 0; }
  done
  return 1
}

# 生成一个猜不出来的令牌
rand_token() {
  if have openssl; then openssl rand -hex 24 2>/dev/null && return 0; fi
  if [ -r /dev/urandom ]; then
    head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; return 0
  fi
  printf '%s%s%s' "$RANDOM$RANDOM" "$RANDOM$RANDOM" "$(date +%s)"
}

# 一次性下载服务：只认 /<token>，下载成功一次就退出，到点也退出。
# 用法：serve_one_shot <文件> <端口> <令牌> <有效秒数> <完成标记文件>
serve_one_shot() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'IGT_PY_EOF'
import http.server, os, sys, time

FILE, PORT, TOKEN, TTL, FLAG = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), sys.argv[5]
NAME = os.path.basename(FILE)

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'

    def log_message(self, *args):
        pass

    def _notfound(self):
        self.send_response(404)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_HEAD(self):
        if self.path != '/' + TOKEN:
            self._notfound()
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/zip')
        self.send_header('Content-Length', str(os.path.getsize(FILE)))
        self.end_headers()

    def do_GET(self):
        if self.path != '/' + TOKEN:
            self._notfound()
            return
        try:
            self.send_response(200)
            self.send_header('Content-Type', 'application/zip')
            self.send_header('Content-Length', str(os.path.getsize(FILE)))
            self.send_header('Content-Disposition', 'attachment; filename="%s"' % NAME)
            self.end_headers()
            with open(FILE, 'rb') as fh:
                while True:
                    chunk = fh.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            return
        except OSError:
            return
        try:
            with open(FLAG, 'w') as fh:
                fh.write('ok')
        except OSError:
            pass

server = http.server.HTTPServer(('0.0.0.0', PORT), Handler)
server.timeout = 1
deadline = time.time() + TTL
try:
    while time.time() < deadline:
        server.handle_request()
        if os.path.exists(FLAG):
            break
finally:
    server.server_close()
IGT_PY_EOF
}

# 打印"在你自己的电脑上执行"的取包命令。
# 这是 Oracle Cloud 这类"端口不能随便开"的机器上最省事的办法：
# 完全走已经放行的 SSH 端口，一个新端口都不用开。
#
# ★ 为什么主推 scp，而不是更短的 ssh + 重定向：
#   `ssh host "cat 文件" > 本地文件` 看着更短，但**在 Windows 自带的
#   PowerShell 5.1 里会把文件写坏**。PS 5.1 的 `>` 等价于
#   `Out-File -Encoding Unicode`，它把 8 位字节流当成「文本」重新编码：
#     · 写成 UTF-16LE，文件头多出 ff fe，长度大约翻倍
#     · 顺手做换行归一化，把 CR(0x0d) 删掉
#   实测：256 字节的二进制 → 516 字节，内容面目全非，zip 根本打不开。
#   （PowerShell 7+ 的 `>` 是字节透传的，实测 256 → 256 字节完全一致。）
#   所以：要么用 scp（不经 shell 重定向，二进制安全，cmd / PowerShell 都能跑），
#   要么在 cmd.exe 里跑 ssh + 重定向（cmd 的 `>` 是真正的字节重定向）。
show_ssh_pull_cmd() {
  local ip="$1" sshport="$2" file="$3"
  local base; base="$(basename "$file")"
  say ""
  hr
  say "  ${C_G}在你自己的电脑上执行这一行就行${C_0}"
  say "  ${C_D}（走 SSH，一个新端口都不用开；Windows 10/11 自带的 cmd 或 PowerShell 都能跑）${C_0}"
  say ""
  say "    ${C_B}scp -P ${sshport} root@${ip}:${file} .${C_0}"
  say ""
  say "  ${C_D}想只把内容打出来也可以，但${C_Y}这一条必须在 cmd.exe 里跑${C_D}：${C_0}"
  say "    ${C_B}ssh -p ${sshport} root@${ip} \"cat ${file}\" > ${base}${C_0}"
  say ""
  say "  ${C_Y}⚠ 两个容易踩的坑：${C_0}"
  say "     · 端口参数大小写不同 —— ssh 是小写 ${C_B}-p${C_0}，scp 是大写 ${C_B}-P${C_0}"
  say "     · ${C_Y}别在 Windows 自带的 PowerShell 5.1 里用 > 重定向${C_0}"
  say "       ${C_D}它会把字节流当文本重编码成 UTF-16（长度翻倍、CR 被删），zip 直接打不开。${C_0}"
  say "       ${C_D}要么用上面的 scp，要么在 cmd.exe 里跑，要么装 PowerShell 7+。${C_0}"
}

do_serve_package() {
  say ""
  say "${C_B}把授权包传给自己${C_0}"
  hr

  local outroot="$DIST_DIR"
  local list
  list="$(ls -1t "$outroot"/*.zip 2>/dev/null | head -20)"
  if [ -z "$list" ]; then
    err "在 $outroot 里没找到 .zip 授权包。请先回菜单 2 签发并打包。"
    pause_key; return 1
  fi

  say "  可传的包（按时间从新到旧）："
  local i=1 f
  for f in $list; do
    say "    $i) $(basename "$f")"
    i=$((i+1))
  done
  say ""

  local sel
  sel="$(ask '选择要传的（序号，直接回车 = 最新那个）' '1')"
  case "$sel" in ''|*[!0-9]*) sel=1 ;; esac
  local target
  target="$(printf '%s\n' $list | sed -n "${sel}p")"
  if [ -z "$target" ] || [ ! -f "$target" ]; then
    err "序号无效"; pause_key; return 1
  fi

  local ip
  ip="$(public_host)"
  [ -n "$ip" ] || ip="$(ask '探测公网 IP 失败，请手动输入本机公网地址' '')"
  local sshport="${TUNNEL_PORT:-22}"

  say ""
  say "  ${C_B}怎么传？${C_0}"
  say "    ${C_B}1${C_0}) 临时 HTTP 链接      ${C_D}（要额外放行一个端口；云服务器还得去控制台加规则）${C_0}"
  say "    ${C_B}2${C_0}) 只给我一条 SSH 命令  ${C_G}（走已开放的端口，一个新端口都不用开）${C_0}"
  say ""
  local how
  how="$(ask '选择 [1/2]' '1')"
  case "$how" in 2) how=2 ;; *) how=1 ;; esac

  if [ "$how" = 2 ]; then
    show_ssh_pull_cmd "$ip" "$sshport" "$target"
    pause_key
    return 0
  fi

  local ttl
  ttl="$(ask '链接有效期（分钟）' '15')"
  case "$ttl" in ''|*[!0-9]*) ttl=15 ;; esac
  [ "$ttl" -lt 1 ] && ttl=1
  [ "$ttl" -gt 120 ] && ttl=120

  # 端口：记住上次用的，方便你在云控制台预先放行一个固定端口
  local defport="${DOWNLOAD_PORT:-}"
  [ -n "$defport" ] || defport="$(find_free_high_port || printf '38135')"
  local port
  port="$(ask '用哪个端口提供下载（回车用默认）' "$defport")"
  case "$port" in ''|*[!0-9]*) port="$defport" ;; esac
  if port_in_use "$port"; then
    warn "端口 ${port} 已被占用，换一个空闲的"
    port="$(find_free_high_port)" || { err "找不到空闲端口"; pause_key; return 1; }
    info "改用 ${port}"
  fi
  if [ "${DOWNLOAD_PORT:-}" != "$port" ]; then
    DOWNLOAD_PORT="$port"
    save_conf
    info "已记住端口 ${port}，下次默认用它"
  fi

  local token; token="$(rand_token)"
  local flag; flag="$(mktemp)"
  rm -f "$flag"

  # 临时放行本机防火墙（ufw / firewalld / iptables 三套都处理），结束后收回
  local fwdid
  if fwdid="$(fw_open_port "$port")"; then
    ok "本机防火墙已放行 ${port}/tcp（${fwdid}）"
  else
    warn "没检测到活动的本机防火墙（ufw / firewalld / iptables）"
  fi

  cleanup_serve() {
    fw_close_port "$port"
    rm -f "$flag" 2>/dev/null
    return 0
  }
  trap 'cleanup_serve; trap - INT TERM; exit 130' INT TERM

  say ""
  hr
  say "  ${C_G}下载链接（${ttl} 分钟内有效，下载一次后自动关闭）${C_0}"
  say ""
  say "    ${C_B}http://${ip}:${port}/${token}${C_0}"
  say ""
  say "  ${C_Y}⚠ 这是明文 HTTP，而且包里含私钥：${C_0}"
  say "     · 这个链接本身就是密码，${C_Y}不要转发给任何人${C_0}（包括家人）"
  say "     · 别在公共 Wi-Fi / 公司网络里下载"
  say "     · 下载完（或超时）服务自动关闭，本机防火墙规则也会收回"

  fw_cloud_hint "$port"

  say ""
  say "  ${C_D}一直连不上就别耗着了 —— 回上一级选 2，用 SSH 命令取，不用开端口。${C_0}"
  say ""
  say "  正在等待下载...（按 Ctrl-C 可提前结束）"
  say ""

  serve_one_shot "$target" "$port" "$token" "$((ttl * 60))" "$flag"

  say ""
  if [ -f "$flag" ]; then
    ok "已完成下载，服务已关闭、本机防火墙规则已收回"
  else
    info "未检测到下载（超时或已中断），服务已关闭、本机防火墙规则已收回"
  fi
  cleanup_serve
  trap - INT TERM
  pause_key
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

  local outroot="$DIST_DIR"
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
  fails="$(ssh_unit_logs --since "24 hours ago" | grep -cE 'Failed|Invalid user' || true)"
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
  local mode="$1" authlines
  [ -f "$SSHD_CONF" ] || return 1
  [ -f "${SSHD_CONF}.igtunnel.bak" ] || cp -a "$SSHD_CONF" "${SSHD_CONF}.igtunnel.bak"
  sed -i "/^${MARK_BEGIN}$/,/^${MARK_END}$/d" "$SSHD_CONF"

  # ★ 这个 Match 块在【两种状态】下都要写，不能只在开口令时写。
  #
  #   只写「开」的那一份，等于把 tun 的认证方式交给全局设置去决定。而绝大多数
  #   发行版的全局默认是 PasswordAuthentication yes —— 于是：
  #     · 安全上：tun 这个账号即使没开口令，也仍然接受密码认证，
  #       而它的密码只是 otp_disable 塞进去的一串随机值，属于"没人猜得出"
  #       而不是"不允许猜"，留了一个不必要的攻击面；
  #     · 体验上（更烦人）：客户端证书一旦不被接受，sshd 会顺手把 password
  #       也列为可选项，ssh 就会去问密码 —— 用户明明没开口令，
  #       却被弹窗要求"请输入管理员给你的今日口令"，无口令可输。
  #
  #   显式写死，两边的行为就都是确定的。
  if [ "$mode" = "on" ]; then
    # 口令开启：证书 + 口令，两个都要（缺一不可）
    authlines="    AuthenticationMethods publickey,password
    PasswordAuthentication yes
    KbdInteractiveAuthentication yes"
  else
    # 口令关闭：只认证书。写明 AuthenticationMethods publickey 之后，
    # 认证失败时 sshd 只会回 "Permission denied (publickey)."，
    # 不会把 password 列进去，客户端据此就能判断"不该问口令"。
    authlines="    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no"
  fi

  cat >> "$SSHD_CONF" <<EOF

$MARK_BEGIN
Match User $TUNNEL_USER
$authlines
    PermitTTY no
    X11Forwarding no
    AllowAgentForwarding no
$MARK_END
EOF
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
  say "  ${C_D}--- sshd_config 末尾的 Match 块（约束 $TUNNEL_USER 账号的认证方式）---${C_0}"
  if grep -q "^${MARK_BEGIN}$" "$SSHD_CONF" 2>/dev/null; then
    sed -n "/^${MARK_BEGIN}$/,/^${MARK_END}$/p" "$SSHD_CONF" | sed 's/^/      /'
    if sed -n "/^${MARK_BEGIN}$/,/^${MARK_END}$/p" "$SSHD_CONF" \
         | grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+no'; then
      say "      ${C_G}→ 该账号只认证书，不接受密码${C_0}"
    else
      say "      ${C_Y}→ 该账号接受「证书 + 每日口令」${C_0}"
    fi
  else
    warn "（缺失）$TUNNEL_USER 账号会沿用全局认证设置"
    info "  建议回菜单 1 重新执行一次安装（会把这一段补上）"
  fi
  say ""
  say "  ${C_D}--- systemd 定时器 ---${C_0}"
  systemctl is-active igtunnel-otp.timer 2>/dev/null | sed 's/^/      igtunnel-otp.timer: /' || true
  say ""
  hr
  pause_key
}

# 卸载时用的删除闸门。
#
# 卸载是**不可逆**操作，而路径来自变量。一个手滑的变量（比如某个环境变量被
# 覆盖成空串、或者被指到 /root）就是灾难。所以这里对每条路径都过一遍硬性检查，
# 宁可少删、报个错，也绝不多删。
#
# 拆成两个函数是有意的：
#   rm_path_allowed —— **纯判断**，只返回结论，不做任何事。
#   safe_rm_rf      —— 判断通过才真删。
# 这样测试可以拿 /etc 去问"允不允许删"，而**不可能**真的删掉任何东西。
#
# rm_path_allowed 返回码：0=允许 1=空 2=系统目录 3=路径太浅 4=含 .. 或通配符
rm_path_allowed() {
  local p="${1:-}"
  [ -n "$p" ] || return 1
  p="${p%/}"        # 去掉结尾斜杠，避免 "/opt/igtunnel/" 绕过下面的匹配

  case "$p" in
    ""|"/"|"."|".."|"/root"|"/etc"|"/usr"|"/var"|"/opt"|"/home"|"/bin"|"/sbin"|\
    "/lib"|"/lib64"|"/boot"|"/dev"|"/proc"|"/sys"|"/tmp"|"/mnt"|"/media"|"/srv")
      return 2
      ;;
    # 下面这些本身是"两级以上"、会通过层级检查，但删掉等于毁掉系统服务，
    # 所以单独列出来。我们的路径永远是它们的**子目录**（如 /etc/ssh/tunnel-ca），
    # 不会正好等于它们本身 —— 一旦相等，说明变量被改坏了。
    "/etc/ssh"|"/etc/systemd"|"/etc/systemd/system"|"/etc/init.d"|\
    "/usr/local"|"/usr/local/bin"|"/usr/local/sbin"|"/usr/bin"|"/usr/sbin"|\
    "/usr/lib"|"/var/lib"|"/var/log"|"/var/spool")
      return 2
      ;;
  esac

  # 必须至少两级（/opt/igtunnel 这种），挡住 "/x" 之类的误配
  case "$p" in
    /*/*) : ;;
    *) return 3 ;;
  esac

  case "$p" in
    *..*) return 4 ;;
    *[\*\?]*) return 4 ;;
  esac

  return 0
}

# 返回值：0 = 删了；2 = 本来就不存在（不算错）；1 = 拒绝或失败
safe_rm_rf() {
  local path="$1" what="${2:-}" p rc

  rm_path_allowed "$path"; rc=$?
  if [ "$rc" != 0 ]; then
    case "$rc" in
      1) err "拒绝删除：路径为空（${what}）" ;;
      2) err "拒绝删除系统目录：${path}（${what}）" ;;
      3) err "拒绝删除过浅的路径：${path}（${what}）" ;;
      4) err "拒绝删除含 .. 或通配符的路径：${path}（${what}）" ;;
      *) err "拒绝删除：${path}（${what}）" ;;
    esac
    return 1
  fi

  p="${path%/}"
  if [ ! -e "$p" ] && [ ! -L "$p" ]; then
    return 2
  fi

  rm -rf -- "$p" || { err "删除失败：${p}"; return 1; }
  return 0
}

do_uninstall() {
  say ""
  say "${C_R}卸载${C_0}"
  hr

  # ---- 先算清楚会删什么，让用户在按确认之前就看得见 ----
  local n_pkg=0 sz_pkg="" pkg_note=""
  if [ -d "$DIST_DIR" ]; then
    n_pkg="$(find "$DIST_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
    sz_pkg="$(du -sh "$DIST_DIR" 2>/dev/null | awk '{print $1}')"
    [ -n "$sz_pkg" ] && pkg_note="，${sz_pkg}"
  fi

  info "会删除（本脚本创建的全部内容）："
  say  "      · 隧道 CA 与所有客户端密钥    ${C_D}${CA_DIR}${C_0}"
  say  "      · 状态目录 / 端口快照 / 口令密钥 ${C_D}${STATE_DIR}${C_0}"
  say  "      · sshd 配置片段               ${C_D}${DROPIN}${C_0}"
  say  "      · sshd_config 末尾的 Match 块"
  say  "      · 口令刷新定时器"
  say  "      · 隧道账号 ${C_B}${TUNNEL_USER}${C_0}（连同它的家目录）"
  if [ "$n_pkg" != 0 ]; then
    say "      · ${C_Y}已生成的授权包（里面含私钥）${C_0}"
    say "        ${C_D}${DIST_DIR}（${n_pkg} 个文件${pkg_note}）${C_0}"
  fi
  if [ -d "$IGT_OPT_DIR" ]; then
    say "      · 客户端模板还原目录          ${C_D}${IGT_OPT_DIR}${C_0}"
  fi
  say ""
  info "不会动：你自己的 SSH 配置与密钥，以及任何不是本脚本创建的文件。"
  say ""
  confirm "确认卸载？" || { info "已取消，没有改动任何东西"; return 0; }

  # ---- 逐个删除，并如实报告 ----
  local removed=0 refused=0

  sed -i "/^${MARK_BEGIN}$/,/^${MARK_END}$/d" "$SSHD_CONF" 2>/dev/null
  rm -f "$DROPIN" 2>/dev/null && removed=$((removed + 1))

  systemctl disable --now igtunnel-otp.timer >/dev/null 2>&1
  rm -f "$SYSTEMD_DIR/igtunnel-otp.service" "$SYSTEMD_DIR/igtunnel-otp.timer"
  systemctl daemon-reload 2>/dev/null

  rm -f "$INSTALLED_CTL" 2>/dev/null && removed=$((removed + 1))

  for spec in "$CA_DIR|隧道 CA 与客户端密钥" \
              "$STATE_DIR|状态目录与快照" \
              "$DIST_DIR|已生成的授权包（含私钥）" \
              "$IGT_OPT_DIR|客户端模板还原目录"; do
    local path="${spec%%|*}" what="${spec#*|}"
    safe_rm_rf "$path" "$what"
    case $? in
      0) removed=$((removed + 1)) ;;
      2) : ;;                                  # 本来就没有，跳过
      *) refused=$((refused + 1)) ;;
    esac
  done

  if id "$TUNNEL_USER" >/dev/null 2>&1; then
    userdel -r "$TUNNEL_USER" >/dev/null 2>&1
  fi

  # sshd 一定要最后确认一次：只有它真的起来了，才敢删那份备份
  restart_ssh "$TUNNEL_PORT" || true

  say ""
  local svc; svc="$(ssh_service)"
  if systemctl is-active --quiet "$svc"; then
    ok "已卸载（清理了 ${removed} 项）"
    # sshd 健康 → 备份已完成使命，一起清掉，不给机器留垃圾
    if [ -f "${SSHD_CONF}.igtunnel.bak" ]; then
      rm -f "${SSHD_CONF}.igtunnel.bak" 2>/dev/null \
        && info "已一并删除 sshd_config 备份（sshd 运行正常，用不上了）"
    fi
  else
    warn "已卸载，但 sshd 现在不是 active！"
    warn "备份保留在 ${SSHD_CONF}.igtunnel.bak —— 用它可以恢复："
    info "  cp ${SSHD_CONF}.igtunnel.bak ${SSHD_CONF} && systemctl restart $svc"
  fi

  [ "$refused" != 0 ] && warn "有 ${refused} 项因为安全检查被拒绝删除，请手工确认。"

  say ""
  info "顺带提醒：家人电脑上那份客户端文件夹还在（里面是私钥）。"
  info "如果不再需要，记得让她把整个文件夹删掉 —— 服务端这边已经不留任何副本了。"
}

# 菜单 17：清理旧的授权包（不动服务，只删包）
#
# 为什么单独做一项：授权包是「一次性」的东西 —— 每签发/续期一次，就往
# $DIST_DIR 里丢一个新包，而【每个包里都含一份私钥】。传完之后留在服务器上
# 没有任何用处，只是风险。卸载会一起清掉（菜单 15），但如果你打算长期用、
# 不想卸载，就需要一个「只清包、不动服务」的入口。
#
# 只删 $DIST_DIR 里的内容，目录本身保留（下次打包还要往里写）。
do_clean_dist() {
  say ""
  say "${C_B}清理旧的授权包${C_0}"
  hr

  if [ ! -d "$DIST_DIR" ]; then
    info "没有需要清理的（${DIST_DIR} 不存在）"
    return 0
  fi

  local n sz
  n="$(find "$DIST_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$n" = 0 ]; then
    info "没有需要清理的（${DIST_DIR} 是空的）"
    return 0
  fi
  sz="$(du -sh "$DIST_DIR" 2>/dev/null | awk '{print $1}')"

  info "${DIST_DIR} 里有 ${n} 项，共 ${sz:-?}（新的在最上面）："
  say ""
  # 和菜单 16 一样按时间倒序。ls -1t 每行一个名字，名字里带空格也不会被拆开。
  local _e _s
  ls -1t "$DIST_DIR" 2>/dev/null | while IFS= read -r _e; do
    [ -n "$_e" ] || continue
    _s="$(du -sh "$DIST_DIR/$_e" 2>/dev/null | awk '{print $1}')"
    say "      $(printf '%-7s' "${_s:-?}")  ${_e}"
  done

  say ""
  warn "这些包里含私钥。已经发给家人、确认能连上的，就没必要再留在服务器上。"
  say ""
  confirm "全部删除？" || { info "已取消，没有改动任何东西"; return 0; }

  # 整目录走同一套安全闸：路径不对就拒绝，宁可不删。
  local rc
  safe_rm_rf "$DIST_DIR" "已生成的授权包（含私钥）"; rc=$?
  case "$rc" in
    0)
      mkdir -p "$DIST_DIR" 2>/dev/null
      ok "已清理 ${n} 项（${DIST_DIR} 目录本身保留，下次打包还要用）"
      ;;
    2)
      info "目录已经不在了，无需清理"
      ;;
    *)
      err "清理失败 —— 一个都没删。"
      ;;
  esac

  say ""
  info "注意：这只是删掉服务器上的副本，不影响任何【已经签发出去的证书】。"
  info "家人电脑上的客户端照常用，除非你在菜单 11 里吊销了授权。"
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
  recent_fail="$(ssh_unit_logs --since '24 hours ago' 2>/dev/null | grep -cE 'Failed|Invalid user' || true)"
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
  say "   ${C_B}15${C_0}) 完全卸载  ${C_D}（含已生成的授权包，不留副本）${C_0}"
  say "   ${C_B}16${C_0}) 把授权包传给自己 ${C_D}（HTTP 链接 / SSH 命令）${C_0}"
  say "   ${C_B}17${C_0}) 清理旧的授权包 ${C_D}（只删包，不动服务）${C_0}"
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
      16) do_serve_package; continue ;;
      17) do_clean_dist; pause_key ;;
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

单文件说明：
  client/ 模板已内嵌在本脚本里。只传这一个 tunnelctl.sh 也能正常打包，
  脚本会把它还原到 /opt/igtunnel/client。

卸载（菜单 15）会删除本脚本创建的全部内容，包括：
  CA 与客户端密钥、状态目录、sshd 配置片段、Match 块、定时器、隧道账号、
  以及 /root/igtunnel-dist 里【已经生成好的授权包】—— 那些包里含私钥，
  不会给你留副本。你自己的 SSH 配置和密钥一律不动。

不想卸载、只想清掉攒下来的授权包？用菜单 17（只删包，服务照常运行）。
EOF
    exit 0
    ;;
esac

need_root
load_conf
menu
