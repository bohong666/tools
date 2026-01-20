#!/bin/bash

# VLESS Reality + Nginx 共用 443 端口方案
# Komari 探针优化版 - 终极完善版
# 解决所有已知问题,自动输出 VLESS 连接

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Reality + Nginx 共用 443 端口部署${NC}"
echo -e "${GREEN}(Komari 探针优化版 v2.0)${NC}"
echo -e "${GREEN}========================================${NC}"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 此脚本必须以 root 权限运行${NC}" 
   exit 1
fi

# ==================== 环境检测 ====================

echo -e "${YELLOW}检测当前环境...${NC}"

# 检测域名
DOMAIN=$(grep -oP 'server_name\s+\K[^;]+' /etc/nginx/sites-enabled/* 2>/dev/null | grep -v "^_" | head -1 | xargs)

if [ -z "$DOMAIN" ]; then
    read -p "请输入你的域名: " DOMAIN
fi

echo -e "域名: ${GREEN}$DOMAIN${NC}"

# 检测 SSL 证书
CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

if [ ! -f "$CERT_PATH" ]; then
    echo -e "${RED}错误: 未找到 SSL 证书 $CERT_PATH${NC}"
    exit 1
fi

if [ ! -f "$KEY_PATH" ]; then
    echo -e "${RED}错误: 未找到 SSL 私钥 $KEY_PATH${NC}"
    exit 1
fi

echo -e "SSL 证书: ${GREEN}✓${NC}"

# 检测 Komari 端口
KOMARI_PORT=$(grep -oP 'proxy_pass http://127\.0\.0\.1:\K\d+' /etc/nginx/sites-available/$DOMAIN 2>/dev/null | head -1)
if [ -z "$KOMARI_PORT" ]; then
    KOMARI_PORT=25774
fi
echo -e "Komari 端口: ${GREEN}$KOMARI_PORT${NC}"

# 检测并安装 Nginx Stream 模块
if ! nginx -V 2>&1 | grep -q "with-stream"; then
    echo -e "${YELLOW}安装 Nginx Stream 模块...${NC}"
    apt update -qq
    apt install -y libnginx-mod-stream >/dev/null 2>&1
fi
echo -e "Stream 模块: ${GREEN}✓${NC}"

# 检测 Xray
if ! command -v xray &> /dev/null; then
    echo -e "${RED}错误: 未安装 Xray${NC}"
    exit 1
fi
echo -e "Xray: ${GREEN}✓${NC}"

echo ""
echo -e "${YELLOW}架构说明:${NC}"
echo -e "443 端口 → Nginx Stream (SNI 分流)"
echo -e "          ├─ SNI = $DOMAIN        → Nginx HTTP → Komari ($KOMARI_PORT)"
echo -e "          └─ SNI = 伪装域名       → Xray Reality"
echo ""

# ==================== 配置输入 ====================

read -p "节点名称 [HK-Reality]: " NODE_NAME
NODE_NAME=${NODE_NAME:-HK-Reality}

# 智能选择端口
REALITY_PORT=8443
NGINX_PORT=8080

# 检测端口占用并自动调整
while netstat -tlnp 2>/dev/null | grep -q ":$REALITY_PORT " && [ "$REALITY_PORT" -lt "9000" ]; do
    REALITY_PORT=$((REALITY_PORT + 1))
done

while netstat -tlnp 2>/dev/null | grep -q ":$NGINX_PORT " && [ "$NGINX_PORT" != "443" ] && [ "$NGINX_PORT" -lt "9000" ]; do
    NGINX_PORT=$((NGINX_PORT + 1))
done

echo -e "Xray Reality 端口: ${GREEN}$REALITY_PORT${NC} (自动选择)"
echo -e "Nginx HTTP 端口: ${GREEN}$NGINX_PORT${NC} (自动选择)"

# 伪装域名
echo ""
echo -e "${YELLOW}请输入伪装域名 (SNI):${NC}"
echo -e "${BLUE}推荐: www.microsoft.com, www.apple.com, www.cloudflare.com, bunny.net${NC}"
echo -e "${RED}重要: 不能是 $DOMAIN！必须是别人的域名！${NC}"
read -p "伪装域名 [www.microsoft.com]: " FAKE_SNI
FAKE_SNI=${FAKE_SNI:-www.microsoft.com}

if [ "$FAKE_SNI" == "$DOMAIN" ]; then
    echo -e "${RED}错误: 伪装域名不能是你自己的域名！${NC}"
    exit 1
fi

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

# ==================== 生成配置 ====================

UUID=$(cat /proc/sys/kernel/random/uuid)

# 生成 Reality 密钥 (兼容所有版本)
echo -e "${YELLOW}生成 Reality 密钥对...${NC}"
KEYS_OUTPUT=$(xray x25519 2>&1)

# 兼容多种输出格式
PRIVATE_KEY=$(echo "$KEYS_OUTPUT" | grep -oP '(?<=PrivateKey: ).*' || echo "$KEYS_OUTPUT" | grep -oP '(?<=Private key: ).*' || echo "$KEYS_OUTPUT" | awk '/Private|PrivateKey/{print $NF}' || echo "")
PUBLIC_KEY=$(echo "$KEYS_OUTPUT" | grep -oP '(?<=Password: ).*' || echo "$KEYS_OUTPUT" | grep -oP '(?<=Public key: ).*' || echo "$KEYS_OUTPUT" | awk '/Password|Public/{print $NF}' || echo "")

# 如果还是失败,手动输入
if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo -e "${YELLOW}自动生成失败,请手动输入密钥:${NC}"
    echo -e "${BLUE}执行 'xray x25519' 获取密钥对${NC}"
    read -p "Private Key (PrivateKey): " PRIVATE_KEY
    read -p "Public Key (Password): " PUBLIC_KEY
fi

SHORT_ID=$(openssl rand -hex 8)

# 获取服务器 IP
SERVER_IP=$(curl -s4 --max-time 5 ip.sb 2>/dev/null || curl -s4 --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo -e "${YELLOW}配置汇总:${NC}"
echo -e "服务器 IP: ${GREEN}$SERVER_IP${NC}"
echo -e "真实域名: ${GREEN}$DOMAIN${NC} → Nginx:$NGINX_PORT → Komari:$KOMARI_PORT"
echo -e "伪装域名: ${GREEN}$FAKE_SNI${NC} → Xray:$REALITY_PORT"
echo -e "UUID: ${GREEN}$UUID${NC}"
echo -e "Public Key: ${GREEN}$PUBLIC_KEY${NC}"
echo -e "Short ID: ${GREEN}$SHORT_ID${NC}"
echo ""
read -p "确认部署? (y/n): " CONFIRM

if [[ "$CONFIRM" != "y" ]]; then
    echo -e "${YELLOW}已取消部署${NC}"
    exit 0
fi

# ==================== 停止服务 ====================

echo -e "${YELLOW}停止现有服务...${NC}"
systemctl stop nginx 2>/dev/null || true
systemctl stop xray 2>/dev/null || true
sleep 1

# ==================== 备份配置 ====================

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
echo -e "${YELLOW}备份现有配置...${NC}"

[ -f /usr/local/etc/xray/config.json ] && cp /usr/local/etc/xray/config.json /usr/local/etc/xray/config.json.backup.$TIMESTAMP
[ -f /etc/nginx/nginx.conf ] && cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup.$TIMESTAMP
[ -f /etc/nginx/sites-available/$DOMAIN ] && cp /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-available/$DOMAIN.backup.$TIMESTAMP

echo -e "${GREEN}✓ 备份完成${NC}"

# ==================== 配置 Xray ====================

echo -e "${YELLOW}配置 Xray Reality...${NC}"

cat > /usr/local/etc/xray/config.json <<EOF
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
echo -e "${GREEN}✓ Xray 配置完成${NC}"

# ==================== 配置 Nginx ====================

echo -e "${YELLOW}配置 Nginx...${NC}"

# 站点配置
cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen $NGINX_PORT ssl http2 proxy_protocol;
    listen [::]:$NGINX_PORT ssl http2 proxy_protocol;
    server_name $DOMAIN;

    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;
    
    client_max_body_size 50M;
    client_body_timeout 300s;
    proxy_read_timeout 300s;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:HIGH:!aNULL:!MD5:!RC4:!DHE;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    # Proxy Protocol 真实 IP 获取
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
    
    # Komari 反向代理
    location / {
        proxy_pass http://127.0.0.1:$KOMARI_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        
        # WebSocket 支持
        proxy_buffering off;
    }
}
EOF

# 主配置
cat > /etc/nginx/nginx.conf <<'NGXCONF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

# Stream 模块 - SNI 分流
stream {
    map $ssl_preread_server_name $backend {
NGXCONF

# 添加域名映射
cat >> /etc/nginx/nginx.conf <<EOF
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
EOF

# 添加 HTTP 配置
cat >> /etc/nginx/nginx.conf <<'NGXCONF'
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

echo -e "${GREEN}✓ Nginx 配置完成${NC}"

# ==================== 测试配置 ====================

echo -e "${YELLOW}测试配置...${NC}"

if ! nginx -t 2>&1 | grep -q "successful"; then
    echo -e "${RED}Nginx 配置测试失败！${NC}"
    nginx -t
    echo ""
    echo -e "${YELLOW}正在回滚配置...${NC}"
    [ -f /etc/nginx/nginx.conf.backup.$TIMESTAMP ] && cp /etc/nginx/nginx.conf.backup.$TIMESTAMP /etc/nginx/nginx.conf
    [ -f /etc/nginx/sites-available/$DOMAIN.backup.$TIMESTAMP ] && cp /etc/nginx/sites-available/$DOMAIN.backup.$TIMESTAMP /etc/nginx/sites-available/$DOMAIN
    [ -f /usr/local/etc/xray/config.json.backup.$TIMESTAMP ] && cp /usr/local/etc/xray/config.json.backup.$TIMESTAMP /usr/local/etc/xray/config.json
    echo -e "${RED}已回滚到备份配置${NC}"
    exit 1
fi

echo -e "${GREEN}✓ 配置测试通过${NC}"

# ==================== 启动服务 ====================

echo -e "${YELLOW}启动服务...${NC}"

systemctl start xray
sleep 1
systemctl start nginx
sleep 2

# 验证服务状态
XRAY_STATUS=$(systemctl is-active xray 2>/dev/null || echo "failed")
NGINX_STATUS=$(systemctl is-active nginx 2>/dev/null || echo "failed")

if [ "$XRAY_STATUS" != "active" ]; then
    echo -e "${RED}Xray 启动失败！${NC}"
    journalctl -u xray -n 30 --no-pager
    exit 1
fi

if [ "$NGINX_STATUS" != "active" ]; then
    echo -e "${RED}Nginx 启动失败！${NC}"
    systemctl status nginx --no-pager
    exit 1
fi

echo -e "${GREEN}✓ 服务启动成功${NC}"

# ==================== 生成 VLESS 连接 ====================

# URL 编码函数
urlencode() {
    local string="${1}"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * ) printf -v o '%%%02x' "'$c"
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

# 生成 VLESS 分享链接
VLESS_LINK="vless://${UUID}@${SERVER_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${FAKE_SNI}&fp=${CLIENT_FP}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#$(urlencode "$NODE_NAME")"

# ==================== 输出配置 ====================

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✓ 部署完成!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}📱 VLESS 分享链接 (直接导入):${NC}"
echo -e "${GREEN}${VLESS_LINK}${NC}"
echo ""
echo -e "${YELLOW}📋 Clash Party / Clash Meta 配置:${NC}"
echo -e "${BLUE}---${NC}"
cat <<YAML
proxies:
  - name: "$NODE_NAME"
    type: vless
    server: $SERVER_IP
    port: 443
    uuid: $UUID
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $FAKE_SNI
    skip-cert-verify: true
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID
    client-fingerprint: $CLIENT_FP
YAML
echo -e "${BLUE}---${NC}"
echo ""
echo -e "${YELLOW}🔑 客户端配置参数:${NC}"
echo -e "服务器: ${GREEN}$SERVER_IP${NC}"
echo -e "端口: ${GREEN}443${NC}"
echo -e "UUID: ${GREEN}$UUID${NC}"
echo -e "SNI: ${GREEN}$FAKE_SNI${NC} ${RED}(客户端必须填这个！)${NC}"
echo -e "Public Key: ${GREEN}$PUBLIC_KEY${NC}"
echo -e "Short ID: ${GREEN}$SHORT_ID${NC}"
echo -e "指纹: ${GREEN}$CLIENT_FP${NC}"
echo ""
echo -e "${YELLOW}🌐 访问测试:${NC}"
echo -e "Komari 探针: ${GREEN}https://$DOMAIN${NC}"
echo ""
echo -e "${BLUE}📊 架构说明:${NC}"
echo -e "443 → Nginx Stream SNI 分流"
echo -e "     ├─ $DOMAIN → Nginx:$NGINX_PORT → Komari:$KOMARI_PORT"
echo -e "     └─ $FAKE_SNI → Xray:$REALITY_PORT"
echo ""

# ==================== 保存配置 ====================

cat > /root/reality-config.txt <<EOF
Reality + Nginx 共用 443 配置
部署时间: $(date)
========================================

节点名称: $NODE_NAME
服务器 IP: $SERVER_IP
域名: $DOMAIN
端口: 443

UUID: $UUID
伪装 SNI: $FAKE_SNI (客户端必填)
Private Key: $PRIVATE_KEY
Public Key: $PUBLIC_KEY
Short ID: $SHORT_ID
指纹: $CLIENT_FP

========================================
VLESS 分享链接:
========================================
$VLESS_LINK

========================================
Clash Party / Clash Meta 配置:
========================================
proxies:
  - name: "$NODE_NAME"
    type: vless
    server: $SERVER_IP
    port: 443
    uuid: $UUID
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $FAKE_SNI
    skip-cert-verify: true
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID
    client-fingerprint: $CLIENT_FP

========================================
架构:
========================================
443 → Nginx Stream SNI 分流
     ├─ $DOMAIN → Nginx:$NGINX_PORT → Komari:$KOMARI_PORT
     └─ $FAKE_SNI → Xray:$REALITY_PORT

Komari 探针: https://$DOMAIN
WebSocket: ✓ 已保留
Proxy Protocol: ✓ 真实 IP 获取

========================================
备份位置:
========================================
Xray: /usr/local/etc/xray/config.json.backup.$TIMESTAMP
Nginx: /etc/nginx/nginx.conf.backup.$TIMESTAMP
站点: /etc/nginx/sites-available/$DOMAIN.backup.$TIMESTAMP

重要: 客户端 SNI 必须填 $FAKE_SNI，不是 $DOMAIN！
EOF

echo -e "${GREEN}配置已保存: /root/reality-config.txt${NC}"
echo ""
echo -e "${YELLOW}📊 验证部署:${NC}"
echo ""
echo -e "端口监听:"
netstat -tlnp 2>/dev/null | grep -E "443|$NGINX_PORT|$REALITY_PORT" | awk '{print "  "$4" → "$7}'
echo ""
echo -e "服务状态:"
echo -e "  Nginx: ${GREEN}$NGINX_STATUS${NC}"
echo -e "  Xray: ${GREEN}$XRAY_STATUS${NC}"
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✓ 部署成功!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}💡 使用提示:${NC}"
echo -e "1. 复制上面的 VLESS 分享链接导入客户端"
echo -e "2. 或使用 Clash 配置手动添加"
echo -e "3. 确保客户端 SNI 填写: ${GREEN}$FAKE_SNI${NC}"
echo -e "4. 查看完整配置: ${GREEN}cat /root/reality-config.txt${NC}"
echo ""
