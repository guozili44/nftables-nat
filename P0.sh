cat << 'EOF' > /root/nft-forward.sh
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ETC_BASE="${ETC_BASE:-/etc}"
CONF_DIR="${CONF_DIR:-$ETC_BASE/nftables.d}"
CONF_FILE="${CONF_FILE:-$CONF_DIR/relay-forward.nft}"
STATE_FILE="${STATE_FILE:-$ETC_BASE/nftables-forward.state}"
SERVICE_FILE="${SERVICE_FILE:-$ETC_BASE/systemd/system/nft-relay-forward.service}"
SYSCTL_FORWARD_FILE="${SYSCTL_FORWARD_FILE:-$ETC_BASE/sysctl.d/99-nft-relay-forward.conf}"
SYSCTL_OPT_FILE="${SYSCTL_OPT_FILE:-$ETC_BASE/sysctl.d/99-nft-relay-extreme.conf}"
SCRIPT_SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

RELAY_LAN_IP4=""
RELAY_LAN_IP6=""
ENABLE_FLOWTABLE=""
RULE_FAMILIES=()
RULE_IN_PORTS=()
RULE_DEST_IPS=()
RULE_DEST_PORTS=()
RULE_NOTES=()

pause(){ read -r -p "按回车继续..." _ || true; }

msg(){ printf '%s\n' "$*"; }
err(){ printf '❌ %s\n' "$*" >&2; }
ok(){ printf '✅ %s\n' "$*"; }
warn(){ printf '⚠️  %s\n' "$*"; }

need_root(){
    [ "${EUID:-$(id -u)}" -eq 0 ] || { err "请使用 root 运行本脚本。"; exit 1; }
}

ensure_dirs(){
    mkdir -p "$CONF_DIR" "$(dirname "$STATE_FILE")" "$(dirname "$SYSCTL_FORWARD_FILE")"
}

have_cmd(){ command -v "$1" >/dev/null 2>&1; }

require_nft(){
    have_cmd nft || { err "未检测到 nft 命令，请先执行“安装 nftables”。"; return 1; }
}

trim(){
    local s="$1"
    s="${s#${s%%[![:space:]]*}}"
    s="${s%${s##*[![:space:]]}}"
    printf '%s' "$s"
}

sanitize_note(){
    local note="$1"
    note="${note//$'\r'/ }"
    note="${note//$'\n'/ }"
    note="${note//$'\t'/ }"
    note="$(trim "$note")"
    note="$(printf '%s' "$note" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177')"
    printf '%.120s' "$note"
}

valid_port(){
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_index(){
    [[ "$1" =~ ^[0-9]+$ ]]
}

valid_ipv4(){
    local ip="$1"
    local IFS=.
    local -a octets=()
    read -r -a octets <<< "$ip"
    [ "${#octets[@]}" -eq 4 ] || return 1
    local o
    for o in "${octets[@]}"; do
        [[ "$o" =~ ^[0-9]+$ ]] || return 1
        [ "$o" -ge 0 ] && [ "$o" -le 255 ] || return 1
    done
}

valid_ipv6(){
    local ip="$1"
    have_cmd python3 || return 1
    python3 - "$ip" <<'PY' >/dev/null 2>&1
import ipaddress, sys
try:
    ipaddress.IPv6Address(sys.argv[1])
except Exception:
    raise SystemExit(1)
PY
}

valid_domain(){
    [[ "$1" =~ ^[a-zA-Z0-9.-]+$ ]]
}

validate_ip_by_family(){
    local family="$1" ip="$2"
    case "$family" in
        4) valid_ipv4 "$ip" || valid_domain "$ip" ;;
        6) valid_ipv6 "$ip" || valid_domain "$ip" ;;
        *) return 1 ;;
    esac
}

get_default_iface(){
    local iface=""
    iface="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' || true)"
    if [ -z "$iface" ]; then
        iface="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' || true)"
    fi
    printf '%s' "$iface"
}

