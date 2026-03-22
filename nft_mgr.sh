cat << 'EOF' > /root/nf.sh
#!/usr/bin/env bash

# ==========================================
# nftables 端口转发管理面板 (Pro Max)
# - 独立表管理，不清空全局 ruleset
# - 配置与内核规则分离提交，避免状态分叉
# - IPv4 / IPv6 双栈转发
# - Flowtable / DDNS 开关与状态显示
# - 先 dry-run，再原子切换
# ==========================================

set -o pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# --------------------------
# 可配置常量
# --------------------------
CMD_NAME="nf"
CONFIG_FILE="/etc/nft_forward_list.conf"
SETTINGS_FILE="/etc/nft_forward_settings.conf"
NFT_MGR_DIR="/etc/nftables.d"
NFT_RUNTIME_CONF="${NFT_MGR_DIR}/nft_mgr_runtime.conf"
NFT_MGR_SERVICE="/etc/systemd/system/nft-mgr.service"
SYSCTL_FILE="/etc/sysctl.d/99-nft-mgr.conf"
LOG_DIR="/var/log/nft_ddns"
LOCK_FILE="/var/lock/nft_mgr.lock"

TABLE_V4="nft_mgr_nat_v4"
TABLE_V6="nft_mgr_nat_v6"
TABLE_INET="nft_mgr_fwd"

DEFAULT_FLOWTABLE_ENABLED="1"
DEFAULT_DDNS_ENABLED="1"

# --------------------------
# 颜色
# --------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

msg_ok()   { echo -e "${GREEN}$*${PLAIN}"; }
msg_warn() { echo -e "${YELLOW}$*${PLAIN}"; }
msg_err()  { echo -e "${RED}$*${PLAIN}"; }
msg_info() { echo -e "${CYAN}$*${PLAIN}"; }

pause() { read -rp "按回车继续..."; }

script_realpath() {
    local src="$0"
    if command -v realpath >/dev/null 2>&1; then
        realpath "$src"
    elif command -v readlink >/dev/null 2>&1; then
        readlink -f "$src" 2>/dev/null || printf '%s\n' "$src"
    else
        printf '%s\n' "$src"
    fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# --------------------------
# 设置读写
# --------------------------
ensure_state_dirs() {
    mkdir -p "$(dirname "$CONFIG_FILE")" "$NFT_MGR_DIR" "$LOG_DIR" 2>/dev/null || true
}

settings_get() {
    local key="$1" default_value="$2" value
    [[ -f "$SETTINGS_FILE" ]] || { printf '%s\n' "$default_value"; return 0; }
    value=$(awk -F= -v k="$key" '$1==k {print $2; found=1} END{if(!found) print "__NFTMGR_UNSET__"}' "$SETTINGS_FILE" 2>/dev/null | tail -n 1 | sed 's/[[:space:]]*$//')
    [[ "$value" == "__NFTMGR_UNSET__" || -z "$value" ]] && printf '%s\n' "$default_value" || printf '%s\n' "$value"
}

settings_set() {
    local key="$1" value="$2"
    local tmp
    ensure_state_dirs
    tmp="$(mktemp /tmp/nftmgr-settings.XXXXXX)"
    [[ -f "$SETTINGS_FILE" ]] && awk -F= -v k="$key" '$1!=k {print $0}' "$SETTINGS_FILE" > "$tmp" || :
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$SETTINGS_FILE"
}

load_settings() {
    FLOWTABLE_ENABLED="$(settings_get FLOWTABLE_ENABLED "$DEFAULT_FLOWTABLE_ENABLED")"
    DDNS_ENABLED="$(settings_get DDNS_ENABLED "$DEFAULT_DDNS_ENABLED")"
    [[ "$FLOWTABLE_ENABLED" == "1" ]] || FLOWTABLE_ENABLED="0"
    [[ "$DDNS_ENABLED" == "1" ]] || DDNS_ENABLED="0"
}

ensure_default_settings() {
    local current
    current=$(settings_get FLOWTABLE_ENABLED "")
    [[ -n "$current" ]] || settings_set FLOWTABLE_ENABLED "$DEFAULT_FLOWTABLE_ENABLED"
    current=$(settings_get DDNS_ENABLED "")
    [[ -n "$current" ]] || settings_set DDNS_ENABLED "$DEFAULT_DDNS_ENABLED"
}

# --------------------------
# 环境与锁
# --------------------------
require_root() {
    [[ $EUID -ne 0 ]] && msg_err "错误: 必须使用 root 权限运行!" && exit 1
}

check_env() {
    local hard_missing=0
    local hard_deps=(nft dig sysctl ip awk sed grep cut head tail sort mktemp chmod mv cp rm find)
    local soft_deps=(flock ss crontab systemctl ufw firewall-cmd modprobe)

    for c in "${hard_deps[@]}"; do
        if ! have_cmd "$c"; then
            msg_err "❌ 缺少必要命令: $c"
            hard_missing=1
        fi
    done

    for c in "${soft_deps[@]}"; do
        have_cmd "$c" || msg_warn "⚠️ 未找到可选命令: $c（对应功能将降级）"
    done

    [[ $hard_missing -eq 1 ]] && {
        msg_err "请先安装必要依赖后再运行。"
        exit 1
    }

    ensure_state_dirs
    [[ -f "$CONFIG_FILE" ]] || : > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    [[ -f "$SETTINGS_FILE" ]] || : > "$SETTINGS_FILE"
    chmod 600 "$SETTINGS_FILE" 2>/dev/null || true
}

with_lock() {
    if have_cmd flock; then
        (
            flock -n 200 || { msg_warn "⚠️ 任务繁忙：已有实例在运行。"; exit 99; }
            "$@"
        ) 200>"$LOCK_FILE"
        return $?
    fi
    "$@"
}

# --------------------------
# 命令安装（仅在需要 cron 时做）
# --------------------------
install_global_command_if_needed() {
    local self target
    self="$(script_realpath)"
    target="/usr/local/bin/${CMD_NAME}"
    [[ "$self" == "$target" ]] && return 0
    cp -f "$self" "$target" 2>/dev/null || return 1
    chmod +x "$target" 2>/dev/null || true
    return 0
}

# --------------------------
# 基础校验
# --------------------------
trim() {
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

normalize_proto() {
    local p="${1,,}"
    case "$p" in
        tcp|udp|both) printf '%s\n' "$p" ;;
        *) printf '%s\n' "both" ;;
    esac
}

is_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

