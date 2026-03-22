#!/bin/bash
# my 综合管理（完整合并版）
# 更新地址：https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/my.sh
# 版本：v2.2.0-full
# 指纹：CMD_NAME="my" / MY_SCRIPT_ID="my-manager"

set -o pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

CMD_NAME="my"
MY_SCRIPT_ID="my-manager"
MY_VERSION="2.2.0-full"
MY_STATE_DIR="/usr/local/lib/my/state"
DNS_STATE_DIR="${MY_STATE_DIR}/dns"
DDNS_STATE_DIR="${MY_STATE_DIR}/ddns"
UPDATE_URL_DIRECT="https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/my.sh"
UPDATE_URL_PROXY="https://mirror.ghproxy.com/https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/my.sh"
REINSTALL_UPSTREAM_GLOBAL="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
REINSTALL_UPSTREAM_CN="https://cnb.cool/bin456789/reinstall/-/git/raw/main/reinstall.sh"
REINSTALL_WORKDIR="/tmp/my-reinstall"
REINSTALL_SCRIPT_PATH="${REINSTALL_WORKDIR}/reinstall.sh"
SSH_PORT_DROPIN="/etc/ssh/sshd_config.d/00-my-port.conf"
SSH_AUTH_DROPIN="/etc/ssh/sshd_config.d/00-my-auth.conf"
SYSCTL_OPT_FILE="/etc/sysctl.d/99-my-optimizer.conf"
DNS_BACKUP_FILE="${DNS_STATE_DIR}/resolv.conf.bak"
DNS_META_FILE="${DNS_STATE_DIR}/meta.conf"
DDNS_CFG_FILE="${DDNS_STATE_DIR}/cloudflare.env"
DDNS_LOG_FILE="${DDNS_STATE_DIR}/update.log"
GITHUB_KNOWN_HOSTS="/root/.ssh/known_hosts"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'
RESET="${PLAIN}"

msg_ok()   { echo -e "${GREEN}$*${PLAIN}"; }
msg_warn() { echo -e "${YELLOW}$*${PLAIN}"; }
msg_err()  { echo -e "${RED}$*${PLAIN}"; }
msg_info() { echo -e "${CYAN}$*${PLAIN}"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }
service_use_systemd() {
    have_cmd systemctl || return 1
    [[ -d /run/systemd/system ]] || [[ "$(cat /proc/1/comm 2>/dev/null)" == "systemd" ]]
}
require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        msg_err "错误：必须使用 root 权限运行。"
        exit 1
    fi
}
script_realpath() {
    if have_cmd readlink; then
        readlink -f "$0" 2>/dev/null && return 0
    fi
    if have_cmd realpath; then
        realpath "$0" 2>/dev/null && return 0
    fi
    printf '%s\n' "$0"
}
base64_nw() {
    if base64 --help 2>/dev/null | grep -q -- '-w'; then
        base64 -w 0
    else
        base64 | tr -d '\r\n'
    fi
}
run_with_timeout() {
    local sec="$1"
    shift
    if have_cmd timeout; then
        timeout "$sec" "$@"
    else
        "$@"
    fi
}
ensure_state_dirs() {
    mkdir -p "$MY_STATE_DIR" "$DNS_STATE_DIR" "$DDNS_STATE_DIR" /root/.ssh 2>/dev/null || true
}
install_self_command() {
    local self
    self="$(script_realpath)"
    if [[ "$self" != "/usr/local/bin/${CMD_NAME}" ]]; then
        cp -f "$self" "/usr/local/bin/${CMD_NAME}" 2>/dev/null || true
        chmod +x "/usr/local/bin/${CMD_NAME}" 2>/dev/null || true
    fi
}

pkg_update_once() {
    if have_cmd apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        run_with_timeout 20 apt-get update -y >/dev/null 2>&1 || run_with_timeout 20 apt-get update >/dev/null 2>&1 || return 1
        return 0
    fi
    return 0
}
pkg_install() {
    if have_cmd apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        run_with_timeout 30 apt-get install -y "$@"
    elif have_cmd dnf; then
        run_with_timeout 30 dnf install -y "$@"
    elif have_cmd yum; then
        run_with_timeout 30 yum install -y "$@"
    else
        return 1
    fi
}
ensure_base_tools() {
    local missing=()
    have_cmd curl || missing+=(curl)
    have_cmd awk || missing+=(gawk)
    have_cmd sed || missing+=(sed)
    have_cmd grep || missing+=(grep)
    have_cmd ss || missing+=(iproute2)
    have_cmd python3 || missing+=(python3)
    if [[ ${#missing[@]} -gt 0 ]]; then
        pkg_update_once >/dev/null 2>&1 || true
        pkg_install "${missing[@]}" >/dev/null 2>&1 || true
    fi
}
ensure_jq_or_python() {
    have_cmd jq && return 0
    have_cmd python3 && return 0
    pkg_update_once >/dev/null 2>&1 || true
    pkg_install jq python3 >/dev/null 2>&1 || pkg_install python3 >/dev/null 2>&1 || true
    have_cmd jq || have_cmd python3
}

status_colorize() {
    local level="$1" text="$2"
    case "$level" in
        ok) printf '%b' "${GREEN}${text}${RESET}" ;;
        warn) printf '%b' "${YELLOW}${text}${RESET}" ;;
        bad) printf '%b' "${RED}${text}${RESET}" ;;
        *) printf '%b' "${CYAN}${text}${RESET}" ;;
    esac
}
status_cc_colored() {
    local cc qd
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
    printf '%s / %s' "$(status_colorize info "$cc")" "$(status_colorize info "$qd")"
}
status_timesync_brief() {
    if have_cmd timedatectl; then
        timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes && { echo 已同步; return; }
        echo 未同步
        return
    fi
    echo 未知
}
status_timesync_line() {
    local ts
    ts="$(status_timesync_brief)"
    if [[ "$ts" == 已同步 ]]; then
        echo -e "  时间同步: $(status_colorize ok "$ts")"
    else
        echo -e "  时间同步: $(status_colorize warn "$ts")"
    fi
}
sshd_effective_port() {
    local port
    port="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')"
    [[ "$port" =~ ^[0-9]+$ ]] || port=22
    printf '%s' "$port"
}
status_ssh_line() {
    local port active auth
    port="$(sshd_effective_port 2>/dev/null || echo 22)"
    if service_use_systemd && systemctl is-active --quiet ssh; then
        active="运行中"
    elif service_use_systemd && systemctl is-active --quiet sshd; then
        active="运行中"
    else
        active="未托管"
    fi
    auth="$(sshd -T 2>/dev/null | awk '/^passwordauthentication / {print $2; exit}')"
    [[ -n "$auth" ]] || auth="unknown"
    echo -e "  SSH: $(status_colorize info "$active") / 端口 ${YELLOW}${port}${RESET} / 密码登录 ${YELLOW}${auth}${RESET}"
}
nginx_site_count() {
    find /etc/nginx/conf.d /etc/nginx/sites-enabled -maxdepth 1 \( -type f -o -type l \) -name '*.conf' 2>/dev/null | wc -l | awk '{print $1}'
}
status_nginx_line() {
    local sites
    sites="$(nginx_site_count 2>/dev/null || echo 0)"
    if service_use_systemd && systemctl is-active --quiet nginx; then
        echo -e "  Nginx 状态: $(status_colorize ok '运行中') / 站点 ${YELLOW}${sites}${RESET}"
    else
        echo -e "  Nginx 状态: $(status_colorize warn '未运行') / 站点 ${YELLOW}${sites}${RESET}"
    fi
}
status_ddns_line() {
    if [[ -s "$DDNS_CFG_FILE" ]]; then
        echo -e "  DDNS: $(status_colorize ok '已配置') / $(awk -F= '/^RECORD_NAME=/{print $2}' "$DDNS_CFG_FILE" 2>/dev/null)"
    else
        echo -e "  DDNS: $(status_colorize warn '未配置')"
    fi
}
status_opt_mode() {
    local mode
    mode="$(awk -F= '/^profile=/{print $2}' "$MY_STATE_DIR/optimizer.conf" 2>/dev/null | tail -n1)"
    [[ -n "$mode" ]] || mode="未应用"
    printf '%s' "$mode"
}

cron_remove_regex() {
    local pattern="$1" tmp
    tmp="$(mktemp /tmp/my-cron.XXXXXX)" || return 1
    crontab -l 2>/dev/null | grep -Ev "$pattern" > "$tmp" || true
    crontab "$tmp" 2>/dev/null || true
    rm -f "$tmp"
}
ensure_global_clean_cron() {
    local tmp line
    tmp="$(mktemp /tmp/my-cron.XXXXXX)" || return 0
    crontab -l 2>/dev/null > "$tmp" || true
    line="0 2 * * * /usr/local/bin/my clean >/dev/null 2>&1"
    grep -Fqx "$line" "$tmp" || echo "$line" >> "$tmp"
    crontab "$tmp" 2>/dev/null || true
    rm -f "$tmp"
}
daily_clean() {
    find /tmp -maxdepth 1 -type f -name 'my-*' -mtime +1 -delete 2>/dev/null || true
    journalctl --vacuum-time=7d >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true
    apt-get clean >/dev/null 2>&1 || true
}

port_in_use() {
    local port="$1"
    ss -lntH 2>/dev/null | awk '{print $4}' | awk -F: '{print $NF}' | grep -qx "$port" && return 0
    ss -lnuH 2>/dev/null | awk '{print $4}' | awk -F: '{print $NF}' | grep -qx "$port" && return 0
    return 1
}
random_free_port() {
    local p
    for p in 20000 20100 20200 20300 20400 20500 20600 20700 20800 20900; do
        port_in_use "$p" || { echo "$p"; return 0; }
    done
    echo 20000
}

random_id() {
    if have_cmd openssl; then
        openssl rand -hex 8 2>/dev/null | tr 'A-Z' 'a-z'
    else
        date +%s | sha256sum 2>/dev/null | cut -c1-16
    fi
}

