#!/usr/bin/env bash
# ============================================================
# sni-check2.sh  REALITY 伪装域名双栈评估 v2
#
# 与 v1 的区别:
#   1. IPv4 / IPv6 分开测, 不再混在一起 -> 能区分"站点不支持 TLS1.3"
#      和"到该地址族的路径不通"
#   2. 加了握手耗时, 方便按区域挑最近的
#   3. 候选池扩到 30 个, 全部是开源基础设施类站点
#   4. 并发 8 路, 30 个域名约 20~40 秒跑完
#
# 用法:
#   bash sni-check2.sh                  # 用内置候选池
#   bash sni-check2.sh www.a.com b.com  # 只测指定域名
#
# 判定标准 (REALITY 硬性要求):
#   TLS1.3 = 是  且  ALPN = h2  且  握手成功
#   三项同时满足才可用, 否则回落会失败或降级成 TLS1.2, 主动探测一打就穿
# ============================================================
set -u

TIMEOUT=6
PARALLEL=8
TMPD=$(mktemp -d /tmp/snicheck.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT

# Xray 内核会明确警告的高风险伪装域名 (v1 脚本里 xray run -test 会报)
RISKY=" apple.com www.apple.com icloud.com microsoft.com www.microsoft.com \
bing.com www.bing.com adobe.com amazon.com aws.amazon.com cloudflare.com \
www.cloudflare.com google.com www.google.com www.yahoo.com baidu.com qq.com \
taobao.com "

DEFAULT_DOMAINS=(
  www.python.org
  www.mozilla.org
  www.docker.com
  www.spotify.com
  www.kernel.org
  www.debian.org
  www.ubuntu.com
  www.rust-lang.org
  go.dev
  www.postgresql.org
  www.nginx.org
  www.apache.org
  www.w3.org
  www.ietf.org
  www.gitlab.com
  www.elastic.co
  www.hashicorp.com
  www.digitalocean.com
  www.linode.com
  www.vultr.com
  www.speedtest.net
  www.php.net
  www.ruby-lang.org
  www.perl.org
  www.gnu.org
  www.freedesktop.org
  www.gentoo.org
  www.archlinux.org
  www.alpinelinux.org
  www.sqlite.org
)

if [ "$#" -gt 0 ]; then
  DOMAINS=("$@")
else
  DOMAINS=("${DEFAULT_DOMAINS[@]}")
fi

# ---- 解析: 优先 getent(Debian), 退回 dig(macOS/精简系统) ----------------
resolve() {
  local d="$1" fam="$2"
  if command -v getent >/dev/null 2>&1; then
    getent "ahostsv$fam" "$d" 2>/dev/null | awk '{print $1; exit}'
  elif command -v dig >/dev/null 2>&1; then
    if [ "$fam" = "4" ]; then
      dig +short A "$d" 2>/dev/null | grep -E '^[0-9]+\.' | head -1
    else
      dig +short AAAA "$d" 2>/dev/null | grep -E ':' | head -1
    fi
  fi
}

# ---- 测一个地址族: 输出 "结果|毫秒" -------------------------------------
probe() {
  local ip="$1" sni="$2" target t0 t1 ms out t a
  [ -z "$ip" ] && { printf '—|—'; return; }

  case "$ip" in
    *:*) target="[$ip]:443" ;;
    *)   target="$ip:443"   ;;
  esac

  t0=$(date +%s%N)
  out=$(echo | timeout "$TIMEOUT" openssl s_client \
          -connect "$target" -servername "$sni" \
          -tls1_3 -alpn h2 2>&1)
  t1=$(date +%s%N)
  ms=$(( (t1 - t0) / 1000000 ))

  t="否"; a="否"
  printf '%s' "$out" | grep -q 'Protocol *: *TLSv1\.3' && t="是"
  printf '%s' "$out" | grep -q 'ALPN protocol: h2'     && a="是"

  if [ "$t" = "是" ] && [ "$a" = "是" ]; then
    printf 'OK|%s' "$ms"
  elif [ "$t" = "是" ]; then
    printf '无h2|%s' "$ms"
  else
    printf '失败|%s' "$ms"
  fi
}

