#!/bin/bash

###############################################################################
# Script Manager 自定义端口部署脚本 (Custom Ports Version)
# 支持手动指定端口，避免与现有服务冲突
# 用法: bash deploy-custom-ports.sh [domain] [email] [http_port] [https_port]
# 示例: bash deploy-custom-ports.sh ss.18avfans.xyz 18avfans@gmail.com 80 8443
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
    echo "用法: bash deploy-custom-ports.sh <domain> [email] [http_port] [https_port]"
    echo "示例: bash deploy-custom-ports.sh ss.18avfans.xyz 18avfans@gmail.com 80 8443"
    echo ""
    echo "参数说明:"
    echo "  domain      - 您的域名（必需）"
    echo "  email       - Let's Encrypt 邮箱（可选，默认: admin@example.com）"
    echo "  http_port   - HTTP 端口（可选，默认: 80）"
    echo "  https_port  - HTTPS 端口（可选，默认: 443）"
    exit 1
fi

DOMAIN=$1
EMAIL=${2:-"admin@example.com"}
HTTP_PORT=${3:-80}
HTTPS_PORT=${4:-443}
PROJECT_DIR="/opt/script-manager"

log_info "开始部署 Script Manager (自定义端口版本)"
log_info "域名: $DOMAIN"
log_info "邮箱: $EMAIL"
log_info "HTTP 端口: $HTTP_PORT"
log_info "HTTPS 端口: $HTTPS_PORT"

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    log_error "请使用 sudo 运行此脚本"
    exit 1
fi

# 第一步：检查并清理旧容器
log_info "第一步：检查并清理旧容器..."
if docker ps -a | grep -q "script-manager"; then
    log_warning "检测到旧的 Script Manager 容器，正在清理..."
    docker-compose -f $PROJECT_DIR/docker-compose.yml down 2>/dev/null || true
    docker container prune -f 2>/dev/null || true
    docker network prune -f 2>/dev/null || true
    sleep 3
    log_success "旧容器已清理"
else
    log_success "没有旧容器"
fi

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
        
        # 允许 SSH
        ufw allow 22/tcp 2>/dev/null || true
        
        # 允许指定的 HTTP 和 HTTPS 端口
        ufw allow $HTTP_PORT/tcp 2>/dev/null || true
        ufw allow $HTTPS_PORT/tcp 2>/dev/null || true
        
        # 允许 Docker 内部通信
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

# 第八步：创建项目目录和配置文件
log_info "第八步：创建项目目录和配置文件..."
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR

# 创建 docker-compose.yml（使用自定义端口）
log_info "创建 docker-compose.yml..."
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
    image: node:22-alpine
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
    command: sh -c "npm install -g pnpm && pnpm install && pnpm build && pnpm start"

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
      - ./agent:/app
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