download_to() {
    local url="$1" dest="$2"
    [[ -n "$url" && -n "$dest" ]] || return 1
    if have_cmd curl; then
        curl -fsSL --connect-timeout 8 --max-time 25 --retry 2 --retry-delay 1 -o "$dest" "$url"
    elif have_cmd wget; then
        wget -qO "$dest" "$url"
    else
        return 1
    fi
}
normalize_update_file() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    sed -i '1s/^ï»¿//' "$f" 2>/dev/null || true
    tr -d '\r' < "$f" > "${f}.lf" 2>/dev/null && mv -f "${f}.lf" "$f" || true
    return 0
}
verify_update_file() {
    local f="$1"
    [[ -s "$f" ]] || return 11
    [[ "$(wc -c < "$f" 2>/dev/null)" =~ ^[0-9]+$ ]] || return 18
    (( $(wc -c < "$f") >= 12000 )) || return 19
    grep -qi '<html' "$f" && return 20
    grep -q '^#!/bin/bash' "$f" || return 12
    grep -q 'CMD_NAME="my"' "$f" || return 13
    grep -q 'MY_SCRIPT_ID="my-manager"' "$f" || return 14
    grep -Eq '^[[:space:]]*main_menu[[:space:]]*\(\)' "$f" || return 15
    grep -Eq '^[[:space:]]*init[[:space:]]*\(\)' "$f" || return 16
    bash -n "$f" || return 17
    return 0
}
github_update() {
    local self tmp bak rc new_ver size url
    self="$(script_realpath)"
    tmp="$(mktemp /tmp/my-update.XXXXXX.sh)" || { msg_err "创建临时文件失败。"; return 1; }
    bak="${self}.bak.$(date +%Y%m%d%H%M%S)"
    for url in "$UPDATE_URL_DIRECT" "$UPDATE_URL_PROXY"; do
        [[ -n "$url" ]] || continue
        : > "$tmp"
        if download_to "$url" "$tmp" >/dev/null 2>&1; then
            normalize_update_file "$tmp"
            verify_update_file "$tmp"
            rc=$?
            if (( rc == 0 )); then
                if cmp -s "$tmp" "$self" 2>/dev/null; then
                    msg_ok "已经是最新内容，无需更新。"
                    rm -f "$tmp"
                    return 0
                fi
                cp -f "$self" "$bak" 2>/dev/null || { msg_err "备份当前脚本失败。"; rm -f "$tmp"; return 1; }
                cp -f "$tmp" "$self" 2>/dev/null || { msg_err "写入新脚本失败。"; rm -f "$tmp"; return 1; }
                chmod +x "$self" 2>/dev/null || true
                if ! bash -n "$self" >/dev/null 2>&1; then
                    cp -f "$bak" "$self" 2>/dev/null || true
                    msg_err "新脚本语法检查失败，已自动回滚。"
                    rm -f "$tmp"
                    return 1
                fi
                install_self_command >/dev/null 2>&1 || true
                new_ver="$(grep -m1 '^MY_VERSION=' "$self" | sed -E 's/^[^"]*"([^"]+)".*/\1/')"
                msg_ok "在线自更新成功。当前版本：${new_ver:-未知}"
                msg_info "备份文件：${bak}"
                rm -f "$tmp"
                return 0
            fi
        else
            rc=2
        fi
    done
    size=$(wc -c < "$tmp" 2>/dev/null || echo 0)
    rm -f "$tmp"
    case "$rc" in
        11) msg_err "更新失败：下载结果为空。" ;;
        12) msg_err "更新失败：缺少 bash 头。" ;;
        13) msg_err "更新失败：缺少 CMD_NAME 标记。" ;;
        14) msg_err "更新失败：缺少脚本 ID 标记。" ;;
        15) msg_err "更新失败：缺少 main_menu()。" ;;
        16) msg_err "更新失败：缺少 init()。" ;;
        17) msg_err "更新失败：新脚本语法错误。" ;;
        19) msg_err "更新失败：下载文件过小（${size} 字节）。" ;;
        20) msg_err "更新失败：下载结果像是网页，不是脚本。" ;;
        *) msg_err "在线自更新失败，请稍后重试或检查上游地址。" ;;
    esac
    return 1
}

write_optimizer_profile() {
    local profile="$1"
    printf 'profile=%s\nupdated_at=%s\n' "$profile" "$(date '+%F %T')" > "$MY_STATE_DIR/optimizer.conf"
}
apply_sysctl_lines() {
    local profile="$1"
    shift
    printf '%s\n' "$@" > "$SYSCTL_OPT_FILE"
    sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_OPT_FILE" >/dev/null 2>&1 || return 1
    write_optimizer_profile "$profile"
}
apply_general_extreme_opt() {
    apply_sysctl_lines "general-extreme" \
"net.core.default_qdisc = fq" \
"net.ipv4.tcp_congestion_control = bbr" \
"net.ipv4.tcp_fastopen = 3" \
"net.ipv4.tcp_mtu_probing = 1" \
"net.ipv4.tcp_slow_start_after_idle = 0" \
"net.ipv4.ip_local_port_range = 10240 65535" \
"net.ipv4.tcp_fin_timeout = 15" \
"net.ipv4.tcp_keepalive_time = 600" \
"net.ipv4.tcp_keepalive_intvl = 30" \
"net.ipv4.tcp_keepalive_probes = 5" \
"net.core.somaxconn = 4096" \
"net.ipv4.tcp_max_syn_backlog = 8192" \
"vm.swappiness = 10"
}
apply_nat_extreme_opt() {
    apply_sysctl_lines "nat-extreme" \
"net.core.default_qdisc = fq" \
"net.ipv4.tcp_congestion_control = bbr" \
"net.ipv4.tcp_fastopen = 3" \
"net.ipv4.tcp_mtu_probing = 1" \
"net.ipv4.tcp_slow_start_after_idle = 0" \
"net.ipv4.ip_local_port_range = 10240 65535" \
"net.ipv4.tcp_fin_timeout = 15" \
"net.ipv4.tcp_tw_reuse = 1" \
"net.netfilter.nf_conntrack_max = 262144" \
"net.netfilter.nf_conntrack_tcp_timeout_established = 1200" \
"net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30" \
"net.core.somaxconn = 8192" \
"net.ipv4.tcp_max_syn_backlog = 16384" \
"net.netfilter.nf_conntrack_buckets = 65536" \
"vm.swappiness = 10"
}