is_ipv4() {
    local ip="$1" IFS=.
    local a b c d
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    read -r a b c d <<< "$ip"
    for n in "$a" "$b" "$c" "$d"; do
        [[ "$n" =~ ^[0-9]+$ ]] || return 1
        [ "$n" -ge 0 ] && [ "$n" -le 255 ] || return 1
    done
    return 0
}

is_ipv6_basic() {
    local ip="$1"
    [[ "$ip" == *:* ]] || return 1
    [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]]
}

is_ipv6() {
    local ip="$1" tmp rc
    is_ipv6_basic "$ip" || return 1
    tmp="$(mktemp /tmp/nftmgr-ip6check.XXXXXX)"
    cat > "$tmp" <<EOF_IP6
add table ip6 __nftmgr_ip6check
add chain ip6 __nftmgr_ip6check c { type nat hook prerouting priority -100; }
add rule ip6 __nftmgr_ip6check c tcp dport 1 dnat to [${ip}]:1
EOF_IP6
    nft -c -f "$tmp" >/dev/null 2>&1
    rc=$?
    rm -f "$tmp"
    return $rc
}

is_literal_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}

is_domain_like() {
    local v="$1"
    [[ -n "$v" ]] || return 1
    [[ "$v" != *[[:space:]]* ]] || return 1
    [[ "$v" != *"/"* ]] || return 1
    [[ "$v" != *"["* ]] || return 1
    [[ "$v" != *"]"* ]] || return 1
    return 0
}

note_addr_type() {
    local addr="$1"
    if is_ipv4 "$addr"; then
        printf '%s\n' "IPv4"
    elif is_ipv6 "$addr"; then
        printf '%s\n' "IPv6"
    else
        printf '%s\n' "域名"
    fi
}

# --------------------------
# 配置行读写与兼容旧格式
# 新格式: lport|addr|tport|last_v4|last_v6|proto
# 旧格式: lport|addr|tport|last_v4|proto
# --------------------------
RULE_LPORT=""
RULE_ADDR=""
RULE_TPORT=""
RULE_LAST_V4=""
RULE_LAST_V6=""
RULE_PROTO=""

parse_rule_line() {
    local line="$1"
    RULE_LPORT=""
    RULE_ADDR=""
    RULE_TPORT=""
    RULE_LAST_V4=""
    RULE_LAST_V6=""
    RULE_PROTO=""

    [[ -z "$line" || "${line:0:1}" == "#" ]] && return 1

    local f1 f2 f3 f4 f5 f6
    IFS='|' read -r f1 f2 f3 f4 f5 f6 <<< "$line"
    [[ -n "$f6" ]] || {
        RULE_LPORT="$f1"
        RULE_ADDR="$f2"
        RULE_TPORT="$f3"
        RULE_LAST_V4="$f4"
        RULE_LAST_V6=""
        RULE_PROTO="$(normalize_proto "$f5")"
        return 0
    }

    RULE_LPORT="$f1"
    RULE_ADDR="$f2"
    RULE_TPORT="$f3"
    RULE_LAST_V4="$f4"
    RULE_LAST_V6="$f5"
    RULE_PROTO="$(normalize_proto "$f6")"
    return 0
}

emit_rule_line() {
    local lport="$1" addr="$2" tport="$3" last_v4="$4" last_v6="$5" proto="$6"
    printf '%s|%s|%s|%s|%s|%s\n' "$lport" "$addr" "$tport" "$last_v4" "$last_v6" "$(normalize_proto "$proto")"
}

rule_is_valid() {
    is_port "$RULE_LPORT" || return 1
    is_port "$RULE_TPORT" || return 1
    [[ -n "$RULE_ADDR" ]] || return 1
    return 0
}

has_domain_rules_in_file() {
    local file="$1" line
    while IFS= read -r line || [[ -n "$line" ]]; do
        parse_rule_line "$line" || continue
        rule_is_valid || continue
        if ! is_literal_ip "$RULE_ADDR"; then
            return 0
        fi
    done < "$file"
    return 1
}

# --------------------------
# DNS 解析
# --------------------------
pick_first_v4() {
    awk 'NF{print $0}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | awk -F. '($1<=255 && $2<=255 && $3<=255 && $4<=255)' | sort -u | head -n 1
}

pick_first_v6() {
    awk 'NF{print $0}' | grep ':' | sort -u | head -n 1
}

resolve_target_pair() {
    local addr="$1"
    RESOLVED_V4=""
    RESOLVED_V6=""

    if is_ipv4 "$addr"; then
        RESOLVED_V4="$addr"
        return 0
    fi
    if is_ipv6 "$addr"; then
        RESOLVED_V6="$addr"
        return 0
    fi

    is_domain_like "$addr" || return 1

    RESOLVED_V4="$(dig +time=2 +tries=1 +short A "$addr" 2>/dev/null | pick_first_v4)"
    RESOLVED_V6="$(dig +time=2 +tries=1 +short AAAA "$addr" 2>/dev/null | pick_first_v6)"

    [[ -n "$RESOLVED_V4" || -n "$RESOLVED_V6" ]]
}

# --------------------------
# DDNS / 调度
# --------------------------
cron_entry() {
    printf '%s\n' "*/5 * * * * /usr/local/bin/${CMD_NAME} --cron > /dev/null 2>&1"
}

cron_is_enabled() {
    have_cmd crontab || return 1
    crontab -l 2>/dev/null | grep -Fqx "$(cron_entry)"
}

remove_legacy_cron_entries() {
    have_cmd crontab || return 0
    local cur
    cur="$(crontab -l 2>/dev/null || true)"
    [[ -n "$cur" ]] || return 0
    printf '%s\n' "$cur" \
        | grep -vE '(^|[[:space:]])(/usr/local/bin/(nf|nftmgr)|(nf|nftmgr))[[:space:]]+--cron([[:space:]]|$)' \
        | crontab - 2>/dev/null || true
}

ensure_ddns_scheduler_state() {
    load_settings
    have_cmd crontab || return 0
    remove_legacy_cron_entries

    if [[ "$DDNS_ENABLED" == "1" ]] && has_domain_rules_in_file "$CONFIG_FILE"; then
        install_global_command_if_needed || {
            msg_warn "⚠️ 无法安装 /usr/local/bin/${CMD_NAME}，DDNS 定时任务未启用。"
            return 1
        }
        if ! cron_is_enabled; then
            (crontab -l 2>/dev/null; cron_entry) | crontab - 2>/dev/null || true
        fi
    else
        if cron_is_enabled; then
            crontab -l 2>/dev/null | grep -Fvx "$(cron_entry)" | crontab - 2>/dev/null || true
        fi
    fi
    return 0
}