# 创建 nginx.conf
log_info "创建 nginx.conf..."
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
    client_max_body_size 20M;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript 
               application/json application/javascript application/xml+rss 
               application/rss+xml application/atom+xml image/svg+xml 
               text/x-component text/x-cross-domain-policy;

    upstream backend {
        server backend:3000;
    }

    upstream vps_agent {
        server vps-agent:5000;
    }

    server {
        listen 80;
        server_name _;
        
        location /health {
            access_log off;
            return 200 "healthy\n";
            add_header Content-Type text/plain;
        }

        location / {
            proxy_pass http://backend;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection 'upgrade';
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_cache_bypass $http_upgrade;
        }
    }

    server {
        listen 80;
        server_name agent.*;

        location / {
            auth_basic "VPS Agent API";
            auth_basic_user_file /etc/nginx/.htpasswd;

            proxy_pass http://vps_agent;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
}
EOF
log_success "nginx.conf 已创建"

# 创建 VPS Agent 脚本
log_info "创建 VPS Agent..."
mkdir -p agent
cat > agent/agent.py << 'EOF'
import os
import hmac
import hashlib
import json
from flask import Flask, request, jsonify
from datetime import datetime
import subprocess

app = Flask(__name__)

WEBHOOK_SECRET = os.getenv('WEBHOOK_SECRET', 'your-webhook-secret')
SCRIPTS_DIR = os.getenv('SCRIPTS_DIR', '/opt/scripts')
LOGS_DIR = os.getenv('LOGS_DIR', '/opt/script-logs')

os.makedirs(SCRIPTS_DIR, exist_ok=True)
os.makedirs(LOGS_DIR, exist_ok=True)

def verify_signature(payload, signature):
    expected_sig = hmac.new(
        WEBHOOK_SECRET.encode(),
        payload.encode(),
        hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(signature, expected_sig)

@app.route('/api/health', methods=['GET'])
def health():
    return jsonify({'status': 'healthy'}), 200

@app.route('/api/webhook', methods=['POST'])
def webhook():
    signature = request.headers.get('X-Webhook-Signature', '')
    payload = request.get_data(as_text=True)
    
    if not verify_signature(payload, signature):
        return jsonify({'error': 'Invalid signature'}), 401
    
    data = request.get_json()
    script_id = data.get('scriptId')
    name = data.get('name')
    content = data.get('content')
    
    script_path = os.path.join(SCRIPTS_DIR, f'{script_id}_{name}')
    os.makedirs(os.path.dirname(script_path), exist_ok=True)
    
    with open(script_path, 'w') as f:
        f.write(content)
    
    os.chmod(script_path, 0o755)
    
    return jsonify({'success': True}), 200

@app.route('/api/execute/<int:script_id>', methods=['POST'])
def execute(script_id):
    scripts = [f for f in os.listdir(SCRIPTS_DIR) if f.startswith(f'{script_id}_')]
    
    if not scripts:
        return jsonify({'error': 'Script not found'}), 404
    
    script_path = os.path.join(SCRIPTS_DIR, scripts[0])
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    log_file = os.path.join(LOGS_DIR, f'{script_id}_{timestamp}.log')
    
    try:
        result = subprocess.run(
            ['bash', script_path],
            capture_output=True,
            text=True,
            timeout=300
        )
        
        with open(log_file, 'w') as f:
            f.write(result.stdout)
            if result.stderr:
                f.write('\nSTDERR:\n' + result.stderr)
        
        return jsonify({
            'success': True,
            'returnCode': result.returncode,
            'stdout': result.stdout,
            'stderr': result.stderr,
            'logFile': log_file
        }), 200
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    port = int(os.getenv('AGENT_PORT', 5000))
    host = os.getenv('AGENT_HOST', '0.0.0.0')
    app.run(host=host, port=port, debug=False)
EOF
log_success "VPS Agent 已创建"

# 第九步：生成环境变量
log_info "第九步：生成环境变量..."
if [ ! -f .env ]; then
    JWT_SECRET=$(openssl rand -base64 32)
    WEBHOOK_SECRET=$(openssl rand -base64 32)
    MYSQL_PASSWORD=$(openssl rand -base64 16)
    
    python3 << EOF
env_content = """MYSQL_ROOT_PASSWORD=root
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
"""

with open('.env', 'w') as f:
    f.write(env_content)
EOF
    log_success ".env 文件已生成"
else
    log_warning ".env 文件已存在，跳过生成"
fi

# 第十步：创建 HTTP Basic Auth
log_info "第十步：创建 HTTP Basic Auth..."
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

# 第十一步：创建必要的目录
log_info "第十一步：创建必要的目录..."
mkdir -p scripts script-logs ssl
log_success "目录已创建"

# 第十二步：启动服务
log_info "第十二步：启动服务..."
docker-compose down 2>/dev/null || true
sleep 2
docker-compose up -d
sleep 20

# 检查服务状态
log_info "检查服务状态..."
if docker-compose ps | grep -q "Up"; then
    log_success "服务已启动"
else
    log_error "服务启动失败，请查看日志"
    docker-compose logs
    exit 1
fi

# 第十三步：获取 SSL 证书
log_info "第十三步：获取 SSL 证书..."
log_warning "请确保域名已指向此 VPS 的 IP 地址"
read -p "是否继续获取 SSL 证书？(y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    docker-compose stop nginx
    sleep 2
    
    if certbot certonly --standalone -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos -m $EMAIL; then
        mkdir -p ssl
        cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem ssl/cert.pem
        cp /etc/letsencrypt/live/$DOMAIN/privkey.pem ssl/key.pem
        chmod 644 ssl/cert.pem ssl/key.pem
        
        log_success "SSL 证书已配置"
    else
        log_error "SSL 证书获取失败"
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
echo "域名: https://$DOMAIN"
echo "HTTP 端口: $HTTP_PORT"
echo "HTTPS 端口: $HTTPS_PORT"
echo "用户名: admin"
echo "密码: $ADMIN_PASSWORD"
echo ""
echo "访问地址: http://$DOMAIN:$HTTP_PORT"
echo "          https://$DOMAIN:$HTTPS_PORT"
echo ""
echo "常用命令:"
echo "  查看服务状态: docker-compose ps"
echo "  查看日志: docker-compose logs -f"
echo "  重启服务: docker-compose restart"
echo "  停止服务: docker-compose down"
echo "  查看特定服务日志: docker-compose logs backend"
echo ""
echo "=========================================="