_dns_now_ms() {
    date +%s%3N 2>/dev/null || python3 - <<'PY'
import time
print(int(time.time()*1000))
PY
}
dns_candidate_servers() {
    cat <<'EOF_DNS'
223.5.5.5|aliyun
223.6.6.6|aliyun
119.29.29.29|tencent
1.12.12.12|tencent
180.76.76.76|baidu
1.1.1.1|cloudflare
8.8.8.8|google
9.9.9.9|quad9
94.140.14.14|adguard
EOF_DNS
}
ensure_dns_probe_tool() {
    have_cmd dig && { echo dig; return 0; }
    have_cmd nslookup && { echo nslookup; return 0; }
    pkg_update_once >/dev/null 2>&1 || true
    pkg_install dnsutils >/dev/null 2>&1 || pkg_install bind-utils >/dev/null 2>&1 || true
    have_cmd dig && { echo dig; return 0; }
    have_cmd nslookup && { echo nslookup; return 0; }
    echo none
    return 1
}
dns_probe_once() {
    local tool="$1" server="$2" domain="$3" start end
    start="$(_dns_now_ms)"
    if [[ "$tool" == "dig" ]]; then
        run_with_timeout 3 dig +time=1 +tries=1 +short @"$server" "$domain" A 2>/dev/null | grep -q '.' || return 1
    elif [[ "$tool" == "nslookup" ]]; then
        run_with_timeout 3 nslookup "$domain" "$server" 2>/dev/null | grep -Eiq 'Address:|Addresses:' || return 1
    else
        return 1
    fi
    end="$(_dns_now_ms)"
    echo $((end-start))
}
dns_probe_avg_ms() {
    local tool="$1" server="$2" total=0 ok=0 elapsed domain
    for domain in www.cloudflare.com www.baidu.com www.qq.com; do
        elapsed="$(dns_probe_once "$tool" "$server" "$domain" 2>/dev/null || true)"
        if [[ "$elapsed" =~ ^[0-9]+$ ]]; then
            total=$((total+elapsed))
            ok=$((ok+1))
        fi
    done
    (( ok > 0 )) || return 1
    echo $((total/ok))
}
dns_pick_best_servers() {
    local tool line ip provider ms used_providers="|"
    tool="$(ensure_dns_probe_tool 2>/dev/null || echo none)"
    [[ "$tool" != none ]] || return 1
    while IFS='|' read -r ip provider; do
        [[ -n "$ip" ]] || continue
        ms="$(dns_probe_avg_ms "$tool" "$ip" 2>/dev/null || true)"
        [[ "$ms" =~ ^[0-9]+$ ]] || continue
        printf '%s|%s|%s\n' "$ms" "$ip" "$provider"
    done < <(dns_candidate_servers) | sort -n | while IFS='|' read -r ms ip provider; do
        if [[ "$used_providers" != *"|$provider|"* ]]; then
            echo "$ip"
            used_providers+="$provider|"
        fi
    done | head -n 3
}
dns_backup() {
    ensure_state_dirs
    if [[ -f /etc/resolv.conf && ! -s "$DNS_BACKUP_FILE" ]]; then
        cp -a /etc/resolv.conf "$DNS_BACKUP_FILE" 2>/dev/null || true
    fi
}
dns_write_meta() {
    local mode="$1" servers="$2"
    ensure_state_dirs
    printf 'mode=%s\nservers=%s\nupdated_at=%s\n' "$mode" "$servers" "$(date '+%F %T')" > "$DNS_META_FILE"
}
dns_apply_resolvconf() {
    local servers=() s
    for s in "$@"; do
        [[ -n "$s" ]] && servers+=("$s")
    done
    [[ ${#servers[@]} -gt 0 ]] || return 1
    dns_backup
    {
        for s in "${servers[@]:0:3}"; do
            echo "nameserver $s"
        done
        echo "options timeout:1 attempts:2 rotate"
    } > /etc/resolv.conf
    dns_write_meta resolvconf "${servers[*]}"
}
dns_apply_systemd_resolved() {
    local servers="$*"
    dns_backup
    mkdir -p /etc/systemd/resolved.conf.d 2>/dev/null || true
    cat > /etc/systemd/resolved.conf.d/99-my-dns.conf <<EOF_DNSCONF
[Resolve]
DNS=${servers}
Domains=~.
Cache=yes
DNSSEC=allow-downgrade
EOF_DNSCONF
    systemctl restart systemd-resolved >/dev/null 2>&1 || return 1
    dns_write_meta resolved "$servers"
}
dns_apply_servers() {
    local servers=() s
    for s in "$@"; do
        [[ -n "$s" ]] && servers+=("$s")
    done
    [[ ${#servers[@]} -gt 0 ]] || return 1
    if service_use_systemd && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        dns_apply_systemd_resolved "${servers[@]}"
    else
        dns_apply_resolvconf "${servers[@]}"
    fi
}
dns_auto_tune() {
    local best=() started now
    started="$(_dns_now_ms)"
    while read -r line; do
        [[ -n "$line" ]] && best+=("$line")
    done < <(dns_pick_best_servers)
    now="$(_dns_now_ms)"
    if (( now - started > 20000 )); then
        msg_warn "DNS 探测耗时较长，已自动中止并回退。"
        best=(223.5.5.5 119.29.29.29 1.1.1.1)
    fi
    if [[ ${#best[@]} -eq 0 ]]; then
        msg_warn "智能 DNS 探测未得到稳定结果，改用安全回退组。"
        best=(223.5.5.5 119.29.29.29 1.1.1.1)
    fi
    dns_apply_servers "${best[@]}" || { msg_err "应用 DNS 失败。"; return 1; }
    msg_ok "DNS 智能调优完成：${best[*]}"
}
dns_manual_set() {
    local input servers=() item
    read -rp "请输入 DNS，多个用空格分隔: " input
    for item in $input; do
        [[ "$item" =~ ^[0-9a-fA-F:.]+$ ]] && servers+=("$item")
    done
    [[ ${#servers[@]} -gt 0 ]] || { msg_err "未输入有效 DNS。"; return 1; }
    dns_apply_servers "${servers[@]}" || return 1
    msg_ok "DNS 已设置为：${servers[*]}"
}
dns_unlock_restore() {
    if [[ -f /etc/systemd/resolved.conf.d/99-my-dns.conf ]]; then
        rm -f /etc/systemd/resolved.conf.d/99-my-dns.conf
        systemctl restart systemd-resolved >/dev/null 2>&1 || true
    fi
    if [[ -s "$DNS_BACKUP_FILE" ]]; then
        cp -a "$DNS_BACKUP_FILE" /etc/resolv.conf 2>/dev/null || true
    fi
    rm -f "$DNS_META_FILE" 2>/dev/null || true
    msg_ok "DNS 已恢复。"
}
get_dns_servers_brief() {
    if have_cmd resolvectl && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        resolvectl dns 2>/dev/null | awk '{for(i=3;i<=NF;i++) print $i}' | paste -sd ',' -
        return
    fi
    awk '/^nameserver /{print $2}' /etc/resolv.conf 2>/dev/null | paste -sd ',' -
}
get_dns_brief_status() {
    local s
    s="$(get_dns_servers_brief 2>/dev/null || true)"
    [[ -n "$s" ]] && echo 已配置 || echo 未配置
}
dns_status() {
    local mode servers
    mode="$(awk -F= '/^mode=/{print $2}' "$DNS_META_FILE" 2>/dev/null | head -n1)"
    servers="$(get_dns_servers_brief 2>/dev/null || true)"
    [[ -n "$mode" ]] || mode="自动检测"
    echo -e "当前模式: ${YELLOW}${mode}${RESET}"
    echo -e "当前 DNS: ${YELLOW}${servers:-未探测到}${RESET}"
}

write_ssh_port_dropin() {
    local port="$1"
    mkdir -p "$(dirname "$SSH_PORT_DROPIN")" 2>/dev/null || true
    cat > "$SSH_PORT_DROPIN" <<EOF_SSHPORT
Port ${port}
EOF_SSHPORT
}
write_ssh_auth_dropin() {
    local pass_mode="$1"
    mkdir -p "$(dirname "$SSH_AUTH_DROPIN")" 2>/dev/null || true
    cat > "$SSH_AUTH_DROPIN" <<EOF_SSHAUTH
PasswordAuthentication ${pass_mode}
KbdInteractiveAuthentication ${pass_mode}
ChallengeResponseAuthentication ${pass_mode}
EOF_SSHAUTH
}
restart_ssh_service() {
    if service_use_systemd; then
        systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1
    else
        service ssh restart >/dev/null 2>&1 || service sshd restart >/dev/null 2>&1
    fi
}
change_ssh_port() {
    local new_port old_port
    read -rp "新的 SSH 端口号 (1-65535): " new_port
    [[ "$new_port" =~ ^[0-9]+$ ]] || { msg_err "端口格式错误。"; return 1; }
    (( new_port >= 1 && new_port <= 65535 )) || { msg_err "端口范围错误。"; return 1; }
    old_port="$(sshd_effective_port 2>/dev/null || echo 22)"
    write_ssh_port_dropin "$new_port"
    if ! sshd -t; then
        rm -f "$SSH_PORT_DROPIN"
        msg_err "sshd 配置校验失败，已取消。"
        return 1
    fi
    restart_ssh_service || { msg_err "SSH 重启失败。"; return 1; }
    if have_cmd ufw; then
        ufw allow "$new_port"/tcp >/dev/null 2>&1 || true
        [[ "$old_port" != "$new_port" ]] && ufw delete allow "$old_port"/tcp >/dev/null 2>&1 || true
    fi
    msg_ok "SSH 端口已修改为 ${new_port}。"
}
change_root_password() { passwd root; }
disable_password_login() {
    write_ssh_auth_dropin no
    sshd -t || { rm -f "$SSH_AUTH_DROPIN"; msg_err "sshd 配置校验失败。"; return 1; }
    restart_ssh_service || { msg_err "SSH 重启失败。"; return 1; }
    msg_ok "已关闭 SSH 密码登录。"
}
restore_password_login() {
    write_ssh_auth_dropin yes
    sshd -t || { rm -f "$SSH_AUTH_DROPIN"; msg_err "sshd 配置校验失败。"; return 1; }
    restart_ssh_service || { msg_err "SSH 重启失败。"; return 1; }
    msg_ok "已恢复 SSH 密码登录。"
}

github_keys_auto_fetch() {
    local verify_user input_host host tmp work_keys work_hosts meta_ok=0 added_count=0 host_count22=0 host_count443=0 ans want_443=1
    mkdir -p /root/.ssh 2>/dev/null || true
    touch "$GITHUB_KNOWN_HOSTS" 2>/dev/null || true
    chmod 600 "$GITHUB_KNOWN_HOSTS" 2>/dev/null || true

    msg_info "将获取并校验 GitHub SSH 主机密钥。"
    printf "请输入 GitHub 用户名（可留空，仅用于本次连通性标记）: "
    read -r verify_user
    printf "请输入 GitHub SSH 主机（默认 github.com，支持 ssh.github.com）: "
    read -r input_host
    host="${input_host:-github.com}"
    case "$host" in
        github.com|ssh.github.com) ;;
        *)
            msg_warn "当前仅支持 github.com / ssh.github.com，已自动回退为 github.com。"
            host="github.com"
            ;;
    esac
    printf "是否同时写入 [ssh.github.com]:443 主机密钥？[Y/n]: "
    read -r ans
    case "${ans,,}" in
        n|no) want_443=0 ;;
        *) want_443=1 ;;
    esac

    tmp="$(mktemp /tmp/my-ghkeys.XXXXXX)" || return 1
    work_keys="$(mktemp /tmp/my-ghkeys-lines.XXXXXX)" || { rm -f "$tmp"; return 1; }
    work_hosts="$(mktemp /tmp/my-known-hosts.XXXXXX)" || { rm -f "$tmp" "$work_keys"; return 1; }

    if download_to "https://api.github.com/meta" "$tmp" >/dev/null 2>&1 && have_cmd python3; then
        if python3 - "$tmp" "$work_keys" "$want_443" <<'PY'
import json,sys
meta=json.load(open(sys.argv[1],'r',encoding='utf-8'))
keys=meta.get('ssh_keys',[])
want443=(sys.argv[3]=='1')
out=[]
for k in keys:
    out.append(f"github.com {k}")
    out.append(f"ssh.github.com {k}")
    if want443:
        out.append(f"[ssh.github.com]:443 {k}")
seen=set()
with open(sys.argv[2],'w',encoding='utf-8') as f:
    for line in out:
        if line not in seen:
            seen.add(line)
            f.write(line+'\n')
PY
        then
            meta_ok=1
        fi
    fi
    rm -f "$tmp"

    if (( meta_ok == 0 )); then
        : > "$work_keys"
        if have_cmd ssh-keyscan; then
            ssh-keyscan -T 5 github.com 2>/dev/null | sed '/^#/d' >> "$work_keys" || true
            ssh-keyscan -T 5 ssh.github.com 2>/dev/null | sed '/^#/d' >> "$work_keys" || true
            if (( want_443 == 1 )); then
                ssh-keyscan -T 5 -p 443 ssh.github.com 2>/dev/null | sed '/^#/d; s/^ssh\.github\.com /[ssh.github.com]:443 /' >> "$work_keys" || true
            fi
        fi
    fi

    grep -Ev '^(github\.com|ssh\.github\.com|\[ssh\.github\.com\]:443)[[:space:],]' "$GITHUB_KNOWN_HOSTS" 2>/dev/null > "$work_hosts" || true
    cat "$work_keys" >> "$work_hosts"
    sort -u "$work_hosts" -o "$work_hosts" 2>/dev/null || true
    cp -f "$work_hosts" "$GITHUB_KNOWN_HOSTS" 2>/dev/null || { rm -f "$work_keys" "$work_hosts"; msg_err "写入 known_hosts 失败。"; return 1; }
    chmod 600 "$GITHUB_KNOWN_HOSTS" 2>/dev/null || true

    added_count=$(grep -Ec '^(github\.com|ssh\.github\.com|\[ssh\.github\.com\]:443)[[:space:]]' "$work_keys" 2>/dev/null || true)
    if have_cmd ssh-keygen; then
        host_count22=$(ssh-keygen -F "$host" -f "$GITHUB_KNOWN_HOSTS" 2>/dev/null | grep -Ec '^(github\.com|ssh\.github\.com) ' || true)
        host_count443=$(ssh-keygen -F '[ssh.github.com]:443' -f "$GITHUB_KNOWN_HOSTS" 2>/dev/null | grep -c '^\[ssh.github.com\]:443 ' || true)
    else
        host_count22=$(grep -Ec '^(github\.com|ssh\.github\.com) ' "$GITHUB_KNOWN_HOSTS" 2>/dev/null || true)
        host_count443=$(grep -c '^\[ssh.github.com\]:443 ' "$GITHUB_KNOWN_HOSTS" 2>/dev/null || true)
    fi

    rm -f "$work_keys" "$work_hosts"

    if (( host_count22 > 0 || host_count443 > 0 )); then
        msg_ok "GitHub 主机密钥已写入 known_hosts。"
        msg_info "目标主机: ${host} | github/ssh.github 条目: ${host_count22} | [ssh.github.com]:443 条目: ${host_count443} | 本次写入: ${added_count}"
        if [[ -n "$verify_user" ]]; then
            msg_info "已记录本次输入的 GitHub 名称：${verify_user}（仅用于校验提示，主机密钥本身与用户名无关）"
        fi
        if (( want_443 == 1 )); then
            msg_info "如需走 443 端口，请把 Git 远程主机写成 ssh.github.com，并使用端口 443。"
        fi
        msg_info "可执行检查：ssh-keygen -F github.com -f ${GITHUB_KNOWN_HOSTS}"
        return 0
    fi

    msg_err "GitHub 主机密钥获取失败。"
    return 1
}


ensure_nginx_installed() {
    if have_cmd nginx; then
        return 0
    fi
    pkg_update_once >/dev/null 2>&1 || true
    pkg_install nginx >/dev/null 2>&1 || { msg_err "安装 Nginx 失败。"; return 1; }
    service_use_systemd && systemctl enable --now nginx >/dev/null 2>&1 || true
}
nginx_list_sites() {
    local files file
    files=$(find /etc/nginx/conf.d /etc/nginx/sites-enabled -maxdepth 1 \( -type f -o -type l \) -name '*.conf' 2>/dev/null)
    if [[ -z "$files" ]]; then
        echo "未发现站点配置。"
        return 0
    fi
    while read -r file; do
        [[ -n "$file" ]] || continue
        echo "- $(basename "$file")"
    done <<< "$files"
}
nginx_add_reverse_proxy() {
    local domain upstream file
    ensure_nginx_installed || return 1
    read -rp "域名: " domain
    read -rp "反代上游（例如 127.0.0.1:3000）: " upstream
    [[ -n "$domain" && -n "$upstream" ]] || { msg_err "域名和上游不能为空。"; return 1; }
    file="/etc/nginx/conf.d/${domain}.conf"
    cat > "$file" <<EOF_NGX
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    client_max_body_size 50m;
    proxy_http_version 1.1;

    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_pass http://${upstream};
    }
}
EOF_NGX
    nginx -t || { rm -f "$file"; msg_err "Nginx 配置校验失败。"; return 1; }
    service_use_systemd && systemctl reload nginx >/dev/null 2>&1 || nginx -s reload >/dev/null 2>&1
    msg_ok "反向代理站点已创建：${domain} -> ${upstream}"
}
nginx_delete_site() {
    local domain
    domain="$1"
    [[ -n "$domain" ]] || { read -rp "要删除的域名: " domain; }
    [[ -n "$domain" ]] || { msg_err "域名不能为空。"; return 1; }
    rm -f "/etc/nginx/conf.d/${domain}.conf" "/etc/nginx/sites-enabled/${domain}.conf" 2>/dev/null || true
    nginx -t >/dev/null 2>&1 || true
    service_use_systemd && systemctl reload nginx >/dev/null 2>&1 || nginx -s reload >/dev/null 2>&1 || true
    msg_ok "已删除站点：${domain}"
}
nginx_repair() {
    ensure_nginx_installed || return 1
    nginx -t || { msg_err "Nginx 配置校验失败。"; return 1; }
    service_use_systemd && systemctl restart nginx >/dev/null 2>&1 || nginx -s reload >/dev/null 2>&1
    msg_ok "Nginx 已修复并重载。"
}

cf_api_call() {
    local method="$1" path="$2" data="${3:-}"
    source "$DDNS_CFG_FILE" || return 1
    if [[ -n "$data" ]]; then
        curl -fsSL -X "$method" "https://api.cloudflare.com/client/v4${path}" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "$data"
    else
        curl -fsSL -X "$method" "https://api.cloudflare.com/client/v4${path}" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json"
    fi
}
json_extract() {
    local expr="$1"
    if have_cmd jq; then
        jq -r "$expr" 2>/dev/null
    else
        python3 - "$expr" <<'PY'
import json,sys
expr=sys.argv[1]
obj=json.load(sys.stdin)
# very small extractor for simple .a.b[0].c paths or booleans
path=expr.strip()
if path.startswith('.'):
    path=path[1:]
cur=obj
for part in path.replace(']','').split('.'):
    if not part:
        continue
    if '[' in part:
        name,idx=part.split('[',1)
        if name:
            cur=cur.get(name)
        cur=cur[int(idx)] if cur is not None else None
    else:
        if isinstance(cur,dict):
            cur=cur.get(part)
        else:
            cur=None
if cur is True: print('true')
elif cur is False: print('false')
elif cur is None: print('')
else: print(cur)
PY
    fi
}
ddns_detect_public_ip() {
    local ip
    for url in https://api.ipify.org https://ifconfig.me https://ip.sb; do
        ip="$(curl -4fsSL --connect-timeout 5 --max-time 8 "$url" 2>/dev/null | tr -d '\r\n')"
        [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return 0; }
    done
    return 1
}
ddns_cf_resolve_zone_id() {
    local resp zone_id
    resp="$(cf_api_call GET "/zones?name=${CF_ZONE_NAME}&status=active" 2>/dev/null)" || return 1
    zone_id="$(printf '%s' "$resp" | json_extract '.result[0].id')"
    [[ -n "$zone_id" && "$zone_id" != null ]] || return 1
    echo "$zone_id"
}
ddns_cf_resolve_record_id() {
    local zone_id="$1" resp record_id
    resp="$(cf_api_call GET "/zones/${zone_id}/dns_records?type=A&name=${RECORD_NAME}" 2>/dev/null)" || return 1
    record_id="$(printf '%s' "$resp" | json_extract '.result[0].id')"
    [[ -n "$record_id" && "$record_id" != null ]] || return 1
    echo "$record_id"
}
ddns_setup() {
    local token zone record proxied ttl zone_id record_id public_ip create_payload update_payload tmp
    ensure_jq_or_python || { msg_err "缺少 jq/python3，无法配置 DDNS。"; return 1; }
    read -rp "Cloudflare API Token: " token
    read -rp "Zone 名称（例如 example.com）: " zone
    read -rp "记录全名（例如 home.example.com）: " record
    read -rp "是否启用代理（true/false，默认 false）: " proxied
    read -rp "TTL（默认 120）: " ttl
    [[ -n "$token" && -n "$zone" && -n "$record" ]] || { msg_err "Token / Zone / 记录名不能为空。"; return 1; }
    [[ "$proxied" == "true" || "$proxied" == "false" ]] || proxied=false
    [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=120
    public_ip="$(ddns_detect_public_ip)" || { msg_err "获取公网 IP 失败。"; return 1; }
    tmp="$(mktemp /tmp/my-ddns.XXXXXX)" || return 1
    cat > "$tmp" <<EOF_CFG
CF_API_TOKEN=${token}
CF_ZONE_NAME=${zone}
RECORD_NAME=${record}
PROXIED=${proxied}
TTL=${ttl}
EOF_CFG
    mv -f "$tmp" "$DDNS_CFG_FILE"
    chmod 600 "$DDNS_CFG_FILE" 2>/dev/null || true
    zone_id="$(ddns_cf_resolve_zone_id)" || { msg_err "获取 Cloudflare Zone ID 失败。"; return 1; }
    sed -i "/^ZONE_ID=/d" "$DDNS_CFG_FILE"
    printf 'ZONE_ID=%s\n' "$zone_id" >> "$DDNS_CFG_FILE"
    source "$DDNS_CFG_FILE"
    record_id="$(ddns_cf_resolve_record_id "$zone_id" 2>/dev/null || true)"
    if [[ -n "$record_id" ]]; then
        sed -i "/^RECORD_ID=/d" "$DDNS_CFG_FILE"
        printf 'RECORD_ID=%s\n' "$record_id" >> "$DDNS_CFG_FILE"
    else
        create_payload=$(printf '{"type":"A","name":"%s","content":"%s","ttl":%s,"proxied":%s}' "$record" "$public_ip" "$ttl" "$proxied")
        record_id="$(cf_api_call POST "/zones/${zone_id}/dns_records" "$create_payload" 2>/dev/null | json_extract '.result.id')"
        [[ -n "$record_id" && "$record_id" != null ]] || { msg_err "创建 DDNS 记录失败。"; return 1; }
        printf 'RECORD_ID=%s\n' "$record_id" >> "$DDNS_CFG_FILE"
    fi
    ddns_update_now || return 1
    ddns_install_cron
    msg_ok "DDNS 已配置完成。"
}
ddns_update_now() {
    local public_ip resp current_ip payload record_id zone_id
    [[ -s "$DDNS_CFG_FILE" ]] || { msg_err "DDNS 未配置。"; return 1; }
    source "$DDNS_CFG_FILE" || return 1
    public_ip="$(ddns_detect_public_ip)" || { msg_err "获取公网 IP 失败。"; return 1; }
    zone_id="${ZONE_ID:-$(ddns_cf_resolve_zone_id)}"
    record_id="${RECORD_ID:-$(ddns_cf_resolve_record_id "$zone_id" 2>/dev/null || true)}"
    [[ -n "$record_id" ]] || { msg_err "获取记录 ID 失败。"; return 1; }
    resp="$(cf_api_call GET "/zones/${zone_id}/dns_records/${record_id}" 2>/dev/null)" || { msg_err "读取当前 DDNS 记录失败。"; return 1; }
    current_ip="$(printf '%s' "$resp" | json_extract '.result.content')"
    if [[ "$current_ip" == "$public_ip" ]]; then
        printf '%s IP unchanged %s\n' "$(date '+%F %T')" "$public_ip" >> "$DDNS_LOG_FILE"
        msg_ok "DDNS 无需更新，当前 IP：${public_ip}"
        return 0
    fi
    payload=$(printf '{"type":"A","name":"%s","content":"%s","ttl":%s,"proxied":%s}' "$RECORD_NAME" "$public_ip" "$TTL" "$PROXIED")
    resp="$(cf_api_call PUT "/zones/${zone_id}/dns_records/${record_id}" "$payload" 2>/dev/null)" || { msg_err "DDNS 更新请求失败。"; return 1; }
    if [[ "$(printf '%s' "$resp" | json_extract '.success')" == "true" ]]; then
        printf '%s updated %s\n' "$(date '+%F %T')" "$public_ip" >> "$DDNS_LOG_FILE"
        sed -i "/^ZONE_ID=/d;/^RECORD_ID=/d" "$DDNS_CFG_FILE"
        printf 'ZONE_ID=%s\nRECORD_ID=%s\n' "$zone_id" "$record_id" >> "$DDNS_CFG_FILE"
        msg_ok "DDNS 已更新为：${public_ip}"
        return 0
    fi
    msg_err "DDNS 更新失败。"
    return 1
}
ddns_install_cron() {
    local tmp line
    [[ -s "$DDNS_CFG_FILE" ]] || return 1
    tmp="$(mktemp /tmp/my-ddns-cron.XXXXXX)" || return 1
    crontab -l 2>/dev/null | grep -v '/usr/local/bin/my ddns update' > "$tmp" || true
    line="*/5 * * * * /usr/local/bin/my ddns update >/dev/null 2>&1"
    echo "$line" >> "$tmp"
    crontab "$tmp" 2>/dev/null || true
    rm -f "$tmp"
    msg_ok "DDNS 定时任务已安装。"
}
ddns_remove() {
    cron_remove_regex '/usr/local/bin/my ddns update'
    rm -f "$DDNS_CFG_FILE" "$DDNS_LOG_FILE" 2>/dev/null || true
    msg_ok "DDNS 配置与定时任务已移除。"
}
ddns_status() {
    if [[ ! -s "$DDNS_CFG_FILE" ]]; then
        msg_warn "DDNS 未配置。"
        return 0
    fi
    source "$DDNS_CFG_FILE" || return 1
    echo -e "记录名: ${YELLOW}${RECORD_NAME}${RESET}"
    echo -e "Zone: ${YELLOW}${CF_ZONE_NAME}${RESET}"
    echo -e "代理: ${YELLOW}${PROXIED}${RESET}"
    echo -e "TTL: ${YELLOW}${TTL}${RESET}"
    echo -e "公网 IP: ${YELLOW}$(ddns_detect_public_ip 2>/dev/null || echo 获取失败)${RESET}"
    [[ -f "$DDNS_LOG_FILE" ]] && tail -n 5 "$DDNS_LOG_FILE" 2>/dev/null | sed 's/^/日志: /'
}

legacy_cleanup() {
    local svc
    msg_warn "开始清理旧代理 / 转发残留..."
    for svc in xray ss-rust ss-v2ray nftmgr; do
        if service_use_systemd; then
            systemctl stop "$svc" >/dev/null 2>&1 || true
            systemctl disable "$svc" >/dev/null 2>&1 || true
        fi
        rm -f "/etc/systemd/system/${svc}.service" "/lib/systemd/system/${svc}.service" "/usr/lib/systemd/system/${svc}.service" 2>/dev/null || true
    done
    rm -rf /usr/local/etc/xray /etc/xray /etc/ss-rust /etc/ss-v2ray /usr/local/lib/my/cache/xray 2>/dev/null || true
    rm -f /usr/local/bin/xray /usr/local/bin/ss-rust /usr/local/bin/nftmgr 2>/dev/null || true
    service_use_systemd && systemctl daemon-reload >/dev/null 2>&1 || true
    msg_ok "旧代理 / 转发残留已清理。"
}

uninstall_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}              清理残留 / 卸载               ${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${YELLOW} 1.${RESET} 清理旧代理 / 转发残留"
        echo -e "${YELLOW} 2.${RESET} 执行日常清理"
        echo -e "${RED} 3.${RESET} 卸载本脚本"
        echo -e " 0. 返回"
        read -rp "请输入数字 [0-3]: " choice
        case "$choice" in
            1) legacy_cleanup; read -n 1 -s -r -p "按任意键继续..." ;;
            2) daily_clean; msg_ok "清理完成。"; read -n 1 -s -r -p "按任意键继续..." ;;
            3) rm -f /usr/local/bin/my; msg_ok "已删除 /usr/local/bin/my。"; exit 0 ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

status_page_loop() {
    while true; do
        local dns dns_servers optmode
        dns="$(get_dns_brief_status 2>/dev/null || echo 未知)"
        dns_servers="$(get_dns_servers_brief 2>/dev/null || echo 未探测到)"
        optmode="$(status_opt_mode)"
        clear 2>/dev/null || true
        echo -e "${CYAN}============================================================${RESET}"
        echo -e "${CYAN}                    统一状态页 / 管理导航                   ${RESET}"
        echo -e "${CYAN}============================================================${RESET}"
        echo -e "${GREEN}网络调优${RESET}"
        echo -e "  优化档位: ${YELLOW}${optmode}${RESET}"
        echo -e "  拥塞控制 / 队列: $(status_cc_colored)"
        status_timesync_line
        echo -e "  DNS: ${YELLOW}${dns}${RESET} / 当前 ${YELLOW}${dns_servers}${RESET}"
        echo -e ""
        echo -e "${GREEN}Nginx 与服务${RESET}"
        status_nginx_line
        status_ddns_line
        echo -e ""
        echo -e "${GREEN}系统基础${RESET}"
        status_ssh_line
        status_xray_line
        echo -e ""
        echo -e "${CYAN}快捷导航${RESET}"
        echo -e "  ${YELLOW}1.${RESET} 优化中心          ${YELLOW}4.${RESET} DDNS / 建站 / DD 中心"
        echo -e "  ${YELLOW}2.${RESET} 刷新 GitHub 密钥   ${YELLOW}5.${RESET} 刷新状态页"
        echo -e "  ${YELLOW}3.${RESET} Xray / 节点中心"
        echo -e "  0. 返回主菜单"
        echo -e "${CYAN}============================================================${RESET}"
        read -rp "请输入数字 [0-5]: " choice
        case "$choice" in
            1) optimize_menu ;;
            2) github_keys_auto_fetch; read -n 1 -s -r -p "按任意键继续..." ;;
            3) xray_menu ;;
            4) services_menu ;;
            5) ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

