#!/bin/bash

# =================================================================
# 脚本名称：Xray + Nginx + 极简探针(monitor-probe) 终极重装脚本
# 功能包含：防扫段探测(444)、BBR加速、SSL自动续期、极简探针、双栈防火墙
#
# 本次修复(功能一项未删，只修隐患):
# 1. 内层 heredoc 结束符改名(XRAYEOF / NGINXEOF)，与建文件时常用的
# 外层 EOF 不再撞名，cat 粘贴建文件不会再被截断。
# 2. 开头加防呆：用 bash <(curl...) / curl | bash 直跑交互脚本会
# 让 read 吞掉脚本自身，直接拒绝并提示先存文件再跑。
# 3. [2/9] 增加残留清理：清掉上次未装完的 xray 二进制/配置/服务残件，
# 保证每次都是干净重装(证书、acme 账户、探针数据不动)。
# 4. [3/9] BBR 两行改为"不存在才追加"，反复运行不再堆出重复行。
# 5. [4/9] 检测到其他 apt/dpkg 进程占锁时先给出提示，避免抢锁互卡。
# 6. [7/9] xray 配置写完先 run -test 校验通过才重启服务。
# 7. [8/9] nginx 先 -t 校验通过才启动，避免缺证书时重启扑空。
# 8. 结尾增加监听端口验收输出。
# 9. [7/9] 移植 vps_manager 的 dokodemo-door 防偷架构：Reality 回落先经
# 本地 guard 白名单校验 SNI，不匹配直接黑洞，不再原样中继给伪装站；
# 伪装域名默认改用大厂 www.yahoo.com(仍可任意输入)。
# =================================================================

