#!/usr/bin/env bash
#
# xray-egress.sh - 切换 xray 默认出口线路
#
# 三种模式:
#   mode1  按入站线路分流: IPv4 进 -> IPv4 出, IPv6 进 -> IPv6 出
#   mode2  任何入站 -> IPv4 出站
#   mode3  任何入站 -> IPv6 出站
#
# 设计原则:
#   * 只改出站 (outbounds) 与必要的路由规则, 绝不碰入站的客户端配置
#     (UUID / Reality 私钥 / SNI / shortId) 与 guard 白名单规则;
#   * 首次运行先把原配置备份到 $STATE_DIR/config.json.orig, 之后每次
#     切换都从这份原始配置出发, 保证模式之间干净切换、不留残余规则;
#   * 每次写入后先 xray -test 校验, 失败自动回滚; 重启后验证服务与
#     监听端口, 失败同样回滚;
#   * 切换配置必须重启 xray 一次 (约 1 秒, 现有连接会断开重连),
#     除此之外不改动任何现有服务; 卸载 = 恢复原始配置 + 重启验证 +
#     删除脚本自身与状态目录。
#
# 用法:
#   ./xray-egress.sh                  交互菜单 (先显示状态, 再进菜单)
#   ./xray-egress.sh status           只显示当前状态
#   ./xray-egress.sh mode1|mode2|mode3
#   ./xray-egress.sh uninstall [--force]
#   ./xray-egress.sh --help
#
# 环境变量 (一般不用改, 测试或特殊环境可用):
#   XRAY_CONFIG            配置文件路径 (默认自动探测)
#   XRAY_BIN               xray 可执行文件 (默认自动探测)
#   XRAY_EGRESS_STATE_DIR  状态/备份目录 (默认 /root/.xray-egress)
#   XRAY_EGRESS_INIT       强制 init 类型: systemd | openrc
#   XRAY_EGRESS_IPV4       强制指定 IPv4 (否则自动探测)
#   XRAY_EGRESS_IPV6       强制指定 IPv6 (否则自动探测)

set -euo pipefail

VERSION="1.0.0"

STATE_DIR="${XRAY_EGRESS_STATE_DIR:-/root/.xray-egress}"
BACKUP_FILE="$STATE_DIR/config.json.orig"
STATE_FILE="$STATE_DIR/state"

CONFIG=""
XRAY_BIN="${XRAY_BIN:-$(command -v xray 2>/dev/null || echo /usr/local/bin/xray)}"

die() {
    echo "错误: $*" >&2
    exit 1
}

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "请用 root 运行本脚本"
    fi
}

detect_config() {
    if [ -n "${XRAY_CONFIG:-}" ] && [ -f "$XRAY_CONFIG" ]; then
        printf '%s\n' "$XRAY_CONFIG"
        return 0
    fi
    local p
    for p in /usr/local/etc/xray/config.json /etc/xray/config.json; do
        if [ -f "$p" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}

detect_init() {
    if [ -n "${XRAY_EGRESS_INIT:-}" ]; then
        printf '%s\n' "$XRAY_EGRESS_INIT"
        return 0
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        printf 'systemd\n'
    elif command -v rc-service >/dev/null 2>&1; then
        printf 'openrc\n'
    else
        printf 'none\n'
    fi
}

xray_active() {
    case "$(detect_init)" in
        systemd) systemctl is-active --quiet xray ;;
        openrc) rc-service xray status >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

restart_xray() {
    case "$(detect_init)" in
        systemd) systemctl restart xray ;;
        openrc) rc-service xray restart ;;
        *) die "无法识别 init 系统 (既无 systemd 也无 OpenRC), 请手动重启 xray" ;;
    esac
}

verify_running() {
    sleep 1
    xray_active || return 1
    ss -tln 2>/dev/null | grep -qE ':443([^0-9]|$)'
}

