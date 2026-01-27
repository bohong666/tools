#!/bin/bash

###############################################################################
# Script Manager 完整重建和修复脚本
# 用法: bash rebuild-and-fix.sh your-domain.com
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

log_info "开始完整重建和修复..."
log_info "域名: $DOMAIN"

# 检查项目目录
if [ ! -d "$PROJECT_DIR" ]; then
    log_error "项目目录不存在: $PROJECT_DIR"
    exit 1
fi

cd $PROJECT_DIR

# 第一步：更新 .env 文件中的所有环境变量
log_info "第一步：更新环境变量..."

python3 << 'PYTHON_EOF'
import os
import re

env_file = '/opt/script-manager/.env'
domain = os.environ.get('DOMAIN', 'ss.18avfans.xyz')

# 读取现有的 .env 文件
with open(env_file, 'r') as f:
    content = f.read()

# 更新所有相关的 URL 环境变量
replacements = {
    r'OAUTH_SERVER_URL=.*': f'OAUTH_SERVER_URL=http://{domain}',
    r'VITE_OAUTH_PORTAL_URL=.*': f'VITE_OAUTH_PORTAL_URL=http://{domain}',
    r'VITE_FRONTEND_FORGE_API_URL=.*': f'VITE_FRONTEND_FORGE_API_URL=http://{domain}/api',
}

for pattern, replacement in replacements.items():
    if re.search(pattern, content):
        content = re.sub(pattern, replacement, content)
    else:
        # 如果不存在，添加到文件末尾
        content += f'\n{replacement}\n'

# 写入更新后的 .env 文件
with open(env_file, 'w') as f:
    f.write(content)

print("[SUCCESS] 环境变量已更新")
PYTHON_EOF

export DOMAIN="$DOMAIN"
python3 << PYTHON_EOF
import os
import re

env_file = '/opt/script-manager/.env'
domain = os.environ.get('DOMAIN', 'ss.18avfans.xyz')

# 读取现有的 .env 文件
with open(env_file, 'r') as f:
    content = f.read()

# 更新所有相关的 URL 环境变量
replacements = {
    r'OAUTH_SERVER_URL=.*': f'OAUTH_SERVER_URL=http://{domain}',
    r'VITE_OAUTH_PORTAL_URL=.*': f'VITE_OAUTH_PORTAL_URL=http://{domain}',
    r'VITE_FRONTEND_FORGE_API_URL=.*': f'VITE_FRONTEND_FORGE_API_URL=http://{domain}/api',
}

for pattern, replacement in replacements.items():
    if re.search(pattern, content):
        content = re.sub(pattern, replacement, content)
    else:
        # 如果不存在，添加到文件末尾
        content += f'\n{replacement}\n'

# 写入更新后的 .env 文件
with open(env_file, 'w') as f:
    f.write(content)

print("[SUCCESS] 环境变量已更新")
PYTHON_EOF

log_success "环境变量已更新"

# 第二步：停止所有容器
log_info "第二步：停止所有容器..."
docker-compose down
sleep 3

log_success "容器已停止"

# 第三步：删除旧的后端镜像以强制重建
log_info "第三步：删除旧镜像..."
docker rmi script-manager-backend 2>/dev/null || true
log_success "旧镜像已删除"

# 第四步：生成 SSL 证书
log_info "第四步：生成 SSL 证书..."

mkdir -p ssl

if [ ! -f "ssl/cert.pem" ] || [ ! -f "ssl/key.pem" ]; then
    log_warning "SSL 证书不存在，生成自签名证书..."
    
    openssl req -x509 -newkey rsa:2048 -keyout ssl/key.pem -out ssl/cert.pem -days 365 -nodes \
        -subj "/C=CN/ST=State/L=City/O=Organization/CN=$DOMAIN" 2>/dev/null
    
    log_success "自签名证书已生成"
else
    log_success "SSL 证书已存在"
fi

# 第五步：更新 Nginx 配置以支持 HTTPS
log_info "第五步：更新 Nginx 配置..."

cat > nginx.conf << EOF
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

    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';

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
        return 301 https://\$host\$request_uri;
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

        # 后端 API（不需要认证）
        location /api/ {
            proxy_pass http://backend;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection 'upgrade';
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_cache_bypass \$http_upgrade;
            proxy_connect_timeout 60s;
            proxy_send_timeout 60s;
            proxy_read_timeout 60s;
        }

        # VPS Agent（不需要认证）
        location /agent/ {
            proxy_pass http://vps-agent/;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection 'upgrade';
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_cache_bypass \$http_upgrade;
        }

        # 前端应用（需要 HTTP Basic Auth）
        location / {
            auth_basic "Script Manager";
            auth_basic_user_file /etc/nginx/.htpasswd;

            proxy_pass http://backend;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection 'upgrade';
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_cache_bypass \$http_upgrade;
            proxy_connect_timeout 60s;
            proxy_send_timeout 60s;
            proxy_read_timeout 60s;
        }
    }
}
EOF

log_success "Nginx 配置已更新"

# 第六步：重新构建和启动所有容器
log_info "第六步：重新构建和启动所有容器..."
log_warning "这可能需要 3-5 分钟，请耐心等待..."

docker-compose up -d --build

sleep 60

# 第七步：检查服务状态
log_info "第七步：检查服务状态..."

echo "=========================================="
docker-compose ps
echo "=========================================="

# 第八步：验证服务
log_info "第八步：验证服务..."

if docker-compose ps | grep -q "script-manager-backend.*Up"; then
    log_success "后端服务正在运行"
else
    log_error "后端服务未运行"
    docker-compose logs backend | tail -100
    exit 1
fi

if docker-compose ps | grep -q "script-manager-nginx.*Up"; then
    log_success "Nginx 服务正在运行"
else
    log_error "Nginx 服务未运行"
    docker-compose logs nginx | tail -100
    exit 1
fi

# 第九步：显示环境变量
log_info "第九步：显示当前环境变量..."

echo "=========================================="
echo "当前环境变量:"
echo "=========================================="
grep -E "OAUTH_SERVER_URL|VITE_OAUTH_PORTAL_URL|VITE_FRONTEND_FORGE_API_URL" /opt/script-manager/.env || true
echo "=========================================="

log_success "完整重建和修复完成！"
echo ""
echo "=========================================="
echo "修复完成"
echo "=========================================="
echo "请访问应用:"
echo "  HTTP:  http://$DOMAIN (会自动重定向到 HTTPS)"
echo "  HTTPS: https://$DOMAIN"
echo ""
echo "注意事项:"
echo "  1. 如果使用自签名证书，浏览器会显示安全警告，这是正常的"
echo "  2. 登录链接现在应该正确指向您的域名"
echo "  3. 如果仍然有问题，请运行以下命令查看日志:"
echo "     docker-compose logs backend"
echo "     docker-compose logs nginx"
echo "=========================================="
echo ""
