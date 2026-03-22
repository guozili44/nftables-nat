#!/bin/bash
# my 综合管理（修复增强版）
# 功能：优化 / DNS / SSH / GitHub known_hosts / DDNS / Nginx / DD / 清理卸载 / 远程更新
# 说明：配置与状态独立存储，升级覆盖脚本时默认保留现有配置
# 版本：v2.2.0-fixed
# 指纹：CMD_NAME="my" / MY_SCRIPT_ID="my-manager"

set -o pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

CMD_NAME="my"
MY_SCRIPT_ID="my-manager"
MY_VERSION="2.2.0-fixed"
MY_STATE_DIR="/usr/local/lib/my/state"
DNS_STATE_DIR="${MY_STATE_DIR}/dns"
DDNS_STATE_DIR="${MY_STATE_DIR}/ddns"
UPDATE_URL_DIRECT=""
UPDATE_URL_PROXY=""
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
UPDATE_URL_FILE="${MY_STATE_DIR}/update-url.conf"
OPTIMIZER_REPORT_FILE="${MY_STATE_DIR}/optimizer-report.conf"
SSH_BACKUP_DIR="${MY_STATE_DIR}/ssh-backups"
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
    mkdir -p "$MY_STATE_DIR" "$DNS_STATE_DIR" "$DDNS_STATE_DIR" "$SSH_BACKUP_DIR" /root/.ssh 2>/dev/null || true
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
    have_cmd ssh-keygen || missing+=(openssh-client)
    have_cmd ssh-keyscan || missing+=(openssh-client)
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

trim_ws() {
    local s="$*"
    s="${s#${s%%[![:space:]]*}}"
    s="${s%${s##*[![:space:]]}}"
    printf '%s' "$s"
}

path_token() {
    printf '%s' "$1" | sed 's#[/ ]#_#g'
}

backup_file_once() {
    local file="$1" backup
    [[ -f "$file" ]] || return 0
    mkdir -p "$SSH_BACKUP_DIR" 2>/dev/null || true
    backup="${SSH_BACKUP_DIR}/$(path_token "$file").bak"
    [[ -f "$backup" ]] || cp -a "$file" "$backup" 2>/dev/null || return 1
}

