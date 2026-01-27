#!/bin/bash

###############################################################################
# Script Manager 完整一体化部署脚本
# 这是最终版本，包含所有必要的配置和修复
# 用法: bash deploy-complete-final.sh your-domain.com your-email@example.com
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

# 参数检查
if [ $# -lt 2 ]; then
    log_error "用法: bash deploy-complete-final.sh <domain> <email>"
    log_error "例如: bash deploy-complete-final.sh ss.18avfans.xyz admin@example.com"
    exit 1
fi

DOMAIN="$1"
EMAIL="$2"
PROJECT_DIR="/opt/script-manager"
HTTP_PORT="${3:-80}"
HTTPS_PORT="${4:-443}"

log_info "=========================================="
log_info "Script Manager 完整部署"
log_info "=========================================="
log_info "域名: $DOMAIN"
log_info "邮箱: $EMAIL"
log_info "HTTP 端口: $HTTP_PORT"
log_info "HTTPS 端口: $HTTPS_PORT"
log_info "=========================================="

# 第一步：检查和创建项目目录
log_info "第一步：检查和创建项目目录..."

if [ ! -d "$PROJECT_DIR" ]; then
    log_info "项目目录不存在，创建中..."
    mkdir -p "$PROJECT_DIR"
fi

cd "$PROJECT_DIR"

log_success "项目目录已就绪"

# 第二步：检查项目源代码
log_info "第二步：检查项目源代码..."

# 检查是否已有项目源代码
if [ ! -f "package.json" ]; then
    log_info "项目源代码不存在，从 CDN 下载..."
    
    # 下载项目源代码
    cd /tmp
    wget -q https://files.manuscdn.com/user_upload_by_module/session_file/310519663315496033/NxNpDfWHtbcHwJVh.gz -O script-manager-source.tar.gz
    tar -xzf script-manager-source.tar.gz
    
    # 复制到项目目录
    cp -r script-manager/* "$PROJECT_DIR/"
    cp -r script-manager/.* "$PROJECT_DIR/" 2>/dev/null || true
    
    # 清理
    rm -rf script-manager script-manager-source.tar.gz
    
    cd "$PROJECT_DIR"
    log_success "项目源代码已下载"
else
    log_success "项目源代码已存在"
fi

# 第三步：创建必要的目录
log_info "第三步：创建必要的目录..."

mkdir -p scripts
mkdir -p script-logs
mkdir -p ssl

log_success "目录已创建"

# 第四步：生成 .env 文件
log_info "第四步：生成 .env 文件..."

# 生成随机密钥
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32)
MYSQL_PASSWORD=$(openssl rand -base64 32)
JWT_SECRET=$(openssl rand -base64 32)
WEBHOOK_SECRET=$(openssl rand -base64 32)

cat > .env << EOF
# 数据库配置
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
MYSQL_USER=script_user
MYSQL_PASSWORD=$MYSQL_PASSWORD
MYSQL_DATABASE=script_manager
MYSQL_PORT=3306

# 后端配置
BACKEND_PORT=3000
NODE_ENV=production
JWT_SECRET=$JWT_SECRET
WEBHOOK_SECRET=$WEBHOOK_SECRET

# OAuth 配置（关键：这里使用您的域名）
OAUTH_SERVER_URL=http://$DOMAIN
VITE_OAUTH_PORTAL_URL=http://$DOMAIN

# 前端配置（关键：这些变量在构建时会被注入）
VITE_APP_ID=local-app
VITE_APP_TITLE=Script Manager
VITE_APP_LOGO=
VITE_FRONTEND_FORGE_API_URL=http://$DOMAIN/api
VITE_FRONTEND_FORGE_API_KEY=
VITE_ANALYTICS_ENDPOINT=
VITE_ANALYTICS_WEBSITE_ID=

# VPS Agent 配置
AGENT_PORT=5000
VPS_AGENT_URL=http://vps-agent:5000

# Nginx 配置
NGINX_PORT=$HTTP_PORT
NGINX_HTTPS_PORT=$HTTPS_PORT
EOF

log_success ".env 文件已生成"

# 第五步：创建修复后的 Dockerfile
log_info "第五步：创建修复后的 Dockerfile..."

cat > Dockerfile << 'DOCKERFILE_EOF'
FROM node:22-alpine

WORKDIR /app

# 安装 pnpm
RUN npm install -g pnpm

# 复制 package 文件
COPY package.json pnpm-lock.yaml ./

# 安装依赖
RUN pnpm install --frozen-lockfile

# 复制源代码
COPY . .

# 接收构建时的环境变量（这是关键！）
ARG VITE_APP_ID=local-app
ARG VITE_APP_TITLE="Script Manager"
ARG VITE_APP_LOGO=""
ARG VITE_OAUTH_PORTAL_URL=http://localhost:3000
ARG VITE_FRONTEND_FORGE_API_URL=http://localhost:3000/api
ARG VITE_FRONTEND_FORGE_API_KEY=""
ARG VITE_ANALYTICS_ENDPOINT=""
ARG VITE_ANALYTICS_WEBSITE_ID=""

# 设置环境变量供构建使用
ENV VITE_APP_ID=$VITE_APP_ID
ENV VITE_APP_TITLE=$VITE_APP_TITLE
ENV VITE_APP_LOGO=$VITE_APP_LOGO
ENV VITE_OAUTH_PORTAL_URL=$VITE_OAUTH_PORTAL_URL
ENV VITE_FRONTEND_FORGE_API_URL=$VITE_FRONTEND_FORGE_API_URL
ENV VITE_FRONTEND_FORGE_API_KEY=$VITE_FRONTEND_FORGE_API_KEY
ENV VITE_ANALYTICS_ENDPOINT=$VITE_ANALYTICS_ENDPOINT
ENV VITE_ANALYTICS_WEBSITE_ID=$VITE_ANALYTICS_WEBSITE_ID

# 构建应用（环境变量会被注入到前端）
RUN pnpm build

# 暴露端口
EXPOSE 3000

# 设置运行时环境变量
ENV NODE_ENV=production

# 运行应用
CMD ["pnpm", "start"]
DOCKERFILE_EOF

log_success "Dockerfile 已创建"

# 第六步：创建 docker-compose.yml
log_info "第六步：创建 docker-compose.yml..."

cat > docker-compose.yml << 'COMPOSE_EOF'
version: '3.8'

services:
  # MySQL 数据库
  mysql:
    image: mysql:8.0
    container_name: script-manager-mysql
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD:-root}
      MYSQL_DATABASE: ${MYSQL_DATABASE:-script_manager}
      MYSQL_USER: ${MYSQL_USER:-script_user}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD:-script_password}
    volumes:
      - mysql_data:/var/lib/mysql
    ports:
      - "${MYSQL_PORT:-3306}:3306"
    networks:
      - script-manager-net
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      timeout: 20s
      retries: 10

  # 后端应用
  backend:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        VITE_APP_ID: ${VITE_APP_ID:-local-app}
        VITE_APP_TITLE: ${VITE_APP_TITLE:-Script Manager}
        VITE_APP_LOGO: ${VITE_APP_LOGO:-}
        VITE_OAUTH_PORTAL_URL: ${VITE_OAUTH_PORTAL_URL:-http://localhost:3000}
        VITE_FRONTEND_FORGE_API_URL: ${VITE_FRONTEND_FORGE_API_URL:-http://localhost:3000/api}
        VITE_FRONTEND_FORGE_API_KEY: ${VITE_FRONTEND_FORGE_API_KEY:-}
        VITE_ANALYTICS_ENDPOINT: ${VITE_ANALYTICS_ENDPOINT:-}
        VITE_ANALYTICS_WEBSITE_ID: ${VITE_ANALYTICS_WEBSITE_ID:-}
    container_name: script-manager-backend
    environment:
      NODE_ENV: production
      DATABASE_URL: mysql://${MYSQL_USER:-script_user}:${MYSQL_PASSWORD:-script_password}@mysql:3306/${MYSQL_DATABASE:-script_manager}
      JWT_SECRET: ${JWT_SECRET:-your-jwt-secret-key-change-me}
      WEBHOOK_SECRET: ${WEBHOOK_SECRET:-your-webhook-secret-change-me}
      VPS_AGENT_URL: ${VPS_AGENT_URL:-http://vps-agent:5000}
      OAUTH_SERVER_URL: ${OAUTH_SERVER_URL:-http://localhost:3000}
      VITE_APP_TITLE: ${VITE_APP_TITLE:-Script Manager}
      VITE_APP_LOGO: ${VITE_APP_LOGO:-}
    ports:
      - "${BACKEND_PORT:-3000}:3000"
    depends_on:
      mysql:
        condition: service_healthy
    networks:
      - script-manager-net
    volumes:
      - ./scripts:/opt/scripts
    restart: unless-stopped

  # VPS Agent
  vps-agent:
    build:
      context: ./vps-agent
      dockerfile: Dockerfile
    container_name: script-manager-vps-agent
    environment:
      WEBHOOK_SECRET: ${WEBHOOK_SECRET:-your-webhook-secret-change-me}
      SCRIPTS_DIR: /opt/scripts
      LOGS_DIR: /opt/script-logs
      AGENT_PORT: 5000
      AGENT_HOST: 0.0.0.0
    ports:
      - "${AGENT_PORT:-5000}:5000"
    volumes:
      - ./scripts:/opt/scripts
      - ./script-logs:/opt/script-logs
    networks:
      - script-manager-net
    restart: unless-stopped

  # Nginx 反向代理
  nginx:
    image: nginx:alpine
    container_name: script-manager-nginx
    ports:
      - "${NGINX_PORT:-80}:80"
      - "${NGINX_HTTPS_PORT:-443}:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx-htpasswd:/etc/nginx/.htpasswd:ro
      - ./ssl:/etc/nginx/ssl:ro
    depends_on:
      - backend
    networks:
      - script-manager-net
    restart: unless-stopped

volumes:
  mysql_data:

networks:
  script-manager-net:
    driver: bridge
COMPOSE_EOF

log_success "docker-compose.yml 已创建"

# 第七步：创建 Nginx 配置
log_info "第七步：创建 Nginx 配置..."

cat > nginx.conf << 'NGINX_EOF'
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

        # 后端 API（不需要认证）
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

        # VPS Agent（不需要认证）
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

        # 前端应用（需要 HTTP Basic Auth）
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
NGINX_EOF

log_success "Nginx 配置已创建"

# 第八步：创建 HTTP Basic Auth
log_info "第八步：创建 HTTP Basic Auth..."

read -p "请输入管理员用户名 (默认: admin): " USERNAME
USERNAME=${USERNAME:-admin}

read -sp "请输入管理员密码: " PASSWORD
echo ""

if command -v htpasswd &> /dev/null; then
    echo "$PASSWORD" | htpasswd -i -c nginx-htpasswd "$USERNAME"
else
    log_warning "htpasswd 未安装，使用 openssl 生成..."
    HASH=$(openssl passwd -apr1 "$PASSWORD")
    echo "$USERNAME:$HASH" > nginx-htpasswd
fi

chmod 644 nginx-htpasswd

log_success "HTTP Basic Auth 已创建"
log_warning "用户名: $USERNAME"
log_warning "密码: $PASSWORD"

# 第九步：停止旧容器
log_info "第九步：停止旧容器..."

docker-compose down 2>/dev/null || true
sleep 3

log_success "旧容器已停止"

# 第十步：删除旧镜像
log_info "第十步：删除旧镜像..."

docker rmi script-manager-backend 2>/dev/null || true

log_success "旧镜像已删除"

# 第十一步：启动所有服务
log_info "第十一步：启动所有服务..."
log_warning "这可能需要 3-5 分钟，请耐心等待..."

docker-compose up -d --build

sleep 60

log_success "所有服务已启动"

# 第十二步：检查服务状态
log_info "第十二步：检查服务状态..."

echo "=========================================="
docker-compose ps
echo "=========================================="

# 第十三步：验证服务
log_info "第十三步：验证服务..."

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

if docker-compose ps | grep -q "script-manager-mysql.*Up"; then
    log_success "MySQL 服务正在运行"
else
    log_error "MySQL 服务未运行"
    docker-compose logs mysql | tail -100
    exit 1
fi

# 第十四步：显示环境变量
log_info "第十四步：显示环境变量..."

echo "=========================================="
echo "当前环境变量:"
echo "=========================================="
grep -E "OAUTH_SERVER_URL|VITE_OAUTH_PORTAL_URL|VITE_FRONTEND_FORGE_API_URL" .env
echo "=========================================="

# 第十五步：验证前端环境变量
log_info "第十五步：验证前端环境变量..."

echo "=========================================="
echo "前端环境变量（构建时注入）:"
echo "=========================================="
docker-compose exec -T backend env | grep -E "VITE_OAUTH_PORTAL_URL|VITE_FRONTEND_FORGE_API_URL" || log_warning "无法获取前端环境变量"
echo "=========================================="

log_success "部署完成！"
echo ""
echo "=========================================="
echo "Script Manager 部署信息"
echo "=========================================="
echo "访问地址: http://$DOMAIN:$HTTP_PORT"
echo "用户名: $USERNAME"
echo "密码: $PASSWORD"
echo ""
echo "常用命令:"
echo "  查看服务状态: docker-compose ps"
echo "  查看日志: docker-compose logs -f"
echo "  查看后端日志: docker-compose logs backend"
echo "  查看 Nginx 日志: docker-compose logs nginx"
echo "  重启服务: docker-compose restart"
echo "  停止服务: docker-compose down"
echo ""
echo "验证登录链接:"
echo "  1. 访问 http://$DOMAIN:$HTTP_PORT"
echo "  2. 点击登录按钮"
echo "  3. 检查跳转的 URL 是否包含 http://$DOMAIN（而不是 localhost:3000）"
echo "=========================================="
echo ""
