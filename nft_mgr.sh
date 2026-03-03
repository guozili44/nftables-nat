#!/bin/bash

# ==========================================
# nftables 端口转发管理面板 (Pro 稳定优化版)
# ==========================================
# 主要改进（相对旧版）：
# 1) 不再 flush ruleset / 不再覆写 /etc/nftables.conf（避免清空系统已有 nft 规则）
# 2) 仅管理自己的表：table ip nft_mgr_nat（低冲突）
# 3) 原子化应用：nft -c 校验 -> 应用 -> 再写入持久化配置
# 4) 并发互斥：所有写配置/应用规则/DDNS 更新均加锁（避免 cron 与交互并发踩踏）
# 5) 安全自更新：下载到临时文件 -> bash -n 校验 -> 原子替换（失败不覆盖）
# 6) 修复关键错误：去掉 sudo、修复潜在冲突 alias、修复高风险覆写/清空行为
#
# 配置文件格式（向下兼容）：
#   lport|target_addr|target_port|last_ip|proto
#   proto: tcp / udp / both
#   旧版没有 proto 字段时，默认 both。
#
# 运行命令（脚本会自安装为 /usr/local/bin/nftmgr）：
#   nftmgr
#   nftmgr --cron
#
# ==========================================

set -o pipefail

# 兼容 cron/systemd 的精简 PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# --------------------------
# 可配置常量
# --------------------------
CONFIG_FILE="/etc/nft_forward_list.conf"
SETTINGS_FILE="/etc/nft_forward_settings.conf"

NFT_MGR_DIR="/etc/nftables.d"
NFT_MGR_CONF="${NFT_MGR_DIR}/nft_mgr.conf"
NFT_MGR_SERVICE="/etc/systemd/system/nft-mgr.service"

SYSCTL_FILE="/etc/sysctl.d/99-nft-mgr.conf"

LOG_DIR="/var/log/nft_ddns"
LOCK_FILE="/var/lock/nft_mgr.lock"

CMD_NAME="nftmgr"

RAW_URL="https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/nft_mgr.sh"
PROXY_URL="https://ghproxy.net/https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/nft_mgr.sh"

# --------------------------
# 颜色
# --------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# --------------------------
# 基础工具
# --------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

script_realpath() {
    realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0"
}

msg_ok()   { echo -e "${GREEN}$*${PLAIN}"; }
msg_warn() { echo -e "${YELLOW}$*${PLAIN}"; }
msg_err()  { echo -e "${RED}$*${PLAIN}"; }
msg_info() { echo -e "${CYAN}$*${PLAIN}"; }

# --------------------------
# 环境与依赖
# --------------------------
require_root() {
    [[ $EUID -ne 0 ]] && msg_err "错误: 必须使用 root 权限运行!" && exit 1
}

detect_pkg_mgr() {
    if have_cmd apt-get; then
        echo "apt"
    elif have_cmd dnf; then
        echo "dnf"
    elif have_cmd yum; then
        echo "yum"
    else
        echo ""
    fi
}

install_deps() {
    local mgr
    mgr="$(detect_pkg_mgr)"
    [[ -z "$mgr" ]] && return 1

    # 依赖：nft/dig/curl/flock/ss
    if [[ "$mgr" == "apt" ]]; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -yqq nftables dnsutils curl util-linux iproute2 >/dev/null 2>&1 || true
    else
        # dnf/yum
        "$mgr" install -y nftables bind-utils curl util-linux iproute >/dev/null 2>&1 || true
    fi
}

check_env() {
    # 自动装依赖（尽量温和）
    local need=0
    for c in nft dig curl flock ss; do
        have_cmd "$c" || need=1
    done
    [[ $need -eq 1 ]] && install_deps

    # 再次检查
    for c in nft dig curl flock ss; do
        have_cmd "$c" || msg_warn "⚠️ 未找到依赖命令: $c（部分功能可能不可用）"
    done

    mkdir -p "$(dirname "$CONFIG_FILE")" "$LOG_DIR" "$NFT_MGR_DIR" 2>/dev/null || true
    [[ -f "$CONFIG_FILE" ]] || touch "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

install_global_command() {
    local self
    self="$(script_realpath)"
    if [[ "$self" != "/usr/local/bin/${CMD_NAME}" ]]; then
        cp -f "$self" "/usr/local/bin/${CMD_NAME}" 2>/dev/null || true
        chmod +x "/usr/local/bin/${CMD_NAME}" 2>/dev/null || true
    fi
}

# --------------------------
# 锁（防并发踩踏）
# --------------------------
with_lock() {
    # 用法：with_lock <func> [args...]
    if have_cmd flock; then
        (
            flock -n 200 || { msg_warn "⚠️ 任务繁忙：已有实例在运行，已跳过本次操作。"; exit 99; }
            "$@"
        ) 200>"$LOCK_FILE"
        return $?
    else
        "$@"
        return $?
    fi
}

# --------------------------
# 参数/输入校验
# --------------------------
is_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

is_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

normalize_proto() {
    local p="${1,,}"
    case "$p" in
        tcp|udp|both) echo "$p" ;;
        "") echo "both" ;;
        *) echo "both" ;;
    esac
}

