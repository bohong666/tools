#!/bin/bash

# Nginx 反向代理部署脚本 (支持后续添加多个 VLESS 节点)
# Nginx 占用 443 端口，通过路径反代到本地 Xray 端口

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}==================================${NC}"
echo -e "${GREEN}Nginx 反向代理部署脚本${NC}"
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

# 停止现有服务避免冲突
echo -e "${YELLOW}检查并停止可能占用 443 端口的服务...${NC}"
systemctl stop nginx 2>/dev/null || true
systemctl stop xray 2>/dev/null || true

# 检查 443 端口占用
if lsof -Pi :443 -sTCP:LISTEN -t >/dev/null 2>&1 ; then
    echo -e "${RED}警告: 443 端口仍被占用${NC}"
    lsof -i :443
    read -p "是否强制结束占用进程? (y/n): " KILL_PROCESS
    if [[ "$KILL_PROCESS" == "y" ]]; then
        fuser -k 443/tcp 2>/dev/null || true
        sleep 2
    else
        echo -e "${RED}请手动释放 443 端口后重试${NC}"
        exit 1
    fi
fi

# 获取用户输入
read -p "请输入您的域名 (例如: example.com): " DOMAIN
read -p "请输入网站路径 (用于伪装，例如: /website 或直接回车使用根路径): " WEB_PATH
WEB_PATH=${WEB_PATH:-/}

echo ""
echo -e "${BLUE}提示: 后续添加 VLESS 节点时，使用以下配置:${NC}"
echo -e "  - Xray 监听端口: ${GREEN}10000, 10001, 10002...${NC} (本地端口)"
echo -e "  - WebSocket 路径: ${GREEN}/vless1, /vless2, /vless3...${NC}"
echo -e "  - 本脚本会创建通用的反代配置文件供你添加节点${NC}"
echo ""
read -p "按回车继续..."

echo -e "${YELLOW}开始安装必要组件...${NC}"

# 安装依赖
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    apt update
    apt install -y nginx certbot python3-certbot-nginx curl wget unzip lsof
elif [[ "$OS" == "centos" || "$OS" == "rhel" ]]; then
    yum install -y epel-release
    yum install -y nginx certbot python3-certbot-nginx curl wget unzip lsof
else
    echo -e "${RED}不支持的操作系统: $OS${NC}"
    exit 1
fi

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
certbot certonly --standalone -d $DOMAIN --agree-tos --register-unsafely-without-email --non-interactive