# 本机 IPv4/IPv6 (出站连接默认会用的源地址, NAT 机上就是内网地址)
detect_ipv4() {
    if [ -n "${XRAY_EGRESS_IPV4:-}" ]; then
        printf '%s\n' "$XRAY_EGRESS_IPV4"
        return 0
    fi
    ip -4 route get 8.8.8.8 2>/dev/null | sed -n 's/.*src \([0-9][0-9.]*\).*/\1/p' | head -n 1
}

detect_ipv6() {
    if [ -n "${XRAY_EGRESS_IPV6:-}" ]; then
        printf '%s\n' "$XRAY_EGRESS_IPV6"
        return 0
    fi
    ip -6 route get 2606:4700:4700::1111 2>/dev/null | sed -n 's/.*src \([0-9a-fA-F:][0-9a-fA-F:]*\).*/\1/p' | head -n 1
}

# 实测公网出口地址 (curl 实际走的出口, 通则返回地址, 不通返回空)
public_ip() {
    curl -"$1" -s -m 6 https://ifconfig.me 2>/dev/null || true
}

mode_name() {
    case "$1" in
        mode1) printf '模式一: 按入站线路分流 (IPv4进->IPv4出, IPv6进->IPv6出)\n' ;;
        mode2) printf '模式二: 任何入站 -> IPv4 出站\n' ;;
        mode3) printf '模式三: 任何入站 -> IPv6 出站\n' ;;
        default) printf '默认: 未修改 (系统默认出站)\n' ;;
        unknown) printf '未知: 配置被手动改过, 与三种模式都不符\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# 从配置文件解析当前模式与出站设置, 输出 key=value
detect_mode_info() {
    python3 - "$CONFIG" <<'PYEOF_DETECT'
import json
import sys

cfg = json.load(open(sys.argv[1], encoding="utf-8"))
obs = {o.get("tag"): o for o in cfg.get("outbounds", [])}
rules = cfg.get("routing", {}).get("rules", [])
has_v4 = "direct-v4" in obs
has_v6 = "direct-v6" in obs
rule_v4 = any(r.get("outboundTag") == "direct-v4" for r in rules)
rule_v6 = any(r.get("outboundTag") == "direct-v6" for r in rules)
direct = obs.get("direct", {})
ds = (direct.get("settings") or {}).get("domainStrategy", "")
st = direct.get("sendThrough", "")
if has_v4 and has_v6 and rule_v4 and rule_v6:
    mode = "mode1"
elif ds == "UseIPv4":
    mode = "mode2"
elif ds == "UseIPv6":
    mode = "mode3"
elif has_v4 or has_v6 or rule_v4 or rule_v6 or ds:
    mode = "unknown"
else:
    mode = "default"
print("mode=" + mode)
print("direct_strategy=" + ds)
print("direct_sendThrough=" + st)
print("has_v4=" + ("1" if has_v4 else "0"))
print("has_v6=" + ("1" if has_v6 else "0"))
PYEOF_DETECT
}

show_status() {
    local mode direct_strategy direct_sendThrough has_v4 has_v6
    mode="unknown"; direct_strategy=""; direct_sendThrough=""; has_v4="0"; has_v6="0"
    while IFS='=' read -r k v; do
        case "$k" in
            mode) mode="$v" ;;
            direct_strategy) direct_strategy="$v" ;;
            direct_sendThrough) direct_sendThrough="$v" ;;
            has_v4) has_v4="$v" ;;
            has_v6) has_v6="$v" ;;
        esac
    done <<EOF_STATUS
