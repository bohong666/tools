#!/bin/bash

###############################################################################
# Script Manager 完整启动脚本
# 用法: bash start-services.sh
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

log_info "开始启动 Script Manager..."

# 检查项目目录
if [ ! -d "$PROJECT_DIR" ]; then
    log_error "项目目录不存在: $PROJECT_DIR"
    exit 1
fi

cd $PROJECT_DIR

# 第一步：检查必要的文件
log_info "第一步：检查必要的文件..."

if [ ! -f .env ]; then
    log_error ".env 文件不存在"
    exit 1
fi

if [ ! -f docker-compose.yml ]; then
    log_error "docker-compose.yml 文件不存在"
    exit 1
fi

log_success ".env 和 docker-compose.yml 文件存在"

# 第二步：检查和创建必要的目录
log_info "第二步：检查和创建必要的目录..."

mkdir -p scripts
mkdir -p script-logs
mkdir -p ssl

log_success "目录已创建"

# 第三步：检查 nginx.conf 文件
log_info "第三步：检查 nginx.conf 文件..."

if [ ! -f nginx.conf ]; then
    log_warning "nginx.conf 文件不存在，创建默认配置..."
    
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

    # HTTP 服务器
    server {
        listen 80;
        server_name _;

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
            proxy_pass http://vps_agent/;
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
    
    log_success "nginx.conf 已创建"
else
    log_success "nginx.conf 文件存在"
fi

# 第四步：检查 nginx-htpasswd 文件
log_info "第四步：检查 nginx-htpasswd 文件..."

if [ ! -f nginx-htpasswd ]; then
    log_warning "nginx-htpasswd 文件不存在"
    log_info "请输入管理员用户名和密码"
    
    read -p "用户名 (默认: admin): " USERNAME
    USERNAME=${USERNAME:-admin}
    
    read -sp "密码: " PASSWORD
    echo ""
    
    # 生成 htpasswd 文件
    echo "$PASSWORD" | htpasswd -i -c nginx-htpasswd "$USERNAME"
    
    log_success "nginx-htpasswd 已创建"
else
    log_success "nginx-htpasswd 文件存在"
fi

# 第五步：停止旧容器
log_info "第五步：停止旧容器..."
docker-compose down 2>/dev/null || true
sleep 3

# 第六步：启动所有服务
log_info "第六步：启动所有服务..."
log_warning "这可能需要 1-2 分钟，请耐心等待..."

docker-compose up -d

sleep 30

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
    docker-compose logs backend | tail -50
    exit 1
fi

if docker-compose ps | grep -q "script-manager-nginx.*Up"; then
    log_success "Nginx 服务正在运行"
else
    log_error "Nginx 服务未运行"
    docker-compose logs nginx | tail -50
    exit 1
fi

if docker-compose ps | grep -q "script-manager-mysql.*Up"; then
    log_success "MySQL 服务正在运行"
else
    log_error "MySQL 服务未运行"
    docker-compose logs mysql | tail -50
    exit 1
fi

log_success "所有服务已启动！"
echo ""
echo "=========================================="
echo "启动完成"
echo "=========================================="
echo "请访问应用: http://ss.18avfans.xyz"
echo "用户名: $USERNAME"
echo "密码: [您设置的密码]"
echo "=========================================="
echo ""
echo "常用命令:"
echo "  查看服务状态: docker-compose ps"
echo "  查看日志: docker-compose logs -f"
echo "  查看后端日志: docker-compose logs backend"
echo "  查看 Nginx 日志: docker-compose logs nginx"
echo "  重启服务: docker-compose restart"
echo "  停止服务: docker-compose down"
echo ""
