#!/bin/bash
# firewall-manager.sh
# 支持 Ubuntu / Debian，自动识别 ufw 或 iptables
# 作者：ChatGPT GPT-5
# 版本：v1.6
# 更新时间：2025-11-07

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本（sudo bash $0）"
  exit 1
fi

FW_VERSION="v1.6"

# 检测防火墙类型
detect_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    FW_TYPE="ufw"
  elif command -v iptables >/dev/null 2>&1; then
    FW_TYPE="iptables"
  else
    echo "❌ 未检测到 ufw 或 iptables，请先安装防火墙"
    exit 1
  fi
}

# 显示防火墙状态及原始规则
show_status() {
  echo "=================================="
  echo "🧭 Linux 防火墙管理器 ($FW_TYPE) - $FW_VERSION"
  echo "=================================="

  if [ "$FW_TYPE" = "ufw" ]; then
    echo "🔹 ufw 状态（完整规则）："
    ufw status verbose
  else
    echo "🔹 iptables 状态（完整 INPUT 链规则）："
    iptables -L INPUT -n -v --line-numbers
  fi
  echo "=================================="
}

# 添加或删除端口 (支持 tcp / udp / both)
modify_port() {
  local action=$1
  local port=$2
  local proto=$3

  [[ "$proto" == "both" ]] && proto_list=("tcp" "udp") || proto_list=("$proto")

  for p in "${proto_list[@]}"; do
    if [ "$FW_TYPE" = "ufw" ]; then
      case $action in
        allow) ufw allow "$port/$p" ;;
        deny) ufw deny "$port/$p" ;;
        delete)
          ufw delete allow "$port/$p" 2>/dev/null
          ufw delete deny "$port/$p" 2>/dev/null
          ;;
      esac
    else
      case $action in
        allow)
          iptables -C INPUT -p "$p" --dport "$port" -j ACCEPT 2>/dev/null
          if [ $? -ne 0 ]; then
            iptables -A INPUT -p "$p" --dport "$port" -j ACCEPT
            echo "✅ 已允许 $p 端口 $port"
          else
            echo "⚠️ $p 端口 $port 已存在允许规则"
          fi
          ;;
        deny)
          iptables -C INPUT -p "$p" --dport "$port" -j DROP 2>/dev/null
          if [ $? -ne 0 ]; then
            iptables -A INPUT -p "$p" --dport "$port" -j DROP
            echo "🚫 已禁止 $p 端口 $port"
          else
            echo "⚠️ $p 端口 $port 已存在禁止规则"
          fi
          ;;
        delete)
          iptables -D INPUT -p "$p" --dport "$port" -j ACCEPT 2>/dev/null
          iptables -D INPUT -p "$p" --dport "$port" -j DROP 2>/dev/null
          echo "🧹 已删除 $p 端口 $port 的规则"
          ;;
      esac
    fi
  done
}

# 保存规则
save_rules() {
  if [ "$FW_TYPE" = "ufw" ]; then
    ufw reload
    echo "✅ ufw 规则已重新加载"
  else
    apt install -y iptables-persistent >/dev/null 2>&1
    netfilter-persistent save
    echo "✅ iptables 规则已保存（重启后仍然生效）"
  fi
}

# 协议选择
choose_proto() {
  echo
  echo "请选择协议类型："
  echo "1) TCP"
  echo "2) UDP"
  echo "3) TCP + UDP（同时开放）"
  read -p "输入编号 (1/2/3): " proto_choice
  case $proto_choice in
    1) proto="tcp" ;;
    2) proto="udp" ;;
    3) proto="both" ;;
    *) echo "❌ 输入无效，默认 TCP"; proto="tcp" ;;
  esac
  echo "$proto"
}

# 临时清空规则（仅 iptables）
temp_clear() {
  if [ "$FW_TYPE" = "iptables" ]; then
    iptables -F
    iptables -P INPUT ACCEPT
    echo "⚠️ iptables 规则已清空（重启后恢复默认策略）"
  else
    echo "⚠️ ufw 不支持临时清空，请使用 ufw disable"
  fi
}

# 开启/关闭防火墙
toggle_firewall() {
  local action=$1
  if [ "$FW_TYPE" = "ufw" ]; then
    [ "$action" == "on" ] && ufw enable || ufw disable
  else
    if [ "$action" == "on" ]; then
      systemctl start netfilter-persistent 2>/dev/null || echo "✅ iptables 已启动"
    else
      iptables -F
      iptables -P INPUT ACCEPT
      echo "⚠️ iptables 已清空规则（关闭防火墙）"
    fi
  fi
}

# 主菜单
main_menu() {
  detect_firewall
  show_status

  echo
  echo "=============================="
  echo "🔥 防火墙管理菜单"
  echo "=============================="
  echo "1) 查看端口规则"
  echo "2) 开启防火墙"
  echo "3) 关闭防火墙"
  echo "4) 临时关闭防火墙（清空规则）"
  echo "5) 允许端口"
  echo "6) 禁止端口"
  echo "7) 删除端口规则"
  echo "8) 保存并重启防火墙"
  echo "9) 退出"
  echo "=============================="

  read -p "请选择操作编号: " choice

  case $choice in
    1) show_status ;;
    2) toggle_firewall on ;;
    3) toggle_firewall off ;;
    4) temp_clear ;;
    5)
      read -p "请输入端口号: " port
      proto=$(choose_proto)
      modify_port allow "$port" "$proto"
      ;;
    6)
      read -p "请输入端口号: " port
      proto=$(choose_proto)
      modify_port deny "$port" "$proto"
      ;;
    7)
      read -p "请输入端口号: " port
      proto=$(choose_proto)
      modify_port delete "$port" "$proto"
      ;;
    8) save_rules ;;
    9) echo "👋 已退出"; exit 0 ;;
    *) echo "❌ 无效选项" ;;
  esac

  echo
  read -p "是否返回主菜单？(y/n): " again
  if [ "$again" = "y" ]; then
    main_menu
  else
    echo "✅ 操作完成。"
  fi
}

# 启动
main_menu
