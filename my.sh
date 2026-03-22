#!/bin/bash
# my 综合极限管理脚本（深度合并版）
# 合并内容：优化 / DNS / SSH / GitHub known_hosts / DDNS / Nginx / DD / Xray(VLESS-Reality + SS2022)
# 特性：
# 1) 深度合并两个脚本的核心能力
# 2) 修复与增强：配置校验、回滚、完整卸载、节点按序号查看/删除
# 3) 支持按极限档应用系统优化
# 4) 一键完整卸载：删除脚本、状态、Xray、定时任务、脚本托管内容

set -o pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

CMD_NAME="${CMD_NAME:-my}"
MY_SCRIPT_ID="${MY_SCRIPT_ID:-my-manager}"
MY_VERSION="${MY_VERSION:-3.0.0-merged}"

MY_STATE_DIR="${MY_STATE_DIR:-/usr/local/lib/my/state}"
DNS_STATE_DIR="${DNS_STATE_DIR:-${MY_STATE_DIR}/dns}"
DDNS_STATE_DIR="${DDNS_STATE_DIR:-${MY_STATE_DIR}/ddns}"
NGINX_STATE_DIR="${NGINX_STATE_DIR:-${MY_STATE_DIR}/nginx}"

REINSTALL_WORKDIR="${REINSTALL_WORKDIR:-/tmp/my-reinstall}"
REINSTALL_SCRIPT_PATH="${REINSTALL_SCRIPT_PATH:-${REINSTALL_WORKDIR}/reinstall.sh}"

SSH_PORT_DROPIN="${SSH_PORT_DROPIN:-/etc/ssh/sshd_config.d/00-my-port.conf}"
SSH_AUTH_DROPIN="${SSH_AUTH_DROPIN:-/etc/ssh/sshd_config.d/00-my-auth.conf}"
SYSCTL_OPT_FILE="${SYSCTL_OPT_FILE:-/etc/sysctl.d/99-my-optimizer.conf}"
DNS_BACKUP_FILE="${DNS_BACKUP_FILE:-${DNS_STATE_DIR}/resolv.conf.bak}"
DNS_META_FILE="${DNS_META_FILE:-${DNS_STATE_DIR}/meta.conf}"
DDNS_CFG_FILE="${DDNS_CFG_FILE:-${DDNS_STATE_DIR}/cloudflare.env}"
DDNS_LOG_FILE="${DDNS_LOG_FILE:-${DDNS_STATE_DIR}/update.log}"
NGINX_SITE_LIST_FILE="${NGINX_SITE_LIST_FILE:-${NGINX_STATE_DIR}/sites.list}"
GITHUB_KNOWN_HOSTS="${GITHUB_KNOWN_HOSTS:-/root/.ssh/known_hosts}"

XRAY_CFG_DIR="${XRAY_CFG_DIR:-/usr/local/etc/xray}"
XRAY_CFG_FILE="${XRAY_CFG_FILE:-${XRAY_CFG_DIR}/config.json}"
XRAY_BINARY_PATH="${XRAY_BINARY_PATH:-/usr/local/bin/xray}"
XRAY_INSTALL_URL_DIRECT="${XRAY_INSTALL_URL_DIRECT:-https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh}"
XRAY_INSTALL_URL_PROXY="${XRAY_INSTALL_URL_PROXY:-https://mirror.ghproxy.com/https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh}"
XRAY_LAST_LINK_FILE="${XRAY_LAST_LINK_FILE:-${MY_STATE_DIR}/xray_subscription_info.txt}"
XRAY_LAST_LOG_FILE="${XRAY_LAST_LOG_FILE:-${MY_STATE_DIR}/xray_install.log}"

UPDATE_URL_DIRECT="${UPDATE_URL_DIRECT:-}"
UPDATE_URL_PROXY="${UPDATE_URL_PROXY:-}"

REINSTALL_UPSTREAM_GLOBAL="${REINSTALL_UPSTREAM_GLOBAL:-https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh}"
REINSTALL_UPSTREAM_CN="${REINSTALL_UPSTREAM_CN:-https://cnb.cool/bin456789/reinstall/-/git/raw/main/reinstall.sh}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
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
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        msg_err "错误：必须使用 root 权限运行。"
        exit 1
    fi
}

script_realpath() {
    local target="${BASH_SOURCE[0]:-$0}"
    if have_cmd readlink; then
        readlink -f "$target" 2>/dev/null && return 0
    fi
    if have_cmd realpath; then
        realpath "$target" 2>/dev/null && return 0
    fi
    printf '%s\n' "$target"
}

menu_pause() {
    echo
    read -n 1 -s -r -p "按任意键继续..." || true
    echo
}

clear_screen() {
    clear 2>/dev/null || true
}

base64_nw() {
    if base64 --help 2>/dev/null | grep -q -- '-w'; then
        base64 -w 0
    else
        base64 | tr -d '\r\n'
    fi
}

urlencode() {
    if have_cmd python3; then
        python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
    else
        printf '%s' "$1" | sed 's/ /%20/g'
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
    mkdir -p \
        "$MY_STATE_DIR" \
        "$DNS_STATE_DIR" \
        "$DDNS_STATE_DIR" \
        "$NGINX_STATE_DIR" \
        "$XRAY_CFG_DIR" \
        /root/.ssh \
        >/dev/null 2>&1 || true
}

install_self_command() {
    local self
    self="$(script_realpath)"
    if [[ -f "$self" && "$self" != "/usr/local/bin/${CMD_NAME}" ]]; then
        cp -f "$self" "/usr/local/bin/${CMD_NAME}" 2>/dev/null || true
        chmod +x "/usr/local/bin/${CMD_NAME}" 2>/dev/null || true
    fi
}

pkg_update_once() {
    if have_cmd apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        run_with_timeout 30 apt-get update -y >/dev/null 2>&1 || run_with_timeout 30 apt-get update >/dev/null 2>&1 || return 1
        return 0
    fi
    return 0
}

