#!/usr/bin/env bash
set -eo pipefail
exec </dev/tty >/dev/tty 2>/dev/tty || true

# ===========================
# 配置
# ===========================
METRIC="${METRIC:-1024}"
TEST_TARGETS="${TEST_TARGETS:-2606:4700:4700::1111 2001:4860:4860::8888}"
GEO="${GEO:-1}"
BACKUP_FILE="/usr/local/bin/v6.route.backup"

# ===========================
# 工具函数
# ===========================
get_srcs() {
  local dev="$1"
  ip -6 addr show dev "$dev" 2>/dev/null |
    sed -n "s/^[[:space:]]*inet6[[:space:]]\([^/]*\)\/.* scope global.*/\1/p"
}

backup_route() {
  echo "正在备份当前 IPv6 默认路由..."
  ip -6 route show default > "$BACKUP_FILE" 2>/dev/null || true
  echo "备份完成：$BACKUP_FILE"
}

restore_route() {
  if [ ! -f "$BACKUP_FILE" ]; then
    echo "没有找到备份文件，无法恢复。"
    return 1
  fi

  echo "正在恢复初始 IPv6 路由..."
  ip -6 route flush default || true

  while IFS= read -r line; do
    [ -n "$line" ] && ip -6 route add $line || true
  done < "$BACKUP_FILE"

  echo "恢复完成。"
}

declare -A GEO_CACHE

dns_ok() {
  getent ahosts ifconfig.co >/dev/null 2>&1 || return 1
  return 0
}

geo_for_src() {
  local src="$1"
  [ "$GEO" = "0" ] && { echo "--"; return; }
  [ -n "${GEO_CACHE[$src]+x}" ] && { echo "${GEO_CACHE[$src]}"; return; }

  command -v curl >/dev/null 2>&1 || { GEO_CACHE[$src]="--"; echo "--"; return; }

  local cc=""
  cc="$(curl -6 -sS --max-time 5 --interface "$src" https://ifconfig.co/country-iso 2>/dev/null | tr -d '\r\n' | head -c 8 || true)"
  if [ -z "$cc" ]; then
    cc="$(curl -6 -sS --max-time 5 --interface "$src" https://ipinfo.io/country 2>/dev/null | tr -d '\r\n' | head -c 8 || true)"
  fi

  cc="$(echo "$cc" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z]//g')"
  [ -z "$cc" ] && cc="--"

  GEO_CACHE[$src]="$cc"
  echo "$cc"
}

# ===========================
# 扫描默认路由
# ===========================
cands_dev=()
cands_gw=()
cands_src=()

parse_defaults() {
  cands_dev=()
  cands_gw=()
  cands_src=()

  local line dev gw src
  while IFS= read -r line; do
    dev="$(echo "$line" | sed -n "s/.* dev \([^ ]*\).*/\1/p")"
    gw="$(echo "$line"  | sed -n "s/.* via \([^ ]*\).*/\1/p")"
    [ -z "$dev" ] && continue
    [ -z "$gw" ] && continue

    while IFS= read -r src; do
      [ -z "$src" ] && continue
      cands_dev+=("$dev")
      cands_gw+=("$gw")
      cands_src+=("$src")
    done < <(get_srcs "$dev" | awk "NF")
  done < <(ip -6 route show default 2>/dev/null | tr -s " " || true)
}

cands_sig() {
  local i s=""
  for i in "${!cands_dev[@]}"; do
    s+="${cands_dev[$i]}|${cands_gw[$i]}|${cands_src[$i]};"
  done
  echo "$s"
}

# ===========================
# 显示当前出口
# ===========================
show_current() {
  echo "当前 IPv6 默认出口："
  local def bestsrc
  def="$(ip -6 route show default 2>/dev/null || true)"
  [ -z "$def" ] && { echo "  (没有 default 路由)"; return; }
  echo "  $def"

  bestsrc="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null |
    sed -n "s/.* src \([^ ]*\).*/\1/p" | head -n1)"

  [ -n "$bestsrc" ] && echo "  (当前路由选择的 SRC: $bestsrc ; 地区: $(geo_for_src "$bestsrc"))"
}