flowtable_supported(){
    have_cmd nft || return 1
    local iface tmp
    iface="$(get_default_iface)"
    [ -n "$iface" ] || return 1
    tmp="$(mktemp)"
    cat > "$tmp" <<EOF2
add table inet relay_probe
add flowtable inet relay_probe ft { hook ingress priority 0; devices = { $iface }; }
delete table inet relay_probe
EOF2
    if nft -c -f "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

flowtable_iface(){
    get_default_iface
}

default_flowtable_setting(){
    if flowtable_supported; then
        printf '1'
    else
        printf '0'
    fi
}

reset_state_vars(){
    RELAY_LAN_IP4=""
    RELAY_LAN_IP6=""
    ENABLE_FLOWTABLE=""
    RULE_FAMILIES=()
    RULE_IN_PORTS=()
    RULE_DEST_IPS=()
    RULE_DEST_PORTS=()
    RULE_NOTES=()
}

load_state(){
    reset_state_vars
    if [ ! -f "$STATE_FILE" ]; then
        ENABLE_FLOWTABLE="$(default_flowtable_setting)"
        return 0
    fi

    local kind a b c d e _rest
    while IFS=$'\t' read -r kind a b c d e _rest; do
        [ -n "${kind:-}" ] || continue
        case "$kind" in
            \#*) ;;
            relay_ip4) RELAY_LAN_IP4="${a:-}" ;;
            relay_ip6) RELAY_LAN_IP6="${a:-}" ;;
            enable_flowtable) ENABLE_FLOWTABLE="${a:-0}" ;;
            rule)
                RULE_FAMILIES+=("${a:-}")
                RULE_IN_PORTS+=("${b:-}")
                RULE_DEST_IPS+=("${c:-}")
                RULE_DEST_PORTS+=("${d:-}")
                RULE_NOTES+=("${e:-}")
                ;;
        esac
    done < "$STATE_FILE"

    [ -n "$ENABLE_FLOWTABLE" ] || ENABLE_FLOWTABLE="$(default_flowtable_setting)"
}

save_state(){
    ensure_dirs
    local tmp
    tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"
    {
        printf '# relay-forward state v2\n'
        printf 'relay_ip4\t%s\n' "$RELAY_LAN_IP4"
        printf 'relay_ip6\t%s\n' "$RELAY_LAN_IP6"
        printf 'enable_flowtable\t%s\n' "$ENABLE_FLOWTABLE"
        local i
        for i in "${!RULE_FAMILIES[@]}"; do
            printf 'rule\t%s\t%s\t%s\t%s\t%s\n' \
                "${RULE_FAMILIES[$i]}" \
                "${RULE_IN_PORTS[$i]}" \
                "${RULE_DEST_IPS[$i]}" \
                "${RULE_DEST_PORTS[$i]}" \
                "${RULE_NOTES[$i]}"
        done
    } > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

validate_state(){
    local i family in_port dip dport note

    [ -z "$RELAY_LAN_IP4" ] || valid_ipv4 "$RELAY_LAN_IP4" || { err "STATE 中的 IPv4 中转源地址不合法：$RELAY_LAN_IP4"; return 1; }
    if [ -n "$RELAY_LAN_IP6" ]; then
        valid_ipv6 "$RELAY_LAN_IP6" || { err "STATE 中的 IPv6 中转源地址不合法：$RELAY_LAN_IP6"; return 1; }
    fi
    case "$ENABLE_FLOWTABLE" in
        0|1) ;;
        *) err "STATE 中的 Flowtable 开关值非法：$ENABLE_FLOWTABLE"; return 1 ;;
    esac

    if [ "${#RULE_FAMILIES[@]}" -ne "${#RULE_IN_PORTS[@]}" ] || \
       [ "${#RULE_FAMILIES[@]}" -ne "${#RULE_DEST_IPS[@]}" ] || \
       [ "${#RULE_FAMILIES[@]}" -ne "${#RULE_DEST_PORTS[@]}" ] || \
       [ "${#RULE_FAMILIES[@]}" -ne "${#RULE_NOTES[@]}" ]; then
        err "STATE 数据损坏：规则字段数量不一致。"
        return 1
    fi

    for i in "${!RULE_FAMILIES[@]}"; do
        family="${RULE_FAMILIES[$i]}"
        in_port="${RULE_IN_PORTS[$i]}"
        dip="${RULE_DEST_IPS[$i]}"
        dport="${RULE_DEST_PORTS[$i]}"
        note="${RULE_NOTES[$i]}"

        case "$family" in
            4) [ -n "$RELAY_LAN_IP4" ] || { err "存在 IPv4 规则，但未配置 RELAY_LAN_IP4。"; return 1; } ;;
            6) [ -n "$RELAY_LAN_IP6" ] || { err "存在 IPv6 规则，但未配置 RELAY_LAN_IP6。"; return 1; } ;;
            *) err "规则 #$((i+1)) 的协议族非法：$family"; return 1 ;;
        esac

        valid_port "$in_port" || { err "规则 #$((i+1)) 的入口端口非法：$in_port"; return 1; }
        validate_ip_by_family "$family" "$dip" || { err "规则 #$((i+1)) 的目标 IP/域名非法：$dip"; return 1; }
        valid_port "$dport" || { err "规则 #$((i+1)) 的目标端口非法：$dport"; return 1; }

        note="$(sanitize_note "$note")"
        RULE_NOTES[$i]="$note"
    done

    return 0
}