optimize_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}                优化中心                    ${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${YELLOW} 1.${RESET} 常规机器极致优化"
        echo -e "${YELLOW} 2.${RESET} NAT 小鸡极致优化"
        echo -e "${YELLOW} 3.${RESET} DNS 智能调优（防卡死版）"
        echo -e "${YELLOW} 4.${RESET} 手动设置 DNS"
        echo -e "${YELLOW} 5.${RESET} 查看 DNS 状态"
        echo -e "${YELLOW} 6.${RESET} 恢复 DNS"
        echo -e "${YELLOW} 7.${RESET} 获取 / 校验 GitHub 主机密钥（会提示输入 GitHub 名称）"
        echo -e "${YELLOW} 8.${RESET} 修改 SSH 端口"
        echo -e "${YELLOW} 9.${RESET} 修改 root 密码"
        echo -e "${YELLOW}10.${RESET} 关闭 SSH 密码登录"
        echo -e "${YELLOW}11.${RESET} 恢复 SSH 密码登录"
        echo -e "${YELLOW}12.${RESET} 运行日常清理"
        echo -e " 0. 返回"
        read -rp "请输入数字 [0-12]: " choice
        case "$choice" in
            1) apply_general_extreme_opt && msg_ok "常规机器极致优化已应用。"; read -n 1 -s -r -p "按任意键继续..." ;;
            2) apply_nat_extreme_opt && msg_ok "NAT 小鸡极致优化已应用。"; read -n 1 -s -r -p "按任意键继续..." ;;
            3) dns_auto_tune; read -n 1 -s -r -p "按任意键继续..." ;;
            4) dns_manual_set; read -n 1 -s -r -p "按任意键继续..." ;;
            5) dns_status; read -n 1 -s -r -p "按任意键继续..." ;;
            6) dns_unlock_restore; read -n 1 -s -r -p "按任意键继续..." ;;
            7) github_keys_auto_fetch; read -n 1 -s -r -p "按任意键继续..." ;;
            8) change_ssh_port; read -n 1 -s -r -p "按任意键继续..." ;;
            9) change_root_password; read -n 1 -s -r -p "按任意键继续..." ;;
            10) disable_password_login; read -n 1 -s -r -p "按任意键继续..." ;;
            11) restore_password_login; read -n 1 -s -r -p "按任意键继续..." ;;
            12) daily_clean; msg_ok "清理完成。"; read -n 1 -s -r -p "按任意键继续..." ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

