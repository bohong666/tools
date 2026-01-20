#!/bin/sh
set -e

BASE="/opt/xray-relay"
XRAY_CONF="$BASE/xray.json"
LIST="$BASE/vless.list"
ACTIVE="$BASE/active"
INIT="$BASE/.initialized"
SSCONF="$BASE/ss.conf"

mkdir -p "$BASE"

# ========= 基础工具 =========
get_ip() {
  ip route get 1 | awk '{print $7; exit}'
}

pause() {
  echo ""
  read -p "回车继续..." _
}

# ========= 系统检测 =========
detect_os() {
  if [ -f /etc/alpine-release ]; then
    OS="alpine"
  elif [ -f /etc/debian_version ]; then
    OS="debian"
  else
    echo "❌ 不支持的系统"
    exit 1
  fi
}

install_xray() {
  if command -v xray >/dev/null 2>&1; then
    return
  fi

  echo "📦 安装 Xray..."

  if [ "$OS" = "alpine" ]; then
    apk add --no-cache curl xray
  else
    apt update
    apt install -y curl xray
  fi
}

# ========= 初始化 =========
init_env() {
  if [ -f "$INIT" ]; then
    return
  fi

  echo "⚙️ 首次运行，初始化 SS 中转参数"

  read -p "请输入 SS 监听端口: " SS_PORT
  read -p "请输入 SS 密码: " SS_PASS

  echo "选择加密方式："
  echo "1) aes-128-gcm（推荐）"
  echo "2) chacha20-ietf-poly1305"
  read -p "选择 [1-2]: " m

  case "$m" in
    2) SS_METHOD="chacha20-ietf-poly1305" ;;
    *) SS_METHOD="aes-128-gcm" ;;
  esac

  cat > "$SSCONF" <<EOF
SS_PORT=$SS_PORT
SS_PASS=$SS_PASS
SS_METHOD=$SS_METHOD
EOF

  touch "$LIST"
  touch "$INIT"

  echo "✅ 初始化完成"
}

load_ssconf() {
  . "$SSCONF"
}

# ========= VLESS 解析 =========
parse_vless() {
  url="$1"

  uuid=$(echo "$url" | sed -n 's|vless://\([^@]*\)@.*|\1|p')
  host=$(echo "$url" | sed -n 's|vless://[^@]*@\([^:]*\):.*|\1|p')
  port=$(echo "$url" | sed -n 's|.*:\([0-9]*\)?.*|\1|p')

  [ -z "$uuid" ] || [ -z "$host" ] || [ -z "$port" ] && return 1

  echo "$uuid|$host|$port"
}

# ========= Xray =========
write_xray_conf() {
  idx=$(cat "$ACTIVE")
  line=$(sed -n "${idx}p" "$LIST")

  uuid=$(echo "$line" | cut -d'|' -f1)
  host=$(echo "$line" | cut -d'|' -f2)
  port=$(echo "$line" | cut -d'|' -f3)

  cat > "$XRAY_CONF" <<EOF
{
  "inbounds": [
    {
      "port": $SS_PORT,
      "protocol": "shadowsocks",
      "settings": {
        "method": "$SS_METHOD",
        "password": "$SS_PASS",
        "network": "tcp,udp"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$host",
            "port": $port,
            "users": [
              { "id": "$uuid", "encryption": "none" }
            ]
          }
        ]
      }
    }
  ]
}
EOF
}

restart_xray() {
  pkill xray 2>/dev/null || true
  nohup xray run -config "$XRAY_CONF" >/dev/null 2>&1 &
}

# ========= 菜单功能 =========
add_node() {
  read -p "请输入完整 VLESS 链接: " url
  parse_vless "$url" >> "$LIST" || { echo "❌ 解析失败"; pause; return; }
  echo "✅ 已添加"
  pause
}

list_nodes() {
  nl -w2 -s'. ' "$LIST" || echo "（暂无落地）"
  pause
}

use_node() {
  list_nodes
  read -p "选择编号: " n
  sed -n "${n}p" "$LIST" >/dev/null || { echo "❌ 无效编号"; pause; return; }
  echo "$n" > "$ACTIVE"
  write_xray_conf
  restart_xray
  echo "🔁 已切换"
  pause
}

show_ss() {
  ip=$(get_ip)

  echo ""
  echo "====== Shadowsocks 连接信息 ======"
  echo ""
  echo "ss://$(printf "%s:%s@%s:%s" "$SS_METHOD" "$SS_PASS" "$ip" "$SS_PORT" | base64 | tr -d '\n')"
  echo ""
  echo "Clash Party 示例："
  echo "--------------------------------"
  cat <<EOF
- name: NAT-Relay
  type: ss
  server: $ip
  port: $SS_PORT
  cipher: $SS_METHOD
  password: $SS_PASS
  udp: true
EOF
  echo "--------------------------------"
  pause
}

edit_ss() {
  echo "当前端口: $SS_PORT"
  read -p "新端口（回车不改）: " p
  [ -n "$p" ] && SS_PORT="$p"

  echo "当前密码: $SS_PASS"
  read -p "新密码（回车不改）: " pw
  [ -n "$pw" ] && SS_PASS="$pw"

  cat > "$SSCONF" <<EOF
SS_PORT=$SS_PORT
SS_PASS=$SS_PASS
SS_METHOD=$SS_METHOD
EOF

  [ -f "$ACTIVE" ] && write_xray_conf && restart_xray
  echo "✅ SS 参数已更新"
  pause
}

menu() {
  while true; do
    clear
    echo "====== Xray SS 中转 ======"
    echo "1. 添加 VLESS 落地"
    echo "2. 查看落地列表"
    echo "3. 切换落地"
    echo "4. 查看 SS 连接"
    echo "5. 修改 SS 参数"
    echo "0. 退出"
    read -p "选择: " c

    case "$c" in
      1) add_node ;;
      2) list_nodes ;;
      3) use_node ;;
      4) show_ss ;;
      5) edit_ss ;;
      0) exit 0 ;;
    esac
  done
}

# ========= 主流程 =========
detect_os
install_xray
init_env
load_ssconf
menu

