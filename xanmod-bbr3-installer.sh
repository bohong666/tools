#!/usr/bin/env bash
# =========================================================
# BBR3 内核自动化安装管理工具
# 版本: 2.0.0
# 特性: 官方源安装、完整备份、一键还原
# =========================================================

set -euo pipefail

readonly SCRIPT_VERSION="2.0.0"
readonly BACKUP_DIR="/opt/bbr3-manager"
readonly BACKUP_INFO="$BACKUP_DIR/system_backup.conf"
readonly BACKUP_PACKAGES="$BACKUP_DIR/original_packages.list"
readonly SYSCTL_CONF="/etc/sysctl.d/99-bbr3.conf"
readonly XANMOD_REPO="/etc/apt/sources.list.d/xanmod-release.list"
readonly XANMOD_GPG="/usr/share/keyrings/xanmod-archive-keyring.gpg"

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# 日志函数
log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以 root 权限运行"
        exit 1
    fi
}

# 检测系统
detect_system() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "无法检测系统类型"
        exit 1
    fi
    
    source /etc/os-release
    
    case "$ID" in
        ubuntu|debian)
            log_success "检测到系统: $PRETTY_NAME"
            ;;
        *)
            log_error "不支持的系统: $PRETTY_NAME (仅支持 Ubuntu/Debian)"
            exit 1
            ;;
    esac
}

# 显示当前状态
show_status() {
    local current_kernel=$(uname -r)
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    local current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    local bbr3_status="不支持"
    local xanmod_installed="未安装"
    
    # 检查 BBR3 支持
    if grep -q "tcp_bbr" /proc/modules 2>/dev/null; then
        if modinfo tcp_bbr 2>/dev/null | grep -q "version.*3"; then
            bbr3_status="已加载 BBR v3"
        elif lsmod | grep -q tcp_bbr; then
            bbr3_status="已加载 BBR v1/v2"
        fi
    fi
    
    # 检测是否安装了 BBR v3（通过检查内核配置或模块）
    if [[ "$current_kernel" == *"xanmod"* ]]; then
        xanmod_installed="已安装"
        # XanMod 6.6+ 内核支持 BBR v3
        local kernel_version=$(echo "$current_kernel" | grep -oP '\d+\.\d+' | head -1)
        if awk "BEGIN {exit !($kernel_version >= 6.6)}"; then
            bbr3_status="内核支持 BBR v3"
        fi
    fi
    
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}              ${CYAN}当前系统网络配置状态${NC}                ${BLUE}║${NC}"
    echo -e "${BLUE}╠════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} 内核版本:      ${GREEN}$current_kernel${NC}"
    echo -e "${BLUE}║${NC} 拥塞控制:      ${GREEN}$current_cc${NC}"
    echo -e "${BLUE}║${NC} 队列算法:      ${GREEN}$current_qdisc${NC}"
    echo -e "${BLUE}║${NC} BBR3 状态:     ${YELLOW}$bbr3_status${NC}"
    echo -e "${BLUE}║${NC} XanMod 内核:   ${YELLOW}$xanmod_installed${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# 备份当前系统状态
backup_system() {
    log_info "正在备份当前系统状态..."
    mkdir -p "$BACKUP_DIR"
    
    # 保存系统信息
    cat > "$BACKUP_INFO" <<EOF
# BBR3 Manager 系统备份
# 备份时间: $(date '+%Y-%m-%d %H:%M:%S')
KERNEL=$(uname -r)
TCP_CC=$(sysctl -n net.ipv4.tcp_congestion_control)
QDISC=$(sysctl -n net.core.default_qdisc)
EOF
    
    # 保存当前已安装的内核包
    dpkg -l | grep -E 'linux-image|linux-headers' | awk '{print $2}' > "$BACKUP_PACKAGES"
    
    # 备份现有的 sysctl 配置
    if [[ -f "$SYSCTL_CONF" ]]; then
        cp "$SYSCTL_CONF" "${SYSCTL_CONF}.backup"
    fi
    
    log_success "系统状态已备份到: $BACKUP_DIR"
    log_info "备份包含: 内核版本、网络参数、内核包列表"
}