restore_ssh_backups() {
    local backup file token
    [[ -d "$SSH_BACKUP_DIR" ]] || return 0
    for backup in "$SSH_BACKUP_DIR"/*.bak; do
        [[ -f "$backup" ]] || continue
        token="$(basename "$backup" .bak)"
        file="${token//_//}"
        cp -a "$backup" "$file" 2>/dev/null || true
    done
}

sysctl_key_exists() {
    local key="$1"
    sysctl -aN 2>/dev/null | grep -Fxq "$key"
}

sysctl_get_quiet() {
    sysctl -n "$1" 2>/dev/null || true
}

update_url_get() {
    if [[ -n "${MY_UPDATE_URL:-}" ]]; then
        printf '%s
' "$MY_UPDATE_URL"
        return 0
    fi
    if [[ -s "$UPDATE_URL_FILE" ]]; then
        awk -F= '/^url=/{sub(/^url=/,""); print; exit}' "$UPDATE_URL_FILE" 2>/dev/null
        return 0
    fi
    if [[ -n "$UPDATE_URL_DIRECT" ]]; then
        printf '%s
' "$UPDATE_URL_DIRECT"
        return 0
    fi
    return 1
}

update_url_set() {
    local url="$1"
    [[ -n "$url" ]] || return 1
    mkdir -p "$MY_STATE_DIR" 2>/dev/null || true
    printf 'url=%s
updated_at=%s
' "$url" "$(date '+%F %T')" > "$UPDATE_URL_FILE"
}

normalize_github_raw_url() {
    local url="$1"
    url="$(trim_ws "$url")"
    [[ -n "$url" ]] || return 1
    if [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$ ]]; then
        printf 'https://raw.githubusercontent.com/%s/%s/%s/%s
' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
        return 0
    fi
    printf '%s
' "$url"
}

update_url_candidates() {
    local base="$1"
    base="$(normalize_github_raw_url "$base")" || return 1
    printf '%s
' "$base"
    if [[ "$base" == https://raw.githubusercontent.com/* ]]; then
        printf 'https://mirror.ghproxy.com/%s
' "$base"
    fi
}

show_update_source() {
    local url
    url="$(update_url_get 2>/dev/null || true)"
    if [[ -n "$url" ]]; then
        echo -e "当前远程更新地址: ${YELLOW}${url}${RESET}"
    else
        echo -e "当前远程更新地址: ${YELLOW}未设置${RESET}"
    fi
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
    head -n 20 "$f" | grep -Eqi '^[[:space:]]*<(!DOCTYPE[[:space:]]+html|html)([[:space:]>]|$)' && return 20
    grep -q '^#!/bin/bash' "$f" || return 12
    grep -q 'CMD_NAME="my"' "$f" || return 13
    grep -q 'MY_SCRIPT_ID="my-manager"' "$f" || return 14
    grep -Eq '^[[:space:]]*main_menu[[:space:]]*\(\)' "$f" || return 15
    grep -Eq '^[[:space:]]*init[[:space:]]*\(\)' "$f" || return 16
    bash -n "$f" || return 17
    return 0
}
github_update() {
    local requested_url="${1-}" target tmp bak rc new_ver size url real_url found=0
    target="/usr/local/bin/${CMD_NAME}"
    [[ -f "$target" ]] || target="$(script_realpath)"
    real_url="$(trim_ws "${requested_url:-$(update_url_get 2>/dev/null || true)}")"
    if [[ -z "$real_url" ]]; then
        msg_warn "未设置远程 GitHub 更新地址。"
        msg_info "请先在“脚本更新”菜单中设置 raw.githubusercontent.com 地址，或使用：my update set <URL>"
        return 1
    fi
    tmp="$(mktemp /tmp/my-update.XXXXXX.sh)" || { msg_err "创建临时文件失败。"; return 1; }
    bak="${target}.bak.$(date +%Y%m%d%H%M%S)"
    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        found=1
        : > "$tmp"
        if download_to "$url" "$tmp" >/dev/null 2>&1; then
            normalize_update_file "$tmp"
            verify_update_file "$tmp"
            rc=$?
            if (( rc == 0 )); then
                if cmp -s "$tmp" "$target" 2>/dev/null; then
                    msg_ok "已经是最新内容，无需更新。"
                    rm -f "$tmp"
                    return 0
                fi
                cp -f "$target" "$bak" 2>/dev/null || { msg_err "备份当前脚本失败。"; rm -f "$tmp"; return 1; }
                cp -f "$tmp" "$target" 2>/dev/null || { msg_err "写入新脚本失败。"; rm -f "$tmp"; return 1; }
                chmod +x "$target" 2>/dev/null || true
                if ! bash -n "$target" >/dev/null 2>&1; then
                    cp -f "$bak" "$target" 2>/dev/null || true
                    msg_err "新脚本语法检查失败，已自动回滚。"
                    rm -f "$tmp"
                    return 1
                fi
                new_ver="$(grep -m1 '^MY_VERSION=' "$target" | sed -E 's/^[^"]*"([^"]+)".*/\1/')"
                msg_ok "远程 GitHub 更新成功。当前版本：${new_ver:-未知}"
                msg_info "更新目标：${target}"
                msg_info "旧版本备份：${bak}"
                rm -f "$tmp"
                return 0
            fi
        else
            rc=2
        fi
    done < <(update_url_candidates "$real_url")
    (( found == 1 )) || rc=2
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
        *) msg_err "远程更新失败，请检查更新地址或网络。" ;;
    esac
    return 1
}