# ===========================
# 列出候选出口
# ===========================
print_list() {
  [ "${#cands_dev[@]}" -eq 0 ] && {
    echo "没有检测到可切换的 IPv6 出口。"
    return 1
  }

  echo "可选 IPv6 出口（地区=国家代码）："
  echo "--------------------------------------------------------------------------"
  printf "%-4s %-6s %-28s %-5s %-28s\n" "ID" "DEV" "GATEWAY" "地区" "SRC"
  echo "--------------------------------------------------------------------------"

  local i tag
  for i in "${!cands_dev[@]}"; do
    tag="$(geo_for_src "${cands_src[$i]}")"
    printf "%-4s %-6s %-28s %-5s %-28s\n" \
      "$((i+1))" "${cands_dev[$i]}" "${cands_gw[$i]}" "$tag" "${cands_src[$i]}"
  done

  echo "--------------------------------------------------------------------------"
  if ! dns_ok; then
    echo "(提示：DNS 可能有问题；若地区显示 --，请检查 /etc/resolv.conf)"
  fi
}

# ===========================
# 测试出口
# ===========================
test_all() {
  parse_defaults
  [ "${#cands_dev[@]}" -eq 0 ] && { echo "没有候选可测试。"; return; }

  echo "测试中（目标：$TEST_TARGETS）"
  local i dev gw src ok t

  for i in "${!cands_dev[@]}"; do
    dev="${cands_dev[$i]}"
    gw="${cands_gw[$i]}"
    src="${cands_src[$i]}"
    ok=0

    ping -6 -c 1 -W 1 -I "$dev" "$gw" >/dev/null 2>&1 && ok=1

    if [ $ok -eq 0 ]; then
      for t in $TEST_TARGETS; do
        ping -6 -c 1 -W 1 -I "$dev" "$t" >/dev/null 2>&1 && { ok=1; break; }
      done
    fi

    if [ $ok -eq 1 ]; then
      echo "  [$((i+1))] OK   dev=$dev via=$gw src=$src 地区=$(geo_for_src "$src")"
    else
      echo "  [$((i+1))] FAIL dev=$dev via=$gw src=$src 地区=$(geo_for_src "$src")"
    fi
  done
}

# ===========================
# 切换出口
# ===========================
switch_to() {
  local id="$1"
  parse_defaults

  case "$id" in
    (*[!0-9]*|"") echo "请输入数字 ID"; return 1;;
  esac

  local idx=$((id-1))
  [ "$idx" -lt 0 ] || [ "$idx" -ge "${#cands_dev[@]}" ] && {
    echo "ID 不存在：$id"
    return 1
  }

  local dev="${cands_dev[$idx]}"
  local gw="${cands_gw[$idx]}"
  local src="${cands_src[$idx]}"

  echo "切换到：ID=$id dev=$dev via=$gw src=$src metric=$METRIC"
  ip -6 route replace default via "$gw" dev "$dev" onlink src "$src" metric "$METRIC"
  echo "完成。"
  show_current
}

# ===========================
# 菜单
# ===========================
menu() {
  echo
  echo "========== IPv6 出口切换 =========="
  echo "0 = 查看当前 IPv6 出口"
  echo "1/2/3... = 切换到对应出口"
  echo "t = 测试所有出口"
  echo "u = 卸载并恢复初始 IPv6 路由"
  echo "q = 退出"
  echo "=================================="
}

# ===========================
# 主程序
# ===========================
main() {
  backup_route
  show_current
  echo

  parse_defaults
  local last_sig
  last_sig="$(cands_sig)"
  print_list || true

  while true; do
    parse_defaults
    local sig
    sig="$(cands_sig)"

    if [ "$sig" != "$last_sig" ]; then
      echo
      echo "(检测到 IPv6 出口变化，已自动刷新列表)"
      print_list || true
      last_sig="$sig"
    fi

    menu
    printf "%s" "请输入你的选择: "

    if ! IFS= read -r ans </dev/tty; then
      echo
      echo "读不到输入，退出。"
      exit 0
    fi

    case "$ans" in
      0) show_current ;;
      t|T) test_all ;;
      u|U) restore_route; exit 0 ;;
      q|Q) echo "退出。"; exit 0 ;;
      *) switch_to "$ans" ;;
    esac
  done
}

main "$@"
