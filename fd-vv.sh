#!/bin/bash

# VLESS Reality + Nginx 共用 443 端口方案
# 使用 Nginx Stream 模块 SNI 分流
# 优化版: 保留 Komari 探针完整配置

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Reality + Nginx 共用 443 端口部署${NC}"
echo -e "${GREEN}(Komari 探针优化版)${NC}"
echo -e "${GREEN}========================================${NC}"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 此脚本必须以 root 权限运行${NC}" 
   exit 1
fi

# 获取域名
DOMAIN=$(grep -oP 'server_name\s+\K[^;]+' /etc/nginx/sites-enabled/* 2>/dev/null | head -1 | xargs)

if [ -z "$DOMAIN" ]; then
    read -p "请输入你的域名: " DOMAIN
fi

echo -e "${YELLOW}当前域名: ${GREEN}$DOMAIN${NC}"
echo ""
echo -e "${YELLOW}架构说明:${NC}"
echo -e "443 端口 → Nginx Stream (SNI 分流)"
echo -e "          ├─ SNI = $DOMAIN        → Nginx HTTP (Komari 探针)"
echo -e "          └─ SNI = 伪装域名       → Xray Reality"
echo ""

# 配置输入
read -p "节点名称 [HK-Reality]: " NODE_NAME
NODE_NAME=${NODE_NAME:-HK-Reality}

read -p "Xray Reality 监听端口 [8443]: " REALITY_PORT
REALITY_PORT=${REALITY_PORT:-8443}

read -p "Nginx HTTP 监听端口 [8080]: " NGINX_PORT
NGINX_PORT=${NGINX_PORT:-8080}

# 端口冲突检测
if netstat -tlnp | grep -q ":$NGINX_PORT "; then
    echo -e "${RED}错误: 端口 $NGINX_PORT 已被占用${NC}"
    netstat -tlnp | grep ":$NGINX_PORT"
    exit 1
fi

if netstat -tlnp | grep -q ":$REALITY_PORT "; then
    echo -e "${RED}错误: 端口 $REALITY_PORT 已被占用${NC}"
    netstat -tlnp | grep ":$REALITY_PORT"
    exit 1
fi

# 伪装域名
echo ""
echo -e "${YELLOW}请输入伪装域名 (SNI):${NC}"
echo -e "${BLUE}推荐: www.microsoft.com, www.apple.com, www.cloudflare.com${NC}"
echo -e "${RED}重要: 不能是 $DOMAIN！必须是别人的域名！${NC}"
read -p "伪装域名 [www.microsoft.com]: " FAKE_SNI
FAKE_SNI=${FAKE_SNI:-www.microsoft.com}

if [ "$FAKE_SNI" == "$DOMAIN" ]; then
    echo -e "${RED}错误: 伪装域名不能是你自己的域名！${NC}"
    exit 1
fi

# 生成配置
UUID=$(cat /proc/sys/kernel/random/uuid)

# 生成 Reality 密钥
echo -e "${YELLOW}生成 Reality 密钥对...${NC}"
KEYS_OUTPUT=$(xray x25519 2>&1)
# 兼容新旧版本 xray 输出格式
PRIVATE_KEY=$(echo "$KEYS_OUTPUT" | grep -oP '(?<=PrivateKey: ).*' || echo "$KEYS_OUTPUT" | grep -oP '(?<=Private key: ).*' || echo "$KEYS_OUTPUT" | grep -i private | awk '{print $NF}')
PUBLIC_KEY=$(echo "$KEYS_OUTPUT" | grep -oP '(?<=Password: ).*' || echo "$KEYS_OUTPUT" | grep -oP '(?<=Public key: ).*' || echo "$KEYS_OUTPUT" | grep -i public | awk '{print $NF}')

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo -e "${RED}密钥生成失败，请手动输入${NC}"
    read -p "Private Key: " PRIVATE_KEY
    read -p "Public Key: " PUBLIC_KEY
fi

SHORT_ID=$(openssl rand -hex 8)

# 客户端指纹
echo ""
echo "1) chrome  2) firefox  3) safari"
read -p "客户端指纹 [1]: " FP
case ${FP:-1} in
    1) CLIENT_FP="chrome" ;;
    2) CLIENT_FP="firefox" ;;
    3) CLIENT_FP="safari" ;;
    *) CLIENT_FP="chrome" ;;
esac

echo ""
echo -e "${YELLOW}配置汇总:${NC}"
echo -e "真实域名: ${GREEN}$DOMAIN${NC} → Nginx HTTP → Komari 探针"
echo -e "伪装域名: ${GREEN}$FAKE_SNI${NC} → Xray Reality"
echo -e "UUID: ${GREEN}$UUID${NC}"
echo -e "Public Key: ${GREEN}$PUBLIC_KEY${NC}"
echo -e "Short ID: ${GREEN}$SHORT_ID${NC}"
echo ""
read -p "确认部署? (y/n): " CONFIRM

if [[ "$CONFIRM" != "y" ]]; then
    exit 0
fi

# 1. 配置 Xray Reality
echo -e "${YELLOW}配置 Xray Reality...${NC}"

CONFIG_FILE="/usr/local/etc/xray/config.json"
cp $CONFIG_FILE ${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true

cat > $CONFIG_FILE <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "$NODE_NAME",
      "port": $REALITY_PORT,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision",
            "email": "$NODE_NAME@local"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$FAKE_SNI:443",
          "xver": 0,
          "serverNames": ["$FAKE_SNI"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

mkdir -p /var/log/xray
systemctl restart xray

if ! systemctl is-active --quiet xray; then
    echo -e "${RED}Xray 启动失败${NC}"
    journalctl -u xray -n 20 --no-pager
    exit 1
fi

echo -e "${GREEN}✓ Xray Reality 配置完成${NC}"

# 2. 修改 Nginx 监听端口
echo -e "${YELLOW}修改 Nginx HTTP 监听端口...${NC}"

SITE_CONF="/etc/nginx/sites-available/$DOMAIN"
cp $SITE_CONF ${SITE_CONF}.backup.$(date +%Y%m%d_%H%M%S)

sed -i "s/listen 443 ssl http2/listen $NGINX_PORT ssl http2 proxy_protocol/" $SITE_CONF
sed -i "s/listen \[::\]:443 ssl http2/listen [::]:$NGINX_PORT ssl http2 proxy_protocol/" $SITE_CONF

# 3. 添加 proxy_protocol 真实 IP 获取
echo -e "${YELLOW}配置 proxy_protocol 支持...${NC}"

# 在 server_name 后添加 real_ip 配置
sed -i "/server_name $DOMAIN;/a\\
\\
    # Proxy Protocol 真实 IP 获取\\
    set_real_ip_from 127.0.0.1;\\
    real_ip_header proxy_protocol;" $SITE_CONF

# 修改 proxy_set_header X-Real-IP
sed -i "s/proxy_set_header X-Real-IP \$remote_addr;/proxy_set_header X-Real-IP \$proxy_protocol_addr;/" $SITE_CONF

# 删除旧的 VLESS 配置引用
sed -i "/include \/etc\/nginx\/conf.d\/vless\/\*.conf;/d" $SITE_CONF

echo -e "${GREEN}✓ Nginx 站点配置更新完成${NC}"

# 4. 配置 Nginx Stream 模块
echo -e "${YELLOW}配置 Nginx Stream SNI 分流...${NC}"

# 备份原配置
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup.$(date +%Y%m%d_%H%M%S)

cat > /etc/nginx/nginx.conf <<NGXCONF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

# Stream 模块 - SNI 分流
stream {
    map \$ssl_preread_server_name \$backend {
        $DOMAIN         127.0.0.1:$NGINX_PORT;
        default         127.0.0.1:$REALITY_PORT;
    }
    
    server {
        listen 443;
        listen [::]:443;
        proxy_pass \$backend;
        ssl_preread on;
        proxy_protocol on;
    }
}

# HTTP 模块
http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    
    gzip on;
    
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
NGXCONF

echo -e "${GREEN}✓ Nginx Stream 配置完成${NC}"

# 5. 测试并重启 Nginx
echo -e "${YELLOW}测试 Nginx 配置...${NC}"

if ! nginx -t 2>&1 | grep -q "successful"; then
    echo -e "${RED}Nginx 配置错误${NC}"
    nginx -t
    echo ""
    echo -e "${YELLOW}正在回滚配置...${NC}"
    cp /etc/nginx/nginx.conf.backup.$(date +%Y%m%d_%H%M%S | head -1) /etc/nginx/nginx.conf
    cp ${SITE_CONF}.backup.$(date +%Y%m%d_%H%M%S | head -1) $SITE_CONF
    exit 1
fi

systemctl reload nginx

if ! systemctl is-active --quiet nginx; then
    echo -e "${RED}Nginx 启动失败${NC}"
    systemctl status nginx
    exit 1
fi

echo -e "${GREEN}✓ Nginx 重启成功${NC}"

# 获取服务器 IP
SERVER_IP=$(curl -s4 ip.sb || hostname -I | awk '{print $1}')

# 输出配置
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}部署完成!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Clash Meta 配置:${NC}"
echo -e "${GREEN}---${NC}"
cat <<YAML
  - type: vless
    name: $NODE_NAME
    server: $SERVER_IP
    port: 443
    uuid: $UUID
    tls: true
    flow: xtls-rprx-vision
    servername: $FAKE_SNI
    client-fingerprint: $CLIENT_FP
    skip-cert-verify: false
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID
    network: tcp
YAML
echo -e "${GREEN}---${NC}"
echo ""
echo -e "${YELLOW}客户端配置说明:${NC}"
echo -e "服务器: ${GREEN}$SERVER_IP${NC} (或 $DOMAIN)"
echo -e "端口: ${GREEN}443${NC}"
echo -e "SNI: ${GREEN}$FAKE_SNI${NC} ${RED}(客户端必须填这个！)${NC}"
echo -e "Public Key: ${GREEN}$PUBLIC_KEY${NC}"
echo -e "Short ID: ${GREEN}$SHORT_ID${NC}"
echo ""
echo -e "${YELLOW}测试:${NC}"
echo -e "访问 Komari 探针: ${GREEN}https://$DOMAIN${NC}"
echo -e "VLESS 连接: 使用上面的 Clash 配置"
echo ""
echo -e "${BLUE}工作原理:${NC}"
echo -e "1. 浏览器访问 https://$DOMAIN"
echo -e "   → Nginx Stream 识别 SNI=$DOMAIN"
echo -e "   → 转发到 Nginx HTTP:$NGINX_PORT"
echo -e "   → 反向代理到 Komari:25774"
echo ""
echo -e "2. VLESS 客户端连接 $SERVER_IP:443 (SNI=$FAKE_SNI)"
echo -e "   → Nginx Stream 识别 SNI≠$DOMAIN"
echo -e "   → 转发到 Xray Reality:$REALITY_PORT"
echo ""

# 保存配置
cat > /root/reality-nginx-share443.txt <<EOF
Reality + Nginx 共用 443 配置 (Komari 探针版)
时间: $(date)
========================================

节点: $NODE_NAME
服务器: $SERVER_IP
域名: $DOMAIN
端口: 443
UUID: $UUID
伪装 SNI: $FAKE_SNI (客户端填这个)
Public Key: $PUBLIC_KEY
Short ID: $SHORT_ID
指纹: $CLIENT_FP

Clash Meta:
---
  - type: vless
    name: $NODE_NAME
    server: $SERVER_IP
    port: 443
    uuid: $UUID
    tls: true
    flow: xtls-rprx-vision
    servername: $FAKE_SNI
    client-fingerprint: $CLIENT_FP
    skip-cert-verify: false
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID
    network: tcp
---

架构:
443 → Nginx Stream SNI 分流
     ├─ $DOMAIN → Nginx HTTP:$NGINX_PORT → Komari:25774
     └─ $FAKE_SNI → Xray Reality:$REALITY_PORT

Komari 探针: https://$DOMAIN
WebSocket: ✓ 已保留配置
Proxy Protocol: ✓ 已启用真实 IP 获取

重要: 客户端 SNI 必须填 $FAKE_SNI，不是 $DOMAIN！
EOF

echo -e "${GREEN}配置已保存: /root/reality-nginx-share443.txt${NC}"
echo ""
echo -e "${YELLOW}请立即测试:${NC}"
echo -e "1. 访问 ${GREEN}https://$DOMAIN${NC} 确认 Komari 探针正常"
echo -e "2. 检查 WebSocket 实时数据是否更新"
echo -e "3. 使用 Clash 配置测试 VLESS 连接"
