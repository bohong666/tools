#!/usr/bin/env bash
# xanmod-bbr3-installer.sh
# One-shot installer + uninstaller for XanMod kernel + BBR3 support
# Version:
SCRIPT_VERSION="1.0.0"

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

# Backup target paths (user requested default)
BACKUP_DIR_CONF="/etc/bbr-manager"
BACKUP_JSON="${BACKUP_DIR_CONF}/backup.json"
BACKUP_CONF="${BACKUP_DIR_CONF}/backup.conf"   # shell sourced on restore

XANMOD_LIST="/etc/apt/sources.list.d/xanmod.list"
XANMOD_GPG="/etc/apt/trusted.gpg.d/xanmod.gpg"
SYSCTL_CONF="/etc/sysctl.d/99-xanmod-bbr.conf"

mkdir -p "$WORKDIR" "$BACKUPDIR" "$BACKUP_DIR_CONF"
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

# ----------------- Status gathering -----------------
gather_status(){
  detect_distro
  CURRENT_KERNEL="$KERNEL_UNAME"
  IS_XANMOD="No"
  if echo "$CURRENT_KERNEL" | grep -qi xanmod; then
    IS_XANMOD="Yes"
  elif [ -f "$XANMOD_LIST" ]; then
    IS_XANMOD="Repo"
  elif command_exists dpkg && dpkg -l 2>/dev/null | grep -qi xanmod; then
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

  IFACES_RAW=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}')
  IFACES=$(echo "$IFACES_RAW" | grep -Ev '^(lo|docker|veth|br-|virbr|tun|tap)' || true)

  # detect installed kernel-packages (dpkg)
  BACKUP_KERNEL_PACKAGES=""
  if command_exists dpkg; then
    BACKUP_KERNEL_PACKAGES=$(dpkg -l | awk '/linux-image|linux-headers/ {print $2}' | tr '\n' ' ' || true)
  fi
}

print_status(){
  gather_status
  echo
  printf "%b\n" "${BOLD}======== 当前系统状态 ========${RESET}"
  printf "脚本版本: %s\n" "$SCRIPT_VERSION"
  printf "系统: %s (%s)\n" "${DISTRO_NAME:-unknown}" "${DISTRO_ID:-unknown}"
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

# ----------------- Backup & Restore -----------------
ensure_backup_dir(){
  mkdir -p "$BACKUP_DIR_CONF"
  chmod 0755 "$BACKUP_DIR_CONF"
}

escape_json_string(){
  # $1 string -> escaped for JSON value
  printf '%s' "$1" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().rstrip("\n")))'
}