nginx_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}              Nginx 建站与反代            ${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${YELLOW} 1.${RESET} 安装 / 启动 Nginx"
        echo -e "${YELLOW} 2.${RESET} 新建反向代理站点"
        echo -e "${YELLOW} 3.${RESET} 查看站点列表"
        echo -e "${YELLOW} 4.${RESET} 删除站点"
        echo -e "${YELLOW} 5.${RESET} 修复 / 重载 Nginx"
        echo -e " 0. 返回"
        read -rp "请输入数字 [0-5]: " choice
        case "$choice" in
            1) ensure_nginx_installed; msg_ok "Nginx 已安装 / 启动。"; read -n 1 -s -r -p "按任意键继续..." ;;
            2) nginx_add_reverse_proxy; read -n 1 -s -r -p "按任意键继续..." ;;
            3) nginx_list_sites; read -n 1 -s -r -p "按任意键继续..." ;;
            4) nginx_delete_site; read -n 1 -s -r -p "按任意键继续..." ;;
            5) nginx_repair; read -n 1 -s -r -p "按任意键继续..." ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

ddns_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}                 DDNS 中心                 ${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${YELLOW} 1.${RESET} 配置 Cloudflare DDNS"
        echo -e "${YELLOW} 2.${RESET} 立即更新 DDNS"
        echo -e "${YELLOW} 3.${RESET} 查看 DDNS 状态"
        echo -e "${YELLOW} 4.${RESET} 安装 / 重装 DDNS 定时任务"
        echo -e "${YELLOW} 5.${RESET} 删除 DDNS 配置"
        echo -e " 0. 返回"
        read -rp "请输入数字 [0-5]: " choice
        case "$choice" in
            1) ddns_setup; read -n 1 -s -r -p "按任意键继续..." ;;
            2) ddns_update_now; read -n 1 -s -r -p "按任意键继续..." ;;
            3) ddns_status; read -n 1 -s -r -p "按任意键继续..." ;;
            4) ddns_install_cron; read -n 1 -s -r -p "按任意键继续..." ;;
            5) ddns_remove; read -n 1 -s -r -p "按任意键继续..." ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

fetch_reinstall_script() {
    mkdir -p "$REINSTALL_WORKDIR" 2>/dev/null || true
    download_to "$REINSTALL_UPSTREAM_GLOBAL" "$REINSTALL_SCRIPT_PATH" || download_to "$REINSTALL_UPSTREAM_CN" "$REINSTALL_SCRIPT_PATH" || return 1
    chmod +x "$REINSTALL_SCRIPT_PATH" 2>/dev/null || true
    [[ -s "$REINSTALL_SCRIPT_PATH" ]]
}
dd_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}             DD / 重装系统中心             ${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${YELLOW} 1.${RESET} Debian 13"
        echo -e "${YELLOW} 2.${RESET} Debian 12"
        echo -e "${YELLOW} 3.${RESET} Ubuntu 24.04"
        echo -e " 0. 返回"
        read -rp "请输入数字 [0-3]: " choice
        case "$choice" in
            1) fetch_reinstall_script || { msg_err "下载重装脚本失败。"; read -n 1 -s -r -p "按任意键继续..."; continue; }; bash "$REINSTALL_SCRIPT_PATH" debian 13 ;;
            2) fetch_reinstall_script || { msg_err "下载重装脚本失败。"; read -n 1 -s -r -p "按任意键继续..."; continue; }; bash "$REINSTALL_SCRIPT_PATH" debian 12 ;;
            3) fetch_reinstall_script || { msg_err "下载重装脚本失败。"; read -n 1 -s -r -p "按任意键继续..."; continue; }; bash "$REINSTALL_SCRIPT_PATH" ubuntu 24.04 ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

services_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}            DDNS / 建站 / DD 中心          ${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${YELLOW} 1.${RESET} DDNS 中心"
        echo -e "${YELLOW} 2.${RESET} Nginx 建站与反代"
        echo -e "${YELLOW} 3.${RESET} DD / 重装系统"
        echo -e " 0. 返回"
        read -rp "请输入数字 [0-3]: " choice
        case "$choice" in
            1) ddns_menu ;;
            2) nginx_menu ;;
            3) dd_menu ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}


status_xray_line() {
    local svc="未安装" ver=""
    if command -v xray >/dev/null 2>&1 || [[ -x /usr/local/bin/xray || -x /usr/bin/xray ]]; then
        if service_use_systemd && systemctl is-active --quiet xray; then
            svc="运行中"
        elif service_use_systemd && systemctl status xray >/dev/null 2>&1; then
            svc="已安装/未运行"
        else
            svc="已安装"
        fi
        ver="$(xray version 2>/dev/null | awk 'NR==1{print $2}')"
        [[ -n "$ver" ]] && svc="$svc / v$ver"
        echo -e "  Xray: $(status_colorize ok \"$svc\")"
    else
        echo -e "  Xray: $(status_colorize warn '未安装')"
    fi
}

xray_module_run() {
    local tmp
    tmp="$(mktemp /tmp/my-xray.XXXXXX.sh)" || { msg_err "无法创建临时文件。"; return 1; }
    cat > "$tmp" <<'__MY_XRAY_PAYLOAD__'
#!/bin/bash

# ==============================================================================
# Xray VLESS-Reality & Shadowsocks 2022 多功能管理脚本
# 版本: Final v2.9.2
# 更新日志 (v2.9.2):
# - [安全] 添加配置文件权限保护
# - [安全] 增强脚本下载验证
# - [安全] 敏感信息显示保护
# - [稳定] 网络操作重试机制
# - [稳定] 服务启动详细错误显示
# ==============================================================================

# --- Shell 严格模式 ---
set -euo pipefail

# --- 全局常量 ---
readonly SCRIPT_VERSION="Final v2.9.2"
readonly xray_config_path="/usr/local/etc/xray/config.json"
readonly xray_binary_path="/usr/local/bin/xray"
readonly xray_install_script_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

# --- 颜色定义 ---
readonly red='\e[91m' green='\e[92m' yellow='\e[93m'
readonly magenta='\e[95m' cyan='\e[96m' none='\e[0m'

# --- 全局变量 ---
xray_status_info=""
is_quiet=false

# --- 辅助函数 ---
error() { 
    echo -e "\n$red[✖] $1$none\n" >&2
    
    # 根据错误内容提供简单建议
    case "$1" in
        *"网络"*|*"下载"*) 
            echo -e "$yellow提示: 检查网络连接或更换DNS$none" >&2 ;;
        *"权限"*|*"root"*) 
            echo -e "$yellow提示: 请使用 sudo 运行脚本$none" >&2 ;;
        *"端口"*) 
            echo -e "$yellow提示: 尝试使用其他端口号$none" >&2 ;;
    esac
}

info() { [[ "$is_quiet" = false ]] && echo -e "\n$yellow[!] $1$none\n"; }
success() { [[ "$is_quiet" = false ]] && echo -e "\n$green[✔] $1$none\n"; }
warning() { [[ "$is_quiet" = false ]] && echo -e "\n$yellow[⚠] $1$none\n"; }

spinner() {
    local pid="$1"
    local spinstr='|/-\'
    if [[ "$is_quiet" = true ]]; then
        wait "$pid"
        return
    fi
    while ps -p "$pid" > /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep 0.1
        printf "\r"
    done
    printf "    \r"
}

get_public_ip() {
    local ip
    local attempts=0
    local max_attempts=2
    
    while [[ $attempts -lt $max_attempts ]]; do
        for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
            for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
                ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
            done
        done
        ((attempts++))
        [[ $attempts -lt $max_attempts ]] && sleep 1
    done
    
    # IPv6 fallback
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
}

# --- 预检查与环境设置 ---
pre_check() {
    [[ "$(id -u)" != 0 ]] && error "错误: 您必须以root用户身份运行此脚本" && exit 1
    if [ ! -f /etc/debian_version ]; then error "错误: 此脚本仅支持 Debian/Ubuntu 及其衍生系统。" && exit 1; fi
    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
        info "检测到缺失的依赖 (jq/curl)，正在尝试自动安装..."
        (DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y jq curl) &> /dev/null &
        spinner $!
        if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
            error "依赖 (jq/curl) 自动安装失败。请手动运行 'apt update && apt install -y jq curl' 后重试。"
            exit 1
        fi
        success "依赖已成功安装。"
    fi
}

