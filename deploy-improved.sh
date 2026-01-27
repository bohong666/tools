#!/bin/bash

###############################################################################
# Script Manager 一键部署脚本 (改进版)
# 用法: bash deploy-improved.sh [domain] [email] [--local-path /path/to/project]
# 示例: 
#   bash deploy-improved.sh example.com admin@example.com
#   bash deploy-improved.sh example.com admin@example.com --local-path /home/user/script-manager
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

# 默认值
PROJECT_DIR="/opt/script-manager"
USE_LOCAL_PATH=false
LOCAL_PATH=""

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --local-path)
            USE_LOCAL_PATH=true
            LOCAL_PATH="$2"
            shift 2
            ;;
        *)
            if [ -z "$DOMAIN" ]; then
                DOMAIN="$1"
            elif [ -z "$EMAIL" ]; then
                EMAIL="$1"
            fi
            shift
            ;;
    esac
done

# 检查参数
if [ -z "$DOMAIN" ]; then
    log_error "缺少必要参数"
    echo "用法: bash deploy-improved.sh <domain> [email] [--local-path /path/to/project]"
    echo ""
    echo "示例 1 - 从本地克隆:"
    echo "  bash deploy-improved.sh example.com admin@example.com --local-path /home/user/script-manager"
    echo ""
    echo "示例 2 - 从 GitHub 克隆 (需要修改脚本中的 GITHUB_REPO):"
    echo "  bash deploy-improved.sh example.com admin@example.com"
    exit 1
fi

EMAIL=${EMAIL:-"admin@example.com"}

log_info "开始部署 Script Manager"
log_info "域名: $DOMAIN"
log_info "邮箱: $EMAIL"

if [ "$USE_LOCAL_PATH" = true ]; then
    log_info "使用本地路径: $LOCAL_PATH"
fi

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

# 第五步：克隆或复制项目
log_info "第五步：处理项目文件..."
if [ "$USE_LOCAL_PATH" = true ]; then
    # 从本地路径复制
    if [ ! -d "$LOCAL_PATH" ]; then
        log_error "本地路径不存在: $LOCAL_PATH"
        exit 1
    fi
    
    if [ ! -d "$PROJECT_DIR" ]; then
        log_info "从 $LOCAL_PATH 复制项目到 $PROJECT_DIR"
        cp -r "$LOCAL_PATH" "$PROJECT_DIR"
    else
        log_warning "项目目录已存在，跳过复制"
    fi
else
    # 从 GitHub 克隆
    if [ ! -d "$PROJECT_DIR" ]; then
        log_info "从 GitHub 克隆项目..."
        mkdir -p /opt
        cd /opt
        
        # 这里需要您替换为实际的 GitHub 仓库 URL
        GITHUB_REPO="https://github.com/your-username/script-manager.git"
        
        if [ "$GITHUB_REPO" = "https://github.com/your-username/script-manager.git" ]; then
            log_error "请修改脚本中的 GITHUB_REPO 变量为您的实际仓库地址"
            log_error "找到这一行: GITHUB_REPO=\"https://github.com/your-username/script-manager.git\""
            log_error "替换为您的仓库地址，例如: GITHUB_REPO=\"https://github.com/myname/script-manager.git\""
            exit 1
        fi
        
        git clone "$GITHUB_REPO" script-manager
        cd script-manager
    else
        log_warning "项目目录已存在，跳过克隆"
        cd $PROJECT_DIR
    fi
fi

cd $PROJECT_DIR

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
    log_warning "生成的密钥已保存到 .env 文件"
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
    certbot certonly --standalone -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos -m $EMAIL
    
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
echo "密码: $ADMIN_PASSWORD"
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
echo ""
echo "更多信息请查看 VPS_DEPLOYMENT_GUIDE.md"
echo "=========================================="