# --------------------------
# DNS 解析
# --------------------------
get_ip() {
    local addr="$1"
    if is_ipv4 "$addr"; then
        echo "$addr"
        return 0
    fi
    # 更稳健：限制超时/尝试次数，优先取第一条 A
    dig +time=2 +tries=1 +short -4 A "$addr" 2>/dev/null \
        | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
        | head -n 1
}

# --------------------------
# 防火墙放行（尽量不混用 iptables；优先 ufw/firewalld）
# --------------------------
manage_firewall() {
    local action="$1"  # add|del
    local port="$2"
    local proto="$3"   # tcp|udp|both
    proto="$(normalize_proto "$proto")"

    if have_cmd ufw && ufw status 2>/dev/null | grep -qw active; then
        if [[ "$action" == "add" ]]; then
            [[ "$proto" == "tcp" || "$proto" == "both" ]] && ufw allow "$port"/tcp >/dev/null 2>&1
            [[ "$proto" == "udp" || "$proto" == "both" ]] && ufw allow "$port"/udp >/dev/null 2>&1
        else
            [[ "$proto" == "tcp" || "$proto" == "both" ]] && ufw --force delete allow "$port"/tcp >/dev/null 2>&1
            [[ "$proto" == "udp" || "$proto" == "both" ]] && ufw --force delete allow "$port"/udp >/dev/null 2>&1
        fi
        return 0
    fi

    if have_cmd firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
        if [[ "$action" == "add" ]]; then
            [[ "$proto" == "tcp" || "$proto" == "both" ]] && firewall-cmd --add-port="${port}/tcp" --permanent >/dev/null 2>&1
            [[ "$proto" == "udp" || "$proto" == "both" ]] && firewall-cmd --add-port="${port}/udp" --permanent >/dev/null 2>&1
        else
            [[ "$proto" == "tcp" || "$proto" == "both" ]] && firewall-cmd --remove-port="${port}/tcp" --permanent >/dev/null 2>&1
            [[ "$proto" == "udp" || "$proto" == "both" ]] && firewall-cmd --remove-port="${port}/udp" --permanent >/dev/null 2>&1
        fi
        firewall-cmd --reload >/dev/null 2>&1
        return 0
    fi

    # 无 ufw/firewalld：不强行改系统过滤策略，避免与用户自定义 nft 防火墙冲突
    return 0
}

# --------------------------
# sysctl 写入（只写本脚本自己的文件）
# --------------------------
sysctl_set_kv() {
    local key="$1"; local value="$2"
    mkdir -p /etc/sysctl.d 2>/dev/null || true
    touch "$SYSCTL_FILE" 2>/dev/null || true

    if grep -qE "^\s*${key}\s*=" "$SYSCTL_FILE" 2>/dev/null; then
        sed -i "s|^\s*${key}\s*=.*|${key} = ${value}|g" "$SYSCTL_FILE"
    else
        echo "${key} = ${value}" >> "$SYSCTL_FILE"
    fi
}

ensure_forwarding() {
    local cur
    cur="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
    if [[ "$cur" != "1" ]]; then
        sysctl_set_kv "net.ipv4.ip_forward" "1"
        sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    fi
}

bbr_available() {
    sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr
}

