#!/bin/bash

# ============================================
# Ubuntu Xray VLESS+Reality+Vision 配置脚本
# 版本: v2.2.0 (增强版)
# 更新日期: 2026-01-18
# 新增功能:
# - 支持更新节点信息(UUID/密钥/ShortID)
# - 支持自定义ServerName
# - 保留原有所有功能
# ============================================

SCRIPT_VERSION="v2.2.0-Enhanced"

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${CYAN}[SUCCESS]${NC} $1"
}

# 显示版本信息
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  Xray VLESS+Reality+Vision 配置脚本${NC}"
echo -e "${BLUE}  版本: ${SCRIPT_VERSION}${NC}"
echo -e "${BLUE}  新增: 节点更新 + 自定义ServerName${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# 检查是否为root用户
if [[ $EUID -ne 0 ]]; then
   log_error "此脚本必须以root权限运行"
   exit 1
fi

# ============================================
# 配置文件路径
# ============================================
CONFIG_FILE="/usr/local/etc/xray/config.json"
BACKUP_FILE="/root/xray_vless_links.txt"
BACKUP_DIR="/root/xray_backups"

# ============================================
# 主菜单
# ============================================
show_main_menu() {
    echo ""
    echo -e "${CYAN}=====================================${NC}"
    echo -e "${CYAN}       Xray 配置管理菜单${NC}"
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
        1)
            fresh_install
            ;;
        2)
            update_node_info
            ;;
        3)
            show_current_info
            ;;
        4)
            uninstall_xray
            ;;
        5)
            log_info "退出脚本"
            exit 0
            ;;
        *)
            log_error "无效选项"
            show_main_menu
            ;;
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
    
    UUID=$(grep -oP '"id":\s*"\K[^"]+' "$CONFIG_FILE" | head -1)
    PRIVATE_KEY=$(grep -oP '"privateKey":\s*"\K[^"]+' "$CONFIG_FILE" | head -1)
    SHORT_ID=$(grep -oP '"shortIds":\s*\[\s*"\K[^"]+' "$CONFIG_FILE" | head -1)
    SERVER_NAME=$(grep -oP '"serverNames":\s*\[\s*"\K[^"]+' "$CONFIG_FILE" | head -1)
    DEST=$(grep -oP '"dest":\s*"\K[^"]+' "$CONFIG_FILE" | head -1)
    
    # 生成公钥
    KEY_OUTPUT=$(/usr/local/bin/xray x25519 -i "$PRIVATE_KEY" 2>&1)
    PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep -E "^(PublicKey|Password):" | awk '{print $2}' | tr -d ' \n\r')
    
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
        grep "VLESS URI (IPv4)" -A 1 "$BACKUP_FILE" | tail -1
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
    
    # 备份当前配置
    mkdir -p "$BACKUP_DIR"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    cp "$CONFIG_FILE" "$BACKUP_DIR/config_${TIMESTAMP}.json"
    [ -f "$BACKUP_FILE" ] && cp "$BACKUP_FILE" "$BACKUP_DIR/links_${TIMESTAMP}.txt"
    log_info "已备份当前配置到: $BACKUP_DIR/"
    
    # 读取当前ServerName
    CURRENT_SERVER_NAME=$(grep -oP '"serverNames":\s*\[\s*"\K[^"]+' "$CONFIG_FILE" | head -1)
    CURRENT_DEST=$(grep -oP '"dest":\s*"\K[^"]+' "$CONFIG_FILE" | head -1)
    
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
    
    # 生成新的密钥信息
    log_info "生成新的节点凭证..."
    
    # 生成新UUID
    NEW_UUID=$(cat /proc/sys/kernel/random/uuid)
    
    # 生成新密钥对
    KEY_OUTPUT=$(/usr/local/bin/xray x25519 2>&1)
    NEW_PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "^PrivateKey:" | cut -d' ' -f2 | tr -d ' \n\r')
    NEW_PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep -E "^(PublicKey|Password):" | awk '{print $2}' | tr -d ' \n\r')
    
    # 验证密钥
    if [ -z "$NEW_PRIVATE_KEY" ] || [ -z "$NEW_PUBLIC_KEY" ]; then
        log_error "密钥生成失败"
        exit 1
    fi
    
    # 生成新ShortID
    NEW_SHORT_ID=$(openssl rand -hex 8)
    
    # 询问节点名称
    read -p "请输入新节点名称（回车使用默认）: " NODE_NAME
    if [ -z "$NODE_NAME" ]; then
        NODE_NAME="Xray-Reality-Updated-$(date +%Y%m%d)"
    fi
    
    log_info "✓ 新UUID: $NEW_UUID"
    log_info "✓ 新Private Key: $NEW_PRIVATE_KEY"
    log_info "✓ 新Public Key: $NEW_PUBLIC_KEY"
    log_info "✓ 新Short ID: $NEW_SHORT_ID"
    log_info "✓ ServerName: $SERVER_NAME"
    
    # 更新配置文件
    log_info "正在更新配置文件..."
    
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
            "id": "$NEW_UUID",
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
          "dest": "$DEST",
          "serverNames": [
            "$SERVER_NAME"
          ],
          "privateKey": "$NEW_PRIVATE_KEY",
          "shortIds": [
            "$NEW_SHORT_ID"
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
    
    # 验证配置
    if ! /usr/local/bin/xray run -test -config "$CONFIG_FILE"; then
        log_error "新配置验证失败，正在恢复备份..."
        cp "$BACKUP_DIR/config_${TIMESTAMP}.json" "$CONFIG_FILE"
        exit 1
    fi
    
    log_success "配置文件更新成功"
    
    # 重启服务
    log_info "重启Xray服务..."
    systemctl restart xray
    sleep 2
    
    if systemctl is-active --quiet xray; then
        log_success "Xray服务重启成功"
    else
        log_error "Xray服务启动失败"
        journalctl -u xray -n 30 --no-pager
        exit 1
    fi
    
    # 生成新的连接信息
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
# 全新安装
# ============================================
fresh_install() {
    # 检测现有配置
    if [ -f "$CONFIG_FILE" ] && [ -f "$BACKUP_FILE" ]; then
        echo ""
        log_warn "检测到现有Xray配置！"
        echo ""
        echo "现有配置信息："
        echo "----------------------------------------"
        
        EXISTING_UUID=$(grep -oP '"id":\s*"\K[^"]+' "$CONFIG_FILE" | head -1)
        EXISTING_PRIVATE=$(grep -oP '"privateKey":\s*"\K[^"]+' "$CONFIG_FILE" | head -1)
        EXISTING_SHORT=$(grep -oP '"shortIds":\s*\[\s*"\K[^"]+' "$CONFIG_FILE" | head -1)
        
        [ -n "$EXISTING_UUID" ] && echo "UUID: $EXISTING_UUID"
        [ -n "$EXISTING_PRIVATE" ] && echo "Private Key: ${EXISTING_PRIVATE:0:20}..."
        [ -n "$EXISTING_SHORT" ] && echo "Short ID: $EXISTING_SHORT"
        
        CONFIG_TIME=$(stat -c %y "$CONFIG_FILE" 2>/dev/null | cut -d'.' -f1)
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
            1)
                USE_EXISTING=true
                ;;
            2)
                USE_EXISTING=false
                mkdir -p "$BACKUP_DIR"
                TIMESTAMP=$(date +%Y%m%d_%H%M%S)
                cp "$CONFIG_FILE" "$BACKUP_DIR/config_${TIMESTAMP}.json"
                [ -f "$BACKUP_FILE" ] && cp "$BACKUP_FILE" "$BACKUP_DIR/links_${TIMESTAMP}.txt"
                log_info "旧配置已备份到: $BACKUP_DIR/"
                ;;
            3)
                show_main_menu
                return
                ;;
            *)
                log_error "无效选项"
                fresh_install
                return
                ;;
        esac
    else
        log_info "未检测到现有配置，将创建新配置"
        USE_EXISTING=false
    fi
    
    # 询问自定义配置
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
    
    # 系统配置和安装
    if [ "$USE_EXISTING" = false ]; then
        perform_system_setup
        install_xray
        generate_keys_and_config "$NODE_NAME" "$SERVER_NAME" "$DEST"
        configure_firewall
        start_xray_service
    else
        load_existing_config
    fi
    
    # 生成连接信息
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
# 系统设置
# ============================================
perform_system_setup() {
    log_info "开始配置系统..."
    
    log_info "更新系统软件包..."
    apt update && apt upgrade -y
    apt autoremove -y
    apt autoclean -y
    
    log_info "清除系统垃圾..."
    apt clean
    journalctl --vacuum-time=3d
    rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
    
    log_info "配置2GB交换空间..."
    if [ -f /swapfile ]; then
        swapoff /swapfile
        rm -f /swapfile
    fi
    
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    
    log_info "启用BBR TCP加速..."
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    sysctl -p
    
    log_info "安装必要依赖..."
    apt install -y curl wget unzip jq qrencode
}