pkg_install() {
    if have_cmd apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        run_with_timeout 120 apt-get install -y "$@"
    elif have_cmd dnf; then
        run_with_timeout 120 dnf install -y "$@"
    elif have_cmd yum; then
        run_with_timeout 120 yum install -y "$@"
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
    have_cmd openssl || missing+=(openssl)
    if [[ ${#missing[@]} -gt 0 ]]; then
        pkg_update_once >/dev/null 2>&1 || true
        pkg_install "${missing[@]}" >/dev/null 2>&1 || true
    fi
}

ensure_json_tools() {
    local missing=()
    have_cmd jq || missing+=(jq)
    have_cmd python3 || missing+=(python3)
    if [[ ${#missing[@]} -gt 0 ]]; then
        pkg_update_once >/dev/null 2>&1 || true
        pkg_install "${missing[@]}" >/dev/null 2>&1 || true
    fi
    have_cmd jq && have_cmd python3
}

random_id() {
    if have_cmd openssl; then
        openssl rand -hex 8 2>/dev/null | tr 'A-Z' 'a-z'
    else
        date +%s | sha256sum 2>/dev/null | cut -c1-16
    fi
}

random_shortid() {
    if have_cmd openssl; then
        openssl rand -hex 8 2>/dev/null | tr 'A-Z' 'a-z'
    else
        printf '%s' "$(random_id)" | cut -c1-16
    fi
}

random_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    elif have_cmd python3; then
        python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
    else
        printf '%s\n' "00000000-0000-4000-8000-$(date +%s | sha256sum | cut -c1-12)"
    fi
}

generate_ss_key() {
    if have_cmd openssl; then
        openssl rand -base64 16 2>/dev/null | tr -d '\r\n'
    else
        date +%s | sha256sum | cut -c1-24
    fi
}

download_to() {
    local url="$1" dest="$2"
    [[ -n "$url" && -n "$dest" ]] || return 1
    if have_cmd curl; then
        curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 1 -o "$dest" "$url"
    elif have_cmd wget; then
        wget -qO "$dest" "$url"
    else
        return 1
    fi
}

normalize_text_file() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    sed -i '1s/^ï»¿//' "$f" 2>/dev/null || true
    tr -d '\r' < "$f" > "${f}.lf" 2>/dev/null && mv -f "${f}.lf" "$f" || true
    return 0
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

is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

is_valid_domain() {
    local d="$1"
    [[ -n "$d" ]] || return 1
    [[ "$d" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "$d" == *.* ]] || return 1
    [[ "$d" != .* && "$d" != *- && "$d" != -* && "$d" != *. ]] || return 1
    [[ "$d" != *..* ]] || return 1
    return 0
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
    dnf autoremove -y >/dev/null 2>&1 || true
    dnf clean all >/dev/null 2>&1 || true
    yum autoremove -y >/dev/null 2>&1 || true
    yum clean all >/dev/null 2>&1 || true
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

write_optimizer_profile() {
    local profile="$1"
    printf 'profile=%s\nupdated_at=%s\n' "$profile" "$(date '+%F %T')" > "$MY_STATE_DIR/optimizer.conf"
}

sysctl_key_exists() {
    local key="$1"
    [[ -e "/proc/sys/${key//./\/}" ]]
}

apply_sysctl_lines() {
    local profile="$1"
    shift
    : > "$SYSCTL_OPT_FILE"
    local line key
    for line in "$@"; do
        key="${line%%=*}"
        key="${key// /}"
        if sysctl_key_exists "$key"; then
            printf '%s\n' "$line" >> "$SYSCTL_OPT_FILE"
        else
            printf '# skip unsupported: %s\n' "$line" >> "$SYSCTL_OPT_FILE"
        fi
    done
    sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_OPT_FILE" >/dev/null 2>&1 || true
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

apply_hyper_extreme_opt() {
    apply_sysctl_lines "hyper-extreme" \
"net.core.default_qdisc = fq" \
"net.ipv4.tcp_congestion_control = bbr" \
"net.core.netdev_max_backlog = 32768" \
"net.core.somaxconn = 32768" \
"net.core.rmem_default = 1048576" \
"net.core.wmem_default = 1048576" \
"net.core.rmem_max = 268435456" \
"net.core.wmem_max = 268435456" \
"net.ipv4.tcp_rmem = 4096 1048576 268435456" \
"net.ipv4.tcp_wmem = 4096 65536 268435456" \
"net.ipv4.udp_rmem_min = 8192" \
"net.ipv4.udp_wmem_min = 8192" \
"net.ipv4.tcp_fastopen = 3" \
"net.ipv4.tcp_mtu_probing = 1" \
"net.ipv4.tcp_slow_start_after_idle = 0" \
"net.ipv4.ip_local_port_range = 10240 65535" \
"net.ipv4.tcp_fin_timeout = 15" \
"net.ipv4.tcp_keepalive_time = 600" \
"net.ipv4.tcp_keepalive_intvl = 30" \
"net.ipv4.tcp_keepalive_probes = 5" \
"net.ipv4.tcp_syn_retries = 3" \
"net.ipv4.tcp_synack_retries = 3" \
"net.ipv4.tcp_tw_reuse = 1" \
"net.ipv4.tcp_max_syn_backlog = 32768" \
"net.ipv4.tcp_max_tw_buckets = 2000000" \
"net.netfilter.nf_conntrack_max = 524288" \
"net.netfilter.nf_conntrack_buckets = 131072" \
"net.netfilter.nf_conntrack_tcp_timeout_established = 1200" \
"net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30" \
"fs.file-max = 1048576" \
"vm.max_map_count = 262144" \
"vm.swappiness = 10"
}

_dns_now_ms() {
    date +%s%3N 2>/dev/null || python3 - <<'PY'
import time
print(int(time.time()*1000))
PY
}

dns_candidate_servers() {
    cat <<'EOF'
223.5.5.5|aliyun
223.6.6.6|aliyun
119.29.29.29|tencent
1.12.12.12|tencent
180.76.76.76|baidu
1.1.1.1|cloudflare
8.8.8.8|google
9.9.9.9|quad9
94.140.14.14|adguard
EOF
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
    local tool line ip provider ms used="|"
    tool="$(ensure_dns_probe_tool 2>/dev/null || echo none)"
    [[ "$tool" != none ]] || return 1
    while IFS='|' read -r ip provider; do
        [[ -n "$ip" ]] || continue
        ms="$(dns_probe_avg_ms "$tool" "$ip" 2>/dev/null || true)"
        [[ "$ms" =~ ^[0-9]+$ ]] || continue
        printf '%s|%s|%s\n' "$ms" "$ip" "$provider"
    done < <(dns_candidate_servers) | sort -n | while IFS='|' read -r ms ip provider; do
        if [[ "$used" != *"|$provider|"* ]]; then
            echo "$ip"
            used+="$provider|"
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
    cat > /etc/systemd/resolved.conf.d/99-my-dns.conf <<EOF
[Resolve]
DNS=${servers}
Domains=~.
Cache=yes
DNSSEC=allow-downgrade
EOF
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
        msg_warn "DNS 探测耗时过长，已自动回退到安全组。"
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
    cat > "$SSH_PORT_DROPIN" <<EOF
Port ${port}
EOF
}

write_ssh_auth_dropin() {
    local pass_mode="$1"
    mkdir -p "$(dirname "$SSH_AUTH_DROPIN")" 2>/dev/null || true
    cat > "$SSH_AUTH_DROPIN" <<EOF
PasswordAuthentication ${pass_mode}
KbdInteractiveAuthentication ${pass_mode}
ChallengeResponseAuthentication ${pass_mode}
EOF
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
    is_valid_port "$new_port" || { msg_err "端口格式或范围错误。"; return 1; }
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
    local tmp keys_ok=0
    mkdir -p /root/.ssh 2>/dev/null || true
    touch "$GITHUB_KNOWN_HOSTS" 2>/dev/null || true
    chmod 600 "$GITHUB_KNOWN_HOSTS" 2>/dev/null || true
    tmp="$(mktemp /tmp/my-ghkeys.XXXXXX)" || return 1
    if download_to "https://api.github.com/meta" "$tmp" >/dev/null 2>&1; then
        if have_cmd python3; then
            python3 - "$tmp" "$GITHUB_KNOWN_HOSTS" <<'PY'
import json,sys
meta=json.load(open(sys.argv[1],'r',encoding='utf-8'))
keys=meta.get('ssh_keys',[])
out=[]
for k in keys:
    out.append(f"github.com {k}")
    out.append(f"ssh.github.com {k}")
existing=set()
try:
    with open(sys.argv[2],'r',encoding='utf-8') as f:
        existing={line.rstrip('\n') for line in f if line.strip()}
except FileNotFoundError:
    pass
with open(sys.argv[2],'a',encoding='utf-8') as f:
    for line in out:
        if line not in existing:
            f.write(line+'\n')
PY
            keys_ok=1
        fi
    fi
    rm -f "$tmp"
    if (( keys_ok == 0 )) && have_cmd ssh-keyscan; then
        run_with_timeout 8 ssh-keyscan github.com ssh.github.com 2>/dev/null >> "$GITHUB_KNOWN_HOSTS" && keys_ok=1 || true
    fi
    if (( keys_ok == 1 )); then
        sort -u "$GITHUB_KNOWN_HOSTS" -o "$GITHUB_KNOWN_HOSTS" 2>/dev/null || true
        msg_ok "GitHub 主机密钥已自动获取并写入 known_hosts。"
        return 0
    fi
    msg_err "GitHub 主机密钥获取失败。"
    return 1
}

remove_github_known_hosts_entries() {
    local tmp
    [[ -f "$GITHUB_KNOWN_HOSTS" ]] || return 0
    tmp="$(mktemp /tmp/my-gh-known-hosts.XXXXXX)" || return 0
    grep -Ev '^(github\.com|ssh\.github\.com)[ ,]' "$GITHUB_KNOWN_HOSTS" > "$tmp" || true
    cat "$tmp" > "$GITHUB_KNOWN_HOSTS"
    rm -f "$tmp"
}

ensure_nginx_installed() {
    if have_cmd nginx; then
        return 0
    fi
    pkg_update_once >/dev/null 2>&1 || true
    pkg_install nginx >/dev/null 2>&1 || { msg_err "安装 Nginx 失败。"; return 1; }
    service_use_systemd && systemctl enable --now nginx >/dev/null 2>&1 || true
}

nginx_track_site() {
    local file="$1"
    ensure_state_dirs
    touch "$NGINX_SITE_LIST_FILE" 2>/dev/null || true
    grep -Fqx "$file" "$NGINX_SITE_LIST_FILE" 2>/dev/null || echo "$file" >> "$NGINX_SITE_LIST_FILE"
}

nginx_untrack_site() {
    local file="$1" tmp
    [[ -f "$NGINX_SITE_LIST_FILE" ]] || return 0
    tmp="$(mktemp /tmp/my-nginx-sites.XXXXXX)" || return 0
    grep -Fvx "$file" "$NGINX_SITE_LIST_FILE" > "$tmp" || true
    mv -f "$tmp" "$NGINX_SITE_LIST_FILE"
}

nginx_list_sites_raw() {
    find /etc/nginx/conf.d /etc/nginx/sites-enabled -maxdepth 1 \( -type f -o -type l \) -name '*.conf' 2>/dev/null | sort
}

nginx_list_sites() {
    local files=() file idx=0
    while read -r file; do
        [[ -n "$file" ]] && files+=("$file")
    done < <(nginx_list_sites_raw)
    if [[ ${#files[@]} -eq 0 ]]; then
        echo "未发现站点配置。"
        return 0
    fi
    for file in "${files[@]}"; do
        idx=$((idx+1))
        printf '%2d. %s\n' "$idx" "$(basename "$file")"
    done
}

nginx_get_site_file_by_index() {
    local idx="$1" cur=0 file
    while read -r file; do
        [[ -n "$file" ]] || continue
        cur=$((cur+1))
        if (( cur == idx )); then
            printf '%s\n' "$file"
            return 0
        fi
    done < <(nginx_list_sites_raw)
    return 1
}

nginx_add_reverse_proxy() {
    local domain upstream file
    ensure_nginx_installed || return 1
    read -rp "域名: " domain
    read -rp "反代上游（例如 127.0.0.1:3000）: " upstream
    [[ -n "$domain" && -n "$upstream" ]] || { msg_err "域名和上游不能为空。"; return 1; }
    file="/etc/nginx/conf.d/${domain}.conf"
    cat > "$file" <<EOF
# MY_MANAGED_SITE=1
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
EOF
    nginx -t || { rm -f "$file"; msg_err "Nginx 配置校验失败。"; return 1; }
    service_use_systemd && systemctl reload nginx >/dev/null 2>&1 || nginx -s reload >/dev/null 2>&1
    nginx_track_site "$file"
    msg_ok "反向代理站点已创建：${domain} -> ${upstream}"
}

nginx_delete_site() {
    local arg="${1:-}" file domain
    if [[ -z "$arg" ]]; then
        nginx_list_sites
        read -rp "请输入要删除的站点序号或域名: " arg
    fi
    if [[ "$arg" =~ ^[0-9]+$ ]]; then
        file="$(nginx_get_site_file_by_index "$arg" 2>/dev/null || true)"
        [[ -n "$file" ]] || { msg_err "未找到对应序号。"; return 1; }
    else
        domain="$arg"
        file="/etc/nginx/conf.d/${domain}.conf"
        [[ -e "$file" ]] || file="/etc/nginx/sites-enabled/${domain}.conf"
    fi
    [[ -e "$file" ]] || { msg_err "站点不存在。"; return 1; }
    rm -f "$file" 2>/dev/null || true
    nginx_untrack_site "$file"
    nginx -t >/dev/null 2>&1 || true
    service_use_systemd && systemctl reload nginx >/dev/null 2>&1 || nginx -s reload >/dev/null 2>&1 || true
    msg_ok "已删除站点：$(basename "$file")"
}

nginx_repair() {
    ensure_nginx_installed || return 1
    nginx -t || { msg_err "Nginx 配置校验失败。"; return 1; }
    service_use_systemd && systemctl restart nginx >/dev/null 2>&1 || nginx -s reload >/dev/null 2>&1
    msg_ok "Nginx 已修复并重载。"
}

nginx_remove_tracked_sites() {
    local file
    [[ -f "$NGINX_SITE_LIST_FILE" ]] || return 0
    while read -r file; do
        [[ -n "$file" ]] || continue
        rm -f "$file" 2>/dev/null || true
    done < "$NGINX_SITE_LIST_FILE"
    rm -f "$NGINX_SITE_LIST_FILE" 2>/dev/null || true
    if have_cmd nginx; then
        nginx -t >/dev/null 2>&1 || true
        service_use_systemd && systemctl reload nginx >/dev/null 2>&1 || nginx -s reload >/dev/null 2>&1 || true
    fi
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
        cur=cur.get(part) if isinstance(cur,dict) else None
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
    local token zone record proxied ttl zone_id record_id public_ip create_payload tmp
    ensure_json_tools || { msg_err "缺少 jq/python3，无法配置 DDNS。"; return 1; }
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
    cat > "$tmp" <<EOF
CF_API_TOKEN=${token}
CF_ZONE_NAME=${zone}
RECORD_NAME=${record}
PROXIED=${proxied}
TTL=${ttl}
EOF
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

xray_installed() {
    [[ -x "$XRAY_BINARY_PATH" ]]
}

xray_config_exists() {
    [[ -s "$XRAY_CFG_FILE" ]]
}

xray_service_user() {
    local u
    if service_use_systemd; then
        u="$(systemctl cat xray 2>/dev/null | awk -F= '/^[[:space:]]*User=/{print $2; exit}')"
        [[ -z "$u" ]] && u="$(awk -F= '/^[[:space:]]*User=/{print $2; exit}' /etc/systemd/system/xray.service /lib/systemd/system/xray.service /usr/lib/systemd/system/xray.service 2>/dev/null)"
    fi
    [[ -n "$u" ]] || u="nobody"
    printf '%s' "$u"
}

xray_fix_permissions() {
    local svc_user svc_group
    [[ -f "$XRAY_CFG_FILE" ]] || return 0
    svc_user="$(xray_service_user 2>/dev/null || echo nobody)"
    svc_group="$(id -gn "$svc_user" 2>/dev/null || true)"
    if [[ "$svc_user" == "root" ]]; then
        chown root:root "$XRAY_CFG_FILE" 2>/dev/null || true
        chmod 600 "$XRAY_CFG_FILE" 2>/dev/null || true
    elif [[ -n "$svc_group" ]]; then
        chown root:"$svc_group" "$XRAY_CFG_FILE" 2>/dev/null || true
        chmod 640 "$XRAY_CFG_FILE" 2>/dev/null || true
    else
        chmod 644 "$XRAY_CFG_FILE" 2>/dev/null || true
    fi
}

xray_download_install_script() {
    local tmp rc=1 url
    tmp="$(mktemp /tmp/my-xray-install.XXXXXX.sh)" || return 1
    for url in "$XRAY_INSTALL_URL_DIRECT" "$XRAY_INSTALL_URL_PROXY"; do
        [[ -n "$url" ]] || continue
        : > "$tmp"
        if download_to "$url" "$tmp" >/dev/null 2>&1; then
            normalize_text_file "$tmp"
            if grep -q 'install_xray' "$tmp" && grep -q 'install-release' "$tmp"; then
                printf '%s\n' "$tmp"
                return 0
            fi
        fi
    done
    rm -f "$tmp"
    return $rc
}

xray_execute_official_script() {
    local log="$XRAY_LAST_LOG_FILE" tmp
    tmp="$(xray_download_install_script)" || { msg_err "下载 Xray 官方安装脚本失败。"; return 1; }
    ensure_state_dirs
    if bash "$tmp" "$@" >"$log" 2>&1; then
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    msg_err "Xray 官方脚本执行失败，最后日志如下："
    tail -n 40 "$log" 2>/dev/null || true
    return 1
}

xray_base_config() {
    cat <<'EOF'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "UseIPv4v6"
      }
    }
  ]
}
EOF
}

xray_ensure_base_config() {
    ensure_state_dirs
    ensure_json_tools || { msg_err "缺少 jq/python3，无法管理 Xray 配置。"; return 1; }
    if [[ ! -f "$XRAY_CFG_FILE" ]]; then
        xray_base_config > "$XRAY_CFG_FILE"
        xray_fix_permissions
    fi
    xray_sanitize_config >/dev/null 2>&1 || true
    return 0
}

xray_sanitize_config() {
    local tmp
    [[ -f "$XRAY_CFG_FILE" ]] || return 0
    ensure_json_tools || return 1
    tmp="$(mktemp /tmp/my-xray-cfg.XXXXXX.json)" || return 1
    if ! jq '
      .inbounds = ((.inbounds // []) | map(
        if .protocol == "vless" and (.streamSettings.security // "") == "reality" then
          .streamSettings.realitySettings |= (
            if has("dest") and (has("target") | not) then .target = .dest else . end
            | del(.publicKey)
            | del(.password)
          )
        else
          .
        end
      ))
      | .outbounds = (.outbounds // [{"protocol":"freedom","tag":"direct","settings":{"domainStrategy":"UseIPv4v6"}}])
    ' "$XRAY_CFG_FILE" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$XRAY_CFG_FILE"
    xray_fix_permissions
}

xray_validate_json_file() {
    local file="$1"
    jq empty "$file" >/dev/null 2>&1
}

xray_test_config_file() {
    local file="$1"
    xray_validate_json_file "$file" || return 1
    if xray_installed; then
        "$XRAY_BINARY_PATH" run -test -c "$file" >/tmp/my-xray-test.log 2>&1 || {
            msg_err "Xray 配置测试失败："
            tail -n 20 /tmp/my-xray-test.log 2>/dev/null || true
            return 1
        }
    fi
    return 0
}

xray_restart_service() {
    if ! xray_installed; then
        msg_warn "Xray 尚未安装。"
        return 1
    fi
    if service_use_systemd; then
        if ! systemctl cat xray >/dev/null 2>&1 && [[ ! -f /etc/systemd/system/xray.service ]] && [[ ! -f /lib/systemd/system/xray.service ]] && [[ ! -f /usr/lib/systemd/system/xray.service ]]; then
            msg_warn "未发现 xray.service，已完成配置写入，但未执行服务重启。"
            return 0
        fi
        systemctl daemon-reload >/dev/null 2>&1 || true
        if systemctl is-enabled xray >/dev/null 2>&1; then
            systemctl restart xray >/dev/null 2>&1 || {
                msg_err "Xray 重启失败。"
                systemctl status xray --no-pager -l | tail -n 20
                return 1
            }
        else
            systemctl enable --now xray >/dev/null 2>&1 || {
                msg_err "Xray 启动失败。"
                systemctl status xray --no-pager -l | tail -n 20
                return 1
            }
        fi
    else
        if have_cmd service && service xray status >/dev/null 2>&1; then
            service xray restart >/dev/null 2>&1 || {
                msg_err "Xray 重启失败。"
                return 1
            }
        else
            msg_warn "未发现受服务管理的 Xray，已完成配置写入，但未执行服务重启。"
            return 0
        fi
    fi
    if service_use_systemd && systemctl is-active --quiet xray; then
        msg_ok "Xray 服务已重启。"
        return 0
    fi
    return 0
}

xray_stop_service() {
    if service_use_systemd; then
        systemctl stop xray >/dev/null 2>&1 || true
        systemctl disable xray >/dev/null 2>&1 || true
    else
        service xray stop >/dev/null 2>&1 || true
    fi
}

xray_commit_config() {
    local tmp="$1" bak
    [[ -f "$tmp" ]] || return 1
    xray_validate_json_file "$tmp" || { msg_err "生成的配置 JSON 非法。"; rm -f "$tmp"; return 1; }
    if xray_installed && ! xray_test_config_file "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if [[ -f "$XRAY_CFG_FILE" ]]; then
        bak="${XRAY_CFG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp -f "$XRAY_CFG_FILE" "$bak" 2>/dev/null || true
    fi
    mv -f "$tmp" "$XRAY_CFG_FILE"
    xray_fix_permissions
    if xray_installed; then
        if ! xray_restart_service; then
            if [[ -n "$bak" && -f "$bak" ]]; then
                cp -f "$bak" "$XRAY_CFG_FILE" 2>/dev/null || true
                xray_fix_permissions
                xray_restart_service >/dev/null 2>&1 || true
            fi
            msg_err "新配置已回滚。"
            return 1
        fi
    fi
    return 0
}

xray_install_core() {
    local had_cfg=0
    [[ -f "$XRAY_CFG_FILE" ]] && had_cfg=1
    ensure_json_tools || { msg_err "缺少 jq/python3，无法安装 Xray。"; return 1; }
    msg_info "正在安装/升级 Xray 核心..."
    xray_execute_official_script install || return 1
    if (( had_cfg == 0 )); then
        mkdir -p "$XRAY_CFG_DIR" 2>/dev/null || true
        xray_base_config > "$XRAY_CFG_FILE"
    fi
    xray_ensure_base_config || return 1
    xray_fix_permissions
    msg_ok "Xray 核心已安装/升级。"
}

xray_update_core() {
    xray_installed || { msg_err "Xray 未安装。"; return 1; }
    msg_info "正在更新 Xray Core / GeoData..."
    xray_execute_official_script install || return 1
    xray_fix_permissions
    xray_restart_service >/dev/null 2>&1 || true
    msg_ok "Xray 已更新。"
}

xray_remove_files_manual() {
    xray_stop_service
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service 2>/dev/null || true
    rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d 2>/dev/null || true
    rm -f /etc/logrotate.d/xray /etc/systemd/system/logrotate@.service /etc/systemd/system/logrotate@.timer 2>/dev/null || true
    rm -f /usr/local/bin/xray 2>/dev/null || true
    rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray 2>/dev/null || true
    rm -f ~/xray_subscription_info.txt 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
}

xray_uninstall_core() {
    msg_info "正在卸载 Xray..."
    xray_execute_official_script remove --purge >/dev/null 2>&1 || true
    xray_remove_files_manual
    rm -f "$XRAY_LAST_LINK_FILE" "$XRAY_LAST_LOG_FILE" 2>/dev/null || true
    msg_ok "Xray 已完整卸载。"
}

xray_install_core_if_needed() {
    xray_installed && return 0
    xray_install_core
}

xray_get_version() {
    if xray_installed; then
        "$XRAY_BINARY_PATH" version 2>/dev/null | head -n1 | awk '{print $2}'
    else
        echo ""
    fi
}

xray_x25519_generate() {
    local out private public
    xray_installed || return 1
    out="$("$XRAY_BINARY_PATH" x25519 2>/dev/null)" || return 1
    private="$(printf '%s\n' "$out" | awk -F': ' '/^PrivateKey:|^Private key:/{print $2; exit}')"
    public="$(printf '%s\n' "$out" | awk -F': ' '/^PublicKey:|^Public key:|^Password:/{print $2; exit}')"
    [[ -n "$private" && -n "$public" ]] || return 1
    printf '%s|%s\n' "$private" "$public"
}

xray_public_from_private() {
    local private="$1" out public
    [[ -n "$private" ]] || return 1
    xray_installed || return 1
    out="$("$XRAY_BINARY_PATH" x25519 -i "$private" 2>/dev/null)" || return 1
    public="$(printf '%s\n' "$out" | awk -F': ' '/^PublicKey:|^Public key:|^Password:/{print $2; exit}')"
    [[ -n "$public" ]] || return 1
    printf '%s\n' "$public"
}

xray_managed_node_count() {
    [[ -f "$XRAY_CFG_FILE" ]] || { echo 0; return 0; }
    jq '[.inbounds[]? | select(.protocol=="vless" or .protocol=="shadowsocks")] | length' "$XRAY_CFG_FILE" 2>/dev/null || echo 0
}

xray_config_index_by_serial() {
    local idx="$1"
    [[ "$idx" =~ ^[0-9]+$ ]] || return 1
    jq -r --argjson idx "$((idx-1))" '
      [ .inbounds | to_entries[] | select(.value.protocol=="vless" or .value.protocol=="shadowsocks") ][$idx].key // empty
    ' "$XRAY_CFG_FILE" 2>/dev/null
}

xray_node_json_by_serial() {
    local idx="$1"
    [[ "$idx" =~ ^[0-9]+$ ]] || return 1
    jq -c --argjson idx "$((idx-1))" '
      [ .inbounds | to_entries[] | select(.value.protocol=="vless" or .value.protocol=="shadowsocks") ][$idx].value // empty
    ' "$XRAY_CFG_FILE" 2>/dev/null
}

xray_node_name() {
    local proto="$1" port="$2" h
    h="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo server)"
    case "$proto" in
        vless) printf '%s-vless-%s' "$h" "$port" ;;
        shadowsocks) printf '%s-ss2022-%s' "$h" "$port" ;;
        *) printf '%s-%s-%s' "$h" "$proto" "$port" ;;
    esac
}

xray_public_ip() {
    ddns_detect_public_ip 2>/dev/null \
        || ip route get 1.1.1.1 2>/dev/null | awk '/src /{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' \
        || hostname -I 2>/dev/null | awk '{print $1}' \
        || getent ahostsv4 "$(hostname -f 2>/dev/null || hostname)" 2>/dev/null | awk '{print $1; exit}'
}

xray_list_nodes() {
    local count idx proto port target name
    count="$(xray_managed_node_count)"
    if [[ "$count" == "0" ]]; then
        msg_warn "当前没有任何 VLESS / SS2022 节点。"
        return 0
    fi
    echo "序号 | 协议 | 端口 | 名称 | 目标"
    echo "-----|------|------|------|------"
    for (( idx=1; idx<=count; idx++ )); do
        proto="$(xray_node_json_by_serial "$idx" | jq -r '.protocol')"
        port="$(xray_node_json_by_serial "$idx" | jq -r '.port')"
        if [[ "$proto" == "vless" ]]; then
            target="$(xray_node_json_by_serial "$idx" | jq -r '.streamSettings.realitySettings.serverNames[0] // .streamSettings.realitySettings.target // .streamSettings.realitySettings.dest // "-"')"
        else
            target="-"
        fi
        name="$(xray_node_name "$proto" "$port")"
        printf '%4d | %-12s | %-5s | %-18s | %s\n' "$idx" "$proto" "$port" "$name" "$target"
    done
}

xray_vless_link_from_json() {
    local node_json="$1" ip display_ip uuid port sni shortid private_key public_key name encoded_name
    ip="$(xray_public_ip)"
    [[ -n "$ip" ]] || { msg_err "无法获取公网 IP。"; return 1; }
    uuid="$(jq -r '.settings.clients[0].id // empty' <<<"$node_json")"
    port="$(jq -r '.port // empty' <<<"$node_json")"
    sni="$(jq -r '.streamSettings.realitySettings.serverNames[0] // empty' <<<"$node_json")"
    shortid="$(jq -r '.streamSettings.realitySettings.shortIds[0] // empty' <<<"$node_json")"
    private_key="$(jq -r '.streamSettings.realitySettings.privateKey // empty' <<<"$node_json")"
    public_key="$(jq -r '.streamSettings.realitySettings.publicKey // .streamSettings.realitySettings.password // empty' <<<"$node_json")"
    if [[ -z "$public_key" && -n "$private_key" ]]; then
        public_key="$(xray_public_from_private "$private_key" 2>/dev/null || true)"
    fi
    [[ -n "$uuid" && -n "$port" && -n "$sni" && -n "$shortid" && -n "$public_key" ]] || {
        msg_err "VLESS 节点信息不完整，无法生成链接。"
        return 1
    }
    display_ip="$ip"
    [[ "$ip" == *:* ]] && display_ip="[$ip]"
    name="$(xray_node_name vless "$port")"
    encoded_name="$(urlencode "$name")"
    printf 'vless://%s@%s:%s?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s#%s\n' \
        "$uuid" "$display_ip" "$port" "$sni" "$public_key" "$shortid" "$encoded_name"
}

xray_ss_link_from_json() {
    local node_json="$1" ip port method password name encoded_name info_b64
    ip="$(xray_public_ip)"
    [[ -n "$ip" ]] || { msg_err "无法获取公网 IP。"; return 1; }
    port="$(jq -r '.port // empty' <<<"$node_json")"
    method="$(jq -r '.settings.method // empty' <<<"$node_json")"
    password="$(jq -r '.settings.password // empty' <<<"$node_json")"
    [[ -n "$port" && -n "$method" && -n "$password" ]] || { msg_err "SS 节点信息不完整，无法生成链接。"; return 1; }
    name="$(xray_node_name shadowsocks "$port")"
    encoded_name="$(urlencode "$name")"
    info_b64="$(printf '%s' "${method}:${password}" | base64_nw)"
    printf 'ss://%s@%s:%s#%s\n' "$info_b64" "$ip" "$port" "$encoded_name"
}

xray_link_by_serial() {
    local idx="$1" node_json proto link
    [[ -f "$XRAY_CFG_FILE" ]] || { msg_err "Xray 配置不存在。"; return 1; }
    node_json="$(xray_node_json_by_serial "$idx")"
    [[ -n "$node_json" && "$node_json" != "null" ]] || { msg_err "序号不存在。"; return 1; }
    proto="$(jq -r '.protocol' <<<"$node_json")"
    case "$proto" in
        vless) link="$(xray_vless_link_from_json "$node_json")" || return 1 ;;
        shadowsocks) link="$(xray_ss_link_from_json "$node_json")" || return 1 ;;
        *) msg_err "不支持的协议：$proto"; return 1 ;;
    esac
    printf '%s\n' "$link"
}

xray_view_link_by_serial() {
    local idx="$1" link node_json proto port name
    link="$(xray_link_by_serial "$idx")" || return 1
    node_json="$(xray_node_json_by_serial "$idx")"
    proto="$(jq -r '.protocol' <<<"$node_json")"
    port="$(jq -r '.port' <<<"$node_json")"
    name="$(xray_node_name "$proto" "$port")"
    echo -e "序号: ${YELLOW}${idx}${RESET}"
    echo -e "协议: ${YELLOW}${proto}${RESET}"
    echo -e "名称: ${YELLOW}${name}${RESET}"
    echo -e "端口: ${YELLOW}${port}${RESET}"
    echo -e "链接:"
    echo "$link"
}

xray_view_all_links() {
    local count idx link
    count="$(xray_managed_node_count)"
    if [[ "$count" == "0" ]]; then
        msg_warn "当前没有节点链接可显示。"
        return 0
    fi
    : > "$XRAY_LAST_LINK_FILE"
    for (( idx=1; idx<=count; idx++ )); do
        echo "[$idx]" | tee -a "$XRAY_LAST_LINK_FILE"
        link="$(xray_link_by_serial "$idx" 2>/dev/null || true)"
        if [[ -n "$link" ]]; then
            echo "$link" | tee -a "$XRAY_LAST_LINK_FILE"
        else
            echo "生成失败" | tee -a "$XRAY_LAST_LINK_FILE"
        fi
        echo | tee -a "$XRAY_LAST_LINK_FILE"
    done
    msg_ok "全部节点链接已输出，并保存到：$XRAY_LAST_LINK_FILE"
}

xray_delete_node_by_serial() {
    local idx="$1" cfg_idx tmp remaining
    [[ -f "$XRAY_CFG_FILE" ]] || { msg_err "Xray 配置不存在。"; return 1; }
    cfg_idx="$(xray_config_index_by_serial "$idx" 2>/dev/null || true)"
    [[ "$cfg_idx" =~ ^[0-9]+$ ]] || { msg_err "序号不存在。"; return 1; }
    tmp="$(mktemp /tmp/my-xray-cfg.XXXXXX.json)" || return 1
    jq --argjson idx "$cfg_idx" 'del(.inbounds[$idx])' "$XRAY_CFG_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
    remaining="$(jq '[.inbounds[]? | select(.protocol=="vless" or .protocol=="shadowsocks")] | length' "$tmp" 2>/dev/null || echo 0)"
    if ! xray_commit_config "$tmp"; then
        return 1
    fi
    if [[ "$remaining" == "0" ]]; then
        xray_stop_service >/dev/null 2>&1 || true
        msg_warn "当前已无任何节点，Xray 服务已停止。"
    fi
    msg_ok "序号 ${idx} 对应节点已删除。"
}

xray_prompt_port() {
    local default_port="$1" label="${2:-端口}" value
    while true; do
        read -rp "${label} (默认 ${default_port}): " value
        [[ -z "$value" ]] && value="$default_port"
        is_valid_port "$value" || { msg_err "端口格式或范围错误。"; continue; }
        if port_in_use "$value"; then
            msg_warn "端口 ${value} 已被占用，请更换。"
            continue
        fi
        printf '%s\n' "$value"
        return 0
    done
}

xray_prompt_uuid() {
    local value
    read -rp "UUID（留空自动生成）: " value
    [[ -n "$value" ]] || value="$(random_uuid)"
    printf '%s\n' "$value"
}

xray_prompt_domain() {
    local default_domain="${1:-learn.microsoft.com}" value
    while true; do
        read -rp "SNI/伪装域名 (默认 ${default_domain}): " value
        [[ -z "$value" ]] && value="$default_domain"
        is_valid_domain "$value" || { msg_err "域名格式无效。"; continue; }
        printf '%s\n' "$value"
        return 0
    done
}

xray_prompt_ss_password() {
    local value
    read -rp "SS2022 密码（留空自动生成）: " value
    [[ -n "$value" ]] || value="$(generate_ss_key)"
    printf '%s\n' "$value"
}

xray_build_vless_inbound() {
    local port="$1" uuid="$2" domain="$3" private_key="$4" shortid="$5" tag="$6"
    jq -n \
      --argjson port "$port" \
      --arg uuid "$uuid" \
      --arg domain "$domain" \
      --arg target "${domain}:443" \
      --arg private_key "$private_key" \
      --arg shortid "$shortid" \
      --arg tag "$tag" '
      {
        "tag": $tag,
        "listen": "0.0.0.0",
        "port": $port,
        "protocol": "vless",
        "settings": {
          "clients": [
            {
              "id": $uuid,
              "flow": "xtls-rprx-vision",
              "email": $tag
            }
          ],
          "decryption": "none"
        },
        "streamSettings": {
          "network": "tcp",
          "security": "reality",
          "realitySettings": {
            "show": false,
            "target": $target,
            "xver": 0,
            "serverNames": [$domain],
            "privateKey": $private_key,
            "shortIds": [$shortid]
          }
        },
        "sniffing": {
          "enabled": true,
          "destOverride": ["http", "tls", "quic"]
        }
      }'
}

xray_build_ss_inbound() {
    local port="$1" password="$2" tag="$3"
    jq -n \
      --argjson port "$port" \
      --arg password "$password" \
      --arg tag "$tag" '
      {
        "tag": $tag,
        "listen": "0.0.0.0",
        "port": $port,
        "protocol": "shadowsocks",
        "settings": {
          "method": "2022-blake3-aes-128-gcm",
          "password": $password
        },
        "sniffing": {
          "enabled": true,
          "destOverride": ["http", "tls", "quic"]
        }
      }'
}

xray_append_inbounds_json() {
    local payload="$1" tmp
    xray_ensure_base_config || return 1
    tmp="$(mktemp /tmp/my-xray-cfg.XXXXXX.json)" || return 1
    jq --argjson payload "$payload" '
      .inbounds = ((.inbounds // []) + $payload)
      | .outbounds = (.outbounds // [{"protocol":"freedom","tag":"direct","settings":{"domainStrategy":"UseIPv4v6"}}])
    ' "$XRAY_CFG_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
    xray_commit_config "$tmp"
}

xray_add_vless_node() {
    local port uuid domain shortid keypair private_key public_key tag inbound_json
    xray_install_core_if_needed || return 1
    port="$(xray_prompt_port 443 "VLESS 端口")" || return 1
    uuid="$(xray_prompt_uuid)" || return 1
    domain="$(xray_prompt_domain "learn.microsoft.com")" || return 1
    shortid="$(random_shortid)"
    keypair="$(xray_x25519_generate)" || { msg_err "生成 Reality 密钥对失败。"; return 1; }
    private_key="${keypair%%|*}"
    public_key="${keypair#*|}"
    tag="my-vless-${port}-$(random_id)"
    inbound_json="$(xray_build_vless_inbound "$port" "$uuid" "$domain" "$private_key" "$shortid" "$tag")" || return 1
    xray_append_inbounds_json "[$inbound_json]" || return 1
    msg_ok "VLESS-Reality 节点已创建。"
    echo -e "客户端公钥/Password: ${YELLOW}${public_key}${RESET}"
    xray_view_link_by_serial "$(xray_managed_node_count)"
}

xray_add_ss_node() {
    local port password tag inbound_json
    xray_install_core_if_needed || return 1
    port="$(xray_prompt_port 8388 "SS2022 端口")" || return 1
    password="$(xray_prompt_ss_password)" || return 1
    tag="my-ss-${port}-$(random_id)"
    inbound_json="$(xray_build_ss_inbound "$port" "$password" "$tag")" || return 1
    xray_append_inbounds_json "[$inbound_json]" || return 1
    msg_ok "Shadowsocks-2022 节点已创建。"
    xray_view_link_by_serial "$(xray_managed_node_count)"
}

xray_add_dual_nodes() {
    local vless_port uuid domain ss_port password shortid keypair private_key public_key vless_tag ss_tag vless_json ss_json
    xray_install_core_if_needed || return 1
    vless_port="$(xray_prompt_port 443 "VLESS 端口")" || return 1
    uuid="$(xray_prompt_uuid)" || return 1
    domain="$(xray_prompt_domain "learn.microsoft.com")" || return 1
    if [[ "$vless_port" == "443" ]]; then
        ss_port="$(xray_prompt_port 8388 "SS2022 端口")" || return 1
    else
        ss_port="$(xray_prompt_port "$((vless_port + 1))" "SS2022 端口")" || return 1
    fi
    password="$(xray_prompt_ss_password)" || return 1
    shortid="$(random_shortid)"
    keypair="$(xray_x25519_generate)" || { msg_err "生成 Reality 密钥对失败。"; return 1; }
    private_key="${keypair%%|*}"
    public_key="${keypair#*|}"
    vless_tag="my-vless-${vless_port}-$(random_id)"
    ss_tag="my-ss-${ss_port}-$(random_id)"
    vless_json="$(xray_build_vless_inbound "$vless_port" "$uuid" "$domain" "$private_key" "$shortid" "$vless_tag")" || return 1
    ss_json="$(xray_build_ss_inbound "$ss_port" "$password" "$ss_tag")" || return 1
    xray_append_inbounds_json "[$vless_json, $ss_json]" || return 1
    msg_ok "双节点（VLESS + SS2022）已创建。"
    echo -e "客户端公钥/Password: ${YELLOW}${public_key}${RESET}"
    xray_view_all_links
}

status_xray_line() {
    local ver count active
    if ! xray_installed; then
        echo -e "  Xray: $(status_colorize warn '未安装')"
        return
    fi
    ver="$(xray_get_version)"
    count="$(xray_managed_node_count)"
    if service_use_systemd && systemctl is-active --quiet xray 2>/dev/null; then
        active="运行中"
    else
        active="未运行"
    fi
    echo -e "  Xray: $(status_colorize info "$active") / 版本 ${YELLOW}${ver:-未知}${RESET} / 节点 ${YELLOW}${count}${RESET}"
}

xray_view_logs() {
    xray_installed || { msg_err "Xray 未安装。"; return 1; }
    msg_info "正在显示 Xray 实时日志，按 Ctrl+C 退出。"
    journalctl -u xray -f --no-pager
}

legacy_cleanup() {
    local svc
    msg_warn "开始清理旧代理/转发残留（不触碰当前 Xray 节点中心）..."
    for svc in ss-rust ss-v2ray nftmgr; do
        if service_use_systemd; then
            systemctl stop "$svc" >/dev/null 2>&1 || true
            systemctl disable "$svc" >/dev/null 2>&1 || true
        fi
        rm -f "/etc/systemd/system/${svc}.service" "/lib/systemd/system/${svc}.service" "/usr/lib/systemd/system/${svc}.service" 2>/dev/null || true
    done
    rm -rf /etc/ss-rust /etc/ss-v2ray /usr/local/lib/my/cache/xray 2>/dev/null || true
    rm -f /usr/local/bin/ss-rust /usr/local/bin/nftmgr 2>/dev/null || true
    service_use_systemd && systemctl daemon-reload >/dev/null 2>&1 || true
    msg_ok "旧代理/转发残留已清理。"
}

remove_self_update_task() {
    cron_remove_regex '/usr/local/bin/my clean'
    cron_remove_regex '/usr/local/bin/my ddns update'
}

reset_sysctl_profile() {
    rm -f "$SYSCTL_OPT_FILE" 2>/dev/null || true
    sysctl --system >/dev/null 2>&1 || true
    rm -f "$MY_STATE_DIR/optimizer.conf" 2>/dev/null || true
}

restore_ssh_dropins() {
    rm -f "$SSH_PORT_DROPIN" "$SSH_AUTH_DROPIN" 2>/dev/null || true
    if have_cmd sshd; then
        sshd -t >/dev/null 2>&1 && restart_ssh_service >/dev/null 2>&1 || true
    fi
}

full_uninstall_my() {
    local self
    self="$(script_realpath)"
    msg_warn "开始完整卸载当前脚本及其托管内容..."
    ddns_remove >/dev/null 2>&1 || true
    dns_unlock_restore >/dev/null 2>&1 || true
    reset_sysctl_profile
    restore_ssh_dropins
    nginx_remove_tracked_sites
    xray_uninstall_core >/dev/null 2>&1 || true
    legacy_cleanup >/dev/null 2>&1 || true
    remove_github_known_hosts_entries
    remove_self_update_task
    rm -rf "$MY_STATE_DIR" "$REINSTALL_WORKDIR" 2>/dev/null || true
    rm -f "/usr/local/bin/${CMD_NAME}" 2>/dev/null || true
    if [[ -n "$self" ]]; then
        rm -f "$self" 2>/dev/null || true
    fi
    msg_ok "当前脚本及其托管内容已完整卸载。"
    exit 0
}

github_update() {
    if [[ -z "$UPDATE_URL_DIRECT" && -z "$UPDATE_URL_PROXY" ]]; then
        msg_warn "当前深度合并版未绑定在线更新源，避免被旧版上游覆盖。"
        return 0
    fi
    msg_warn "当前版本未启用在线更新。"
}

fetch_reinstall_script() {
    mkdir -p "$REINSTALL_WORKDIR" 2>/dev/null || true
    download_to "$REINSTALL_UPSTREAM_GLOBAL" "$REINSTALL_SCRIPT_PATH" || download_to "$REINSTALL_UPSTREAM_CN" "$REINSTALL_SCRIPT_PATH" || return 1
    chmod +x "$REINSTALL_SCRIPT_PATH" 2>/dev/null || true
    [[ -s "$REINSTALL_SCRIPT_PATH" ]]
}

dd_menu() {
    while true; do
        clear_screen
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}             DD / 重装系统中心             ${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${YELLOW} 1.${RESET} Debian 13"
        echo -e "${YELLOW} 2.${RESET} Debian 12"
        echo -e "${YELLOW} 3.${RESET} Ubuntu 24.04"
        echo -e " 0. 返回"
        read -rp "请输入数字 [0-3]: " choice
        case "$choice" in
            1) fetch_reinstall_script || { msg_err "下载重装脚本失败。"; menu_pause; continue; }; bash "$REINSTALL_SCRIPT_PATH" debian 13 ;;
            2) fetch_reinstall_script || { msg_err "下载重装脚本失败。"; menu_pause; continue; }; bash "$REINSTALL_SCRIPT_PATH" debian 12 ;;
            3) fetch_reinstall_script || { msg_err "下载重装脚本失败。"; menu_pause; continue; }; bash "$REINSTALL_SCRIPT_PATH" ubuntu 24.04 ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

optimize_menu() {
    while true; do
        clear_screen
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}                优化中心                    ${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${YELLOW} 1.${RESET} 常规机器极致优化"
        echo -e "${YELLOW} 2.${RESET} NAT 小鸡极致优化"
        echo -e "${YELLOW} 3.${RESET} 全项超极限优化"
        echo -e "${YELLOW} 4.${RESET} DNS 智能调优（防卡死版）"
        echo -e "${YELLOW} 5.${RESET} 手动设置 DNS"
        echo -e "${YELLOW} 6.${RESET} 查看 DNS 状态"
        echo -e "${YELLOW} 7.${RESET} 恢复 DNS"
        echo -e "${YELLOW} 8.${RESET} 自动获取 GitHub 主机密钥"
        echo -e "${YELLOW} 9.${RESET} 修改 SSH 端口"
        echo -e "${YELLOW}10.${RESET} 修改 root 密码"
        echo -e "${YELLOW}11.${RESET} 关闭 SSH 密码登录"
        echo -e "${YELLOW}12.${RESET} 恢复 SSH 密码登录"
        echo -e "${YELLOW}13.${RESET} 运行日常清理"
        echo -e " 0. 返回"
        read -rp "请输入数字 [0-13]: " choice
        case "$choice" in
            1) apply_general_extreme_opt && msg_ok "常规机器极致优化已应用。"; menu_pause ;;
            2) apply_nat_extreme_opt && msg_ok "NAT 小鸡极致优化已应用。"; menu_pause ;;
            3) apply_hyper_extreme_opt && msg_ok "全项超极限优化已应用。"; menu_pause ;;
            4) dns_auto_tune; menu_pause ;;
            5) dns_manual_set; menu_pause ;;
            6) dns_status; menu_pause ;;
            7) dns_unlock_restore; menu_pause ;;
            8) github_keys_auto_fetch; menu_pause ;;
            9) change_ssh_port; menu_pause ;;
            10) change_root_password; menu_pause ;;
            11) disable_password_login; menu_pause ;;
            12) restore_password_login; menu_pause ;;
            13) daily_clean; msg_ok "清理完成。"; menu_pause ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

