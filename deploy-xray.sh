#!/bin/bash

# ============================================
# Ubuntu Xray VLESS+Reality+Vision 配置脚本
# 版本: v2.0.3
# 更新日期: 2024-12-11
# 作者:hogue
# ============================================

SCRIPT_VERSION="v2.0.3"

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# 显示版本信息
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  Xray VLESS+Reality+Vision 配置脚本${NC}"
echo -e "${BLUE}  版本: ${SCRIPT_VERSION}${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

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
apt install -y curl wget unzip jq qrencode

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

# 生成X25519密钥对 - 新版Xray的输出格式
log_info "正在生成X25519密钥对..."
KEY_OUTPUT=$(/usr/local/bin/xray x25519 2>&1)

# 解析新版Xray输出格式：
# PrivateKey: xxx (不是 "Private key:")
# Password: xxx (这个实际上是PublicKey)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "^PrivateKey:" | cut -d' ' -f2 | tr -d ' \n\r')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep "^PublicKey:" | cut -d' ' -f2 | tr -d ' \n\r')

# 如果没有PublicKey字段，检查Password字段（旧版本兼容）
if [ -z "$PUBLIC_KEY" ]; then
    PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep "^Password:" | cut -d' ' -f2 | tr -d ' \n\r')
fi

# 验证密钥是否生成成功
if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    log_error "密钥解析失败，原始输出："
    echo "$KEY_OUTPUT"
    log_error "尝试使用-i参数重新生成..."
    
    # 使用-i参数生成（指定私钥）
    KEY_OUTPUT2=$(/usr/local/bin/xray x25519 -i "$PRIVATE_KEY" 2>&1) || true
    if [ -n "$KEY_OUTPUT2" ]; then
        PUBLIC_KEY=$(echo "$KEY_OUTPUT2" | grep "^PublicKey:" | cut -d' ' -f2 | tr -d ' \n\r')
        if [ -z "$PUBLIC_KEY" ]; then
            PUBLIC_KEY=$(echo "$KEY_OUTPUT2" | grep "^Password:" | cut -d' ' -f2 | tr -d ' \n\r')
        fi
    fi
fi

# 最终验证
if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    log_error "无法生成密钥对！"
    log_error "原始输出："
    echo "$KEY_OUTPUT"
    exit 1
fi

log_info "✓ Private Key: $PRIVATE_KEY"
log_info "✓ Public Key: $PUBLIC_KEY"

# 生成short_id（8位十六进制）
SHORT_ID=$(openssl rand -hex 8)

# 获取服务器IP地址
IPV4=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com || curl -s -4 api.ipify.org)
IPV6=$(curl -s -6 ifconfig.me 2>/dev/null || curl -s -6 icanhazip.com 2>/dev/null || echo "")

log_info "服务器IPv4地址: $IPV4"
if [ -n "$IPV6" ]; then
    log_info "服务器IPv6地址: $IPV6"
fi

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
          "tls",
          "quic"
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
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

# 验证配置文件
log_info "验证Xray配置文件..."
if /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json; then
    log_info "配置文件验证成功"
else
    log_error "配置文件验证失败"
    cat /usr/local/etc/xray/config.json
    exit 1
fi

# ============================================
# 9. 配置防火墙
# ============================================
log_info "配置防火墙规则..."
if command -v ufw &> /dev/null; then
    ufw allow 443/tcp
    ufw --force enable
    log_info "UFW防火墙已配置"
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=443/tcp
    firewall-cmd --reload
    log_info "Firewalld已配置"
else
    log_warn "未检测到防火墙，跳过防火墙配置"
fi

# ============================================
# 10. 启动Xray服务
# ============================================
log_info "启动Xray服务..."
systemctl daemon-reload
systemctl enable xray
systemctl restart xray
sleep 3

# 检查服务状态
if systemctl is-active --quiet xray; then
    log_info "Xray服务启动成功 ✓"