optimize_system() {
    clear
    echo -e "${GREEN}--- 系统优化 (BBR + 转发 + 自启动) ---${PLAIN}"
    echo "1) 稳定推荐：仅开启转发 + 尝试启用 BBR"
    echo "2) 性能增强：在 1 的基础上，适度提升队列/并发（偏高负载）"
    echo "0) 返回"
    echo "--------------------------------"
    read -rp "请选择 [0-2]: " pick

    case "$pick" in
        0) return ;;
        1|2) ;;
        *) msg_err "无效选项"; sleep 1; return ;;
    esac

    msg_info "正在写入 sysctl 配置..."
    sysctl_set_kv "net.ipv4.ip_forward" "1"

    # BBR: 仅在内核支持时写入，避免误导
    if bbr_available; then
        sysctl_set_kv "net.core.default_qdisc" "fq"
        sysctl_set_kv "net.ipv4.tcp_congestion_control" "bbr"
    else
        msg_warn "⚠️ 当前内核未检测到 bbr（将仅启用转发）。"
    fi

    if [[ "$pick" == "2" ]]; then
        sysctl_set_kv "net.core.somaxconn" "8192"
        sysctl_set_kv "net.core.netdev_max_backlog" "8192"
        # 适度提升 file-max（保守值）
        sysctl_set_kv "fs.file-max" "524288"
    fi

    sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true

    # nftables + nft-mgr service
    if have_cmd systemctl; then
        msg_info "正在设置 nftables 开机自启..."
        systemctl enable --now nftables >/dev/null 2>&1 || true
        ensure_nft_mgr_service
    fi

    msg_ok "✅ 系统优化已应用。"
    sleep 2
}

# --------------------------
# nft-mgr systemd 持久化服务
# --------------------------
ensure_nft_mgr_service() {
    [[ -d "$NFT_MGR_DIR" ]] || mkdir -p "$NFT_MGR_DIR" 2>/dev/null || true
    [[ -f "$NFT_MGR_CONF" ]] || generate_empty_conf "$NFT_MGR_CONF"

    if ! have_cmd systemctl; then
        return 0
    fi

    local nftbin
    nftbin="$(command -v nft 2>/dev/null || echo /usr/sbin/nft)"

    cat > "$NFT_MGR_SERVICE" << EOF
[Unit]
Description=nftables Port Forwarding Manager (nftmgr)
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c '${nftbin} delete table ip nft_mgr_nat 2>/dev/null || true; ${nftbin} -f ${NFT_MGR_CONF}'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable nft-mgr >/dev/null 2>&1 || true
}

# --------------------------
# 生成 nft 配置（只管理自己的表）
# --------------------------
generate_empty_conf() {
    local out="$1"
    cat > "$out" << 'EOF'
# nft-mgr empty ruleset (generated)
table ip nft_mgr_nat {
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
    }
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
    }
}
EOF
    chmod 600 "$out" 2>/dev/null || true
}

generate_nft_conf() {
    local out="$1"
    local any=0

    {
        echo "# nft-mgr ruleset (generated at $(date '+%F %T'))"
        echo "table ip nft_mgr_nat {"
        echo "    chain prerouting {"
        echo "        type nat hook prerouting priority -100; policy accept;"
        # DNAT + in counter
        while IFS='|' read -r lp addr tp last_ip proto; do
            [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
            proto="$(normalize_proto "$proto")"
            is_port "$lp" || continue
            is_port "$tp" || continue

            local ip
            ip="$last_ip"
            [[ -z "$ip" ]] && ip="$(get_ip "$addr")"
            is_ipv4 "$ip" || continue

            local pexpr
            case "$proto" in
                tcp)  pexpr="tcp" ;;
                udp)  pexpr="udp" ;;
                both) pexpr="{ tcp, udp }" ;;
            esac

            echo "        meta l4proto ${pexpr} th dport ${lp} counter comment \"in_${lp}\" dnat to ${ip}:${tp}"
            any=1
        done < "$CONFIG_FILE"
        echo "    }"
        echo "    chain postrouting {"
        echo "        type nat hook postrouting priority 100; policy accept;"
        # out counter + masquerade
        while IFS='|' read -r lp addr tp last_ip proto; do
            [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
            proto="$(normalize_proto "$proto")"
            is_port "$lp" || continue
            is_port "$tp" || continue

            local ip
            ip="$last_ip"
            [[ -z "$ip" ]] && ip="$(get_ip "$addr")"
            is_ipv4 "$ip" || continue

            local pexpr
            case "$proto" in
                tcp)  pexpr="tcp" ;;
                udp)  pexpr="udp" ;;
                both) pexpr="{ tcp, udp }" ;;
            esac

            # 统计回包（仅统计 DNAT 的连接，避免误计本机服务）
            echo "        ct status dnat ct original dport ${lp} ct direction reply meta l4proto ${pexpr} counter comment \"out_${lp}\""

            # 仅对该转发连接做 masquerade（使用 ct original dport 限定，避免影响本机主动访问）
            echo "        ct status dnat ct original dport ${lp} meta l4proto ${pexpr} ip daddr ${ip} th dport ${tp} masquerade"
            any=1
        done < "$CONFIG_FILE"
        echo "    }"
        echo "}"
    } > "$out"

    chmod 600 "$out" 2>/dev/null || true
    [[ $any -eq 1 ]] || return 2
    return 0
}

