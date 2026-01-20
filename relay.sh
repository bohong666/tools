#!/bin/sh
set -e

BASE="/opt/xray-relay"
XRAY_CONF="$BASE/xray.json"
LIST="$BASE/vless.list"
ACTIVE="$BASE/active"
INIT="$BASE/.initialized"

SS_PORT=8388
SS_PASS="relaypass"
SS_METHOD="aes-128-gcm"

mkdir -p "$BASE"

detect_os() {
  if [ -f /etc/alpine-release ]; then
    OS="alpine"
  elif [ -f /etc/debian_version ]; then
    OS="debian"
  else
    echo "不支持的系统"
    exit 1
  fi
}

install_deps() {
  if command -v xray >/dev/null 2>&1; then
    return
  fi

  if [ "$OS" = "alpine" ]; then
    apk add --no-cache curl unzip xray shadowsocks-libev
  else
    apt update
    apt install -y curl unzip xray shadowsocks-libev
  fi
}

init_env() {
  if [ ! -f "$INIT" ]; then
    touch "$LIST"
    touch "$INIT"
  fi
}

parse_vless() {
  url="$1"

  uuid=$(echo "$url" | sed -n 's|vless://\([^@]*\)@.*|\1|p')
  host=$(echo "$url" | sed -n 's|vless://[^@]*@\([^:]*\):.*|\1|p')
  port=$(echo "$url" | sed -n 's|.*:\([0-9]*\)?.*|\1|p')

  echo "$uuid|$host|$port"
}

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
              {
                "id": "$uuid",
                "encryption": "none"
              }
            ]
          }
        ]
      }
    }
  ]
}
EOF
}

restart_services() {
  pkill xray || true
  nohup xray run -config "$XRAY_CONF" >/dev/null 2>&1 &
}

add_node() {
  echo "请输入完整 VLESS 链接："
  read url
  parsed=$(parse_vless "$url")
  echo "$parsed" >> "$LIST"
  echo "已添加"
}

list_nodes() {
  nl -w2 -s'. ' "$LIST"
}

use_node() {
  list_nodes
  echo "选择编号："
  read n
  echo "$n" > "$ACTIVE"
  write_xray_conf
  restart_services
  echo "已切换"
}

current_node() {
  if [ ! -f "$ACTIVE" ]; then
    echo "尚未启用落地"
    return
  fi
  n=$(cat "$ACTIVE")
  echo "当前使用第 $n 个落地："
  sed -n "${n}p" "$LIST"
}

menu() {
  while true; do
    echo ""
    echo "==== Xray SS 中转 ===="
    echo "1. 添加落地"
    echo "2. 查看落地列表"
    echo "3. 切换落地"
    echo "4. 当前落地"
    echo "0. 退出"
    read -p "选择: " c

    case "$c" in
      1) add_node ;;
      2) list_nodes ;;
      3) use_node ;;
      4) current_node ;;
      0) exit 0 ;;
    esac
  done
}

detect_os
install_deps
init_env
menu