nginx_menu() {
    while true; do
        clear_screen
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}              Nginx 建站与反代            ${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${YELLOW} 1.${RESET} 安装 / 启动 Nginx"
        echo -e "${YELLOW} 2.${RESET} 新建反向代理站点"
        echo -e "${YELLOW} 3.${RESET} 查看站点列表"
        echo -e "${YELLOW} 4.${RESET} 删除站点（支持序号）"
        echo -e "${YELLOW} 5.${RESET} 修复 / 重载 Nginx"
        echo -e " 0. 返回"
        read -rp "请输入数字 [0-5]: " choice
        case "$choice" in
            1) ensure_nginx_installed; msg_ok "Nginx 已安装 / 启动。"; menu_pause ;;
            2) nginx_add_reverse_proxy; menu_pause ;;
            3) nginx_list_sites; menu_pause ;;
            4) nginx_delete_site; menu_pause ;;
            5) nginx_repair; menu_pause ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

ddns_menu() {
    while true; do
        clear_screen
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
            1) ddns_setup; menu_pause ;;
            2) ddns_update_now; menu_pause ;;
            3) ddns_status; menu_pause ;;
            4) ddns_install_cron; menu_pause ;;
            5) ddns_remove; menu_pause ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

xray_menu_header() {
    local ver nodes running
    ver="$(xray_get_version)"
    nodes="$(xray_managed_node_count)"
    if xray_installed && service_use_systemd && systemctl is-active --quiet xray 2>/dev/null; then
        running="运行中"
    elif xray_installed; then
        running="未运行"
    else
        running="未安装"
    fi
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}             Xray / 节点中心               ${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "状态: ${YELLOW}${running}${RESET} / 版本 ${YELLOW}${ver:-未安装}${RESET} / 节点 ${YELLOW}${nodes}${RESET}"
    echo -e "${CYAN}--------------------------------------------${RESET}"
}