# ============================================
# 安装Xray
# ============================================
install_xray() {
    log_info "安装Xray-core..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

# ============================================
# 生成密钥和配置
# ============================================
generate_keys_and_config() {
    local node_name="$1"
    local server_name="$2"
    local dest="$3"
    
    log_info "生成密钥对和UUID..."
    
    NEW_UUID=$(cat /proc/sys/kernel/random/uuid)
    
    KEY_OUTPUT=$(/usr/local/bin/xray x25519 2>&1)
    NEW_PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "^PrivateKey:" | cut -d' ' -f2 | tr -d ' \n\r')
    NEW_PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep -E "^(PublicKey|Password):" | awk '{print $2}' | tr -d ' \n\r')
    
    if [ -z "$NEW_PRIVATE_KEY" ] || [ -z "$NEW_PUBLIC_KEY" ]; then
        log_error "密钥生成失败"
        exit 1
    fi
    
    NEW_SHORT_ID=$(openssl rand -hex 8)
    
    log_info "✓ UUID: $NEW_UUID"
    log_info "✓ Private Key: $NEW_PRIVATE_KEY"
    log_info "✓ Public Key: $NEW_PUBLIC_KEY"
    log_info "✓ Short ID: $NEW_SHORT_ID"
    
    log_info "创建Xray配置文件..."
    
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
            "id": "$NEW_UUID",
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
          "privateKey": "$NEW_PRIVATE_KEY",
          "shortIds": [
            "$NEW_SHORT_ID"
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
    if command -v ufw &> /dev/null; then
        ufw allow 443/tcp
        ufw --force enable
        log_info "UFW防火墙已配置"
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=443/tcp
        firewall-cmd --reload
        log_info "Firewalld已配置"
    else
        log_warn "未检测到防火墙，跳过"
    fi
}

