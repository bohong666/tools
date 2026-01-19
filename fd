#!/bin/bash

# VPS反向代理一键部署脚本 (HTTPS + VLESS)
# 支持 SNI 分流和 Cloudflare 优选域名

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}==================================${NC}"
echo -e "${GREEN}VPS 反向代理一键部署脚本${NC}"
echo -e "${GREEN}==================================${NC}"

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 此脚本必须以 root 权限运行${NC}" 
   exit 1
fi

# 检测系统类型
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo -e "${RED}无法检测操作系统类型${NC}"
    exit 1
fi

# 获取用户输入
read -p "请输入您的域名 (例如: example.com): " DOMAIN
read -p "请输入网站路径 (用于伪装，例如: /mywebsite): " WEB_PATH
read -p "请输入 VLESS 路径 (例如: /vless): " VLESS_PATH
read -p "是否启用 Cloudflare CDN? (y/n): " USE_CF

# 生成 UUID
UUID=$(cat /proc/sys/kernel/random/uuid)

echo -e "${YELLOW}开始安装必要组件...${NC}"

# 安装依赖
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    apt update
    apt install -y nginx certbot python3-certbot-nginx curl wget unzip
elif [[ "$OS" == "centos" || "$OS" == "rhel" ]]; then
    yum install -y epel-release
    yum install -y nginx certbot python3-certbot-nginx curl wget unzip
else
    echo -e "${RED}不支持的操作系统: $OS${NC}"
    exit 1
fi

# 安装 Xray
echo -e "${YELLOW}安装 Xray...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 配置防火墙
echo -e "${YELLOW}配置防火墙...${NC}"
if command -v ufw &> /dev/null; then
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 22/tcp
    ufw --force enable
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --permanent --add-service=ssh
    firewall-cmd --reload
fi

# 获取 SSL 证书
echo -e "${YELLOW}获取 SSL 证书...${NC}"
systemctl stop nginx
certbot certonly --standalone -d $DOMAIN --agree-tos --register-unsafely-without-email --non-interactive
systemctl start nginx

# 创建网站目录和伪装页面
mkdir -p /var/www/$DOMAIN
cat > /var/www/$DOMAIN/index.html <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>Welcome</title>
    <meta charset="utf-8">
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f4f4f4; }
        .container { background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #333; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome to $DOMAIN</h1>
        <p>This is a sample page.</p>
    </div>
</body>
</html>
EOF

# 配置 Xray
echo -e "${YELLOW}配置 Xray...${NC}"
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 10000,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$VLESS_PATH"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF

# 配置 Nginx
echo -e "${YELLOW}配置 Nginx...${NC}"
cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    root /var/www/$DOMAIN;
    index index.html;

    # 网站路径
    location $WEB_PATH {
        try_files \$uri \$uri/ =404;
    }

    # VLESS 代理路径
    location $VLESS_PATH {
        if (\$http_upgrade != "websocket") {
            return 404;
        }
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
    }

    # 默认页面
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

# 启用站点配置
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# 测试 Nginx 配置
nginx -t

# 启动服务
echo -e "${YELLOW}启动服务...${NC}"
systemctl restart nginx
systemctl enable nginx
systemctl restart xray
systemctl enable xray

# 设置自动续期证书
(crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -

# 输出配置信息
echo -e "${GREEN}==================================${NC}"
echo -e "${GREEN}部署完成!${NC}"
echo -e "${GREEN}==================================${NC}"
echo -e "${YELLOW}VLESS 配置信息:${NC}"
echo -e "地址: ${GREEN}$DOMAIN${NC}"
echo -e "端口: ${GREEN}443${NC}"
echo -e "UUID: ${GREEN}$UUID${NC}"
echo -e "传输协议: ${GREEN}ws${NC}"
echo -e "路径: ${GREEN}$VLESS_PATH${NC}"
echo -e "TLS: ${GREEN}启用${NC}"
echo -e "SNI: ${GREEN}$DOMAIN${NC}"
echo ""
echo -e "${YELLOW}网站访问地址:${NC}"
echo -e "https://$DOMAIN$WEB_PATH"
echo ""

if [[ "$USE_CF" == "y" || "$USE_CF" == "Y" ]]; then
    echo -e "${YELLOW}Cloudflare 设置建议:${NC}"
    echo -e "1. 在 Cloudflare DNS 设置中添加 A 记录指向您的 VPS IP"
    echo -e "2. 开启 ${GREEN}代理状态 (橙色云)${NC}"
    echo -e "3. SSL/TLS 加密模式设置为 ${GREEN}完全(严格)${NC}"
    echo -e "4. 关闭 ${GREEN}Always Use HTTPS${NC} 以避免重定向循环"
    echo -e "5. 在客户端配置中使用优选 IP 可进一步提升速度"
    echo ""
fi

echo -e "${YELLOW}客户端配置示例 (通用格式):${NC}"
echo "vless://$UUID@$DOMAIN:443?encryption=none&security=tls&sni=$DOMAIN&type=ws&host=$DOMAIN&path=$VLESS_PATH#MyProxy"
echo ""
echo -e "${GREEN}请保存以上配置信息!${NC}"
echo -e "${YELLOW}日志查看命令:${NC}"
echo "journalctl -u xray -f"
echo "journalctl -u nginx -f"
