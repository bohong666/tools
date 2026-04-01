#!/bin/bash

# ============================================
# Ubuntu/Alpine Xray VLESS+Reality+Vision 配置脚本
# 版本: v3.5.0
# 修复内容:
# 1. 修复 Xray v26.x x25519 密钥输出格式变化导致的解析失败
# 2. 修复 update_node_info 中 public_key 引用错误 ($PUBLIC_KEY 应为 $NEW_PUBLIC_KEY)
# 3. 增加多种密钥解析方案，兼容新旧版本格式
# 4. 增加磁盘空间检测，防止小硬盘 VPS 崩溃
# 5. 增加对纯 IPv6 (IPv6-only) VPS 的全面支持
# 6. 增加 GitHub 连通性检测及备用下载节点
# 7. 修复 LXC/Docker 容器环境下 swapon/sysctl 权限问题
# 8. [v3.5.0] 修复 parse_xray_keys 兼容 "Password (PublicKey):" 输出格式
# ============================================

SCRIPT_VERSION="v3.5.0"

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局变量
OS_TYPE=""
PKG_MANAGER=""
SERVICE_MANAGER=""
TOTAL_MEM=0
TOTAL_DISK=0

# 日志函数
log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${CYAN}[SUCCESS]${NC} $1"; }

# ============================================
# 系统检测
# ============================================
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME=$ID

        if [ "$OS_NAME" = "alpine" ]; then
            OS_TYPE="alpine"
            PKG_MANAGER="apk"
            SERVICE_MANAGER="openrc"
            log_info "检测到 Alpine Linux (轻量化模式)"
        elif [ "$OS_NAME" = "ubuntu" ] || [ "$OS_NAME" = "debian" ]; then
            OS_TYPE="ubuntu"
            PKG_MANAGER="apt"
            SERVICE_MANAGER="systemd"
            log_info "检测到 Ubuntu/Debian 系统"
        else
            log_error "不支持的操作系统: $OS_NAME"
            log_error "目前仅支持 Ubuntu/Debian 和 Alpine Linux"
            exit 1
        fi
    else
        log_error "无法检测操作系统"
        exit 1
    fi

    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
    TOTAL_DISK=$(df -BG / | awk 'NR==2 {print $2}' | sed 's/G//')
    log_info "系统资源: 内存 ${TOTAL_MEM}MB, 硬盘总大小 ${TOTAL_DISK}GB"

    if [ "$OS_TYPE" = "alpine" ] && [ "$TOTAL_MEM" -lt 256 ]; then
        log_warn "低内存环境 (<256MB), 将使用极简模式"
    fi
}

# 显示版本信息
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  Xray VLESS+Reality+Vision 配置脚本${NC}"
echo -e "${BLUE}  版本: ${SCRIPT_VERSION}${NC}"
echo -e "${BLUE}  支持: Ubuntu/Debian + Alpine Linux${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

if [[ $EUID -ne 0 ]]; then
    log_error "此脚本必须以root权限运行"
    exit 1
fi

detect_os

# ============================================
# 配置文件路径
# ============================================
CONFIG_FILE="/usr/local/etc/xray/config.json"
BACKUP_FILE="/root/xray_vless_links.txt"
BACKUP_DIR="/root/xray_backups"

# ============================================
# 【核心修复 v3.5.0】兼容新旧版本的密钥解析函数
#
# 已知输出格式汇总：
#   Xray v1.x:   "PrivateKey: xxx"         / "PublicKey: xxx"
#   Xray v26.x:  "Private key: xxx"        / "Public key: xxx"
#   Xray v26.x:  "PrivateKey: xxx"         / "Password (PublicKey): xxx"
#
# 修复要点：
#   公钥行不一定以 "public" 开头，需同时匹配行内含 "publickey" 的情况
# ============================================
parse_xray_keys() {
    local key_output="$1"

    # 私钥：匹配所有以 "private"（不区分大小写）开头的行，取最后一个字段
    # 兼容: "PrivateKey: xxx" / "Private key: xxx"
    NEW_PRIVATE_KEY=$(echo "$key_output" | grep -iE "^private" | awk '{print $NF}' | tr -d ' \n\r')

    # 公钥：匹配行首为 "public" 或行内含 "publickey" 的行，取最后一个字段
    # 兼容: "PublicKey: xxx" / "Public key: xxx" / "Password (PublicKey): xxx"
    NEW_PUBLIC_KEY=$(echo "$key_output" | grep -iE "(^public|publickey)" | awk '{print $NF}' | tr -d ' \n\r')

    # 验证结果
    if [ -z "$NEW_PRIVATE_KEY" ] || [ -z "$NEW_PUBLIC_KEY" ]; then
        log_error "密钥解析失败，原始输出如下："
        echo "$key_output"
        log_error "请检查 Xray 是否正确安装，或尝试手动运行: /usr/local/bin/xray x25519"
        return 1
    fi

    return 0
}

# 从私钥推导公钥（用于读取现有配置时）
derive_public_key() {
    local private_key="$1"
    local key_output
    key_output=$(/usr/local/bin/xray x25519 -i "$private_key" 2>&1)
    echo "$key_output" | grep -iE "(^public|publickey)" | awk '{print $NF}' | tr -d ' \n\r'
}

