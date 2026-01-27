#!/usr/bin/env bash
set -euo pipefail

# ===========================
# 可选参数（环境变量覆盖）
# ===========================
PORT="${PORT:-8388}"
METHOD="${METHOD:-aes-256-gcm}"
PASSWORD="${PASSWORD:-}"
TAG="${TAG:-xray-ss}"
DOCKER="${DOCKER:-0}"          # 1 = 使用 Docker 运行 Xray

XRAY_DIR="/usr/local/xray"
XRAY_CONFIG="${XRAY_DIR}/config.json"
LOG_FILE="/var/log/xray.log"

mkdir -p "$XRAY_DIR"

# ===========================
# 自动生成随机密码（如未指定）
# ===========================
if [[ -z "$PASSWORD" ]]; then
    PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
fi

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
# 写入 Xray 配置（通用）
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
# Docker 模式
# ===========================
if [[ "$DOCKER" == "1" ]]; then
    echo "使用 Docker 模式运行 Xray-SS"

    if ! command -v docker >/dev/null 2>&1; then
        echo "未检测到 docker，请先安装 Docker 后重试。"
        exit 1
    fi

    # 拉镜像（这里用 teddysun/xray，稳定常用）
    docker pull teddysun/xray >/dev/null

    # 停旧容器
    docker rm -f xray-ss >/dev/null 2>&1 || true

    # 启动容器
    docker run -d \
        --name xray-ss \
        --restart=always \
        -p ${PORT}:${PORT}/tcp \
        -p ${PORT}:${PORT}/udp \
        -v "${XRAY_CONFIG}:/etc/xray/config.json:ro" \
        teddysun/xray

else
    # ===========================
    # 裸机模式：下载 Xray + systemd / nohup
    # ===========================
    XRAY_BIN="${XRAY_DIR}/xray"

    echo "下载 Xray 二进制..."
    LATEST_URL=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest \
        | grep browser_download_url | grep linux-64.zip | cut -d '"' -f 4)

    curl -L "$LATEST_URL" -o /tmp/xray.zip
    unzip -o /tmp/xray.zip -d "$XRAY_DIR" >/dev/null
    chmod +x "$XRAY_BIN"

    HAS_SYSTEMD=false
    if pidof systemd >/dev/null 2>&1; then
        HAS_SYSTEMD=true
    fi

    if $HAS_SYSTEMD; then
        echo "检测到 systemd，使用 systemd 管理 Xray"

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
echo "模式:     $([[ "$DOCKER" == "1" ]] && echo Docker || echo 裸机)"
echo "IP:       $IP"
echo "端口:     $PORT"
echo "加密:     $METHOD"
echo "密码:     $PASSWORD"
echo
echo "SS 链接："
echo "$SS_URL"
echo "==================================================="
