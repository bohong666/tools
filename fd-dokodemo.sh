#!/bin/bash

# Xray Dokodemo-door 中转服务添加脚本
# 用途：在现有 Xray 配置中添加端口转发功能

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置参数
XRAY_CONFIG="/usr/local/etc/xray/config.json"
RELAY_PORT=10942
TARGET_IP="43.248.10.59"  # 目标 VLESS 服务器 IP
TARGET_PORT=443  # 目标服务器端口

echo -e "${GREEN}=== Xray Dokodemo-door 中转服务配置脚本 ===${NC}"

# 检查是否为 root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 此脚本需要 root 权限运行${NC}"
   exit 1
fi

# 检查目标 IP 是否已设置
if [ -z "$TARGET_IP" ]; then
    echo -e "${RED}错误: 请先编辑脚本，设置 TARGET_IP 变量${NC}"
    echo -e "${YELLOW}提示: 编辑此脚本，找到 TARGET_IP=\"\" 并填入目标服务器 IP${NC}"
    exit 1
fi

# 检查 Xray 配置文件是否存在
if [ ! -f "$XRAY_CONFIG" ]; then
    echo -e "${RED}错误: Xray 配置文件不存在: $XRAY_CONFIG${NC}"
    exit 1
fi

# 备份原配置
BACKUP_FILE="${XRAY_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
echo -e "${YELLOW}备份原配置到: $BACKUP_FILE${NC}"
cp "$XRAY_CONFIG" "$BACKUP_FILE"

# 检查 jq 是否安装
if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}安装 jq 工具...${NC}"
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y jq
    elif command -v yum &> /dev/null; then
        yum install -y jq
    else
        echo -e "${RED}错误: 无法自动安装 jq，请手动安装${NC}"
        exit 1
    fi
fi

# 检查端口是否已被占用
if netstat -tuln | grep -q ":$RELAY_PORT "; then
    echo -e "${RED}错误: 端口 $RELAY_PORT 已被占用${NC}"
    netstat -tuln | grep ":$RELAY_PORT "
    exit 1
fi

# 添加 dokodemo-door 配置
echo -e "${GREEN}添加 dokodemo-door 中转配置...${NC}"
jq --arg port "$RELAY_PORT" \
   --arg target_ip "$TARGET_IP" \
   --arg target_port "$TARGET_PORT" \
   '.inbounds += [{
     "port": ($port | tonumber),
     "protocol": "dokodemo-door",
     "tag": "relay-to-target",
     "settings": {
       "address": $target_ip,
       "port": ($target_port | tonumber),
       "network": "tcp,udp"
     },
     "sniffing": {
       "enabled": false
     }
   }]' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp"

# 验证 JSON 格式
if jq empty "${XRAY_CONFIG}.tmp" 2>/dev/null; then
    mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
    echo -e "${GREEN}配置文件更新成功${NC}"
else
    echo -e "${RED}错误: 生成的配置文件 JSON 格式无效${NC}"
    rm -f "${XRAY_CONFIG}.tmp"
    exit 1
fi

# 配置防火墙
echo -e "${YELLOW}配置防火墙规则...${NC}"
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    ufw allow $RELAY_PORT/tcp
    ufw allow $RELAY_PORT/udp
    echo -e "${GREEN}UFW 防火墙规则已添加${NC}"
elif command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=$RELAY_PORT/tcp
    firewall-cmd --permanent --add-port=$RELAY_PORT/udp
    firewall-cmd --reload
    echo -e "${GREEN}Firewalld 防火墙规则已添加${NC}"
else
    echo -e "${YELLOW}未检测到活动的防火墙，跳过防火墙配置${NC}"
fi

# 重启 Xray 服务
echo -e "${YELLOW}重启 Xray 服务...${NC}"
systemctl restart xray

# 等待服务启动
sleep 2

# 检查服务状态
if systemctl is-active --quiet xray; then
    echo -e "${GREEN}✓ Xray 服务运行正常${NC}"
else
    echo -e "${RED}✗ Xray 服务启动失败，正在恢复备份...${NC}"
    cp "$BACKUP_FILE" "$XRAY_CONFIG"
    systemctl restart xray
    exit 1
fi

# 检查端口监听
if netstat -tuln | grep -q ":$RELAY_PORT "; then
    echo -e "${GREEN}✓ 端口 $RELAY_PORT 监听正常${NC}"
else
    echo -e "${RED}✗ 端口 $RELAY_PORT 未监听${NC}"
    exit 1
fi

# 显示配置信息
echo -e "\n${GREEN}=== 配置完成 ===${NC}"
echo -e "${YELLOW}中转服务信息:${NC}"
echo -e "  监听端口: ${GREEN}$RELAY_PORT${NC}"
echo -e "  目标地址: ${GREEN}$TARGET_IP:$TARGET_PORT${NC}"
echo -e "  协议支持: ${GREEN}TCP/UDP${NC}"
echo -e "\n${YELLOW}使用方法:${NC}"
echo -e "  在客户端配置中，将服务器地址设置为:"
echo -e "  ${GREEN}$(curl -s ifconfig.me):$RELAY_PORT${NC}"
echo -e "\n${YELLOW}备份文件:${NC}"
echo -e "  ${GREEN}$BACKUP_FILE${NC}"
echo -e "\n${YELLOW}查看日志:${NC}"
echo -e "  ${GREEN}journalctl -u xray -f${NC}"
echo -e "\n${GREEN}部署成功！${NC}"