xray_menu() {
    while true; do
        clear_screen
        xray_menu_header
        echo -e "${YELLOW} 1.${RESET} 安装 / 修复 Xray 核心"
        echo -e "${YELLOW} 2.${RESET} 新增 VLESS-Reality 节点"
        echo -e "${YELLOW} 3.${RESET} 新增 Shadowsocks-2022 节点"
        echo -e "${YELLOW} 4.${RESET} 一键新增双节点（VLESS + SS2022）"
        echo -e "${YELLOW} 5.${RESET} 查看节点列表（带序号）"
        echo -e "${YELLOW} 6.${RESET} 按序号查看节点链接"
        echo -e "${YELLOW} 7.${RESET} 按序号删除节点"
        echo -e "${YELLOW} 8.${RESET} 查看全部节点链接"
        echo -e "${YELLOW} 9.${RESET} 重启 Xray"
        echo -e "${YELLOW}10.${RESET} 查看 Xray 日志"
        echo -e "${YELLOW}11.${RESET} 更新 Xray Core / GeoData"
        echo -e "${YELLOW}12.${RESET} 完整卸载 Xray"
        echo -e " 0. 返回"
        read -rp "请输入数字 [0-12]: " choice
        case "$choice" in
            1) xray_install_core; menu_pause ;;
            2) xray_add_vless_node; menu_pause ;;
            3) xray_add_ss_node; menu_pause ;;
            4) xray_add_dual_nodes; menu_pause ;;
            5) xray_list_nodes; menu_pause ;;
            6) xray_list_nodes; read -rp "请输入节点序号: " idx; xray_view_link_by_serial "$idx"; menu_pause ;;
            7) xray_list_nodes; read -rp "请输入要删除的节点序号: " idx; xray_delete_node_by_serial "$idx"; menu_pause ;;
            8) xray_view_all_links; menu_pause ;;
            9) xray_restart_service; menu_pause ;;
            10) xray_view_logs ;;
            11) xray_update_core; menu_pause ;;
            12) xray_uninstall_core; menu_pause ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

