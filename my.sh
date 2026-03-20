#!/bin/bash
# my 综合管理（优化专用精简版）
# 已物理移除：Xray / Reality / SS2022 / NFT 转发相关代码
# 更新地址：https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/my.sh
# 版本：v2.0.0-clean
# 指纹：CMD_NAME="my" / MY_SCRIPT_ID="my-manager"

set -o pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

CMD_NAME="my"
MY_SCRIPT_ID="my-manager"
MY_VERSION="2.0.1-clean"
MY_STATE_DIR="/usr/local/lib/my/state"
DNS_STATE_DIR="${MY_STATE_DIR}/dns"
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
    mkdir -p "$MY_STATE_DIR" "$DNS_STATE_DIR" 2>/dev/null || true
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
        apt-get update -y >/dev/null 2>&1 || apt-get update >/dev/null 2>&1 || return 1
        return 0
    fi
    return 0
}
pkg_install() {
    if have_cmd apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y "$@"
    elif have_cmd dnf; then
        dnf install -y "$@"
    elif have_cmd yum; then
        yum install -y "$@"
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
    if [[ ${#missing[@]} -gt 0 ]]; then
        pkg_update_once >/dev/null 2>&1 || true
        pkg_install "${missing[@]}" >/dev/null 2>&1 || true
    fi
}
ensure_dns_tools() {
    if have_cmd dig; then
        return 0
    fi
    pkg_update_once >/dev/null 2>&1 || true
    pkg_install dnsutils >/dev/null 2>&1 || pkg_install bind-utils >/dev/null 2>&1 || true
    have_cmd dig
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
    find /etc/nginx/conf.d /etc/nginx/sites-enabled -maxdepth 1 -type f \( -name '*.conf' -o -type l \) 2>/dev/null | wc -l | awk '{print $1}'
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

download_to() {
    local url="$1" dest="$2"
    [[ -n "$url" && -n "$dest" ]] || return 1
    if have_cmd curl; then
        curl -fL --connect-timeout 10 --retry 2 --retry-delay 1 -o "$dest" "$url"
    elif have_cmd wget; then
        wget -O "$dest" "$url"
    else
        return 1
    fi
}
normalize_update_file() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    sed -i '1s/^ï»¿//' "$f" 2>/dev/null || true
    tr -d '
' < "$f" > "${f}.lf" 2>/dev/null && mv -f "${f}.lf" "$f" || true
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
                new_ver=$(grep -m1 '^MY_VERSION=' "$self" | sed -E 's/^[^"]*"([^"]+)".*//')
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

sysctl_key_supported() {
    sysctl -aN 2>/dev/null | grep -qx "$1"
}
apply_sysctl_optimizer() {
    local tmp
    tmp="$(mktemp /tmp/my-sysctl.XXXXXX)" || return 1
    cat > "$tmp" <<'SYSCTL_EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
vm.swappiness = 10
SYSCTL_EOF
    awk 'BEGIN{ok=1}
        {
            line=$0
            if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*$/) {print line; next}
            split(line,a,"=")
            gsub(/[[:space:]]+$/, "", a[1])
            gsub(/^[[:space:]]+/, "", a[1])
            print line
        }' "$tmp" > "$SYSCTL_OPT_FILE"
    sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_OPT_FILE" >/dev/null 2>&1
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
119.29.29.29|tencent
180.76.76.76|baidu
1.1.1.1|cloudflare
8.8.8.8|google
9.9.9.9|quad9
94.140.14.14|adguard
EOF_DNS
}
dns_probe_avg_ms() {
    local server="$1" total=0 ok=0 i start end elapsed domain
    ensure_dns_tools || return 1
    for domain in www.cloudflare.com www.baidu.com www.qq.com; do
        start="$(_dns_now_ms)"
        if dig +time=1 +tries=1 +short @"$server" "$domain" A >/dev/null 2>&1; then
            end="$(_dns_now_ms)"
            elapsed=$((end-start))
            total=$((total+elapsed))
            ok=$((ok+1))
        fi
    done
    (( ok > 0 )) || return 1
    echo $((total/ok))
}
dns_pick_best_servers() {
    local line ip provider ms scored
    while IFS='|' read -r ip provider; do
        [[ -n "$ip" ]] || continue
        ms="$(dns_probe_avg_ms "$ip" 2>/dev/null || true)"
        [[ "$ms" =~ ^[0-9]+$ ]] || continue
        printf '%s|%s|%s\n' "$ms" "$ip" "$provider"
    done < <(dns_candidate_servers) | sort -n | head -n 3 | awk -F'|' '{print $2}'
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
    printf 'mode=%s\nservers=%s\n' "$mode" "$servers" > "$DNS_META_FILE"
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
    local best=()
    while read -r line; do
        [[ -n "$line" ]] && best+=("$line")
    done < <(dns_pick_best_servers)
    if [[ ${#best[@]} -eq 0 ]]; then
        msg_err "智能 DNS 测试失败。"
        return 1
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
change_root_password() {
    passwd root
}
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
    files=$(find /etc/nginx/conf.d /etc/nginx/sites-enabled -maxdepth 1 -type f -name '*.conf' 2>/dev/null)
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

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
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
            3)
                rm -f /usr/local/bin/my
                msg_ok "已删除 /usr/local/bin/my。"
                exit 0
                ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

status_page_loop() {
    while true; do
        local dns dns_servers
        dns="$(get_dns_brief_status 2>/dev/null || echo 未知)"
        dns_servers="$(get_dns_servers_brief 2>/dev/null || echo 未探测到)"
        clear 2>/dev/null || true
        echo -e "${CYAN}============================================================${RESET}"
        echo -e "${CYAN}                    统一状态页 / 管理导航                   ${RESET}"
        echo -e "${CYAN}============================================================${RESET}"
        echo -e "${GREEN}网络调优${RESET}"
        echo -e "  拥塞控制 / 队列: $(status_cc_colored)"
        status_timesync_line
        echo -e "  DNS: ${YELLOW}${dns}${RESET} / 当前 ${YELLOW}${dns_servers}${RESET}"
        echo -e ""
        echo -e "${GREEN}Nginx 与建站${RESET}"
        status_nginx_line
        echo -e ""
        echo -e "${GREEN}系统基础${RESET}"
        status_ssh_line
        echo -e ""
        echo -e "${CYAN}快捷导航${RESET}"
        echo -e "  ${YELLOW}1.${RESET} 优化与系统中心      ${YELLOW}3.${RESET} DD / 重装系统中心"
        echo -e "  ${YELLOW}2.${RESET} Nginx 反向代理      ${YELLOW}4.${RESET} 刷新状态页"
        echo -e "  0. 返回主菜单"
        echo -e "${CYAN}============================================================${RESET}"
        read -rp "请输入数字 [0-4]: " choice
        case "$choice" in
            1) system_menu ;;
            2) nginx_menu ;;
            3) dd_menu ;;
            4) ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

system_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}              优化与系统中心              ${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${YELLOW} 1.${RESET} 应用系统网络优化"
        echo -e "${YELLOW} 2.${RESET} DNS 智能调优"
        echo -e "${YELLOW} 3.${RESET} 手动设置 DNS"
        echo -e "${YELLOW} 4.${RESET} 查看 DNS 状态"
        echo -e "${YELLOW} 5.${RESET} 恢复 DNS"
        echo -e "${YELLOW} 6.${RESET} 修改 SSH 端口"
        echo -e "${YELLOW} 7.${RESET} 修改 root 密码"
        echo -e "${YELLOW} 8.${RESET} 关闭 SSH 密码登录"
        echo -e "${YELLOW} 9.${RESET} 恢复 SSH 密码登录"
        echo -e "${YELLOW}10.${RESET} 运行日常清理"
        echo -e " 0. 返回"
        read -rp "请输入数字 [0-10]: " choice
        case "$choice" in
            1) apply_sysctl_optimizer; msg_ok "系统网络优化已应用。"; read -n 1 -s -r -p "按任意键继续..." ;;
            2) dns_auto_tune; read -n 1 -s -r -p "按任意键继续..." ;;
            3) dns_manual_set; read -n 1 -s -r -p "按任意键继续..." ;;
            4) dns_status; read -n 1 -s -r -p "按任意键继续..." ;;
            5) dns_unlock_restore; read -n 1 -s -r -p "按任意键继续..." ;;
            6) change_ssh_port; read -n 1 -s -r -p "按任意键继续..." ;;
            7) change_root_password; read -n 1 -s -r -p "按任意键继续..." ;;
            8) disable_password_login; read -n 1 -s -r -p "按任意键继续..." ;;
            9) restore_password_login; read -n 1 -s -r -p "按任意键继续..." ;;
            10) daily_clean; msg_ok "清理完成。"; read -n 1 -s -r -p "按任意键继续..." ;;
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
            1)
                fetch_reinstall_script || { msg_err "下载重装脚本失败。"; read -n 1 -s -r -p "按任意键继续..."; continue; }
                bash "$REINSTALL_SCRIPT_PATH" debian 13
                ;;
            2)
                fetch_reinstall_script || { msg_err "下载重装脚本失败。"; read -n 1 -s -r -p "按任意键继续..."; continue; }
                bash "$REINSTALL_SCRIPT_PATH" debian 12
                ;;
            3)
                fetch_reinstall_script || { msg_err "下载重装脚本失败。"; read -n 1 -s -r -p "按任意键继续..."; continue; }
                bash "$REINSTALL_SCRIPT_PATH" ubuntu 24.04
                ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