# --------------------------
# 原子化应用规则到内核 + 持久化
# --------------------------
apply_rules_impl() {
    ensure_forwarding
    ensure_nft_mgr_service

    local tmp
    tmp="$(mktemp /tmp/nftmgr.XXXXXX)"
    local has_rules=0

    if generate_nft_conf "$tmp"; then
        has_rules=1
    else
        # 没有有效规则：生成空表，保持一致性
        generate_empty_conf "$tmp"
        has_rules=0
    fi

    # 语法检查
    if have_cmd nft; then
        nft -c -f "$tmp" >/dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            msg_err "❌ nft 规则语法校验失败：未应用、未写入持久化文件。"
            rm -f "$tmp"
            return 1
        fi

        # 应用（只动自己的表）
        nft delete table ip nft_mgr_nat >/dev/null 2>&1 || true
        if ! nft -f "$tmp" >/dev/null 2>&1; then
            msg_err "❌ nft 应用失败：未写入持久化文件。"
            rm -f "$tmp"
            return 1
        fi
    else
        msg_err "❌ 未找到 nft 命令，无法应用规则。"
        rm -f "$tmp"
        return 1
    fi

    # 持久化写入（原子替换）
    mkdir -p "$NFT_MGR_DIR" 2>/dev/null || true
    if [[ -f "$NFT_MGR_CONF" ]]; then
        cp -a "$NFT_MGR_CONF" "${NFT_MGR_CONF}.bak.$(date +%s)" 2>/dev/null || true
    fi
    mv -f "$tmp" "$NFT_MGR_CONF"
    chmod 600 "$NFT_MGR_CONF" 2>/dev/null || true

    if have_cmd systemctl; then
        systemctl enable nft-mgr >/dev/null 2>&1 || true
    fi

    if [[ $has_rules -eq 1 ]]; then
        msg_ok "✅ 规则已原子化应用并持久化。"
    else
        msg_ok "✅ 当前无有效转发规则：已应用空表并持久化。"
    fi
    return 0
}

apply_rules() {
    with_lock apply_rules_impl
}

# --------------------------
# 流量格式化
# --------------------------
format_bytes() {
    local bytes="$1"
    if [[ -z "$bytes" || "$bytes" -eq 0 ]]; then
        echo "0 B"
    elif [ "$bytes" -lt 1024 ]; then
        echo "${bytes} B"
    elif [ "$bytes" -lt 1048576 ]; then
        echo "$(( bytes / 1024 )) KB"
    elif [ "$bytes" -lt 1073741824 ]; then
        echo "$(( bytes / 1048576 )) MB"
    elif [ "$bytes" -lt 1099511627776 ]; then
        awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
    else
        awk "BEGIN {printf \"%.2f TB\", $bytes/1099511627776}"
    fi
}

# --------------------------
# 新增转发
# --------------------------
port_in_use() {
    local port="$1"
    local proto="$2"
    proto="$(normalize_proto "$proto")"
    local used=1

    if have_cmd ss; then
        if [[ "$proto" == "tcp" || "$proto" == "both" ]]; then
            ss -lntH 2>/dev/null | awk '{print $4}' | awk -F: '{print $NF}' | grep -qx "$port" && used=0
        fi
        if [[ "$proto" == "udp" || "$proto" == "both" ]]; then
            ss -lnuH 2>/dev/null | awk '{print $4}' | awk -F: '{print $NF}' | grep -qx "$port" && used=0
        fi
    fi
    return $used
}