# ---- 单个域名 ------------------------------------------------------------
check_one() {
  local d="$1" o="$2" ip4 ip6 r4 r6 r4s r6s v4 v6 ms4 ms6
  ip4=$(resolve "$d" 4)
  ip6=$(resolve "$d" 6)

  r4=$(probe "$ip4" "$d"); r4s="${r4%%|*}"; ms4="${r4##*|}"
  r6=$(probe "$ip6" "$d"); r6s="${r6%%|*}"; ms6="${r6##*|}"

  v4="$r4s"; [ "$r4s" != "失败" ] && [ "$r4s" != "—" ] && v4="$r4s ${ms4}ms"
  v6="$r6s"; [ "$r6s" != "失败" ] && [ "$r6s" != "—" ] && v6="$r6s ${ms6}ms"

  {
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$d" "${ip4:--}" "$v4" "${ip6:--}" "$v6"
  } > "$o"
}

export -f resolve probe check_one
export TIMEOUT

# ---- 表头 ----------------------------------------------------------------
echo "================================================================================================"
echo "REALITY 伪装域名双栈评估 v2   $(date '+%Y-%m-%d %H:%M:%S')"
echo "内核: $(xray version 2>/dev/null | head -1 || echo '未安装 xray')"
echo "出口: v4=$(curl -4 -s --noproxy '*' --max-time 5 https://api.ipify.org 2>/dev/null || echo '不通')  v6=$(curl -6 -s --noproxy '*' --max-time 5 https://api6.ipify.org 2>/dev/null || echo '不通')"
echo "================================================================================================"
printf '%-24s %-17s %-13s %-17s %-13s\n' "域名" "IPv4" "v4握手" "IPv6(首段)" "v6握手"
echo "------------------------------------------------------------------------------------------------"

# ---- 并发跑 --------------------------------------------------------------
i=0
for d in "${DOMAINS[@]}"; do
  i=$((i + 1))
  ( check_one "$d" "$TMPD/$(printf '%03d' "$i")" ) &
  while [ "$(jobs -rp | wc -l)" -ge "$PARALLEL" ]; do wait -n 2>/dev/null || break; done
done
wait

for f in "$TMPD"/*; do
  [ -f "$f" ] || continue
  IFS=$'\t' read -r d i4 r4 i6 r6 < "$f"
  ip6s="$i6"
  case "$i6" in
    *:*) ip6s=$(printf '%s' "$i6" | cut -d: -f1-3)"…" ;;
  esac
  printf '%-24s %-17s %-13s %-17s %-13s\n' "$d" "$i4" "$r4" "$ip6s" "$r6"
done

echo "------------------------------------------------------------------------------------------------"
echo
echo "【可用清单】(v4 或 v6 任一侧握手成功且带 h2)"
n=0
for f in "$TMPD"/*; do
  [ -f "$f" ] || continue
  IFS=$'\t' read -r d i4 r4 i6 r6 < "$f"
  case "$r4$r6" in
    *OK*)
      n=$((n + 1))
      mark=""
      case "$RISKY" in *" $d "*) mark="  ← Xray 风险库，别用" ;; esac
      printf '  %-2d %-24s v4=%-12s v6=%-12s%s\n' "$n" "$d" "$r4" "$r6" "$mark"
      ;;
  esac
done
[ "$n" -eq 0 ] && echo "  无。检查网络或换一批候选。"

echo
echo "【说明】"
echo "  OK      = TLS1.3 + h2 全绿，可用作 REALITY dest"
echo "  无h2    = 能握 TLS1.3 但不协商 h2，不可用（真实浏览器不会这样，特征明显）"
echo "  失败    = 该地址族握不上手，不可用"
echo
echo "【下一步】"
echo "  1. 每台服务器各跑一遍，挑本机延迟最低的可用域名"
echo "  2. 多台机器必须用不同域名，避免同 SNI 多 IP 的聚类特征"
echo "  3. 选定后在本地（不走代理）验证大陆能否直连:"
echo "     curl -sS -o /dev/null -w '%{http_version}\\n' --noproxy '*' https://<域名>"
echo "     返回 2 说明大陆可直连；超时说明该 SNI 在大陆被掐，不能用"
