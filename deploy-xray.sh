#!/bin/bash

# ============================================
# Ubuntu Xray VLESS+Reality+Vision 配置脚本
# ============================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为root用户
if [[ $EUID -ne 0 ]]; then
   log_error "此脚本必须以root权限运行"
   exit 1
fi

# 读取自定义节点名称
read -p "请输入节点名称（直接回车使用默认名称）: " NODE_NAME
if [ -z "$NODE_NAME" ]; then
    NODE_NAME="Xray-Reality-$(date +%Y%m%d)"
fi

log_info "开始配置系统..."

# ============================================
# 1. 更新系统
# ============================================
log_info "更新系统软件包..."
apt update && apt upgrade -y
apt autoremove -y
apt autoclean -y

# ============================================
# 2. 清除系统垃圾
# ============================================
log_info "清除系统垃圾..."
apt clean
journalctl --vacuum-time=3d
rm -rf /tmp/*
rm -rf /var/tmp/*

# ============================================
# 3. 设置2G交换空间（缓存）
# ============================================
log_info "配置2GB交换空间..."
if [ -f /swapfile ]; then
    swapoff /swapfile
    rm -f /swapfile
fi

fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile

# 永久挂载
if ! grep -q '/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ============================================
# 4. 启用BBR加速
# ============================================
log_info "启用BBR TCP拥塞控制算法..."
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
fi
sysctl -p

# ============================================
# 5. 安装依赖
# ============================================
log_info "安装必要依赖..."
apt install -y curl wget unzip jq

# ============================================
# 6. 安装Xray
# ============================================
log_info "安装Xray-core..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# ============================================
# 7. 生成密钥和ID
# ============================================
log_info "生成密钥对和UUID..."

# 生成UUID
UUID=$(cat /proc/sys/kernel/random/uuid)

# 生成X25519密钥对
KEY_PAIR=$(/usr/local/bin/xray x25519)
PRIVATE_KEY=$(echo "$KEY_PAIR" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEY_PAIR" | grep "Public key:" | awk '{print $3}')

# 生成short_id（16位十六进制）
SHORT_ID=$(openssl rand -hex 8)

# 获取服务器IP地址
IPV4=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com)
IPV6=$(curl -s -6 ifconfig.me 2>/dev/null || echo "")

# ============================================
# 8. 创建Xray配置文件
# ============================================
log_info "创建Xray配置文件..."

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.drymt.com:443",
          "serverNames": [
            "www.drymt.com"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

# ============================================
# 9. 启动Xray服务
# ============================================
log_info "启动Xray服务..."
systemctl enable xray
systemctl restart xray
sleep 2

# 检查服务状态
if systemctl is-active --quiet xray; then
    log_info "Xray服务启动成功"
else
    log_error "Xray服务启动失败，请检查配置"
    systemctl status xray
    exit 1
fi

# ============================================
# 10. 生成VLESS连接字符串
# ============================================
log_info "生成VLESS节点连接..."

# 生成IPv4 VLESS链接
VLESS_IPV4="vless://${UUID}@${IPV4}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.drymt.com&fp=firefox&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${NODE_NAME}"

# 如果有IPv6，生成IPv6 VLESS链接
if [ -n "$IPV6" ]; then
    VLESS_IPV6="vless://${UUID}@[${IPV6}]:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.drymt.com&fp=firefox&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${NODE_NAME}-IPv6"
fi

# ============================================
# 输出结果
# ============================================
echo ""
echo "============================================"
log_info "配置完成！"
echo "============================================"
echo ""
echo -e "${GREEN}节点信息：${NC}"
echo "----------------------------------------"
echo "节点名称: $NODE_NAME"
echo "UUID: $UUID"
echo "Public Key: $PUBLIC_KEY"
echo "Short ID: $SHORT_ID"
echo "服务器IPv4: $IPV4"
if [ -n "$IPV6" ]; then
    echo "服务器IPv6: $IPV6"
fi
echo "端口: 443"
echo "传输协议: TCP"
echo "流控: xtls-rprx-vision"
echo "TLS: Reality"
echo "SNI: www.drymt.com"
echo "指纹: firefox"
echo "----------------------------------------"
echo ""
echo -e "${GREEN}VLESS节点连接（IPv4）：${NC}"
echo "$VLESS_IPV4"
echo ""

if [ -n "$IPV6" ]; then
    echo -e "${GREEN}VLESS节点连接（IPv6）：${NC}"
    echo "$VLESS_IPV6"
    echo ""
fi

# 保存到文件
cat > /root/xray_vless_links.txt <<EOF
节点名称: $NODE_NAME
配置时间: $(date)

========== 节点详细信息 ==========
UUID: $UUID
Public Key: $PUBLIC_KEY
Private Key: $PRIVATE_KEY
Short ID: $SHORT_ID
服务器IPv4: $IPV4
$([ -n "$IPV6" ] && echo "服务器IPv6: $IPV6")
端口: 443
传输协议: TCP
流控: xtls-rprx-vision
TLS: Reality
SNI: www.drymt.com
目标地址: www.drymt.com:443
指纹: firefox

========== VLESS连接（IPv4） ==========
$VLESS_IPV4

$([ -n "$IPV6" ] && echo "========== VLESS连接（IPv6） ==========" && echo "$VLESS_IPV6")

========== 管理命令 ==========
查看Xray状态: systemctl status xray
启动Xray: systemctl start xray
停止Xray: systemctl stop xray
重启Xray: systemctl restart xray
查看日志: journalctl -u xray -f
配置文件: /usr/local/etc/xray/config.json

========== BBR状态检查 ==========
检查BBR: sysctl net.ipv4.tcp_congestion_control
查看可用算法: sysctl net.ipv4.tcp_available_congestion_control
EOF

log_info "配置信息已保存到 /root/xray_vless_links.txt"
echo ""
log_warn "请复制上方的VLESS链接导入到Clash Party等客户端进行测试"
log_warn "建议使用浏览器测试连接: https://www.google.com"
echo ""
echo "============================================"
log_info "系统优化完成摘要："
echo "✓ 系统已更新到最新"
echo "✓ 系统垃圾已清理"
echo "✓ 已配置2GB交换空间"
echo "✓ BBR加速已启用"
echo "✓ Xray已安装并启动"
echo "✓ VLESS+Reality+Vision节点已配置"
echo "============================================"

# BBR验证
BBR_STATUS=$(sysctl net.ipv4.tcp_congestion_control | grep bbr)
if [ -n "$BBR_STATUS" ]; then
    log_info "BBR状态: $BBR_STATUS ✓"
else
    log_warn "BBR可能未正确启用，请检查"
fi
