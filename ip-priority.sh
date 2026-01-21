#!/bin/bash

echo "=== 当前出口检测 ==="
echo -n "自动出口 IP: "
curl -s https://api64.ipify.org || echo "失败"

echo
echo "DNS 优先顺序："
getent ahosts google.com | head -n 2

echo
echo "1) 设置 IPv4 优先"
echo "2) 设置 IPv6 优先"
echo "0) 退出"
read -rp "选择: " opt

case "$opt" in
  1)
    sed -i '/precedence ::ffff:0:0\/96/d' /etc/gai.conf
    echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
    echo "已设置 IPv4 优先"
    ;;
  2)
    sed -i '/precedence ::ffff:0:0\/96/d' /etc/gai.conf
    echo "已设置 IPv6 优先"
    ;;
  *)
    exit 0
    ;;
esac

echo
echo "=== 修改后验证 ==="
getent ahosts google.com | head -n 2
echo -n "自动出口 IP: "
curl -s https://api64.ipify.org || echo "失败"