# 安装 XanMod 内核（BBR3）
install_xanmod_bbr3() {
    log_info "开始安装 XanMod 内核 (包含 BBR v3 支持)"
    
    # 先备份
    backup_system
    
    # 安装依赖
    log_info "安装必要依赖..."
    apt-get update
    apt-get install -y wget gnupg
    
    # 添加 XanMod 官方仓库
    log_info "添加 XanMod 官方 GPG 密钥..."
    wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor -o "$XANMOD_GPG"
    
    log_info "配置 XanMod 官方软件源..."
    echo "deb [signed-by=$XANMOD_GPG] http://deb.xanmod.org releases main" > "$XANMOD_REPO"
    
    # 更新软件源
    log_info "更新软件包列表..."
    apt-get update
    
    # 检查可用的 XanMod 内核
    log_info "检查可用的 XanMod 内核版本..."
    local available_kernels=$(apt-cache search linux-xanmod-x64v | grep -E 'linux-xanmod-x64v[0-9]' | awk '{print $1}' | sort -V)
    
    if [[ -z "$available_kernels" ]]; then
        log_error "未找到可用的 XanMod 内核包"
        log_info "尝试使用通用版本..."
        available_kernels=$(apt-cache search linux-xanmod | grep -E 'linux-xanmod-' | awk '{print $1}' | head -5)
    fi
    
    if [[ -z "$available_kernels" ]]; then
        log_error "无法找到任何 XanMod 内核包，请检查网络连接或系统兼容性"
        return 1
    fi
    
    echo ""
    log_info "找到以下可用内核:"
    echo "$available_kernels" | nl
    echo ""
    
    # 选择最新的 x64v3 版本（推荐）或第一个可用版本
    local selected_kernel=$(echo "$available_kernels" | grep 'x64v3' | tail -1)
    if [[ -z "$selected_kernel" ]]; then
        selected_kernel=$(echo "$available_kernels" | tail -1)
    fi
    
    log_warning "将安装: ${GREEN}$selected_kernel${NC}"
    log_warning "注意: x64v3 版本需要较新的 CPU (2013年后)，如果不兼容请选择 x64v2"
    echo ""
    read -p "$(echo -e ${YELLOW}是否继续安装? [Y/n]: ${NC})" confirm
    
    if [[ "$confirm" =~ ^[Nn] ]]; then
        log_info "取消安装"
        return 0
    fi
    
    # 安装内核
    log_info "正在安装 $selected_kernel (可能需要几分钟)..."
    if apt-get install -y "$selected_kernel"; then
        log_success "XanMod 内核安装成功"
    else
        log_error "内核安装失败"
        return 1
    fi
    
    # 配置 BBR3
    log_info "配置 BBR v3 参数..."
    cat > "$SYSCTL_CONF" <<EOF
# BBR v3 配置
# 由 BBR3 Manager 自动生成
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# 启用 BBR 相关优化
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
EOF
    
    log_success "BBR3 配置已写入: $SYSCTL_CONF"
    log_warning "注意: 需要重启系统后才能使用新内核和 BBR v3"
    
    echo ""
    read -p "$(echo -e ${YELLOW}是否立即重启? [y/N]: ${NC})" reboot_now
    if [[ "$reboot_now" =~ ^[Yy] ]]; then
        log_info "系统将在 3 秒后重启..."
        sleep 3
        reboot
    else
        log_warning "请手动重启系统: sudo reboot"
    fi
}