backup_preinstall(){
  gather_status
  ensure_backup_dir

  ok "正在备份当前系统状态到: $BACKUP_JSON (同时生成 $BACKUP_CONF)"
  # create conf (shell-friendly)
  cat > "$BACKUP_CONF" <<EOF
# Backup created: $(date -Iseconds)
BACKUP_DATE="$(date -Iseconds)"
BACKUP_DISTRO="${DISTRO_NAME:-unknown}"
BACKUP_DISTRO_ID="${DISTRO_ID:-unknown}"
BACKUP_ARCH="${ARCH:-unknown}"
BACKUP_CURRENT_KERNEL="${CURRENT_KERNEL:-unknown}"
BACKUP_IS_XANMOD="${IS_XANMOD:-unknown}"
BACKUP_TCP_CURRENT="${TCP_CURRENT:-unknown}"
BACKUP_TCP_AVAILABLE="${TCP_AVAILABLE:-unknown}"
BACKUP_QDISC_CURRENT="${QDISC_CURRENT:-unknown}"
BACKUP_QDISC_AVAILABLE="${QDISC_AVAILABLE:-unknown}"
BACKUP_BBR3_LOADED="${BBR3_LOADED:-unknown}"
BACKUP_BBR_VERSION="${BBR_VERSION_DISPLAY:-unknown}"
BACKUP_CAKE_PRESENT="${CAKE_PRESENT:-unknown}"
BACKUP_IFACES="${IFACES:-}"
BACKUP_KERNEL_PACKAGES="${BACKUP_KERNEL_PACKAGES:-}"
EOF

  # create json (best-effort, escape strings)
  # Use python3 if available to ensure valid JSON; else create simple JSON with minimal escaping
  if command_exists python3; then
    python3 - <<PY > "$BACKUP_JSON"
import json,sys
d = {
  "date":"$(date -Iseconds)",
  "distro":"${DISTRO_NAME:-unknown}",
  "distro_id":"${DISTRO_ID:-unknown}",
  "arch":"${ARCH:-unknown}",
  "current_kernel":"${CURRENT_KERNEL:-unknown}",
  "is_xanmod":"${IS_XANMOD:-unknown}",
  "tcp_current":"${TCP_CURRENT:-unknown}",
  "tcp_available":"${TCP_AVAILABLE:-unknown}",
  "qdisc_current":"${QDISC_CURRENT:-unknown}",
  "qdisc_available":"${QDISC_AVAILABLE:-unknown}",
  "bbr3_loaded":"${BBR3_LOADED:-unknown}",
  "bbr_version":"${BBR_VERSION_DISPLAY:-unknown}",
  "cake_present":"${CAKE_PRESENT:-unknown}",
  "ifaces":"${IFACES:-}",
  "kernel_packages":"${BACKUP_KERNEL_PACKAGES:-}"
}
json.dump(d,sys.stdout,indent=2)
PY
  else
    # Fallback: rudimentary JSON (may not escape all characters)
    cat > "$BACKUP_JSON" <<EOF
{
  "date":"$(date -Iseconds)",
  "distro":"${DISTRO_NAME:-unknown}",
  "distro_id":"${DISTRO_ID:-unknown}",
  "arch":"${ARCH:-unknown}",
  "current_kernel":"${CURRENT_KERNEL:-unknown}",
  "is_xanmod":"${IS_XANMOD:-unknown}",
  "tcp_current":"${TCP_CURRENT:-unknown}",
  "tcp_available":"${TCP_AVAILABLE:-unknown}",
  "qdisc_current":"${QDISC_CURRENT:-unknown}",
  "qdisc_available":"${QDISC_AVAILABLE:-unknown}",
  "bbr3_loaded":"${BBR3_LOADED:-unknown}",
  "bbr_version":"${BBR_VERSION_DISPLAY:-unknown}",
  "cake_present":"${CAKE_PRESENT:-unknown}",
  "ifaces":"${IFACES:-}",
  "kernel_packages":"${BACKUP_KERNEL_PACKAGES:-}"
}
EOF
  fi

  ok "备份已完成: $BACKUP_JSON  & $BACKUP_CONF"
  echo
  ok "请保留 $BACKUP_DIR_CONF 以便将来恢复。"
}

