#!/usr/bin/env bash
# deploy-xray-vless-xtls.sh
# 完整 Xray VLESS + XTLS 部署脚本，支持 Clash Party 导入节点
# Usage: bash deploy-xray-vless-xtls.sh [NodeName]

set -e

NODE_NAME=${1:-VLESS-$(date +%m%d%H%M)}
CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CLASH_FILE="/root/${NODE_NAME}-clash.yaml"

XRAY_VERSION="v25.12.8"

echo "=============================="
echo "节点名称: $NODE_NAME"
echo "Xray 版本: $XRAY_VERSION"
echo "=============================="

# 1. 系统更新和依赖
apt update -y
apt upgrade -y
apt install -y curl wget unzip lsof qrencode sudo

# 2. 启用 BBR
modprobe tcp_bbr || true
sysctl -w net.core.default_qdisc=fq
sysctl -w net.ipv4.tcp_congestion_control=bbr

# 3. 安装 Xray
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

# 6. 获取 IPv4 和 IPv6
IPV4=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
IPV6=$(ip -6 addr show eth0 | grep -oP '(?<=inet6\s)[\da-f:]+(?=/64)' | head -1)

# 7. 配置 VLESS + XTLS
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
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision",
            "encryption": "none",
            "client-fingerprint": "firefox",
            "short-id": "auto",
            "public-key": ""
          }
        ],
        "decryption": "none",
        "fallbacks": [
          {"dest": "www.drymt.com:443"}
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "xtls",
        "xtlsSettings": {
          "serverName": "www.drymt.com",
          "alpn": ["h2","http/1.1"]
        }
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "settings": {}}
  ]
}
EOF

# 8. systemd 服务
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

systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# 9. 生成 Clash Party YAML
cat > "$CLASH_FILE" <<EOF
proxies:
  - name: "$NODE_NAME"
    type: vless
    server: $IPV4
    port: 443
    uuid: $UUID
    tls: true
    skip-cert-verify: false
    network: tcp
    encryption: none
    flow: xtls-rprx-vision
    client-fingerprint: firefox
    servername: www.drymt.com
    dest: www.drymt.com:443
EOF

# 输出信息
echo "=============================="
echo "Xray VLESS+XTLS 部署完成！"
echo "UUID: $UUID"
echo "IPv4: $IPV4"
echo "IPv6: $IPV6"
echo "Clash Party YAML 文件: $CLASH_FILE"
echo "=============================="
