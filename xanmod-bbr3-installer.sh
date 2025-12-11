#!/usr/bin/env bash
# xanmod-bbr3-installer.sh
# One-shot installer + uninstaller for XanMod kernel + BBR3 support
# Script version:
SCRIPT_VERSION="Ver 3"

set -euo pipefail
IFS=$'\n\t'

# ----------------- Colors -----------------
RED="$(printf '\033[31m')"
GREEN="$(printf '\033[32m')"
YELLOW="$(printf '\033[33m')"
BLUE="$(printf '\033[34m')"
BOLD="$(printf '\033[1m')"
RESET="$(printf '\033[0m')"

info(){ printf "%b\n" "${BLUE}${1}${RESET}"; }
ok(){ printf "%b\n" "${GREEN}${1}${RESET}"; }
warn(){ printf "%b\n" "${YELLOW}${1}${RESET}"; }
err(){ printf "%b\n" "${RED}${1}${RESET}"; }

# ----------------- Globals -----------------
WORKDIR="/var/tmp/xanmod-installer-$$"
BACKUPDIR="/var/tmp/xanmod-backup-$$"
LOGFILE="/var/log/xanmod-installer-$$.log"
XANMOD_LIST="/etc/apt/sources.list.d/xanmod.list"
XANMOD_GPG="/etc/apt/trusted.gpg.d/xanmod.gpg"
SYSCTL_CONF="/etc/sysctl.d/99-xanmod-bbr.conf"

mkdir -p "$WORKDIR" "$BACKUPDIR"
exec > >(tee -a "$LOGFILE") 2>&1

# ----------------- Helpers -----------------
die(){ err "FATAL: $*"; exit 1; }
run(){ echo "+ $*"; eval "$*"; }
command_exists(){ command -v "$1" >/dev/null 2>&1; }

# ----------------- Detect system -----------------
detect_distro(){
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_ID=${ID,,}
    DISTRO_NAME=$NAME
  else
    die "无法识别发行版 (no /etc/os-release)"
  fi
  ARCH=$(uname -m)
  KERNEL_UNAME=$(uname -r)
}

# ----------------- Status display -----------------
gather_status(){
  detect_distro
  CURRENT_KERNEL="$KERNEL_UNAME"
  IS_XANMOD="No"
  if echo "$CURRENT_KERNEL" | grep -qi xanmod; then
    IS_XANMOD="Yes"
  elif [ -f "$XANMOD_LIST" ]; then
    IS_XANMOD="Repo"
  elif dpkg -l 2>/dev/null | grep -qi xanmod; then
    IS_XANMOD="Yes"
  fi

  if command_exists sysctl; then
    TCP_AVAILABLE=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    TCP_CURRENT=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
  else
    TCP_AVAILABLE=""
    TCP_CURRENT=""
  fi

  QDISC_CURRENT=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
  QDISC_AVAILABLE=$(find /lib/modules/$(uname -r) -maxdepth 3 -type f -name "sch_*" -printf "%f\n" 2>/dev/null | sed 's/^sch_//' | sort -u | xargs || true)

  BBR3_LOADED="No"
  BBR_VERSION_DISPLAY="Unknown"
  if lsmod | grep -qi 'tcp_bbr3'; then
    BBR3_LOADED="Yes"
    BBR_VERSION_DISPLAY="v3"
  elif echo "$TCP_AVAILABLE" | tr ' ' '\n' | grep -q "^bbr3$"; then
    BBR3_LOADED="Available"
    BBR_VERSION_DISPLAY="v3"
  elif echo "$TCP_AVAILABLE" | tr ' ' '\n' | grep -q "^bbr$"; then
    if command_exists modinfo && modinfo tcp_bbr3 >/dev/null 2>&1; then
      BBR3_LOADED="Yes"
      BBR_VERSION_DISPLAY="v3"
    else
      BBR_VERSION_DISPLAY="v1/unknown"
    fi
  fi

  CAKE_PRESENT="No"
  if lsmod | grep -qi 'sch_cake'; then
    CAKE_PRESENT="Yes"
  elif find /lib/modules/$(uname -r) -type f -name 'sch_cake.ko*' | grep -q .; then
    CAKE_PRESENT="Available"
  fi

  IFACES_RAW=$(ip -o link show | awk -F': ' '{print $2}')
  # Filter plausible physical interfaces
  IFACES=$(echo "$IFACES_RAW" | grep -Ev '^(lo|docker|veth|br-|virbr|tun|tap)' || true)
}