ensure_unique_port(){
    local family="$1" in_port="$2" skip_idx="${3:-}"
    local i
    for i in "${!RULE_FAMILIES[@]}"; do
        [ -n "$skip_idx" ] && [ "$i" = "$skip_idx" ] && continue
        if [ "${RULE_FAMILIES[$i]}" = "$family" ] && [ "${RULE_IN_PORTS[$i]}" = "$in_port" ]; then
            return 1
        fi
    done
    return 0
}

write_forward_sysctl(){
    cat > "$SYSCTL_FORWARD_FILE" <<'EOF2'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF2
    if sysctl --system >/dev/null 2>&1; then
        ok "已启用 IPv4/IPv6 转发。"
    else
        warn "sysctl --system 执行时有返回错误，请手动检查内核参数是否全部生效。"
    fi
}

write_extreme_sysctl(){
    cat > "$SYSCTL_OPT_FILE" <<'EOF2'
fs.file-max = 2097152
fs.nr_open = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 262144
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.optmem_max = 25165824
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_max_syn_backlog = 262144
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432
net.ipv4.udp_rmem_min = 65536
net.ipv4.udp_wmem_min = 65536
net.netfilter.nf_conntrack_max = 4194304
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_generic_timeout = 120
vm.max_map_count = 1048576
vm.swappiness = 10
EOF2

    modprobe tcp_bbr 2>/dev/null || true
    modprobe nf_conntrack 2>/dev/null || modprobe ip_conntrack 2>/dev/null || true

    if sysctl --system >/dev/null 2>&1; then
        ok "极限性能参数已写入并刷新。"
    else
        warn "部分参数受限于内核环境未生效，已尽可能应用最佳配置。"
    fi
}

install_nftables(){
    clear
    ensure_dirs

    if ! have_cmd nft; then
        msg "正在安装 nftables..."
        if have_cmd apt; then
            apt update && apt install -y nftables
        elif have_cmd dnf; then
            dnf install -y nftables
        elif have_cmd yum; then
            yum install -y nftables
        elif have_cmd zypper; then
            zypper --non-interactive install nftables
        else
            err "未识别的包管理器，请手动安装 nftables。"
            pause
            return 1
        fi
    else
        ok "nftables 已安装。"
    fi

    write_forward_sysctl
    create_or_update_service >/dev/null 2>&1 || true

    if have_cmd systemctl; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable nft-relay-forward.service >/dev/null 2>&1 || true
    fi

    ok "nftables 环境准备完成。"
    pause
}