check_xray_status() {
    if [[ ! -f "$xray_binary_path" || ! -x "$xray_binary_path" ]]; then
        xray_status_info=" Xray 状态: ${red}未安装${none}"
        return
    fi
    local xray_version
    xray_version=$("$xray_binary_path" version 2>/dev/null | head -n 1 | awk '{print $2}' || echo "未知")
    local service_status
    if systemctl is-active --quiet xray 2>/dev/null; then
        service_status="${green}运行中${none}"
    else
        service_status="${yellow}未运行${none}"
    fi
    xray_status_info=" Xray 状态: ${green}已安装${none} | ${service_status} | 版本: ${cyan}${xray_version}${none}"
}

# 新增：快速状态检查
quick_status() {
    if [[ ! -f "$xray_binary_path" ]]; then
        echo -e " ${red}●${none} 未安装"
        return
    fi
    
    local status_icon
    if systemctl is-active --quiet xray 2>/dev/null; then
        status_icon="${green}●${none}"
    else
        status_icon="${red}●${none}"
    fi
    
    echo -e " $status_icon Xray $(systemctl is-active xray 2>/dev/null || echo "inactive")"
}

# --- 核心配置生成函数 ---
generate_ss_key() {
    openssl rand -base64 16
}

build_vless_inbound() {
    local port="$1" uuid="$2" domain="$3" private_key="$4" public_key="$5" shortid="20220701"
    jq -n --argjson port "$port" --arg uuid "$uuid" --arg domain "$domain" --arg private_key "$private_key" --arg public_key "$public_key" --arg shortid "$shortid" \
    '{ "listen": "0.0.0.0", "port": $port, "protocol": "vless", "settings": {"clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}], "decryption": "none"}, "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"show": false, "dest": ($domain + ":443"), "xver": 0, "serverNames": [$domain], "privateKey": $private_key, "publicKey": $public_key, "shortIds": [$shortid]}}, "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]} }'
}

build_ss_inbound() {
    local port="$1" password="$2"
    jq -n --argjson port "$port" --arg password "$password" \
    '{ "listen": "0.0.0.0", "port": $port, "protocol": "shadowsocks", "settings": {"method": "2022-blake3-aes-128-gcm", "password": $password} }'
}

write_config() {
    local inbounds_json="$1"
    local config_content
    
    config_content=$(jq -n --argjson inbounds "$inbounds_json" \
    '{
      "log": {"loglevel": "warning"},
      "inbounds": $inbounds,
      "outbounds": [
        {
          "protocol": "freedom",
          "settings": {
            "domainStrategy": "UseIPv4v6"
          }
        }
      ]
    }')
    
    # 新增：验证生成的JSON是否有效
    if ! echo "$config_content" | jq . >/dev/null 2>&1; then
        error "生成的配置文件格式错误！"
        return 1
    fi
    
    echo "$config_content" > "$xray_config_path"
    
    # 修复：设置适当权限，确保 xray 用户可以读取
    chmod 644 "$xray_config_path"
    chown root:root "$xray_config_path"
}

execute_official_script() {
    local args="$1"
    local script_content
    
    # 增强：添加简单的内容检查
    script_content=$(curl -L "$xray_install_script_url")
    if [[ -z "$script_content" || ! "$script_content" =~ "install-release" ]]; then
        error "下载 Xray 官方安装脚本失败或内容异常！请检查网络连接。"
        return 1
    fi
    
    echo "$script_content" | bash -s -- $args &> /dev/null &
    spinner $!
    if ! wait $!; then
        return 1
    fi
}

run_core_install() {
    info "正在下载并安装 Xray 核心..."
    if ! execute_official_script "install"; then
        error "Xray 核心安装失败！"
        return 1
    fi
    
    info "正在更新 GeoIP 和 GeoSite 数据文件..."
    if ! execute_official_script "install-geodata"; then
        error "Geo-data 更新失败！"
        info "这通常不影响核心功能，您可以稍后手动更新。"
    fi
    
    success "Xray 核心及数据文件已准备就绪。"
}

# --- 输入验证与交互函数 (优化) ---
is_valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

# 新增：端口可用性检测
is_port_available() {
    local port="$1"
    is_valid_port "$port" || return 1
    
    # 检查端口是否被占用
    if ss -tlpn 2>/dev/null | grep -q ":$port "; then
        warning "端口 $port 已被占用，建议选择其他端口"
        return 1
    fi
    return 0
}

is_valid_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9-]{1,63}(\.[a-zA-Z0-9-]{1,63})+$ ]] && [[ "$domain" != *--* ]]
}

prompt_for_vless_config() {
    local -n p_port="$1" p_uuid="$2" p_sni="$3"
    local default_port="${4:-443}"

    while true; do
        read -p "$(echo -e " -> 请输入 VLESS 端口 (默认: ${cyan}${default_port}${none}): ")" p_port || true
        [[ -z "$p_port" ]] && p_port="$default_port"
        if is_port_available "$p_port"; then break; fi
    done
    info "VLESS 端口将使用: ${cyan}${p_port}${none}"

    read -p "$(echo -e " -> 请输入UUID (留空将自动生成): ")" p_uuid || true
    if [[ -z "$p_uuid" ]]; then
        p_uuid=$(cat /proc/sys/kernel/random/uuid)
        info "已为您生成随机UUID: ${cyan}${p_uuid}${none}"
    fi

    while true; do
        read -p "$(echo -e " -> 请输入SNI域名 (默认: ${cyan}learn.microsoft.com${none}): ")" p_sni || true
        [[ -z "$p_sni" ]] && p_sni="learn.microsoft.com"
        if is_valid_domain "$p_sni"; then break; else error "域名格式无效，请重新输入。"; fi
    done
    info "SNI 域名将使用: ${cyan}${p_sni}${none}"
}

prompt_for_ss_config() {
    local -n p_port="$1" p_pass="$2"
    local default_port="${3:-8388}"

    while true; do
        read -p "$(echo -e " -> 请输入 Shadowsocks 端口 (默认: ${cyan}${default_port}${none}): ")" p_port || true
        [[ -z "$p_port" ]] && p_port="$default_port"
        if is_port_available "$p_port"; then break; fi
    done
    info "Shadowsocks 端口将使用: ${cyan}${p_port}${none}"
    
    read -p "$(echo -e " -> 请输入 Shadowsocks 密钥 (留空将自动生成): ")" p_pass || true
    if [[ -z "$p_pass" ]]; then
        p_pass=$(generate_ss_key)
        # 修改：完整显示SS密钥
        info "已为您生成随机密钥: ${cyan}${p_pass}${none}"
    fi
}

# --- 菜单功能函数 ---
draw_divider() {
    printf "%0.s─" {1..48}
    printf "\n"
}

draw_menu_header() {
    clear
    echo -e "${cyan} Xray VLESS-Reality & Shadowsocks-2022 管理脚本${none}"
    echo -e "${yellow} Version: ${SCRIPT_VERSION}${none}"
    draw_divider
    check_xray_status
    echo -e "${xray_status_info}"
    quick_status  # 新增快速状态显示
    draw_divider
}

press_any_key_to_continue() {
    echo ""
    read -n 1 -s -r -p " 按任意键返回主菜单..." || true
}

install_menu() {
    local vless_exists="" ss_exists=""
    if [[ -f "$xray_config_path" ]]; then
        vless_exists=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
        ss_exists=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)
    fi
    
    draw_menu_header
    if [[ -n "$vless_exists" && -n "$ss_exists" ]]; then
        success "您已安装 VLESS-Reality + Shadowsocks-2022 双协议。"
        info "如需修改，请使用主菜单的"修改配置"选项。\n 如需重装，请先"卸载"后，再重新"安装"。"
        return
    elif [[ -n "$vless_exists" && -z "$ss_exists" ]]; then
        info "检测到您已安装 VLESS-Reality"
        echo -e "${cyan} 请选择下一步操作${none}"
        draw_divider
        printf "  ${green}%-2s${none} %-35s\n" "1." "追加安装 Shadowsocks-2022 (组成双协议)"
        printf "  ${red}%-2s${none} %-35s\n" "2." "覆盖重装 VLESS-Reality"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回主菜单"
        draw_divider
        read -p " 请输入选项 [0-2]: " choice || true
        case "$choice" in 1) add_ss_to_vless ;; 2) install_vless_only ;; 0) return ;; *) error "无效选项。" ;; esac
    elif [[ -z "$vless_exists" && -n "$ss_exists" ]]; then
        info "检测到您已安装 Shadowsocks-2022"
        echo -e "${cyan} 请选择下一步操作${none}"
        draw_divider
        printf "  ${green}%-2s${none} %-35s\n" "1." "追加安装 VLESS-Reality (组成双协议)"
        printf "  ${red}%-2s${none} %-35s\n" "2." "覆盖重装 Shadowsocks-2022"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回主菜单"
        draw_divider
        read -p " 请输入选项 [0-2]: " choice || true
        case "$choice" in 1) add_vless_to_ss ;; 2) install_ss_only ;; 0) return ;; *) error "无效选项。" ;; esac
    else
        clean_install_menu
    fi
}

clean_install_menu() {
    draw_menu_header
    echo -e "${cyan} 请选择要安装的协议类型${none}"
    draw_divider
    printf "  ${green}%-2s${none} %-35s\n" "1." "仅 VLESS-Reality"
    printf "  ${cyan}%-2s${none} %-35s\n" "2." "仅 Shadowsocks-2022"
    printf "  ${yellow}%-2s${none} %-35s\n" "3." "VLESS-Reality + Shadowsocks-2022 (双协议)"
    draw_divider
    printf "  ${magenta}%-2s${none} %-35s\n" "0." "返回主菜单"
    draw_divider
    read -p " 请输入选项 [0-3]: " choice || true
    case "$choice" in 1) install_vless_only ;; 2) install_ss_only ;; 3) install_dual ;; 0) return ;; *) error "无效选项。" ;; esac
}

add_ss_to_vless() {
    info "开始追加安装 Shadowsocks-2022..."
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，操作中止。请检查您的网络连接。"
        return 1
    fi
    local vless_inbound vless_port default_ss_port ss_port ss_password ss_inbound
    vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path")
    vless_port=$(echo "$vless_inbound" | jq -r '.port')
    default_ss_port=$([[ "$vless_port" == "443" ]] && echo "8388" || echo "$((vless_port + 1))")
    
    prompt_for_ss_config ss_port ss_password "$default_ss_port"

    ss_inbound=$(build_ss_inbound "$ss_port" "$ss_password")
    write_config "[$vless_inbound, $ss_inbound]"
    
    if ! restart_xray; then return 1; fi
    
    success "追加安装成功！"
    view_all_info
}