print_status(){
  gather_status
  echo
  printf "%b\n" "${BOLD}======== 当前系统状态 ========${RESET}"
  printf "脚本版本: %s\n" "$SCRIPT_VERSION"
  printf "系统: %s (%s)\n" "$DISTRO_NAME" "$DISTRO_ID"
  printf "架构: %s\n" "$ARCH"
  printf "当前内核: %s\n" "$CURRENT_KERNEL"
  printf "是否 XanMod 内核: %s\n" "$IS_XANMOD"
  printf "拥塞控制 (当前): %s\n" "${TCP_CURRENT:-N/A}"
  printf "拥塞控制 (可用): %s\n" "${TCP_AVAILABLE:-N/A}"
  printf "队列调度 (default_qdisc): %s\n" "${QDISC_CURRENT:-N/A}"
  printf "可用 qdisc 模块: %s\n" "${QDISC_AVAILABLE:-N/A}"
  printf "BBR3 模块状态: %s\n" "${BBR3_LOADED}"
  printf "BBR 版本 (判定): %s\n" "${BBR_VERSION_DISPLAY}"
  printf "CAKE 状态: %s\n" "${CAKE_PRESENT}"
  printf "检测到网络接口: %s\n" "${IFACES:-(none)}"
  printf "%b\n" "${BOLD}===============================${RESET}"
  echo
}

# ----------------- Backup pre-install state -----------------
backup_preinstall(){
  info "准备备份当前系统状态到：$BACKUPDIR"
  mkdir -p "$BACKUPDIR"
  echo "date: $(date -Iseconds)" > "$BACKUPDIR/metadata.txt"
  echo "distro: $DISTRO_ID" >> "$BACKUPDIR/metadata.txt"
  echo "arch: $ARCH" >> "$BACKUPDIR/metadata.txt"
  echo "current_kernel: $CURRENT_KERNEL" >> "$BACKUPDIR/metadata.txt"
  if command_exists dpkg; then
    dpkg -l > "$BACKUPDIR/dpkg-list.txt" || true
  elif command_exists rpm; then
    rpm -qa > "$BACKUPDIR/rpm-list.txt" || true
  fi
  mkdir -p "$BACKUPDIR/boot-snapshot"
  find /boot -maxdepth 1 -type f -print0 | xargs -0 -I{} cp -av "{}" "$BACKUPDIR/boot-snapshot/" || true
  cp -av /etc/default/grub "$BACKUPDIR/" 2>/dev/null || true
  if command_exists grub-mkconfig; then
    grub-mkconfig -o "$BACKUPDIR/grub.cfg.backup" 2>/dev/null || true
  fi
  ok "备份已保存到 $BACKUPDIR （回滚时保留此目录）"
}

# ----------------- XanMod repo & install -----------------
add_xanmod_repo_and_key(){
  info "正在添加 XanMod 官方仓库与 GPG 公钥..."
  case "$DISTRO_ID" in
    ubuntu|debian)
      echo "deb http://deb.xanmod.org releases main" | tee "$XANMOD_LIST" >/dev/null
      if command_exists curl; then
        curl -fsSL https://dl.xanmod.org/gpg.key -o "$WORKDIR/xanmod.gpg" || die "无法下载 XanMod GPG key"
      elif command_exists wget; then
        wget -qO "$WORKDIR/xanmod.gpg" https://dl.xanmod.org/gpg.key || die "无法下载 XanMod GPG key"
      else
        die "系统没有 curl 或 wget，无法获取 XanMod GPG key"
      fi
      mkdir -p /etc/apt/trusted.gpg.d
      if command_exists gpg; then
        gpg --dearmor "$WORKDIR/xanmod.gpg" 2>/dev/null | tee "$XANMOD_GPG" >/dev/null || cp -v "$WORKDIR/xanmod.gpg" "$XANMOD_GPG"
      else
        cp -v "$WORKDIR/xanmod.gpg" "$XANMOD_GPG"
      fi
      run "apt-get update -y"
      ;;
    *)
      die "目前仅支持 Debian/Ubuntu 系列（自动添加 XanMod 仓库）"
      ;;
  esac
  ok "XanMod 仓库添加完成。"
}