services_menu() {
    while true; do
        clear_screen
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}          DDNS / 建站 / DD 中心           ${RESET}"
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

uninstall_menu() {
    while true; do
        clear_screen
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}              清理残留 / 卸载               ${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${YELLOW} 1.${RESET} 清理旧代理 / 转发残留"
        echo -e "${YELLOW} 2.${RESET} 执行日常清理"
        echo -e "${YELLOW} 3.${RESET} 完整卸载 Xray"
        echo -e "${RED} 4.${RESET} 一键完整卸载当前脚本（含脚本本身）"
        echo -e " 0. 返回"
        read -rp "请输入数字 [0-4]: " choice
        case "$choice" in
            1) legacy_cleanup; menu_pause ;;
            2) daily_clean; msg_ok "清理完成。"; menu_pause ;;
            3) xray_uninstall_core; menu_pause ;;
            4) read -rp "确认执行完整卸载？这会删除脚本本身及托管内容 [Y/n]: " c; [[ "$c" =~ ^[nN]$ ]] || full_uninstall_my ;;
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
        clear_screen
        echo -e "${CYAN}============================================================${RESET}"
        echo -e "${CYAN}                    统一状态页 / 管理导航                   ${RESET}"
        echo -e "${CYAN}============================================================${RESET}"
        echo -e "${GREEN}网络调优${RESET}"
        echo -e "  优化档位: ${YELLOW}${optmode}${RESET}"
        echo -e "  拥塞控制 / 队列: $(status_cc_colored)"
        status_timesync_line
        echo -e "  DNS: ${YELLOW}${dns}${RESET} / 当前 ${YELLOW}${dns_servers}${RESET}"
        echo -e ""
        echo -e "${GREEN}服务状态${RESET}"
        status_xray_line
        status_nginx_line
        status_ddns_line
        echo -e ""
        echo -e "${GREEN}系统基础${RESET}"
        status_ssh_line
        echo -e ""
        echo -e "${CYAN}快捷导航${RESET}"
        echo -e "  ${YELLOW}1.${RESET} 优化中心          ${YELLOW}3.${RESET} Xray / 节点中心"
        echo -e "  ${YELLOW}2.${RESET} 刷新 GitHub 密钥   ${YELLOW}4.${RESET} DDNS / 建站 / DD 中心"
        echo -e "  ${YELLOW}5.${RESET} 刷新状态页"
        echo -e "  0. 返回主菜单"
        echo -e "${CYAN}============================================================${RESET}"
        read -rp "请输入数字 [0-5]: " choice
        case "$choice" in
            1) optimize_menu ;;
            2) github_keys_auto_fetch; menu_pause ;;
            3) xray_menu ;;
            4) services_menu ;;
            5) ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