# --------------------------
# 防火墙放行
# --------------------------
firewall_backend() {
    if have_cmd ufw && ufw status 2>/dev/null | grep -qw active; then
        printf '%s\n' "ufw"
        return 0
    fi
    if have_cmd firewall-cmd && have_cmd systemctl && systemctl is-active --quiet firewalld 2>/dev/null; then
        printf '%s\n' "firewalld"
        return 0
    fi
    printf '%s\n' "none"
}

manage_firewall() {
    local action="$1" port="$2" proto
    proto="$(normalize_proto "$3")"

    case "$(firewall_backend)" in
        ufw)
            if [[ "$action" == "add" ]]; then
                [[ "$proto" == "tcp" || "$proto" == "both" ]] && ufw allow "$port"/tcp >/dev/null 2>&1 || true
                [[ "$proto" == "udp" || "$proto" == "both" ]] && ufw allow "$port"/udp >/dev/null 2>&1 || true
            else
                [[ "$proto" == "tcp" || "$proto" == "both" ]] && ufw --force delete allow "$port"/tcp >/dev/null 2>&1 || true
                [[ "$proto" == "udp" || "$proto" == "both" ]] && ufw --force delete allow "$port"/udp >/dev/null 2>&1 || true
            fi
            ;;
        firewalld)
            if [[ "$action" == "add" ]]; then
                [[ "$proto" == "tcp" || "$proto" == "both" ]] && firewall-cmd --add-port="${port}/tcp" --permanent >/dev/null 2>&1 || true
                [[ "$proto" == "udp" || "$proto" == "both" ]] && firewall-cmd --add-port="${port}/udp" --permanent >/dev/null 2>&1 || true
            else
                [[ "$proto" == "tcp" || "$proto" == "both" ]] && firewall-cmd --remove-port="${port}/tcp" --permanent >/dev/null 2>&1 || true
                [[ "$proto" == "udp" || "$proto" == "both" ]] && firewall-cmd --remove-port="${port}/udp" --permanent >/dev/null 2>&1 || true
            fi
            firewall-cmd --reload >/dev/null 2>&1 || true
            ;;
        *)
            ;;
    esac
}

# --------------------------
# 系统调优 / 转发
# --------------------------
sysctl_set_kv() {
    local key="$1" value="$2"
    mkdir -p /etc/sysctl.d 2>/dev/null || true
    touch "$SYSCTL_FILE" 2>/dev/null || true
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$SYSCTL_FILE" 2>/dev/null; then
        sed -i "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|g" "$SYSCTL_FILE"
    else
        printf '%s = %s\n' "$key" "$value" >> "$SYSCTL_FILE"
    fi
}

apply_sysctl_file() {
    sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1
}

ensure_forwarding() {
    sysctl_set_kv "net.ipv4.ip_forward" "1"
    sysctl_set_kv "net.ipv6.conf.all.forwarding" "1"
    apply_sysctl_file >/dev/null 2>&1 || true
}

bbr_available() {
    sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr
}

optimize_system() {
    clear
    echo -e "${GREEN}--- 系统优化 (极限性能版) ---${PLAIN}"
    echo "将写入高并发、队列、连接跟踪、BBR 等极限参数。"
    read -rp "确认应用？[y/N]: " pick
    [[ "$pick" =~ ^[Yy]$ ]] || return 0

    have_cmd modprobe && {
        modprobe nf_conntrack 2>/dev/null || modprobe ip_conntrack 2>/dev/null || true
        modprobe tcp_bbr 2>/dev/null || true
        modprobe nft_flow_offload 2>/dev/null || true
    }

    sysctl_set_kv "net.ipv4.ip_forward" "1"
    sysctl_set_kv "net.ipv6.conf.all.forwarding" "1"

    if bbr_available; then
        sysctl_set_kv "net.core.default_qdisc" "fq"
        sysctl_set_kv "net.ipv4.tcp_congestion_control" "bbr"
    else
        msg_warn "⚠️ 当前内核未检测到 BBR，已跳过 BBR。"
    fi

    sysctl_set_kv "fs.file-max" "2097152"
    sysctl_set_kv "fs.inotify.max_user_instances" "8192"
    sysctl_set_kv "fs.inotify.max_user_watches" "1048576"
    sysctl_set_kv "net.core.somaxconn" "65535"
    sysctl_set_kv "net.core.netdev_max_backlog" "262144"
    sysctl_set_kv "net.core.optmem_max" "25165824"
    sysctl_set_kv "net.ipv4.ip_local_port_range" "1024 65535"
    sysctl_set_kv "net.ipv4.tcp_max_syn_backlog" "262144"
    sysctl_set_kv "net.ipv4.tcp_fin_timeout" "10"
    sysctl_set_kv "net.ipv4.tcp_keepalive_time" "600"
    sysctl_set_kv "net.ipv4.tcp_keepalive_intvl" "30"
    sysctl_set_kv "net.ipv4.tcp_keepalive_probes" "5"
    sysctl_set_kv "net.ipv4.tcp_mtu_probing" "1"
    sysctl_set_kv "net.ipv4.tcp_slow_start_after_idle" "0"
    sysctl_set_kv "net.ipv4.tcp_tw_reuse" "1"
    sysctl_set_kv "net.netfilter.nf_conntrack_max" "2097152"
    sysctl_set_kv "net.netfilter.nf_conntrack_buckets" "524288"
    sysctl_set_kv "net.netfilter.nf_conntrack_tcp_timeout_established" "7200"
    sysctl_set_kv "net.netfilter.nf_conntrack_tcp_timeout_time_wait" "30"
    sysctl_set_kv "vm.max_map_count" "1048576"

    if apply_sysctl_file; then
        msg_ok "✅ 极限系统调优已应用。"
    else
        msg_warn "⚠️ sysctl 部分参数应用失败，请手动检查 ${SYSCTL_FILE}。"
    fi
    sleep 2
}

# --------------------------
# Flowtable 探测
# --------------------------
flowtable_iface_list() {
    ip -o link show up 2>/dev/null \
        | awk -F': ' '{print $2}' \
        | sed 's/@.*//' \
        | grep -vE '^(lo|docker[0-9]*|veth.*|br-.*|virbr.*|cni.*|flannel.*|kube.*)$' \
        | sort -u
}

