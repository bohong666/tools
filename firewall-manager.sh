#!/bin/bash
# firewall-manager.sh
# 支持 Ubuntu / Debian，自动识别 ufw 或 iptables
# 作者：ChatGPT GPT-5
# 更新时间：2025-11-07

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本（sudo bash $0）"
  exit 1
fi

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

# 显示当前状态
show_status() {
  echo "=============================="
  echo "🔍 防火墙类型: $FW_TYPE"
  echo "=============================="
  if [ "$FW_TYPE" = "ufw" ]; then
    ufw status verbose
  else
    echo "🔥 当前 iptables 规则："
    iptables -L -n -v
  fi
}

# 列出允许与禁用端口
list_ports() {
  echo "=============================="
  echo "📋 当前端口策略："
  echo "=============================="
  if [ "$FW_TYPE" = "ufw" ]; then
    ufw status numbered
  else
    echo "✅ 允许端口："
    iptables -L INPUT -n | grep ACCEPT | awk '{print $7}' | grep -E '^[0-9]+$' | sort -u
    echo
    echo "🚫 禁止端口："
    iptables -L INPUT -n | grep DROP | awk '{print $7}' | grep -E '^[0-9]+$' | sort -u
  fi
}

# 开启或关闭防火墙
toggle_firewall() {
  local action=$1
  if [ "$FW_TYPE" = "ufw" ]; then
    if [ "$action" = "on" ]; then
      ufw enable
    else
      ufw disable
    fi
  else
    if [ "$action" = "on" ]; then
      systemctl start netfilter-persistent 2>/dev/null || iptables -P INPUT ACCEPT
    else
      iptables -P INPUT ACCEPT
      iptables -F
      echo "⚠️ iptables 已清空规则（相当于关闭防火墙）"
    fi
  fi
}

# 添加或删除端口
modify_port() {
  local action=$1
  local port=$2
  if [ "$FW_TYPE" = "ufw" ]; then
    if [ "$action" = "allow" ]; then
      ufw allow "$port"
    elif [ "$action" = "deny" ]; then
      ufw deny "$port"
    elif [ "$action" = "delete" ]; then
      ufw delete "$port"
    fi
  else
    if [ "$action" = "allow" ]; then
      iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
    elif [ "$action" = "deny" ]; then
      iptables -A INPUT -p tcp --dport "$port" -j DROP
    elif [ "$action" = "delete" ]; then
      iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
      iptables -D INPUT -p tcp --dport "$port" -j DROP 2>/dev/null
    fi
  fi
}

# 保存规则
save_rules() {
  if [ "$FW_TYPE" = "ufw" ]; then
    ufw reload
  else
    apt install -y iptables-persistent >/dev/null 2>&1
    netfilter-persistent save
    echo "✅ 规则已保存（重启后仍然生效）"
  fi
}

# 主菜单
main_menu() {
  detect_firewall
  show_status
  echo
  echo "=============================="
  echo "🧭 防火墙管理菜单"
  echo "=============================="
  echo "1) 查看端口规则"
  echo "2) 开启防火墙"
  echo "3) 关闭防火墙"
  echo "4) 临时关闭防火墙（重启后恢复）"
  echo "5) 添加允许端口"
  echo "6) 添加禁止端口"
  echo "7) 删除端口规则"
  echo "8) 保存并重启防火墙"
  echo "9) 退出"
  echo
  read -p "请选择操作编号: " choice
  case $choice in
    1) list_ports ;;
    2) toggle_firewall on ;;
    3) toggle_firewall off ;;
    4) echo "⚠️ 临时关闭：仅清空当前规则，不保存"; iptables -F ;;
    5) read -p "请输入端口号: " port; modify_port allow "$port" ;;
    6) read -p "请输入端口号: " port; modify_port deny "$port" ;;
    7) read -p "请输入端口号: " port; modify_port delete "$port" ;;
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

main_menu
