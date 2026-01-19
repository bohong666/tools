#!/bin/bash

# VLESS 节点添加脚本 - 适配 Nginx 反代架构
# 支持多节点配置，每个节点独立端口

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_FILE="/usr/local/etc/xray/config.json"
NGINX_VLESS_DIR="/etc/nginx/conf.d/vless"

echo -e "${GREEN}==================================${NC}"
echo -e "${GREEN}VLESS 节点添加工具${NC}"
echo -e "${GREEN}适配 Nginx 反代架构${NC}"
echo -e "${GREEN}==================================${NC}"

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 此脚本必须以 root 权限运行${NC}" 
   exit 1
fi

# 检查 Xray 是否已安装
if ! command -v xray &> /dev/null; then
    echo -e "${YELLOW}Xray 未安装，正在安装...${NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

# 检查 Nginx 是否运行
if ! systemctl is-active --quiet nginx; then
    echo -e "${RED}错误: Nginx 未运行，请先部署 Nginx 反代${NC}"
    exit 1
fi

# 检查配置目录
if [ ! -d "$NGINX_VLESS_DIR" ]; then
    echo -e "${RED}错误: Nginx VLESS 配置目录不存在${NC}"
    echo -e "${YELLOW}请先运行 Nginx 反代部署脚本${NC}"
    exit 1
fi

# 获取当前已使用的端口
echo -e "${YELLOW}检测已使用的端口...${NC}"
USED_PORTS=()
if [ -f "$CONFIG_FILE" ]; then
    USED_PORTS=($(jq -r '.inbounds[]? | select(.port != null) | .port' "$CONFIG_FILE" 2>/dev/null || echo ""))
fi

