#!/bin/sh
set -e

BASE="/opt/xray-relay"
LIST="$BASE/vless.list"
ACTIVE="$BASE/active.conf"
XRAY_CONF="/etc/xray/config.json"

mkdir -p "$BASE"
touch "$LIST"

parse_vless() {
  URL="${1#vless://}"
  BASEP="${URL%%\?*}"
  QUERY="${URL#*\?}"

  UUID="${BASEP%@*}"
  HOSTPORT="${BASEP#*@}"
  ADDR="${HOSTPORT%:*}"
  PORT="${HOSTPORT##*:}"

  get() {
    echo "$QUERY" | tr '&' '\n' | grep "^$1=" | cut -d= -f2
  }

  FLOW=$(get flow)
  SEC=$(get security)
  SNI=$(get sni)
  PBK=$(get pbk)
  SID=$(get sid)
}

write_conf() {
cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": 1081,
    "protocol": "socks",
    "settings": { "udp": true }
  }],
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "$ADDR",
        "port": $PORT,
        "users": [{
          "id": "$UUID",
          "encryption": "none",
          "flow": "$FLOW"
        }]
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "$SEC",
      "tlsSettings": {
        "serverName": "$SNI",
        "realitySettings": {
          "publicKey": "$PBK",
          "shortId": "$SID"
        }
      }
    }
  }]
}
EOF
}

apply() {
  IDX="$1"
  LINE=$(sed -n "${IDX}p" "$LIST")
  [ -z "$LINE" ] && echo "无效编号" && return
  parse_vless "$LINE"
  write_conf
  echo "$IDX" > "$ACTIVE"
  rc-service xray restart
  echo "✅ 已切换落地 #$IDX"
}

menu() {
  echo "==============================="
  echo " Alpine NAT Xray 中转菜单"
  echo "==============================="
  echo " 1) 添加 VLESS 落地"
  echo " 2) 查看落地列表"
  echo " 3) 切换落地"
  echo " 4) 当前落地"
  echo " 5) 重启 Xray"
  echo " 0) 退出"
  echo "-------------------------------"
}

while true; do
  menu
  printf "请选择: "
  read c
  case "$c" in
    1)
      printf "粘贴 VLESS 链接: "
      read u
      echo "$u" >> "$LIST"
      echo "已添加"
      ;;
    2)
      nl -w2 -s'. ' "$LIST"
      ;;
    3)
      nl -w2 -s'. ' "$LIST"
      printf "选择编号: "
      read i
      apply "$i"
      ;;
    4)
      [ -f "$ACTIVE" ] && sed -n "$(cat $ACTIVE)p" "$LIST" || echo "未启用"
      ;;
    5)
      rc-service xray restart
      ;;
    0)
      exit 0
      ;;
    *)
      echo "无效选项"
      ;;
  esac
  echo
done