restore_from_backup(){
  if [ ! -f "$BACKUP_CONF" ]; then
    err "未找到备份配置文件: $BACKUP_CONF"
    return 1
  fi

  # make an additional snapshot of current state before restoring
  info "将在恢复前再次备份当前状态（双保险）..."
  cp -av "$BACKUP_CONF" "${BACKUP_CONF}.pre-restore.$(date +%s)" 2>/dev/null || true
  cp -av "$BACKUP_JSON" "${BACKUP_JSON}.pre-restore.$(date +%s)" 2>/dev/null || true

  # load backup conf (safe)
  # shellcheck disable=SC1090
  source "$BACKUP_CONF"

  ok "读取备份：$BACKUP_CONF (创建于 $BACKUP_DATE)"
  echo "备份记录的系统内核: $BACKUP_CURRENT_KERNEL"
  echo "备份记录的拥塞控制: $BACKUP_TCP_CURRENT"
  echo "备份记录的 qdisc: $BACKUP_QDISC_CURRENT"
  echo "备份记录的网络接口: $BACKUP_IFACES"
  echo

  read -r -p "$(printf '%b' "${YELLOW}确认要按备份恢复 sysctl (TCP + qdisc)？[y/N]: ${RESET}")" ans
  ans=${ans:-n}
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    # restore sysctl
    cat > "$SYSCTL_CONF" <<EOF
# Restored by xanmod-bbr3-installer (backup date: ${BACKUP_DATE:-unknown})
net.core.default_qdisc = ${BACKUP_QDISC_CURRENT:-fq}
net.ipv4.tcp_congestion_control = ${BACKUP_TCP_CURRENT:-bbr}
EOF
    run "sysctl --system || true"
    ok "sysctl 已恢复（可能需重启或重新加载内核模块生效）"
  else
    warn "跳过 sysctl 恢复"
  fi

  # attempt to restore qdisc (requires choosing interface)
  read -r -p "$(printf '%b' "${YELLOW}是否要尝试恢复 qdisc 到备份时的状态？[y/N]: ${RESET}")" ans2
  ans2=${ans2:-n}
  if [[ "$ans2" =~ ^[Yy]$ ]]; then
    # Ask which interface to apply (default to first saved)
    SAVED_IFACE=$(echo "$BACKUP_IFACES" | awk '{print $1}')
    if [ -z "$SAVED_IFACE" ]; then
      warn "备份中未记录接口，无法自动恢复 qdisc"
    else
      echo "备份中记录的首个接口: $SAVED_IFACE"
      read -r -p "$(printf '%b' "${YELLOW}确认在接口 $SAVED_IFACE 上恢复 qdisc ${BACKUP_QDISC_CURRENT:-fq}？[y/N]: ${RESET}")" ans3
      ans3=${ans3:-n}
      if [[ "$ans3" =~ ^[Yy]$ ]]; then
        # apply restore (conservative)
        if command_exists tc; then
          run "tc qdisc del dev ${SAVED_IFACE} root 2>/dev/null || true"
          run "tc qdisc replace dev ${SAVED_IFACE} root ${BACKUP_QDISC_CURRENT:-fq} || true"
          ok "已尝试在 $SAVED_IFACE 上恢复 qdisc（可能需要内核模块支持或重启）"
        else
          warn "系统无 tc 命令，无法恢复 qdisc；请先安装 iproute2"
        fi
      fi
    fi
  else
    warn "跳过 qdisc 恢复"
  fi

  # Attempt kernel package restore guidance / action
  if [ -n "${BACKUP_KERNEL_PACKAGES:-}" ]; then
    echo
    warn "备份时记录了内核相关包（数量可能较多）。脚本可以尝试恢复这些包（若仍可从仓库安装）。"
    read -r -p "$(printf '%b' "${YELLOW}是否尝试重新安装备份中记录的内核包？（需要网络并由 apt 提供）[y/N]: ${RESET}")" ansk
    ansk=${ansk:-n}
    if [[ "$ansk" =~ ^[Yy]$ ]]; then
      if command_exists apt-get; then
        # simple attempt: install listed packages (this may skip already-installed)
        run "apt-get update -y || true"
        # limit length to avoid extremely long apt invocation: split by space and install selectively
        IFS=' ' read -r -a pkgarr <<< "${BACKUP_KERNEL_PACKAGES}"
        toinstall=()
        for p in "${pkgarr[@]}"; do
          # skip empty
          [ -z "$p" ] && continue
          # check if installed now
          if dpkg -l 2>/dev/null | awk '{print $2}' | grep -xq "$p"; then
            continue
          fi
          toinstall+=("$p")
        done
        if [ ${#toinstall[@]} -gt 0 ]; then
          warn "将尝试安装 ${#toinstall[@]} 个包（可能部分不存在于当前仓库）"
          run "apt-get install -y ${toinstall[*]} || true"
        else
          ok "备份中记录的内核包已全部安装，无需操作"
        fi
      else
        warn "系统不支持 apt-get，无法自动恢复内核包"
      fi
    fi
  fi

  # restore /boot files from boot-snapshot if present in /var/tmp backupdir
  # earlier script stores /var/tmp/... backup; but for safety we only restore from BACKUPDIR that our script created in session
  # The script earlier also saved search-backup in $BACKUPDIR; we'll prompt user to manually restore if present.
  if [ -d "$BACKUPDIR/boot-snapshot" ]; then
    echo
    warn "脚本检测到会话临时备份 $BACKUPDIR/boot-snapshot（若存在可选恢复）。"
    read -r -p "$(printf '%b' "${YELLOW}是否将 $BACKUPDIR/boot-snapshot/* 恢复覆盖到 /boot ?（谨慎）[y/N]: ${RESET}")" ansb
    ansb=${ansb:-n}
    if [[ "$ansb" =~ ^[Yy]$ ]]; then
      run "cp -av $BACKUPDIR/boot-snapshot/* /boot/ || true"
      ok "已尝试恢复 /boot 内容（请手动检查 /boot 并运行 update-grub，如有必要）"
      run "update-grub || true"
    else
      warn "跳过 /boot 恢复"
    fi
  fi

  ok "恢复流程完成（部分操作可能需要手动检查或重启以完全生效）"
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

# ----------------- Qdisc & Sysctl application -----------------
select_interface(){
  gather_status
  mapfile -t IF_ARR < <(echo "$IFACES" | tr ' ' '\n' | sed '/^$/d')
  if [ ${#IF_ARR[@]} -eq 0 ]; then
    read -r -p "$(printf '%b' "${YELLOW}未自动检测到可用网卡，请手动输入接口名 (如 eth0): ${RESET}")" manif
    if [ -z "$manif" ]; then
      die "未提供接口，终止"
    fi
    SELECT_IF="$manif"
  elif [ ${#IF_ARR[@]} -eq 1 ]; then
    SELECT_IF="${IF_ARR[0]}"
    echo "自动选择接口: $SELECT_IF"
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

  if [[ "$qdisc" == "cake" ]]; then
    if [ -n "$cake_bw" ]; then
      ok "将为接口 $iface 应用 CAKE 带宽模板: ${cake_bw}mbit (同时作为上/下行)"
      run "tc qdisc del dev $iface root 2>/dev/null || true"
      run "tc qdisc replace dev $iface root cake bandwidth ${cake_bw}mbit || { warn '在 root 上应用 cake 失败'; }"
      run "tc qdisc del dev $iface ingress 2>/dev/null || true"
      if tc qdisc replace dev "$iface" ingress cake bandwidth ${cake_bw}mbit 2>/dev/null; then
        ok "已在 ingress 应用 cake bandwidth ${cake_bw}mbit"
      else
        warn "在 ingress 应用 cake 失败（内核/平台可能不支持直接在 ingress 使用 cake），已在 egress(root) 应用。"
      fi
    else
      run "tc qdisc replace dev $iface root cake || true"
      warn "未提供 bandwidth，已在 root 应用 cake（无带宽限制）"
    fi
  else
    run "tc qdisc replace dev $iface root $qdisc || { warn '应用 qdisc 失败'; }"
  fi

  ok "尝试应用 qdisc 完成（部分操作可能需重启或内核模块支持）。"
}

# ----------------- Uninstall XanMod -----------------
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

# ----------------- Interaction (CC & qdisc) -----------------
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

  CAKE_BW=""
  if [[ "$QD" == "cake" ]]; then
    echo
    warn "你选择了 CAKE。请按提示输入 单一 带宽值 (Mbps)，脚本会同时应用到上行/下行。"
    while true; do
      read -r -p "$(printf '%b' "${YELLOW}请输入带宽值 (Mbps, 仅数字，例如 100) 或回车取消: ${RESET}")" bw
      bw=${bw:-}
      if [ -z "$bw" ]; then
        warn "未输入带宽值，将以默认方式应用 cake（无 bandwidth 限制）"
        CAKE_BW=""
        break
      fi
      if echo "$bw" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then
        CAKE_BW="$bw"
        ok "将使用带宽: ${CAKE_BW} Mbps（同时作为上/下行）"
        break
      else
        warn "输入无效，请输入正数（例如 100）"
      fi
    done
  fi

  select_interface
  backup_preinstall
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
 2) 选择/切换 拥塞控制算法 (CC) 与 qdisc（交互式；CAKE 使用单一带宽值）
 3) 卸载 XanMod（保守模式）
 4) 备份当前系统状态（手动触发）
 5) 恢复备份（使用 ${BACKUP_JSON} / ${BACKUP_CONF}）
 6) 显示 /boot 内容 & 已安装内核包
 7) 直接重启系统
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
        restore_from_backup
        ;;
      6)
        echo "---- /boot 文件 ----"
        ls -la /boot || true
        echo
        echo "---- 已安装的内核相关包（dpkg -l | grep linux-image） ----"
        dpkg -l | grep linux-image || true
        ;;
      7)
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