# 建议下一个可用端口
SUGGESTED_PORT=10000
if [ ${#USED_PORTS[@]} -gt 0 ]; then
    LAST_PORT=$(printf '%s\n' "${USED_PORTS[@]}" | sort -n | tail -1)
    SUGGESTED_PORT=$((LAST_PORT + 1))
fi

echo ""
echo -e "${BLUE}当前已使用端口: ${USED_PORTS[*]:-无}${NC}"
echo -e "${BLUE}建议使用端口: ${GREEN}$SUGGESTED_PORT${NC}"
echo ""

# 获取用户输入
read -p "请输入节点名称 (例如: node1): " NODE_NAME
read -p "请输入监听端口 [回车使用 $SUGGESTED_PORT]: " PORT
PORT=${PORT:-$SUGGESTED_PORT}

# 验证端口
if [[ ! "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
    echo -e "${RED}错误: 端口必须在 1024-65535 之间${NC}"
    exit 1
fi

# 检查端口是否已被使用
if printf '%s\n' "${USED_PORTS[@]}" | grep -q "^${PORT}$"; then
    echo -e "${RED}错误: 端口 $PORT 已被其他节点使用${NC}"
    exit 1
fi

read -p "请输入 WebSocket 路径 (例如: /vless1): " WS_PATH
if [[ ! "$WS_PATH" =~ ^/ ]]; then
    WS_PATH="/$WS_PATH"
fi

# 选择传输协议
echo ""
echo -e "${YELLOW}请选择传输协议:${NC}"
echo "1) WebSocket (推荐，适合 CDN)"
echo "2) TCP (直连)"
read -p "请选择 [1]: " PROTOCOL_CHOICE
PROTOCOL_CHOICE=${PROTOCOL_CHOICE:-1}

# 生成 UUID
UUID=$(cat /proc/sys/kernel/random/uuid)

echo ""
echo -e "${YELLOW}节点配置信息:${NC}"
echo -e "节点名称: ${GREEN}$NODE_NAME${NC}"
echo -e "监听端口: ${GREEN}127.0.0.1:$PORT${NC}"
echo -e "UUID: ${GREEN}$UUID${NC}"
if [ "$PROTOCOL_CHOICE" == "1" ]; then
    echo -e "传输协议: ${GREEN}WebSocket${NC}"
    echo -e "WS 路径: ${GREEN}$WS_PATH${NC}"
else
    echo -e "传输协议: ${GREEN}TCP${NC}"
fi
echo ""
read -p "确认添加此节点? (y/n): " CONFIRM

if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo -e "${YELLOW}已取消${NC}"
    exit 0
fi

# 创建新的 inbound 配置
if [ "$PROTOCOL_CHOICE" == "1" ]; then
    NEW_INBOUND=$(cat <<EOF
{
  "tag": "$NODE_NAME",
  "port": $PORT,
  "listen": "127.0.0.1",
  "protocol": "vless",
  "settings": {
    "clients": [
      {
        "id": "$UUID",
        "level": 0,
        "email": "$NODE_NAME@local"
      }
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "ws",
    "wsSettings": {
      "path": "$WS_PATH"
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls"]
  }
}
EOF
)
else
    NEW_INBOUND=$(cat <<EOF
{
  "tag": "$NODE_NAME",
  "port": $PORT,
  "listen": "127.0.0.1",
  "protocol": "vless",
  "settings": {
    "clients": [
      {
        "id": "$UUID",
        "level": 0,
        "email": "$NODE_NAME@local"
      }
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp"
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls"]
  }
}
EOF
)
fi

# 更新 Xray 配置
echo -e "${YELLOW}更新 Xray 配置...${NC}"

if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
    # 创建新配置文件
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    $NEW_INBOUND
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {},
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
else
    # 添加到现有配置
    jq ".inbounds += [$NEW_INBOUND]" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
fi

# 验证 JSON 配置
if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
    echo -e "${RED}错误: 生成的配置文件 JSON 格式错误${NC}"
    exit 1
fi

# 重启 Xray
echo -e "${YELLOW}重启 Xray...${NC}"
systemctl restart xray
systemctl enable xray

sleep 2

# 检查 Xray 是否运行
if ! systemctl is-active --quiet xray; then
    echo -e "${RED}错误: Xray 启动失败${NC}"
    journalctl -u xray -n 20 --no-pager
    exit 1
fi

# 添加 Nginx 反代配置（仅 WebSocket）
if [ "$PROTOCOL_CHOICE" == "1" ]; then
    echo -e "${YELLOW}配置 Nginx 反代...${NC}"
    
    NGINX_CONF="$NGINX_VLESS_DIR/$NODE_NAME.conf"
    
    cat > "$NGINX_CONF" <<EOF
# VLESS 节点: $NODE_NAME
# 端口: $PORT | 路径: $WS_PATH
location $WS_PATH {
    if (\$http_upgrade != "websocket") {
        return 404;
    }
    proxy_redirect off;
    proxy_pass http://127.0.0.1:$PORT;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_read_timeout 300s;
}
EOF

    # 测试 Nginx 配置
    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        echo -e "${GREEN}Nginx 配置已更新${NC}"
    else
        echo -e "${RED}Nginx 配置错误${NC}"
        nginx -t
        rm "$NGINX_CONF"
        exit 1
    fi
fi

# 获取域名（从 Nginx 配置中提取）
DOMAIN=$(grep -oP 'server_name\s+\K[^;]+' /etc/nginx/sites-enabled/* 2>/dev/null | head -1 | xargs)

# 输出连接信息
echo ""
echo -e "${GREEN}==================================${NC}"
echo -e "${GREEN}节点添加成功!${NC}"
echo -e "${GREEN}==================================${NC}"
echo ""
echo -e "${YELLOW}节点信息:${NC}"
echo -e "节点名称: ${GREEN}$NODE_NAME${NC}"
echo -e "UUID: ${GREEN}$UUID${NC}"
echo -e "本地端口: ${GREEN}$PORT${NC}"

if [ "$PROTOCOL_CHOICE" == "1" ]; then
    echo -e "传输协议: ${GREEN}WebSocket${NC}"
    echo -e "WS 路径: ${GREEN}$WS_PATH${NC}"
    echo ""
    echo -e "${YELLOW}客户端配置:${NC}"
    echo -e "地址: ${GREEN}$DOMAIN${NC}"
    echo -e "端口: ${GREEN}443${NC}"
    echo -e "UUID: ${GREEN}$UUID${NC}"
    echo -e "传输协议: ${GREEN}ws${NC}"
    echo -e "路径: ${GREEN}$WS_PATH${NC}"
    echo -e "TLS: ${GREEN}启用${NC}"
    echo -e "SNI: ${GREEN}$DOMAIN${NC}"
    echo ""
    echo -e "${YELLOW}分享链接:${NC}"
    ENCODED_PATH=$(printf %s "$WS_PATH" | jq -sRr @uri)
    echo -e "${GREEN}vless://$UUID@$DOMAIN:443?encryption=none&security=tls&sni=$DOMAIN&type=ws&host=$DOMAIN&path=$ENCODED_PATH#$NODE_NAME${NC}"
else
    echo -e "传输协议: ${GREEN}TCP${NC}"
    echo ""
    echo -e "${YELLOW}注意: TCP 模式需要额外配置 Nginx stream 模块${NC}"
    echo -e "${YELLOW}建议使用 WebSocket 模式以获得更好的兼容性${NC}"
fi

echo ""
echo -e "${YELLOW}管理命令:${NC}"
echo -e "查看状态: ${GREEN}systemctl status xray${NC}"
echo -e "查看日志: ${GREEN}journalctl -u xray -f${NC}"
echo -e "查看配置: ${GREEN}cat $CONFIG_FILE | jq${NC}"
echo -e "测试连接: ${GREEN}curl -I https://$DOMAIN${NC}"
echo ""
echo -e "${BLUE}提示: 可以重复运行此脚本添加更多节点${NC}"

# 保存配置信息到文件
INFO_FILE="/root/vless-$NODE_NAME.txt"
cat > "$INFO_FILE" <<EOF
VLESS 节点信息 - $NODE_NAME
生成时间: $(date)
=================================

服务器信息:
- 域名: $DOMAIN
- 端口: 443
- UUID: $UUID
- 传输: WebSocket
- 路径: $WS_PATH
- TLS: 启用

分享链接:
vless://$UUID@$DOMAIN:443?encryption=none&security=tls&sni=$DOMAIN&type=ws&host=$DOMAIN&path=$(printf %s "$WS_PATH" | jq -sRr @uri)#$NODE_NAME

本地端口: $PORT
配置文件: $CONFIG_FILE
Nginx 配置: $NGINX_VLESS_DIR/$NODE_NAME.conf
EOF

echo -e "${GREEN}配置信息已保存到: $INFO_FILE${NC}"