$(detect_mode_info)
EOF_STATUS

    local init_svc xray_state xray_pid listen_ports
    init_svc="$(detect_init)"
    if xray_active; then
        xray_state="运行中"
    else
        xray_state="未运行"
    fi
    xray_pid="$(pgrep -x xray 2>/dev/null | head -n 1 || true)"
    listen_ports="$(ss -tlnp 2>/dev/null | grep -E 'xray' | awk '{print $4}' | sort -u | tr '\n' ' ' || true)"

    local if_v4 if_v6 gw_v4 gw_v6 pub4 pub6
    if_v4="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | head -n 1 || true)"
    if_v6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6 /{print $2}' | head -n 1 || true)"
    gw_v4="$(detect_ipv4 || true)"
    gw_v6="$(detect_ipv6 || true)"
    pub4="$(public_ip 4 || true)"
    pub6="$(public_ip 6 || true)"

    echo "========== xray 出口状态 =========="
    echo "当前模式   : $(mode_name "$mode")"
    echo "配置文件   : $CONFIG"
    echo "xray 服务  : $xray_state ($init_svc${xray_pid:+, pid $xray_pid})"
    echo "监听端口   : ${listen_ports:-未检测到}"
    echo "----------------------------------------"
    echo "本机地址 (网卡):"
    echo "  IPv4     : ${if_v4:-无}  (出站源地址: ${gw_v4:-无})"
    echo "  IPv6     : ${if_v6:-无}  (出站源地址: ${gw_v6:-无})"
    echo "公网出口 (curl 实测):"
    echo "  IPv4     : ${pub4:-不通}"
    echo "  IPv6     : ${pub6:-不通}"
    echo "----------------------------------------"
    echo "出站配置:"
    if [ "$has_v4" = "1" ] || [ "$has_v6" = "1" ]; then
        echo "  direct-v4  : freedom, UseIPv4, sendThrough=${gw_v4:-?}"
        echo "  direct-v6  : freedom, UseIPv6, sendThrough=${gw_v6:-?}"
    fi
    if [ -n "$direct_strategy" ] || [ -n "$direct_sendThrough" ]; then
        echo "  direct     : freedom, domainStrategy=${direct_strategy:-未设置}, sendThrough=${direct_sendThrough:-未设置}"
    else
        echo "  direct     : freedom (默认, 未强制出站线路)"
    fi
    echo "========================================"
}

backup_pristine() {
    mkdir -p "$STATE_DIR"
    if [ ! -f "$BACKUP_FILE" ]; then
        cp "$CONFIG" "$BACKUP_FILE"
        echo "已备份原始配置到 $BACKUP_FILE (以后切换/卸载都以这份为准)"
    fi
}

rollback_to_pristine() {
    echo "正在恢复原始配置..." >&2
    cp "$BACKUP_FILE" "$CONFIG"
    restart_xray || true
}

# 对原始配置做模式变换, 写到目标文件 (python 负责 JSON 操作)
transform_config() {
    local src="$1" mode="$2" ipv4="$3" ipv6="$4"
    python3 - "$src" "$mode" "$ipv4" "$ipv6" <<'PYEOF_EGRESS'
import json
import sys

path, mode, ipv4, ipv6 = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

with open(path, encoding="utf-8") as f:
    cfg = json.load(f)

inbounds = cfg.get("inbounds", [])
routing = cfg.setdefault("routing", {})
rules = routing.setdefault("rules", [])

# 主入站标签: 除 dokodemo-door guard 外的所有入站
main_tags = []
for ib in inbounds:
    if ib.get("protocol") == "dokodemo-door":
        continue
    tag = ib.get("tag")
    if not tag:
        tag = "in-%s" % ib.get("port", "0")
        ib["tag"] = tag
    main_tags.append(tag)

if mode == "mode1" and not main_tags:
    sys.stderr.write("错误: 配置里找不到非 guard 的入站\n")
    sys.exit(2)

def find_outbound(tag):
    for ob in cfg.get("outbounds", []):
        if ob.get("tag") == tag:
            return ob
    return None

def drop_outbound(tag):
    cfg["outbounds"] = [ob for ob in cfg.get("outbounds", []) if ob.get("tag") != tag]

def drop_rules(tags):
    routing["rules"] = [
        r for r in routing["rules"] if r.get("outboundTag") not in tags
    ]

# 先清掉本脚本管理的对象, 保证模式之间干净切换
drop_outbound("direct-v4")
drop_outbound("direct-v6")
drop_rules({"direct-v4", "direct-v6"})

if mode == "mode1":
    # 保留原 direct 出站不动 (guard 规则与默认出口继续用它),
    # 新增两条分流出站, 并把分流规则追加到规则末尾:
    # guard 规则与 bittorrent 拦截在前面, 保持优先。
    cfg.setdefault("outbounds", []).append({
        "protocol": "freedom",
        "settings": {"domainStrategy": "UseIPv4"},
        "sendThrough": ipv4,
        "tag": "direct-v4",
    })
    cfg.setdefault("outbounds", []).append({
        "protocol": "freedom",
        "settings": {"domainStrategy": "UseIPv6"},
        "sendThrough": ipv6,
        "tag": "direct-v6",
    })
    routing["rules"].append({
        "type": "field",
        "inboundTag": main_tags,
        "source": ["0.0.0.0/0"],
        "outboundTag": "direct-v4",
    })
    routing["rules"].append({
        "type": "field",
        "inboundTag": main_tags,
        "source": ["::/0"],
        "outboundTag": "direct-v6",
    })
elif mode in ("mode2", "mode3"):
    strategy = "UseIPv4" if mode == "mode2" else "UseIPv6"
    addr = ipv4 if mode == "mode2" else ipv6
    direct = find_outbound("direct")
    if direct is None or direct.get("protocol") != "freedom":
        sys.stderr.write("错误: 配置里找不到 tag 为 direct 的 freedom 出站\n")
        sys.exit(2)
    settings = direct.get("settings")
    if not isinstance(settings, dict):
        settings = {}
        direct["settings"] = settings
    settings["domainStrategy"] = strategy
    direct["sendThrough"] = addr
    dns = cfg.get("dns")
    if isinstance(dns, dict):
        dns["queryStrategy"] = strategy
else:
    sys.stderr.write("错误: 未知模式 %s\n" % mode)
    sys.exit(2)

with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYEOF_EGRESS
}

