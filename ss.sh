#!/usr/bin/env bash
set -euo pipefail

# ===========================
# 可选参数（用户可自定义）
# ===========================
PORT="${PORT:-8388}"
METHOD="${METHOD:-aes-256-gcm}"
PASSWORD="${PASSWORD:-}"
TAG="xray-ss"

# ===========================
# 自动生成随机密码（如未指定）
# ===========================
if [[ -z "$PASSWORD" ]]; then
    PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
fi

# ===========================
# 基础路径
# ===========================
XRAY_DIR="/usr/local/xray"
XRAY_BIN="${XRAY_DIR}/xray"
XRAY_CONFIG="${XRAY_DIR}/config.json"
LOG_FILE="/var/log/xray.log"

mkdir -p "$XRAY_DIR"

# ===========================
# 安装依赖
# ===========================
install_pkg() {
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache "$@"
    elif command -v apt >/dev/null 2>&1; then
        apt update && apt install -y "$@"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$@"
    elif command -v opkg >/dev/null 2>&1; then
        opkg update && opkg install "$@"
    fi
}

command -v curl >/dev/null 2>&1 || install_pkg curl
command -v unzip >/dev/null 2>&1 || install_pkg unzip

# ===========================
# 下载 Xray
# ===========================
echo "下载 Xray..."
LATEST_URL=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest \
    | grep browser_download_url | grep linux-64.zip | cut -d '"' -f 4)

curl -L "$LATEST_URL" -o /tmp/xray.zip
unzip -o /tmp/xray.zip -d "$XRAY_DIR" >/dev/null
chmod +x "$XRAY_BIN"

# ===========================
# 写入配置
# ===========================
cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "$LOG_FILE",
    "error": "$LOG_FILE"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "shadowsocks",
      "settings": {
        "method": "$METHOD",
        "password": "$PASSWORD",
        "network": "tcp,udp"
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF

# ===========================
# 判断是否有 systemd
# ===========================
HAS_SYSTEMD=false
if pidof systemd >/dev/null 2>&1; then
    HAS_SYSTEMD=true
fi

# ===========================
# 启动方式：systemd / nohup
# ===========================
if $HAS_SYSTEMD; then
    echo "检测到 systemd，使用 systemd 管理服务"

    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=${XRAY_BIN} -config ${XRAY_CONFIG}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray

else
    echo "未检测到 systemd，使用 nohup 后台运行"
    pkill -f "$XRAY_BIN" 2>/dev/null || true
    nohup "$XRAY_BIN" -config "$XRAY_CONFIG" >/dev/null 2>&1 &
fi

# ===========================
# 获取公网 IP
# ===========================
get_ip() {
    ip=$(curl -4s https://ifconfig.co || true)
    if [[ -z "$ip" ]]; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {print $7}')
    fi
    echo "$ip"
}

IP=$(get_ip)

# ===========================
# 生成 SS 链接
# ===========================
BASE64_CRED=$(printf '%s' "${METHOD}:${PASSWORD}" | base64 | tr -d '\n')
SS_URL="ss://${BASE64_CRED}@${IP}:${PORT}#${TAG}"

echo
echo "================ Shadowsocks 已部署 ================"
echo "IP:       $IP"
echo "端口:     $PORT"
echo "加密:     $METHOD"
echo "密码:     $PASSWORD"
echo
echo "SS 链接："
echo "$SS_URL"
echo "==================================================="