comprehensive_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}              系统与建站中心              ${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${YELLOW} 1.${RESET} 优化与系统中心"
        echo -e "${YELLOW} 2.${RESET} Nginx 建站与反代"
        echo -e "${GREEN} 3.${RESET} DD / 重装系统"
        echo -e " 0. 返回"
        read -rp "请输入数字 [0-3]: " choice
        case "$choice" in
            1) system_menu ;;
            2) nginx_menu ;;
            3) dd_menu ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

main_menu() {
    clear 2>/dev/null || true
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}            my 优化专用版 v${MY_VERSION}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${YELLOW} 1.${RESET} 状态页 / 快捷导航"
    echo -e "${YELLOW} 2.${RESET} 优化与系统中心"
    echo -e "${YELLOW} 3.${RESET} 系统与建站中心"
    echo -e "${YELLOW} 4.${RESET} 脚本更新"
    echo -e "${YELLOW} 5.${RESET} 清理残留 / 卸载"
    echo -e " 0. 退出"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    read -rp "请输入数字 [0-5]: " choice
    case "$choice" in
        1) status_page_loop ;;
        2) system_menu ;;
        3) comprehensive_menu ;;
        4) github_update; read -n 1 -s -r -p "按任意键继续..." ;;
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
        system|sys)
            shift
            if [[ "${1:-}" == "menu" || -z "${1:-}" ]]; then
                system_menu
            else
                case "$1" in
                    optimize) apply_sysctl_optimizer ;;
                    ssh-port) change_ssh_port ;;
                    disable-passwd) disable_password_login ;;
                    enable-passwd) restore_password_login ;;
                    *) msg_err "未知 system 子命令"; exit 1 ;;
                esac
            fi
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
        dd)
            dd_menu
            exit 0
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
            msg_err "未知参数。可用：my status | my system <menu|optimize|ssh-port|disable-passwd|enable-passwd> | my dns <auto|manual|status|restore> | my nginx <menu|install|list|delete 域名|repair> | my dd | my update | my purge"
            exit 1
            ;;
    esac
fi

init
while true; do
    main_menu
done