add_forward_impl() {
    local lport taddr tport proto tip

    read -rp "请输入本地监听端口 (1-65535): " lport
    is_port "$lport" || { msg_err "错误: 本地端口必须是 1-65535 的纯数字。"; sleep 2; return 1; }

    if grep -qE "^${lport}\|" "$CONFIG_FILE" 2>/dev/null; then
        msg_err "错误: 本地端口 $lport 已存在规则！请先删除旧规则。"
        sleep 2
        return 1
    fi

    echo -e "${CYAN}选择协议:${PLAIN}\n 1) TCP\n 2) UDP\n 3) TCP+UDP(默认)\n--------------------------------"
    read -rp "请选择 [1-3]: " psel
    case "$psel" in
        1) proto="tcp" ;;
        2) proto="udp" ;;
        3|"") proto="both" ;;
        *) proto="both" ;;
    esac

    if port_in_use "$lport" "$proto"; then
        msg_warn "⚠️ 检测到本机已有进程监听该端口（${lport}/${proto}）。继续添加转发会导致外部访问被 DNAT 劫持。"
        read -rp "仍要继续？[y/N]: " go
        [[ "$go" != "y" && "$go" != "Y" ]] && return 1
    fi

    read -rp "请输入目标地址 (IP 或 域名): " taddr
    [[ -z "$taddr" ]] && { msg_err "错误: 目标地址不能为空。"; sleep 2; return 1; }

    read -rp "请输入目标端口 (1-65535): " tport
    is_port "$tport" || { msg_err "错误: 目标端口必须是 1-65535 的纯数字。"; sleep 2; return 1; }

    msg_info "正在解析并验证目标地址..."
    tip="$(get_ip "$taddr")"
    [[ -z "$tip" ]] && { msg_err "错误: 解析失败，请检查域名或服务器网络/DNS。"; sleep 2; return 1; }

    # 先备份配置，保证失败可回滚
    local conf_bak
    conf_bak="$(mktemp /tmp/nftmgr-conf.XXXXXX)"
    cp -a "$CONFIG_FILE" "$conf_bak" 2>/dev/null || true

    echo "${lport}|${taddr}|${tport}|${tip}|${proto}" >> "$CONFIG_FILE"

    if ! apply_rules_impl; then
        # 回滚
        [[ -s "$conf_bak" ]] && mv -f "$conf_bak" "$CONFIG_FILE" || true
        msg_err "❌ 应用规则失败：已回滚本次新增配置。"
        sleep 2
        return 1
    fi
    rm -f "$conf_bak" 2>/dev/null || true

    manage_firewall "add" "$lport" "$proto" || true

    msg_ok "添加成功！映射路径: [本机] ${lport}/${proto} -> [目标] ${taddr}:${tport} (${tip})"
    sleep 2
    return 0
}

add_forward() {
    with_lock add_forward_impl
}

# --------------------------
# 流量看板与规则管理（删除）
# --------------------------
get_traffic_snapshot() {
    nft -a list table ip nft_mgr_nat 2>/dev/null || true
}

extract_bytes_by_comment() {
    local snapshot="$1"
    local comment="$2"
    echo "$snapshot" | grep -F "comment \"${comment}\"" | sed -n 's/.*bytes \([0-9]\+\).*/\1/p' | head -n 1
}