main_menu() {
    clear_screen
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}     my 深度合并极限管理版 v${MY_VERSION}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${YELLOW} 1.${RESET} 状态页 / 快捷导航"
    echo -e "${YELLOW} 2.${RESET} 优化中心"
    echo -e "${YELLOW} 3.${RESET} Xray / 节点中心"
    echo -e "${YELLOW} 4.${RESET} DDNS / 建站 / DD 中心"
    echo -e "${YELLOW} 5.${RESET} 清理残留 / 卸载"
    echo -e " 0. 退出"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    read -rp "请输入数字 [0-5]: " choice
    case "$choice" in
        1) status_page_loop ;;
        2) optimize_menu ;;
        3) xray_menu ;;
        4) services_menu ;;
        5) uninstall_menu ;;
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
    cron_remove_regex '(^|\s)(/usr/local/bin/nftmgr|/usr/local/bin/ssr|/usr/local/bin/ss-rust)(\s|$)'
}

usage() {
    cat <<'EOF'
可用命令：
  my status
  my optimize <menu|general|nat|hyper>
  my dns <auto|manual|status|restore>
  my github keys
  my ssh <port|passwd|disable-passwd|enable-passwd>
  my nginx <menu|install|list|delete [序号|域名]|repair>
  my ddns <menu|setup|update|status|install-cron|remove>
  my xray <menu|install-core|update-core|add-vless|add-ss|add-dual|list-nodes|view-node 序号|view-links|delete-node 序号|restart|logs|uninstall>
  my dd
  my purge
  my full-uninstall
EOF
}