flowtable_devices_csv() {
    local devices line first=1 out=""
    devices="$(flowtable_iface_list)"
    [[ -n "$devices" ]] || return 1
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ $first -eq 1 ]]; then
            out="$line"
            first=0
        else
            out+=", $line"
        fi
    done <<< "$devices"
    [[ -n "$out" ]] || return 1
    printf '%s\n' "$out"
}

flowtable_supported() {
    local devices tmp rc
    load_settings
    [[ "$FLOWTABLE_ENABLED" == "1" ]] || return 1

    devices="$(flowtable_devices_csv)" || return 1
    tmp="$(mktemp /tmp/nftmgr-flowcheck.XXXXXX)"
    cat > "$tmp" <<EOF_FLOW
add table inet __nftmgr_flowcheck
add flowtable inet __nftmgr_flowcheck f { hook ingress priority 0; devices = { ${devices} }; }
add chain inet __nftmgr_flowcheck fwd { type filter hook forward priority 0; policy accept; }
add rule inet __nftmgr_flowcheck fwd meta l4proto { tcp, udp } flow offload @f
EOF_FLOW
    nft -c -f "$tmp" >/dev/null 2>&1
    rc=$?
    rm -f "$tmp"
    return $rc
}

flowtable_status_text() {
    load_settings
    if [[ "$FLOWTABLE_ENABLED" != "1" ]]; then
        printf '%s\n' "关闭"
        return 0
    fi
    if flowtable_supported; then
        printf '%s\n' "开启"
    else
        printf '%s\n' "开启(当前内核/接口不支持，运行时自动跳过)"
    fi
}

# --------------------------
# 运行时/持久化配置生成
# --------------------------
quote_nft_ipv6_target() {
    printf '[%s]' "$1"
}

emit_table_v4_body() {
    local file="$1" line
    echo "chain prerouting {"
    echo "    type nat hook prerouting priority -100; policy accept;"
    while IFS= read -r line || [[ -n "$line" ]]; do
        parse_rule_line "$line" || continue
        rule_is_valid || continue
        [[ -n "$RULE_LAST_V4" ]] || continue
        case "$RULE_PROTO" in
            tcp)  echo "    tcp dport ${RULE_LPORT} counter dnat to ${RULE_LAST_V4}:${RULE_TPORT}" ;;
            udp)  echo "    udp dport ${RULE_LPORT} counter dnat to ${RULE_LAST_V4}:${RULE_TPORT}" ;;
            both)
                echo "    tcp dport ${RULE_LPORT} counter dnat to ${RULE_LAST_V4}:${RULE_TPORT}"
                echo "    udp dport ${RULE_LPORT} counter dnat to ${RULE_LAST_V4}:${RULE_TPORT}"
                ;;
        esac
    done < "$file"
    echo "}"
    echo "chain postrouting {"
    echo "    type nat hook postrouting priority 100; policy accept;"
    while IFS= read -r line || [[ -n "$line" ]]; do
        parse_rule_line "$line" || continue
        rule_is_valid || continue
        [[ -n "$RULE_LAST_V4" ]] || continue
        case "$RULE_PROTO" in
            tcp)  echo "    ip daddr ${RULE_LAST_V4} tcp dport ${RULE_TPORT} counter masquerade" ;;
            udp)  echo "    ip daddr ${RULE_LAST_V4} udp dport ${RULE_TPORT} counter masquerade" ;;
            both)
                echo "    ip daddr ${RULE_LAST_V4} tcp dport ${RULE_TPORT} counter masquerade"
                echo "    ip daddr ${RULE_LAST_V4} udp dport ${RULE_TPORT} counter masquerade"
                ;;
        esac
    done < "$file"
    echo "}"
}

emit_table_v6_body() {
    local file="$1" line target
    echo "chain prerouting {"
    echo "    type nat hook prerouting priority -100; policy accept;"
    while IFS= read -r line || [[ -n "$line" ]]; do
        parse_rule_line "$line" || continue
        rule_is_valid || continue
        [[ -n "$RULE_LAST_V6" ]] || continue
        target="$(quote_nft_ipv6_target "$RULE_LAST_V6")"
        case "$RULE_PROTO" in
            tcp)  echo "    tcp dport ${RULE_LPORT} counter dnat to ${target}:${RULE_TPORT}" ;;
            udp)  echo "    udp dport ${RULE_LPORT} counter dnat to ${target}:${RULE_TPORT}" ;;
            both)
                echo "    tcp dport ${RULE_LPORT} counter dnat to ${target}:${RULE_TPORT}"
                echo "    udp dport ${RULE_LPORT} counter dnat to ${target}:${RULE_TPORT}"
                ;;
        esac
    done < "$file"
    echo "}"
    echo "chain postrouting {"
    echo "    type nat hook postrouting priority 100; policy accept;"
    while IFS= read -r line || [[ -n "$line" ]]; do
        parse_rule_line "$line" || continue
        rule_is_valid || continue
        [[ -n "$RULE_LAST_V6" ]] || continue
        case "$RULE_PROTO" in
            tcp)  echo "    ip6 daddr ${RULE_LAST_V6} tcp dport ${RULE_TPORT} counter masquerade" ;;
            udp)  echo "    ip6 daddr ${RULE_LAST_V6} udp dport ${RULE_TPORT} counter masquerade" ;;
            both)
                echo "    ip6 daddr ${RULE_LAST_V6} tcp dport ${RULE_TPORT} counter masquerade"
                echo "    ip6 daddr ${RULE_LAST_V6} udp dport ${RULE_TPORT} counter masquerade"
                ;;
        esac
    done < "$file"
    echo "}"
}

emit_table_inet_body() {
    local devices
    echo "chain forward {"
    echo "    type filter hook forward priority 0; policy accept;"
    echo "    tcp flags syn tcp option maxseg size set rt mtu"
    if flowtable_supported; then
        echo "    meta l4proto { tcp, udp } flow offload @f"
    fi
    echo "}"
}

runtime_table_ip() {
    local file="$1"
    echo "table ip ${TABLE_V4} {"
    emit_table_v4_body "$file"
    echo "}"
}

runtime_table_ip6() {
    local file="$1"
    echo "table ip6 ${TABLE_V6} {"
    emit_table_v6_body "$file"
    echo "}"
}

runtime_table_inet() {
    local file="$1" devices
    echo "table inet ${TABLE_INET} {"
    if flowtable_supported; then
        devices="$(flowtable_devices_csv)"
        echo "flowtable f {"
        echo "    hook ingress priority 0;"
        echo "    devices = { ${devices} };"
        echo "}"
    fi
    emit_table_inet_body "$file"
    echo "}"
}