add_vless_to_ss() {
    info "开始追加安装 VLESS-Reality..."
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，操作中止。请检查您的网络连接。"
        return 1
    fi
    local ss_inbound ss_port default_vless_port vless_port vless_uuid vless_domain key_pair private_key public_key vless_inbound
    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path")
    ss_port=$(echo "$ss_inbound" | jq -r '.port')
    default_vless_port=$([[ "$ss_port" == "8388" ]] && echo "443" || echo "$((ss_port - 1))")

    prompt_for_vless_config vless_port vless_uuid vless_domain "$default_vless_port"

    info "正在生成 Reality 密钥对..."
    key_pair=$("$xray_binary_path" x25519)
    private_key=$(echo "$key_pair" | awk '/PrivateKey:/ {print $2}')
    public_key=$(echo "$key_pair" | awk '/Password:/ {print $2}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        error "生成 Reality 密钥对失败！请检查 Xray 核心是否正常，或尝试卸载后重装。"
        exit 1
    fi
    
    vless_inbound=$(build_vless_inbound "$vless_port" "$vless_uuid" "$vless_domain" "$private_key" "$public_key")
    write_config "[$vless_inbound, $ss_inbound]"
    
    if ! restart_xray; then return 1; fi
    
    success "追加安装成功！"
    view_all_info
}

install_vless_only() {
    info "开始配置 VLESS-Reality..."
    local port uuid domain
    prompt_for_vless_config port uuid domain
    run_install_vless "$port" "$uuid" "$domain"
}

install_ss_only() {
    info "开始配置 Shadowsocks-2022..."
    local port password
    prompt_for_ss_config port password
    run_install_ss "$port" "$password"
}

install_dual() {
    info "开始配置双协议 (VLESS-Reality + Shadowsocks-2022)..."
    local vless_port vless_uuid vless_domain ss_port ss_password
    prompt_for_vless_config vless_port vless_uuid vless_domain
    
    local default_ss_port
    if [[ "$vless_port" == "443" ]]; then
        default_ss_port=8388
    else
        default_ss_port=$((vless_port + 1))
    fi
    
    prompt_for_ss_config ss_port ss_password "$default_ss_port"
    
    run_install_dual "$vless_port" "$vless_uuid" "$vless_domain" "$ss_port" "$ss_password"
}

update_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装。" && return; fi
    info "正在检查最新版本..."
    local current_version latest_version
    current_version=$("$xray_binary_path" version | head -n 1 | awk '{print $2}')
    latest_version=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name' | sed 's/v//' || echo "")
    
    if [[ -z "$latest_version" ]]; then error "获取最新版本号失败，请检查网络或稍后重试。" && return; fi
    info "当前版本: ${cyan}${current_version}${none}，最新版本: ${cyan}${latest_version}${none}"
    
    if [[ "$current_version" == "$latest_version" ]]; then
        success "您的 Xray 已是最新版本。" && return
    fi
    
    info "发现新版本，开始更新..."
    run_core_install
    if ! restart_xray; then return 1; fi
    success "Xray 更新成功！"
}

uninstall_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装。" && return; fi
    read -p "$(echo -e "${yellow}您确定要卸载 Xray 吗？这将删除所有配置！[Y/n]: ${none}")" confirm || true
    if [[ "$confirm" =~ ^[nN]$ ]]; then
        info "操作已取消。"
        return
    fi
    info "正在卸载 Xray..."
    if ! execute_official_script "remove --purge"; then
        error "Xray 卸载失败！"
        return 1
    fi
    rm -f ~/xray_subscription_info.txt
    success "Xray 已成功卸载。"
}

modify_config_menu() {
    if [[ ! -f "$xray_config_path" ]]; then error "错误: Xray 未安装。" && return; fi
    
    local vless_exists="" ss_exists=""
    vless_exists=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
    ss_exists=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)
    
    if [[ -n "$vless_exists" && -n "$ss_exists" ]]; then
        draw_menu_header
        echo -e "${cyan} 请选择要修改的协议配置${none}"
        draw_divider
        printf "  ${green}%-2s${none} %-35s\n" "1." "VLESS-Reality"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "Shadowsocks-2022"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回主菜单"
        draw_divider
        read -p " 请输入选项 [0-2]: " choice || true
        case "$choice" in 1) modify_vless_config ;; 2) modify_ss_config ;; 0) return ;; *) error "无效选项。" ;; esac
    elif [[ -n "$vless_exists" ]]; then
        modify_vless_config
    elif [[ -n "$ss_exists" ]]; then
        modify_ss_config
    else
        error "未找到可修改的协议配置。"
    fi
}

modify_vless_config() {
    info "开始修改 VLESS-Reality 配置..."
    local vless_inbound current_port current_uuid current_domain private_key public_key port uuid domain new_vless_inbound ss_inbound new_inbounds
    vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path")
    current_port=$(echo "$vless_inbound" | jq -r '.port')
    current_uuid=$(echo "$vless_inbound" | jq -r '.settings.clients[0].id')
    current_domain=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.serverNames[0]')
    private_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.privateKey')
    public_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.publicKey')
    
    while true; do
        read -p "$(echo -e " -> 新端口 (当前: ${cyan}${current_port}${none}, 留空不改): ")" port || true
        [[ -z "$port" ]] && port=$current_port
        if is_port_available "$port" || [[ "$port" == "$current_port" ]]; then break; fi
    done

    read -p "$(echo -e " -> 新UUID (当前: ${cyan}${current_uuid}${none}, 留空不改): ")" uuid || true
    [[ -z "$uuid" ]] && uuid=$current_uuid
    
    while true; do
        read -p "$(echo -e " -> 新SNI域名 (当前: ${cyan}${current_domain}${none}, 留空不改): ")" domain || true
        [[ -z "$domain" ]] && domain=$current_domain
        if is_valid_domain "$domain"; then break; else error "域名格式无效，请重新输入。"; fi
    done
    
    new_vless_inbound=$(build_vless_inbound "$port" "$uuid" "$domain" "$private_key" "$public_key")
    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)
    new_inbounds="[$new_vless_inbound]"
    [[ -n "$ss_inbound" ]] && new_inbounds="[$new_vless_inbound, $ss_inbound]"
    
    write_config "$new_inbounds"
    if ! restart_xray; then return 1; fi

    success "配置修改成功！"
    view_all_info
}

modify_ss_config() {
    info "开始修改 Shadowsocks-2022 配置..."
    local ss_inbound current_port current_password port password new_ss_inbound vless_inbound new_inbounds
    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path")
    current_port=$(echo "$ss_inbound" | jq -r '.port')
    current_password=$(echo "$ss_inbound" | jq -r '.settings.password')
    
    while true; do
        read -p "$(echo -e " -> 新端口 (当前: ${cyan}${current_port}${none}, 留空不改): ")" port || true
        [[ -z "$port" ]] && port=$current_port
        if is_port_available "$port" || [[ "$port" == "$current_port" ]]; then break; fi
    done

    # 修改：完整显示当前SS密钥
    read -p "$(echo -e " -> 新密钥 (当前: ${cyan}${current_password}${none}, 留空不改): ")" password || true
    [[ -z "$password" ]] && password=$current_password
    
    new_ss_inbound=$(build_ss_inbound "$port" "$password")
    vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
    new_inbounds="[$new_ss_inbound]"
    [[ -n "$vless_inbound" ]] && new_inbounds="[$vless_inbound, $new_ss_inbound]"
    
    write_config "$new_inbounds"
    if ! restart_xray; then return 1; fi

    success "配置修改成功！"
    view_all_info
}

restart_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装。" && return 1; fi
    
    info "正在重启 Xray 服务..."
    if ! systemctl restart xray; then
        error "尝试重启 Xray 服务失败！"
        # 新增：显示详细错误信息
        echo -e "\n${yellow}错误详情:${none}"
        systemctl status xray --no-pager -l | tail -5
        return 1
    fi
    
    # 等待时间稍微延长，确保服务完全启动
    sleep 2
    if systemctl is-active --quiet xray; then
        success "Xray 服务已成功重启！"
    else
        error "服务启动失败，详细信息:"
        systemctl status xray --no-pager -l | tail -5
        return 1
    fi
}

view_xray_log() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装。" && return; fi
    info "正在显示 Xray 实时日志... 按 Ctrl+C 退出。"
    journalctl -u xray -f --no-pager
}

view_all_info() {
    if [ ! -f "$xray_config_path" ]; then
        [[ "$is_quiet" = true ]] && return
        error "错误: 配置文件不存在。"
        return
    fi
    
    [[ "$is_quiet" = false ]] && clear && echo -e "${cyan} Xray 配置及订阅信息${none}" && draw_divider

    local ip
    ip=$(get_public_ip)
    if [[ -z "$ip" ]]; then
        [[ "$is_quiet" = false ]] && error "无法获取公网 IP 地址。"
        return 1
    fi
    local host
    host=$(hostname)
    local links_array=()

    local vless_inbound
    vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
    if [[ -n "$vless_inbound" ]]; then
        local uuid port domain public_key shortid display_ip link_name_raw link_name_encoded vless_url
        uuid=$(echo "$vless_inbound" | jq -r '.settings.clients[0].id')
        port=$(echo "$vless_inbound" | jq -r '.port')
        domain=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.serverNames[0]')
        public_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.publicKey')
        shortid=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.shortIds[0]')
        
        if [[ -z "$public_key" ]]; then
            [[ "$is_quiet" = false ]] && error "VLESS配置不完整，可能已损坏。"
        else
            display_ip=$ip && [[ $ip =~ ":" ]] && display_ip="[$ip]"
            link_name_raw="$host X-reality"
            link_name_encoded=$(echo "$link_name_raw" | sed 's/ /%20/g')
            vless_url="vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}#${link_name_encoded}"
            links_array+=("$vless_url")

            if [[ "$is_quiet" = false ]]; then
                echo -e "${green} [ VLESS-Reality 配置 ]${none}"
                printf "    %s: ${cyan}%s${none}\n" "节点名称" "$link_name_raw"
                printf "    %s: ${cyan}%s${none}\n" "服务器地址" "$ip"
                printf "    %s: ${cyan}%s${none}\n" "端口" "$port"
                printf "    %s: ${cyan}%s${none}\n" "UUID" "${uuid}"
                printf "    %s: ${cyan}%s${none}\n" "流控" "xtls-rprx-vision"
                printf "    %s: ${cyan}%s${none}\n" "传输协议" "tcp"
                printf "    %s: ${cyan}%s${none}\n" "安全类型" "reality"
                printf "    %s: ${cyan}%s${none}\n" "SNI" "$domain"
                printf "    %s: ${cyan}%s${none}\n" "指纹" "chrome"
                printf "    %s: ${cyan}%s${none}\n" "PublicKey" "${public_key}"
                printf "    %s: ${cyan}%s${none}\n" "ShortId" "$shortid"
            fi
        fi
    fi

    local ss_inbound
    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)
    if [[ -n "$ss_inbound" ]]; then
        local port method password link_name_raw user_info_base64 ss_url
        port=$(echo "$ss_inbound" | jq -r '.port')
        method=$(echo "$ss_inbound" | jq -r '.settings.method')
        password=$(echo "$ss_inbound" | jq -r '.settings.password')
        link_name_raw="$host X-ss2022"
        user_info_base64=$(echo -n "${method}:${password}" | base64 -w 0)
        ss_url="ss://${user_info_base64}@${ip}:${port}#${link_name_raw}"
        links_array+=("$ss_url")
        
        if [[ "$is_quiet" = false ]]; then
            echo ""
            echo -e "${green} [ Shadowsocks-2022 配置 ]${none}"
            printf "    %s: ${cyan}%s${none}\n" "节点名称" "$link_name_raw"
            printf "    %s: ${cyan}%s${none}\n" "服务器地址" "$ip"
            printf "    %s: ${cyan}%s${none}\n" "端口" "$port"
            printf "    %s: ${cyan}%s${none}\n" "加密方式" "$method"
            # 修改：完整显示SS密钥
            printf "    %s: ${cyan}%s${none}\n" "密码" "${password}"
        fi
    fi

    if [ ${#links_array[@]} -gt 0 ]; then
        if [[ "$is_quiet" = true ]]; then
            printf "%s\n" "${links_array[@]}"
        else
            draw_divider
            printf "%s\n" "${links_array[@]}" > ~/xray_subscription_info.txt
            success "所有订阅链接已汇总保存到: ~/xray_subscription_info.txt"
            
            echo -e "\n${yellow} --- V2Ray / Clash 等客户端可直接导入以下链接 --- ${none}\n"
            for link in "${links_array[@]}"; do
                echo -e "${cyan}${link}${none}\n"
            done
            draw_divider
        fi
    elif [[ "$is_quiet" = false ]]; then
        info "当前未安装任何协议，无订阅信息可显示。"
    fi
}

# --- 核心安装逻辑函数 ---
run_install_vless() {
    local port="$1" uuid="$2" domain="$3"
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，安装中止。请检查您的网络连接。"
        exit 1
    fi
    run_core_install || exit 1
    info "正在生成 Reality 密钥对..."
    local key_pair private_key public_key vless_inbound
    key_pair=$("$xray_binary_path" x25519)
    private_key=$(echo "$key_pair" | awk '/PrivateKey:/ {print $2}')
    public_key=$(echo "$key_pair" | awk '/Password:/ {print $2}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        error "生成 Reality 密钥对失败！请检查 Xray 核心是否正常，或尝试卸载后重装。"
        exit 1
    fi

    vless_inbound=$(build_vless_inbound "$port" "$uuid" "$domain" "$private_key" "$public_key")
    write_config "[$vless_inbound]"
    
    if ! restart_xray; then exit 1; fi

    success "VLESS-Reality 安装成功！"
    view_all_info
}

run_install_ss() {
    local port="$1" password="$2"
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，安装中止。请检查您的网络连接。"
        exit 1
    fi
    run_core_install || exit 1
    local ss_inbound
    ss_inbound=$(build_ss_inbound "$port" "$password")
    write_config "[$ss_inbound]"

    if ! restart_xray; then exit 1; fi

    success "Shadowsocks-2022 安装成功！"
    view_all_info
}

run_install_dual() {
    local vless_port="$1" vless_uuid="$2" vless_domain="$3" ss_port="$4" ss_password="$5"
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，安装中止。请检查您的网络连接。"
        exit 1
    fi
    run_core_install || exit 1
    info "正在生成 Reality 密钥对..."
    local key_pair private_key public_key vless_inbound ss_inbound
    key_pair=$("$xray_binary_path" x25519)
    private_key=$(echo "$key_pair" | awk '/PrivateKey:/ {print $2}')
    public_key=$(echo "$key_pair" | awk '/Password:/ {print $2}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        error "生成 Reality 密钥对失败！请检查 Xray 核心是否正常，或尝试卸载后重装。"
        exit 1
    fi

    vless_inbound=$(build_vless_inbound "$vless_port" "$vless_uuid" "$vless_domain" "$private_key" "$public_key")
    ss_inbound=$(build_ss_inbound "$ss_port" "$ss_password")
    write_config "[$vless_inbound, $ss_inbound]"
    
    if ! restart_xray; then exit 1; fi

    success "双协议安装成功！"
    view_all_info
}

# --- 主菜单与脚本入口 ---
main_menu() {
    while true; do
        draw_menu_header
        printf "  ${green}%-2s${none} %-35s\n" "1." "安装 Xray (VLESS/Shadowsocks)"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "更新 Xray"
        printf "  ${red}%-2s${none} %-35s\n" "3." "卸载 Xray"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "4." "修改配置"
        printf "  ${cyan}%-2s${none} %-35s\n" "5." "重启 Xray"
        printf "  ${magenta}%-2s${none} %-35s\n" "6." "查看 Xray 日志"
        printf "  ${green}%-2s${none} %-35s\n" "7." "查看订阅信息"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "退出脚本"
        draw_divider
        
        read -p " 请输入选项 [0-7]: " choice || true
        
        local needs_pause=true
        
        case "$choice" in
            1) install_menu ;;
            2) update_xray ;;
            3) uninstall_xray ;;
            4) modify_config_menu ;;
            5) restart_xray ;;
            6) view_xray_log; needs_pause=false ;;
            7) view_all_info ;;
            0) success "感谢使用！"; exit 0 ;;
            *) error "无效选项。请输入0到7之间的数字。" ;;
        esac
        
        if [ "$needs_pause" = true ]; then
            press_any_key_to_continue
        fi
    done
}