apply_mode() {
    local mode="$1"
    local ipv4 ipv6 tmp
    ipv4="$(detect_ipv4 || true)"
    ipv6="$(detect_ipv6 || true)"

    case "$mode" in
        mode1)
            [ -n "$ipv4" ] || die "未检测到 IPv4 地址, 无法使用模式一"
            [ -n "$ipv6" ] || die "未检测到 IPv6 地址, 无法使用模式一"
            ;;
        mode2)
            [ -n "$ipv4" ] || die "未检测到 IPv4 地址, 无法使用模式二"
            ;;
        mode3)
            [ -n "$ipv6" ] || die "未检测到 IPv6 地址, 无法使用模式三"
            if [ -z "$(public_ip 6)" ]; then
                die "IPv6 出站测试失败 (curl -6 不通), 模式三会让全部出站断网, 已拒绝执行, 请先排查本机 IPv6 出口"
            fi
            ;;
    esac

    echo "正在切换到: $(mode_name "$mode")"
    backup_pristine

    tmp="$(mktemp)"
    cp "$BACKUP_FILE" "$tmp"
    if ! transform_config "$tmp" "$mode" "$ipv4" "$ipv6"; then
        rm -f "$tmp"
        die "配置生成失败, 未做任何修改"
    fi
    if ! "$XRAY_BIN" -test -config "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        die "新配置校验失败 (xray -test 未通过), 未做任何修改"
    fi
    cp "$tmp" "$CONFIG"
    rm -f "$tmp"

    echo "配置已写入, 正在重启 xray (约 1 秒, 现有连接会断开重连)..."
    restart_xray
    if ! verify_running; then
        rollback_to_pristine
        die "重启后验证失败 (服务未运行或 443 未监听), 已恢复原始配置"
    fi
    printf '%s\n' "$mode" > "$STATE_FILE"
    echo "切换成功: $(mode_name "$mode")"
    show_status
}