else
    log_error "Xray服务启动失败，查看详细日志："
    journalctl -u xray -n 50 --no-pager
    exit 1
fi

# ============================================
# 11. 生成VLESS连接字符串
# ============================================
log_info "生成VLESS节点连接..."

# URL编码函数
urlencode() {
    local string="$1"
    echo -n "$string" | jq -sRr @uri
}

# 编码节点名称
ENCODED_NAME=$(urlencode "$NODE_NAME")
ENCODED_NAME_IPV6=$(urlencode "${NODE_NAME}-IPv6")

# 生成IPv4 VLESS链接
VLESS_IPV4="vless://${UUID}@${IPV4}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.drymt.com&fp=firefox&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${ENCODED_NAME}"

# 如果有IPv6，生成IPv6 VLESS链接
if [ -n "$IPV6" ]; then
    VLESS_IPV6="vless://${UUID}@[${IPV6}]:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.drymt.com&fp=firefox&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${ENCODED_NAME_IPV6}"
fi

# ============================================
# 12. Clash Meta 配置格式
# ============================================
cat > /root/clash_config.yaml <<EOF
proxies:
  - name: "$NODE_NAME"
    type: vless
    server: $IPV4
    port: 443
    uuid: $UUID
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: www.drymt.com
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID
    client-fingerprint: firefox
EOF

if [ -n "$IPV6" ]; then
    cat >> /root/clash_config.yaml <<EOF
  - name: "${NODE_NAME}-IPv6"
    type: vless
    server: $IPV6
    port: 443
    uuid: $UUID
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: www.drymt.com
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID
    client-fingerprint: firefox
EOF
fi

# ============================================
# 输出结果
# ============================================
echo ""
echo "============================================"
log_info "配置完成！脚本版本: ${SCRIPT_VERSION}"
echo "============================================"
echo ""
echo -e "${GREEN}节点信息：${NC}"
echo "----------------------------------------"
echo "节点名称: $NODE_NAME"
echo "UUID: $UUID"
echo "Private Key: $PRIVATE_KEY"
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
echo "目标地址: www.drymt.com:443"
echo "客户端指纹: firefox"
echo "----------------------------------------"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}VLESS节点连接（IPv4）：${NC}"
echo -e "${YELLOW}$VLESS_IPV4${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ -n "$IPV6" ]; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}VLESS节点连接（IPv6）：${NC}"
    echo -e "${YELLOW}$VLESS_IPV6${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
fi

# 生成二维码（如果有qrencode）
if command -v qrencode &> /dev/null; then
    echo -e "${GREEN}IPv4节点二维码：${NC}"
    qrencode -t ANSIUTF8 "$VLESS_IPV4"
    echo ""
fi

# 保存到文件
cat > /root/xray_vless_links.txt <<EOF
========================================
Xray VLESS+Reality+Vision 节点信息
脚本版本: $SCRIPT_VERSION
配置时间: $(date '+%Y-%m-%d %H:%M:%S %Z')
========================================

节点名称: $NODE_NAME

========== 密钥信息 ==========
UUID: $UUID
Private Key: $PRIVATE_KEY
Public Key: $PUBLIC_KEY
Short ID: $SHORT_ID

========== 服务器信息 ==========
服务器IPv4: $IPV4
$([ -n "$IPV6" ] && echo "服务器IPv6: $IPV6")
端口: 443
传输协议: TCP
流控: xtls-rprx-vision

========== Reality 配置 ==========
TLS: Reality
SNI: www.drymt.com
目标地址: www.drymt.com:443
客户端指纹: firefox

========== VLESS URI (IPv4) ==========
$VLESS_IPV4

$([ -n "$IPV6" ] && echo "========== VLESS URI (IPv6) ==========" && echo "$VLESS_IPV6")

========== Clash Meta 配置 ==========
配置文件已保存到: /root/clash_config.yaml
可直接复制 clash_config.yaml 的内容到 Clash Meta/Party 使用

