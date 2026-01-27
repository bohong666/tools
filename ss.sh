#!/usr/bin/env bash
set -euo pipefail

# ===== 基本参数，可按需修改 =====
PORT=8388
METHOD="aes-256-gcm"
TAG="xray-ss"
XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
# ===============================

# 检查 root
if [[ "$EUID" -ne 0 ]]; then
  echo "请用 root 运行：sudo $0"
  exit 1
fi

# 检查系统
if [[ -f /etc/debian_version ]]; then
  OS_FAMILY="debian"
elif [[ -f /etc/redhat-release ]]; then
  OS_FAMILY="redhat"
else
  OS_FAMILY="unknown"
fi

# 安装依赖
if ! command -v curl >/dev/null 2>&1; then
  if [[ "$OS_FAMILY" == "debian" ]]; then
    apt-get update
    apt-get install -y curl
  elif [[ "$OS_FAMILY" == "redhat" ]]; then
    yum install -y curl
  else
    echo "未知系统，请手动安装 curl 后重试。"
    exit 1
  fi
fi

# 安装 / 更新 Xray（官方脚本）
bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install

# 生成随机密码
SS_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"

# 备份旧配置
if [[ -f "$XRAY_CONFIG_PATH" ]]; then
  cp "$XRAY_CONFIG_PATH" "${XRAY_CONFIG_PATH}.$(date +%Y%m%d%H%M%S).bak"
fi

# 写入新的 Xray 配置（Shadowsocks 入站）
cat > "$XRAY_CONFIG_PATH" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "shadowsocks",
      "settings": {
        "method": "${METHOD}",
        "password": "${SS_PASSWORD}",
        "network": "tcp,udp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      },
      "tag": "ss-in"
    }
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
      "tag": "blocked"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": []
  }
}
EOF

# 重启 Xray
systemctl daemon-reload || true
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray

sleep 1
if ! systemctl is-active --quiet xray; then
  echo "Xray 启动失败，请用：journalctl -u xray -e 查看日志。"
  exit 1
fi

# 获取服务器 IPv4
get_ip() {
  local ip
  # 优先从路由获取
  if ip route get 1.1.1.1 >/dev/null 2>&1; then
    ip=$(ip route get 1.1.1.1 | awk '/src/ {print $7; exit}')
  fi
  # 兜底用外网服务
  if [[ -z "${ip:-}" ]]; then
    ip=$(curl -4s https://ifconfig.co || true)
  fi
  echo "$ip"
}

SERVER_IP="$(get_ip)"

if [[ -z "$SERVER_IP" ]]; then
  echo "无法自动获取服务器 IP，请手动确认后自行拼接 SS 链接。"
  echo "加密方式: ${METHOD}"
  echo "密码: ${SS_PASSWORD}"
  echo "端口: ${PORT}"
  exit 0
fi

# 生成 SS 链接（SIP002 格式：ss://base64(method:password)@host:port#tag）
encode_base64() {
  if base64 --help 2>&1 | grep -q -- "-w "; then
    printf '%s' "$1" | base64 -w0
  else
    printf '%s' "$1" | base64 | tr -d '\n'
  fi
}

BASE64_CRED="$(encode_base64 "${METHOD}:${SS_PASSWORD}")"
SS_URL="ss://${BASE64_CRED}@${SERVER_IP}:${PORT}#${TAG}"

echo
echo "================= Xray Shadowsocks 已部署 ================="
echo "加密方式: ${METHOD}"
echo "密码:     ${SS_PASSWORD}"
echo "端口:     ${PORT}"
echo "服务器IP: ${SERVER_IP}"
echo
echo "SS 链接（可直接导入客户端）："
echo "${SS_URL}"
echo "==========================================================="