install_xanmod_kernel(){
  info "准备安装 XanMod 内核（stable/release）"
  PKG="linux-xanmod"
  if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    warn "检测到 ARM 架构 ($ARCH)，请确认 XanMod 是否提供对应包。"
  fi
  read -r -p "$(printf '%b' "${YELLOW}将安装包: ${PKG}。继续吗？[y/N]: ${RESET}")" ans
  ans=${ans:-n}
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    warn "用户取消安装。"
    return 1
  fi
  backup_preinstall
  run "apt-get install -y ${PKG} || apt-get -f install -y"
  ok "XanMod 内核安装命令已执行。"
  run "update-grub || true"
  ok "已更新 grub 配置。请重启系统以切换内核（菜单有重启选项）。"
}

# ----------------- Apply sysctl and qdisc -----------------
select_interface(){
  gather_status
  # build array
  mapfile -t IF_ARR < <(echo "$IFACES" | tr ' ' '\n' | sed '/^$/d')
  if [ ${#IF_ARR[@]} -eq 0 ]; then
    die "未检测到可用网络接口，请手动输入接口名（如 eth0）"
  elif [ ${#IF_ARR[@]} -eq 1 ]; then
    echo "自动选择接口: ${IF_ARR[0]}"
    SELECT_IF="${IF_ARR[0]}"
  else
    echo "检测到多个接口，请选择接口（按编号）:"
    for i in "${!IF_ARR[@]}"; do
      printf "%2d) %s\n" $((i+1)) "${IF_ARR[$i]}"
    done
    read -r -p "$(printf '%b' "${YELLOW}输入编号 (回车选择 1): ${RESET}")" ifsel
    ifsel=${ifsel:-1}
    if ! [[ "$ifsel" =~ ^[0-9]+$ ]] || [ "$ifsel" -lt 1 ] || [ "$ifsel" -gt "${#IF_ARR[@]}" ]; then
      warn "输入无效，选择第 1 个接口"
      ifsel=1
    fi
    SELECT_IF="${IF_ARR[$((ifsel-1))]}"
  fi
  ok "将对接口 [$SELECT_IF] 应用 qdisc"
}

apply_qdisc_and_sysctl(){
  local cc="$1"
  local qdisc="$2"
  local iface="$3"
  local cake_bw="$4"  # may be empty
  info "设置：拥塞控制 = $cc，队列调度 = $qdisc，接口 = $iface"
  cat > "$SYSCTL_CONF" <<EOF
# XanMod + BBR tuning added by xanmod-bbr3-installer (version $SCRIPT_VERSION)
net.core.default_qdisc = $qdisc
net.ipv4.tcp_congestion_control = $cc
EOF
  run "sysctl --system || true"

  if [[ "$cc" == "bbr3" ]]; then
    if modprobe tcp_bbr3 2>/dev/null; then
      ok "tcp_bbr3 模块加载成功"
    else
      warn "tcp_bbr3 模块加载失败（可能需要支持 bbr3 的内核并重启）"
    fi
  elif [[ "$cc" == "bbr" ]]; then
    modprobe tcp_bbr 2>/dev/null || true
  fi

  if ! command_exists tc; then
    warn "'tc' 未安装，尝试安装 iproute2..."
    if command_exists apt-get; then
      run "apt-get update -y && apt-get install -y iproute2 || true"
    fi
  fi

  # apply qdisc
  if [[ "$qdisc" == "cake" ]]; then
    if [ -n "$cake_bw" ]; then
      # apply same bandwidth for egress + ingress (用户选择 B：同数值)
      ok "将为接口 $iface 应用 CAKE 带宽模板: ${cake_bw}mbit (同时作为上/下行)"
      # remove existing
      run "tc qdisc del dev $iface root 2>/dev/null || true"
      run "tc qdisc replace dev $iface root cake bandwidth ${cake_bw}mbit || { warn '在 root 上应用 cake 失败'; }"
      # Try ingress (may fail on some kernels) — attempt and warn if fails
      run "tc qdisc del dev $iface ingress 2>/dev/null || true"
      if tc qdisc replace dev "$iface" ingress cake bandwidth ${cake_bw}mbit 2>/dev/null; then
        ok "已在 ingress 应用 cake bandwidth ${cake_bw}mbit"
      else
        warn "在 ingress 应用 cake 失败（内核/平台可能不支持直接在 ingress 使用 cake），已在 egress(root) 应用。"
      fi
    else
      # no bandwidth provided, try generic
      run "tc qdisc replace dev $iface root cake || true"
      warn "未提供 bandwidth，已在 root 应用 cake（无带宽限制）"
    fi
  else
    # generic qdisc apply (replace)
    run "tc qdisc replace dev $iface root $qdisc || { warn '应用 qdisc 失败'; }"
  fi

  ok "尝试应用 qdisc 完成（部分操作可能需重启或内核模块支持）。"
}

# ----------------- Uninstall XanMod (conservative) -----------------
uninstall_xanmod(){
  info "开始卸载 XanMod（保守模式）"
  PX=$(dpkg -l 2>/dev/null | awk '/xanmod/ {print $2}' || true)
  if [ -z "$PX" ]; then
    warn "未检测到已安装的 XanMod 包（按包名判断）。将尝试移除 linux-xanmod 包名（若存在）"
    PX="linux-xanmod"
  fi
  printf "%s\n" "检测到以下可能的 XanMod 包：" 
  printf "%s\n" "$PX"
  read -r -p "$(printf '%b' "${YELLOW}确认移除这些包？[y/N]: ${RESET}")" ans
  ans=${ans:-n}
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    warn "用户取消卸载。"
    return 1
  fi
  run "apt-get remove -y ${PX} || true"
  run "apt-get autoremove -y || true"
  if [ -f "$XANMOD_LIST" ]; then
    rm -f "$XANMOD_LIST"
    ok "已移除 XanMod 源文件：$XANMOD_LIST"
  fi
  if [ -f "$XANMOD_GPG" ]; then
    rm -f "$XANMOD_GPG"
    ok "已移除 XanMod GPG key: $XANMOD_GPG"
  fi
  run "apt-get update -y || true"
  run "update-grub || true"
  ok "卸载完成。请检查 /boot 并在必要时重启。备份目录：$BACKUPDIR"
}

# ----------------- Interactive chooser (with CAKE bandwidth same-value) -----------------
choose_congestion_and_qdisc(){
  gather_status
  echo
  printf "%b\n" "${BOLD}请选择要设置的拥塞控制算法 (congestion control):${RESET}"
  local options=()
  if [ -n "$TCP_AVAILABLE" ]; then
    IFS=' '; for x in $TCP_AVAILABLE; do options+=("$x"); done
  else
    options=(bbr bbr2 bbr3 cubic reno)
  fi
  # unique
  local seen=(); local uniq=()
  for opt in "${options[@]}"; do
    if [[ ! " ${seen[*]} " =~ " ${opt} " ]]; then uniq+=("$opt"); seen+=("$opt"); fi
  done
  options=("${uniq[@]}")

  local i=1
  for opt in "${options[@]}"; do printf "%2d) %s\n" "$i" "$opt"; i=$((i+1)); done
  read -r -p "$(printf '%b' "${YELLOW}请输入编号 (回车保持当前: ${TCP_CURRENT:-none}): ${RESET}")" sel
  if [ -z "$sel" ]; then
    CC="${TCP_CURRENT:-bbr}"
  else
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#options[@]}" ]; then
      warn "输入无效，使用当前值或默认 bbr"
      CC="${TCP_CURRENT:-bbr}"
    else
      CC="${options[$((sel-1))]}"
    fi
  fi

  echo
  printf "%b\n" "${BOLD}请选择队列调度算法 (qdisc):${RESET}"
  local qopts=()
  if [ -n "$QDISC_AVAILABLE" ]; then
    IFS=' '; for x in $QDISC_AVAILABLE; do qopts+=("$x"); done
  else
    qopts=(cake fq fq_codel pfifo_fast)
  fi
  i=1
  for q in "${qopts[@]}"; do printf "%2d) %s\n" "$i" "$q"; i=$((i+1)); done
  read -r -p "$(printf '%b' "${YELLOW}请输入编号 (回车保持当前: ${QDISC_CURRENT:-fq}): ${RESET}")" qsel
  if [ -z "$qsel" ]; then
    QD="${QDISC_CURRENT:-fq}"
  else
    if ! [[ "$qsel" =~ ^[0-9]+$ ]] || [ "$qsel" -lt 1 ] || [ "$qsel" -gt "${#qopts[@]}" ]; then
      warn "输入无效，使用当前 qdisc 或默认 fq"
      QD="${QDISC_CURRENT:-fq}"
    else
      QD="${qopts[$((qsel-1))]}"
    fi
  fi

  # if cake chosen, ask for single bandwidth number (same for up/down)
  CAKE_BW=""
  if [[ "$QD" == "cake" ]]; then
    echo
    warn "你选择了 CAKE。根据你的设置 (选项 B)，脚本将使用 单一带宽数值 同时作为 上行/下行。"
    while true; do
      read -r -p "$(printf '%b' "${YELLOW}请输入带宽值 (Mbps, 仅数字，例如 100) 或回车取消: ${RESET}")" bw
      bw=${bw:-}
      if [ -z "$bw" ]; then
        warn "未输入带宽值，将以默认方式应用 cake（无 bandwidth 限制）"
        CAKE_BW=""
        break
      fi
      # validate integer or decimal
      if echo "$bw" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then
        # convert to integer if decimal (tc accepts decimals)
        CAKE_BW="$bw"
        ok "将使用带宽: ${CAKE_BW} Mbps（同时作为上/下行）"
        break
      else
        warn "输入无效，请输入正数（例如 100）"
      fi
    done
  fi

  select_interface
  # apply
  apply_qdisc_and_sysctl "$CC" "$QD" "$SELECT_IF" "$CAKE_BW"
  ok "已尝试应用拥塞算法 $CC 与 qdisc $QD（部分更改可能在重启或模块加载后生效）。"
}

# ----------------- Menu -----------------
main_menu(){
  while true; do
    print_status
    cat <<EOF
$(printf '%b' "${BOLD}请选择操作:${RESET}")
 1) 安装 XanMod 内核（添加官方 repo 并安装 linux-xanmod）
 2) 选择/切换 拥塞控制算法 (CC) 与 qdisc（交互式；CAKE 使用单一带宽值作为上下行）
 3) 卸载 XanMod（保守模式）
 4) 备份当前系统状态（手动触发）
 5) 显示 /boot 内容 & 已安装内核包
 6) 直接重启系统
 0) 退出