# ============================================
# UUID生成函数
# ============================================
generate_uuid() {
    if [ -f /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen &>/dev/null; then
        uuidgen
    elif /usr/local/bin/xray uuid 2>/dev/null | grep -qE '^[0-9a-f-]{36}$'; then
        /usr/local/bin/xray uuid 2>/dev/null
    else
        od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}'
    fi
}

# ============================================
# 重启Xray服务
# ============================================
restart_xray_service() {
    log_info "重启Xray服务..."

    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl restart xray
        sleep 2
        if systemctl is-active --quiet xray; then
            log_success "Xray服务重启成功"
        else
            log_error "Xray服务启动失败"
            journalctl -u xray -n 30 --no-pager
            exit 1
        fi
    else
        /etc/init.d/xray restart
        sleep 2
        if /etc/init.d/xray status 2>/dev/null | grep -q "started"; then
            log_success "Xray服务重启成功"
        else
            log_error "Xray服务启动失败"
            tail -n 50 /var/log/xray/error.log 2>/dev/null || echo "无法读取日志"
            exit 1
        fi
    fi
}

# ============================================
# 主菜单
# ============================================
show_main_menu() {
    echo ""
    echo -e "${CYAN}=====================================${NC}"
    echo -e "${CYAN}   Xray 配置管理菜单 ($OS_TYPE)${NC}"
    echo -e "${CYAN}=====================================${NC}"
    echo ""
    echo "请选择操作："
    echo ""
    echo "1) 全新安装 Xray 节点"
    echo "2) 更新现有节点信息 (UUID/密钥/ShortID)"
    echo "3) 显示当前节点信息"
    echo "4) 卸载 Xray"
    echo "5) 退出脚本"
    echo ""
    read -p "请输入选项 [1-5]: " MAIN_CHOICE

    case $MAIN_CHOICE in
        1) fresh_install ;;
        2) update_node_info ;;
        3) show_current_info ;;
        4) uninstall_xray ;;
        5) log_info "退出脚本"; exit 0 ;;
        *) log_error "无效选项"; show_main_menu ;;
    esac
}