dispatch_cli() {
    case "$1" in
        clean|daily_clean)
            daily_clean
            ;;
        status)
            status_page_loop
            ;;
        optimize)
            shift
            case "${1:-menu}" in
                menu) optimize_menu ;;
                general) apply_general_extreme_opt ;;
                nat) apply_nat_extreme_opt ;;
                hyper) apply_hyper_extreme_opt ;;
                *) usage; return 1 ;;
            esac
            ;;
        dns)
            shift
            case "${1:-status}" in
                auto) dns_auto_tune ;;
                manual) dns_manual_set ;;
                status) dns_status ;;
                unlock|restore) dns_unlock_restore ;;
                *) usage; return 1 ;;
            esac
            ;;
        github)
            shift
            case "${1:-keys}" in
                keys|known-hosts) github_keys_auto_fetch ;;
                *) usage; return 1 ;;
            esac
            ;;
        ssh)
            shift
            case "${1:-menu}" in
                port) change_ssh_port ;;
                passwd) change_root_password ;;
                disable-passwd) disable_password_login ;;
                enable-passwd) restore_password_login ;;
                *) usage; return 1 ;;
            esac
            ;;
        nginx)
            shift
            case "${1:-menu}" in
                menu) nginx_menu ;;
                install) ensure_nginx_installed ;;
                list) nginx_list_sites ;;
                delete) shift; nginx_delete_site "${1:-}" ;;
                repair) nginx_repair ;;
                *) usage; return 1 ;;
            esac
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
                *) usage; return 1 ;;
            esac
            ;;
        xray)
            shift
            case "${1:-menu}" in
                menu) xray_menu ;;
                install-core) xray_install_core ;;
                update-core) xray_update_core ;;
                add-vless) xray_add_vless_node ;;
                add-ss) xray_add_ss_node ;;
                add-dual) xray_add_dual_nodes ;;
                list-nodes) xray_list_nodes ;;
                view-node) shift; xray_view_link_by_serial "${1:-}" ;;
                view-links) xray_view_all_links ;;
                delete-node) shift; xray_delete_node_by_serial "${1:-}" ;;
                restart) xray_restart_service ;;
                logs) xray_view_logs ;;
                uninstall) xray_uninstall_core ;;
                *) usage; return 1 ;;
            esac
            ;;
        dd)
            dd_menu
            ;;
        purge|cleanup-legacy)
            legacy_cleanup
            ;;
        full-uninstall)
            full_uninstall_my
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            usage
            return 1
            ;;
    esac
}

main() {
    init
    if [[ $# -gt 0 ]]; then
        dispatch_cli "$@"
        exit $?
    fi
    while true; do
        main_menu
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