write_optimizer_profile() {
    local profile="$1" applied="$2" skipped="$3" failed="$4"
    printf 'profile=%s
updated_at=%s
applied=%s
skipped=%s
failed=%s
' "$profile" "$(date '+%F %T')" "$applied" "$skipped" "$failed" > "$MY_STATE_DIR/optimizer.conf"
}
apply_sysctl_lines() {
    local profile="$1"
    shift
    local line key value applied=0 skipped=0 failed=0 current_cc
    mkdir -p /etc/sysctl.d 2>/dev/null || true
    : > "$SYSCTL_OPT_FILE"
    current_cc="$(sysctl_get_quiet net.ipv4.tcp_congestion_control)"
    for line in "$@"; do
        key="$(trim_ws "${line%%=*}")"
        value="$(trim_ws "${line#*=}")"
        [[ -n "$key" && -n "$value" ]] || continue
        if [[ "$key" == "net.ipv4.tcp_congestion_control" ]] && ! sysctl_get_quiet net.ipv4.tcp_available_congestion_control | grep -qw "$value"; then
            msg_warn "当前内核不支持拥塞控制算法 ${value}，保留当前值 ${current_cc:-未知}。"
            skipped=$((skipped+1))
            continue
        fi
        if ! sysctl_key_exists "$key"; then
            msg_warn "跳过当前内核不存在的参数：${key}"
            skipped=$((skipped+1))
            continue
        fi
        printf '%s = %s
' "$key" "$value" >> "$SYSCTL_OPT_FILE"
        if sysctl -q -w "${key}=${value}" >/dev/null 2>&1; then
            applied=$((applied+1))
        else
            msg_warn "参数写入失败：${key}=${value}"
            failed=$((failed+1))
        fi
    done
    sysctl -q -p "$SYSCTL_OPT_FILE" >/dev/null 2>&1 || true
    write_optimizer_profile "$profile" "$applied" "$skipped" "$failed"
    printf 'profile=%s
applied=%s
skipped=%s
failed=%s
current_cc=%s
current_qdisc=%s
' "$profile" "$applied" "$skipped" "$failed" "$(sysctl_get_quiet net.ipv4.tcp_congestion_control)" "$(sysctl_get_quiet net.core.default_qdisc)" > "$OPTIMIZER_REPORT_FILE"
    if (( applied > 0 )); then
        msg_ok "调优已写入：成功 ${applied} 项，跳过 ${skipped} 项，失败 ${failed} 项。"
        return 0
    fi
    msg_err "没有任何调优参数成功写入。"
    return 1
}
apply_general_extreme_opt() {
    apply_sysctl_lines "general-extreme" "net.core.default_qdisc = fq" "net.ipv4.tcp_congestion_control = bbr" "fs.file-max = 2097152" "fs.inotify.max_user_instances = 8192" "fs.inotify.max_user_watches = 1048576" "net.core.somaxconn = 65535" "net.core.netdev_max_backlog = 262144" "net.core.optmem_max = 25165824" "net.ipv4.ip_local_port_range = 10240 65535" "net.ipv4.tcp_max_syn_backlog = 262144" "net.ipv4.tcp_fin_timeout = 10" "net.ipv4.tcp_fastopen = 3" "net.ipv4.tcp_keepalive_time = 600" "net.ipv4.tcp_keepalive_intvl = 30" "net.ipv4.tcp_keepalive_probes = 5" "net.ipv4.tcp_mtu_probing = 1" "net.ipv4.tcp_slow_start_after_idle = 0" "net.ipv4.tcp_tw_reuse = 1" "vm.max_map_count = 1048576" "vm.swappiness = 10"
}
apply_nat_extreme_opt() {
    apply_sysctl_lines "nat-extreme" "net.core.default_qdisc = fq" "net.ipv4.tcp_congestion_control = bbr" "net.ipv4.ip_forward = 1" "net.ipv6.conf.all.forwarding = 1" "fs.file-max = 2097152" "net.core.somaxconn = 65535" "net.core.netdev_max_backlog = 262144" "net.core.optmem_max = 25165824" "net.ipv4.ip_local_port_range = 10240 65535" "net.ipv4.tcp_max_syn_backlog = 262144" "net.ipv4.tcp_fin_timeout = 10" "net.ipv4.tcp_fastopen = 3" "net.ipv4.tcp_keepalive_time = 600" "net.ipv4.tcp_keepalive_intvl = 30" "net.ipv4.tcp_keepalive_probes = 5" "net.ipv4.tcp_mtu_probing = 1" "net.ipv4.tcp_slow_start_after_idle = 0" "net.ipv4.tcp_tw_reuse = 1" "net.netfilter.nf_conntrack_max = 2097152" "net.netfilter.nf_conntrack_buckets = 524288" "net.netfilter.nf_conntrack_tcp_timeout_established = 7200" "net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30"
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
comment_out_port_directives_in_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    backup_file_once "$file" || return 1
    python3 - "$file" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
lines=p.read_text(encoding='utf-8', errors='ignore').splitlines()
out=[]
changed=False
for line in lines:
    if re.match(r'^\s*Port\s+[0-9]+\s*$', line) and '# my-disabled-port' not in line:
        out.append('# my-disabled-port ' + line.lstrip())
        changed=True
    else:
        out.append(line)
if changed:
    p.write_text('\n'.join(out)+'\n', encoding='utf-8')
PY
}
prepare_ssh_single_port() {
    local file
    comment_out_port_directives_in_file /etc/ssh/sshd_config || return 1
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        for file in /etc/ssh/sshd_config.d/*.conf; do
            [[ -f "$file" ]] || continue
            [[ "$file" == "$SSH_PORT_DROPIN" ]] && continue
            [[ "$file" == "$SSH_AUTH_DROPIN" ]] && continue
            comment_out_port_directives_in_file "$file" || return 1
        done
    fi
}
restart_ssh_service() {
    if service_use_systemd; then
        systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1
    else
        service ssh restart >/dev/null 2>&1 || service sshd restart >/dev/null 2>&1
    fi
}
ssh_port_listening() {
    local port="$1"
    ss -lntH 2>/dev/null | awk '{print $4}' | awk -F: '{print $NF}' | grep -qx "$port"
}
rollback_ssh_port_change() {
    restore_ssh_backups
    rm -f "$SSH_PORT_DROPIN" 2>/dev/null || true
    restart_ssh_service >/dev/null 2>&1 || true
}
change_ssh_port() {
    local new_port old_port
    read -rp "新的 SSH 端口号 (1-65535): " new_port
    [[ "$new_port" =~ ^[0-9]+$ ]] || { msg_err "端口格式错误。"; return 1; }
    (( new_port >= 1 && new_port <= 65535 )) || { msg_err "端口范围错误。"; return 1; }
    old_port="$(sshd_effective_port 2>/dev/null || echo 22)"
    prepare_ssh_single_port || { msg_err "处理已有 SSH 端口配置失败。"; return 1; }
    write_ssh_port_dropin "$new_port"
    if ! sshd -t; then
        msg_err "sshd 配置校验失败，已自动回滚。"
        rollback_ssh_port_change
        return 1
    fi
    if ! restart_ssh_service; then
        msg_err "SSH 重启失败，已自动回滚。"
        rollback_ssh_port_change
        return 1
    fi
    sleep 1
    if ! ssh_port_listening "$new_port"; then
        msg_err "新端口 ${new_port} 未监听，已自动回滚。"
        rollback_ssh_port_change
        return 1
    fi
    if have_cmd ufw; then
        ufw allow "$new_port"/tcp >/dev/null 2>&1 || true
        [[ "$old_port" != "$new_port" ]] && ufw delete allow "$old_port"/tcp >/dev/null 2>&1 || true
    fi
    if have_cmd firewall-cmd; then
        firewall-cmd --permanent --add-port="${new_port}/tcp" >/dev/null 2>&1 || true
        [[ "$old_port" != "$new_port" ]] && firewall-cmd --permanent --remove-port="${old_port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    msg_ok "SSH 端口已切换为 ${new_port}，旧端口 ${old_port} 已不再作为脚本管理目标。"
    msg_info "请先新开一个终端测试 ${new_port} 可登录，再关闭当前会话。"
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
    local tmp meta_ok=0 added_count=0 host_count443=0 host_count22=0
    local work_keys work_hosts backup_file
    mkdir -p /root/.ssh 2>/dev/null || true
    touch "$GITHUB_KNOWN_HOSTS" 2>/dev/null || true
    chmod 600 "$GITHUB_KNOWN_HOSTS" 2>/dev/null || true
    tmp="$(mktemp /tmp/my-ghmeta.XXXXXX.json)" || return 1
    work_keys="$(mktemp /tmp/my-ghkeys.XXXXXX)" || { rm -f "$tmp"; return 1; }
    work_hosts="$(mktemp /tmp/my-knownhosts.XXXXXX)" || { rm -f "$tmp" "$work_keys"; return 1; }
    backup_file="${GITHUB_KNOWN_HOSTS}.bak.$(date +%Y%m%d%H%M%S)"

    if download_to "https://api.github.com/meta" "$tmp" >/dev/null 2>&1; then
        if have_cmd python3; then
            python3 - "$tmp" "$work_keys" <<'PY'
import json,sys
meta=json.load(open(sys.argv[1],'r',encoding='utf-8'))
keys=meta.get('ssh_keys',[])
seen=set(); out=[]
for k in keys:
    for host in ('github.com','ssh.github.com','[ssh.github.com]:443'):
        line=f"{host} {k}"
        if line not in seen:
            seen.add(line)
            out.append(line)
with open(sys.argv[2],'w',encoding='utf-8') as f:
    for line in out:
        f.write(line+'\n')
PY
            [[ -s "$work_keys" ]] && meta_ok=1
        fi
    fi
    rm -f "$tmp"
    if (( meta_ok == 0 )) && have_cmd ssh-keyscan; then
        ssh-keyscan -T 5 github.com 2>/dev/null | sed '/^#/d' >> "$work_keys" || true
        ssh-keyscan -T 5 ssh.github.com 2>/dev/null | sed '/^#/d' >> "$work_keys" || true
        ssh-keyscan -T 5 -p 443 ssh.github.com 2>/dev/null | sed '/^#/d; s/^ssh\.github\.com /[ssh.github.com]:443 /' >> "$work_keys" || true
    fi
    [[ -s "$work_keys" ]] || { rm -f "$work_keys" "$work_hosts"; msg_err "GitHub 主机密钥获取失败。"; return 1; }

    cp -a "$GITHUB_KNOWN_HOSTS" "$backup_file" 2>/dev/null || true
    grep -Ev '^(github\.com|ssh\.github\.com|\[ssh\.github\.com\]:443)[[:space:]]' "$GITHUB_KNOWN_HOSTS" 2>/dev/null > "$work_hosts" || true
    cat "$work_keys" >> "$work_hosts"
    sort -u "$work_hosts" -o "$work_hosts" 2>/dev/null || true
    cp -f "$work_hosts" "$GITHUB_KNOWN_HOSTS" 2>/dev/null || { rm -f "$work_keys" "$work_hosts"; msg_err "写入 known_hosts 失败。"; return 1; }
    chmod 600 "$GITHUB_KNOWN_HOSTS" 2>/dev/null || true

    if have_cmd ssh-keygen; then
        host_count22=$(ssh-keygen -F github.com -f "$GITHUB_KNOWN_HOSTS" 2>/dev/null | grep -c '^github.com ' || true)
        host_count443=$(ssh-keygen -F '[ssh.github.com]:443' -f "$GITHUB_KNOWN_HOSTS" 2>/dev/null | grep -c '^\[ssh.github.com\]:443 ' || true)
    else
        host_count22=$(grep -c '^github\.com ' "$GITHUB_KNOWN_HOSTS" 2>/dev/null || true)
        host_count443=$(grep -c '^\[ssh.github.com\]:443 ' "$GITHUB_KNOWN_HOSTS" 2>/dev/null || true)
    fi
    added_count=$(wc -l < "$work_keys" 2>/dev/null || echo 0)
    rm -f "$work_keys" "$work_hosts"
    if (( host_count22 > 0 || host_count443 > 0 )); then
        msg_ok "GitHub 主机密钥已刷新到 known_hosts。"
        msg_info "github.com 条目: ${host_count22} | [ssh.github.com]:443 条目: ${host_count443} | 本次写入: ${added_count}"
        msg_info "文件位置: ${GITHUB_KNOWN_HOSTS}"
        return 0
    fi
    msg_err "GitHub 主机密钥验证失败，已保留备份：${backup_file}"
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
full_uninstall() {
    local self
    self="$(script_realpath)"
    msg_warn "开始完整卸载 my：删除脚本、配置、定时任务、SSH/DNS/DDNS/Nginx 管理残留。"
    cron_remove_regex '/usr/local/bin/my ddns update'
    cron_remove_regex '/usr/local/bin/my clean'
    rm -f "$SYSCTL_OPT_FILE" "$DNS_META_FILE" "$DNS_BACKUP_FILE" "$DDNS_CFG_FILE" "$DDNS_LOG_FILE" "$UPDATE_URL_FILE" "$OPTIMIZER_REPORT_FILE" 2>/dev/null || true
    rm -f "$SSH_PORT_DROPIN" "$SSH_AUTH_DROPIN" 2>/dev/null || true
    rm -rf "$MY_STATE_DIR" 2>/dev/null || true
    if [[ -f /etc/systemd/resolved.conf.d/99-my-dns.conf ]]; then
        rm -f /etc/systemd/resolved.conf.d/99-my-dns.conf
        systemctl restart systemd-resolved >/dev/null 2>&1 || true
    fi
    sysctl -q --system >/dev/null 2>&1 || true
    rm -f /usr/local/bin/my 2>/dev/null || true
    [[ "$self" != "/usr/local/bin/my" ]] && rm -f "$self" 2>/dev/null || true
    msg_ok "my 已完整卸载。"
    msg_info "若你曾通过本脚本修改过 SSH 主配置且需要恢复，请手动检查：/etc/ssh/sshd_config 与 /etc/ssh/sshd_config.d/"
    exit 0
}

uninstall_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}              清理残留 / 卸载               ${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${YELLOW} 1.${RESET} 清理旧代理 / 转发残留"
        echo -e "${YELLOW} 2.${RESET} 执行日常清理"
        echo -e "${RED} 3.${RESET} 一键完整卸载（含脚本本体）"
        echo -e " 0. 返回"
        read -rp "请输入数字 [0-3]: " choice
        case "$choice" in
            1) legacy_cleanup; read -n 1 -s -r -p "按任意键继续..." ;;
            2) daily_clean; msg_ok "清理完成。"; read -n 1 -s -r -p "按任意键继续..." ;;
            3) full_uninstall ;;
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
        echo -e ""
        echo -e "${CYAN}快捷导航${RESET}"
        echo -e "  ${YELLOW}1.${RESET} 优化中心          ${YELLOW}3.${RESET} DDNS / 建站 / DD 中心"
        echo -e "  ${YELLOW}2.${RESET} 刷新 GitHub 密钥   ${YELLOW}4.${RESET} 刷新状态页"
        echo -e "  0. 返回主菜单"
        echo -e "${CYAN}============================================================${RESET}"
        read -rp "请输入数字 [0-4]: " choice
        case "$choice" in
            1) optimize_menu ;;
            2) github_keys_auto_fetch; read -n 1 -s -r -p "按任意键继续..." ;;
            3) services_menu ;;
            4) ;;
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
        echo -e "${YELLOW} 7.${RESET} 自动获取 GitHub 主机密钥"
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

update_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}                脚本更新中心                ${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        show_update_source
        echo -e "${YELLOW} 1.${RESET} 一键远程 GitHub 更新"
        echo -e "${YELLOW} 2.${RESET} 设置 / 修改远程更新地址"
        echo -e "${YELLOW} 3.${RESET} 查看当前更新地址"
        echo -e "${YELLOW} 4.${RESET} 用当前运行文件覆盖安装（保留配置）"
        echo -e " 0. 返回"
        read -rp "请输入数字 [0-4]: " choice
        case "$choice" in
            1) github_update; read -n 1 -s -r -p "按任意键继续..." ;;
            2)
                read -rp "请输入 GitHub raw 脚本地址（或 github.com/blob 链接）: " url
                url="$(normalize_github_raw_url "$url" 2>/dev/null || true)"
                [[ -n "$url" ]] || { msg_err "更新地址不能为空。"; read -n 1 -s -r -p "按任意键继续..."; continue; }
                update_url_set "$url" && msg_ok "远程更新地址已保存。" || msg_err "保存更新地址失败。"
                read -n 1 -s -r -p "按任意键继续..."
                ;;
            3) show_update_source; read -n 1 -s -r -p "按任意键继续..." ;;
            4) install_self_command && msg_ok "已用当前文件覆盖安装到 /usr/local/bin/my，配置已保留。"; read -n 1 -s -r -p "按任意键继续..." ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

main_menu() {
    clear 2>/dev/null || true
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}          my 修复增强版 v${MY_VERSION}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${YELLOW} 1.${RESET} 状态页 / 快捷导航"
    echo -e "${YELLOW} 2.${RESET} 优化中心"
    echo -e "${YELLOW} 3.${RESET} DDNS / 建站 / DD 中心"
    echo -e "${YELLOW} 4.${RESET} 脚本更新 / 远程 GitHub 更新"
    echo -e "${YELLOW} 5.${RESET} 清理残留 / 卸载"
    echo -e " 0. 退出"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    read -rp "请输入数字 [0-5]: " choice
    case "$choice" in
        1) status_page_loop ;;
        2) optimize_menu ;;
        3) services_menu ;;
        4) update_menu ;;
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
                update) shift; github_update "$1" ;;
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
        update)
            shift || true
            case "${1:-run}" in
                menu) update_menu ;;
                run) shift || true; github_update "$1" ;;
                set) shift || true; update_url_set "$1" && msg_ok "远程更新地址已保存。" ;;
                show) show_update_source ;;
                install-self) install_self_command && msg_ok "已覆盖安装到 /usr/local/bin/my。" ;;
                *) msg_err "未知 update 子命令"; exit 1 ;;
            esac
            exit $?
            ;;
        purge|cleanup-legacy)
            legacy_cleanup
            exit $?
            ;;
        *)
            msg_err "未知参数。可用：my status | my optimize <menu|general|nat> | my dns <auto|manual|status|restore> | my github <keys|update [URL]> | my ssh <port|passwd|disable-passwd|enable-passwd> | my nginx <menu|install|list|delete 域名|repair> | my ddns <menu|setup|update|status|install-cron|remove> | my dd | my update <run|set URL|show|install-self> | my purge"
            exit 1
            ;;
    esac
fi

if [[ "${MY_UNIT_TEST:-0}" != "1" ]]; then
    init
    while true; do
        main_menu
    done
fi
