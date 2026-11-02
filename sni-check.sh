#!/usr/bin/env bash
# ============================================================
# sni-check.sh — REALITY 伪装域名（SNI）候选评估
# 在 VPS 上运行，只读，不改任何配置
#
# 用法:
#   bash sni-check.sh                 # 评估内置候选列表
#   bash sni-check.sh a.com b.com     # 评估指定域名
#
# 评估四件事:
#   1. 服务器能否解析出 A/AAAA
#   2. 是否支持 TLS 1.3 + ALPN h2（REALITY 对目标站的硬要求）
#   3. 服务器到该站 443 是否可达（回落必须能连通）
#   4. Xray 内核是否把它列为高风险目标（会直接打印警告）
# ============================================================
set -u

XCFG=/usr/local/etc/xray/config.json
XRAY=$(command -v xray || echo /usr/local/bin/xray)
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

DEFAULT_LIST=(
  www.samsung.com www.nvidia.com www.amd.com www.intel.com
  www.tesla.com www.salesforce.com www.oracle.com www.dell.com
  www.zoom.us www.dropbox.com www.spotify.com www.twitch.tv
  www.autodesk.com www.jetbrains.com www.python.org www.docker.com
  www.mozilla.org www.ikea.com www.bbc.com www.uniqlo.com
)

if [ $# -gt 0 ]; then
  LIST=("$@")
else
  LIST=("${DEFAULT_LIST[@]}")
fi

[ -f "$XCFG" ] || { echo "找不到 $XCFG"; exit 1; }
[ -x "$XRAY" ] || { echo "找不到 xray 可执行文件"; exit 1; }

echo "============================================================"
echo " REALITY 伪装域名评估  ($(date '+%F %T'))"
echo " 服务端内核: $($XRAY version 2>/dev/null | head -1 | cut -c1-60)"
echo "============================================================"

# 生成一份只替换 serverNames 的临时配置，用来触发 Xray 的风险提示
make_cfg() {
  python3 - "$1" "$2" <<'PY'
import json,sys
src, dst = sys.argv[1], sys.argv[2]
name = dst.rsplit('.json',1)[0].split('__')[-1]
try:
    c = json.load(open(src))
except Exception as e:
    sys.exit("配置读取失败: %s" % e)
hit = False
for ib in c.get('inbounds', []):
    ss = ib.get('streamSettings', {})
    if ss.get('security') == 'reality':
        rs = ss.setdefault('realitySettings', {})
        rs['serverNames'] = [name]
        rs['dest'] = name + ':443'
        hit = True
for ob in c.get('outbounds', []):
    ss = ob.get('streamSettings', {})
    if ss.get('security') == 'reality':
        rs = ss.setdefault('realitySettings', {})
        rs['serverName'] = name
json.dump(c, open(dst,'w'), indent=2)
sys.exit(0 if hit else 1)
PY
}

printf "%-22s %-16s %-10s %-9s %-8s %s\n" "域名" "解析IP" "TLS1.3" "ALPN-h2" "443可达" "Xray风险评估"
echo "--------------------------------------------------------------------------------------------"

for d in "${LIST[@]}"; do
  # 1. 解析
  ip=$(getent ahosts "$d" 2>/dev/null | awk '$2=="STREAM"{print $1; exit}')
  [ -z "$ip" ] && ip=$(getent hosts "$d" 2>/dev/null | awk '{print $1; exit}')
  [ -z "$ip" ] && ip="解析失败"

  # 2/3. TLS 1.3 + h2 + 可达
  tls="否"; h2="否"; reach="否"
  if [ "$ip" != "解析失败" ]; then
    out=$(echo | timeout 8 openssl s_client -connect "${d}:443" -servername "$d" -tls1_3 -alpn h2 2>/dev/null)
    if [ -n "$out" ]; then
      reach="是"
      echo "$out" | grep -q "Protocol *: *TLSv1.3" && tls="是"
      echo "$out" | grep -q "ALPN protocol: h2" && h2="是"
    fi
  fi

  # 4. Xray 风险评估
  risk="-"
  if make_cfg "$XCFG" "$TMPD/__${d}.json" 2>/dev/null; then
    msg=$("$XRAY" run -test -config "$TMPD/__${d}.json" 2>&1)
    if echo "$msg" | grep -qi "increase the likelihood"; then
      risk="!! 高风险(内核警告)"
    elif echo "$msg" | grep -qi "Configuration OK"; then
      risk="通过"
    else
      risk="校验失败"
    fi
  else
    risk="(无法构造测试配置)"
  fi

  printf "%-22s %-16s %-10s %-9s %-8s %s\n" "$d" "${ip:0:15}" "$tls" "$h2" "$reach" "$risk"
done

echo
echo "============================================================"
echo " 判定标准（三项全绿才可用）:"
echo "   TLS1.3=是  ALPN-h2=是  443可达=是  Xray风险评估=通过"
echo ""
echo " 注意: 若目标站只解析出 IPv6 而本机没有可用 IPv6 出口，"
echo "       回落会连不上，探测方会看到'无响应'——这本身就是特征。"
echo "       请同时确认: curl -6 -s https://api6.ipify.org 有输出"
echo "============================================================"