# 创建网站目录和伪装页面
mkdir -p /var/www/$DOMAIN
cat > /var/www/$DOMAIN/index.html <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>Welcome</title>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { 
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 20px;
        }
        .container { 
            background: white; 
            padding: 50px 40px;
            border-radius: 16px; 
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            max-width: 600px;
            width: 100%;
            text-align: center;
        }
        h1 { 
            color: #333; 
            font-size: 2.5em;
            margin-bottom: 20px;
            font-weight: 700;
        }
        p { 
            color: #666; 
            font-size: 1.1em;
            line-height: 1.6;
            margin-bottom: 15px;
        }
        .domain {
            color: #667eea;
            font-weight: 600;
        }
        .footer {
            margin-top: 30px;
            padding-top: 20px;
            border-top: 1px solid #eee;
            color: #999;
            font-size: 0.9em;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 Welcome</h1>
        <p>Your server <span class="domain">$DOMAIN</span> is running successfully.</p>
        <p>This is a sample landing page.</p>
        <div class="footer">
            Powered by Nginx
        </div>
    </div>
</body>
</html>
EOF

# 创建 Nginx 配置目录
mkdir -p /etc/nginx/conf.d/vless

# 创建主配置文件
echo -e "${YELLOW}配置 Nginx 主配置...${NC}"
cat > /etc/nginx/sites-available/$DOMAIN <<EOF
# HTTP 重定向到 HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

# HTTPS 主配置
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    # SSL 证书配置
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:HIGH:!aNULL:!MD5:!RC4:!DHE;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    # 安全头
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;

    # 网站根目录
    root /var/www/$DOMAIN;
    index index.html index.htm;

    # 网站路径
    location $WEB_PATH {
        try_files \$uri \$uri/ =404;
    }

    # 引入 VLESS 节点配置（通过独立文件管理）
    include /etc/nginx/conf.d/vless/*.conf;

    # 默认页面
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

# 创建 VLESS 节点配置说明文件
cat > /etc/nginx/conf.d/vless/README.txt <<EOF
===========================================
VLESS 节点反代配置目录
===========================================

使用说明：
1. 在这个目录创建 .conf 文件来添加新的 VLESS 节点反代
2. 每个节点一个文件，方便管理

示例配置文件名: vless1.conf, vless2.conf

配置模板:
-----------
# VLESS 节点 1
location /vless1 {
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
-----------

添加节点步骤:
1. 创建配置文件: nano /etc/nginx/conf.d/vless/vless1.conf
2. 粘贴上面的模板，修改路径和端口
3. 测试配置: nginx -t
4. 重载 Nginx: systemctl reload nginx
5. 配置对应的 Xray 监听相应端口 (10000, 10001...)

当前域名: $DOMAIN
证书路径: /etc/letsencrypt/live/$DOMAIN/

===========================================
EOF

# 创建一个示例配置文件
cat > /etc/nginx/conf.d/vless/example.conf.disabled <<EOF
# 示例 VLESS 节点配置 (重命名为 .conf 后生效)
# location /vless1 {
#     if (\$http_upgrade != "websocket") {
#         return 404;
#     }
#     proxy_redirect off;
#     proxy_pass http://127.0.0.1:10000;
#     proxy_http_version 1.1;
#     proxy_set_header Upgrade \$http_upgrade;
#     proxy_set_header Connection "upgrade";
#     proxy_set_header Host \$host;
#     proxy_set_header X-Real-IP \$remote_addr;
#     proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
#     proxy_read_timeout 300s;
# }
EOF

# 创建便捷添加节点的脚本
cat > /usr/local/bin/add-vless-proxy <<'SCRIPT'
#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}添加 VLESS 反代配置${NC}"
read -p "请输入 WebSocket 路径 (例如: /vless1): " PATH
read -p "请输入 Xray 监听的本地端口 (例如: 10000): " PORT

CONF_FILE="/etc/nginx/conf.d/vless/vless-${PORT}.conf"

cat > $CONF_FILE <<EOF
# VLESS 节点 - 端口 $PORT
location $PATH {
    if (\$http_upgrade != "websocket") {
        return 404;
    }
    proxy_redirect off;
    proxy_pass http://127.0.0.1:$PORT;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_read_timeout 300s;
}
EOF

echo -e "${YELLOW}配置已创建: $CONF_FILE${NC}"
echo -e "${YELLOW}测试 Nginx 配置...${NC}"
if nginx -t; then
    echo -e "${GREEN}配置测试通过，重载 Nginx...${NC}"
    systemctl reload nginx
    echo -e "${GREEN}完成! 请确保 Xray 在端口 $PORT 监听${NC}"
else
    echo -e "${RED}配置错误，请检查${NC}"
    rm $CONF_FILE
fi
SCRIPT

chmod +x /usr/local/bin/add-vless-proxy

# 启用站点配置
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# 测试 Nginx 配置
echo -e "${YELLOW}测试 Nginx 配置...${NC}"
nginx -t

# 启动 Nginx
echo -e "${YELLOW}启动 Nginx...${NC}"
systemctl restart nginx
systemctl enable nginx

# 设置自动续期证书
(crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -

# 输出配置信息
echo -e "${GREEN}==================================${NC}"
echo -e "${GREEN}Nginx 反代部署完成!${NC}"
echo -e "${GREEN}==================================${NC}"
echo ""
echo -e "${YELLOW}网站信息:${NC}"
echo -e "域名: ${GREEN}$DOMAIN${NC}"
echo -e "访问地址: ${GREEN}https://$DOMAIN${NC}"
echo -e "SSL 证书: ${GREEN}已配置并自动续期${NC}"
echo ""
echo -e "${YELLOW}添加 VLESS 节点步骤:${NC}"
echo -e "1. 运行你的 Xray 安装脚本:"
echo -e "   ${GREEN}bash <(curl -fsSL https://raw.githubusercontent.com/bohong666/tools/refs/heads/main/xray.sh)${NC}"
echo ""
echo -e "2. 配置 Xray 时注意:"
echo -e "   - 监听地址: ${GREEN}127.0.0.1${NC} (本地)"
echo -e "   - 监听端口: ${GREEN}10000${NC} (或 10001, 10002... 每个节点不同端口)"
echo -e "   - 传输方式: ${GREEN}WebSocket${NC}"
echo -e "   - WebSocket 路径: ${GREEN}/vless1${NC} (或 /vless2, /vless3...)"
echo ""
echo -e "3. Xray 配置完成后，添加 Nginx 反代:"
echo -e "   ${GREEN}add-vless-proxy${NC}"
echo -e "   然后按提示输入路径和端口"
echo ""
echo -e "${YELLOW}或者手动添加:${NC}"
echo -e "   nano /etc/nginx/conf.d/vless/vless1.conf"
echo -e "   (参考: /etc/nginx/conf.d/vless/README.txt)"
echo ""
echo -e "${YELLOW}管理命令:${NC}"
echo -e "查看配置: ${GREEN}cat /etc/nginx/conf.d/vless/README.txt${NC}"
echo -e "测试配置: ${GREEN}nginx -t${NC}"
echo -e "重载配置: ${GREEN}systemctl reload nginx${NC}"
echo -e "查看日志: ${GREEN}tail -f /var/log/nginx/error.log${NC}"
echo ""
echo -e "${BLUE}Cloudflare CDN 配置提示:${NC}"
echo -e "1. DNS 添加 A 记录指向 VPS IP"
echo -e "2. 启用代理 (橙色云图标)"
echo -e "3. SSL/TLS 模式: ${GREEN}完全(严格)${NC}"
echo -e "4. 使用优选 IP 可提升速度"
echo ""
echo -e "${GREEN}部署完成! Nginx 已占用 443 端口并准备好反代${NC}"