# ============================================
# 显示当前节点信息
# ============================================
show_current_info() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "未检测到Xray配置，请先安装"
        exit 1
    fi

    log_info "读取当前节点配置..."
    echo ""

    UUID=$(grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
    PRIVATE_KEY=$(grep -o '"privateKey"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
    SHORT_ID=$(grep -o '"shortIds"[[:space:]]*:[[:space:]]*\[[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
    SERVER_NAME=$(grep -o '"serverNames"[[:space:]]*:[[:space:]]*\[[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
    DEST=$(grep -o '"dest"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')

    PUBLIC_KEY=$(derive_public_key "$PRIVATE_KEY")

    echo -e "${GREEN}========== 当前节点信息 ==========${NC}"
    echo "UUID: $UUID"
    echo "Private Key: $PRIVATE_KEY"
    echo "Public Key: $PUBLIC_KEY"
    echo "Short ID: $SHORT_ID"
    echo "ServerName: $SERVER_NAME"
    echo "目标地址: $DEST"
    echo "配置文件: $CONFIG_FILE"
    echo ""

    if [ -f "$BACKUP_FILE" ]; then
        echo -e "${GREEN}VLESS连接信息已保存在: ${NC}$BACKUP_FILE"
        echo ""
        if grep -q "VLESS URI (IPv4)" "$BACKUP_FILE"; then
            echo -e "${GREEN}VLESS URI (IPv4):${NC}"
            grep "VLESS URI (IPv4)" -A 1 "$BACKUP_FILE" 2>/dev/null | tail -1
            echo ""
        fi
        if grep -q "VLESS URI (IPv6)" "$BACKUP_FILE"; then
            echo -e "${GREEN}VLESS URI (IPv6):${NC}"
            grep "VLESS URI (IPv6)" -A 1 "$BACKUP_FILE" 2>/dev/null | tail -1
            echo ""
        fi
    fi

    echo ""
    read -p "按回车键返回主菜单..."
    show_main_menu
}

# ============================================
# 更新节点信息
# ============================================
update_node_info() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "未检测到现有配置，请先执行全新安装"
        exit 1
    fi

    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_warn "此操作将更新节点的关键信息"
    log_warn "更新后，旧的节点连接将立即失效"
    log_warn "请确保您已准备好更新客户端配置"
    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    read -p "确认要继续更新节点吗? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        log_info "已取消更新操作"
        show_main_menu
        return
    fi

    mkdir -p "$BACKUP_DIR"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    cp "$CONFIG_FILE" "$BACKUP_DIR/config_${TIMESTAMP}.json"
    [ -f "$BACKUP_FILE" ] && cp "$BACKUP_FILE" "$BACKUP_DIR/links_${TIMESTAMP}.txt"
    log_info "已备份当前配置到: $BACKUP_DIR/"

    CURRENT_SERVER_NAME=$(grep -o '"serverNames"[[:space:]]*:[[:space:]]*\[[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
    CURRENT_DEST=$(grep -o '"dest"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')

    echo ""
    log_info "当前ServerName: $CURRENT_SERVER_NAME"
    echo ""
    echo "选择ServerName配置方式:"
    echo "1) 保持当前配置: $CURRENT_SERVER_NAME"
    echo "2) 自定义新的ServerName"
    echo ""
    read -p "请选择 [1/2]: " SNI_CHOICE

    if [ "$SNI_CHOICE" = "2" ]; then
        read -p "请输入新的ServerName (如: www.example.com): " CUSTOM_SNI
        if [ -z "$CUSTOM_SNI" ]; then
            log_error "ServerName不能为空"
            update_node_info
            return
        fi
        SERVER_NAME="$CUSTOM_SNI"
        DEST="${CUSTOM_SNI}:443"
        log_info "将使用自定义ServerName: $SERVER_NAME"
    else
        SERVER_NAME="$CURRENT_SERVER_NAME"
        DEST="$CURRENT_DEST"
        log_info "保持当前ServerName: $SERVER_NAME"
    fi

    log_info "生成新的节点凭证..."

    NEW_UUID=$(generate_uuid)

    KEY_OUTPUT=$(/usr/local/bin/xray x25519 2>&1)
    # 【修复】使用兼容函数解析密钥
    if ! parse_xray_keys "$KEY_OUTPUT"; then
        exit 1
    fi

    NEW_SHORT_ID=$(openssl rand -hex 8)

    read -p "请输入新节点名称（回车使用默认）: " NODE_NAME
    [ -z "$NODE_NAME" ] && NODE_NAME="Xray-Reality-Updated-$(date +%Y%m%d)"

    log_info "✓ 新UUID: $NEW_UUID"
    log_info "✓ 新Private Key: $NEW_PRIVATE_KEY"
    log_info "✓ 新Public Key: $NEW_PUBLIC_KEY"
    log_info "✓ 新Short ID: $NEW_SHORT_ID"
    log_info "✓ ServerName: $SERVER_NAME"

    write_config_file "$NEW_UUID" "$NEW_PRIVATE_KEY" "$NEW_SHORT_ID" "$SERVER_NAME" "$DEST"

    if ! /usr/local/bin/xray run -test -config "$CONFIG_FILE"; then
        log_error "新配置验证失败，正在恢复备份..."
        cp "$BACKUP_DIR/config_${TIMESTAMP}.json" "$CONFIG_FILE"
        exit 1
    fi

    log_success "配置文件更新成功"
    restart_xray_service

    # 【修复】使用 $NEW_PUBLIC_KEY 而非旧的 $PUBLIC_KEY
    generate_connection_info "$NEW_UUID" "$NEW_PRIVATE_KEY" "$NEW_PUBLIC_KEY" "$NEW_SHORT_ID" "$NODE_NAME" "$SERVER_NAME" "$DEST"

    echo ""
    log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "节点信息更新完成！"
    log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_warn "重要提醒："
    echo "1. 旧的节点连接已失效"
    echo "2. 请使用上方新的VLESS URI更新客户端"
    echo "3. 详细信息已保存到: $BACKUP_FILE"
    echo "4. 旧配置备份在: $BACKUP_DIR/config_${TIMESTAMP}.json"
    echo ""

    read -p "按回车键返回主菜单..."
    show_main_menu
}

# ============================================
# 写入配置文件（抽取为独立函数，避免重复代码）
# ============================================
write_config_file() {
    local uuid="$1"
    local private_key="$2"
    local short_id="$3"
    local server_name="$4"
    local dest="$5"

    mkdir -p /usr/local/etc/xray

    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$dest",
          "serverNames": [
            "$server_name"
          ],
          "privateKey": "$private_key",
          "shortIds": [
            "$short_id"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
}

# ============================================
# 全新安装
# ============================================
fresh_install() {
    if [ -f "$CONFIG_FILE" ] && [ -f "$BACKUP_FILE" ]; then
        echo ""
        log_warn "检测到现有Xray配置！"
        echo ""
        echo "现有配置信息："
        echo "----------------------------------------"

        EXISTING_UUID=$(grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
        EXISTING_PRIVATE=$(grep -o '"privateKey"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
        EXISTING_SHORT=$(grep -o '"shortIds"[[:space:]]*:[[:space:]]*\[[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')

        [ -n "$EXISTING_UUID" ]    && echo "UUID: $EXISTING_UUID"
        [ -n "$EXISTING_PRIVATE" ] && echo "Private Key: ${EXISTING_PRIVATE:0:20}..."
        [ -n "$EXISTING_SHORT" ]   && echo "Short ID: $EXISTING_SHORT"

        if [ "$OS_TYPE" = "ubuntu" ]; then
            CONFIG_TIME=$(stat -c %y "$CONFIG_FILE" 2>/dev/null | cut -d'.' -f1)
        else
            CONFIG_TIME=$(stat "$CONFIG_FILE" 2>/dev/null | grep Modify | cut -d' ' -f2,3 | cut -d'.' -f1)
        fi
        [ -n "$CONFIG_TIME" ] && echo "配置时间: $CONFIG_TIME"

        echo "----------------------------------------"
        echo ""
        echo "请选择操作："
        echo "1) 保留现有配置，仅显示连接信息"
        echo "2) 生成新配置（旧配置将被备份）"
        echo "3) 返回主菜单"
        echo ""
        read -p "请输入选项 [1/2/3]: " CONFIG_CHOICE

        case $CONFIG_CHOICE in
            1) USE_EXISTING=true ;;
            2)
                USE_EXISTING=false
                mkdir -p "$BACKUP_DIR"
                TIMESTAMP=$(date +%Y%m%d_%H%M%S)
                cp "$CONFIG_FILE" "$BACKUP_DIR/config_${TIMESTAMP}.json"
                [ -f "$BACKUP_FILE" ] && cp "$BACKUP_FILE" "$BACKUP_DIR/links_${TIMESTAMP}.txt"
                log_info "旧配置已备份到: $BACKUP_DIR/"
                ;;
            3) show_main_menu; return ;;
            *) log_error "无效选项"; fresh_install; return ;;
        esac
    else
        log_info "未检测到现有配置，将创建新配置"
        USE_EXISTING=false
    fi

    if [ "$USE_EXISTING" = false ]; then
        read -p "请输入节点名称（回车使用默认）: " NODE_NAME
        [ -z "$NODE_NAME" ] && NODE_NAME="Xray-Reality-$(date +%Y%m%d)"

        echo ""
        echo "ServerName配置："
        echo "1) 使用默认: www.drymt.com"
        echo "2) 自定义ServerName"
        echo ""
        read -p "请选择 [1/2]: " SNI_CHOICE

        if [ "$SNI_CHOICE" = "2" ]; then
            read -p "请输入ServerName (如: www.example.com): " CUSTOM_SNI
            if [ -z "$CUSTOM_SNI" ]; then
                log_warn "输入为空，使用默认值"
                SERVER_NAME="www.drymt.com"
                DEST="www.drymt.com:443"
            else
                SERVER_NAME="$CUSTOM_SNI"
                DEST="${CUSTOM_SNI}:443"
            fi
        else
            SERVER_NAME="www.drymt.com"
            DEST="www.drymt.com:443"
        fi

        log_info "将使用ServerName: $SERVER_NAME"
    fi

    if [ "$USE_EXISTING" = false ]; then
        perform_system_setup
        install_xray
        generate_keys_and_config "$NODE_NAME" "$SERVER_NAME" "$DEST"
        configure_firewall
        start_xray_service
    else
        load_existing_config
    fi

    UUID="${UUID:-$NEW_UUID}"
    PRIVATE_KEY="${PRIVATE_KEY:-$NEW_PRIVATE_KEY}"
    PUBLIC_KEY="${PUBLIC_KEY:-$NEW_PUBLIC_KEY}"
    SHORT_ID="${SHORT_ID:-$NEW_SHORT_ID}"

    generate_connection_info "$UUID" "$PRIVATE_KEY" "$PUBLIC_KEY" "$SHORT_ID" "$NODE_NAME" "$SERVER_NAME" "$DEST"
    show_completion_summary "$USE_EXISTING"

    echo ""
    read -p "按回车键返回主菜单..."
    show_main_menu
}

# ============================================
# 系统设置（Ubuntu）
# ============================================
perform_system_setup_ubuntu() {
    log_info "开始配置Ubuntu系统..."

    log_info "检查系统包状态..."
    dpkg --configure -a 2>/dev/null || true

    log_info "修复系统依赖..."
    if apt --fix-broken install -y 2>&1 | grep -q "E:"; then
        log_warn "检测到严重依赖问题，尝试深度修复..."
        BROKEN_PKGS=$(apt --fix-broken install -y 2>&1 | grep "Depends:" | awk '{print $1}' | sort -u)
        if [ -n "$BROKEN_PKGS" ]; then
            for pkg in $BROKEN_PKGS; do
                apt remove -y "$pkg" 2>/dev/null || true
            done
            apt --fix-broken install -y
            apt autoremove -y
        fi
    fi

    log_info "更新系统软件包..."
    for i in {1..3}; do
        if apt update && apt upgrade -y; then
            break
        else
            log_warn "更新失败，第 $i 次重试..."
            apt --fix-broken install -y
            sleep 2
        fi
    done

    apt autoremove -y
    apt autoclean -y

    log_info "清除系统垃圾..."
    apt clean
    journalctl --vacuum-time=3d 2>/dev/null || true
    rm -rf /tmp/* /var/tmp/* 2>/dev/null || true

    # Swap 配置
    log_info "正在智能配置交换空间 (Swap)..."

    if [ -f /swapfile ]; then
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
    fi

    AVAIL_KB=$(df -k / | awk 'NR==2 {print $4}')
    DO_SWAP=false

    if [ -z "$AVAIL_KB" ]; then
        log_warn "无法检测剩余空间，跳过 Swap 创建"
    elif [ "$AVAIL_KB" -gt 3145728 ]; then
        log_info "磁盘剩余空间充足 ($((AVAIL_KB/1024))MB)，创建标准 2GB Swap..."
        fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 2>/dev/null || true
        DO_SWAP=true
    elif [ "$AVAIL_KB" -gt 1048576 ]; then
        log_warn "磁盘剩余空间有限 ($((AVAIL_KB/1024))MB)，降级创建 512MB Swap..."
        fallocate -l 512M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=512 2>/dev/null || true
        DO_SWAP=true
    else
        log_warn "磁盘剩余空间极低 ($((AVAIL_KB/1024))MB)，跳过 Swap 创建"
    fi

    if [ "$DO_SWAP" = true ] && [ -f /swapfile ]; then
        chmod 600 /swapfile
        mkswap /swapfile 2>/dev/null || true
        if swapon /swapfile 2>/dev/null; then
            grep -q '/swapfile' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            log_success "Swap 配置成功"
        else
            log_warn "当前环境不支持启用 Swap (LXC/Docker)，已跳过"
            rm -f /swapfile
        fi
    fi

    # BBR 配置
    log_info "启用BBR TCP加速..."
    touch /etc/sysctl.conf 2>/dev/null || true
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null       || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

    if sysctl -p 2>/dev/null; then
        log_success "BBR TCP加速已启用"
    else
        log_warn "容器环境权限不足，无法修改内核参数(BBR)，已跳过"
    fi

    log_info "安装必要依赖..."
    apt install -y curl wget unzip jq qrencode 2>/dev/null || apt install -y curl wget unzip
}

# ============================================
# 系统设置（Alpine）
# ============================================
perform_system_setup_alpine() {
    log_info "开始配置Alpine系统（轻量化模式）..."

    log_info "更新软件包索引..."
    apk update

    AVAIL_KB=$(df -k / | awk 'NR==2 {print $4}')
    DO_SWAP=false

    if [ -f /swapfile ]; then
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
    fi

    if [ "$AVAIL_KB" -ge 1048576 ]; then
        log_info "检测到足够剩余空间($((AVAIL_KB/1024))MB)，配置 512MB 交换空间..."
        dd if=/dev/zero of=/swapfile bs=1M count=512 2>/dev/null || true
        [ -f /swapfile ] && DO_SWAP=true
    else
        log_warn "硬盘可用空间不足 1GB ($((AVAIL_KB/1024))MB)，跳过交换空间配置"
    fi

    if [ "$DO_SWAP" = true ]; then
        chmod 600 /swapfile
        mkswap /swapfile 2>/dev/null || true
        if swapon /swapfile 2>/dev/null; then
            grep -q '/swapfile' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            log_success "已配置512MB交换空间"
        else
            log_warn "当前环境不支持启用 Swap (LXC/Docker)，已跳过"
            rm -f /swapfile
        fi
    fi

    log_info "启用BBR TCP加速..."
    touch /etc/sysctl.conf 2>/dev/null || true
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null       || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

    if sysctl -p 2>/dev/null; then
        log_success "BBR TCP加速已启用"
    else
        log_warn "容器环境权限不足，无法修改内核参数(BBR)，已跳过"
    fi

    log_info "安装必要依赖（极简模式）..."
    apk add --no-cache bash curl wget unzip openssl coreutils util-linux

    rm -rf /var/cache/apk/* /tmp/* 2>/dev/null || true
}

perform_system_setup() {
    if [ "$OS_TYPE" = "ubuntu" ]; then
        perform_system_setup_ubuntu
    else
        perform_system_setup_alpine
    fi
}

# ============================================
# 安装Xray（Alpine手动安装）
# ============================================
install_xray_alpine() {
    log_info "为Alpine手动安装Xray-core..."

    log_info "获取Xray最新版本..."
    if curl -sI -m 5 https://api.github.com >/dev/null 2>&1; then
        XRAY_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    else
        log_warn "无法直接访问GitHub API，使用 ghproxy..."
        XRAY_VERSION=$(curl -sL https://ghp.ci/https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    fi

    if [ -z "$XRAY_VERSION" ]; then
        log_warn "无法获取最新版本，使用默认版本 v1.8.4"
        XRAY_VERSION="v1.8.4"
    fi

    log_info "目标版本: $XRAY_VERSION"

    ARCH=$(uname -m)
    case $ARCH in
        x86_64)         XRAY_ARCH="64" ;;
        aarch64|arm64)  XRAY_ARCH="arm64-v8a" ;;
        armv7l)         XRAY_ARCH="arm32-v7a" ;;
        *) log_error "不支持的架构: $ARCH"; exit 1 ;;
    esac

    log_info "系统架构: $ARCH -> Xray架构: $XRAY_ARCH"

    DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"
    if ! curl -sI -m 5 https://github.com >/dev/null 2>&1; then
        log_warn "无法直接访问 GitHub，使用 ghp.ci 代理下载..."
        DOWNLOAD_URL="https://ghp.ci/${DOWNLOAD_URL}"
    fi
    log_info "下载地址: $DOWNLOAD_URL"

    cd /tmp
    rm -f "Xray-linux-${XRAY_ARCH}.zip"

    if ! wget -O "Xray-linux-${XRAY_ARCH}.zip" "$DOWNLOAD_URL"; then
        log_error "Xray下载失败"
        exit 1
    fi

    log_info "解压Xray..."
    unzip -o "Xray-linux-${XRAY_ARCH}.zip" -d /tmp/xray_tmp

    log_info "安装Xray文件..."
    mkdir -p /usr/local/bin /usr/local/etc/xray /var/log/xray /usr/local/share/xray

    install -m 755 /tmp/xray_tmp/xray /usr/local/bin/xray
    [ -f /tmp/xray_tmp/geoip.dat ]   && cp /tmp/xray_tmp/geoip.dat   /usr/local/share/xray/ || true
    [ -f /tmp/xray_tmp/geosite.dat ] && cp /tmp/xray_tmp/geosite.dat /usr/local/share/xray/ || true

    rm -rf /tmp/xray_tmp "/tmp/Xray-linux-${XRAY_ARCH}.zip"

    if ! /usr/local/bin/xray version; then
        log_error "Xray安装失败"
        exit 1
    fi

    log_success "Xray安装成功"

    log_info "创建OpenRC服务..."
    cat > /etc/init.d/xray <<'EOFSERVICE'
#!/sbin/openrc-run

name="xray"
description="Xray Service"
command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/xray/access.log"
error_log="/var/log/xray/error.log"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log/xray
}
EOFSERVICE

    chmod +x /etc/init.d/xray
    log_success "OpenRC服务创建成功"
}

# ============================================
# 安装Xray（Ubuntu使用官方脚本）
# ============================================
install_xray_ubuntu() {
    log_info "使用官方脚本安装Xray-core..."
    if curl -sI -m 5 https://raw.githubusercontent.com >/dev/null 2>&1; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    else
        log_warn "无法访问GitHub，使用代理下载安装脚本..."
        bash -c "$(curl -L https://ghp.ci/https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" @ install
    fi
}

install_xray() {
    if [ "$OS_TYPE" = "alpine" ]; then
        install_xray_alpine
    else
        install_xray_ubuntu
    fi
}

# ============================================
# 生成密钥和配置
# ============================================
generate_keys_and_config() {
    local node_name="$1"
    local server_name="$2"
    local dest="$3"

    log_info "生成密钥对和UUID..."

    NEW_UUID=$(generate_uuid)

    KEY_OUTPUT=$(/usr/local/bin/xray x25519 2>&1)
    # 【核心修复】使用兼容新旧版本的解析函数
    if ! parse_xray_keys "$KEY_OUTPUT"; then
        exit 1
    fi

    NEW_SHORT_ID=$(openssl rand -hex 8)

    log_info "✓ UUID: $NEW_UUID"
    log_info "✓ Private Key: $NEW_PRIVATE_KEY"
    log_info "✓ Public Key: $NEW_PUBLIC_KEY"
    log_info "✓ Short ID: $NEW_SHORT_ID"

    log_info "创建Xray配置文件..."
    write_config_file "$NEW_UUID" "$NEW_PRIVATE_KEY" "$NEW_SHORT_ID" "$server_name" "$dest"

    if ! /usr/local/bin/xray run -test -config "$CONFIG_FILE"; then
        log_error "配置文件验证失败"
        exit 1
    fi

    log_success "配置文件创建成功"
}

# ============================================
# 配置防火墙
# ============================================
configure_firewall() {
    log_info "配置防火墙规则..."

    if [ "$OS_TYPE" = "alpine" ]; then
        if command -v iptables &>/dev/null; then
            iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
            if command -v ip6tables &>/dev/null; then
                ip6tables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
            fi
            if rc-service iptables status &>/dev/null 2>&1; then
                /etc/init.d/iptables save  2>/dev/null || true
                /etc/init.d/ip6tables save 2>/dev/null || true
            fi
            log_info "iptables规则已配置"
        else
            log_warn "未检测到iptables，跳过防火墙配置"
        fi
    else
        if command -v ufw &>/dev/null; then
            ufw allow 443/tcp 2>/dev/null || true
            ufw --force enable 2>/dev/null || true
            log_info "UFW防火墙已配置"
        elif command -v firewall-cmd &>/dev/null; then
            firewall-cmd --permanent --add-port=443/tcp 2>/dev/null || true
            firewall-cmd --reload 2>/dev/null || true
            log_info "Firewalld已配置"
        else
            log_warn "未检测到防火墙，跳过"
        fi
    fi
}

# ============================================
# 启动服务
# ============================================
start_xray_service() {
    log_info "启动Xray服务..."

    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl daemon-reload
        systemctl enable xray 2>/dev/null || true
        systemctl restart xray
        sleep 3

        if systemctl is-active --quiet xray; then
            log_success "Xray服务启动成功"
        else
            log_error "Xray服务启动失败"
            journalctl -u xray -n 50 --no-pager
            exit 1
        fi
    else
        rc-update add xray default 2>/dev/null || true
        /etc/init.d/xray start
        sleep 3

        if /etc/init.d/xray status 2>/dev/null | grep -q "started"; then
            log_success "Xray服务启动成功"
        else
            log_error "Xray服务启动失败，检查日志..."
            tail -n 50 /var/log/xray/error.log 2>/dev/null || echo "无法读取日志文件"
            /usr/local/bin/xray run -test -config "$CONFIG_FILE" || true
            exit 1
        fi
    fi
}

# ============================================
# 加载现有配置
# ============================================
load_existing_config() {
    log_info "读取现有配置信息..."

    UUID=$(grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
    PRIVATE_KEY=$(grep -o '"privateKey"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
    SHORT_ID=$(grep -o '"shortIds"[[:space:]]*:[[:space:]]*\[[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
    SERVER_NAME=$(grep -o '"serverNames"[[:space:]]*:[[:space:]]*\[[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
    DEST=$(grep -o '"dest"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')

    if [ -f "$BACKUP_FILE" ]; then
        PUBLIC_KEY=$(grep "^Public Key:" "$BACKUP_FILE" | awk '{print $3}')
        NODE_NAME=$(grep "^节点名称:" "$BACKUP_FILE" | cut -d' ' -f2-)
    fi

    # 若备份文件中没有公钥，则实时推导
    if [ -z "$PUBLIC_KEY" ]; then
        PUBLIC_KEY=$(derive_public_key "$PRIVATE_KEY")
    fi
    [ -z "$NODE_NAME" ] && NODE_NAME="Xray-Reality-Existing"

    log_info "✓ 已读取现有配置"
}

# ============================================
# URL编码函数
# ============================================
urlencode() {
    local string="$1"
    local strlen=${#string}
    local encoded="" pos c o

    for (( pos=0; pos<strlen; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * ) printf -v o '%%%02x' "'$c" ;;
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

# ============================================
# 生成连接信息
# ============================================
generate_connection_info() {
    local uuid="$1"
    local private_key="$2"
    local public_key="$3"
    local short_id="$4"
    local node_name="$5"
    local server_name="$6"
    local dest="$7"

    IPV4=$(curl -s -4 --max-time 10 ifconfig.me 2>/dev/null || \
           curl -s -4 --max-time 10 icanhazip.com 2>/dev/null || \
           curl -s -4 --max-time 10 api.ipify.org 2>/dev/null || echo "")
    IPV6=$(curl -s -6 --max-time 10 ifconfig.me 2>/dev/null || \
           curl -s -6 --max-time 10 icanhazip.com 2>/dev/null || echo "")

    if [ -z "$IPV4" ] && [ -z "$IPV6" ]; then
        log_error "无法获取服务器任何IP地址 (IPv4 和 IPv6 均失败)"
        exit 1
    fi

    [ -n "$IPV4" ] && log_info "服务器IPv4: $IPV4" || log_warn "未检测到IPv4地址，将使用纯IPv6模式"
    [ -n "$IPV6" ] && log_info "服务器IPv6: $IPV6"

    ENCODED_NAME=$(urlencode "$node_name")
    ENCODED_NAME_IPV6=$(urlencode "${node_name}-IPv6")

    [ -n "$IPV4" ] && VLESS_IPV4="vless://${uuid}@${IPV4}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${server_name}&fp=firefox&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#${ENCODED_NAME}"

    if [ -n "$IPV6" ]; then
        local ipv6_label
        [ -z "$IPV4" ] && ipv6_label="$ENCODED_NAME" || ipv6_label="$ENCODED_NAME_IPV6"
        VLESS_IPV6="vless://${uuid}@[${IPV6}]:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${server_name}&fp=firefox&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#${ipv6_label}"
    fi

    # 生成 Clash 配置
    cat > /root/clash_config.yaml <<EOF
proxies:
EOF

    if [ -n "$IPV4" ]; then
        cat >> /root/clash_config.yaml <<EOF
  - name: "$node_name"
    type: vless
    server: $IPV4
    port: 443
    uuid: $uuid
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $server_name
    reality-opts:
      public-key: $public_key
      short-id: $short_id
    client-fingerprint: firefox
EOF
    fi

    if [ -n "$IPV6" ]; then
        local clash_name
        [ -z "$IPV4" ] && clash_name="$node_name" || clash_name="${node_name}-IPv6"
        cat >> /root/clash_config.yaml <<EOF
  - name: "$clash_name"
    type: vless
    server: "$IPV6"
    port: 443
    uuid: $uuid
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $server_name
    reality-opts:
      public-key: $public_key
      short-id: $short_id
    client-fingerprint: firefox
EOF
    fi

    echo ""
    echo "============================================"
    log_info "节点配置完成！"
    echo "============================================"
    echo ""
    echo -e "${GREEN}节点信息：${NC}"
    echo "----------------------------------------"
    echo "节点名称: $node_name"
    echo "UUID: $uuid"
    echo "Private Key: $private_key"
    echo "Public Key: $public_key"
    echo "Short ID: $short_id"
    [ -n "$IPV4" ] && echo "服务器IPv4: $IPV4"
    [ -n "$IPV6" ] && echo "服务器IPv6: $IPV6"
    echo "端口: 443 | 传输: TCP | 流控: xtls-rprx-vision"
    echo "TLS: Reality | SNI: $server_name | 目标: $dest"
    echo "客户端指纹: firefox"
    echo "----------------------------------------"
    echo ""

    if [ -n "$IPV4" ]; then
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}VLESS节点连接（IPv4）：${NC}"
        echo -e "${YELLOW}$VLESS_IPV4${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
    fi

    if [ -n "$IPV6" ]; then
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}VLESS节点连接（IPv6）：${NC}"
        echo -e "${YELLOW}$VLESS_IPV6${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
    fi

    MAIN_IP=${IPV4:-$IPV6}

    # 写入备份文件
    cat > "$BACKUP_FILE" <<EOFBACKUP
========================================
Xray VLESS+Reality+Vision 节点信息
脚本版本: $SCRIPT_VERSION
系统类型: $OS_TYPE
配置时间: $(date '+%Y-%m-%d %H:%M:%S %Z')
========================================

节点名称: $node_name

========== 密钥信息 ==========
UUID: $uuid
Private Key: $private_key
Public Key: $public_key
Short ID: $short_id

========== 服务器信息 ==========
EOFBACKUP

    [ -n "$IPV4" ] && echo "服务器IPv4: $IPV4" >> "$BACKUP_FILE"
    [ -n "$IPV6" ] && echo "服务器IPv6: $IPV6" >> "$BACKUP_FILE"

    cat >> "$BACKUP_FILE" <<EOFBACKUP
端口: 443
传输协议: TCP
流控: xtls-rprx-vision

========== Reality 配置 ==========
TLS: Reality
SNI: $server_name
目标地址: $dest
客户端指纹: firefox
EOFBACKUP

    [ -n "$IPV4" ] && cat >> "$BACKUP_FILE" <<EOFBACKUP

========== VLESS URI (IPv4) ==========
$VLESS_IPV4
EOFBACKUP

    [ -n "$IPV6" ] && cat >> "$BACKUP_FILE" <<EOFBACKUP

========== VLESS URI (IPv6) ==========
$VLESS_IPV6
EOFBACKUP

    cat >> "$BACKUP_FILE" <<EOFBACKUP

========== Clash Meta 配置 ==========
配置文件已保存到: /root/clash_config.yaml

========== 客户端配置参数（手动配置用）==========
地址(Address): $MAIN_IP
端口(Port): 443
用户ID(UUID): $uuid
流控(Flow): xtls-rprx-vision
传输协议(Network): tcp
传输层安全(TLS): reality
SNI: $server_name
Fingerprint: firefox
PublicKey: $public_key
ShortId: $short_id
SpiderX: 
Dest: $dest

========== 管理命令 ($OS_TYPE) ==========
$(if [ "$SERVICE_MANAGER" = "systemd" ]; then
    echo "查看状态: systemctl status xray"
    echo "启动/停止/重启: systemctl start|stop|restart xray"
    echo "查看日志: journalctl -u xray -f"
else
    echo "查看状态: /etc/init.d/xray status"
    echo "启动/停止/重启: /etc/init.d/xray start|stop|restart"
    echo "查看日志: tail -f /var/log/xray/error.log"
fi)
测试配置: /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json

========== 故障排查 ==========
1. 检查端口: ss -tlnp | grep 443
2. 测试目标: curl -I https://$server_name
3. 检查防火墙: $([ "$OS_TYPE" = "alpine" ] && echo "iptables -L" || echo "ufw status")
========================================
EOFBACKUP

    log_info "详细配置信息已保存到 $BACKUP_FILE"
    log_info "Clash配置已保存到 /root/clash_config.yaml"
}

# ============================================
# 显示完成摘要
# ============================================
show_completion_summary() {
    local use_existing="$1"

    echo ""
    echo "============================================"
    log_info "系统状态摘要 (版本: ${SCRIPT_VERSION}, 系统: $OS_TYPE)"
    echo "============================================"

    if [ "$use_existing" = false ]; then
        echo "✓ 系统已更新"
        if grep -q '/swapfile' /etc/fstab 2>/dev/null; then
            SWAP_SIZE=$(free -m | grep Swap | awk '{print $2}')
            echo "✓ 已配置 ${SWAP_SIZE}MB 交换空间"
        else
            echo "✓ 容器环境/空间不足，已跳过交换空间"
        fi
        if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
            echo "✓ BBR加速已启用"
        else
            echo "✓ 容器环境不支持BBR，已跳过"
        fi
        echo "✓ Xray 已安装并运行"
        echo "✓ VLESS+Reality+Vision节点已配置"
        echo "✓ 防火墙规则已配置"
    else
        echo "✓ 使用现有配置，Xray 运行中"
    fi
    echo "============================================"

    echo ""
    log_info "实时状态验证："

    BBR_STATUS=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    [ "$BBR_STATUS" = "bbr" ] && echo "✓ BBR: 已启用" || log_warn "⚠ BBR: ${BBR_STATUS:-未知(容器限制)}"

    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        XRAY_STATUS=$(systemctl is-active xray 2>/dev/null || echo "unknown")
        [ "$XRAY_STATUS" = "active" ] && echo "✓ Xray服务: 运行中" || echo "✗ Xray服务: $XRAY_STATUS"
    else
        /etc/init.d/xray status 2>/dev/null | grep -q "started" && echo "✓ Xray服务: 运行中" || echo "✗ Xray服务: 未运行"
    fi

    LISTENING=$(ss -tlnp 2>/dev/null | grep ':443' || netstat -tlnp 2>/dev/null | grep ':443' || echo "")
    [ -n "$LISTENING" ] && echo "✓ 端口443: 正在监听" || log_warn "⚠ 端口443: 未检测到监听"

    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "配置完成！建议步骤："
    echo "1. 复制上方的VLESS URI到客户端"
    echo "2. 或导入 /root/clash_config.yaml 到 Clash"
    echo "3. 连接后访问 https://www.google.com 测试"
    [ "$SERVICE_MANAGER" = "systemd" ] && echo "4. 查看日志: journalctl -u xray -f" || echo "4. 查看日志: tail -f /var/log/xray/error.log"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ============================================
# 卸载Xray
# ============================================
uninstall_xray() {
    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_warn "此操作将完全卸载Xray及其配置"
    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    read -p "确认要卸载吗? (yes/no): " CONFIRM

    if [ "$CONFIRM" != "yes" ]; then
        log_info "已取消卸载"
        show_main_menu
        return
    fi

    log_info "停止Xray服务..."
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl stop xray    2>/dev/null || true
        systemctl disable xray 2>/dev/null || true
    else
        /etc/init.d/xray stop           2>/dev/null || true
        rc-update del xray default      2>/dev/null || true
    fi

    log_info "备份配置文件..."
    mkdir -p "$BACKUP_DIR"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    [ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "$BACKUP_DIR/config_uninstall_${TIMESTAMP}.json"
    [ -f "$BACKUP_FILE" ] && cp "$BACKUP_FILE" "$BACKUP_DIR/links_uninstall_${TIMESTAMP}.txt"

    log_info "卸载Xray..."
    if [ "$OS_TYPE" = "alpine" ]; then
        rm -f /usr/local/bin/xray
        rm -rf /usr/local/etc/xray /etc/init.d/xray /var/log/xray /usr/local/share/xray
        log_success "Xray文件已删除"
    else
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge
    fi

    log_success "Xray已卸载"
    log_info "配置备份在: $BACKUP_DIR/"
    echo ""

    read -p "按回车键返回主菜单..."
    show_main_menu
}

# ============================================
# 脚本入口
# ============================================
show_main_menu