build_runtime_conf() {
    local file="$1" out="$2"
    {
        echo "# nft-mgr runtime ruleset (generated at $(date '+%F %T'))"
        runtime_table_ip "$file"
        runtime_table_ip6 "$file"
        runtime_table_inet "$file"
    } > "$out"
    chmod 600 "$out" 2>/dev/null || true
}

write_transaction_table() {
    local family="$1" name="$2" temp_name="$3" body_func="$4" file="$5"
    if nft list table "$family" "$name" >/dev/null 2>&1; then
        echo "table ${family} ${temp_name} {"
        if [[ "$family" == "ip" ]]; then
            emit_table_v4_body "$file"
        elif [[ "$family" == "ip6" ]]; then
            emit_table_v6_body "$file"
        else
            if flowtable_supported; then
                local devices
                devices="$(flowtable_devices_csv)"
                echo "flowtable f {"
                echo "    hook ingress priority 0;"
                echo "    devices = { ${devices} };"
                echo "}"
            fi
            emit_table_inet_body "$file"
        fi
        echo "}"
        echo "delete table ${family} ${name}"
        echo "rename table ${family} ${temp_name} ${name}"
    else
        echo "table ${family} ${name} {"
        if [[ "$family" == "ip" ]]; then
            emit_table_v4_body "$file"
        elif [[ "$family" == "ip6" ]]; then
            emit_table_v6_body "$file"
        else
            if flowtable_supported; then
                local devices
                devices="$(flowtable_devices_csv)"
                echo "flowtable f {"
                echo "    hook ingress priority 0;"
                echo "    devices = { ${devices} };"
                echo "}"
            fi
            emit_table_inet_body "$file"
        fi
        echo "}"
    fi
}

build_transaction_conf() {
    local file="$1" out="$2"
    local suffix
    suffix="$(date +%s)_$$"
    {
        echo "# nft-mgr transaction ruleset (generated at $(date '+%F %T'))"
        write_transaction_table ip "$TABLE_V4" "${TABLE_V4}_new_${suffix}" emit_table_v4_body "$file"
        write_transaction_table ip6 "$TABLE_V6" "${TABLE_V6}_new_${suffix}" emit_table_v6_body "$file"
        write_transaction_table inet "$TABLE_INET" "${TABLE_INET}_new_${suffix}" emit_table_inet_body "$file"
    } > "$out"
    chmod 600 "$out" 2>/dev/null || true
}

# --------------------------
# 持久化服务（仅在成功应用后安装）
# --------------------------
ensure_nft_mgr_service() {
    have_cmd systemctl || return 0
    local nftbin
    nftbin="$(command -v nft 2>/dev/null || echo /usr/sbin/nft)"
    mkdir -p "$NFT_MGR_DIR" 2>/dev/null || true
    cat > "$NFT_MGR_SERVICE" <<EOF_SERVICE
[Unit]
Description=nftables Port Forwarding Manager (nf)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c '${nftbin} delete table inet ${TABLE_INET} >/dev/null 2>&1 || true; ${nftbin} delete table ip ${TABLE_V4} >/dev/null 2>&1 || true; ${nftbin} delete table ip6 ${TABLE_V6} >/dev/null 2>&1 || true; ${nftbin} -f ${NFT_RUNTIME_CONF}'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable nft-mgr >/dev/null 2>&1 || true
}

# --------------------------
# 原子提交：先校验，再切换，再写状态
# --------------------------
apply_candidate_rules() {
    local candidate_file="$1"
    local tx_tmp runtime_tmp check_err apply_err

    ensure_forwarding

    tx_tmp="$(mktemp /tmp/nftmgr-tx.XXXXXX)"
    runtime_tmp="$(mktemp /tmp/nftmgr-runtime.XXXXXX)"

    build_transaction_conf "$candidate_file" "$tx_tmp"
    build_runtime_conf "$candidate_file" "$runtime_tmp"

    check_err="$(nft -c -f "$tx_tmp" 2>&1)"
    if [[ $? -ne 0 ]]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || true
        {
            echo "[$(date '+%F %T')] nft dry-run error:"
            echo "$check_err"
        } > "${LOG_DIR}/last_nft_error.log"
        msg_err "❌ nft 规则校验失败，未应用。详情见 ${LOG_DIR}/last_nft_error.log"
        rm -f "$tx_tmp" "$runtime_tmp"
        return 1
    fi

    apply_err="$(nft -f "$tx_tmp" 2>&1)"
    if [[ $? -ne 0 ]]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || true
        {
            echo "[$(date '+%F %T')] nft apply error:"
            echo "$apply_err"
        } > "${LOG_DIR}/last_nft_error.log"
        msg_err "❌ nft 规则应用失败，原有内核规则未切换。详情见 ${LOG_DIR}/last_nft_error.log"
        rm -f "$tx_tmp" "$runtime_tmp"
        return 1
    fi

    mkdir -p "$NFT_MGR_DIR" 2>/dev/null || true
    mv -f "$runtime_tmp" "$NFT_RUNTIME_CONF"
    chmod 600 "$NFT_RUNTIME_CONF" 2>/dev/null || true
    mv -f "$candidate_file" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    rm -f "$tx_tmp"

    ensure_nft_mgr_service
    if have_cmd systemctl; then
        systemctl enable nft-mgr >/dev/null 2>&1 || true
    fi
    ensure_ddns_scheduler_state >/dev/null 2>&1 || true
    return 0
}

apply_rules_current() {
    local candidate
    candidate="$(mktemp /tmp/nftmgr-current.XXXXXX)"
    cp -a "$CONFIG_FILE" "$candidate" 2>/dev/null || : > "$candidate"
    apply_candidate_rules "$candidate"
}

# --------------------------
# 规则辅助
# --------------------------
port_rule_exists() {
    local file="$1" port="$2" line
    while IFS= read -r line || [[ -n "$line" ]]; do
        parse_rule_line "$line" || continue
        rule_is_valid || continue
        [[ "$RULE_LPORT" == "$port" ]] && return 0
    done < "$file"
    return 1
}

