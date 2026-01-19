#!/bin/bash

# Komari 服务器监控探针快速部署脚本
# 使用官方安装脚本 + Nginx 反向代理集成

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}==================================${NC}"
echo -e "${GREEN}Komari 监控探针快速部署${NC}"
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
read -p "访问路径 (例如: / 或 /monitor) [/]: " BASE_PATH
BASE_PATH=${BASE_PATH:-/}

# 检测 Komari 默认端口
KOMARI_PORT=25774

echo ""
echo -e "${YELLOW}Komari 配置信息:${NC}"
echo -e "默认端口: ${GREEN}$KOMARI_PORT${NC}"
echo -e "访问路径: ${GREEN}$BASE_PATH${NC}"
echo -e "域名: ${GREEN}$DOMAIN${NC}"
echo ""
read -p "确认开始安装? (y/n): " CONFIRM

if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo -e "${YELLOW}已取消${NC}"
    exit 0
fi

# 安装 Komari（使用官方脚本）
echo -e "${YELLOW}下载并运行 Komari 官方安装脚本...${NC}"
cd /tmp
curl -fsSL https://raw.githubusercontent.com/komari-monitor/komari/main/install-komari.sh -o install-komari.sh
chmod +x install-komari.sh

# 运行官方安装脚本
echo -e "${YELLOW}正在安装 Komari...${NC}"
./install-komari.sh

# 等待服务启动
echo -e "${YELLOW}等待 Komari 服务启动...${NC}"
sleep 5

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
cp /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-available/${DOMAIN}.backup.$(date +%Y%m%d_%H%M%S)

# 如果是根路径，替换整个配置
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
    # 如果是子路径，在 VLESS 配置前添加 location
    sed -i "/include \/etc\/nginx\/conf.d\/vless/i \    # Komari 监控面板\n    location ${BASE_PATH} {\n        proxy_pass http://127.0.0.1:${KOMARI_PORT}${BASE_PATH};\n        proxy_http_version 1.1;\n        proxy_set_header Upgrade \$http_upgrade;\n        proxy_set_header Connection \"upgrade\";\n        proxy_set_header Host \$host;\n        proxy_set_header X-Real-IP \$remote_addr;\n        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto \$scheme;\n        proxy_read_timeout 300s;\n        proxy_buffering off;\n    }\n" /etc/nginx/sites-available/$DOMAIN
fi

# 测试 Nginx 配置
echo -e "${YELLOW}测试 Nginx 配置...${NC}"
if nginx -t 2>&1 | grep -q "successful"; then
    systemctl reload nginx
    echo -e "${GREEN}Nginx 配置更新成功${NC}"
else
    echo -e "${RED}Nginx 配置错误，恢复最新备份${NC}"
    LATEST_BACKUP=$(ls -t /etc/nginx/sites-available/${DOMAIN}.backup.* 2>/dev/null | head -1)
    if [ -n "$LATEST_BACKUP" ]; then
        cp "$LATEST_BACKUP" /etc/nginx/sites-available/$DOMAIN
        nginx -t
    fi
    exit 1
fi

# 输出部署信息
echo ""
echo -e "${GREEN}==================================${NC}"
echo -e "${GREEN}Komari 部署完成!${NC}"
echo -e "${GREEN}==================================${NC}"
echo ""
echo -e "${YELLOW}访问信息:${NC}"
echo -e "面板地址: ${GREEN}https://${DOMAIN}${BASE_PATH}${NC}"
echo -e "默认端口: ${GREEN}${KOMARI_PORT}${NC} (通过 Nginx 反代到 443)"
echo ""
echo -e "${BLUE}首次访问会引导您创建管理员账号${NC}"
echo ""
echo -e "${YELLOW}Agent 安装 (在被监控服务器上运行):${NC}"
echo -e "${GREEN}curl -fsSL https://raw.githubusercontent.com/komari-monitor/komari-agent/main/install-agent.sh | bash -s -- --server https://${DOMAIN}${BASE_PATH}${NC}"
echo ""
echo -e "${YELLOW}管理命令:${NC}"
echo -e "启动: ${GREEN}systemctl start komari${NC}"
echo -e "停止: ${GREEN}systemctl stop komari${NC}"
echo -e "重启: ${GREEN}systemctl restart komari${NC}"
echo -e "状态: ${GREEN}systemctl status komari${NC}"
echo -e "日志: ${GREEN}journalctl -u komari -f${NC}"
echo ""
echo -e "配置文件: ${GREEN}/opt/komari/config.yaml${NC}"
echo -e "数据目录: ${GREEN}/opt/komari/data/${NC}"
echo ""

# 获取 Komari 的实际配置信息
if [ -f /opt/komari/config.yaml ]; then
    echo -e "${YELLOW}Komari 配置文件位置:${NC}"
    echo -e "${GREEN}/opt/komari/config.yaml${NC}"
    echo ""
    echo -e "${BLUE}提示: 可以编辑此文件修改配置，然后重启服务${NC}"
    echo -e "${BLUE}systemctl restart komari${NC}"
fi

# 保存配置信息
INFO_FILE="/root/komari-info.txt"
cat > $INFO_FILE <<EOF
Komari 监控系统部署信息
生成时间: $(date)
=================================

访问地址: https://${DOMAIN}${BASE_PATH}
本地端口: ${KOMARI_PORT}

首次访问会引导您创建管理员账号

Agent 安装命令 (在被监控服务器上运行):
curl -fsSL https://raw.githubusercontent.com/komari-monitor/komari-agent/main/install-agent.sh | bash -s -- --server https://${DOMAIN}${BASE_PATH}

目录信息:
- 安装目录: /opt/komari
- 配置文件: /opt/komari/config.yaml
- 数据目录: /opt/komari/data

管理命令:
- 启动: systemctl start komari
- 停止: systemctl stop komari
- 重启: systemctl restart komari
- 日志: journalctl -u komari -f

Nginx 配置备份:
$(ls -t /etc/nginx/sites-available/${DOMAIN}.backup.* 2>/dev/null | head -1)

官方文档: https://github.com/komari-monitor/komari
EOF

echo -e "${GREEN}配置信息已保存到: ${INFO_FILE}${NC}"
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}下一步操作:${NC}"
echo -e "${BLUE}1. 访问 https://${DOMAIN}${BASE_PATH} 创建管理员账号${NC}"
echo -e "${BLUE}2. 在被监控服务器上安装 Agent${NC}"
echo -e "${BLUE}3. 在 Komari 面板中查看服务器状态${NC}"
echo -e "${BLUE}========================================${NC}"