EOF
    read -r -p "$(printf '%b' "${YELLOW}输入编号: ${RESET}")" choice
    choice=${choice:-0}
    case "$choice" in
      1)
        add_xanmod_repo_and_key
        install_xanmod_kernel || true
        read -r -p "$(printf '%b' "${YELLOW}是否现在重启以使用新内核？[y/N]: ${RESET}")" rans
        rans=${rans:-n}
        if [[ "$rans" =~ ^[Yy]$ ]]; then
          warn "系统将重启，当前会话将中断。"
          sync
          reboot
        fi
        ;;
      2)
        choose_congestion_and_qdisc
        ;;
      3)
        uninstall_xanmod
        ;;
      4)
        backup_preinstall
        ;;
      5)
        echo "---- /boot 文件 ----"
        ls -la /boot || true
        echo
        echo "---- 已安装的内核相关包（dpkg -l | grep linux-image） ----"
        dpkg -l | grep linux-image || true
        ;;
      6)
        read -r -p "$(printf '%b' "${YELLOW}确认现在重启？[y/N]: ${RESET}")" rr
        rr=${rr:-n}
        if [[ "$rr" =~ ^[Yy]$ ]]; then
          warn "重启中..."
          sync
          reboot
        fi
        ;;
      0)
        ok "退出。"
        exit 0
        ;;
      *)
        warn "无效选项"
        ;;
    esac
    echo
    read -r -p "$(printf '%b' "${YELLOW}按回车返回菜单...${RESET}")"
  done
}

# ----------------- Entry -----------------
if [ "$(id -u)" -ne 0 ]; then
  die "请以 root 用户运行此脚本（sudo）"
fi

main_menu

# EOF