create_or_update_service(){
    have_cmd systemctl || return 0
    require_nft || return 1
    local nft_bin
    nft_bin="$(command -v nft)"
    mkdir -p "$(dirname "$SERVICE_FILE")"
    cat > "$SERVICE_FILE" <<EOF2
[Unit]
Description=Relay Forward nftables Rules
Wants=network-online.target
After=network-online.target
ConditionPathExists=$CONF_FILE

[Service]
Type=oneshot
ExecStart=/bin/sh -c '$nft_bin list table ip relay_nat4 >/dev/null 2>&1 && $nft_bin delete table ip relay_nat4 >/dev/null 2>&1 || true; $nft_bin list table ip6 relay_nat6 >/dev/null 2>&1 && $nft_bin delete table ip6 relay_nat6 >/dev/null 2>&1 || true; $nft_bin list table inet relay_filter >/dev/null 2>&1 && $nft_bin delete table inet relay_filter >/dev/null 2>&1 || true; exec $nft_bin -f $CONF_FILE'
ExecReload=/bin/sh -c '$nft_bin list table ip relay_nat4 >/dev/null 2>&1 && $nft_bin delete table ip relay_nat4 >/dev/null 2>&1 || true; $nft_bin list table ip6 relay_nat6 >/dev/null 2>&1 && $nft_bin delete table ip6 relay_nat6 >/dev/null 2>&1 || true; $nft_bin list table inet relay_filter >/dev/null 2>&1 && $nft_bin delete table inet relay_filter >/dev/null 2>&1 || true; exec $nft_bin -f $CONF_FILE'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF2
}

delete_runtime_tables(){
    require_nft || return 1
    nft list table ip relay_nat4 >/dev/null 2>&1 && nft delete table ip relay_nat4 >/dev/null 2>&1 || true
    nft list table ip6 relay_nat6 >/dev/null 2>&1 && nft delete table ip6 relay_nat6 >/dev/null 2>&1 || true
    nft list table inet relay_filter >/dev/null 2>&1 && nft delete table inet relay_filter >/dev/null 2>&1 || true
}

generate_nft_conf(){
    validate_state

    local has_v4=0 has_v6=0 i
    for i in "${!RULE_FAMILIES[@]}"; do
        case "${RULE_FAMILIES[$i]}" in
            4) has_v4=1 ;;
            6) has_v6=1 ;;
        esac
    done

    local ft_active=0 ft_iface=""
    if [ "$ENABLE_FLOWTABLE" = "1" ] && [ "${#RULE_FAMILIES[@]}" -gt 0 ] && flowtable_supported; then
        ft_active=1
        ft_iface="$(flowtable_iface)"
    fi

    printf '#!/usr/sbin/nft -f\n'
    printf '# relay-forward generated: %s\n\n' "$(date '+%F %T %z')"

    if [ "$has_v4" -eq 1 ]; then
        printf 'table ip relay_nat4 {\n'
        printf '    chain prerouting {\n'
        printf '        type nat hook prerouting priority -100; policy accept;\n'
        for i in "${!RULE_FAMILIES[@]}"; do
            [ "${RULE_FAMILIES[$i]}" = "4" ] || continue
            printf '        tcp dport %s dnat to %s:%s\n' "${RULE_IN_PORTS[$i]}" "${RULE_DEST_IPS[$i]}" "${RULE_DEST_PORTS[$i]}"
            printf '        udp dport %s dnat to %s:%s\n' "${RULE_IN_PORTS[$i]}" "${RULE_DEST_IPS[$i]}" "${RULE_DEST_PORTS[$i]}"
        done
        printf '    }\n\n'
        printf '    chain postrouting {\n'
        printf '        type nat hook postrouting priority 100; policy accept;\n'
        for i in "${!RULE_FAMILIES[@]}"; do
            [ "${RULE_FAMILIES[$i]}" = "4" ] || continue
            printf '        ip daddr %s tcp dport %s snat to %s\n' "${RULE_DEST_IPS[$i]}" "${RULE_DEST_PORTS[$i]}" "$RELAY_LAN_IP4"
            printf '        ip daddr %s udp dport %s snat to %s\n' "${RULE_DEST_IPS[$i]}" "${RULE_DEST_PORTS[$i]}" "$RELAY_LAN_IP4"
        done
        printf '    }\n'
        printf '}\n\n'
    fi

    if [ "$has_v6" -eq 1 ]; then
        printf 'table ip6 relay_nat6 {\n'
        printf '    chain prerouting {\n'
        printf '        type nat hook prerouting priority -100; policy accept;\n'
        for i in "${!RULE_FAMILIES[@]}"; do
            [ "${RULE_FAMILIES[$i]}" = "6" ] || continue
            printf '        tcp dport %s dnat to [%s]:%s\n' "${RULE_IN_PORTS[$i]}" "${RULE_DEST_IPS[$i]}" "${RULE_DEST_PORTS[$i]}"
            printf '        udp dport %s dnat to [%s]:%s\n' "${RULE_IN_PORTS[$i]}" "${RULE_DEST_IPS[$i]}" "${RULE_DEST_PORTS[$i]}"
        done
        printf '    }\n\n'
        printf '    chain postrouting {\n'
        printf '        type nat hook postrouting priority 100; policy accept;\n'
        for i in "${!RULE_FAMILIES[@]}"; do
            [ "${RULE_FAMILIES[$i]}" = "6" ] || continue
            printf '        ip6 daddr %s tcp dport %s snat to %s\n' "${RULE_DEST_IPS[$i]}" "${RULE_DEST_PORTS[$i]}" "$RELAY_LAN_IP6"
            printf '        ip6 daddr %s udp dport %s snat to %s\n' "${RULE_DEST_IPS[$i]}" "${RULE_DEST_PORTS[$i]}" "$RELAY_LAN_IP6"
        done
        printf '    }\n'
        printf '}\n\n'
    fi

    if [ "${#RULE_FAMILIES[@]}" -gt 0 ]; then
        printf 'table inet relay_filter {\n'
        if [ "$ft_active" = "1" ] && [ -n "$ft_iface" ]; then
            printf '    flowtable relay_ft {\n'
            printf '        hook ingress priority 0;\n'
            printf '        devices = { %s };\n' "$ft_iface"
            printf '    }\n\n'
        fi
        printf '    chain forward {\n'
        printf '        type filter hook forward priority 0; policy accept;\n'
        printf '        tcp flags syn tcp option maxseg size set rt mtu\n'
        if [ "$ft_active" = "1" ]; then
            printf '        ct state established,related flow offload @relay_ft\n'
        fi
        printf '    }\n'
        printf '}\n'
    fi
}

