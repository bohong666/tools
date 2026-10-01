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
#  2) 本脚本只往三处写 sshd 相关文件：
#       /etc/ssh/sshd_config.d/10-tunnel.conf        （整文件由本脚本管理）
#       /etc/ssh/sshd_config 末尾的 Match 块         （用 BEGIN/END 标记圈起来）
#       /etc/systemd/system/ssh.socket.d/10-tunnel.conf
#         └─ 只在【socket 激活】模式下才写（Ubuntu 22.10+ 默认）。
#            那种模式下 sshd_config 的 Port 指令不生效，端口必须写这里。
#     动手前自动备份 sshd_config 到 sshd_config.igtunnel.bak。
#  3) 每次重启 sshd 之前都会「快照」当前【实际在监听】的端口；重启之后逐项核对：
#     原有端口是否都还在、新端口是否真的起来了、sshd 是否还活着、
#     其他服务的监听是否被波及。任何一项不对就【自动回滚】并恢复 sshd。
#     ★ 注意用的是内核视角（ss / ssh.socket），不是 `sshd -T` ——
#        socket 激活时 `sshd -T` 报的是配置里的端口，和真正 bind 的可以完全不一样。
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
# ★ systemd socket 激活模式下的监听端口配置（Ubuntu 22.10+ 默认走这条路）。
#   做成变量同样是为了让测试能把它指向沙盒，而不是真去动 /etc/systemd/system。
SOCKET_DROPIN_DIR="${SOCKET_DROPIN_DIR:-/etc/systemd/system/ssh.socket.d}"
SOCKET_DROPIN="$SOCKET_DROPIN_DIR/10-tunnel.conf"
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

# ★ 脚本版本。改这个脚本时请顺手更新（格式：YYYY.MM.DD-当日序号）。
#
# 为什么值得占一行：你经常要把新脚本传到一台【已经有旧脚本】的机器上覆盖，
# 而覆盖成功与否、跑的是哪一版，以前完全没有办法确认 —— 只能靠"我记得传过了"。
# 现在：菜单最下面一行会显示它，`--version` 也能直接问。
SCRIPT_VER="2026.10.01-1"

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
  # ★ 为什么不用 `systemctl list-unit-files | grep -q`：
  #   本脚本第 37 行是 `set -uo pipefail`。grep -q 一命中就退出，此时 systemctl
  #   还在往管道里写 → 收到 SIGPIPE → 退出码 141 → pipefail 让整条管道返回 141
  #   → if 判为「失败」。实测在 Oracle 的 Ubuntu 上就是这里返回了 sshd（真实是 ssh），
  #   进而让 ssh_socket_activated 的守卫短路，整条 socket 激活处理链路被关掉，
  #   隧道端口写进了不生效的文件 —— 客户端拿到 Connection refused。
  #
  # 改用【退出码探测】，全程不解析任何文本：
  #   · 单元不存在 → 1；被 mask → 0（退化配置，后续判据会失败，不会误判）
  #   · Debian 上 ssh.service 带 Alias=sshd.service，反过来问 sshd 也返回 0
  #     → 所以【必须先问 ssh】。这个顺序是有意的，别调换。
  if systemctl cat ssh.service >/dev/null 2>&1; then
    printf 'ssh'
  else
    printf 'sshd'
  fi
}

