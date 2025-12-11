#!/usr/bin/env bash
# deploy-xray-vless.sh
# 完整 Xray VLESS 双栈部署脚本
# Usage: bash deploy-xray-vless.sh [NodeName]

set -e

NODE_NAME=${1:-VLESS-$(date +%m%d%H%M)}
CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"

echo "节点名称: $NODE_NAME"

# 1. 更新系统并安装依赖
echo "更新系统并安装依赖..."
apt update -y
apt upgrade -y
apt install -y curl wget unzip lsof qrencode sudo

# 2. 启用 BBR
echo "启用 BBR..."
modprobe tcp_bbr || true
sysctl -w net.core.default_qdisc=fq
sysctl -w net.ipv4.tcp_congestion_control=bbr

# 3. 安装 Xray
echo "安装 Xray..."
XRAY_VERSION="v25.12.8"
TMP_DIR=$(mktemp -d)
curl -L -o "$TMP_DIR/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip"
unzip -o "$TMP_DIR/xray.zip" -d "$TMP_DIR"
install -m 755 "$TMP_DIR/xray" /usr/local/bin/xray
mkdir -p /usr/local/share/xray
install -m 644 "$TMP_DIR/geoip.dat" /usr/local/share/xray/
install -m 644 "$TMP_DIR/geosite.dat" /usr/local/share/xray/
rm -rf "$TMP_DIR"

# 4. 创建配置目录
mkdir -p "$CONFIG_DIR"

# 5. 生成 UUID
UUID=$(cat /proc/sys/kernel/random/uuid)
echo "生成 UUID: $UUID"

# 6. 自动获取本机 IPv4 和 IPv6（只取 eth0 第一条）
IPV4=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
IPV6=$(ip -6 addr show eth0 | grep -oP '(?<=inet6\s)[\da-f:]+(?=/64)' | head -1)

# 7. 写配置文件
cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "info",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$UUID"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls"
      }
    },
    {
      "port": 443,
      "protocol": "vless",
      "listen": "::",
      "settings": {
        "clients": [{"id": "$UUID"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls"
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "settings": {}}
  ]
}
EOF

# 8. 创建 systemd 服务
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config $CONFIG_FILE
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

# 9. 启用并启动服务
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# 10. 输出节点信息
echo "=================================================="
echo "Xray VLESS 部署完成！"
echo "节点名称: $NODE_NAME"
echo "UUID: $UUID"
echo "IPv4 VLESS: vless://$UUID@$IPV4:443?encryption=none&security=tls#$NODE_NAME"
if [ -n "$IPV6" ]; then
    echo "IPv6 VLESS: vless://$UUID@[$IPV6]:443?encryption=none&security=tls#$NODE_NAME"
fi
echo "日志路径: /var/log/xray/"
echo "配置路径: $CONFIG_FILE"
echo "=================================================="