view_and_del_forward_impl() {
    clear
    if [[ ! -s "$CONFIG_FILE" ]]; then
        msg_warn "当前没有任何转发规则。"
        read -rp "按回车返回主菜单..."
        return 0
    fi

    local traffic_data
    traffic_data="$(get_traffic_snapshot)"

    local total_in=0
    local total_out=0

    echo -e "${CYAN}=========================== 实时流量看板 ===========================${PLAIN}"
    printf "%-4s | %-6s | %-5s | %-16s | %-6s | %-10s | %-10s\n" "序号" "本地" "协议" "目标地址" "目标" "接收(RX)" "发送(TX)"
    echo "--------------------------------------------------------------------"

    local i=1
    while IFS='|' read -r lp addr tp last_ip proto; do
        [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
        proto="$(normalize_proto "$proto")"
        is_port "$lp" || continue
        is_port "$tp" || continue

        local in_bytes out_bytes
        in_bytes="$(extract_bytes_by_comment "$traffic_data" "in_${lp}")"
        out_bytes="$(extract_bytes_by_comment "$traffic_data" "out_${lp}")"
        [[ -z "$in_bytes" ]] && in_bytes=0
        [[ -z "$out_bytes" ]] && out_bytes=0

        total_in=$((total_in + in_bytes))
        total_out=$((total_out + out_bytes))

        local in_str out_str
        in_str="$(format_bytes "$in_bytes")"
        out_str="$(format_bytes "$out_bytes")"

        local short_addr="${addr:0:15}"
        printf "%-4s | %-6s | %-5s | %-16s | %-6s | %-10s | %-10s\n" "$i" "$lp" "$proto" "$short_addr" "$tp" "$in_str" "$out_str"
        ((i++))
    done < "$CONFIG_FILE"

    echo "--------------------------------------------------------------------"
    echo -e "${CYAN}[ 全局总流量 ]  接收(RX): ${GREEN}$(format_bytes "$total_in")${CYAN}  |  发送(TX): ${YELLOW}$(format_bytes "$total_out")${PLAIN}"
    echo -e "${CYAN}====================================================================${PLAIN}"

    echo -e "\n${YELLOW}提示: 输入规则前面的【序号】即可删除，输入【0】或直接按回车返回。${PLAIN}"
    local action
    read -rp "请选择操作: " action

    if [[ -z "$action" || "$action" == "0" ]]; then
        return 0
    fi
    if ! [[ "$action" =~ ^[0-9]+$ ]]; then
        msg_err "输入无效，请输入正确的数字。"
        sleep 2
        return 1
    fi

    local total_lines
    total_lines="$(awk -F'|' 'BEGIN{c=0} $0!~/^\s*($|#)/{ if($1~/^[0-9]+$/ && $1>=1 && $1<=65535 && $3~/^[0-9]+$/ && $3>=1 && $3<=65535){c++}} END{print c+0}' "$CONFIG_FILE" 2>/dev/null)"
    if [[ "$action" -lt 1 || "$action" -gt "$total_lines" ]]; then
        msg_err "序号超出范围！"
        sleep 2
        return 1
    fi

    # 找到第 N 条【合法规则】所在行号（忽略空行/注释/非法行）
    local line_no
    line_no="$(awk -F'|' -v N="$action" 'BEGIN{c=0}
        $0!~/^\s*($|#)/{
            if($1~/^[0-9]+$/ && $1>=1 && $1<=65535 && $3~/^[0-9]+$/ && $3>=1 && $3<=65535){
                c++; if(c==N){print NR; exit}
            }
        }' "$CONFIG_FILE")"
    [[ -z "$line_no" ]] && { msg_err "删除失败：无法定位规则行。"; sleep 2; return 1; }

    local del_line del_port del_proto
    del_line="$(sed -n "${line_no}p" "$CONFIG_FILE")"
    del_port="$(echo "$del_line" | cut -d'|' -f1)"
    del_proto="$(echo "$del_line" | cut -d'|' -f5)"
    del_proto="$(normalize_proto "$del_proto")"

    # 先备份配置，保证失败可回滚
    local conf_bak
    conf_bak="$(mktemp /tmp/nftmgr-conf.XXXXXX)"
    cp -a "$CONFIG_FILE" "$conf_bak" 2>/dev/null || true

    sed -i "${line_no}d" "$CONFIG_FILE"

    if ! apply_rules_impl; then
        [[ -s "$conf_bak" ]] && mv -f "$conf_bak" "$CONFIG_FILE" || true
        msg_err "❌ 应用规则失败：已回滚本次删除操作。"
        sleep 2
        return 1
    fi
    rm -f "$conf_bak" 2>/dev/null || true

    manage_firewall "del" "$del_port" "$del_proto" || true

    msg_ok "已成功删除本地端口为 ${del_port}/${del_proto} 的转发规则。"
    sleep 2
    return 0
}

view_and_del_forward() {
    with_lock view_and_del_forward_impl
}

# --------------------------
# DDNS 追踪更新（域名 -> IP 变化）
# --------------------------
ddns_update_impl() {
    local changed=0
    local temp_file
    temp_file="$(mktemp /tmp/nftmgr-ddns.XXXXXX)"

    [[ -d "$LOG_DIR" ]] || mkdir -p "$LOG_DIR"
    local today_log="$LOG_DIR/$(date '+%Y-%m-%d').log"

    # 逐行读取，保留注释/空行；只更新合法规则行
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 空行
        if [[ -z "$line" ]]; then
            echo "" >> "$temp_file"
            continue
        fi
        # 注释
        if [[ "${line:0:1}" == "#" ]]; then
            echo "$line" >> "$temp_file"
            continue
        fi

        local lp addr tp last_ip proto
        IFS='|' read -r lp addr tp last_ip proto <<< "$line"
        proto="$(normalize_proto "$proto")"

        if ! is_port "$lp" || ! is_port "$tp" || [[ -z "$addr" ]]; then
            # 非法行：原样保留，避免误删/误改
            echo "$line" >> "$temp_file"
            continue
        fi

        local current_ip
        current_ip="$(get_ip "$addr")"

        if [[ -n "$current_ip" && "$current_ip" != "$last_ip" ]]; then
            echo "${lp}|${addr}|${tp}|${current_ip}|${proto}" >> "$temp_file"
            changed=1
            echo "[$(date '+%H:%M:%S')] 端口 ${lp}: ${addr} 变动 (${last_ip:-N/A} -> ${current_ip})" >> "$today_log"
        else
            # 统一写回规范格式（补齐 proto 字段）
            echo "${lp}|${addr}|${tp}|${last_ip}|${proto}" >> "$temp_file"
        fi
    done < "$CONFIG_FILE"

    mv -f "$temp_file" "$CONFIG_FILE"

    if [[ $changed -eq 1 ]]; then
        apply_rules_impl || true
    fi

    # 只保留最近 7 天日志
    find "$LOG_DIR" -type f -name "*.log" -mtime +7 -exec rm -f {} \; 2>/dev/null || true
}

ddns_update() {
    with_lock ddns_update_impl
}

# --------------------------
# 定时任务管理（DDNS）
# --------------------------
manage_cron() {
    clear
    echo -e "${GREEN}--- 管理定时监控 (DDNS 同步) ---${PLAIN}"
    echo "1. 自动添加定时任务 (每分钟检测)"
    echo "2. 一键删除定时任务"
    echo "3. 查看 DDNS 变动历史日志 (仅保留最近7天)"
    echo "0. 返回主菜单"
    echo "--------------------------------"
    local cron_choice
    read -rp "请选择操作 [0-3]: " cron_choice

    local SCRIPT_PATH="/usr/local/bin/${CMD_NAME}"

    case "$cron_choice" in
        1)
            if crontab -l 2>/dev/null | grep -q "${SCRIPT_PATH} --cron"; then
                msg_warn "定时任务已存在。"
                sleep 2
                return
            fi
            (crontab -l 2>/dev/null; echo "* * * * * ${SCRIPT_PATH} --cron > /dev/null 2>&1") | crontab - 2>/dev/null
            msg_ok "定时任务已添加！将自动检查 IP 并生成日志。"
            sleep 2
            ;;
        2)
            crontab -l 2>/dev/null | grep -v "${SCRIPT_PATH} --cron" | crontab - 2>/dev/null
            msg_warn "定时任务已清除。"
            sleep 2
            ;;
        3)
            clear
            if [[ -d "$LOG_DIR" ]] && ls "$LOG_DIR"/*.log >/dev/null 2>&1; then
                echo -e "${GREEN}--- 近 7 天 DDNS 变动日志（末20行） ---${PLAIN}"
                cat "$LOG_DIR"/*.log 2>/dev/null | tail -n 20
            else
                msg_warn "暂无 IP 变动记录。"
            fi
            echo ""
            read -rp "按回车键返回..."
            ;;
        0) return ;;
        *) msg_err "无效选项"; sleep 1 ;;
    esac
}

# --------------------------
# 安全自更新
# --------------------------
download_to() {
    local url="$1"
    local out="$2"
    if have_cmd curl; then
        curl -fsSL --retry 2 --connect-timeout 8 --max-time 120 "$url" -o "$out" >/dev/null 2>&1
    elif have_cmd wget; then
        wget -qO "$out" "$url" >/dev/null 2>&1
    else
        return 1
    fi
}

update_script() {
    clear
    echo -e "${GREEN}--- 脚本更新（安全模式） ---${PLAIN}"
    echo "1. GitHub 官方直连更新 (推荐海外机)"
    echo "2. GHProxy 代理更新 (推荐国内机)"
    echo "0. 取消并返回主菜单"
    echo "--------------------------------"
    local up_choice target_url
    read -rp "请选择更新线路 [0-2]: " up_choice

    case "$up_choice" in
        1) target_url="$RAW_URL" ;;
        2) target_url="$PROXY_URL" ;;
        0) return ;;
        *) msg_err "无效选项。"; sleep 1; return ;;
    esac

    msg_info "正在拉取最新代码..."
    local tmp
    tmp="$(mktemp /tmp/nftmgr-update.XXXXXX)"

    if ! download_to "$target_url" "$tmp" || [[ ! -s "$tmp" ]]; then
        msg_err "失败: 无法连接服务器或下载为空。"
        rm -f "$tmp"
        sleep 2
        return
    fi

    # 基本合法性校验
    if ! head -n 1 "$tmp" | grep -q "^#!/bin/bash"; then
        msg_err "失败: 文件内容非法（缺少 shebang）。"
        rm -f "$tmp"
        sleep 2
        return
    fi

    if ! bash -n "$tmp" >/dev/null 2>&1; then
        msg_err "失败: 新脚本语法校验失败，已中止替换。"
        rm -f "$tmp"
        sleep 2
        return
    fi

    # 原子替换
    local dest="/usr/local/bin/${CMD_NAME}"
    cp -a "$dest" "${dest}.bak.$(date +%s)" 2>/dev/null || true
    install -m 755 "$tmp" "${dest}.new" >/dev/null 2>&1 || { msg_err "失败: 写入失败。"; rm -f "$tmp"; return; }
    mv -f "${dest}.new" "$dest"
    rm -f "$tmp"

    msg_ok "✅ 更新成功！面板正在热重启..."
    sleep 1
    exec "$dest"
}

# --------------------------
# 清空规则
# --------------------------
clear_all_rules_impl() {
    if [[ ! -s "$CONFIG_FILE" ]]; then
        msg_warn "当前没有规则，无需清空。"
        sleep 1
        return 0
    fi

    msg_warn "⚠️ 将清空所有转发规则（并移除 ufw/firewalld 放行）。"
    read -rp "确认清空？[y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return 0

    while IFS='|' read -r lp addr tp last_ip proto; do
        [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
        is_port "$lp" || continue
        proto="$(normalize_proto "$proto")"
        manage_firewall "del" "$lp" "$proto" || true
    done < "$CONFIG_FILE"

    # 先备份配置，保证失败可回滚
    local conf_bak
    conf_bak="$(mktemp /tmp/nftmgr-conf.XXXXXX)"
    cp -a "$CONFIG_FILE" "$conf_bak" 2>/dev/null || true

    > "$CONFIG_FILE"
    if ! apply_rules_impl; then
        [[ -s "$conf_bak" ]] && mv -f "$conf_bak" "$CONFIG_FILE" || true
        msg_err "❌ 清空后应用规则失败：已回滚配置。"
        sleep 2
        return 1
    fi
    rm -f "$conf_bak" 2>/dev/null || true
    msg_ok "✅ 所有规则已清空。"
    sleep 2
}

clear_all_rules() {
    with_lock clear_all_rules_impl
}

# --------------------------
# 完全卸载
# --------------------------
uninstall_script_impl() {
    clear
    echo -e "${RED}--- 卸载 nftables 端口转发管理面板 ---${PLAIN}"
    read -rp "警告: 此操作将删除本脚本、规则配置、定时任务、systemd 服务，并移除本脚本创建的 nft 表。确认？[y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return 0

    # 删除防火墙放行
    while IFS='|' read -r lp addr tp last_ip proto; do
        [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
        is_port "$lp" || continue
        proto="$(normalize_proto "$proto")"
        manage_firewall "del" "$lp" "$proto" || true
    done < "$CONFIG_FILE"

    # 删除 nft 表（仅本脚本的表）
    nft delete table ip nft_mgr_nat >/dev/null 2>&1 || true

    # 删除 cron
    local SCRIPT_PATH="/usr/local/bin/${CMD_NAME}"
    crontab -l 2>/dev/null | grep -v "${SCRIPT_PATH} --cron" | crontab - 2>/dev/null || true

    # 删除 systemd 服务
    if have_cmd systemctl; then
        systemctl disable --now nft-mgr >/dev/null 2>&1 || true
        rm -f "$NFT_MGR_SERVICE" 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    # 删除持久化文件/日志/配置
    rm -f "$NFT_MGR_CONF" "$CONFIG_FILE" "$SETTINGS_FILE" "$SYSCTL_FILE" "$LOCK_FILE" 2>/dev/null || true
    rm -rf "$LOG_DIR" 2>/dev/null || true

    msg_ok "✅ 卸载完成。"
    # 删除自身
    rm -f "/usr/local/bin/${CMD_NAME}" 2>/dev/null || true
    exit 0
}

uninstall_script() {
    with_lock uninstall_script_impl
}

# --------------------------
# 主菜单
# --------------------------
main_menu() {
    clear
    echo -e "${GREEN}==========================================${PLAIN}"
    echo -e "${GREEN}     nftables 端口转发管理面板 (Pro)      ${PLAIN}"
    echo -e "${GREEN}==========================================${PLAIN}"
    echo "1. 开启 BBR + 转发 + 自启动 (稳定/性能)"
    echo "2. 新增端口转发 (支持域名/IP，支持TCP/UDP选择)"
    echo "3. 流量看板与规则管理 (查看/删除)"
    echo "4. 清空所有转发规则"
    echo "5. 管理 DDNS 定时监控与日志"
    echo "6. 从 GitHub 更新当前脚本 (安全更新)"
    echo "7. 一键完全卸载本脚本"
    echo "0. 退出面板"
    echo "------------------------------------------"
    local choice
    read -rp "请选择操作 [0-7]: " choice

    case "$choice" in
        1) optimize_system ;;
        2) add_forward ;;
        3) view_and_del_forward ;;
        4) clear_all_rules ;;
        5) manage_cron ;;
        6) update_script ;;
        7) uninstall_script ;;
        0) exit 0 ;;
        *) msg_err "无效选项"; sleep 1 ;;
    esac
}

# --------------------------
# 入口
# --------------------------
require_root
check_env
install_global_command

# cron 模式
if [[ "${1:-}" == "--cron" ]]; then
    ddns_update
    exit 0
fi

# 菜单循环
while true; do
    main_menu
done
