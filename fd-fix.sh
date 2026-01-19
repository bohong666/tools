#!/bin/bash

# Nginx 上传文件大小限制修改脚本

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}==================================${NC}"
echo -e "${GREEN}Nginx 上传限制修改工具${NC}"
echo -e "${GREEN}==================================${NC}"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 此脚本必须以 root 权限运行${NC}" 
   exit 1
fi

# 获取域名
DOMAIN=$(grep -oP 'server_name\s+\K[^;]+' /etc/nginx/sites-enabled/* 2>/dev/null | head -1 | xargs)

echo -e "${YELLOW}当前域名: ${GREEN}$DOMAIN${NC}"
echo ""
echo -e "${YELLOW}当前 Nginx 配置中的上传限制:${NC}"

# 检查现有配置
if grep -q "client_max_body_size" /etc/nginx/sites-available/$DOMAIN; then
    CURRENT_SIZE=$(grep "client_max_body_size" /etc/nginx/sites-available/$DOMAIN | head -1 | awk '{print $2}' | tr -d ';')
    echo -e "已配置: ${GREEN}$CURRENT_SIZE${NC}"
else
    echo -e "未配置 (默认: ${YELLOW}1M${NC})"
fi

if grep -q "client_max_body_size" /etc/nginx/nginx.conf; then
    GLOBAL_SIZE=$(grep "client_max_body_size" /etc/nginx/nginx.conf | grep -v "#" | head -1 | awk '{print $2}' | tr -d ';')
    echo -e "全局配置: ${GREEN}$GLOBAL_SIZE${NC}"
fi

echo ""
echo -e "${YELLOW}推荐配置:${NC}"
echo "1) 50M  (适合上传主题、插件)"
echo "2) 100M (推荐)"
echo "3) 500M (大文件上传)"
echo "4) 1G   (视频文件)"
echo "5) 自定义"
echo ""
read -p "请选择 [2]: " CHOICE
CHOICE=${CHOICE:-2}

case $CHOICE in
    1)
        SIZE="50M"
        ;;
    2)
        SIZE="100M"
        ;;
    3)
        SIZE="500M"
        ;;
    4)
        SIZE="1G"
        ;;
    5)
        read -p "请输入大小 (例如: 200M, 2G): " SIZE
        ;;
    *)
        SIZE="100M"
        ;;
esac

echo ""
echo -e "${YELLOW}将设置上传限制为: ${GREEN}$SIZE${NC}"
read -p "确认修改? (y/n): " CONFIRM

if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo -e "${YELLOW}已取消${NC}"
    exit 0
fi

# 备份配置
echo -e "${YELLOW}备份配置文件...${NC}"
cp /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-available/${DOMAIN}.backup.upload_$(date +%Y%m%d_%H%M%S)

# 修改站点配置
echo -e "${YELLOW}修改站点配置...${NC}"

# 检查是否已存在 client_max_body_size
if grep -q "client_max_body_size" /etc/nginx/sites-available/$DOMAIN; then
    # 替换现有配置
    sed -i "s/client_max_body_size .*/client_max_body_size $SIZE;/" /etc/nginx/sites-available/$DOMAIN
else
    # 在 server 块中添加配置（在 ssl_certificate 之后）
    sed -i "/ssl_certificate_key/a \    client_max_body_size $SIZE;" /etc/nginx/sites-available/$DOMAIN
fi

# 同时修改全局配置（可选但推荐）
echo -e "${YELLOW}修改全局配置...${NC}"
if grep -q "client_max_body_size" /etc/nginx/nginx.conf; then
    sed -i "s/.*client_max_body_size.*/    client_max_body_size $SIZE;/" /etc/nginx/nginx.conf
else
    # 在 http 块中添加
    sed -i "/http {/a \    client_max_body_size $SIZE;" /etc/nginx/nginx.conf
fi

# 同时调整相关超时配置
echo -e "${YELLOW}调整超时配置...${NC}"
if ! grep -q "client_body_timeout" /etc/nginx/sites-available/$DOMAIN; then
    sed -i "/client_max_body_size/a \    client_body_timeout 300s;\n    client_header_timeout 300s;\n    proxy_connect_timeout 300s;\n    proxy_send_timeout 300s;\n    proxy_read_timeout 300s;" /etc/nginx/sites-available/$DOMAIN
fi

# 测试配置
echo -e "${YELLOW}测试 Nginx 配置...${NC}"
if nginx -t 2>&1 | grep -q "successful"; then
    echo -e "${GREEN}配置测试通过${NC}"
    
    # 重载 Nginx
    echo -e "${YELLOW}重载 Nginx...${NC}"
    systemctl reload nginx
    
    echo ""
    echo -e "${GREEN}==================================${NC}"
    echo -e "${GREEN}配置修改成功!${NC}"
    echo -e "${GREEN}==================================${NC}"
    echo ""
    echo -e "${YELLOW}新的配置:${NC}"
    echo -e "上传限制: ${GREEN}$SIZE${NC}"
    echo -e "超时时间: ${GREEN}300秒${NC}"
    echo ""
    echo -e "${YELLOW}验证:${NC}"
    echo "curl -I https://$DOMAIN 2>&1 | grep -i 'server'"
    echo ""
    echo -e "${GREEN}现在可以上传主题了!${NC}"
else
    echo -e "${RED}Nginx 配置测试失败${NC}"
    nginx -t
    
    # 恢复备份
    echo -e "${YELLOW}恢复备份配置...${NC}"
    LATEST_BACKUP=$(ls -t /etc/nginx/sites-available/${DOMAIN}.backup.upload_* 2>/dev/null | head -1)
    if [ -n "$LATEST_BACKUP" ]; then
        cp "$LATEST_BACKUP" /etc/nginx/sites-available/$DOMAIN
        echo -e "${GREEN}已恢复备份${NC}"
    fi
    exit 1
fi

# 显示最终配置
echo -e "${YELLOW}当前配置内容:${NC}"
echo -e "${GREEN}----------------------------------${NC}"
grep -A 3 "client_max_body_size" /etc/nginx/sites-available/$DOMAIN
echo -e "${GREEN}----------------------------------${NC}"

# 保存信息
INFO_FILE="/root/nginx-upload-limit.txt"
cat > $INFO_FILE <<EOF
Nginx 上传限制修改记录
修改时间: $(date)
=================================

域名: $DOMAIN
上传限制: $SIZE
超时时间: 300秒

配置文件: /etc/nginx/sites-available/$DOMAIN
备份文件: $(ls -t /etc/nginx/sites-available/${DOMAIN}.backup.upload_* 2>/dev/null | head -1)

测试命令:
curl -X POST -F "file=@test.zip" https://$DOMAIN/upload

如需恢复:
cp $(ls -t /etc/nginx/sites-available/${DOMAIN}.backup.upload_* 2>/dev/null | head -1) /etc/nginx/sites-available/$DOMAIN
systemctl reload nginx
EOF

echo -e "${GREEN}配置信息已保存到: ${INFO_FILE}${NC}"
