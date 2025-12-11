#!/usr/bin/env bash
# =========================================================
# BBR Manager 网络栈管理工具
# Version: 1.1.0
# Author: ChatGPT
# =========================================================

set -e

SCRIPT_VERSION="1.1.0"
BACKUP_DIR="/etc/bbr-manager"
BACKUP_FILE="$BACKUP_DIR/backup.json"
BACKUP_CONF="$BACKUP_DIR/backup.conf"

# ---------------------------------------------------------
# Color
# ---------------------------------------------------------
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
RESET="\e[0m"

# ---------------------------------------------------------
# Ensure root
# ---------------------------------------------------------
[[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 执行脚本${RESET}" && exit 1

mkdir -p "$BACKUP_DIR"

# ---------------------------------------------------------
# Detect System Status
# ---------------------------------------------------------
detect_status() {
    CURRENT_KERNEL=$(uname -r)
    CC=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    QDISC=$(sysctl net.core.default_qdisc | awk '{print $3}')

    BBR_VER="未知"
    modprobe tcp_bbr3 &>/dev/null && BBR_VER="BBRv3 可用"

    XANMOD="未安装"
    echo "$CURRENT_KERNEL" | grep -qi xanmod && XANMOD="已安装"

    echo -e "${CYAN}========== 当前系统状态 ==========${RESET}"
    echo -e "${GREEN}内核版本:         ${RESET}$CURRENT_KERNEL"
    echo -e "${GREEN}拥塞控制算法:     ${RESET}$CC"
    echo -e "${GREEN}队列调度算法:     ${RESET}$QDISC"
    echo -e "${GREEN}BBR 状态:         ${RESET}$BBR_VER"
    echo -e "${GREEN}XanMod 内核:      ${RESET}$XANMOD"
    echo -e "${CYAN}==================================${RESET}\n"
}

# ---------------------------------------------------------
# Backup Current State
# ---------------------------------------------------------
backup_state() {
    echo -e "${YELLOW}正在备份当前系统状态...${RESET}"

    cat > "$BACKUP_FILE" <<EOF
{
  "kernel": "$(uname -r)",
  "cc": "$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')",
  "qdisc": "$(sysctl net.core.default_qdisc | awk '{print $3}')"
}
EOF

    echo "KERNEL=$(uname -r)" > "$BACKUP_CONF"
    echo "CC=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')" >> "$BACKUP_CONF"
    echo "QDISC=$(sysctl net.core.default_qdisc | awk '{print $3}')" >> "$BACKUP_CONF"

    echo -e "${GREEN}备份完成：$BACKUP_FILE${RESET}\n"
}

# ---------------------------------------------------------
# Restore Backup
# ---------------------------------------------------------
restore_backup() {
    [[ ! -f "$BACKUP_CONF" ]] && echo -e "${RED}没有找到备份文件！${RESET}" && return

    echo -e "${YELLOW}加载备份...${RESET}"
    source "$BACKUP_CONF"

    echo -e "${GREEN}恢复拥塞控制算法: $CC${RESET}"
    sysctl -w net.ipv4.tcp_congestion_control="$CC" >/dev/null

    echo -e "${GREEN}恢复队列调度算法: $QDISC${RESET}"
    sysctl -w net.core.default_qdisc="$QDISC" >/dev/null

    echo -e "${GREEN}恢复内核包信息: $KERNEL${RESET}"
    echo -e "${CYAN}恢复完成，建议重启系统${RESET}"
}

# ---------------------------------------------------------
# Add XanMod Repo & Install
# ---------------------------------------------------------
install_xanmod() {
    echo -e "${YELLOW}正在添加 XanMod 仓库...${RESET}"

    # 使用正确 GPG Key
    curl -fsSL https://dl.xanmod.org/gpg.key \
        | gpg --dearmor \
        | tee /usr/share/keyrings/xanmod.gpg >/dev/null

    echo "deb [signed-by=/usr/share/keyrings/xanmod.gpg] http://deb.xanmod.org releases main" \
        > /etc/apt/sources.list.d/xanmod.list

    apt-get update -y

    # 自动查找可用 XanMod 内核包
    PACKAGE_NAME=$(apt-cache search linux-xanmod | grep -E 'linux-xanmod(-lts|-mainline)?' | awk '{print $1}' | head -n1)

    if [[ -z "$PACKAGE_NAME" ]]; then
        echo -e "${RED}未找到可安装的 XanMod 内核包，请确认仓库是否支持当前 Ubuntu 版本${RESET}"
        return
    fi

    echo -e "${GREEN}找到可安装包: $PACKAGE_NAME${RESET}"
    apt-get install -y "$PACKAGE_NAME"

    echo -e "${GREEN}XanMod 内核安装完成，请重启系统${RESET}"
}

# ---------------------------------------------------------
# Choose CC & QDISC
# ---------------------------------------------------------
select_cc_and_qdisc() {
    echo -e "${CYAN}可用拥塞控制算法:${RESET}"
    sysctl net.ipv4.tcp_available_congestion_control

    echo -e "\n${CYAN}可用队列算法:${RESET}"
    echo -e "常见: fq, fq_codel, cake"

    echo -e "\n${YELLOW}请输入要使用的拥塞算法 (如 bbr, bbr3, cubic): ${RESET}"
    read -r CC
    sysctl -w net.ipv4.tcp_congestion_control="$CC"

    echo -e "${YELLOW}请输入队列调度算法 (如 cake, fq, fq_codel): ${RESET}"
    read -r QDISC

    if [[ "$QDISC" == "cake" ]]; then
        echo -e "${CYAN}启用 CAKE 需要输入带宽值 (可分别输入 VPS 和本地带宽)：${RESET}"
        echo -e "${YELLOW}本地带宽 (例如 100mbit):${RESET}"
        read -r LOCAL_BW
        echo -e "${YELLOW}VPS 带宽 (例如 100mbit):${RESET}"
        read -r VPS_BW

        # 合并使用 (取最小值或单值可自行修改)
        BW="$LOCAL_BW"

        tc qdisc replace dev eth0 root cake bandwidth "$BW"
    else
        sysctl -w net.core.default_qdisc="$QDISC"
    fi

    echo -e "${GREEN}算法切换完毕！${RESET}\n"
}

# ---------------------------------------------------------
# Uninstall XanMod
# ---------------------------------------------------------
uninstall_xanmod() {
    echo -e "${YELLOW}正在卸载 XanMod 内核...${RESET}"

    PACKAGE_NAME=$(dpkg -l | grep linux-xanmod | awk '{print $2}')
    if [[ -n "$PACKAGE_NAME" ]]; then
        apt-get purge -y $PACKAGE_NAME
        apt-get autoremove -y
        echo -e "${GREEN}卸载完成，请选择旧内核启动${RESET}"
    else
        echo -e "${RED}未检测到 XanMod 内核已安装${RESET}"
    fi
}

# ---------------------------------------------------------
# Show /boot kernels
# ---------------------------------------------------------
show_kernels() {
    echo -e "${CYAN}/boot 内容:${RESET}"
    ls -l /boot

    echo -e "\n${CYAN}已安装内核包:${RESET}"
    dpkg --list | grep linux-image || true
}

# ---------------------------------------------------------
# Menu
# ---------------------------------------------------------
while true; do
clear
echo -e "${CYAN}======================================================${RESET}"
echo -e "        ${GREEN}BBR Manager 网络栈管理工具 v$SCRIPT_VERSION${RESET}"
echo -e "${CYAN}======================================================${RESET}"

detect_status

echo -e "${YELLOW}请选择操作:${RESET}"
echo -e " ${GREEN}1${RESET}) 安装 XanMod 内核"
echo -e " ${GREEN}2${RESET}) 切换 拥塞控制算法 & qdisc"
echo -e " ${GREEN}3${RESET}) 卸载 XanMod"
echo -e " ${GREEN}4${RESET}) 手动备份当前系统状态"
echo -e " ${GREEN}5${RESET}) 恢复备份"
echo -e " ${GREEN}6${RESET}) 显示 /boot 内容 & 内核列表"
echo -e " ${GREEN}7${RESET}) 重启系统"
echo -e " ${GREEN}0${RESET}) 退出"
echo -ne "${YELLOW}输入编号: ${RESET}"
read -r choice

case "$choice" in
    1) install_xanmod ;;
    2) select_cc_and_qdisc ;;
    3) uninstall_xanmod ;;
    4) backup_state ;;
    5) restore_backup ;;
    6) show_kernels ;;
    7) reboot ;;
    0) exit 0 ;;
    *) echo -e "${RED}无效输入${RESET}" ;;
esac

echo -e "\n按任意键返回菜单..."
read -n 1
done
