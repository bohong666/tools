#!/bin/bash
set -e

# ------------------------
# 用户配置
# ------------------------
NODE_NAME=${1:-"VLESS-$(date +%s)"}  # 第一个参数可自定义节点名称，否则自动生成

# ------------------------
# 系统更新 & 安装依赖
# ------------------------
echo "更新系统..."
apt update -y && apt upgrade -y
apt install -y curl wget unzip lsof sudo qrencode openssl

# ------------------------
# 启用 BBR
# ------------------------
echo "启用 BBR..."
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p

# ------------------------
# 安装 Xray-core
# ------------------------
echo "安装 Xray..."
bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install

# ------------------------
# 生成 UUID / Reality Key / shortId
# ------------------------
UUID=$(xray uuid)
PRIV_KEY=$(xray x25519)
SHORTID=$(openssl rand -hex 8)

# ------------------------
# 设置 Xray 配置
# ------------------------
cat > /etc/xray/config.json <<EOF
{
    "log": {"loglevel": "warning"},
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {"type":"field","protocol":["bittorrent"],"outboundTag":"block"},
            {"type":"field","ip":["geoip:private"],"outboundTag":"block"},
            {"type":"field","ip":["geoip:cn"],"outboundTag":"block"},
            {"type":"field","domain":["geosite:category-ads-all"],"outboundTag":"block"}
        ]
    },
    "inbounds": [
        {
            "tag": "xray-xtls-reality",
            "listen": "0.0.0.0",
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [{"id":"$UUID","flow":"xtls-rprx-vision"}],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "www.drymt.com:443",
                    "serverNames": ["www.drymt.com"],
                    "privateKey": "$PRIV_KEY",
                    "shortIds": ["$SHORTID"]
                }
            },
            "sniffing": {"enabled":true,"destOverride":["http","tls","quic"]}
        }
    ],
    "outbounds": [
        {"protocol": "freedom","tag": "direct"},
        {"protocol": "blackhole","tag": "block"}
    ]
}
EOF

# ------------------------
# 设置 systemd 并启动 Xray
# ------------------------
systemctl enable xray
systemctl restart xray

# ------------------------
# 获取 IP
# ------------------------
IP4=$(curl -4 -s https://api.ipify.org)
IP6=$(curl -6 -s https://api64.ipify.org || echo "")

# ------------------------
# 生成 VLESS 节点链接
# ------------------------
VLESS_LINK_IPV4="vless://$UUID@${IP4}:443?flow=xtls-rprx-vision&security=reality&encryption=none&type=tcp&reality=dest%3Dwww.drymt.com%3BserverNames%3Dwww.drymt.com%3BshortId%3D$SHORTID#$NODE_NAME"

if [[ -n "$IP6" ]]; then
  VLESS_LINK_IPV6="vless://$UUID@[$IP6]:443?flow=xtls-rprx-vision&security=reality&encryption=none&type=tcp&reality=dest%3Dwww.drymt.com%3BserverNames%3Dwww.drymt.com%3BshortId%3D$SHORTID#$NODE_NAME-IPv6"
fi

# ------------------------
# 输出结果
# ------------------------
echo "------------------------"
echo "Xray VLESS 节点已部署完成！"
echo "节点名称: $NODE_NAME"
echo "UUID: $UUID"
echo "PrivateKey: $PRIV_KEY"
echo "ShortId: $SHORTID"
echo "IPv4 VLESS 节点链接: $VLESS_LINK_IPV4"
if [[ -n "$IP6" ]]; then
  echo "IPv6 VLESS 节点链接: $VLESS_LINK_IPV6"
fi
echo "------------------------"