# ============================================
# 启动服务
# ============================================
start_xray_service() {
    log_info "启动Xray服务..."
    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray
    sleep 3
    
    if systemctl is-active --quiet xray; then
        log_success "Xray服务启动成功"
    else
        log_error "Xray服务启动失败"
        journalctl -u xray -n 50 --no-pager
        exit 1
    fi
}

# ============================================
# 加载现有配置
# ============================================
load_existing_config() {
    log_info "读取现有配置信息..."
    
    UUID=$(grep -oP '"id":\s*"\K[^"]+' "$CONFIG_FILE" | head -1)
    PRIVATE_KEY=$(grep -oP '"privateKey":\s*"\K[^"]+' "$CONFIG_FILE" | head -1)
    SHORT_ID=$(grep -oP '"shortIds":\s*\[\s*"\K[^"]+' "$CONFIG_FILE" | head -1)
    SERVER_NAME=$(grep -oP '"serverNames":\s*\[\s*"\K[^"]+' "$CONFIG_FILE" | head -1)
    DEST=$(grep -oP '"dest":\s*"\K[^"]+' "$CONFIG_FILE" | head -1)
    
    if [ -f "$BACKUP_FILE" ]; then
        PUBLIC_KEY=$(grep "^Public Key:" "$BACKUP_FILE" | awk '{print $3}')
        NODE_NAME=$(grep "^节点名称:" "$BACKUP_FILE" | cut -d' ' -f2-)
        [ -z "$NODE_NAME" ] && NODE_NAME="Xray-Reality-Existing"
    else
        KEY_OUTPUT=$(/usr/local/bin/xray x25519 -i "$PRIVATE_KEY" 2>&1)
        PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep -E "^(PublicKey|Password):" | awk '{print $2}' | tr -d ' \n\r')
        NODE_NAME="Xray-Reality-Existing"
    fi
    
    log_info "✓ 已读取现有配置"
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
    
    IPV4=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com || curl -s -4 api.ipify.org)
    IPV6=$(curl -s -6 ifconfig.me 2>/dev/null || curl -s -6 icanhazip.com 2>/dev/null || echo "")
    
    log_info "服务器IPv4: $IPV4"
    [ -n "$IPV6" ] && log_info "服务器IPv6: $IPV6"
    
    # URL编码
    urlencode() {
        local string="$1"
        echo -n "$string" | jq -sRr @uri
    }
    
    ENCODED_NAME=$(urlencode "$node_name")
    ENCODED_NAME_IPV6=$(urlencode "${node_name}-IPv6")
    
    VLESS_IPV4="vless://${uuid}@${IPV4}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${server_name}&fp=firefox&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#${ENCODED_NAME}"
    
    if [ -n "$IPV6" ]; then
        VLESS_IPV6="vless://${uuid}@[${IPV6}]:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${server_name}&fp=firefox&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#${ENCODED_NAME_IPV6}"
    fi
    
    # 生成Clash配置
    cat > /root/clash_config.yaml <<EOF