case "$0" in
/dev/fd/*|/proc/self/fd/*|bash)
echo "错误：本脚本是交互式脚本，不能用 bash <(curl...) 或 curl | bash 直接运行，"
echo "那样 read 会把脚本自身当成键盘输入读掉。请先另存为文件再运行，例如："
echo "curl -fsSL 脚本网址 -o rebuild_all.sh"
echo "bash rebuild_all.sh"
exit 1
;;
esac

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

PORT_XRAY=8443
PORT_WEB=8081
PORT_MONITOR=28080 # 极简探针 Hub 默认监听端口
PORT_GUARD=54321  # 防偷 guard(dokodemo-door) 本地监听端口

echo -e "${GREEN}>>> [1/9] 配置初始化...${PLAIN}"
read -p "1. 请输入您的域名 (如 hon0.com): " DOMAIN
read -p "2. 请输入您的 SSH 端口号 [默认: 22]: " INPUT_SSH_PORT
SSH_PORT=${INPUT_SSH_PORT:-22}
read -p "3. 请输入 Reality 伪装域名 [默认: www.yahoo.com]: " INPUT_SNI
SNI=${INPUT_SNI:-www.yahoo.com}
read -p "4. 请输入邮箱(用于申请证书): " EMAIL

echo -e "${GREEN}>>> [2/9] 准备环境与释放端口...${PLAIN}"
# 如果旧的 Xray 或 Nginx 占用了 443 端口，先将它们杀掉以防冲突
systemctl stop xray 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true
systemctl stop monitor-hub 2>/dev/null || true
# 清除上次未安装完成的 xray 残件，保证本次是干净重装
# (证书、acme 账户、探针 /opt/monitor 数据不在此列，不动)
systemctl disable xray 2>/dev/null || true
rm -rf /usr/local/etc/xray /usr/local/share/xray
rm -f /usr/local/bin/xray
rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d
systemctl daemon-reload 2>/dev/null || true

echo -e "${GREEN}>>> [3/9] 开启 BBR 网络加速...${PLAIN}"
grep -qx "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
grep -qx "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p

echo -e "${GREEN}>>> [4/9] 安装依赖与防火墙持久化工具...${PLAIN}"
if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
echo -e "${YELLOW}提示：检测到有 apt/dpkg 进程正在运行并占用锁，本步会排队等待；若长时间不动，多半是残留的 apt 进程卡死，请到另一个终端用 ps 查清后 kill 掉再回来。${PLAIN}"
fi
apt update
apt install -y curl socat nginx libnginx-mod-stream uuid-runtime openssl iptables-persistent netfilter-persistent

echo -e "${GREEN}>>> [5/9] 申请 SSL 证书 (包含自动续期机制)...${PLAIN}"
curl https://get.acme.sh | sh -s email=${EMAIL}
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue -d ${DOMAIN} --standalone -k ec-256 --force \
--pre-hook "systemctl stop nginx" \
--post-hook "systemctl start nginx"

mkdir -p /etc/nginx/ssl
~/.acme.sh/acme.sh --installcert -d ${DOMAIN} --ecc \
--fullchain-file /etc/nginx/ssl/cert.crt \
--key-file /etc/nginx/ssl/private.key \
--reloadcmd "systemctl restart nginx"

echo -e "${GREEN}>>> [6/9] 安装 极简探针 (monitor-probe) Hub...${PLAIN}"
echo -e "${YELLOW}======================================================${PLAIN}"
echo -e "${YELLOW}接下来将进入极简探针的交互安装器，请按以下步骤操作：${PLAIN}"
echo -e "1. 输入 ${GREEN}1${PLAIN} 选择安装。"
echo -e "2. 提示监听端口时，请直接按 ${GREEN}回车${PLAIN}（使用默认的 28080）。"
echo -e "3. 安装成功返回菜单时，请输入 ${GREEN}q${PLAIN} 退出安装器。"
echo -e "${YELLOW}退出后，本脚本会自动继续执行接下来的步骤！${PLAIN}"
echo -e "${YELLOW}======================================================${PLAIN}"
read -p ">>> 请按 回车键 开始安装探针..."
curl -fsSL https://raw.githubusercontent.com/monitor-probe/monitor/main/install-hub.sh -o install-hub.sh
chmod +x install-hub.sh
./install-hub.sh

echo -e "${GREEN}>>> [7/9] 安装并配置内部 Xray (Reality)...${PLAIN}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
KEYS=$(xray x25519)
PK=$(echo "$KEYS" | grep -i "Private" | awk '{print $NF}')
PUB=$(echo "$KEYS" | grep -iE "Public|Password" | awk '{print $NF}')

UUID=$(cat /proc/sys/kernel/random/uuid)
SHORT=$(openssl rand -hex 4)

cat > /usr/local/etc/xray/config.json << XRAYEOF
{
"log": { "loglevel": "warning" },
"inbounds": [
{
"tag": "in-xray",
"listen": "127.0.0.1", "port": ${PORT_XRAY}, "protocol": "vless",
"settings": { "clients": [{ "id": "${UUID}", "flow": "xtls-rprx-vision" }], "decryption": "none" },
"streamSettings": {
"network": "tcp", "security": "reality",
"realitySettings": { "show": false, "dest": "127.0.0.1:${PORT_GUARD}", "serverNames": ["${SNI}"], "privateKey": "${PK}", "shortIds": ["${SHORT}"] }
},
"sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true }
},
{
"tag": "guard",
"listen": "127.0.0.1", "port": ${PORT_GUARD}, "protocol": "dokodemo-door",
"settings": { "address": "${SNI}", "port": 443, "network": "tcp" },
"sniffing": { "enabled": true, "destOverride": ["tls"], "routeOnly": true }
}
],
"outbounds": [
{ "protocol": "freedom", "tag": "direct" },
{ "protocol": "blackhole", "tag": "block" }
],
"routing": {
"domainStrategy": "IPIfNonMatch",
"rules": [
{ "type": "field", "inboundTag": ["guard"], "domain": ["${SNI}"], "outboundTag": "direct" },
{ "type": "field", "inboundTag": ["guard"], "outboundTag": "block" },
{ "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }
]
}
}
XRAYEOF
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
if [ $? -ne 0 ]; then
echo -e "${RED}Xray 配置校验未通过，已停止后续步骤，请把上面的报错贴回处理。${PLAIN}"
exit 1
fi
systemctl enable xray && systemctl restart xray

echo -e "${GREEN}>>> [8/9] 配置 Nginx (Stream分流 + 扫段克星)...${PLAIN}"
cat > /etc/nginx/nginx.conf << NGINXEOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events { worker_connections 768;}

stream {
map \$ssl_preread_server_name \$backend {
${DOMAIN} 127.0.0.1:${PORT_WEB};
default 127.0.0.1:${PORT_XRAY};
}
server { listen 443 reuseport; listen [::]:443 reuseport; proxy_pass \$backend; ssl_preread on;}
}

http {
sendfile on; tcp_nopush on; types_hash_max_size 2048; client_max_body_size 1024m;
server_tokens off;
include /etc/nginx/mime.types; default_type application/octet-stream;

# 扫段克星：拦截 IP 直连 / 假域名解析
server {
listen 80 default_server; listen [::]:80 default_server;
server_name _;
return 444;
}

# HTTP 强制跳转 HTTPS
server {
listen 80;
server_name ${DOMAIN};
return 301 https://\$host\$request_uri;
}

# 探针核心服务
server {
listen 127.0.0.1:${PORT_WEB} ssl http2;
server_name ${DOMAIN};
ssl_certificate /etc/nginx/ssl/cert.crt;
ssl_certificate_key /etc/nginx/ssl/private.key;

# 严苛的 Host 校验防伪造
if (\$host != '${DOMAIN}') {
return 444;
}

location / {
proxy_pass http://127.0.0.1:${PORT_MONITOR};
proxy_set_header Host \$host;
proxy_set_header X-Real-IP \$remote_addr;
proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto https; proxy_http_version 1.1;
# 兼容极简探针的 WebSocket 长连接
proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade";
}
}
}
NGINXEOF
if ! nginx -t; then
echo -e "${RED}Nginx 配置校验未通过(常见原因：证书文件没装好)，已停止后续步骤，请把上面的报错贴回处理。${PLAIN}"
exit 1
fi
systemctl enable nginx && systemctl restart nginx

echo -e "${GREEN}>>> [9/9] 部署双栈安全防火墙...${PLAIN}"
iptables -F
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A INPUT -p tcp --dport ${SSH_PORT} -j ACCEPT
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p udp --dport 443 -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -P INPUT DROP
iptables -P FORWARD DROP

ip6tables -F
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
ip6tables -A INPUT -p tcp --dport 80 -j ACCEPT
ip6tables -A INPUT -p tcp --dport 443 -j ACCEPT
ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP

netfilter-persistent save
netfilter-persistent reload

LINK="vless://${UUID}@${DOMAIN}:443?security=reality&encryption=none&pbk=${PUB}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&sid=${SHORT}&spx=%2F#${DOMAIN}_Reborn"

echo -e "${GREEN}>>> 监听端口验收(应能看到 443/8081/8443/28080/54321)：${PLAIN}"
ss -tlnp | grep -E ':(443|8081|8443|28080|54321)[[:space:]]' || echo -e "${YELLOW}未检测到预期监听，请把完整输出贴回排查。${PLAIN}"

echo -e "${GREEN}=========================================================${PLAIN}"
echo -e "${GREEN} 🎉 重装完成！极简探针已接管，扫段克星已激活。${PLAIN}"
echo -e "${GREEN}=========================================================${PLAIN}"
echo -e "${YELLOW}1. 极简探针面板:${PLAIN}"
echo -e " 网址: https://${DOMAIN}"
echo -e ""
echo -e "${YELLOW}2. 全新 Xray 节点 (请在客户端替换旧节点):${PLAIN}"
echo -e " ${LINK}"
echo -e "${GREEN}=========================================================${PLAIN}"
