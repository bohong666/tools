#!/usr/bin/env bash
# ============================================================
# vps-diag.sh — 只读诊断脚本（不修改任何配置、不重启任何服务）
# 用法：在 VPS 上执行  bash vps-diag.sh
# 说明：私钥/密码/UUID 已自动打码，可安全粘贴
# ============================================================
set -u

DB=/etc/vps_manager/nodes.db
HDB=/etc/vps_manager/hy2.db
XCFG=/usr/local/etc/xray/config.json
XLOG=/var/log/xray/error.log

hr() { echo "------------------------------------------------------------"; }

echo "===== 0. 系统信息 ====="
. /etc/os-release 2>/dev/null
echo "OS      : ${PRETTY_NAME:-unknown}"
echo "Kernel  : $(uname -r)   Arch: $(uname -m)"
echo "Load    : $(cat /proc/loadavg 2>/dev/null)"
echo "Uptime  : $(uptime -p 2>/dev/null || uptime)"
echo "内存    : $(free -m 2>/dev/null | awk '/Mem:/{print $3"/"$2" MB used"}')"

hr
echo "===== 1. 内核版本（决定 REALITY 是否需要 MLKEM）====="
if command -v xray >/dev/null 2>&1; then
  echo "Xray : $(xray version 2>/dev/null | head -1)"
else
  echo "Xray : 未安装"
fi
if command -v hysteria >/dev/null 2>&1; then
  echo "HY2  : $(hysteria version 2>/dev/null | head -1)"
else
  echo "HY2  : 未安装"
fi
echo "脚本版本记录: $(cat /etc/vps_manager/version 2>/dev/null || echo '无')"

hr
echo "===== 2. 配置校验 ====="
if [ -f "$XCFG" ]; then
  xray run -test -config "$XCFG" 2>&1 | tail -5
else
  echo "配置文件不存在: $XCFG"
fi

hr
echo "===== 3. 监听端口 ====="
echo "-- TCP --"
ss -tlnp 2>/dev/null | grep -E "xray|hysteria|nginx|caddy" || echo "(无匹配)"
echo "-- UDP --"
ss -ulnp 2>/dev/null | grep -E "xray|hysteria" || echo "(无匹配)"

hr
echo "===== 4. 节点 DB（已打码）====="
echo "-- nodes.db  [uuid|port|sni|sid|privateKey|name|fp] --"
if [ -f "$DB" ]; then
  awk -F'|' -v OFS='|' 'NF>=7 && $1!~/^#/{$1=substr($1,1,8)"…"; $5="<KEY-REDACTED>"; print}' "$DB"
else
  echo "(不存在)"
fi
echo "-- hy2.db  [svc|name|port|hop|start|end|int|ext|pwd|sni|masq|masqval|obfs|obfspwd|up|down|ignore] --"
if [ -f "$HDB" ]; then
  awk -F'|' -v OFS='|' 'NF>=17 && $1!~/^#/{$9="***"; $14="***"; print}' "$HDB"
else
  echo "(不存在)"
fi

hr
echo "===== 5. 【关键】REALITY 回落目标是否指向本机自身 ====="
MYIP=$(curl -s -4 --max-time 5 https://api4.ipify.org 2>/dev/null)
[ -z "$MYIP" ] && MYIP=$(curl -s -4 --max-time 5 https://ifconfig.me 2>/dev/null)
echo "本机公网 IPv4: ${MYIP:-检测失败}"
if [ -f "$DB" ]; then
  while IFS='|' read -r uuid port sni sid priv name fp; do
    [ -z "$uuid" ] && continue
    case "$uuid" in '#'*) continue ;; esac
    ip=$(getent hosts "$sni" 2>/dev/null | awk '{print $1}' | head -1)
    if [ -z "$ip" ]; then
      ip=$(python3 -c "import socket;print(socket.gethostbyname('$sni'))" 2>/dev/null)
    fi
    flag=""
    [ -n "$MYIP" ] && [ "$ip" = "$MYIP" ] && flag="   <<<< 自指！回落会打回本机 443"
    printf "  端口 %-6s SNI=%-22s -> %s%s\n" "$port" "$sni" "${ip:-解析失败}" "$flag"
  done < "$DB"
fi
echo "-- 本机 hosts 里是否有 SNI 记录 --"
grep -vE "^\s*#|^\s*$" /etc/hosts 2>/dev/null | head -20

hr
echo "===== 6. 防火墙现状 ====="
echo "-- iptables INPUT --"
iptables -S INPUT 2>/dev/null | head -25
echo "-- iptables nat PREROUTING --"
iptables -t nat -S PREROUTING 2>/dev/null | head -25
if command -v ufw >/dev/null 2>&1; then echo "-- ufw --"; ufw status 2>/dev/null | head -8; fi
if command -v firewall-cmd >/dev/null 2>&1; then echo "-- firewalld --"; firewall-cmd --list-ports 2>/dev/null; fi

hr
echo "===== 7. 内核调优现状（HY2 吞吐强相关）====="
for k in \
  net.ipv4.tcp_congestion_control net.core.default_qdisc \
  net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
  net.core.somaxconn net.ipv4.ip_local_port_range fs.file-max \
  net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_count \
  net.ipv4.tcp_fastopen net.ipv4.tcp_slow_start_after_idle \
  net.ipv4.tcp_mtu_probing net.ipv4.tcp_notsent_lowat ; do
  printf "  %-42s = %s\n" "$k" "$(sysctl -n $k 2>/dev/null || echo 'n/a')"
done

hr
echo "===== 8. REALITY 被主动探测 / 异常连接统计 ====="
if [ -f "$XLOG" ]; then
  echo "  日志大小: $(du -h "$XLOG" 2>/dev/null | cut -f1)"
  echo "  invalid connection 累计: $(grep -c 'REALITY: processed invalid connection' "$XLOG" 2>/dev/null || echo 0)"
  echo "  最近 24h 内 invalid:     $(grep 'REALITY: processed invalid connection' "$XLOG" 2>/dev/null | grep -c "$(date +%Y/%m/%d)" || echo 0)"
  echo "  -- 最近 8 条相关错误 --"
  grep -iE "reality|invalid|rejected|too many|failed to" "$XLOG" 2>/dev/null | tail -8 | cut -c1-170
else
  echo "  日志不存在: $XLOG"
fi
echo "-- HY2 日志尾部 --"
for f in /var/log/hysteria2/*.log; do
  [ -f "$f" ] || continue
  echo "  [$f]"; tail -5 "$f" 2>/dev/null | cut -c1-170
done

hr
echo "===== 9. 资源与连接 ====="
echo "  conntrack : $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo n/a) / $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo n/a)"
XPID=$(pgrep -x xray 2>/dev/null | head -1)
[ -n "$XPID" ] && echo "  xray PID=$XPID  fd=$(ls /proc/$XPID/fd 2>/dev/null | wc -l)  CPU=$(ps -o %cpu= -p $XPID 2>/dev/null)"
echo "  dmesg 中 conntrack/OOM 告警:"
dmesg 2>/dev/null | grep -iE "conntrack.*full|out of memory|nf_conntrack" | tail -3 || echo "  (无)"

hr
echo "===== 10. 443 端口归属（判断是否 nginx 前置）====="
ss -tlnp 2>/dev/null | grep ':443 ' || echo "  (443 无监听)"
echo "  nginx/caddy 进程: $(pgrep -a 'nginx|caddy' 2>/dev/null | head -3 || echo '无')"

hr
echo "===== 诊断结束，请把以上全部输出贴回来 ====="