# --- 非交互式安装逻辑 ---
non_interactive_usage() {
    cat << 'EOF'

非交互式安装用法:
  ./$(basename "$0") install --type <vless|ss|dual> [选项...]

  通用选项:
    --type <type>      安装类型 (必须: vless, ss, dual)
    --quiet            静默模式, <em>成功</em>后只输出订阅链接

  VLESS 选项:
    --vless-port <p>   VLESS 端口 (默认: 443)
    --uuid <uuid>      UUID (默认: 随机生成)
    --sni <domain>     SNI 域名 (默认: learn.microsoft.com)

  Shadowsocks 选项:
    --ss-port <p>      Shadowsocks 端口 (默认: 8388)
    --ss-pass <pass>   Shadowsocks 密码 (默认: 随机生成)

  示例:
    # 安装 VLESS (使用默认值)
    ./$(basename "$0") install --type vless

    # 安静地安装双协议并指定 VLESS 端口和 UUID，并将链接保存到文件
    ./$(basename "$0") install --type dual --vless-port 2053 --uuid 'your-uuid-here' --quiet > links.txt
EOF
}

non_interactive_dispatcher() {
    if [[ $# -eq 0 || "$1" != "install" ]]; then
        main_menu
        return
    fi
    shift

    local type="" vless_port="" uuid="" sni="" ss_port="" ss_pass=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type) type="$2"; shift 2 ;;
            --vless-port) vless_port="$2"; shift 2 ;;
            --uuid) uuid="$2"; shift 2 ;;
            --sni) sni="$2"; shift 2 ;;
            --ss-port) ss_port="$2"; shift 2 ;;
            --ss-pass) ss_pass="$2"; shift 2 ;;
            --quiet) is_quiet=true; shift ;;
            *) error "未知参数: $1"; non_interactive_usage; exit 1 ;;
        esac
    done

    case "$type" in
        vless)
            [[ -z "$vless_port" ]] && vless_port=443
            [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid)
            [[ -z "$sni" ]] && sni="learn.microsoft.com"
            if ! is_valid_port "$vless_port" || ! is_valid_domain "$sni"; then
                error "VLESS 参数无效。请检查端口或SNI域名。" && non_interactive_usage && exit 1
            fi
            info "开始非交互式安装 VLESS..."
            run_install_vless "$vless_port" "$uuid" "$sni"
            ;;
        ss)
            [[ -z "$ss_port" ]] && ss_port=8388
            [[ -z "$ss_pass" ]] && ss_pass=$(generate_ss_key)
            if ! is_valid_port "$ss_port"; then
                error "Shadowsocks 参数无效。请检查端口。" && non_interactive_usage && exit 1
            fi
            info "开始非交互式安装 Shadowsocks..."
            run_install_ss "$ss_port" "$ss_pass"
            ;;
        dual)
            [[ -z "$vless_port" ]] && vless_port=443
            [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid)
            [[ -z "$sni" ]] && sni="learn.microsoft.com"
            [[ -z "$ss_pass" ]] && ss_pass=$(generate_ss_key)
            if [[ -z "$ss_port" ]]; then
                if [[ "$vless_port" == "443" ]]; then ss_port=8388; else ss_port=$((vless_port + 1)); fi
            fi
            if ! is_valid_port "$vless_port" || ! is_valid_domain "$sni" || ! is_valid_port "$ss_port"; then
                error "双协议参数无效。请检查端口或SNI域名。" && non_interactive_usage && exit 1
            fi
            info "开始非交互式安装双协议..."
            run_install_dual "$vless_port" "$uuid" "$sni" "$ss_port" "$ss_pass"
            ;;
        *)
            error "必须通过 --type 指定安装类型 (vless|ss|dual)"
            non_interactive_usage
            exit 1
            ;;
    esac
}

# --- 脚本主入口 ---
main() {
    pre_check
    non_interactive_dispatcher "$@"
}

main "$@"

__MY_XRAY_PAYLOAD__
    chmod +x "$tmp" 2>/dev/null || true
    bash "$tmp" "$@"
    local rc=$?
    rm -f "$tmp" 2>/dev/null || true
    return $rc
}

xray_menu() {
    xray_module_run
}

main_menu() {
    clear 2>/dev/null || true
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}          my 综合管理 v${MY_VERSION}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${YELLOW} 1.${RESET} 状态页 / 快捷导航"
    echo -e "${YELLOW} 2.${RESET} 优化中心"
    echo -e "${YELLOW} 3.${RESET} Xray / 节点中心"
    echo -e "${YELLOW} 4.${RESET} DDNS / 建站 / DD 中心"
    echo -e "${YELLOW} 5.${RESET} 脚本更新"
    echo -e "${YELLOW} 6.${RESET} 清理残留 / 卸载"
    echo -e " 0. 退出"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    read -rp "请输入数字 [0-6]: " choice
    case "$choice" in
        1) status_page_loop ;;
        2) optimize_menu ;;
        3) xray_menu ;;
        4) services_menu ;;
        5) github_update; read -n 1 -s -r -p "按任意键继续..." ;;
        6) uninstall_menu ;;
        0) exit 0 ;;
        *) msg_err "无效选项"; sleep 1 ;;
    esac
}

init() {
    require_root
    ensure_state_dirs
    ensure_base_tools
    install_self_command
    ensure_global_clean_cron
    cron_remove_regex '(^|\s)(/usr/local/bin/nftmgr|/usr/local/bin/ssr|/usr/local/bin/xray)(\s|$)'
}

if [[ $# -gt 0 ]]; then
    require_root
    ensure_state_dirs
    ensure_base_tools
    install_self_command
    case "$1" in
        clean|daily_clean)
            daily_clean
            exit 0
            ;;
        status)
            status_page_loop
            exit 0
            ;;
        optimize)
            shift
            case "${1:-menu}" in
                menu) optimize_menu ;;
                general) apply_general_extreme_opt ;;
                nat) apply_nat_extreme_opt ;;
                *) msg_err "未知 optimize 子命令"; exit 1 ;;
            esac
            exit $?
            ;;
        dns)
            shift
            case "${1:-status}" in
                auto) dns_auto_tune ;;
                manual) dns_manual_set ;;
                status) dns_status ;;
                unlock|restore) dns_unlock_restore ;;
                *) msg_err "未知 dns 子命令"; exit 1 ;;
            esac
            exit $?
            ;;
        github)
            shift
            case "${1:-keys}" in
                keys|known-hosts) github_keys_auto_fetch ;;
                *) msg_err "未知 github 子命令"; exit 1 ;;
            esac
            exit $?
            ;;
        ssh)
            shift
            case "${1:-menu}" in
                port) change_ssh_port ;;
                passwd) change_root_password ;;
                disable-passwd) disable_password_login ;;
                enable-passwd) restore_password_login ;;
                *) msg_err "未知 ssh 子命令"; exit 1 ;;
            esac
            exit $?
            ;;
        nginx)
            shift
            case "${1:-menu}" in
                menu) nginx_menu ;;
                install) ensure_nginx_installed ;;
                list) nginx_list_sites ;;
                delete) shift; nginx_delete_site "$1" ;;
                repair) nginx_repair ;;
                *) msg_err "未知 nginx 子命令"; exit 1 ;;
            esac
            exit $?
            ;;
        ddns)
            shift
            case "${1:-menu}" in
                menu) ddns_menu ;;
                setup) ddns_setup ;;
                update) ddns_update_now ;;
                status) ddns_status ;;
                install-cron) ddns_install_cron ;;
                remove) ddns_remove ;;
                *) msg_err "未知 ddns 子命令"; exit 1 ;;
            esac
            exit $?
            ;;
        dd)
            dd_menu
            exit 0
            ;;
        xray)
            shift
            xray_module_run "$@"
            exit $?
            ;;
        update)
            github_update
            exit $?
            ;;
        purge|cleanup-legacy)
            legacy_cleanup
            exit $?
            ;;
        *)
            msg_err "未知参数。可用：my status | my optimize <menu|general|nat> | my dns <auto|manual|status|restore> | my github keys | my ssh <port|passwd|disable-passwd|enable-passwd> | my nginx <menu|install|list|delete 域名|repair> | my ddns <menu|setup|update|status|install-cron|remove> | my xray [install --type vless|ss|dual ...] | my dd | my update | my purge"
            exit 1
            ;;
    esac
fi

init
while true; do
    main_menu
done
