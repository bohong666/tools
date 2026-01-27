#!/bin/bash

###############################################################################
# Script Manager 环境变量修复脚本 v3 (完整重建版本)
# 用法: bash fix-env-v3.sh
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

log_info "开始修复环境变量 (v3 - 完整重建版本)..."

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

log_info "备份原 .env 文件..."
cp .env .env.backup.$(date +%s)
log_success ".env 文件已备份"

log_info "提取现有的密钥..."

# 使用 Python 安全地提取和更新环境变量
python3 << 'PYTHON_EOF'
import os
import subprocess

env_file = '/opt/script-manager/.env'

# 读取现有的 .env 文件
env_vars = {}
if os.path.exists(env_file):
    with open(env_file, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                env_vars[key.strip()] = value.strip()

# 生成或保留密钥
def get_random_secret():
    return subprocess.check_output(['openssl', 'rand', '-base64', '32']).decode().strip()

jwt_secret = env_vars.get('JWT_SECRET', get_random_secret())
webhook_secret = env_vars.get('WEBHOOK_SECRET', get_random_secret())
mysql_password = env_vars.get('MYSQL_PASSWORD', 'script_password')

# 创建新的 .env 文件内容
new_env_content = f"""# MySQL 配置
MYSQL_ROOT_PASSWORD=root
MYSQL_DATABASE=script_manager
MYSQL_USER=script_user
MYSQL_PASSWORD={mysql_password}
MYSQL_PORT=3306

# Node.js 配置
NODE_ENV=production
BACKEND_PORT=3000
AGENT_PORT=5000

# 安全密钥
JWT_SECRET={jwt_secret}
WEBHOOK_SECRET={webhook_secret}

# OAuth 配置 (本地部署必须配置)
OAUTH_SERVER_URL=http://localhost:3000
VITE_OAUTH_PORTAL_URL=http://localhost:3000
VITE_APP_ID=local-app
OWNER_OPEN_ID=local-user
OWNER_NAME=Admin

# 应用配置
VITE_APP_TITLE=Script Manager
VITE_APP_LOGO=
VPS_AGENT_URL=http://vps-agent:5000

# Nginx 配置
NGINX_PORT=80
NGINX_HTTPS_PORT=8443

# 数据库连接字符串
DATABASE_URL=mysql://script_user:{mysql_password}@mysql:3306/script_manager

# Manus 内部 API (本地部署可忽略)
BUILT_IN_FORGE_API_URL=http://localhost:3000
BUILT_IN_FORGE_API_KEY=local-key
VITE_FRONTEND_FORGE_API_URL=http://localhost:3000
VITE_FRONTEND_FORGE_API_KEY=local-key
"""

# 写入新的 .env 文件
with open(env_file, 'w') as f:
    f.write(new_env_content)

print("[SUCCESS] .env 文件已更新")
PYTHON_EOF

log_success ".env 文件已更新"

# 显示更新后的内容
log_info "更新后的 .env 文件内容："
echo "=========================================="
cat .env | grep -v "^#" | grep -v "^$"
echo "=========================================="

# 停止所有容器
log_info "停止所有容器..."
docker-compose down
sleep 3

# 删除后端镜像（强制重新构建）
log_info "删除后端镜像..."
docker rmi script-manager-backend:latest 2>/dev/null || true
sleep 2

# 启动所有容器（会重新构建后端镜像）
log_info "启动所有容器（重新构建后端镜像）..."
log_warning "这可能需要 2-3 分钟，请耐心等待..."
docker-compose up -d --build backend
sleep 60

# 检查服务状态
log_info "检查服务状态..."
MAX_RETRIES=10
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if docker-compose ps | grep -q "script-manager-backend.*Up"; then
        log_success "后端服务已启动"
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
    log_error "后端服务启动失败"
    docker-compose logs backend
    exit 1
fi

# 显示后端日志
log_info "后端日志："
docker-compose logs backend | tail -30

log_success "环境变量修复完成！"
echo ""
echo "=========================================="
echo "修复完成"
echo "=========================================="
echo "请刷新浏览器页面，重新访问应用"
echo "访问地址: http://ss.18avfans.xyz"
echo "=========================================="
