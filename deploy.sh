#!/bin/bash

###############################################################################
# Script Manager 一键部署脚本
# 用法: bash deploy.sh [domain] [email]
# 示例: bash deploy.sh example.com admin@example.com
###############################################################################

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# 检查参数
if [ $# -lt 1 ]; then
    log_error "缺少必要参数"
    echo "用法: bash deploy.sh <domain> [email]"
    echo "示例: bash deploy.sh example.com admin@example.com"
    exit 1
fi

DOMAIN=$1
EMAIL=${2:-"admin@example.com"}
PROJECT_DIR="/opt/script-manager"

log_info "开始部署 Script Manager"
log_info "域名: $DOMAIN"
log_info "邮箱: $EMAIL"

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
    log_error "请使用 sudo 运行此脚本"
    exit 1
fi

# 第一步：更新系统
log_info "第一步：更新系统..."
apt-get update -qq
apt-get upgrade -y -qq

# 第二步：安装 Docker
log_info "第二步：安装 Docker..."
if ! command -v docker &> /dev/null; then
    apt-get install -y -qq docker.io
    systemctl start docker
    systemctl enable docker
    log_success "Docker 已安装"
else
    log_success "Docker 已存在"
fi

# 第三步：安装 Docker Compose
log_info "第三步：安装 Docker Compose..."
if ! command -v docker-compose &> /dev/null; then
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    log_success "Docker Compose 已安装"
else
    log_success "Docker Compose 已存在"
fi

# 第四步：安装必要工具
log_info "第四步：安装必要工具..."
apt-get install -y -qq apache2-utils git certbot python3-certbot-nginx

# 第五步：克隆项目
log_info "第五步：克隆项目..."
if [ ! -d "$PROJECT_DIR" ]; then
    mkdir -p /opt
    cd /opt
    git clone <repository-url> script-manager
    cd script-manager
else
    log_warning "项目目录已存在，跳过克隆"
    cd $PROJECT_DIR
fi

# 第六步：生成环境变量
log_info "第六步：生成环境变量..."
if [ ! -f .env ]; then
    cp .env.example .env
    
    # 生成随机密钥
    JWT_SECRET=$(openssl rand -base64 32)
    WEBHOOK_SECRET=$(openssl rand -base64 32)
    MYSQL_PASSWORD=$(openssl rand -base64 16)
    
    # 更新 .env 文件
    sed -i "s/MYSQL_PASSWORD=.*/MYSQL_PASSWORD=$MYSQL_PASSWORD/" .env
    sed -i "s/JWT_SECRET=.*/JWT_SECRET=$JWT_SECRET/" .env
    sed -i "s/WEBHOOK_SECRET=.*/WEBHOOK_SECRET=$WEBHOOK_SECRET/" .env
    
    log_success ".env 文件已生成"
else
    log_warning ".env 文件已存在，跳过生成"
fi

# 第七步：创建 HTTP Basic Auth
log_info "第七步：创建 HTTP Basic Auth..."
if [ ! -f nginx-htpasswd ]; then
    htpasswd -c -b nginx-htpasswd admin admin123
    chmod 644 nginx-htpasswd
    log_success "HTTP Basic Auth 已创建"
    log_warning "默认密码: admin123 (强烈建议修改！)"
else
    log_warning "nginx-htpasswd 已存在，跳过创建"
fi

# 第八步：更新 Nginx 配置
log_info "第八步：更新 Nginx 配置..."
sed -i "s/server_name _;/server_name $DOMAIN www.$DOMAIN;/" nginx.conf
log_success "Nginx 配置已更新"

# 第九步：启动服务
log_info "第九步：启动服务..."
docker-compose up -d
sleep 10

# 检查服务状态
if docker-compose ps | grep -q "Up"; then
    log_success "服务已启动"
else
    log_error "服务启动失败，请查看日志"
    docker-compose logs
    exit 1
fi

# 第十步：获取 SSL 证书
log_info "第十步：获取 SSL 证书..."
log_warning "请确保域名已指向此 VPS 的 IP 地址"
read -p "是否继续获取 SSL 证书？(y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    # 停止 Nginx
    docker-compose stop nginx
    sleep 2
    
    # 获取证书
    certbot certonly --standalone -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos -m $EMAIL
    
    # 复制证书
    mkdir -p ssl
    cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem ssl/cert.pem
    cp /etc/letsencrypt/live/$DOMAIN/privkey.pem ssl/key.pem
    chmod 644 ssl/cert.pem ssl/key.pem
    
    # 启用 HTTPS 配置
    sed -i 's/# server {/server {/g' nginx.conf
    sed -i 's/#     listen 443/    listen 443/g' nginx.conf
    sed -i 's/#     server_name/    server_name/g' nginx.conf
    sed -i 's/#     ssl_certificate/    ssl_certificate/g' nginx.conf
    sed -i 's/#     ssl_/    ssl_/g' nginx.conf
    sed -i 's/#     location/    location/g' nginx.conf
    sed -i 's/#     }/    }/g' nginx.conf
    sed -i 's/# }/}/g' nginx.conf
    
    # 启动 Nginx
    docker-compose up -d nginx
    sleep 5
    
    log_success "SSL 证书已配置"
else
    log_warning "跳过 SSL 证书配置，应用将以 HTTP 方式运行"
    docker-compose up -d nginx
fi

# 完成
log_success "部署完成！"
echo ""
echo "=========================================="
echo "Script Manager 部署信息"
echo "=========================================="
echo "域名: https://$DOMAIN"
echo "用户名: admin"
echo "密码: admin123 (请立即修改！)"
echo ""
echo "后续步骤:"
echo "1. 访问 https://$DOMAIN 并登录"
echo "2. 修改管理员密码: htpasswd nginx-htpasswd admin"
echo "3. 修改 MySQL 密码: 编辑 .env 文件"
echo "4. 修改 JWT_SECRET 和 WEBHOOK_SECRET"
echo "5. 查看日志: docker-compose logs -f"
echo ""
echo "更多信息请查看 VPS_DEPLOYMENT_GUIDE.md"
echo "=========================================="
