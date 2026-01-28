# 1. 创建脚本文件
cat > install_final.sh << 'EOF'
#!/bin/bash

# =================================================================
# 脚本名称：Xray Reality + Nginx Stream + Komari (终极收藏版)
# 功能包含：自动流控、数据持久化、防火墙自动配置、开机自启
# =================================================================

# --- 1. 颜色与变量 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

DOMAIN="hon0.com"
PORT_XRAY=8443
PORT_WEB=8081
PORT_KOMARI=25774
HOST_DATA_DIR="/opt/komari/data" # 数据持久化目录

# --- 2. 交互式配置 (关键) ---
echo -e "${GREEN}>>> [1/8] 配置初始化...${PLAIN}"

# 2.1 获取 SSH 端口 (防关门)
echo -e "${YELLOW}---------------------------------------------------${PLAIN}"
read -p "请输入您的 SSH 端口号 [默认: 22]: " INPUT_SSH_PORT
SSH_PORT=${INPUT_SSH_PORT:-22}
echo -e "${GREEN}SSH 端口已确认为: ${SSH_PORT} (防火墙将放行此端口)${PLAIN}"

# 2.2 获取 SNI
echo -e "${YELLOW}---------------------------------------------------${PLAIN}"
read -p "请输入 Reality 伪装域名 [默认: www.hkpc.org]: " INPUT_SNI
SNI=${INPUT_SNI:-www.hkpc.org}
echo -e "${GREEN}伪装域名已确认为: ${SNI}${PLAIN}"
echo -e "${YELLOW}---------------------------------------------------${PLAIN}"

# --- 3. 环境清理 ---
echo -e "${GREEN}>>> [2/8] 清理旧环境...${PLAIN}"
systemctl stop nginx xray 2>/dev/null
# 确保之前未设置自启的服务被禁用
systemctl disable nginx xray 2>/dev/null
killall nginx xray 2>/dev/null
if command -v docker &> /dev/null; then
    docker rm -f komari 2>/dev/null
fi
rm -rf /etc/nginx/conf.d/* /etc/nginx/sites-enabled/*
# 确保数据目录存在
mkdir -p "$HOST_DATA_DIR"

# --- 4. 安装依赖 ---
echo -e "${GREEN}>>> [3/8] 安装依赖与工具...${PLAIN}"
apt update
# 安装 iptables-persistent 用于保存防火墙规则
apt install -y curl socat nginx libnginx-mod-stream uuid-runtime openssl iptables-persistent netfilter-persistent

# --- 5. 证书复用逻辑 ---
echo -e "${GREEN}>>> [4/8] 准备 SSL 证书...${PLAIN}"
mkdir -p /etc/nginx/ssl
DEST_CERT="/etc/nginx/ssl/cert.crt"
DEST_KEY="/etc/nginx/ssl/private.key"

if [ -f "/root/.acme.sh/hon0.com_ecc/fullchain.cer" ]; then
    cp "/root/.acme.sh/hon0.com_ecc/fullchain.cer" "$DEST_CERT"
    cp "/root/.acme.sh/hon0.com_ecc/hon0.com.key" "$DEST_KEY"
elif [ -f "/root/.acme.sh/hon0.com/fullchain.cer" ]; then
    cp "/root/.acme.sh/hon0.com/fullchain.cer" "$DEST_CERT"
    cp "/root/.acme.sh/hon0.com/hon0.com.key" "$DEST_KEY"
elif [ -f "/etc/nginx/ssl/cert.crt" ]; then
    echo "使用现有 Nginx 证书"
else
    echo -e "${RED}❌ 致命错误：找不到证书文件！${PLAIN}"
    exit 1
fi
chmod 644 "$DEST_CERT" "$DEST_KEY"

# --- 6. 部署 Komari (持久化 + 时区) ---
echo -e "${GREEN}>>> [5/8] 启动 Komari 容器...${PLAIN}"
if ! command -v docker &> /dev/null; then curl -fsSL https://get.docker.com | sh; fi

docker run -d \
  --name komari \
  --restart=always \
  -p 127.0.0.1:${PORT_KOMARI}:${PORT_KOMARI} \
  -v "${HOST_DATA_DIR}:/app/data" \
  -e TZ=Asia/Shanghai \
  -e ADMIN_USERNAME=admin \
  -e ADMIN_PASSWORD=admin888 \
  ghcr.io/komari-monitor/komari:latest

# --- 7. 安装 Xray (开机自启) ---
echo -e "${GREEN}>>> [6/8] 配置 Xray...${PLAIN}"
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
      "settings": {
        "clients": [{ "id": "${UUID}", "flow": "xtls-rprx-vision" }], "decryption": "none"
      },
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
# 【修复】设置开机自启
systemctl enable xray
systemctl restart xray

# --- 8. 配置 Nginx (大文件上传 + Stream + 开机自启) ---
echo -e "${GREEN}>>> [7/8] 配置 Nginx...${PLAIN}"

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
    server {
        listen 443 reuseport;
        listen [::]:443 reuseport;
        proxy_pass \$backend;
        ssl_preread on;
    }
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    # 【修复】全局允许 1GB 上传
    client_max_body_size 1024m;
    
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    include /etc/nginx/conf.d/*.conf;
}
EOF

cat > /etc/nginx/conf.d/web_internal.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 127.0.0.1:${PORT_WEB} ssl http2;
    server_name ${DOMAIN};
    ssl_certificate ${DEST_CERT};
    ssl_certificate_key ${DEST_KEY};
    
    location / {
        proxy_pass http://127.0.0.1:${PORT_KOMARI};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

# 【修复】设置开机自启
systemctl enable nginx
systemctl restart nginx

# --- 9. 防火墙配置 (自动保存) ---
echo -e "${GREEN}>>> [8/8] 配置安全防火墙...${PLAIN}"
iptables -F
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
# 放行用户输入的 SSH 端口
iptables -A INPUT -p tcp --dport ${SSH_PORT} -j ACCEPT
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p udp --dport 443 -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -P INPUT DROP
iptables -P FORWARD DROP

# 保存规则 (持久化)
netfilter-persistent save
netfilter-persistent reload

# --- 10. 结果输出 ---
LINK="vless://${UUID}@${DOMAIN}:443?security=reality&encryption=none&pbk=${PUB}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&sid=${SHORT}&spx=%2F#${DOMAIN}_Final"

echo ""
echo -e "${GREEN}=========================================================${PLAIN}"
echo -e "${GREEN}   🎉 终极版部署完成！系统已重启自动保护。${PLAIN}"
echo -e "${GREEN}=========================================================${PLAIN}"
echo -e "${YELLOW}1. Komari 面板 (已修正时区/允许大文件):${PLAIN}"
echo -e "   网址: https://${DOMAIN}"
echo -e "   账号: admin / 密码: admin888"
echo -e ""
echo -e "${YELLOW}2. Xray 节点 (Reality):${PLAIN}"
echo -e "   ${LINK}"
echo -e ""
echo -e "${YELLOW}3. 防火墙状态:${PLAIN}"
echo -e "   SSH 端口 [${SSH_PORT}] 已放行。规则已永久保存。"
echo -e "${GREEN}=========================================================${PLAIN}"
EOF

# 2. 赋予权限并运行
chmod +x install_final.sh
./install_final.sh
