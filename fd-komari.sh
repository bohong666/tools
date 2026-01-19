#!/bin/bash

# Komari 服务器监控探针部署脚本
# 集成到现有 Nginx + VLESS 架构
# GitHub: https://github.com/komari-monitor/komari

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}==================================${NC}"
echo -e "${GREEN}Komari 监控探针部署脚本${NC}"
echo -e "${GREEN}==================================${NC}"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 此脚本必须以 root 权限运行${NC}" 
   exit 1
fi

# 获取现有域名
DOMAIN=$(grep -oP 'server_name\s+\K[^;]+' /etc/nginx/sites-enabled/* 2>/dev/null | head -1 | xargs)
if [ -z "$DOMAIN" ]; then
    read -p "请输入域名: " DOMAIN
fi

echo -e "${YELLOW}当前域名: ${GREEN}$DOMAIN${NC}"
echo ""

# 配置选项
read -p "Komari 监听端口 [8080]: " KOMARI_PORT
KOMARI_PORT=${KOMARI_PORT:-8080}

read -p "访问路径 (例如: / 或 /monitor) [/]: " BASE_PATH
BASE_PATH=${BASE_PATH:-/}

read -p "是否需要密码保护? (y/n) [n]: " NEED_AUTH
NEED_AUTH=${NEED_AUTH:-n}

if [[ "$NEED_AUTH" == "y" || "$NEED_AUTH" == "Y" ]]; then
    read -p "设置管理员用户名 [admin]: " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-admin}
    read -sp "设置管理员密码: " ADMIN_PASS
    echo ""
fi

# 检测系统
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
fi

# 安装依赖
echo -e "${YELLOW}安装依赖...${NC}"
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    apt update
    apt install -y curl wget git build-essential
elif [[ "$OS" == "centos" || "$OS" == "rhel" ]]; then
    yum install -y curl wget git gcc make
fi

# 安装 Go (Komari 需要 Go 编译)
if ! command -v go &> /dev/null; then
    echo -e "${YELLOW}安装 Go...${NC}"
    GO_VERSION="1.21.5"
    wget https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz
    rm go${GO_VERSION}.linux-amd64.tar.gz
    
    # 配置环境变量
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
    export PATH=$PATH:/usr/local/go/bin
fi

# 创建工作目录
KOMARI_DIR="/opt/komari"
mkdir -p $KOMARI_DIR
cd $KOMARI_DIR

# 克隆项目
echo -e "${YELLOW}下载 Komari...${NC}"
if [ -d "$KOMARI_DIR/komari" ]; then
    echo -e "${YELLOW}检测到已存在的 Komari 目录，正在更新...${NC}"
    cd $KOMARI_DIR/komari
    git pull
else
    git clone https://github.com/komari-monitor/komari.git
    cd $KOMARI_DIR/komari
fi

# 创建配置文件
echo -e "${YELLOW}配置 Komari...${NC}"

cat > config.yaml <<EOF
server:
  # 监听地址 (只监听本地，通过 Nginx 反代)
  listen: "127.0.0.1:${KOMARI_PORT}"
  
  # 基础路径
  base_path: "${BASE_PATH}"
  
  # 数据库配置 (使用 SQLite)
  database:
    type: "sqlite"
    path: "${KOMARI_DIR}/data/komari.db"

# 监控配置
monitor:
  # 数据保留时间 (天)
  retention_days: 30
  
  # 采集间隔 (秒)
  interval: 60
  
  # 告警配置
  alert:
    enabled: true
    # CPU 使用率告警阈值
    cpu_threshold: 80
    # 内存使用率告警阈值
    memory_threshold: 85
    # 磁盘使用率告警阈值
    disk_threshold: 90

# Agent 配置
agent:
  # Agent 通信密钥 (用于 Agent 连接)
  secret: "$(openssl rand -hex 32)"

# 安全配置
security:
  # JWT 密钥
  jwt_secret: "$(openssl rand -hex 32)"
  
  # 会话超时 (分钟)
  session_timeout: 1440
EOF

# 如果需要密码保护
if [[ "$NEED_AUTH" == "y" || "$NEED_AUTH" == "Y" ]]; then
    cat >> config.yaml <<EOF

# 认证配置
auth:
  enabled: true
  admin_user: "${ADMIN_USER}"
  admin_password: "${ADMIN_PASS}"
EOF
else
    cat >> config.yaml <<EOF

# 认证配置 (已禁用)
auth:
  enabled: false
EOF
fi

# 创建数据目录
mkdir -p $KOMARI_DIR/data

# 编译 Komari
echo -e "${YELLOW}编译 Komari...${NC}"
go mod download
go build -o komari-server cmd/server/main.go

# 创建 systemd 服务
echo -e "${YELLOW}创建系统服务...${NC}"
cat > /etc/systemd/system/komari.service <<EOF
[Unit]
Description=Komari Monitoring Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${KOMARI_DIR}/komari
ExecStart=${KOMARI_DIR}/komari/komari-server -c ${KOMARI_DIR}/komari/config.yaml
Restart=always
RestartSec=10

# 资源限制
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable komari
systemctl start komari

# 等待服务启动
echo -e "${YELLOW}等待服务启动...${NC}"
sleep 3

# 检查服务状态
if systemctl is-active --quiet komari; then
    echo -e "${GREEN}Komari 服务启动成功${NC}"
else
    echo -e "${RED}Komari 服务启动失败，查看日志:${NC}"
    journalctl -u komari -n 20 --no-pager
    exit 1
fi

# 配置 Nginx 反向代理
echo -e "${YELLOW}配置 Nginx 反向代理...${NC}"

# 备份现有配置
cp /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-available/${DOMAIN}.backup

# 如果是根路径，需要修改整个配置
if [ "$BASE_PATH" == "/" ]; then
    cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:HIGH:!aNULL:!MD5:!RC4:!DHE;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    # Komari 反向代理
    location / {
        proxy_pass http://127.0.0.1:${KOMARI_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        
        # WebSocket 支持
        proxy_buffering off;
    }
    
    # 引入 VLESS 节点配置
    include /etc/nginx/conf.d/vless/*.conf;
}
EOF
else
    # 如果是子路径，添加 location 块
    # 读取现有配置，在 VLESS include 之前插入
    TEMP_CONF="/tmp/nginx_temp_$DOMAIN.conf"
    
    # 提取 server 块内容（VLESS include 之前的部分）
    sed -n '/listen 443/,/include \/etc\/nginx\/conf.d\/vless/p' /etc/nginx/sites-available/$DOMAIN | head -n -1 > $TEMP_CONF
    
    # 添加 Komari location
    cat >> $TEMP_CONF <<EOF
    
    # Komari 监控面板
    location ${BASE_PATH} {
        proxy_pass http://127.0.0.1:${KOMARI_PORT}${BASE_PATH};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_buffering off;
    }
    
    # 引入 VLESS 节点配置
    include /etc/nginx/conf.d/vless/*.conf;
}
EOF
    
    # 重新组装完整配置
    sed -n '1,/listen 443/p' /etc/nginx/sites-available/$DOMAIN | head -n -1 > /etc/nginx/sites-available/${DOMAIN}.new
    cat $TEMP_CONF >> /etc/nginx/sites-available/${DOMAIN}.new
    mv /etc/nginx/sites-available/${DOMAIN}.new /etc/nginx/sites-available/$DOMAIN
    rm $TEMP_CONF
fi

# 测试 Nginx 配置
echo -e "${YELLOW}测试 Nginx 配置...${NC}"
if nginx -t; then
    systemctl reload nginx
    echo -e "${GREEN}Nginx 配置更新成功${NC}"
else
    echo -e "${RED}Nginx 配置错误，恢复备份${NC}"
    mv /etc/nginx/sites-available/${DOMAIN}.backup /etc/nginx/sites-available/$DOMAIN
    nginx -t
    exit 1
fi

# 获取 Agent 密钥
AGENT_SECRET=$(grep "secret:" $KOMARI_DIR/komari/config.yaml | head -1 | awk '{print $2}' | tr -d '"')

# 输出部署信息
echo ""
echo -e "${GREEN}==================================${NC}"
echo -e "${GREEN}Komari 部署完成!${NC}"
echo -e "${GREEN}==================================${NC}"
echo ""
echo -e "${YELLOW}访问信息:${NC}"
echo -e "面板地址: ${GREEN}https://${DOMAIN}${BASE_PATH}${NC}"

if [[ "$NEED_AUTH" == "y" || "$NEED_AUTH" == "Y" ]]; then
    echo -e "管理员账号: ${GREEN}${ADMIN_USER}${NC}"
    echo -e "管理员密码: ${GREEN}${ADMIN_PASS}${NC}"
else
    echo -e "认证: ${YELLOW}未启用（建议启用）${NC}"
fi

echo ""
echo -e "${YELLOW}Agent 配置信息:${NC}"
echo -e "Server URL: ${GREEN}https://${DOMAIN}${BASE_PATH}${NC}"
echo -e "Agent Secret: ${GREEN}${AGENT_SECRET}${NC}"
echo ""
echo -e "${BLUE}在被监控服务器上安装 Agent:${NC}"
echo -e "${GREEN}bash <(curl -fsSL https://raw.githubusercontent.com/komari-monitor/komari/main/scripts/install-agent.sh)${NC}"
echo ""

echo -e "${YELLOW}管理命令:${NC}"
echo -e "启动: ${GREEN}systemctl start komari${NC}"
echo -e "停止: ${GREEN}systemctl stop komari${NC}"
echo -e "重启: ${GREEN}systemctl restart komari${NC}"
echo -e "状态: ${GREEN}systemctl status komari${NC}"
echo -e "日志: ${GREEN}journalctl -u komari -f${NC}"
echo ""
echo -e "配置文件: ${GREEN}${KOMARI_DIR}/komari/config.yaml${NC}"
echo -e "数据目录: ${GREEN}${KOMARI_DIR}/data/${NC}"
echo ""

# 保存配置信息
INFO_FILE="/root/komari-info.txt"
cat > $INFO_FILE <<EOF
Komari 监控系统部署信息
生成时间: $(date)
=================================

访问地址: https://${DOMAIN}${BASE_PATH}
$(if [[ "$NEED_AUTH" == "y" || "$NEED_AUTH" == "Y" ]]; then
echo "管理员账号: ${ADMIN_USER}"
echo "管理员密码: ${ADMIN_PASS}"
fi)

Agent 配置:
Server URL: https://${DOMAIN}${BASE_PATH}
Agent Secret: ${AGENT_SECRET}

安装 Agent 命令:
bash <(curl -fsSL https://raw.githubusercontent.com/komari-monitor/komari/main/scripts/install-agent.sh)

目录信息:
- 安装目录: ${KOMARI_DIR}/komari
- 配置文件: ${KOMARI_DIR}/komari/config.yaml
- 数据目录: ${KOMARI_DIR}/data

管理命令:
- 启动: systemctl start komari
- 停止: systemctl stop komari
- 重启: systemctl restart komari
- 日志: journalctl -u komari -f

备份配置: /etc/nginx/sites-available/${DOMAIN}.backup
EOF

echo -e "${GREEN}配置信息已保存到: ${INFO_FILE}${NC}"
echo ""
echo -e "${BLUE}提示: 请妥善保管 Agent Secret，它用于 Agent 连接认证${NC}"
