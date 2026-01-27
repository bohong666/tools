#!/bin/bash

###############################################################################
# Script Manager 本地部署脚本 (Local Deployment)
# 使用已上传到 VPS 的 tar 文件进行部署
# 用法: bash deploy-local.sh [domain] [email] [http_port] [https_port] [tar_path]
# 示例: bash deploy-local.sh ss.18avfans.xyz 18avfans@gmail.com 80 8443 /tmp/script-manager-source.tar.gz
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
if [ $# -lt 1 ]; then
    log_error "缺少必要参数"
    echo "用法: bash deploy-local.sh <domain> [email] [http_port] [https_port] [tar_path]"
    echo "示例: bash deploy-local.sh ss.18avfans.xyz 18avfans@gmail.com 80 8443 /tmp/script-manager-source.tar.gz"
    exit 1
fi

DOMAIN=$1
EMAIL=${2:-"admin@example.com"}
HTTP_PORT=${3:-80}
HTTPS_PORT=${4:-443}
TAR_PATH=${5:-"/tmp/script-manager-source.tar.gz"}
PROJECT_DIR="/opt/script-manager"

log_info "开始部署 Script Manager (本地版本)"
log_info "域名: $DOMAIN"
log_info "邮箱: $EMAIL"
log_info "HTTP 端口: $HTTP_PORT"
log_info "HTTPS 端口: $HTTPS_PORT"
log_info "tar 文件路径: $TAR_PATH"

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    log_error "请使用 sudo 运行此脚本"
    exit 1
fi

# 检查 tar 文件是否存在
if [ ! -f "$TAR_PATH" ]; then
    log_error "tar 文件不存在: $TAR_PATH"
    exit 1
fi
log_success "tar 文件已找到"

# 第一步：清理旧环境
log_info "第一步：清理旧环境..."
if [ -d "$PROJECT_DIR" ]; then
    cd $PROJECT_DIR
    docker-compose down 2>/dev/null || true
    sleep 2
fi

docker container prune -f 2>/dev/null || true
docker network prune -f 2>/dev/null || true
log_success "旧环境已清理"

# 第二步：检查端口可用性
log_info "第二步：检查端口可用性..."

check_port() {
    local port=$1
    local port_name=$2
    
    if netstat -tuln 2>/dev/null | grep -q ":$port "; then
        log_warning "端口 $port ($port_name) 已被占用"
        return 0
    else
        log_success "端口 $port ($port_name) 可用"
        return 1
    fi
}

PORT_CONFLICT=false

if check_port $HTTP_PORT "HTTP"; then
    PORT_CONFLICT=true
fi

if check_port $HTTPS_PORT "HTTPS"; then
    PORT_CONFLICT=true
fi

if [ "$PORT_CONFLICT" = true ]; then
    log_warning "检测到端口冲突，请修改端口号后重新运行脚本"
    exit 1
fi

# 第三步：处理 UFW 防火墙
log_info "第三步：处理 UFW 防火墙..."
if command -v ufw &> /dev/null; then
    if ufw status | grep -q "Status: active"; then
        log_warning "检测到 UFW 防火墙已启用，正在配置..."
        
        ufw allow 22/tcp 2>/dev/null || true
        ufw allow $HTTP_PORT/tcp 2>/dev/null || true
        ufw allow $HTTPS_PORT/tcp 2>/dev/null || true
        ufw allow from 172.16.0.0/12 2>/dev/null || true
        
        log_success "UFW 防火墙已配置"
    fi
fi

# 第四步：更新系统
log_info "第四步：更新系统..."
apt-get update -qq
apt-get upgrade -y -qq

# 第五步：安装 Docker
log_info "第五步：安装 Docker..."
if ! command -v docker &> /dev/null; then
    apt-get install -y -qq docker.io
    systemctl start docker
    systemctl enable docker
    log_success "Docker 已安装"
else
    log_success "Docker 已存在"
    systemctl start docker 2>/dev/null || true
fi

# 第六步：安装 Docker Compose
log_info "第六步：安装 Docker Compose..."
if ! command -v docker-compose &> /dev/null; then
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose 2>/dev/null
    chmod +x /usr/local/bin/docker-compose
    log_success "Docker Compose 已安装"
else
    log_success "Docker Compose 已存在"
fi

# 第七步：安装必要工具
log_info "第七步：安装必要工具..."
apt-get install -y -qq apache2-utils git certbot python3-certbot-nginx curl netcat-openbsd psmisc net-tools

# 第八步：解压项目
log_info "第八步：解压项目..."
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR

log_info "从 $TAR_PATH 解压项目..."
tar -xzf "$TAR_PATH" --strip-components=1

if [ ! -f "package.json" ]; then
    log_error "解压失败或目录结构不正确，找不到 package.json"
    exit 1
fi

log_success "项目已解压"

# 第九步：创建 docker-compose.yml
log_info "第九步：创建 docker-compose.yml..."

cat > docker-compose.yml << EOF
services:
  mysql:
    image: mysql:8.0
    container_name: script-manager-mysql
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD:-root}
      MYSQL_DATABASE: \${MYSQL_DATABASE:-script_manager}
      MYSQL_USER: \${MYSQL_USER:-script_user}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD:-script_password}
    volumes:
      - mysql_data:/var/lib/mysql
    ports:
      - "\${MYSQL_PORT:-3306}:3306"
    networks:
      - script-manager-net
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      timeout: 20s
      retries: 10
    restart: unless-stopped

  backend:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: script-manager-backend
    working_dir: /app
    environment:
      NODE_ENV: production
      DATABASE_URL: mysql://\${MYSQL_USER:-script_user}:\${MYSQL_PASSWORD:-script_password}@mysql:3306/\${MYSQL_DATABASE:-script_manager}
      JWT_SECRET: \${JWT_SECRET:-your-jwt-secret-key-change-me}
      WEBHOOK_SECRET: \${WEBHOOK_SECRET:-your-webhook-secret-change-me}
      VPS_AGENT_URL: \${VPS_AGENT_URL:-http://vps-agent:5000}
    ports:
      - "\${BACKEND_PORT:-3000}:3000"
    depends_on:
      mysql:
        condition: service_healthy
    networks:
      - script-manager-net
    volumes:
      - ./scripts:/opt/scripts
    restart: unless-stopped

  vps-agent:
    image: python:3.11-slim
    container_name: script-manager-vps-agent
    working_dir: /app
    environment:
      WEBHOOK_SECRET: \${WEBHOOK_SECRET:-your-webhook-secret-change-me}
      SCRIPTS_DIR: /opt/scripts
      LOGS_DIR: /opt/script-logs
      AGENT_PORT: 5000
      AGENT_HOST: 0.0.0.0
    ports:
      - "\${AGENT_PORT:-5000}:5000"
    volumes:
      - ./scripts:/opt/scripts
      - ./script-logs:/opt/script-logs
      - ./vps-agent:/app
    networks:
      - script-manager-net
    restart: unless-stopped
    command: sh -c "pip install flask && python agent.py"

  nginx:
    image: nginx:alpine
    container_name: script-manager-nginx
    ports:
      - "$HTTP_PORT:80"
      - "$HTTPS_PORT:443"
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
EOF
log_success "docker-compose.yml 已创建"

# 第十步：创建 Dockerfile
log_info "第十步：创建 Dockerfile..."
cat > Dockerfile << 'EOF'
FROM node:22-alpine

WORKDIR /app

# 安装必要的工具
RUN apk add --no-cache python3 make g++

# 复制项目文件
COPY package.json pnpm-lock.yaml* ./
COPY . .

# 安装依赖
RUN npm install -g pnpm
RUN pnpm install --frozen-lockfile

# 构建项目
RUN pnpm build

# 启动应用
CMD ["pnpm", "start"]
EOF
log_success "Dockerfile 已创建"

# 第十一步：生成环境变量
log_info "第十一步：生成环境变量..."
if [ ! -f .env ]; then
    JWT_SECRET=$(openssl rand -base64 32)
    WEBHOOK_SECRET=$(openssl rand -base64 32)
    MYSQL_PASSWORD=$(openssl rand -base64 16)
    
    cat > .env << EOF
MYSQL_ROOT_PASSWORD=root
MYSQL_DATABASE=script_manager
MYSQL_USER=script_user
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MYSQL_PORT=3306
NODE_ENV=production
JWT_SECRET=${JWT_SECRET}
WEBHOOK_SECRET=${WEBHOOK_SECRET}
VPS_AGENT_URL=http://vps-agent:5000
VITE_APP_TITLE=Script Manager
VITE_APP_LOGO=
BACKEND_PORT=3000
AGENT_PORT=5000
NGINX_PORT=$HTTP_PORT
NGINX_HTTPS_PORT=$HTTPS_PORT
EOF
    log_success ".env 文件已生成"
else
    log_warning ".env 文件已存在，跳过生成"
fi

# 第十二步：创建 HTTP Basic Auth
log_info "第十二步：创建 HTTP Basic Auth..."
if [ ! -f nginx-htpasswd ]; then
    log_info "为管理员账户设置密码..."
    read -p "请输入管理员密码 (默认: admin123): " ADMIN_PASSWORD
    ADMIN_PASSWORD=${ADMIN_PASSWORD:-"admin123"}
    
    htpasswd -c -b nginx-htpasswd admin "$ADMIN_PASSWORD"
    chmod 644 nginx-htpasswd
    log_success "HTTP Basic Auth 已创建"
    log_warning "用户名: admin"
    log_warning "密码: $ADMIN_PASSWORD"
else
    log_warning "nginx-htpasswd 已存在，跳过创建"
fi

# 第十三步：创建必要的目录
log_info "第十三步：创建必要的目录..."
mkdir -p scripts script-logs ssl
log_success "目录已创建"

# 第十四步：启动服务
log_info "第十四步：启动服务..."
log_info "这可能需要 3-5 分钟，请耐心等待..."

docker-compose down 2>/dev/null || true
sleep 2
docker-compose up -d
sleep 60

# 检查服务状态
log_info "检查服务状态..."
MAX_RETRIES=10
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if docker-compose ps | grep -q "script-manager-backend.*Up"; then
        log_success "所有服务已启动"
        break
    else
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            log_warning "等待服务启动... ($RETRY_COUNT/$MAX_RETRIES)"
            sleep 10
        fi
    fi
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    log_error "后端服务启动失败，请查看日志"
    docker-compose logs backend
    exit 1
fi

# 第十五步：获取 SSL 证书
log_info "第十五步：获取 SSL 证书..."
log_warning "请确保域名已指向此 VPS 的 IP 地址"
read -p "是否继续获取 SSL 证书？(y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    docker-compose stop nginx
    sleep 2
    
    if certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos -m $EMAIL; then
        mkdir -p ssl
        cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem ssl/cert.pem
        cp /etc/letsencrypt/live/$DOMAIN/privkey.pem ssl/key.pem
        chmod 644 ssl/cert.pem ssl/key.pem
        
        log_success "SSL 证书已配置"
    else
        log_error "SSL 证书获取失败"
        log_warning "您可以稍后手动运行: certbot certonly --standalone -d $DOMAIN"
    fi
    
    docker-compose up -d nginx
    sleep 5
else
    log_warning "跳过 SSL 证书配置"
    docker-compose up -d nginx
fi

# 完成
log_success "部署完成！"
echo ""
echo "=========================================="
echo "Script Manager 部署信息"
echo "=========================================="
echo "域名: $DOMAIN"
echo "HTTP 端口: $HTTP_PORT"
echo "HTTPS 端口: $HTTPS_PORT"
echo "用户名: admin"
echo "密码: $ADMIN_PASSWORD"
echo ""
echo "访问地址: http://$DOMAIN:$HTTP_PORT"
if [ "$HTTPS_PORT" != "443" ]; then
    echo "          https://$DOMAIN:$HTTPS_PORT"
else
    echo "          https://$DOMAIN"
fi
echo ""
echo "常用命令 (在 $PROJECT_DIR 目录中执行):"
echo "  查看服务状态: docker-compose ps"
echo "  查看日志: docker-compose logs -f"
echo "  查看特定服务日志: docker-compose logs backend"
echo "  重启服务: docker-compose restart"
echo "  停止服务: docker-compose down"
echo ""
echo "故障排查:"
echo "  如果看到 502 错误，请运行: docker-compose logs backend"
echo "  检查后端是否正常启动"
echo ""
echo "=========================================="