port_in_use() {
    local port="$1" proto="$2"
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

rule_count() {
    local file="$1" line count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        parse_rule_line "$line" || continue
        rule_is_valid || continue
        count=$((count + 1))
    done < "$file"
    printf '%s\n' "$count"
}

get_rule_line_number_by_index() {
    local file="$1" want="$2" line nr=0 idx=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        nr=$((nr + 1))
        parse_rule_line "$line" || continue
        rule_is_valid || continue
        idx=$((idx + 1))
        if [[ "$idx" == "$want" ]]; then
            printf '%s\n' "$nr"
            return 0
        fi
    done < "$file"
    return 1
}

# --------------------------
# 新增规则
# --------------------------
add_forward_impl() {
    local lport taddr tport proto psel tmp_candidate

    read -rp "请输入本地监听端口 (1-65535): " lport
    is_port "$lport" || { msg_err "错误: 本地端口必须是 1-65535 的纯数字。"; sleep 2; return 1; }

    if port_rule_exists "$CONFIG_FILE" "$lport"; then
        msg_err "错误: 本地端口 ${lport} 已存在规则，请先删除旧规则。"
        sleep 2
        return 1
    fi

    echo -e "${CYAN}选择协议:${PLAIN}\n 1) TCP\n 2) UDP\n 3) TCP+UDP(默认)\n--------------------------------"
    read -rp "请选择 [1-3]: " psel
    case "$psel" in
        1) proto="tcp" ;;
        2) proto="udp" ;;
        *) proto="both" ;;
    esac

    if port_in_use "$lport" "$proto"; then
        msg_warn "⚠️ 检测到本机已有进程监听 ${lport}/${proto}，外部访问可能被 DNAT 劫持。"
        read -rp "仍要继续？[y/N]: " go
        [[ "$go" =~ ^[Yy]$ ]] || return 1
    fi

    read -rp "请输入目标地址 (IPv4 / IPv6 / 域名): " taddr
    taddr="$(printf '%s' "$taddr" | trim)"
    [[ -n "$taddr" ]] || { msg_err "错误: 目标地址不能为空。"; sleep 2; return 1; }

    read -rp "请输入目标端口 (1-65535): " tport
    is_port "$tport" || { msg_err "错误: 目标端口必须是 1-65535 的纯数字。"; sleep 2; return 1; }

    echo -e "${CYAN}正在解析并验证目标地址...${PLAIN}"
    if ! resolve_target_pair "$taddr"; then
        msg_err "错误: 目标地址非法，或域名 A/AAAA 解析失败。"
        sleep 2
        return 1
    fi

    tmp_candidate="$(mktemp /tmp/nftmgr-add.XXXXXX)"
    cp -a "$CONFIG_FILE" "$tmp_candidate" 2>/dev/null || : > "$tmp_candidate"
    emit_rule_line "$lport" "$taddr" "$tport" "$RESOLVED_V4" "$RESOLVED_V6" "$proto" >> "$tmp_candidate"

    if ! apply_candidate_rules "$tmp_candidate"; then
        msg_err "❌ 应用规则失败：本次新增未提交。"
        sleep 2
        return 1
    fi

    manage_firewall add "$lport" "$proto"
    msg_ok "✅ 添加成功：${lport}/${proto} -> ${taddr}:${tport}"
    [[ -n "$RESOLVED_V4" ]] && msg_info "   IPv4: ${RESOLVED_V4}"
    [[ -n "$RESOLVED_V6" ]] && msg_info "   IPv6: ${RESOLVED_V6}"
    sleep 2
    return 0
}

add_forward() { with_lock add_forward_impl; }

# --------------------------
# 规则管理
# --------------------------
list_and_del_forward_impl() {
    clear
    if [[ ! -s "$CONFIG_FILE" ]] || [[ "$(rule_count "$CONFIG_FILE")" == "0" ]]; then
        msg_warn "当前没有任何转发规则。"
        pause
        return 0
    fi

    echo -e "${CYAN}============================= 规则管理 =============================${PLAIN}"
    printf "%-4s | %-6s | %-5s | %-8s | %-24s | %-6s | %-15s | %-24s\n" "序号" "本地" "协议" "类型" "目标地址" "目标" "IPv4" "IPv6"
    echo "---------------------------------------------------------------------------------------------------------------"

    local i=1 line v4show v6show
    while IFS= read -r line || [[ -n "$line" ]]; do
        parse_rule_line "$line" || continue
        rule_is_valid || continue
        v4show="${RULE_LAST_V4:--}"
        v6show="${RULE_LAST_V6:--}"
        printf "%-4s | %-6s | %-5s | %-8s | %-24s | %-6s | %-15s | %-24s\n" \
            "$i" "$RULE_LPORT" "$RULE_PROTO" "$(note_addr_type "$RULE_ADDR")" "$RULE_ADDR" "$RULE_TPORT" "$v4show" "$v6show"
        i=$((i + 1))
    done < "$CONFIG_FILE"

    echo "---------------------------------------------------------------------------------------------------------------"
    echo -e "${YELLOW}输入序号即可删除；输入 0 或直接回车返回。${PLAIN}"

    local action line_no del_line del_port del_proto tmp_candidate
    read -rp "请选择操作: " action
    [[ -z "$action" || "$action" == "0" ]] && return 0
    [[ "$action" =~ ^[0-9]+$ ]] || { msg_err "输入无效。"; sleep 2; return 1; }

    local total
    total="$(rule_count "$CONFIG_FILE")"
    if [[ "$action" -lt 1 || "$action" -gt "$total" ]]; then
        msg_err "序号超出范围。"
        sleep 2
        return 1
    fi

    line_no="$(get_rule_line_number_by_index "$CONFIG_FILE" "$action")" || {
        msg_err "删除失败：无法定位规则行。"
        sleep 2
        return 1
    }

    del_line="$(sed -n "${line_no}p" "$CONFIG_FILE")"
    parse_rule_line "$del_line" || {
        msg_err "删除失败：规则格式异常。"
        sleep 2
        return 1
    }
    del_port="$RULE_LPORT"
    del_proto="$RULE_PROTO"

    tmp_candidate="$(mktemp /tmp/nftmgr-del.XXXXXX)"
    sed "${line_no}d" "$CONFIG_FILE" > "$tmp_candidate"

    if ! apply_candidate_rules "$tmp_candidate"; then
        msg_err "❌ 删除失败：内核规则未切换，配置未变更。"
        sleep 2
        return 1
    fi

    manage_firewall del "$del_port" "$del_proto"
    msg_ok "✅ 已删除本地端口 ${del_port}/${del_proto}。"
    sleep 2
    return 0
}

list_and_del_forward() { with_lock list_and_del_forward_impl; }