proxies:
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
    
    if [ -n "$IPV6" ]; then
        cat >> /root/clash_config.yaml <<EOF
  - name: "${node_name}-IPv6"
    type: vless
    server: $IPV6
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
    
    # 显示连接信息
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
    echo "服务器IPv4: $IPV4"
    [ -n "$IPV6" ] && echo "服务器IPv6: $IPV6"
    echo "端口: 443"
    echo "传输协议: TCP"
    echo "流控: xtls-rprx-vision"
    echo "TLS: Reality"
    echo "SNI: $server_name"
    echo "目标地址: $dest"
    echo "客户端指纹: firefox"
    echo "----------------------------------------"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}VLESS节点连接（IPv4）：${NC}"
    echo -e "${YELLOW}$VLESS_IPV4${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if [ -n "$IPV6" ]; then
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}VLESS节点连接（IPv6）：${NC}"
        echo -e "${YELLOW}$VLESS_IPV6${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
    fi
    
    # 生成二维码
    if command -v qrencode &> /dev/null; then
        echo -e "${GREEN}IPv4节点二维码：${NC}"
        qrencode -t ANSIUTF8 "$VLESS_IPV4"
        echo ""
    fi
    
    # 保存到文件
    cat > "$BACKUP_FILE" <<EOFBACKUP
========================================
Xray VLESS+Reality+Vision 节点信息
脚本版本: $SCRIPT_VERSION
配置时间: $(date '+%Y-%m-%d %H:%M:%S %Z')
========================================

节点名称: $node_name

========== 密钥信息 ==========
UUID: $uuid
Private Key: $private_key
Public Key: $public_key
Short ID: $short_id

========== 服务器信息 ==========
服务器IPv4: $IPV4
$([ -n "$IPV6" ] && echo "服务器IPv6: $IPV6")
端口: 443
传输协议: TCP
流控: xtls-rprx-vision

========== Reality 配置 ==========
TLS: Reality
SNI: $server_name
目标地址: $dest
客户端指纹: firefox

========== VLESS URI (IPv4) ==========
$VLESS_IPV4

$([ -n "$IPV6" ] && echo "========== VLESS URI (IPv6) ==========" && echo "$VLESS_IPV6")