backup_conf_if_exists(){
    if [ -f "$CONF_FILE" ]; then
        cp -a "$CONF_FILE" "$CONF_FILE.bak.$(date +%F-%H%M%S)"
    fi
}

backup_state_snapshot(){
    if [ -f "$STATE_FILE" ]; then
        printf '1\n'
        cat "$STATE_FILE"
    else
        printf '0\n'
    fi
}

restore_state_snapshot(){
    local snapshot="$1"
    local existed first_line content
    first_line="$(printf '%s' "$snapshot" | sed -n '1p')"
    content="$(printf '%s' "$snapshot" | sed '1d')"
    if [ "$first_line" = "1" ]; then
        printf '%s\n' "$content" > "$STATE_FILE"
    else
        rm -f "$STATE_FILE"
    fi
    load_state
}

apply_generated_conf(){
    require_nft || return 1
    ensure_dirs
    validate_state

    local tmp backup restore_needed=0
    tmp="$(mktemp)"
    backup="$(mktemp)"
    
    # 【修复重点】：改为双引号，避免局部变量在结束时销毁引发 set -u 报错
    trap "rm -f '$tmp' '$backup'" RETURN

    generate_nft_conf > "$tmp"

    if ! nft -c -f "$tmp" >/dev/null 2>&1; then
        err "nft dry-run 校验失败，新配置未写入。"
        msg "你可以手动检查临时生成内容：$tmp"
        trap - RETURN
        rm -f "$backup"
        return 1
    fi

    if [ -f "$CONF_FILE" ]; then
        cp -a "$CONF_FILE" "$backup"
        restore_needed=1
    fi

    backup_conf_if_exists
    cp -f "$tmp" "$CONF_FILE"
    create_or_update_service >/dev/null 2>&1 || true

    delete_runtime_tables
    if nft -f "$CONF_FILE" >/dev/null 2>&1; then
        if have_cmd systemctl; then
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable nft-relay-forward.service >/dev/null 2>&1 || true
        fi
        ok "规则已通过 dry-run 校验并成功应用。"
        return 0
    fi

    err "新规则运行时加载失败，正在尝试回滚。"
    if [ "$restore_needed" = "1" ]; then
        cp -f "$backup" "$CONF_FILE"
        delete_runtime_tables
        nft -f "$CONF_FILE" >/dev/null 2>&1 || true
    else
        rm -f "$CONF_FILE"
        delete_runtime_tables
    fi
    return 1
}

