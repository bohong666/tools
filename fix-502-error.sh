#!/bin/bash

###############################################################################
# Script Manager 502 错误诊断和修复脚本
# 用法: bash fix-502-error.sh
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

log_info "开始诊断 502 错误..."

# 检查项目目录
if [ ! -d "$PROJECT_DIR" ]; then
    log_error "项目目录不存在: $PROJECT_DIR"
    exit 1
fi

cd $PROJECT_DIR

# 第一步：检查所有容器状态
log_info "第一步：检查容器状态..."
echo "=========================================="
docker-compose ps
echo "=========================================="

# 第二步：检查后端是否正常运行
log_info "第二步：检查后端服务..."
if docker-compose ps | grep -q "script-manager-backend.*Up"; then
    log_success "后端服务正在运行"
else
    log_error "后端服务未运行"
    log_info "查看后端日志："
    docker-compose logs backend | tail -50
    exit 1
fi

# 第三步：检查 Nginx 配置
log_info "第三步：检查 Nginx 配置..."
if [ -f nginx.conf ]; then
    log_success "nginx.conf 文件存在"
    log_info "Nginx 配置内容（upstream 部分）："
    grep -A 10 "upstream backend" nginx.conf || log_warning "未找到 upstream backend 配置"
else
    log_error "nginx.conf 文件不存在"
    exit 1
fi

# 第四步：检查 Nginx 容器日志
log_info "第四步：检查 Nginx 日志..."
echo "=========================================="
docker-compose logs nginx | tail -50
echo "=========================================="

# 第五步：测试后端连接
log_info "第五步：测试后端连接..."
if docker-compose exec -T backend curl -s http://localhost:3000/api/trpc/auth.me 2>/dev/null | grep -q "error\|success"; then
    log_success "后端 API 响应正常"
else
    log_warning "后端 API 响应异常，但这可能是正常的"
fi

# 第六步：检查网络连接
log_info "第六步：检查容器网络..."
docker-compose exec -T backend ping -c 1 nginx 2>/dev/null && log_success "后端可以连接到 Nginx" || log_warning "后端无法连接到 Nginx"

# 第七步：重启 Nginx
log_info "第七步：重启 Nginx..."
docker-compose restart nginx
sleep 5

# 第八步：再次检查状态
log_info "第八步：再次检查 Nginx 状态..."
if docker-compose ps | grep -q "script-manager-nginx.*Up"; then
    log_success "Nginx 已重启并运行"
else
    log_error "Nginx 启动失败"
    docker-compose logs nginx | tail -50
    exit 1
fi

log_success "诊断和修复完成！"
echo ""
echo "=========================================="
echo "修复完成"
echo "=========================================="
echo "请刷新浏览器页面，重新访问应用"
echo "访问地址: http://ss.18avfans.xyz"
echo "=========================================="
echo ""
echo "如果仍然出现 502 错误，请运行以下命令查看详细日志："
echo "  docker-compose logs nginx"
echo "  docker-compose logs backend"
echo ""