========== 客户端配置参数（手动配置用）==========
地址(Address): $IPV4
端口(Port): 443
用户ID(UUID): $UUID
流控(Flow): xtls-rprx-vision
传输协议(Network): tcp
传输层安全(TLS): reality
SNI: www.drymt.com
Fingerprint: firefox
PublicKey: $PUBLIC_KEY
ShortId: $SHORT_ID
SpiderX: 
Dest: www.drymt.com:443

========== 管理命令 ==========
查看Xray状态: systemctl status xray
启动Xray: systemctl start xray
停止Xray: systemctl stop xray
重启Xray: systemctl restart xray
查看实时日志: journalctl -u xray -f
查看最近日志: journalctl -u xray -n 50
测试配置: /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
配置文件位置: /usr/local/etc/xray/config.json

========== BBR 检查命令 ==========
检查BBR状态: sysctl net.ipv4.tcp_congestion_control
查看可用算法: sysctl net.ipv4.tcp_available_congestion_control
查看连接统计: ss -tin

========== 性能测试建议 ==========
1. 使用客户端连接后访问: https://www.google.com
2. 测试速度: https://fast.com 或 https://speedtest.net
3. 检查IP: https://ip.sb 或 https://ipinfo.io

========== 故障排查 ==========
1. 检查服务状态: systemctl status xray
2. 查看详细日志: journalctl -u xray -n 100
3. 验证配置文件: /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
4. 检查端口占用: netstat -tlnp | grep 443
5. 测试目标站点: curl -I https://www.drymt.com
6. 检查防火墙: ufw status 或 iptables -L

========== 安全建议 ==========
1. 定期更新系统: apt update && apt upgrade
2. 定期更新Xray: bash -c "\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
3. 监控服务状态: systemctl status xray
4. 备份配置文件: cp /usr/local/etc/xray/config.json /root/config.json.bak

========================================
EOF

log_info "详细配置信息已保存到 /root/xray_vless_links.txt"
log_info "Clash配置已保存到 /root/clash_config.yaml"
echo ""
log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_warn "请复制上方的VLESS URI导入到客户端进行测试"
log_warn "支持的客户端: v2rayN, v2rayNG, Clash Meta, Clash Party等"
log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "============================================"
log_info "系统优化完成摘要 (版本: ${SCRIPT_VERSION})："
echo "============================================"
echo "✓ 系统已更新到最新"
echo "✓ 系统垃圾已清理"
echo "✓ 已配置2GB交换空间 ($(free -h | grep Swap | awk '{print $2}'))"
echo "✓ BBR加速已启用"
echo "✓ Xray $(xray version | head -n 1 | awk '{print $2}') 已安装并运行"
echo "✓ VLESS+Reality+Vision节点已配置"
echo "✓ 防火墙规则已配置"
echo "============================================"

# BBR和服务验证
echo ""
log_info "系统状态验证："
BBR_STATUS=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
if [ "$BBR_STATUS" = "bbr" ]; then
    echo "✓ BBR状态: 已启用 ($BBR_STATUS)"
else
    log_warn "⚠ BBR状态: $BBR_STATUS (建议重启系统后生效)"
fi

XRAY_STATUS=$(systemctl is-active xray)
if [ "$XRAY_STATUS" = "active" ]; then
    echo "✓ Xray服务: 运行中"
else
    echo "✗ Xray服务: $XRAY_STATUS"
fi

LISTENING=$(ss -tlnp | grep :443 | grep xray)
if [ -n "$LISTENING" ]; then
    echo "✓ 端口443: 正在监听"
else
    log_warn "⚠ 端口443: 未检测到监听"
fi

echo ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "配置完成！建议步骤："
echo "1. 继续优化防火墙 bash <(curl -fsSL https://raw.githubusercontent.com/bohong666/tools/refs/heads/main/firewall-manager.sh)"
echo "2. 通过 https://omnitt.com 进行 tcp 调优"
echo "3. 连接后访问 https://www.google.com 测试"
echo "4. 查看日志: journalctl -u xray -f"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