configure_relay_ips(){
    clear
    load_state

    local ipv4 ipv6 old_state_snapshot
    old_state_snapshot="$(backup_state_snapshot)"
    msg "--- 配置中转源 IP（SNAT 地址）---"
    msg "当前 IPv4：${RELAY_LAN_IP4:-未设置}"
    msg "当前 IPv6：${RELAY_LAN_IP6:-未设置}"
    msg "说明：IPv4 规则必须配置 IPv4 中转源 IP；IPv6 规则必须配置 IPv6 中转源 IP。"
    msg "留空表示保持不变；输入 none 表示清空该项。"

    read -r -p "新的 IPv4 中转源 IP: " ipv4
    read -r -p "新的 IPv6 中转源 IP: " ipv6

    ipv4="$(trim "$ipv4")"
    ipv6="$(trim "$ipv6")"

    if [ -n "$ipv4" ]; then
        if [ "$ipv4" = "none" ]; then
            RELAY_LAN_IP4=""
        elif valid_ipv4 "$ipv4"; then
            RELAY_LAN_IP4="$ipv4"
        else
            err "IPv4 地址不合法。"
            pause
            return 1
        fi
    fi

    if [ -n "$ipv6" ]; then
        if [ "$ipv6" = "none" ]; then
            RELAY_LAN_IP6=""
        elif valid_ipv6 "$ipv6"; then
            RELAY_LAN_IP6="$ipv6"
        else
            err "IPv6 地址不合法，且本机需要安装 python3 用于校验 IPv6。"
            pause
            return 1
        fi
    fi

    save_state
    if apply_generated_conf; then
        ok "中转源 IP 已更新。"
    else
        restore_state_snapshot "$old_state_snapshot"
    fi
    pause
}

ensure_relay_ip_for_family(){
    local family="$1"
    local ip=""
    case "$family" in
        4)
            if [ -n "$RELAY_LAN_IP4" ]; then
                return 0
            fi
            read -r -p "未配置 IPv4 中转源 IP，请现在输入: " ip
            ip="$(trim "$ip")"
            valid_ipv4 "$ip" || { err "IPv4 中转源 IP 不合法。"; return 1; }
            RELAY_LAN_IP4="$ip"
            ;;
        6)
            if [ -n "$RELAY_LAN_IP6" ]; then
                return 0
            fi
            read -r -p "未配置 IPv6 中转源 IP，请现在输入: " ip
            ip="$(trim "$ip")"
            valid_ipv6 "$ip" || { err "IPv6 中转源 IP 不合法，且本机需要安装 python3 用于校验 IPv6。"; return 1; }
            RELAY_LAN_IP6="$ip"
            ;;
        *)
            err "未知的地址族：$family"
            return 1
            ;;
    esac
}

add_forward(){
    clear
    require_nft || { pause; return 1; }
    load_state

    local family in_port dip dport note old_state_snapshot
    old_state_snapshot="$(backup_state_snapshot)"
    msg "--- 添加转发规则 ---"
    msg "4 = IPv4，6 = IPv6"
    read -r -p "地址族 [4/6] (默认 4): " family
    family="$(trim "$family")"
    [ -n "$family" ] || family="4"

    case "$family" in
        4|6) ;;
        *) err "地址族只能是 4 或 6。"; pause; return 1 ;;
    esac

    ensure_relay_ip_for_family "$family" || { pause; return 1; }

    read -r -p "入口端口: " in_port
    read -r -p "目标 IP或域名: " dip
    read -r -p "目标端口: " dport
    read -r -p "备注（可选）: " note

    in_port="$(trim "$in_port")"
    dip="$(trim "$dip")"
    dport="$(trim "$dport")"
    note="$(sanitize_note "$note")"

    valid_port "$in_port" || { err "入口端口非法。"; pause; return 1; }
    validate_ip_by_family "$family" "$dip" || { err "目标 IP 或域名非法。"; pause; return 1; }
    valid_port "$dport" || { err "目标端口非法。"; pause; return 1; }
    ensure_unique_port "$family" "$in_port" || { err "同一地址族下该入口端口已存在规则。"; pause; return 1; }

    RULE_FAMILIES+=("$family")
    RULE_IN_PORTS+=("$in_port")
    RULE_DEST_IPS+=("$dip")
    RULE_DEST_PORTS+=("$dport")
    RULE_NOTES+=("$note")

    save_state
    if apply_generated_conf; then
        ok "已添加规则：IPv$family ${in_port} -> ${dip}:${dport} [${note}]"
    else
        restore_state_snapshot "$old_state_snapshot"
    fi
    pause
}