# 内核证据：是否存在某个 TCP LISTEN 端口【同时】被 sshd 和 systemd(pid=1) 持有。
#
# 返回 0 = 有证据；1 = 无证据；2 = 无法判断（ss 读不到 / 看不到进程名）
#
# ★ 这是【完全不依赖 systemd 任何文本输出】的兜底判据。socket 激活时监听 fd
#   归 systemd(pid=1) 所有，sshd 被拉起后继承同一个 fd，于是 `ss -p` 的同一行
#   会同时列出 sshd 和 systemd(pid=1) —— 这是内核事实，改不了也骗不了。
#
# ★ 全程不许有"提前退出"的消费者：grep -q / head / awk 中途 exit 都会让上游
#   吃 SIGPIPE，在 pipefail 下污染退出码（本脚本刚因为这个栽过一次）。
#   所以 awk 只在 END 里给退出码。
#
# ★ 端口号做全等比较（取最后一个 : 之后的整段），22 不会匹配到 2222；
#   也【不允许跨端口拼凑】—— 22 上只有 systemd、2222 上只有 sshd 不算证据。
ssh_socket_kernel_evidence() {
  local out
  out="$(ss -tlnpH 2>/dev/null)" || return 2
  [ -n "$out" ] || return 2
  case "$out" in
    *'users:('*) : ;;
    *) return 2 ;;   # 非 root 看不到进程名 —— 证据不足，不许武断下结论
  esac
  printf '%s\n' "$out" | awk '
    {
      n = split($4, a, /:/); port = a[n]
      if (port !~ /^[0-9]+$/) next
      if ($0 ~ /users:\(\(.*"systemd",pid=1[,)]/)   sysd[port]  = 1
      if ($0 ~ /users:\(\(.*"sshd",pid=[0-9]+[,)]/) sshdp[port] = 1
    }
    END { for (p in sysd) if (p in sshdp) exit 0; exit 1 }'
}

# ============================================================
#  socket 激活（Ubuntu 22.10+ 默认）—— 本脚本最容易漏、后果最严重的坑
# ============================================================
#
# Ubuntu 22.10 起，sshd 默认由 systemd 的 ssh.socket 拉起。此时：
#
#   · 监听端口归【ssh.socket】管，sshd_config 里的 Port 指令【完全不生效】
#   · 但 `sshd -T` 仍然会把它读到的 Port 原样报出来 —— 配置"看起来是对的"
#   · 于是：配置里写着 2222，内核那边一个端口都没多
#     → 家人的客户端收到 Connection refused
#
# 实测踩过（Oracle 上的 Ubuntu 实例）：
#     sudo sshd -T | grep ^port     →  port 22 / port 2222   ← sshd 以为的
#     sudo ss -tlnp | grep :2222    →  （空）                 ← 内核实际的
#
# 判据：看 LISTEN 那行 fd 的持有者 —— 是 systemd(pid=1) 就是 socket 激活。
# 教训：`sshd -T` 说的是"sshd 以为的"，`ss` 说的才是"内核在做的"。
#       两者不一致时，看谁持有 fd。
ssh_socket_activated() {
  # ★ 这里【故意】没有 `[ "$(ssh_service)" = "ssh" ] || return 1` 那个守卫。
  #   它依赖 ssh_service 的返回值，而 ssh_service 一旦判错（曾经因为 SIGPIPE
  #   返回过 sshd），守卫就把整条 socket 激活链路静默关掉 —— 实测故障就是
  #   这两层叠加的结果。守卫本身也是多余的：RHEL 系根本不装 ssh.socket 单元，
  #   下面两条 is-active / is-enabled 天然返回非 0。
  systemctl is-active  --quiet ssh.socket 2>/dev/null && return 0
  systemctl is-enabled --quiet ssh.socket 2>/dev/null && return 0
  # 兜底：内核证据。就算 systemd 那边完全问不出来，只要内核里能看到
  # 「sshd 和 systemd(pid=1) 同时持有一个端口」，那就是 socket 激活。
  ssh_socket_kernel_evidence && return 0
  return 1
}

# ssh.socket 当前真正在监听的端口（问 systemd，权威）
socket_listen_ports() {
  local raw ports
  raw="$(systemctl show ssh.socket -p Listen 2>/dev/null)" || return 1
  [ -n "$raw" ] || return 1
  ports="$(printf '%s\n' "$raw" | sed -E 's/^Listen=//' | tr ' ' '\n' \
    | sed -E 's/^.*[:.]([0-9]+)$/\1/' | grep -E '^[0-9]+$' | sort -un)"
  # ★ 必须检查结果非空。`systemctl show` 在 socket 没监听任何东西时
  #   会返回 "Listen="（非空字符串），只判 raw 非空会漏过去，
  #   然后调用方拿到一个"成功但空"的结果 —— 又是一种静默失败。
  [ -n "$ports" ] || return 1
  printf '%s\n' "$ports"
}

# 从现有 ssh.socket 的 Listen 里取出地址前缀（如 0.0.0.0 / [::]）。
# 目的：沿用系统原本的绑定方式，不自己发明 IPv6 —— 在没开 IPv6 的机器上
# 硬写 [::]:port 会让 socket 起不来，那样 SSH 就真的断了。
socket_addr_prefixes() {
  local raw
  raw="$(systemctl show ssh.socket -p Listen 2>/dev/null | sed -E 's/^Listen=//')"
  [ -n "$raw" ] || return 0
  printf '%s\n' "$raw" | tr ' ' '\n' | grep -E '[:.]' \
    | sed -E 's/[:.]([0-9]+)$//' | grep -v '^$' | sort -u
}

# sshd 真正在监听的端口（★ 内核视角，校验必须用这个）
#
# socket 激活模式下要格外小心，这里有个"看着能跑、其实会锁死自己"的陷阱：
#
#   · 监听 fd 归 systemd(pid=1) 所有，已触发的 sshd 实例自己不再 listen，
#     所以【不能】像传统模式那样按进程名筛 `ss -p | grep sshd`。
#   · 那改成 grep systemd 行不行？更糟 —— `ss -p` 只写进程名，
#     systemd-resolved(53)、systemd-timesyncd 和持有 ssh.socket 的 systemd
#     长得一模一样。按名字筛会把别人的端口当成我们的，最坏情况是往
#     ssh.socket 的 drop-in 里写一个 53，socket 直接起不来 —— 那才是真的断连。
#
# 做法：拿 ssh.socket 配置里的端口，逐个去内核里核对，只保留【真的在监听】的。
#       这样只会少报、绝不会多报。少报的代价是回滚（安全），
#       多报的代价是锁死自己（不可接受）。
ssh_real_ports() {
  if ssh_socket_activated; then
    local cfg kern p out=""
    cfg="$(socket_listen_ports)" || return 1
    kern="$(ss -tlnpH 2>/dev/null | awk '{print $4}' \
      | sed -E 's/^.*[:.]([0-9]+)$/\1/' | grep -E '^[0-9]+$' | sort -un)"
    # 内核视角读不到 → 宁可判失败，也不拿配置文件糊弄自己
    [ -n "$kern" ] || return 1
    for p in $cfg; do
      printf '%s\n' "$kern" | grep -qx "$p" && out="${out}${p} "
    done
    out="$(printf '%s\n' $out | grep -E '^[0-9]+$' | sort -un)"
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
    return 0
  fi
  local k
  k="$(ss -tlnpH 2>/dev/null | grep -i 'sshd')"
  [ -n "$k" ] || return 1
  printf '%s\n' "$k" | awk '{print $4}' \
    | sed -E 's/^.*[:.]([0-9]+)$/\1/' | grep -E '^[0-9]+$' | sort -un
}

# 写 ssh.socket 的 drop-in（socket 激活模式下，真正决定监听端口的地方）。
#
# ★ 那行【空的】`ListenStream=` 是必须的：systemd 的列表型指令是累加的，
#   不先清空就会把新端口"追加"到原来的 22 上 —— 你以为只监听 2222，
#   实际两个都在监听，而且不报任何错、不留任何提示。
build_socket_dropin() {
  local ports="$1" prefixes
  [ -n "$(printf '%s' "$ports" | tr -d ' ')" ] || { err "socket 端口列表为空，拒绝写入"; return 1; }

  mkdir -p "$SOCKET_DROPIN_DIR" || { err "建不了目录 $SOCKET_DROPIN_DIR"; return 1; }

  prefixes="$(socket_addr_prefixes)"
  {
    echo "# 由 tunnelctl.sh 生成，请勿手工编辑"
    echo "#"
    echo "# 你的 sshd 由 systemd 的 ssh.socket 拉起（Ubuntu 22.10+ 默认）。"
    echo "# 这种模式下 /etc/ssh/sshd_config 里的 Port 指令【不生效】，"
    echo "# 监听端口只认这里。所以要加端口，必须写进这个文件。"
    echo "#"
    echo "# 第一行空赋值是【必须的】：systemd 列表型指令是累加的，"
    echo "# 不清空的话新端口只会被追加，而不是替换掉原来的。"
    echo "[Socket]"
    echo "ListenStream="
    for p in $ports; do
      if [ -n "$prefixes" ]; then
        printf '%s\n' $prefixes | while IFS= read -r _a; do
          [ -n "$_a" ] && echo "ListenStream=${_a}:${p}"
        done
      else
        echo "ListenStream=${p}"
      fi
    done
  } > "$SOCKET_DROPIN" || { err "写不了 $SOCKET_DROPIN"; return 1; }
  chmod 644 "$SOCKET_DROPIN" 2>/dev/null
  return 0
}

# 把「当前真实在监听的端口 − 旧端口 + 新端口」同步进 ssh.socket。
# 非 socket 激活时什么都不做、返回 0（空操作）—— 这样调用方可以无脑 `&&` 串起来。
#
# ★ 一定要带上现有端口：漏掉登录口 = 把自己关在门外。
sync_socket_ports() {
  local newp="$1" oldp="${2:-}" p ports="" cur
  ssh_socket_activated || return 0

  # ★★ 读不到当前端口就【绝对不许写】★★
  #   下面这段是"当前端口 − 旧端口 + 新端口"。如果当前端口读成了空，
  #   结果就只剩新端口一个 —— 登录口会被静默摘掉，写完重启 socket，
  #   你当前这条连接还活着（已建立的连接不受影响），但下次登录就上不去了。
  #   这是本脚本里唯一能真正把人关在门外的路径，所以在这里硬拦一道。
  if ! cur="$(ssh_real_ports 2>/dev/null)" || [ -z "$cur" ]; then
    err "读不到 ssh.socket 当前正在监听的端口，拒绝改写配置（怕把你的登录口弄丢）"
    err "  请先手工确认这两条："
    err "    systemctl show ssh.socket -p Listen"
    err "    sudo ss -tlnp | grep -E 'systemd|sshd'"
    return 1
  fi

  for p in $cur; do
    [ -n "$p" ] || continue
    [ -n "$oldp" ] && [ "$p" = "$oldp" ] && continue
    [ "$p" = "$newp" ] && continue
    ports="${ports}${p} "
  done
  [ -n "$newp" ] && ports="${ports}${newp}"
  ports="$(printf '%s\n' $ports | grep -E '^[0-9]+$' | sort -un)"
  [ -n "$ports" ] || { err "socket 端口列表为空，拒绝写入"; return 1; }
  build_socket_dropin "$ports" || return 1
  info "已同步 ssh.socket 端口列表：$(printf '%s ' $ports)"
  return 0
}

# 安全的 sshd 重启：校验配置 -> 拍快照 -> 重启 -> 逐项核对 -> 不对就回滚。
#
# 参数：
#   $1 = 本次【预期会消失】的端口（换端口 / 卸载时会用到）
#   $2 = 本次【预期会新出现】的端口（安装 / 换端口时用）。
#        这个参数很关键：它专门抓"socket 激活导致 Port 指令静默失效"——
#        配置写了、sshd -T 也认了，但内核那边根本没监听。
restart_ssh() {
  local expected_gone="${1:-}"
  local expected_new="${2:-}"
  local svc; svc="$(ssh_service)"

  if ! sshd -t 2>/tmp/sshd_test_err; then
    err "sshd 配置校验没通过，已放弃重启（没有改动任何运行中的服务）："
    sed 's/^/      /' /tmp/sshd_test_err >&2
    return 1
  fi

  snapshot_ssh

  if ssh_socket_activated; then
    # ★ socket 激活：监听端口归 ssh.socket 管，重启 ssh.service【没有任何用】。
    #   必须先 daemon-reload（让 systemd 重新读 drop-in），再重启 socket。
    #   实测就是这样翻车的：脚本重启了 ssh.service、校验也过了，
    #   但内核那边一个端口都没多，家人拿到 Connection refused。
    if ! systemctl daemon-reload; then
      err "systemctl daemon-reload 失败"
      return 1
    fi
    if ! systemctl restart ssh.socket; then
      err "重启 ssh.socket 失败"
      return 1
    fi
    sleep 1
    # socket 重启后 ssh.service 未必被自动拉起，补一下（已在跑则是空操作）
    systemctl start "$svc" >/dev/null 2>&1 || true
  else
    if ! systemctl restart "$svc"; then
      err "重启 $svc 失败"
      return 1
    fi
  fi
  sleep 1

  if verify_ssh_intact "$expected_gone" "$expected_new"; then
    ok "sshd 已重启，核对通过（实际监听：$(ssh_real_ports | tr '\n' ' '))"
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
U37+MJ7/DwhWqPgAaAEA
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
    # ★ 不用 `| grep -q`：消费者提前退出 → 上游 awk/ss 吃 SIGPIPE →
    #   pipefail 让管道返回 141 → 这里 `return $?` 会把「占用」误判成「空闲」，
    #   脚本就会去绑一个已被占用的端口，白白触发一次回滚。
    #   awk 也【不能】在匹配时提前 exit，必须读完所有输入、只在 END 里给退出码。
    # ★ 端口做全等比较（取最后一个 : 之后的整段），22 不会匹配到 2222。
    ss -tlnH 2>/dev/null | awk -v p="$p" '
      { n = split($4, a, /:/); if (a[n] == p) f = 1 }
      END { exit(f ? 0 : 1) }'
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

# ufw 当前是否处于活动状态。
#
# ★ 为什么不能写 `ufw status | grep -q "Status: active"`：
#   1) ufw 是 Python + gettext 写的，输出跟着 locale 走。中文系统上它打印的
#      是「状态：活动」，英文串必然匹配不上 —— 整个 ufw 分支被静默跳过，
#      用户会以为「脚本没生效」，实际是这一行判断没进来。
#      所以必须 LC_ALL=C 强制英文输出。
#   2) 仍然是「消费者提前退出」那类问题：grep -q 一命中就退出，上游 ufw
#      吃 SIGPIPE，在 pipefail 下污染退出码。这里改用 case 做前缀匹配，
#      全程不引入管道。
#
# 返回 0 = 活动；1 = 未活动 / 没装 / 读不到。
# 读不到时按「未活动」处理：宁可漏调一次 ufw（后面还有 firewalld / iptables
# 兜底），也不要误判成活动去执行一条注定失败的 ufw 命令。
ufw_active() {
  have ufw || return 1
  local out
  out="$(LC_ALL=C ufw status 2>/dev/null)" || return 1
  case "$out" in
    "Status: active"*) return 0 ;;
  esac
  return 1
}

# 放行一个 TCP 端口。stdout 输出"放行了哪些"，返回 0 表示至少放行了一处。
fw_open_port() {
  local port="$1" did=0

  if ufw_active; then
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
  if ufw_active; then
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
  # ★ 内核视角的真实监听端口。校验用这个，不用 sshd -T ——
  #   socket 激活时 sshd -T 报的是配置里的端口，和真正 bind 的可以完全不一样。
  ssh_real_ports     > "$SNAPDIR/real.before"       2>/dev/null || : > "$SNAPDIR/real.before"
  listen_ports_all   > "$SNAPDIR/listen.before"     2>/dev/null || : > "$SNAPDIR/listen.before"
  ssh_service        > "$SNAPDIR/svc.before"        2>/dev/null || true
  info "已拍下改动前的快照（sshd 实际监听：$(tr '\n' ' ' < "$SNAPDIR/real.before")）"
}

# verify_ssh_intact [预期会消失的端口] [预期会新出现的端口]
verify_ssh_intact() {
  local expected_gone="${1:-}" expected_new="${2:-}"
  local svc; svc="$(cat "$SNAPDIR/svc.before" 2>/dev/null || ssh_service)"
  local bad=0 p
  local svc_up=0
  if systemctl is-active --quiet "$svc"; then
    svc_up=1
  fi
  # socket 激活模式下 ssh.service 是"按需拉起"的：如果是从 VPS 厂商的
  # 网页控制台（不是 SSH）在跑这个脚本，ssh.service 可能压根没启动过，
  # 但 ssh.socket 活得好好的、端口也都在监听 —— 这种情况不该判失败。
  if [ "$svc_up" = 0 ] && ssh_socket_activated \
     && systemctl is-active --quiet ssh.socket; then
    svc_up=1
  fi
  if [ "$svc_up" = 0 ]; then
    err "$svc 没有在运行"
    return 1
  fi

  # ★ 用【内核视角】的监听端口核对，不用 `sshd -T`。
  #   socket 激活时 sshd -T 报的是配置里的端口，和真正 bind 的可以完全不一样。
  #   旧版只看 sshd -T，于是"校验通过"而实际上一个端口都没在监听 —— 这个坑
  #   让家人拿到了 Connection refused，却在服务端看起来一切正常。
  local now; now="$(ssh_real_ports || true)"
  if [ -z "$now" ]; then
    err "读不到 sshd 实际监听的端口"
    return 1
  fi

  # 1) 原来【真实在监听】的 sshd 端口，除了预期消失的那个，其余必须还在
  if [ -s "$SNAPDIR/real.before" ]; then
    while read -r p; do
      [ -n "$p" ] || continue
      [ "$p" = "$expected_gone" ] && continue
      if ! printf '%s\n' "$now" | grep -qx "$p"; then
        err "原本在监听的 sshd 端口 ${p} 不见了"
        bad=1
      fi
    done < "$SNAPDIR/real.before"
  fi

  # 2) ★ 预期新出现的端口必须【真的】在监听。
  #    这一步专门抓"socket 激活导致 Port 指令静默失效"这一类失败 ——
  #    以前的校验永远发现不了它，因为配置和 sshd -T 都是"对的"。
  if [ -n "$expected_new" ]; then
    if printf '%s\n' "$now" | grep -qx "$expected_new"; then
      :
    else
      err "隧道端口 ${expected_new} 没有真的在监听（配置写了，但不生效）"
      if ssh_socket_activated; then
        err "  原因：你的 sshd 由 systemd 的 ssh.socket 拉起。这种模式下"
        err "  sshd_config 里的 Port 指令【不生效】，端口必须写进 ssh.socket。"
        err "  排查用的三条命令："
        err "    systemctl cat ssh.socket | grep -i listenstream"
        err "    ls -l ${SOCKET_DROPIN_DIR}/"
        err "    sudo ss -tlnp | grep ':${expected_new}'"
      fi
      bad=1
    fi
  fi

  # 3) 不属于 sshd 的监听端口不应该因为我们而消失（例如 Xray 的 443）
  local before_now sshd_before now_all
  before_now="$(cat "$SNAPDIR/listen.before" 2>/dev/null || true)"
  sshd_before="$(cat "$SNAPDIR/real.before" 2>/dev/null || true)"
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
  # ★ socket 激活时，隧道端口是写在 ssh.socket 里的 —— 不摘掉的话，
  #   回滚之后那个端口还在监听（虽然 CA 已经不可用，但没必要留着）。
  if [ -f "$SOCKET_DROPIN" ]; then
    mv -f "$SOCKET_DROPIN" "${SOCKET_DROPIN}.failed.$(date +%Y%m%d%H%M%S)" 2>/dev/null
  fi
  sed -i "/^${MARK_BEGIN}$/,/^${MARK_END}$/d" "$SSHD_CONF" 2>/dev/null
  if ssh_socket_activated; then
    systemctl daemon-reload 2>/dev/null
    systemctl restart ssh.socket 2>/dev/null
    systemctl start "$svc" >/dev/null 2>&1 || true
  else
    systemctl restart "$svc" 2>/dev/null
  fi
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
    ok "sshd 配置里的端口：$(printf '%s ' $cur_ports)"
    if printf '%s\n' $cur_ports | grep -qx '22'; then
      info "其中含 22 → 本脚本不会改变你平时的登录端口"
    else
      info "你的 SSH 不在 22 上 —— 没问题。脚本会把上面这些端口【原样保留】，只额外加隧道端口。"
    fi
  else
    err "sshd -T 解析失败，sshd 配置可能已有问题，先修好再来"
    fail=1
  fi

  # --- socket 激活：最容易漏、后果最严重的一种情况 ---
  if ssh_socket_activated; then
    local real_ports
    real_ports="$(ssh_real_ports 2>/dev/null || true)"
    warn "你的 sshd 是【systemd socket 激活】模式（Ubuntu 22.10+ 默认）"
    info "  → 监听端口由 ssh.socket 决定，${SSHD_CONF} 里的 Port 指令【不生效】"
    info "  → 真正在监听：$(printf '%s ' $real_ports)"
    info "  脚本会同时写 ${SOCKET_DROPIN}，并重启 ssh.socket —— 这样才能真的加上隧道端口。"
    if [ "$(printf '%s ' $cur_ports | tr -d ' ')" != "$(printf '%s ' $real_ports | tr -d ' ')" ]; then
      warn "  ⚠ 配置里的端口和实际监听的不一致！"
      info "     配置：$(printf '%s ' $cur_ports)"
      info "     实际：$(printf '%s ' $real_ports)"
      info "     这正是 socket 激活造成的 —— 写 sshd_config 不会改变实际监听端口。"
    fi
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

  # ★★ 光写 sshd_config 不够 ★★
  # Ubuntu 22.10+ 默认由 systemd 的 ssh.socket 拉起 sshd，此时 sshd_config 里的
  # Port 指令【不生效】—— 监听端口只认 ssh.socket。只写上面那份，结果就是
  # 「配置写着 2222、sshd -T 也说 2222，但内核那边一个端口都没多」，
  # 家人的客户端收到 Connection refused。
  #
  # 所以这里必须把【当前真实在监听的端口 ∪ 隧道端口】写进 ssh.socket 的 drop-in。
  # 注意要带上现有端口 —— 漏掉登录口就等于把自己关在门外。
  if ssh_socket_activated; then
    if sync_socket_ports "$TUNNEL_PORT" "$prev_port"; then
      ok "已写入 $SOCKET_DROPIN"
      info "  （你的 sshd 由 ssh.socket 拉起，端口必须写这里才生效）"
    else
      warn "写 ssh.socket 配置失败 —— 隧道端口很可能不会真的监听！"
    fi
  fi

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
  # 第二个参数是"预期新出现的端口" —— 核对时如果它没真的监听，直接判失败并回滚。
  restart_ssh "$prev_port" "$TUNNEL_PORT" || return 1

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

  # ★ 用退出码探测，不用 `systemctl list-unit-files | grep -q`（SIGPIPE 陷阱，
  #   见 ssh_service 上面的说明）。这里判错的后果比 SSH 那处更重：会漏掉停用
  #   sslh.socket，导致 sslh 与 socket 争抢 443 起不来，而脚本已经把用户
  #   原有的 443 服务停掉了 —— 等于把代理打挂。
  if systemctl cat sslh.socket >/dev/null 2>&1; then
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
  sync_socket_ports "$ssh_port" "$old_tunnel_port" || true
  save_conf

  if restart_ssh "$old_tunnel_port" "$ssh_port"; then
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
  # ★ 必须把「实际监听」和「配置里写的」分开显示。
  #   socket 激活时两者会不一致，而那个不一致就是故障本身 ——
  #   只显示其中一个，用户会以为一切正常。
  local _real _cfg
  _real="$(ssh_real_ports 2>/dev/null | tr '\n' ' ' || true)"
  _cfg="$(sshd_ports 2>/dev/null | tr '\n' ' ' || true)"
  if ssh_socket_activated; then
    say "  模式          : ${C_Y}systemd socket 激活${C_0}（ssh.socket 决定端口）"
    say "  ssh.socket 配置: $SOCKET_DROPIN"
    say "  实际在监听    : ${C_G}${_real:-（读不到）}${C_0}"
    if [ -n "$_cfg" ] && [ "${_real% }" != "${_cfg% }" ]; then
      say "  sshd_config 里 : ${C_R}${_cfg}${C_0}  ${C_D}← 不生效！${C_0}"
    fi
  else
    say "  实际在监听    : ${C_G}${_real:-（读不到）}${C_0}"
  fi
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
  if ssh_socket_activated; then
    say  "      · ssh.socket 端口配置          ${C_D}${SOCKET_DROPIN}${C_0}"
    say  "        ${C_D}（你的 sshd 由 socket 激活，隧道端口写在这里）${C_0}"
  fi
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
  # socket 激活时隧道端口写在 ssh.socket 的 drop-in 里，也要摘掉，
  # 否则卸载后那个端口还继续监听（没必要留着）。
  rm -f "$SOCKET_DROPIN" 2>/dev/null && removed=$((removed + 1))

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
  sync_socket_ports "$np" "$old" || true    # socket 激活时才做事
  save_conf
  if restart_ssh "$old" "$np"; then
    ok "隧道端口已改为 ${np}"
    info "重新打包：菜单 2，输入同名客户端即可（复用旧密钥，只更新配置）"
  else
    TUNNEL_PORT="$old"; CLIENT_PORT="$old"; save_conf
    warn "换端口失败，正在尝试恢复原来的隧道配置..."
    if build_dropin "$old" && sync_socket_ports "$old" "$np" && restart_ssh "" "$old"; then
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
  say "   ${C_D}脚本版本 ${SCRIPT_VER}${C_0}"
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
  --version|-V)
    # 只报版本，连 root 都不需要。用来确认"传上去的到底是不是新版"。
    printf 'tunnelctl.sh %s\n' "$SCRIPT_VER"
    exit 0
    ;;
  --help|-h)
    cat <<EOF
Instagram 隧道 · 服务端控制台

  sudo bash $0                进入交互菜单
  sudo bash $0 --check        只读环境预检（绝不改动任何东西）
  sudo bash $0 --diag         只读健康检查 / 被封诊断
  sudo bash $0 --version      只报脚本版本（不需要 root）
  sudo bash $0 --otp-refresh  仅刷新今日口令（供定时器调用）

当前版本：$SCRIPT_VER
  （覆盖上传新脚本后，用 --version 或菜单最下面那行确认真的换上了）

安全说明：
  本脚本从不读写你的 Xray / V2Ray / Nginx 配置。
  它只往三处写 sshd 相关文件：sshd_config.d/10-tunnel.conf、
  sshd_config 末尾的 Match 块、以及 socket 激活模式下的 ssh.socket.d/10-tunnel.conf
  （Ubuntu 22.10+ 默认是 socket 激活，那种模式下 sshd_config 的 Port 指令不生效，
   端口必须写在 ssh.socket 里）。
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
