#!/bin/bash

echo "=== 当前 TCP 拥塞控制算法 ==="
sysctl net.ipv4.tcp_congestion_control

echo
echo "=== 系统可用的 TCP 拥塞控制算法 ==="
sysctl net.ipv4.tcp_available_congestion_control

echo
echo "=== 当前内核版本 ==="
uname -r

echo
echo "=== 检测 BBR 版本 ==="
# 检查内核是否加载了 BBR 模块
if lsmod | grep -q bbr; then
    echo "内核模块 bbr 已加载"
else
    echo "内核模块 bbr 未加载 (默认内置在现代内核里)"
fi

# 判断 BBR3 支持
if grep -q bbr3 /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    echo "系统支持 BBR3，可以设置 tcp_congestion_control=bbr3"
else
    echo "系统不支持 BBR3，只能使用原版 BBR1"
fi

# 输出内核配置相关信息
echo
echo "=== 内核 TCP BBR 信息 ==="
dmesg | grep -i bbr | tail -n 10
