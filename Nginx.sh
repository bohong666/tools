cat > rebuild_all.sh << 'EOF'
#!/bin/bash

# =================================================================
# 脚本名称：Xray + Nginx + Komari 灾后重建终极版
# 功能包含：BBR加速、SSL全自动续期、IPv4/IPv6防火墙、Docker持久化
# =================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

PORT_XRAY=8443
PORT_WEB=8081
PORT_KOMARI=25774
HOST_DATA_DIR="/opt/komari/data"

echo -e "${GREEN}>>> [1/9] 配置初始化...${PLAIN}"
read -p "1. 请输入您的域名 (如 hon0.com): " DOMAIN
read -p "2. 请输入您的 SSH 端口号 [默认: 22]: " INPUT_SSH_PORT
SSH_PORT=${INPUT_SSH_PORT:-22}
read -p "3. 请输入 Reality 伪装域名 [默认: www.hkpc.org]: " INPUT_SNI
SNI=${INPUT_SNI:-www.hkpc.org}
read -p "4. 请输入邮箱(用于申请证书): " EMAIL

echo -e "${GREEN}>>> [2/9] 开启 BBR 网络加速...${PLAIN}"
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p

echo -e "${GREEN}>>> [3/9] 安装依赖与防火墙持久化工具...${PLAIN}"
apt update
apt install -y curl socat nginx libnginx-mod-stream uuid-runtime openssl iptables-persistent netfilter-persistent
# 临时停止 nginx 释放 80 端口用于申请证书
systemctl stop nginx

echo -e "${GREEN}>>> [4/9] 申请 SSL 证书 (包含自动续期机制)...${PLAIN}"
curl https://get.acme.sh | sh -s email=${EMAIL}
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
# 强制申请，并配置续期前后的 Nginx 启停动作
~/.acme.sh/acme.sh --issue -d ${DOMAIN} --standalone -k ec-256 --force \
  --pre-hook "systemctl stop nginx" \
  --post-hook "systemctl start nginx"
  
mkdir -p /etc/nginx/ssl
~/.acme.sh/acme.sh --installcert -d ${DOMAIN} --ecc \
  --fullchain-file /etc/nginx/ssl/cert.crt \
  --key-file /etc/nginx/ssl/private.key \
  --reloadcmd "systemctl restart nginx"

echo -e "${GREEN}>>> [5/9] 部署 Komari 面板...${PLAIN}"
if ! command -v docker &> /dev/null; then curl -fsSL https://get.docker.com | sh; fi
mkdir -p "${HOST_DATA_DIR}"
docker run -d \
  --name komari \
  --restart=always \
  -p 127.0.0.1:${PORT_KOMARI}:${PORT_KOMARI} \
  -v "${HOST_DATA_DIR}:/app/data" \
  -e TZ=Asia/Shanghai \
  -e ADMIN_USERNAME=admin \
  -e ADMIN_PASSWORD=admin888 \
  ghcr.io/komari-monitor/komari:latest

echo -e "${GREEN}>>> [6/9] 安装并配置 Xray (Reality)...${PLAIN}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
KEYS=$(xray x25519)
PK=$(echo "$KEYS" | grep -i "Private" | awk '{print $NF}')
PUB=$(echo "$KEYS" | grep -i "Public" | awk '{print $NF}')
if [[ -z "$PUB" ]]; then PUB=$(echo "$KEYS" | grep -i "Password" | awk '{print $NF}'); fi
UUID=$(cat /proc/sys/kernel/random/uuid)
SHORT=$(openssl rand -hex 4)

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1", "port": ${PORT_XRAY}, "protocol": "vless",
      "settings": { "clients": [{ "id": "${UUID}", "flow": "xtls-rprx-vision" }], "decryption": "none" },
      "streamSettings": {
        "network": "tcp", "security": "reality",
        "realitySettings": { "show": false, "dest": "${SNI}:443", "xver": 0, "serverNames": ["${SNI}"], "privateKey": "${PK}", "shortIds": ["${SHORT}"] }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
systemctl enable xray && systemctl restart xray

echo -e "${GREEN}>>> [7/9] 配置 Nginx (Stream分流 + 大文件)...${PLAIN}"
cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;
events { worker_connections 768; }
stream {
    map \$ssl_preread_server_name \$backend {
        ${DOMAIN}        127.0.0.1:${PORT_WEB};
        default          127.0.0.1:${PORT_XRAY};
    }
    server { listen 443 reuseport; listen [::]:443 reuseport; proxy_pass \$backend; ssl_preread on; }
}
http {
    sendfile on; tcp_nopush on; types_hash_max_size 2048; client_max_body_size 1024m;
    include /etc/nginx/mime.types; default_type application/octet-stream;
    include /etc/nginx/conf.d/*.conf;
}
EOF

cat > /etc/nginx/conf.d/web_internal.conf <<EOF
server { listen 80; server_name ${DOMAIN}; return 301 https://\$host\$request_uri; }
server {
    listen 127.0.0.1:${PORT_WEB} ssl http2; server_name ${DOMAIN};
    ssl_certificate /etc/nginx/ssl/cert.crt; ssl_certificate_key /etc/nginx/ssl/private.key;
    location / {
        proxy_pass http://127.0.0.1:${PORT_KOMARI}; proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https; proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade";
    }
}
EOF
systemctl enable nginx && systemctl restart nginx

echo -e "${GREEN}>>> [8/9] 部署双栈安全防火墙...${PLAIN}"
# IPv4
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
# IPv6
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

echo -e "${GREEN}=========================================================${PLAIN}"
echo -e "${GREEN}   🎉 重建完成！新系统已搭载 BBR 加速及全套自动防护。${PLAIN}"
echo -e "${GREEN}=========================================================${PLAIN}"
echo -e "${YELLOW}1. Komari 面板:${PLAIN}"
echo -e "   网址: https://${DOMAIN}"
echo -e "   账号: admin / 密码: admin888"
echo -e ""
echo -e "${YELLOW}2. 全新 Xray 节点 (请在客户端替换旧节点):${PLAIN}"
echo -e "   ${LINK}"
echo -e "${GREEN}=========================================================${PLAIN}"
EOF

chmod +x rebuild_all.sh
./rebuild_all.sh
