#!/bin/bash

###############################################################################
# Script Manager 环境变量修复脚本
# 用法: bash fix-env.sh
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

log_info "开始修复环境变量..."

# 检查项目目录
if [ ! -d "$PROJECT_DIR" ]; then
    log_error "项目目录不存在: $PROJECT_DIR"
    exit 1
fi

cd $PROJECT_DIR

# 检查 .env 文件
if [ ! -f .env ]; then
    log_error ".env 文件不存在"
    exit 1
fi

log_info "读取当前 .env 文件..."

# 生成必要的环境变量
log_info "生成必要的环境变量..."

# 获取当前的 JWT_SECRET 和 WEBHOOK_SECRET
JWT_SECRET=$(grep "^JWT_SECRET=" .env | cut -d'=' -f2 || echo "")
WEBHOOK_SECRET=$(grep "^WEBHOOK_SECRET=" .env | cut -d'=' -f2 || echo "")

# 如果没有，生成新的
if [ -z "$JWT_SECRET" ]; then
    JWT_SECRET=$(openssl rand -base64 32)
    log_info "生成新的 JWT_SECRET"
fi

if [ -z "$WEBHOOK_SECRET" ]; then
    WEBHOOK_SECRET=$(openssl rand -base64 32)
    log_info "生成新的 WEBHOOK_SECRET"
fi

# 创建新的 .env 文件
log_info "更新 .env 文件..."

cat > .env.new << EOF
# MySQL 配置
MYSQL_ROOT_PASSWORD=root
MYSQL_DATABASE=script_manager
MYSQL_USER=script_user
MYSQL_PASSWORD=$(grep "^MYSQL_PASSWORD=" .env | cut -d'=' -f2 || echo "script_password")
MYSQL_PORT=3306

# Node.js 配置
NODE_ENV=production
BACKEND_PORT=3000
AGENT_PORT=5000

# 安全密钥
JWT_SECRET=${JWT_SECRET}
WEBHOOK_SECRET=${WEBHOOK_SECRET}

# OAuth 配置（Manus 内部使用，本地部署可忽略）
OAUTH_SERVER_URL=http://localhost:3000
VITE_OAUTH_PORTAL_URL=http://localhost:3000

# 应用配置
VITE_APP_TITLE=Script Manager
VITE_APP_LOGO=
VPS_AGENT_URL=http://vps-agent:5000

# Nginx 配置
NGINX_PORT=80
NGINX_HTTPS_PORT=8443

# 其他配置
DATABASE_URL=mysql://script_user:$(grep "^MYSQL_PASSWORD=" .env | cut -d'=' -f2 || echo "script_password")@mysql:3306/script_manager
EOF

# 备份原文件
cp .env .env.backup
log_success ".env 文件已备份为 .env.backup"

# 替换文件
mv .env.new .env
log_success ".env 文件已更新"

# 重启服务
log_info "重启后端服务..."
docker-compose restart backend
sleep 10

# 检查服务状态
log_info "检查服务状态..."
if docker-compose ps | grep -q "script-manager-backend.*Up"; then
    log_success "后端服务已重启"
else
    log_error "后端服务启动失败"
    docker-compose logs backend
    exit 1
fi

log_success "环境变量修复完成！"
echo ""
echo "=========================================="
echo "修复完成"
echo "=========================================="
echo "请刷新浏览器页面，重新访问应用"
echo "访问地址: http://ss.18avfans.xyz"
echo "=========================================="
