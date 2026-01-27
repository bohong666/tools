#!/bin/bash

###############################################################################
# Script Manager OAuth 和 HTTPS 配置修复脚本
# 用法: bash fix-oauth-https.sh your-domain.com
###############################################################################

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

PROJECT_DIR="/opt/script-manager"
DOMAIN="${1:-ss.18avfans.xyz}"
EMAIL="${2:-admin@example.com}"

log_info "开始修复 OAuth 和 HTTPS 配置..."
log_info "域名: $DOMAIN"

# 检查项目目录
if [ ! -d "$PROJECT_DIR" ]; then
    log_error "项目目录不存在: $PROJECT_DIR"
    exit 1
fi

cd $PROJECT_DIR

# 第一步：更新 .env 文件中的 OAuth 配置
log_info "第一步：更新 OAuth 配置..."

python3 << PYTHON_EOF
import os

env_file = '/opt/script-manager/.env'

# 读取现有的 .env 文件
env_vars = {}
with open(env_file, 'r') as f:
    for line in f:
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            key, value = line.split('=', 1)
            env_vars[key.strip()] = value.strip()

# 更新 OAuth 配置
domain = "$DOMAIN"
env_vars['OAUTH_SERVER_URL'] = f"http://{domain}"
env_vars['VITE_OAUTH_PORTAL_URL'] = f"http://{domain}"

# 创建新的 .env 文件内容
new_env_content = ""
with open(env_file, 'r') as f:
    for line in f:
        line = line.rstrip('\n')
        if line.startswith('OAUTH_SERVER_URL='):
            new_env_content += f"OAUTH_SERVER_URL=http://{domain}\n"
        elif line.startswith('VITE_OAUTH_PORTAL_URL='):
            new_env_content += f"VITE_OAUTH_PORTAL_URL=http://{domain}\n"
        else:
            new_env_content += line + "\n"

# 写入新的 .env 文件
with open(env_file, 'w') as f:
    f.write(new_env_content)

print("[SUCCESS] OAuth 配置已更新")
PYTHON_EOF

log_success "OAuth 配置已更新"

# 第二步：检查 SSL 证书
log_info "第二步：检查 SSL 证书..."

if [ -f "ssl/cert.pem" ] && [ -f "ssl/key.pem" ]; then
    log_success "SSL 证书已存在"
else
    log_warning "SSL 证书不存在"
    log_info "正在使用 Let's Encrypt 获取 SSL 证书..."
    
    # 创建 ssl 目录
    mkdir -p ssl
    
    # 停止 Nginx
    docker-compose stop nginx 2>/dev/null || true
    sleep 3
    
    # 获取 SSL 证书
    if command -v certbot &> /dev/null; then
        log_info "使用 Certbot 获取证书..."
        certbot certonly --standalone -d "$DOMAIN" --email "$EMAIL" --agree-tos --non-interactive 2>/dev/null || {
            log_warning "Certbot 获取证书失败，使用自签名证书"
            
            # 生成自签名证书
            openssl req -x509 -newkey rsa:2048 -keyout ssl/key.pem -out ssl/cert.pem -days 365 -nodes \
                -subj "/C=CN/ST=State/L=City/O=Organization/CN=$DOMAIN" 2>/dev/null
            
            log_success "自签名证书已生成"
        }
        
        # 如果 Certbot 成功，复制证书
        if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
            cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ssl/cert.pem
            cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ssl/key.pem
            log_success "Let's Encrypt 证书已复制"
        fi
    else
        log_warning "Certbot 未安装，使用自签名证书"
        
        # 生成自签名证书
        openssl req -x509 -newkey rsa:2048 -keyout ssl/key.pem -out ssl/cert.pem -days 365 -nodes \
            -subj "/C=CN/ST=State/L=City/O=Organization/CN=$DOMAIN" 2>/dev/null
        
        log_success "自签名证书已生成"
    fi
fi

# 第三步：更新 Nginx 配置以支持 HTTPS
log_info "第三步：更新 Nginx 配置..."

cat > nginx.conf << 'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    client_max_body_size 100M;

    # 后端应用
    upstream backend {
        server backend:3000;
    }

    # VPS Agent
    upstream vps_agent {
        server vps-agent:5000;
    }

    # HTTP 重定向到 HTTPS
    server {
        listen 80;
        server_name _;
        
        # 重定向到 HTTPS
        return 301 https://$host$request_uri;
    }

    # HTTPS 服务器
    server {
        listen 443 ssl http2;
        server_name _;

        # SSL 证书配置
        ssl_certificate /etc/nginx/ssl/cert.pem;
        ssl_certificate_key /etc/nginx/ssl/key.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5;
        ssl_prefer_server_ciphers on;

        # 后端 API
        location /api/ {
            proxy_pass http://backend;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection 'upgrade';
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_cache_bypass $http_upgrade;
            proxy_connect_timeout 60s;
            proxy_send_timeout 60s;
            proxy_read_timeout 60s;
        }

        # VPS Agent
        location /agent/ {
            proxy_pass http://vps-agent/;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection 'upgrade';
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_cache_bypass $http_upgrade;
        }

        # 前端应用（HTTP Basic Auth）
        location / {
            auth_basic "Script Manager";
            auth_basic_user_file /etc/nginx/.htpasswd;

            proxy_pass http://backend;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection 'upgrade';
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_cache_bypass $http_upgrade;
            proxy_connect_timeout 60s;
            proxy_send_timeout 60s;
            proxy_read_timeout 60s;
        }
    }
}
EOF

log_success "Nginx 配置已更新"

# 第四步：重启后端服务
log_info "第四步：重启后端服务..."
docker-compose restart backend
sleep 10

log_success "后端服务已重启"

# 第五步：启动 Nginx
log_info "第五步：启动 Nginx..."
docker-compose up -d nginx
sleep 5

# 第六步：验证配置
log_info "第六步：验证配置..."

if docker-compose ps | grep -q "script-manager-nginx.*Up"; then
    log_success "Nginx 已启动"
else
    log_error "Nginx 启动失败"
    docker-compose logs nginx | tail -50
    exit 1
fi

log_success "OAuth 和 HTTPS 配置修复完成！"
echo ""
echo "=========================================="
echo "修复完成"
echo "=========================================="
echo "请访问应用:"
echo "  HTTP:  http://$DOMAIN"
echo "  HTTPS: https://$DOMAIN"
echo ""
echo "注意: 如果使用自签名证书，浏览器会显示安全警告，这是正常的"
echo "=========================================="
echo ""