# --------------------------
# DDNS 更新
# --------------------------
ddns_update_impl() {
    load_settings
    [[ "$DDNS_ENABLED" == "1" ]] || return 0
    [[ -f "$CONFIG_FILE" ]] || return 0
    has_domain_rules_in_file "$CONFIG_FILE" || return 0

    local changed=0 line tmp_candidate today_log old_v4 old_v6
    tmp_candidate="$(mktemp /tmp/nftmgr-ddns.XXXXXX)"
    today_log="${LOG_DIR}/$(date '+%Y-%m-%d').log"

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" || "${line:0:1}" == "#" ]]; then
            printf '%s\n' "$line" >> "$tmp_candidate"
            continue
        fi

        parse_rule_line "$line" || { printf '%s\n' "$line" >> "$tmp_candidate"; continue; }
        rule_is_valid || { printf '%s\n' "$line" >> "$tmp_candidate"; continue; }

        if is_literal_ip "$RULE_ADDR"; then
            emit_rule_line "$RULE_LPORT" "$RULE_ADDR" "$RULE_TPORT" "$RULE_LAST_V4" "$RULE_LAST_V6" "$RULE_PROTO" >> "$tmp_candidate"
            continue
        fi

        old_v4="$RULE_LAST_V4"
        old_v6="$RULE_LAST_V6"
        if ! resolve_target_pair "$RULE_ADDR"; then
            printf '[%s] [ERROR] 端口 %s: 域名 %s A/AAAA 解析失败（保持旧值）\n' "$(date '+%H:%M:%S')" "$RULE_LPORT" "$RULE_ADDR" >> "$today_log"
            emit_rule_line "$RULE_LPORT" "$RULE_ADDR" "$RULE_TPORT" "$RULE_LAST_V4" "$RULE_LAST_V6" "$RULE_PROTO" >> "$tmp_candidate"
            continue
        fi

        if [[ "$RESOLVED_V4" != "$old_v4" || "$RESOLVED_V6" != "$old_v6" ]]; then
            changed=1
            printf '[%s] 端口 %s: %s 变动 (IPv4 %s -> %s, IPv6 %s -> %s)\n' \
                "$(date '+%H:%M:%S')" "$RULE_LPORT" "$RULE_ADDR" \
                "${old_v4:--}" "${RESOLVED_V4:--}" "${old_v6:--}" "${RESOLVED_V6:--}" >> "$today_log"
        fi
        emit_rule_line "$RULE_LPORT" "$RULE_ADDR" "$RULE_TPORT" "$RESOLVED_V4" "$RESOLVED_V6" "$RULE_PROTO" >> "$tmp_candidate"
    done < "$CONFIG_FILE"

    if [[ $changed -eq 1 ]]; then
        if ! apply_candidate_rules "$tmp_candidate"; then
            printf '[%s] [ERROR] nft 规则应用失败，本次 DDNS 更新已丢弃，配置保持不变\n' "$(date '+%H:%M:%S')" >> "$today_log"
            rm -f "$tmp_candidate"
            return 1
        fi
        printf '[%s] [OK] DDNS 更新已提交\n' "$(date '+%H:%M:%S')" >> "$today_log"
    else
        rm -f "$tmp_candidate"
    fi

    find "$LOG_DIR" -type f -name '*.log' -mtime +7 -exec rm -f {} \; 2>/dev/null || true
    return 0
}

# 修补了嵌套死锁问题的封装
ddns_update() { with_lock ddns_update_impl; }

