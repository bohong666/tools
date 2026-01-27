#!/bin/bash

###############################################################################
# Script Manager 完全自包含部署脚本
# 用法: bash deploy-standalone.sh [domain] [email]
# 示例: bash deploy-standalone.sh ss.18avfans.xyz 18avfans@gmail.com
#
# 此脚本会自动从 GitHub 下载所有必要的文件
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
    echo "用法: bash deploy-standalone.sh <domain> [email]"
    echo "示例: bash deploy-standalone.sh ss.18avfans.xyz 18avfans@gmail.com"
    exit 1
fi

DOMAIN=$1
EMAIL=${2:-"admin@example.com"}
PROJECT_DIR="/opt/script-manager"
GITHUB_REPO="https://github.com/bohong666/tools/raw/refs/heads/main"

log_info "开始部署 Script Manager"
log_info "域名: $DOMAIN"
log_info "邮箱: $EMAIL"

# 检查 root 权限
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
apt-get install -y -qq apache2-utils git certbot python3-certbot-nginx curl

# 第五步：克隆项目
log_info "第五步：克隆项目..."
if [ ! -d "$PROJECT_DIR" ]; then
    mkdir -p /opt
    cd /opt
    
    log_info "从 GitHub 克隆项目..."
    git clone https://github.com/bohong666/tools.git script-manager-temp
    
    # 如果克隆的是 tools 仓库，我们需要找到 script-manager 目录
    if [ -d "script-manager-temp/script-manager" ]; then
        mv script-manager-temp/script-manager script-manager
        rm -rf script-manager-temp
    else
        # 如果目录结构不同，直接使用
        mv script-manager-temp script-manager
    fi
    
    cd script-manager
else
    log_warning "项目目录已存在，跳过克隆"
    cd $PROJECT_DIR
fi

# 第六步：生成环境变量
log_info "第六步：生成环境变量..."
if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        cp .env.example .env
    else
        log_warning ".env.example 不存在，创建基础 .env 文件"
        cat > .env << 'EOF'
MYSQL_ROOT_PASSWORD=root
MYSQL_DATABASE=script_manager
MYSQL_USER=script_user
MYSQL_PASSWORD=script_password
MYSQL_PORT=3306
NODE_ENV=production
JWT_SECRET=your-jwt-secret-key-change-me
WEBHOOK_SECRET=your-webhook-secret-change-me
VPS_AGENT_URL=http://vps-agent:5000
VITE_APP_TITLE=Script Manager
VITE_APP_LOGO=
BACKEND_PORT=3000
AGENT_PORT=5000
NGINX_PORT=80
NGINX_HTTPS_PORT=443
EOF
    fi
    
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

# 第八步：更新 Nginx 配置
log_info "第八步：更新 Nginx 配置..."
if [ -f nginx.conf ]; then
    sed -i "s/server_name _;/server_name $DOMAIN www.$DOMAIN;/" nginx.conf
    log_success "Nginx 配置已更新"
else
    log_warning "nginx.conf 不存在，跳过更新"
fi

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
    if certbot certonly --standalone -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos -m $EMAIL; then
        # 复制证书
        mkdir -p ssl
        cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem ssl/cert.pem
        cp /etc/letsencrypt/live/$DOMAIN/privkey.pem ssl/key.pem
        chmod 644 ssl/cert.pem ssl/key.pem
        
        # 启用 HTTPS 配置
        if [ -f nginx.conf ]; then
            sed -i 's/# server {/server {/g' nginx.conf
            sed -i 's/#     listen 443/    listen 443/g' nginx.conf
            sed -i 's/#     server_name/    server_name/g' nginx.conf
            sed -i 's/#     ssl_certificate/    ssl_certificate/g' nginx.conf
            sed -i 's/#     ssl_/    ssl_/g' nginx.conf
            sed -i 's/#     location/    location/g' nginx.conf
            sed -i 's/#     }/    }/g' nginx.conf
            sed -i 's/# }/}/g' nginx.conf
        fi
        
        log_success "SSL 证书已配置"
    else
        log_error "SSL 证书获取失败"
        log_warning "请检查域名是否已正确指向此 VPS"
        log_warning "您可以稍后手动运行: certbot certonly --standalone -d $DOMAIN"
    fi
    
    # 启动 Nginx
    docker-compose up -d nginx
    sleep 5
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
echo "密码: $ADMIN_PASSWORD"
echo ""
echo "访问地址:"
echo "  https://$DOMAIN"
echo ""
echo "后续步骤:"
echo "1. 访问 https://$DOMAIN 并登录"
echo "2. 修改管理员密码: htpasswd nginx-htpasswd admin"
echo "3. 修改 MySQL 密码: 编辑 .env 文件"
echo "4. 修改 JWT_SECRET 和 WEBHOOK_SECRET"
echo "5. 查看日志: docker-compose logs -f"
echo ""
echo "常用命令:"
echo "  查看服务状态: docker-compose ps"
echo "  查看日志: docker-compose logs -f"
echo "  重启服务: docker-compose restart"
echo "  停止服务: docker-compose down"
echo "  查看特定服务日志: docker-compose logs backend"
echo ""
echo "=========================================="