========== Clash Meta 配置 ==========
配置文件已保存到: /root/clash_config.yaml
可直接复制 clash_config.yaml 的内容到 Clash Meta/Party 使用

========== 客户端配置参数（手动配置用）==========
地址(Address): $IPV4
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

========== 管理命令 ==========
查看Xray状态: systemctl status xray
启动Xray: systemctl start xray
停止Xray: systemctl stop xray
重启Xray: systemctl restart xray
查看实时日志: journalctl -u xray -f
查看最近日志: journalctl -u xray -n 50
测试配置: /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
配置文件位置: /usr/local/etc/xray/config.json

========== BBR 检查命令 ==========
检查BBR状态: sysctl net.ipv4.tcp_congestion_control
查看可用算法: sysctl net.ipv4.tcp_available_congestion_control
查看连接统计: ss -tin

========== 性能测试建议 ==========
1. 使用客户端连接后访问: https://www.google.com
2. 测试速度: https://fast.com 或 https://speedtest.net
3. 检查IP: https://ip.sb 或 https://ipinfo.io

========== 故障排查 ==========
1. 检查服务状态: systemctl status xray
2. 查看详细日志: journalctl -u xray -n 100
3. 验证配置文件: /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
4. 检查端口占用: netstat -tlnp | grep 443
5. 测试目标站点: curl -I https://$server_name
6. 检查防火墙: ufw status 或 iptables -L

========== 安全建议 ==========
1. 定期更新系统: apt update && apt upgrade
2. 定期更新Xray: bash -c "\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
3. 定期更新节点信息（建议每3-6个月）
4. 监控服务状态: systemctl status xray
5. 备份配置文件: cp /usr/local/etc/xray/config.json /root/config.json.bak

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
    if [ "$use_existing" = true ]; then
        log_info "系统状态 (版本: ${SCRIPT_VERSION})："
    else
        log_info "系统优化完成摘要 (版本: ${SCRIPT_VERSION})："
    fi
    echo "============================================"
    
    if [ "$use_existing" = false ]; then
        echo "✓ 系统已更新到最新"
        echo "✓ 系统垃圾已清理"
        echo "✓ 已配置2GB交换空间"
        echo "✓ BBR加速已启用"
        echo "✓ Xray 已安装并运行"
        echo "✓ VLESS+Reality+Vision节点已配置"
        echo "✓ 防火墙规则已配置"
    else
        echo "✓ 使用现有配置"
        echo "✓ Xray 运行中"
        echo "✓ 配置信息已更新"
    fi
    echo "============================================"
    
    echo ""
    log_info "系统状态验证："
    BBR_STATUS=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [ "$BBR_STATUS" = "bbr" ]; then
        echo "✓ BBR状态: 已启用"
    else
        log_warn "⚠ BBR状态: $BBR_STATUS"
    fi
    
    XRAY_STATUS=$(systemctl is-active xray)
    if [ "$XRAY_STATUS" = "active" ]; then
        echo "✓ Xray服务: 运行中"
    else
        echo "✗ Xray服务: $XRAY_STATUS"
    fi
    
    LISTENING=$(ss -tlnp | grep :443 | grep xray)
    if [ -n "$LISTENING" ]; then
        echo "✓ 端口443: 正在监听"
    else
        log_warn "⚠ 端口443: 未检测到监听"
    fi
    
    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "配置完成！建议步骤："
    echo "1. 复制上方的VLESS URI到客户端"
    echo "2. 或使用 /root/clash_config.yaml 导入Clash"
    echo "3. 连接后访问 https://www.google.com 测试"
    echo "4. 查看日志: journalctl -u xray -f"
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
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true
    
    log_info "备份配置文件..."
    mkdir -p "$BACKUP_DIR"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    [ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "$BACKUP_DIR/config_uninstall_${TIMESTAMP}.json"
    [ -f "$BACKUP_FILE" ] && cp "$BACKUP_FILE" "$BACKUP_DIR/links_uninstall_${TIMESTAMP}.txt"
    
    log_info "卸载Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge
    
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