list_forward(){
    clear
    load_state

    msg "--- 当前转发规则 ---"
    msg "IPv4 中转源 IP：${RELAY_LAN_IP4:-未设置}"
    msg "IPv6 中转源 IP：${RELAY_LAN_IP6:-未设置}"

    if [ "$ENABLE_FLOWTABLE" = "1" ]; then
        if flowtable_supported; then
            msg "Flowtable：已开启（接口：$(flowtable_iface)）"
        else
            msg "Flowtable：已请求开启，但当前内核/接口不支持，运行时会自动跳过"
        fi
    else
        msg "Flowtable：已关闭"
    fi
    msg "----------------------------------------"

    if [ "${#RULE_FAMILIES[@]}" -eq 0 ]; then
        msg "暂无规则。"
    else
        local i
        for i in "${!RULE_FAMILIES[@]}"; do
            printf '%s. IPv%s %s -> %s:%s  [%s]\n' \
                "$((i+1))" \
                "${RULE_FAMILIES[$i]}" \
                "${RULE_IN_PORTS[$i]}" \
                "${RULE_DEST_IPS[$i]}" \
                "${RULE_DEST_PORTS[$i]}" \
                "${RULE_NOTES[$i]}"
        done
    fi

    msg "----------------------------------------"
    pause
}

delete_forward(){
    clear
    load_state

    local old_state_snapshot
    old_state_snapshot="$(backup_state_snapshot)"

    if [ "${#RULE_FAMILIES[@]}" -eq 0 ]; then
        msg "暂无可删除的规则。"
        pause
        return 0
    fi

    msg "--- 删除转发规则 ---"
    local i idx
    for i in "${!RULE_FAMILIES[@]}"; do
        printf '%s. IPv%s %s -> %s:%s  [%s]\n' \
            "$((i+1))" \
            "${RULE_FAMILIES[$i]}" \
            "${RULE_IN_PORTS[$i]}" \
            "${RULE_DEST_IPS[$i]}" \
            "${RULE_DEST_PORTS[$i]}" \
            "${RULE_NOTES[$i]}"
    done
    printf '0. 返回\n'
    printf '%s\n' '----------------------------------------'
    read -r -p "请输入要删除的序号: " idx
    idx="$(trim "$idx")"

    [ -n "$idx" ] || { msg "已取消。"; pause; return 0; }
    valid_index "$idx" || { err "序号必须是数字。"; pause; return 1; }
    [ "$idx" -eq 0 ] && return 0
    idx=$((idx - 1))

    if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#RULE_FAMILIES[@]}" ]; then
        err "序号超出范围。"
        pause
        return 1
    fi

    unset 'RULE_FAMILIES[idx]' 'RULE_IN_PORTS[idx]' 'RULE_DEST_IPS[idx]' 'RULE_DEST_PORTS[idx]' 'RULE_NOTES[idx]'
    RULE_FAMILIES=("${RULE_FAMILIES[@]}")
    RULE_IN_PORTS=("${RULE_IN_PORTS[@]}")
    RULE_DEST_IPS=("${RULE_DEST_IPS[@]}")
    RULE_DEST_PORTS=("${RULE_DEST_PORTS[@]}")
    RULE_NOTES=("${RULE_NOTES[@]}")

    save_state
    if apply_generated_conf; then
        ok "规则已删除。"
    else
        restore_state_snapshot "$old_state_snapshot"
    fi
    pause
}