# --------------------------
# 开关 / 状态管理
# --------------------------
manage_features_impl() {
    load_settings
    clear
    echo -e "${GREEN}--- 加速与监控开关 ---${PLAIN}"
    echo "1. 切换 Flowtable 加速   [当前: $(flowtable_status_text)]"
    if cron_is_enabled; then
        echo "2. 切换 DDNS 自动监控   [当前: $( [[ "$DDNS_ENABLED" == "1" ]] && echo "开启 / 定时任务已安装" || echo "关闭 / 定时任务仍存在" )]"
    else
        echo "2. 切换 DDNS 自动监控   [当前: $( [[ "$DDNS_ENABLED" == "1" ]] && echo "开启 / 定时任务未安装(无域名规则或未同步)" || echo "关闭" )]"
    fi
    echo "3. 立即执行一次 DDNS 检查"
    echo "4. 查看 DDNS 日志（最近 7 天）"
    echo "0. 返回主菜单"
    echo "--------------------------------"

    local pick
    read -rp "请选择 [0-4]: " pick
    case "$pick" in
        1)
            if [[ "$FLOWTABLE_ENABLED" == "1" ]]; then
                settings_set FLOWTABLE_ENABLED 0
                msg_info "已关闭 Flowtable。"
            else
                settings_set FLOWTABLE_ENABLED 1
                msg_info "已开启 Flowtable（若内核/接口不支持，将在应用时自动跳过）。"
            fi
            load_settings
            if [[ -s "$CONFIG_FILE" ]]; then
                apply_rules_current >/dev/null 2>&1 || msg_warn "⚠️ 已保存开关，但当前规则重载失败，请稍后检查。"
            fi
            sleep 2
            ;;
        2)
            if [[ "$DDNS_ENABLED" == "1" ]]; then
                settings_set DDNS_ENABLED 0
                msg_info "已关闭 DDNS 自动监控。"
            else
                settings_set DDNS_ENABLED 1
                msg_info "已开启 DDNS 自动监控。"
            fi
            load_settings
            ensure_ddns_scheduler_state
            sleep 2
            ;;
        3)
            # 【修复点】：避免双重获取 flock 死锁，直接调用内层业务逻辑
            if ddns_update_impl; then
                msg_ok "DDNS 检查完成。"
            else
                msg_warn "DDNS 检查已完成，但存在失败项，请查看日志。"
            fi
            sleep 2
            ;;
        4)
            clear
            if [[ -d "$LOG_DIR" ]] && ls "$LOG_DIR"/*.log >/dev/null 2>&1; then
                echo -e "${GREEN}--- DDNS 日志（末 50 行） ---${PLAIN}"
                cat "$LOG_DIR"/*.log 2>/dev/null | tail -n 50
            else
                msg_warn "暂无 DDNS 日志。"
            fi
            echo
            pause
            ;;
        0) return 0 ;;
        *) msg_err "无效选项"; sleep 1 ;;
    esac
}

manage_features() { with_lock manage_features_impl; }

# --------------------------
# 清空规则
# --------------------------
clear_all_rules_impl() {
    if [[ ! -s "$CONFIG_FILE" ]] || [[ "$(rule_count "$CONFIG_FILE")" == "0" ]]; then
        msg_warn "当前没有规则，无需清空。"
        sleep 1
        return 0
    fi

    msg_warn "⚠️ 将清空所有转发规则。"
    read -rp "确认清空？[y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0

    local tmp_candidate old_copy line
    tmp_candidate="$(mktemp /tmp/nftmgr-clear.XXXXXX)"
    old_copy="$(mktemp /tmp/nftmgr-oldrules.XXXXXX)"
    cp -a "$CONFIG_FILE" "$old_copy"
    : > "$tmp_candidate"

    if ! apply_candidate_rules "$tmp_candidate"; then
        rm -f "$old_copy"
        msg_err "❌ 清空失败：原有规则保持不变。"
        sleep 2
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        parse_rule_line "$line" || continue
        rule_is_valid || continue
        manage_firewall del "$RULE_LPORT" "$RULE_PROTO"
    done < "$old_copy"
    rm -f "$old_copy"

    msg_ok "✅ 所有规则已清空。"
    sleep 2
    return 0
}

clear_all_rules() { with_lock clear_all_rules_impl; }

# --------------------------
# 卸载
# --------------------------
remove_old_system_include_if_present() {
    local nft_conf="/etc/nftables.conf"
    [[ -f "$nft_conf" ]] || return 0
    local bak tmp
    bak="${nft_conf}.nftmgr.uninstall.bak.$(date +%s)"
    cp -a "$nft_conf" "$bak" 2>/dev/null || true
    tmp="$(mktemp /tmp/nftmgr-uninstall-nftconf.XXXXXX)"
    sed '/# nf include (added .*$/d; /# nftmgr persistent include$/d; \|include "/etc/nftables.d/nft_mgr.conf"|d' "$nft_conf" > "$tmp"
    if nft -c -f "$tmp" >/dev/null 2>&1; then
        mv -f "$tmp" "$nft_conf"
    else
        rm -f "$tmp"
        msg_warn "⚠️ 检测到旧版 /etc/nftables.conf include，已保留原文件与备份 ${bak}，请按需手动清理。"
    fi
}

uninstall_script_impl() {
    clear
    echo -e "${RED}--- 卸载 nftables 端口转发管理面板 ---${PLAIN}"
    read -rp "确认卸载？这将删除规则、配置、DDNS 定时任务与 systemd 服务。[y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0

    local old_copy line
    old_copy="$(mktemp /tmp/nftmgr-uninstall-rules.XXXXXX)"
    cp -a "$CONFIG_FILE" "$old_copy" 2>/dev/null || : > "$old_copy"

    : > "$CONFIG_FILE"
    apply_rules_current >/dev/null 2>&1 || true

    while IFS= read -r line || [[ -n "$line" ]]; do
        parse_rule_line "$line" || continue
        rule_is_valid || continue
        manage_firewall del "$RULE_LPORT" "$RULE_PROTO"
    done < "$old_copy"
    rm -f "$old_copy"

    if have_cmd crontab; then
        remove_legacy_cron_entries
        if cron_is_enabled; then
            crontab -l 2>/dev/null | grep -Fvx "$(cron_entry)" | crontab - 2>/dev/null || true
        fi
    fi

    have_cmd nft && nft delete table inet "$TABLE_INET" >/dev/null 2>&1 || true
    have_cmd nft && nft delete table ip "$TABLE_V4" >/dev/null 2>&1 || true
    have_cmd nft && nft delete table ip6 "$TABLE_V6" >/dev/null 2>&1 || true

    if have_cmd systemctl; then
        systemctl disable --now nft-mgr >/dev/null 2>&1 || true
        rm -f "$NFT_MGR_SERVICE" 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    remove_old_system_include_if_present

    rm -f "$NFT_RUNTIME_CONF" "$CONFIG_FILE" "$SETTINGS_FILE" "$SYSCTL_FILE" "$LOCK_FILE" 2>/dev/null || true
    rm -rf "$LOG_DIR" 2>/dev/null || true
    rmdir "$NFT_MGR_DIR" 2>/dev/null || true
    rm -f "/usr/local/bin/${CMD_NAME}" 2>/dev/null || true

    msg_ok "✅ 卸载完成。"
    exit 0
}

uninstall_script() { with_lock uninstall_script_impl; }

# --------------------------
# 主菜单
# --------------------------
main_menu() {
    load_settings
    clear
    echo -e "${GREEN}====================================================${PLAIN}"
    echo -e "${GREEN}       nftables 端口转发管理面板 (Pro Max)${PLAIN}"
    echo -e "${GREEN}====================================================${PLAIN}"
    echo "Flowtable: $(flowtable_status_text)"
    if cron_is_enabled; then
        echo "DDNS 自动监控: $( [[ "$DDNS_ENABLED" == "1" ]] && echo "开启（定时任务已安装）" || echo "关闭（但残留定时任务，请进菜单同步）" )"
    else
        echo "DDNS 自动监控: $( [[ "$DDNS_ENABLED" == "1" ]] && echo "开启（当前未安装定时任务）" || echo "关闭" )"
    fi
    echo "当前规则数: $(rule_count "$CONFIG_FILE")"
    echo "----------------------------------------------------"
    echo "1. 开启极限网络调优 (BBR+高并发+连接跟踪)"
    echo "2. 新增端口转发 (IPv4/IPv6/域名, TCP/UDP)"
    echo "3. 规则管理 (查看/删除)"
    echo "4. 清空所有转发规则"
    echo "5. 管理 Flowtable / DDNS 开关与日志"
    echo "6. 一键完全卸载本脚本"
    echo "0. 退出面板"
    echo "----------------------------------------------------"

    local choice
    read -rp "请选择操作 [0-6]: " choice
    case "$choice" in
        1) optimize_system ;;
        2) add_forward ;;
        3) list_and_del_forward ;;
        4) clear_all_rules ;;
        5) manage_features ;;
        6) uninstall_script ;;
        0) exit 0 ;;
        *) msg_err "无效选项"; sleep 1 ;;
    esac
}

# --------------------------
# 入口
# --------------------------
require_root
check_env
ensure_default_settings
load_settings

case "${1:-}" in
    --cron)
        ddns_update
        exit $?
        ;;
esac

while true; do
    main_menu
done
EOF

chmod +x /root/nf.sh
bash /root/nf.sh