confirm_uninstall() {
    local ans=""
    if [ "${2:-}" = "--force" ]; then
        return 0
    fi
    if [ -t 0 ]; then
        read -rp "确认卸载? 将恢复安装前配置并删除本脚本 (y/N): " ans || return 1
    elif [ -e /dev/tty ]; then
        read -rp "确认卸载? 将恢复安装前配置并删除本脚本 (y/N): " ans </dev/tty || return 1
    else
        echo "非交互环境, 请加 --force 确认卸载" >&2
        return 1
    fi
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

uninstall() {
    if ! confirm_uninstall "$@"; then
        echo "已取消卸载"
        return 0
    fi
    if [ -f "$BACKUP_FILE" ]; then
        cp "$BACKUP_FILE" "$CONFIG"
        if ! "$XRAY_BIN" -test -config "$CONFIG" >/dev/null 2>&1; then
            die "恢复后的配置校验失败, 未删除备份, 请手动检查 $CONFIG"
        fi
        echo "已恢复安装前配置, 正在重启 xray..."
        restart_xray
        if ! verify_running; then
            die "重启后验证失败, 备份仍在 $BACKUP_FILE, 请手动检查"
        fi
        echo "xray 已恢复到安装前配置并正常运行"
    else
        echo "未找到原始配置备份, 配置未被本脚本修改过, 直接卸载"
    fi
    rm -rf "$STATE_DIR"
    local self_path
    self_path="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
    case "$self_path" in
        /dev/fd/*|/proc/*|bash|sh)
            echo "本次通过管道运行, 无法删除脚本文件, 请手动删除下载的脚本"
            ;;
        *)
            rm -f "$self_path" && echo "已删除脚本 $self_path"
            ;;
    esac
    echo "卸载完成"
}

usage() {
    echo "xray-egress.sh v$VERSION - 切换 xray 默认出口线路"
    echo ""
    echo "用法:"
    echo "  $0                  交互菜单 (先显示状态, 再进菜单)"
    echo "  $0 status           只显示当前状态"
    echo "  $0 mode1            模式一: IPv4进->IPv4出, IPv6进->IPv6出"
    echo "  $0 mode2            模式二: 任何入站 -> IPv4 出站"
    echo "  $0 mode3            模式三: 任何入站 -> IPv6 出站"
    echo "  $0 uninstall [--force]  卸载: 恢复安装前配置并删除脚本"
    echo "  $0 --help"
}

menu() {
    if [ ! -t 0 ] && [ -e /dev/tty ]; then
        exec </dev/tty
    fi
    while true; do
        show_status
        echo "请选择操作:"
        echo "  1) 模式一: IPv4进->IPv4出, IPv6进->IPv6出"
        echo "  2) 模式二: 任何入站 -> IPv4出站"
        echo "  3) 模式三: 任何入站 -> IPv6出站"
        echo "  4) 刷新状态"
        echo "  5) 卸载 (恢复安装前配置并删除脚本)"
        echo "  0) 退出"
        local choice=""
        read -rp "请输入 [0-5]: " choice || exit 0
        case "$choice" in
            1) apply_mode mode1 ;;
            2) apply_mode mode2 ;;
            3) apply_mode mode3 ;;
            4) show_status ;;
            5) uninstall ;;
            0) exit 0 ;;
            *) echo "无效选择, 请重新输入" ;;
        esac
        echo ""
        read -rp "按回车返回菜单..." _dummy || true
    done
}

main() {
    need_root
    command -v python3 >/dev/null 2>&1 || die "需要 python3 (Debian/Ubuntu: apt install -y python3; Alpine: apk add python3)"
    CONFIG="$(detect_config)" || die "找不到 xray 配置文件 (/usr/local/etc/xray/config.json 或 /etc/xray/config.json), 可用 XRAY_CONFIG 环境变量指定"
    if [ ! -x "$XRAY_BIN" ] && [ ! -f "$XRAY_BIN" ]; then
        die "找不到 xray 可执行文件, 可用 XRAY_BIN 环境变量指定"
    fi
    case "${1:-}" in
        ""|menu) menu ;;
        status) show_status ;;
        mode1|mode2|mode3) apply_mode "$1" ;;
        uninstall) uninstall "$@" ;;
        -h|--help|help) usage ;;
        *)
            echo "未知参数: $1" >&2
            usage
            exit 1
            ;;
    esac
}

main "$@"