# 卸载 XanMod 并还原系统
uninstall_xanmod() {
    log_warning "准备卸载 XanMod 内核并还原系统..."
    
    if [[ ! -f "$BACKUP_INFO" ]]; then
        log_error "未找到备份信息文件"
        log_info "将仅执行卸载操作，无法自动还原到之前的内核"
        read -p "$(echo -e ${YELLOW}是否继续? [y/N]: ${NC})" confirm
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            return 0
        fi
    fi
    
    # 显示将被卸载的包
    local xanmod_packages=$(dpkg -l | grep linux-xanmod | awk '{print $2}')
    
    if [[ -z "$xanmod_packages" ]]; then
        log_warning "未检测到已安装的 XanMod 内核"
        return 0
    fi
    
    echo ""
    log_info "将卸载以下内核包:"
    echo "$xanmod_packages"
    echo ""
    read -p "$(echo -e ${YELLOW}确认卸载? [y/N]: ${NC})" confirm
    
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        log_info "取消卸载"
        return 0
    fi
    
    # 卸载 XanMod 内核
    log_info "正在卸载 XanMod 内核..."
    apt-get purge -y $xanmod_packages
    apt-get autoremove -y
    
    # 删除 XanMod 仓库
    if [[ -f "$XANMOD_REPO" ]]; then
        rm -f "$XANMOD_REPO"
        log_info "已删除 XanMod 软件源"
    fi
    
    if [[ -f "$XANMOD_GPG" ]]; then
        rm -f "$XANMOD_GPG"
        log_info "已删除 XanMod GPG 密钥"
    fi
    
    # 还原 sysctl 配置
    if [[ -f "$BACKUP_INFO" ]]; then
        log_info "还原网络配置..."
        source "$BACKUP_INFO"
        
        if [[ -n "${TCP_CC:-}" ]]; then
            echo "net.ipv4.tcp_congestion_control = $TCP_CC" > "$SYSCTL_CONF"
        fi
        if [[ -n "${QDISC:-}" ]]; then
            echo "net.core.default_qdisc = $QDISC" >> "$SYSCTL_CONF"
        fi
        
        sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true
        log_success "网络配置已还原"
    fi
    
    # 更新 GRUB
    log_info "更新 GRUB 配置..."
    update-grub
    
    log_success "XanMod 内核已完全卸载"
    log_warning "请重启系统以使用原来的内核"
    
    echo ""
    read -p "$(echo -e ${YELLOW}是否立即重启? [y/N]: ${NC})" reboot_now
    if [[ "$reboot_now" =~ ^[Yy] ]]; then
        log_info "系统将在 3 秒后重启..."
        sleep 3
        reboot
    fi
}

# 显示已安装的内核
show_kernels() {
    echo ""
    log_info "已安装的内核包:"
    dpkg -l | grep -E 'linux-image|linux-headers' | awk '{printf "  %s %s\n", $2, $3}'
    
    echo ""
    log_info "/boot 目录内容:"
    ls -lh /boot | grep -E 'vmlinuz|initrd'
    
    echo ""
    log_info "当前使用的内核: $(uname -r)"
}

# 查看备份信息
show_backup_info() {
    if [[ ! -f "$BACKUP_INFO" ]]; then
        log_warning "未找到备份信息"
        return 0
    fi
    
    echo ""
    log_info "备份信息:"
    cat "$BACKUP_INFO"
    
    if [[ -f "$BACKUP_PACKAGES" ]]; then
        echo ""
        log_info "备份的内核包列表:"
        cat "$BACKUP_PACKAGES"
    fi
}

# 主菜单
show_menu() {
    clear
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                                                            ║"
    echo "║          BBR v3 内核管理工具 v${SCRIPT_VERSION}                    ║"
    echo "║          官方源安装 · 完整备份 · 一键还原                   ║"
    echo "║                                                            ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    show_status
    
    echo -e "${CYAN}请选择操作:${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}) 安装 XanMod 内核 (包含 BBR v3)"
    echo -e "  ${GREEN}2${NC}) 卸载 XanMod 并还原系统"
    echo -e "  ${GREEN}3${NC}) 查看已安装的内核"
    echo -e "  ${GREEN}4${NC}) 查看备份信息"
    echo -e "  ${GREEN}5${NC}) 手动备份当前状态"
    echo -e "  ${GREEN}6${NC}) 重启系统"
    echo -e "  ${RED}0${NC}) 退出"
    echo ""
    echo -ne "${YELLOW}请输入选项 [0-6]: ${NC}"
}

# 主循环
main() {
    check_root
    detect_system
    
    while true; do
        show_menu
        read -r choice
        
        case "$choice" in
            1)
                install_xanmod_bbr3
                ;;
            2)
                uninstall_xanmod
                ;;
            3)
                show_kernels
                ;;
            4)
                show_backup_info
                ;;
            5)
                backup_system
                ;;
            6)
                log_warning "系统将在 3 秒后重启..."
                sleep 3
                reboot
                ;;
            0)
                log_info "感谢使用！"
                exit 0
                ;;
            *)
                log_error "无效选项，请重新选择"
                ;;
        esac
        
        echo ""
        read -p "$(echo -e ${CYAN}按回车键继续...${NC})"
    done
}

# 运行主程序
main