toggle_flowtable(){
    clear
    require_nft || { pause; return 1; }
    load_state

    local old_state_snapshot
    old_state_snapshot="$(backup_state_snapshot)"

    if [ "$ENABLE_FLOWTABLE" = "1" ]; then
        ENABLE_FLOWTABLE="0"
        save_state
        if apply_generated_conf; then
            ok "Flowtable 加速已关闭。"
        else
            restore_state_snapshot "$old_state_snapshot"
        fi
        pause
        return 0
    fi

    if ! flowtable_supported; then
        err "当前内核、nftables 或默认出口接口不支持 Flowtable。"
        pause
        return 1
    fi

    ENABLE_FLOWTABLE="1"
    save_state
    if apply_generated_conf; then
        ok "Flowtable 加速已开启。"
    else
        restore_state_snapshot "$old_state_snapshot"
    fi
    pause
}

optimize_system_extreme(){
    clear
    msg "--- 极限性能调优 ---"
    msg "将写入高并发、高吞吐优先的系统参数。"
    msg "这会尽可能把转发相关上限调高；部分参数可能因内核/内存限制被拒绝。"
    read -r -p "确认应用极限性能参数？[y/N]: " pick
    case "$pick" in
        y|Y) ;;
        *) msg "已取消。"; pause; return 0 ;;
    esac

    write_forward_sysctl
    write_extreme_sysctl
    ok "极限性能参数处理完成。"
    pause
}

uninstall_script(){
    clear
    msg "⚠️  这将只删除本脚本创建的独立资源，不会清空全局 nft ruleset。"
    msg "将执行以下操作："
    msg "  1) 删除本脚本创建的 nft 表（relay_nat4 / relay_nat6 / relay_filter）"
    msg "  2) 删除本脚本的独立配置和状态文件"
    msg "  3) 删除本脚本创建的 sysctl 文件"
    msg "  4) 删除并停用 nft-relay-forward.service"
    msg "  5) 删除当前脚本文件"
    read -r -p "确认继续卸载？[y/N]: " confirm
    case "$confirm" in
        y|Y) ;;
        *) msg "已取消卸载。"; pause; return 0 ;;
    esac

    if have_cmd systemctl; then
        systemctl disable --now nft-relay-forward.service >/dev/null 2>&1 || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    if have_cmd nft; then
        delete_runtime_tables || true
    fi

    rm -f "$CONF_FILE" "$STATE_FILE" "$SERVICE_FILE" "$SYSCTL_FORWARD_FILE" "$SYSCTL_OPT_FILE"
    sysctl --system >/dev/null 2>&1 || true

    ok "已卸载本脚本创建的规则与配置。"
    msg "正在删除脚本本体..."
    rm -f "$SCRIPT_SELF"
    exit 0
}

show_menu(){
    clear
    printf '%s\n' '========== nftables 转发管理 =========='
    printf '%s\n' '1) 安装 / 检查 nftables 环境'
    printf '%s\n' '2) 配置中转源 IP（IPv4/IPv6）'
    printf '%s\n' '3) 添加转发规则'
    printf '%s\n' '4) 删除转发规则'
    printf '%s\n' '5) 查看当前规则'
    printf '%s\n' '6) 切换 Flowtable 加速'
    printf '%s\n' '7) 应用极限性能调优'
    printf '%s\n' '8) 卸载本脚本'
    printf '%s\n' '0) 退出'
    printf '%s\n' '======================================'
}

main(){
    need_root
    while true; do
        show_menu
        read -r -p '请选择: ' choice
        case "$(trim "$choice")" in
            1) install_nftables ;;
            2) configure_relay_ips ;;
            3) add_forward ;;
            4) delete_forward ;;
            5) list_forward ;;
            6) toggle_flowtable ;;
            7) optimize_system_extreme ;;
            8) uninstall_script ;;
            0) exit 0 ;;
            *) err '无效选项。'; pause ;;
        esac
    done
}

if [ "${RELAY_NO_MENU:-0}" != "1" ]; then
    main
fi
EOF

chmod +x /root/nft-forward.sh
bash /root/nft-forward.sh
