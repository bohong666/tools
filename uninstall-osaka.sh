#!/bin/bash
# ==============================================================
# 一键卸载脚本:清除 rebuild_all.sh 与 vps_manager 两套脚本的全部安装足迹
# 适用:Ubuntu/Debian 系,需 root 运行(sudo bash uninstall-osaka.sh)
# 在 AMD 与 ARM 两台机上各运行一次,互不影响。
#
# 会清除:xray(二进制/配置/服务/日志) / vps_manager 数据与备份 /
#         nginx(包与配置,含 /etc/nginx/ssl 证书) / acme.sh 与其 cron /
#         极简探针 hub+agent(/opt/monitor 含数据库) / sysctl 里的 BBR 行 /
#         iptables 与 ip6tables 规则(清空并恢复 ACCEPT 后保存)
# 绝不触碰:fanout(/var/lib/fanout 与 fanout.service)、sshd、系统自带服务。
#
# 注意:极简探针数据库 /opt/monitor/data 将被删除。需要保留历史数据,
#       请先在探针 Web 界面导出备份再运行本脚本。
# ==============================================================

set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; PLAIN='\033[0m'
step() { echo -e "\n${GREEN}>>> $*${PLAIN}"; }
warn() { echo -e "${YELLOW}[!] $*${PLAIN}"; }

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}请以 root 运行:sudo bash $0${PLAIN}"
  exit 1
fi

echo -e "${YELLOW}======================================================${PLAIN}"
echo "本脚本将清除以下内容(本机):"
echo "  - xray:/usr/local/bin/xray、/usr/local/etc/xray、/usr/local/share/xray、/var/log/xray、xray.service"
echo "  - vps_manager:/etc/vps_manager、/root/vps_manager_backups"
echo "  - nginx:卸载软件包并删除 /etc/nginx(含 ssl 证书)"
echo "  - acme.sh:~/.acme.sh、root crontab 中的续期任务"
echo "  - 极简探针:monitor-hub / monitor-agent 服务、/opt/monitor(数据库一并删,先导出! )、monitor 用户"
echo "  - /etc/sysctl.conf 中的 BBR 两行;清空 iptables/ip6tables 并保存为 ACCEPT"
echo "不触碰:fanout 及其 /var/lib/fanout、SSH、其他系统服务。"
echo -e "${YELLOW}======================================================${PLAIN}"
printf '确认继续卸载? [y/N] '
read -r ans
[ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "已取消"; exit 0; }

step "1/8 停止并禁用服务"
for svc in xray nginx monitor-hub monitor-agent; do
  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
done

step "2/8 删除 systemd 单元"
rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
rm -rf /etc/systemd/system/xray.service.d
rm -f /etc/systemd/system/monitor-hub.service /etc/systemd/system/monitor-agent.service
rm -f /lib/systemd/system/xray.service /lib/systemd/system/xray@.service 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed 2>/dev/null || true

step "3/8 删除 xray 与 vps_manager 残留"
rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
rm -f /usr/local/bin/xray
rm -rf /etc/vps_manager /root/vps_manager_backups

step "4/8 删除极简探针(hub+agent)"
rm -rf /opt/monitor
userdel monitor 2>/dev/null || true

step "5/8 卸载 nginx 并删除配置与证书"
apt-get purge -y nginx nginx-common nginx-core libnginx-mod-stream >/dev/null 2>&1 || true
rm -rf /etc/nginx

step "6/8 删除 acme.sh 与证书续期任务"
rm -rf /root/.acme.sh
if crontab -l >/dev/null 2>&1; then
  crontab -l 2>/dev/null | grep -v 'acme.sh' | crontab - || true
fi
sed -i '/acme\.sh/d' /root/.bashrc 2>/dev/null || true

step "7/8 清除 sysctl 中的 BBR 行(运行时算法在下次重启后恢复默认)"
sed -i '/^net\.core\.default_qdisc=fq$/d' /etc/sysctl.conf 2>/dev/null || true
sed -i '/^net\.ipv4\.tcp_congestion_control=bbr$/d' /etc/sysctl.conf 2>/dev/null || true

step "8/8 清空防火墙规则并恢复 ACCEPT(不会锁死 SSH)"
iptables -F 2>/dev/null || true
iptables -X 2>/dev/null || true
iptables -P INPUT ACCEPT 2>/dev/null || true
iptables -P FORWARD ACCEPT 2>/dev/null || true
iptables -P OUTPUT ACCEPT 2>/dev/null || true
ip6tables -F 2>/dev/null || true
ip6tables -X 2>/dev/null || true
ip6tables -P INPUT ACCEPT 2>/dev/null || true
ip6tables -P FORWARD ACCEPT 2>/dev/null || true
ip6tables -P OUTPUT ACCEPT 2>/dev/null || true
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save >/dev/null 2>&1 || true
else
  rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6 2>/dev/null || true
fi
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'status: active'; then
  warn "检测到 ufw 处于启用状态,本脚本未动它;如需一并清干净,手动执行:ufw --force reset"
fi

step "验证残留"
LEFT=""
ss -tlnp 2>/dev/null | grep -E ':(443|8443|8081|28080|54321)[[:space:]]' && LEFT="ports"
systemctl list-unit-files 2>/dev/null | grep -E '^(xray|nginx|monitor-hub|monitor-agent)\.service' && LEFT="${LEFT} units"
for d in /etc/vps_manager /opt/monitor /usr/local/etc/xray /etc/nginx; do
  [ -e "$d" ] && { echo "残留目录:$d"; LEFT="${LEFT} dirs"; }
done
command -v xray >/dev/null 2>&1 && { echo "xray 二进制仍在"; LEFT="${LEFT} bin"; }
command -v nginx >/dev/null 2>&1 && { echo "nginx 二进制仍在"; LEFT="${LEFT} bin"; }

echo ""
if [ -z "$LEFT" ]; then
  echo -e "${GREEN}======================================================${PLAIN}"
  echo -e "${GREEN}卸载完成,两套脚本的足迹已清理干净(fanout 未触碰)。${PLAIN}"
  echo -e "${GREEN}现在可以用 rebuild_all.sh 重新安装了。${PLAIN}"
  echo -e "${GREEN}======================================================${PLAIN}"
else
  echo -e "${RED}仍有残留:$LEFT,请把上面验证段的完整输出贴回处理。${PLAIN}"
fi
