#!/bin/bash
# 自动安全防火墙配置脚本
# 适配 Debian / Ubuntu / CentOS
# 作者：ChatGPT（安全版）

### ------------------------
### 1. 检查 root 权限
### ------------------------
if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用 root 执行该脚本"
    exit 1
fi

### ------------------------
### 2. 检测系统类型
### ------------------------
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "❌ 无法识别系统类型"
    exit 1
fi

echo "🔍 检测到系统：$PRETTY_NAME"

### ------------------------
### 3. 检测当前 SSH 端口（避免锁死）
### ------------------------
SSH_PORT=$(ss -tlnp | grep sshd | awk '{print $4}' | sed 's/.*://')

if [ -z "$SSH_PORT" ]; then
    SSH_PORT=22
fi

echo "🔐 当前 SSH 端口自动检测为：$SSH_PORT"
echo "⚠️ 该端口将自动加入放行列表，确保不会断线。"

### ------------------------
### 4. 显示当前防火墙规则
### ------------------------
echo -e "\n=========================="
echo "当前 IPv4 iptables 规则："
echo "=========================="
iptables -L -n -v
echo -e "\n=========================="
echo "当前 IPv6 ip6tables 规则："
echo "=========================="
ip6tables -L -n -v

### ------------------------
### 5. 让用户输入需要放行的端口
### ------------------------
echo ""
echo "请输入你需要开放的端口（例如：443,80,12345）"
echo "SSH 端口（$SSH_PORT）会自动加入，无需重复输入"
read -p "允许的端口： " USER_PORTS

# 合并端口列表
ALLOW_PORTS="$SSH_PORT"
if [ -n "$USER_PORTS" ]; then
    ALLOW_PORTS="$ALLOW_PORTS,$USER_PORTS"
fi

echo ""
echo "允许放行的端口最终为：$ALLOW_PORTS"

### ------------------------
### 6. 二次确认
### ------------------------
read -p "⚠️ 确认要应用此防火墙规则？ (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "❌ 用户取消"
    exit 1
fi

echo ""
echo "🚧 开始应用规则..."

### ------------------------
### 7. 清空旧规则 / 设置默认策略
### ------------------------

# IPv4
iptables -F
iptables -X
iptables -Z
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# IPv6
ip6tables -F
ip6tables -X
ip6tables -Z
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT ACCEPT

### ------------------------
### 8. 通用放行规则
### ------------------------

# loopback
iptables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -i lo -j ACCEPT

# 已建立连接
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

### ------------------------
### 9. 禁用 ICMP（禁止 ping）
### ------------------------
iptables -A INPUT -p icmp -j DROP
ip6tables -A INPUT -p icmpv6 -j DROP

### ------------------------
### 10. 开放用户端口（IPv4 + IPv6）
### ------------------------
IFS=',' read -ra PORT_ARRAY <<< "$ALLOW_PORTS"

for port in "${PORT_ARRAY[@]}"; do
    port_trim=$(echo $port | xargs)

    echo "放行端口：$port_trim (TCP/UDP)"
    iptables -A INPUT -p tcp --dport "$port_trim" -j ACCEPT
    iptables -A INPUT -p udp --dport "$port_trim" -j ACCEPT

    ip6tables -A INPUT -p tcp --dport "$port_trim" -j ACCEPT
    ip6tables -A INPUT -p udp --dport "$port_trim" -j ACCEPT
done

### ------------------------
### 11. 保存规则
### ------------------------
if [[ "$OS" == "debian" || "$OS" == "ubuntu" ]]; then
    apt install -y iptables-persistent >/dev/null 2>&1
    netfilter-persistent save
    echo "💾 规则已保存（Debian/Ubuntu）"
elif [[ "$OS" == "centos" ]]; then
    service iptables save
    echo "💾 规则已保存（CentOS）"
else
    echo "⚠️ 未知系统，未保存规则，请手动保存！"
fi

echo ""
echo "✅ 防火墙规则已成功应用！当前开放端口：$ALLOW_PORTS"
echo "🔐 SSH ($SSH_PORT) 已自动保护，不会断线。"
echo "🛑 Ping (ICMP) 已关闭。"
echo ""
echo "建议你另外开一个终端测试："
echo "nc -zv YOUR_IP $SSH_PORT"
echo ""
echo "如需退回默认规则，可随时找我。"
