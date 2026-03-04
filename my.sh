#!/bin/bash
# ==============================================================================
# 综合网络管理脚本 (SSR + NFt 转发)
# 快捷命令: my
# ==============================================================================

set -o pipefail

# --------------------------
# 基础常量配置
# --------------------------
readonly SCRIPT_VERSION="21.0-Pro-Integrated"
readonly CMD_NAME="my"
readonly SCRIPT_FILE="/usr/local/bin/${CMD_NAME}"

# --- 更新相关配置 ---
readonly SCRIPT_URL="https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/my.sh"
readonly SCRIPT_ID="my-integrated-mgr"
readonly SCRIPT_FINGERPRINT_1="CMD_NAME=\"my\""
readonly SCRIPT_FINGERPRINT_2="menu_main()"

# --- 颜色与样式 ---
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly RESET='\033[0m'
readonly PLAIN='\033[0m'

# --- 锁文件与日志 ---
readonly LOCK_FILE="/var/lock/my_mgr.lock"
readonly CRON_BK_FILE="/tmp/my_cron_bkp"

# --- SSR 模块配置 ---
readonly CONF_FILE="/etc/sysctl.d/99-ssr-net.conf"
readonly NAT_CONF_FILE="/etc/sysctl.d/99-ssr-nat.conf"
readonly DDNS_CONF="/usr/local/etc/ssr_ddns.conf"
readonly DDNS_LOG="/var/log/ssr_ddns.log"
readonly META_DIR="/usr/local/etc/ssr_meta"
readonly META_FILE="${META_DIR}/versions.conf"
readonly DNS_BACKUP_DIR="/usr/local/etc/ssr_dns_backup"
readonly DNS_META="${DNS_BACKUP_DIR}/meta.conf"
readonly DNS_FILE_BAK="${DNS_BACKUP_DIR}/resolv.conf.bak"
readonly RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/ssr-dns.conf"

# --- NFt 模块配置 ---
readonly NFT_CONFIG_FILE="/etc/nft_forward_list.conf"
readonly NFT_SETTINGS_FILE="/etc/nft_forward_settings.conf"
readonly NFT_MGR_DIR="/etc/nftables.d"
readonly NFTABLES_CONF="/etc/nftables.conf"
readonly NFTABLES_CREATED_MARK="/etc/nftables.conf.nftmgr_created"
readonly NFT_MGR_CONF="${NFT_MGR_DIR}/nft_mgr.conf"
readonly NFT_MGR_SERVICE="/etc/systemd/system/nft-mgr.service"
readonly NFT_SYSCTL_FILE="/etc/sysctl.d/99-nft-mgr.conf"
readonly NFT_LOG_DIR="/var/log/nft_ddns"
PERSIST_MODE_DEFAULT="service"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"
trap 'echo -e "\n${GREEN}已安全退出脚本。${RESET}"; exit 0' SIGINT

# ==============================================================================
# 通用工具函数
# ==============================================================================
have_cmd() { command -v "$1" >/dev/null 2>&1; }
msg_ok()   { echo -e "${GREEN}$*${PLAIN}"; }
msg_warn() { echo -e "${YELLOW}$*${PLAIN}"; }
msg_err()  { echo -e "${RED}$*${PLAIN}"; }

run_with_timeout() {
    local seconds="$1"; shift
    if have_cmd timeout; then timeout "${seconds}" "$@"; else "$@"; fi
}

download_file() {
    local url="$1"; local dest="$2"
    rm -f "$dest"
    if have_cmd curl; then
        curl -fsSL --retry 3 --connect-timeout 8 --max-time 120 "$url" -o "$dest" >/dev/null 2>&1
    else
        wget -qO "$dest" "$url" >/dev/null 2>&1
    fi
}

script_realpath() {
    local src="$0"
    [[ -L "$src" ]] && src="$(readlink -f "$src")"
    echo "$src"
}

with_lock() {
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

is_port() { local p="$1"; [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; }
is_ipv4() { local ip="$1"; [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
normalize_proto() {
    local p="${1,,}"
    case "$p" in tcp|udp|both) echo "$p" ;; *) echo "both" ;; esac
}

get_ip() {
    local addr="$1"
    if is_ipv4 "$addr"; then echo "$addr"; return 0; fi
    dig +time=2 +tries=1 +short -4 A "$addr" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n 1
}

manage_firewall() {
    local action="$1"; local port="$2"; local proto="$3"
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
    return 0
}

base64_nw() {
    if base64 --help 2>&1 | grep -q -- '-w'; then base64 -w 0; else base64 | tr -d '\n'; fi
}

meta_get() {
    local key="$1"; [[ -f "$META_FILE" ]] || return 1
    grep -E "^${key}=" "$META_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- | sed 's/^"//; s/"$//'
}

meta_set() {
    local key="$1"; local value="$2"
    mkdir -p "$META_DIR" 2>/dev/null || true
    touch "$META_FILE" 2>/dev/null || true
    chmod 600 "$META_FILE" 2>/dev/null || true
    if grep -qE "^${key}=" "$META_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|g" "$META_FILE"
    else
        echo "${key}=\"${value}\"" >> "$META_FILE"
    fi
}

github_latest_tag() {
    local repo="$1"; local tag=""
    if have_cmd curl && have_cmd jq; then tag=$(curl -fsSL --max-time 10 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | jq -r '.tag_name' 2>/dev/null); fi
    [[ -n "$tag" && "$tag" != "null" ]] && echo "$tag"
}

safe_install_binary() {
    local newbin="$1"; local dest="$2"; local backup="${dest}.bak.$(date +%s)"
    [[ -s "$newbin" ]] || return 1
    [[ -f "$dest" ]] && cp -a "$dest" "$backup" 2>/dev/null || true
    install -m 755 "$newbin" "${dest}.new" >/dev/null 2>&1 || return 1
    mv -f "${dest}.new" "$dest" >/dev/null 2>&1 || return 1
    return 0
}

force_kill_service() {
    local target=$1; local from_menu=$2
    if [[ -z "$target" ]]; then
        msg_err "❌ 目标服务名为空！"
        [[ "$from_menu" == "menu" ]] && { sleep 2; return; } || exit 1
    fi
    echo -e "${RED}☢️ 正在执行系统级物理粉碎: ${target} ...${RESET}"
    systemctl stop "$target" 2>/dev/null
    systemctl disable "$target" 2>/dev/null
    rm -f "/etc/systemd/system/${target}.service" "/etc/systemd/system/${target}"
    systemctl daemon-reload
    msg_ok "✅ 目标服务 [${target}] 已彻底蒸发！"
    [[ "$from_menu" == "menu" ]] && sleep 2 || exit 0
}

# ==============================================================================
# 环境初始化与安全接管
# ==============================================================================
init_env() {
    [[ $EUID -ne 0 ]] && msg_err "错误: 必须使用 root 权限运行！" && exit 1

    local deps=(curl jq bc wget tar openssl unzip nftables dnsutils util-linux iproute2 sysctl)
    local missing=()
    for dep in "${deps[@]}"; do
        if ! have_cmd "${dep%% *}"; then
             case "$dep" in
                 "dnsutils") have_cmd dig || missing+=("$dep") ;;
                 "iproute2") have_cmd ss || missing+=("$dep") ;;
                 *) missing+=("$dep") ;;
             esac
        fi
    done

    if ((${#missing[@]} > 0)); then
        if have_cmd apt-get; then
            apt-get update -qq >/dev/null 2>&1 || true
            apt-get install -yqq curl jq bc wget tar xz-utils openssl unzip util-linux e2fsprogs nftables dnsutils iproute2 >/dev/null 2>&1 || true
        elif have_cmd yum || have_cmd dnf; then
            local mgr="yum"
            have_cmd dnf && mgr="dnf"
            "$mgr" install -yq curl jq bc wget tar xz openssl unzip util-linux e2fsprogs nftables bind-utils iproute >/dev/null 2>&1 || true
        fi
    fi

    mkdir -p "$META_DIR" "$DNS_BACKUP_DIR" "$NFT_MGR_DIR" "$NFT_LOG_DIR" 2>/dev/null || true
    [[ -f "$NFT_CONFIG_FILE" ]] || touch "$NFT_CONFIG_FILE"
    [[ -f "$NFT_SETTINGS_FILE" ]] || touch "$NFT_SETTINGS_FILE"
    chmod 600 "$NFT_CONFIG_FILE" "$NFT_SETTINGS_FILE" 2>/dev/null || true

    rm -f /usr/local/bin/ssr 2>/dev/null
    rm -f /usr/local/bin/nftmgr 2>/dev/null
    rm -f /usr/local/bin/nft 2>/dev/null

    local self; self="$(script_realpath)"
    if [[ "$self" != "$SCRIPT_FILE" ]]; then
        cp -f "$self" "$SCRIPT_FILE" 2>/dev/null || true
        chmod +x "$SCRIPT_FILE" 2>/dev/null || true
    fi
}

init_cron_base() {
    local lock_prefix=""
    have_cmd flock && lock_prefix="flock -n ${LOCK_FILE}"
    crontab -l 2>/dev/null | grep -vE "/usr/local/bin/(ssr|nftmgr|my)" > "$CRON_BK_FILE" || true
    if ! grep -q "vm.drop_caches" "$CRON_BK_FILE"; then
        echo "0 2 * * * /sbin/sysctl -w vm.drop_caches=3 >/dev/null 2>&1" >> "$CRON_BK_FILE"
    fi
    crontab "$CRON_BK_FILE" 2>/dev/null || true
    rm -f "$CRON_BK_FILE"
}

# ==============================================================================
# 模块通用管理系统 (系统/DNS/密钥/时间/CF DDNS)
# ==============================================================================
change_ssh_port() {
    read -rp "新的 SSH 端口号 (1-65535): " new_port
    if is_port "$new_port"; then
        manage_firewall "add" "$new_port" "tcp"
        sed -i "s/^#\?Port [0-9]*/Port $new_port/g" /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
        msg_ok "✅ SSH 端口已修改为 $new_port 。"
    else
        msg_err "❌ 端口无效。"
    fi
    sleep 2
}

change_root_password() {
    read -rsp "新的 root 密码: " new_pass; echo ""
    [[ -z "$new_pass" ]] && return
    read -rsp "再次输入确认: " new_pass_confirm; echo ""
    [[ "$new_pass" != "$new_pass_confirm" ]] && msg_err "两次密码不一致！" && sleep 2 && return
    echo "root:$new_pass" | chpasswd && msg_ok "✅ 密码修改成功！"
    sleep 2
}

sync_server_time() {
    echo -e "${CYAN}>>> 正在同步时间...${RESET}"
    if have_cmd apt-get; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -yqq systemd-timesyncd >/dev/null 2>&1 || true
        systemctl enable --now systemd-timesyncd 2>/dev/null || true
    elif have_cmd yum; then
        yum install -yq chrony >/dev/null 2>&1 || true
        systemctl enable --now chronyd 2>/dev/null || true
    fi
    msg_ok "✅ 同步服务已启动（若系统支持）。"
    sleep 2
}

apply_ssh_key_sec() {
    sed -i 's/^#\?PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
    sed -i 's/^#\?PasswordAuthentication no/PasswordAuthentication no/g' /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
    msg_ok "✅ 密码登录已封锁。"
    sleep 2
}

ssh_key_menu() {
    while true; do
        clear
        echo -e "${CYAN}========= SSH 密钥登录管理 =========${RESET}"
        echo -e "${YELLOW} 1.${RESET} 自动拉取公钥 (GitHub)"
        echo -e "${YELLOW} 2.${RESET} 手动填写公钥"
        echo -e "${YELLOW} 3.${RESET} 一键生成密钥对"
        echo -e "${RED} 4.${RESET} 恢复密码登录"
        echo -e " 0. 返回"
        read -rp "输入 [0-4]: " skm_num
        case "$skm_num" in
            1)
                read -rp "GitHub用户名: " gh_user
                [[ -n "$gh_user" ]] && {
                    mkdir -p ~/.ssh && chmod 700 ~/.ssh
                    local keys; keys=$(curl -s "https://github.com/${gh_user}.keys" 2>/dev/null || true)
                    [[ -n "$keys" && "$keys" != "Not Found" ]] && {
                        echo "$keys" >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys
                        msg_ok "✅ 拉取成功！"; apply_ssh_key_sec
                    } || { msg_err "❌ 未找到公钥。"; sleep 2; }
                }
                ;;
            2)
                read -rp "粘贴公钥: " manual_key
                [[ -n "$manual_key" ]] && {
                    mkdir -p ~/.ssh && chmod 700 ~/.ssh
                    echo "$manual_key" >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys
                    msg_ok "✅ 成功！"; apply_ssh_key_sec
                }
                ;;
            3)
                mkdir -p ~/.ssh && chmod 700 ~/.ssh; rm -f ~/.ssh/id_ed25519*
                ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -q
                cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys
                echo -e "${RED}⚠️ 请保存以下私钥（只显示一次）！⚠️${RESET}\n"
                cat ~/.ssh/id_ed25519
                echo -e "\n${YELLOW}========================${RESET}"
                read -rp "关闭密码登录 (y/N): " confirm
                [[ "$confirm" == "y" || "$confirm" == "Y" ]] && apply_ssh_key_sec
                ;;
            4)
                sed -i 's/^#\?PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config
                systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
                msg_ok "✅ 已恢复密码登录。"; sleep 2
                ;;
            0) return ;;
        esac
    done
}

dns_backup() {
    mkdir -p "$DNS_BACKUP_DIR"
    local is_symlink=0; local target=""
    if [[ -L /etc/resolv.conf ]]; then
        is_symlink=1; target="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
    else
        cp -a /etc/resolv.conf "$DNS_FILE_BAK" 2>/dev/null || true
    fi

    local immutable=0
    if have_cmd lsattr; then
        if lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'; then immutable=1; fi
    fi

    cat > "$DNS_META" << EOF
BACKUP_TIME="$(date -Is 2>/dev/null || date)"
IS_SYMLINK="${is_symlink}"
SYMLINK_TARGET="${target}"
WAS_IMMUTABLE="${immutable}"
EOF
    chmod 600 "$DNS_META" "$DNS_FILE_BAK" 2>/dev/null || true
}

dns_apply_resolvconf() {
    local lock_mode="$1"
    if have_cmd chattr; then chattr -i /etc/resolv.conf 2>/dev/null || true; fi
    cat > /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2606:4700:4700::1111
EOF
    if [[ "$lock_mode" == "lock" ]] && have_cmd chattr; then
        chattr +i /etc/resolv.conf 2>/dev/null || true
    fi
}

dns_apply_systemd_resolved() {
    mkdir -p /etc/systemd/resolved.conf.d
    cat > "$RESOLVED_DROPIN" << 'EOF'
[Resolve]
DNS=1.1.1.1 8.8.8.8 2606:4700:4700::1111
FallbackDNS=9.9.9.9 149.112.112.112
DNSSEC=no
EOF
    chmod 644 "$RESOLVED_DROPIN" 2>/dev/null || true
    systemctl restart systemd-resolved 2>/dev/null || true
}

dns_set_or_lock() {
    local mode="$1"; dns_backup
    if [[ -L /etc/resolv.conf ]]; then
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            dns_apply_systemd_resolved
        else
            msg_warn "⚠️ 检测到 /etc/resolv.conf 为 symlink，但 systemd-resolved 未运行，已跳过强制写入以避免破坏系统 DNS 机制。"
            return 1
        fi
    else
        dns_apply_resolvconf "$mode"
    fi
    return 0
}

dns_unlock_restore() {
    if have_cmd chattr; then chattr -i /etc/resolv.conf 2>/dev/null || true; fi
    if [[ -f "$RESOLVED_DROPIN" ]]; then
        rm -f "$RESOLVED_DROPIN"; systemctl restart systemd-resolved 2>/dev/null || true
    fi
    if [[ -f "$DNS_META" ]]; then
        source "$DNS_META" 2>/dev/null || true
        if [[ "${IS_SYMLINK:-0}" == "1" ]]; then
            if [[ -n "${SYMLINK_TARGET:-}" ]]; then rm -f /etc/resolv.conf; ln -sf "${SYMLINK_TARGET}" /etc/resolv.conf; fi
        else
            if [[ -f "$DNS_FILE_BAK" ]]; then cp -a "$DNS_FILE_BAK" /etc/resolv.conf 2>/dev/null || true; fi
        fi
        if [[ "${WAS_IMMUTABLE:-0}" == "1" ]] && have_cmd chattr; then chattr +i /etc/resolv.conf 2>/dev/null || true; fi
    fi
}

dns_status() {
    echo -e "${CYAN}========= DNS 状态 =========${RESET}"
    if [[ -L /etc/resolv.conf ]]; then echo -e "resolv.conf: ${YELLOW}symlink${RESET} -> $(readlink -f /etc/resolv.conf 2>/dev/null || echo "unknown")"
    else echo -e "resolv.conf: ${GREEN}regular file${RESET}"; fi
    if have_cmd lsattr; then
        local attr; attr=$(lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}')
        if echo "$attr" | grep -q 'i'; then echo -e "immutable: ${YELLOW}ON${RESET}"; else echo -e "immutable: ${GREEN}OFF${RESET}"; fi
    fi
    if [[ -f "$RESOLVED_DROPIN" ]]; then echo -e "systemd-resolved drop-in: ${YELLOW}enabled${RESET} (${RESOLVED_DROPIN})"
    else echo -e "systemd-resolved drop-in: ${GREEN}disabled${RESET}"; fi
    echo -e "${CYAN}---------- /etc/resolv.conf ----------${RESET}"
    sed -n '1,30p' /etc/resolv.conf 2>/dev/null || true
}

dns_menu() {
    while true; do
        clear
        echo -e "${CYAN}========= DNS 管理中心 =========${RESET}"
        echo -e "${YELLOW} 1.${RESET} 查看 DNS 状态"
        echo -e "${YELLOW} 2.${RESET} 设置 DNS（不锁）"
        echo -e "${YELLOW} 3.${RESET} 锁定 DNS（尽可能稳健：symlink 则走 systemd-resolved）"
        echo -e "${YELLOW} 4.${RESET} 一键解锁并恢复（回滚至备份）"
        echo -e " 0. 返回"
        read -rp "输入 [0-4]: " dn
        case "$dn" in
            1) clear; dns_status; echo ""; read -n 1 -s -r -p "按任意键返回..." ;;
            2) dns_set_or_lock "set"; msg_ok "✅ DNS 已设置。"; sleep 2 ;;
            3) dns_set_or_lock "lock"; msg_ok "✅ DNS 已锁定/固定。"; sleep 2 ;;
            4) dns_unlock_restore; msg_ok "✅ 已解锁并恢复。"; sleep 2 ;;
            0) return ;;
        esac
    done
}

setup_cf_ddns() {
    clear
    echo -e "${CYAN}========= 🌐 原生 Cloudflare DDNS 配置 =========${RESET}"
    echo -e "${YELLOW}前提：域名已托管到 Cloudflare，并准备好 API Token（需 Zone.DNS 读写权限）。${RESET}\n"
    read -rsp "1. 请输入 Cloudflare API Token: " cf_token; echo ""
    [[ -z "$cf_token" ]] && return
    read -rp "2. 请输入根域名 (例如: example.com): " cf_zone
    [[ -z "$cf_zone" ]] && return
    read -rp "3. 请输入要绑定的子域名 (例如: ddns.example.com): " cf_record
    [[ -z "$cf_record" ]] && return

    echo -e "${CYAN}>>> 正在验证 Token 并获取 Zone ID...${RESET}"
    local zone_response zone_id
    zone_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$cf_zone" -H "Authorization: Bearer $cf_token" -H "Content-Type: application/json")
    zone_id=$(echo "$zone_response" | jq -r '.result[0].id' 2>/dev/null)

    if [[ -z "$zone_id" || "$zone_id" == "null" ]]; then
        msg_err "❌ 验证失败！请检查 Token 或根域名。"
        sleep 3
        return
    fi

    mkdir -p /usr/local/etc
    cat > "$DDNS_CONF" << EOF
CF_TOKEN="${cf_token}"
CF_ZONE_ID="${zone_id}"
CF_RECORD="${cf_record}"
LAST_IP=""
EOF
    chmod 600 "$DDNS_CONF" 2>/dev/null || true
    msg_ok "✅ DDNS 配置保存成功！\n>>> 正在进行首次推送..."
    run_cf_ddns "manual"
    sleep 2
}

run_cf_ddns() {
    local mode=$1
    if [[ ! -f "$DDNS_CONF" ]]; then
        [[ "$mode" == "manual" ]] && msg_err "❌ DDNS 未配置。"
        return
    fi
    source "$DDNS_CONF"

    local current_ip
    current_ip=$(curl -s4m8 https://api.ipify.org 2>/dev/null || curl -s4m8 ifconfig.me 2>/dev/null || true)
    if [[ -z "$current_ip" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [错误] 无法获取公网 IP" >> "$DDNS_LOG"
        return
    fi
    if [[ "$current_ip" == "$LAST_IP" && "$mode" != "manual" ]]; then return; fi
    [[ "$mode" == "manual" ]] && echo -e "${YELLOW}获取到当前 IP: $current_ip ，正在通信...${RESET}"

    local record_response record_id api_result success
    record_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?name=${CF_RECORD}&type=A" -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json")
    record_id=$(echo "$record_response" | jq -r '.result[0].id' 2>/dev/null)

    if [[ -z "$record_id" || "$record_id" == "null" ]]; then
        api_result=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" --data "{\"type\":\"A\",\"name\":\"${CF_RECORD}\",\"content\":\"${current_ip}\",\"ttl\":60,\"proxied\":false}")
    else
        api_result=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}" -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" --data "{\"type\":\"A\",\"name\":\"${CF_RECORD}\",\"content\":\"${current_ip}\",\"ttl\":60,\"proxied\":false}")
    fi

    success=$(echo "$api_result" | jq -r '.success' 2>/dev/null)
    if [[ "$success" == "true" ]]; then
        sed -i "s/^LAST_IP=.*/LAST_IP=\"${current_ip}\"/g" "$DDNS_CONF"
        chmod 600 "$DDNS_CONF" 2>/dev/null || true
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [成功] IP 更新为: $current_ip" >> "$DDNS_LOG"
        [[ "$mode" == "manual" ]] && msg_ok "✅ 解析已更新为: $current_ip"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [失败] API响应: $api_result" >> "$DDNS_LOG"
        [[ "$mode" == "manual" ]] && msg_err "❌ 更新失败！"
    fi
}

remove_cf_ddns() {
    local cli_mode=$1
    if [[ ! -f "$DDNS_CONF" ]]; then
        msg_err "❌ DDNS 未配置。"
        [[ "$cli_mode" != "force" ]] && sleep 2
        return
    fi
    source "$DDNS_CONF"
    if [[ "$cli_mode" != "force" ]]; then
        echo -e "${RED}⚠️ 警告：这将删除本地配置并尝试粉碎 Cloudflare 云端记录 [${CF_RECORD}]！${RESET}"
        read -rp "确定要执行吗？(y/N): " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    fi
    echo -e "${CYAN}>>> 正在销毁云端解析记录...${RESET}"
    local record_response record_id
    record_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?name=${CF_RECORD}&type=A" -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json")
    record_id=$(echo "$record_response" | jq -r '.result[0].id' 2>/dev/null)

    if [[ -n "$record_id" && "$record_id" != "null" ]]; then
        curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}" -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" > /dev/null 2>&1 || true
        msg_ok "✅ 云端记录已删除（若 API 权限允许）。"
    fi
    rm -f "$DDNS_CONF" "$DDNS_LOG"
    crontab -l 2>/dev/null | grep -v "${SCRIPT_FILE} --ssr-ddns" | crontab - 2>/dev/null || true
    msg_ok "✅ 本地 DDNS 任务已撤销。"
    [[ "$cli_mode" != "force" ]] && sleep 2
}

cf_ddns_menu() {
    while true; do
        clear
        echo -e "${CYAN}========= 🌐 动态域名解析 (Cloudflare DDNS) =========${RESET}"
        if [[ -f "$DDNS_CONF" ]]; then
            source "$DDNS_CONF"
            echo -e "${GREEN}当前状态: 已启用守护${RESET}"
            echo -e "绑定域名: ${YELLOW}$CF_RECORD${RESET}"
            echo -e "最近记录 IP: ${YELLOW}$LAST_IP${RESET}"
            echo -e "---------------------------------"
            echo -e "${YELLOW} 1.${RESET} 修改 DDNS 配置"
            echo -e "${YELLOW} 2.${RESET} 手动强制推送更新"
            echo -e "${YELLOW} 3.${RESET} 查看运行日志(最近15行)"
            echo -e "${RED} 4.${RESET} 彻底删除 DDNS (含云端记录)"
            echo -e " 0. 返回"
            read -rp "请输入数字 [0-4]: " ddns_num
            case "$ddns_num" in
                1) setup_cf_ddns ;;
                2) run_cf_ddns "manual"; sleep 2 ;;
                3) if [[ -f "$DDNS_LOG" ]]; then clear; tail -n 15 "$DDNS_LOG"; echo ""; read -n 1 -s -r -p "按任意键返回..."; fi ;;
                4) remove_cf_ddns "menu" ;;
                0) return ;;
            esac
        else
            echo -e "${RED}当前状态: 未配置${RESET}"
            echo -e "---------------------------------"
            echo -e "${YELLOW} 1.${RESET} 开启 Cloudflare DDNS"
            echo -e " 0. 返回"
            read -rp "请输入数字 [0-1]: " ddns_num
            case "$ddns_num" in
                1) setup_cf_ddns ;;
                0) return ;;
            esac
        fi
    done
}
# ==============================================================================
# 节点原生部署模块 (SS-Rust / VLESS Reality / ShadowTLS)
# ==============================================================================
install_ss_rust_native() {
    clear
    echo -e "${CYAN}========= 原生交互安装 SS-Rust =========${RESET}"
    rm -f /etc/systemd/system/ss-rust.service

    read -rp "自定义端口 (1-65535) [留空随机]: " custom_port
    local port=$custom_port
    if ! is_port "$port"; then port=$((RANDOM % 55535 + 10000)); fi

    echo -e "\n${CYAN}加密协议:${RESET}"
    echo -e " 1) 2022-blake3-aes-128-gcm"
    echo -e " 2) 2022-blake3-aes-256-gcm"
    echo -e " 3) 2022-blake3-chacha20-poly1305"
    echo -e " 4) aes-256-gcm"
    read -rp "选择 [1-4] (默认1): " method_choice

    local method="2022-blake3-aes-128-gcm"; local pwd_len=16
    case "$method_choice" in
        2) method="2022-blake3-aes-256-gcm"; pwd_len=32 ;;
        3) method="2022-blake3-chacha20-poly1305"; pwd_len=32 ;;
        4) method="aes-256-gcm"; pwd_len=0 ;;
    esac

    local pwd=""
    if [[ "$pwd_len" -ne 0 ]]; then
        read -rp "密码 (留空生成 Base64): " input_pwd
        if [[ -z "$input_pwd" ]]; then pwd=$(openssl rand -base64 "$pwd_len" 2>/dev/null | tr -d '\n')
        else pwd=$(echo -n "$input_pwd" | base64_nw); fi
    else
        read -rp "传统密码 (留空随机): " input_pwd
        if [[ -z "$input_pwd" ]]; then pwd=$(openssl rand -hex 12 2>/dev/null)
        else pwd="$input_pwd"; fi
    fi

    local arch; arch=$(uname -m)
    local ss_arch="x86_64-unknown-linux-gnu"
    [[ "$arch" == "aarch64" ]] && ss_arch="aarch64-unknown-linux-gnu"

    echo -e "${CYAN}>>> 正在获取 SS-Rust 最新版本信息...${RESET}"
    local ss_latest; ss_latest=$(github_latest_tag "shadowsocks/shadowsocks-rust")
    [[ -z "$ss_latest" ]] && ss_latest="v1.22.0"

    local tmpdir; tmpdir=$(mktemp -d /tmp/ssr-ssrust.XXXXXX)
    local tarball="${tmpdir}/ss-rust.tar.xz"
    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${ss_latest}/shadowsocks-${ss_latest}.${ss_arch}.tar.xz"

    echo -e "${CYAN}>>> 下载核心: ${ss_latest} (${ss_arch}) ...${RESET}"
    if ! download_file "$url" "$tarball" || [[ ! -s "$tarball" ]] || ! tar -tf "$tarball" >/dev/null 2>&1; then
        msg_err "❌ 核心下载或校验失败，请重试。"
        rm -rf "$tmpdir"; sleep 3; return
    fi

    tar -xf "$tarball" -C "$tmpdir" ssserver >/dev/null 2>&1 || true
    if [[ ! -x "${tmpdir}/ssserver" ]]; then
        msg_err "❌ 解压失败：未找到 ssserver。"
        rm -rf "$tmpdir"; sleep 3; return
    fi

    if ! run_with_timeout 3 "${tmpdir}/ssserver" --version >/dev/null 2>&1; then
        run_with_timeout 3 "${tmpdir}/ssserver" -V >/dev/null 2>&1 || {
            msg_err "❌ 新核心自检失败（无法运行）。已中止替换。"
            rm -rf "$tmpdir"; sleep 3; return
        }
    fi

    safe_install_binary "${tmpdir}/ssserver" /usr/local/bin/ss-rust || {
        msg_err "❌ 安装失败（写入 /usr/local/bin/ss-rust 失败）。"
        rm -rf "$tmpdir"; sleep 3; return
    }

    mkdir -p /etc/ss-rust
    cat > /etc/ss-rust/config.json << EOF
{ "server": "::", "server_port": $port, "password": "$pwd", "method": "$method", "mode": "tcp_and_udp", "fast_open": true }
EOF

    cat > /etc/systemd/system/ss-rust.service << EOF
[Unit]
Description=Shadowsocks-Rust Server
After=network.target

[Service]
ExecStart=/usr/local/bin/ss-rust -c /etc/ss-rust/config.json
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now ss-rust >/dev/null 2>&1 || true

    manage_firewall "add" "$port" "both"
    meta_set "SS_RUST_TAG" "$ss_latest"

    msg_ok "✅ SS-Rust (${ss_latest}) 安装完成！"
    rm -rf "$tmpdir"; sleep 2
}

install_vless_native() {
    clear
    echo -e "${CYAN}========= 原生交互安装 VLESS Reality =========${RESET}"
    rm -f /etc/systemd/system/xray.service

    read -rp "伪装域名 [默认 updates.cdn-apple.com]: " sni_domain
    [[ -z "$sni_domain" ]] && sni_domain="updates.cdn-apple.com"

    read -rp "监听端口 [留空随机]: " port
    if ! is_port "$port"; then port=$((RANDOM % 55535 + 10000)); fi

    local arch; arch=$(uname -m)
    local xray_arch="64"
    [[ "$arch" == "aarch64" ]] && xray_arch="arm64-v8a"

    echo -e "${CYAN}>>> 正在获取 Xray 最新版本信息...${RESET}"
    local xray_latest; xray_latest=$(github_latest_tag "XTLS/Xray-core")
    [[ -z "$xray_latest" ]] && xray_latest="v1.8.24"

    local tmpdir; tmpdir=$(mktemp -d /tmp/ssr-xray.XXXXXX)
    local zipf="${tmpdir}/xray.zip"
    local url="https://github.com/XTLS/Xray-core/releases/download/${xray_latest}/Xray-linux-${xray_arch}.zip"

    echo -e "${CYAN}>>> 下载核心: ${xray_latest} (linux-${xray_arch}) ...${RESET}"
    if ! download_file "$url" "$zipf" || [[ ! -s "$zipf" ]] || ! unzip -t "$zipf" >/dev/null 2>&1; then
        msg_err "❌ 核心下载或校验失败。"
        rm -rf "$tmpdir"; sleep 3; return
    fi

    unzip -qo "$zipf" xray -d "$tmpdir" >/dev/null 2>&1 || true
    if [[ ! -x "${tmpdir}/xray" ]]; then
        msg_err "❌ 解压失败：未找到 xray。"
        rm -rf "$tmpdir"; sleep 3; return
    fi

    if ! run_with_timeout 3 "${tmpdir}/xray" version >/dev/null 2>&1; then
        msg_err "❌ 新核心自检失败（无法运行）。已中止替换。"
        rm -rf "$tmpdir"; sleep 3; return
    fi

    safe_install_binary "${tmpdir}/xray" /usr/local/bin/xray || {
        msg_err "❌ 安装失败（写入 /usr/local/bin/xray 失败）。"
        rm -rf "$tmpdir"; sleep 3; return
    }

    mkdir -p /usr/local/etc/xray
    local uuid keys priv pub short_id
    uuid=$(/usr/local/bin/xray uuid 2>/dev/null)
    keys=$(/usr/local/bin/xray x25519 2>/dev/null)
    priv=$(echo "$keys" | grep "Private" | awk '{print $3}')
    pub=$(echo "$keys" | grep "Public" | awk '{print $3}')
    short_id=$(openssl rand -hex 8 2>/dev/null)

    cat > /usr/local/etc/xray/config.json << EOF
{ "inbounds": [{ "port": $port, "protocol": "vless", "settings": { "clients": [{"id": "$uuid", "flow": "xtls-rprx-vision"}], "decryption": "none" }, "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "dest": "${sni_domain}:443", "serverNames": ["${sni_domain}"], "privateKey": "$priv", "shortIds": ["$short_id"] } } }], "outbounds": [{"protocol": "freedom"}] }
EOF

    cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now xray >/dev/null 2>&1 || true

    manage_firewall "add" "$port" "tcp"
    meta_set "XRAY_TAG" "$xray_latest"

    msg_ok "✅ VLESS Reality (${xray_latest}) 安装成功！"
    rm -rf "$tmpdir"; sleep 2
}

install_shadowtls_native() {
    clear
    echo -e "${CYAN}========= 原生安装 ShadowTLS =========${RESET}"

    local ss_port=""
    if [[ -f "/etc/ss-rust/config.json" ]]; then
        ss_port=$(jq -r '.server_port' /etc/ss-rust/config.json 2>/dev/null)
    fi

    local up_port=""
    if [[ -n "$ss_port" && "$ss_port" != "null" ]]; then
        echo -e "${YELLOW}检测到本地 SS-Rust，推荐保护：${RESET}"
        echo -e "${CYAN} 1) 保护 SS-Rust (端口: $ss_port)${RESET}"
        echo -e "${CYAN} 2) 手动输入自定义端口${RESET}"
        read -rp "选择 [1-2]: " protect_choice
        if [[ "$protect_choice" == "1" ]]; then up_port=$ss_port
        else read -rp "需要保护的上游端口: " up_port; fi
    else
        read -rp "需要保护的上游端口: " up_port
    fi

    [[ -z "$up_port" ]] && msg_err "端口无效！" && sleep 2 && return

    read -rp "ShadowTLS 伪装端口 [留空随机]: " listen_port
    if ! is_port "$listen_port"; then listen_port=$((RANDOM % 55535 + 10000)); fi

    read -rp "伪装域名 (SNI) [留空默认 updates.cdn-apple.com]: " sni_domain
    [[ -z "$sni_domain" ]] && sni_domain="updates.cdn-apple.com"

    local pwd; pwd=$(openssl rand -base64 8 2>/dev/null | tr -d '\n')
    local arch; arch=$(uname -m)
    local st_arch="x86_64-unknown-linux-musl"
    [[ "$arch" == "aarch64" ]] && st_arch="aarch64-unknown-linux-musl"

    echo -e "${CYAN}>>> 正在获取 ShadowTLS 最新版本信息...${RESET}"
    local st_latest; st_latest=$(github_latest_tag "ihciah/shadow-tls")
    [[ -z "$st_latest" ]] && st_latest="v0.2.25"

    local tmpdir; tmpdir=$(mktemp -d /tmp/ssr-stls.XXXXXX)
    local binf="${tmpdir}/shadow-tls"
    local url="https://github.com/ihciah/shadow-tls/releases/download/${st_latest}/shadow-tls-${st_arch}"

    echo -e "${CYAN}>>> 下载核心: ${st_latest} (${st_arch}) ...${RESET}"
    if ! download_file "$url" "$binf" || [[ ! -s "$binf" ]]; then
        msg_err "❌ 下载失败。"
        rm -rf "$tmpdir"; sleep 3; return
    fi
    chmod +x "$binf" >/dev/null 2>&1 || true

    if ! run_with_timeout 3 "$binf" --version >/dev/null 2>&1; then
        run_with_timeout 3 "$binf" -V >/dev/null 2>&1 || run_with_timeout 3 "$binf" --help >/dev/null 2>&1 || {
            msg_err "❌ 新核心自检失败（无法运行）。已中止替换。"
            rm -rf "$tmpdir"; sleep 3; return
        }
    fi

    safe_install_binary "$binf" /usr/local/bin/shadow-tls || {
        msg_err "❌ 安装失败（写入 /usr/local/bin/shadow-tls 失败）。"
        rm -rf "$tmpdir"; sleep 3; return
    }

    cat > /etc/systemd/system/shadowtls-${listen_port}.service << EOF
[Unit]
Description=ShadowTLS Service on port ${listen_port}
After=network.target

[Service]
ExecStart=/usr/local/bin/shadow-tls --v3 --strict server \\
  --listen 0.0.0.0:${listen_port} \\
  --server 127.0.0.1:${up_port} \\
  --tls ${sni_domain}:443 \\
  --password ${pwd}
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now shadowtls-"${listen_port}" >/dev/null 2>&1 || true

    manage_firewall "add" "$listen_port" "tcp"
    meta_set "SHADOWTLS_TAG" "$st_latest"

    msg_ok "✅ ShadowTLS (${st_latest}) 安装成功！已挂载在 ${up_port} 上层。"
    rm -rf "$tmpdir"; sleep 2
}

# ==============================================================================
# 统一节点生命周期管控中心
# ==============================================================================
unified_node_manager() {
    while true; do
        clear
        echo -e "${CYAN}========= 🔰 统一节点生命周期管控中心 =========${RESET}"

        for s in /etc/systemd/system/shadowtls-*.service; do
            [[ -e "$s" ]] || continue
            local check_port; check_port=$(basename "$s" | sed 's/shadowtls-//g' | sed 's/.service//g')
            if ! [[ "$check_port" =~ ^[0-9]+$ ]]; then
                systemctl stop "$(basename "$s")" 2>/dev/null || true
                systemctl disable "$(basename "$s")" 2>/dev/null || true
                rm -f "$s"; systemctl daemon-reload
            fi
        done

        local has_ss=0 has_vless=0 has_stls=0
        if [[ -f "/etc/ss-rust/config.json" ]]; then echo -e "${GREEN} 1) ⚡ SS-Rust 节点${RESET}"; has_ss=1
        else echo -e "${RED} 1) ❌ 未部署 SS-Rust${RESET}"; fi

        if [[ -f "/usr/local/etc/xray/config.json" ]]; then echo -e "${GREEN} 2) 🔮 VLESS Reality 节点${RESET}"; has_vless=1
        else echo -e "${RED} 2) ❌ 未部署 VLESS Reality${RESET}"; fi

        if ls /etc/systemd/system/shadowtls-*.service 1> /dev/null 2>&1; then echo -e "${GREEN} 3) 🛡️ ShadowTLS 防阻断保护实例${RESET}"; has_stls=1
        else echo -e "${RED} 3) ❌ 未部署 ShadowTLS${RESET}"; fi

        echo -e "${CYAN}--------------------------------------------${RESET}"
        echo -e "${RED} 4) ☢️ 全局强制核爆 (清理任意卡死/幽灵服务)${RESET}"
        echo -e " 0) 返回"
        read -rp "请选择 [0-4]: " node_choice

        case "$node_choice" in
            1)
                if [[ $has_ss -eq 1 ]]; then
                    clear
                    local ip port method password b64 link
                    ip=$(curl -s4m8 ip.sb 2>/dev/null || curl -s4m8 ifconfig.me 2>/dev/null || echo "0.0.0.0")
                    port=$(jq -r '.server_port' /etc/ss-rust/config.json 2>/dev/null)
                    method=$(jq -r '.method' /etc/ss-rust/config.json 2>/dev/null)
                    password=$(jq -r '.password' /etc/ss-rust/config.json 2>/dev/null)
                    b64=$(echo -n "${method}:${password}" | base64_nw)
                    link="ss://${b64}@${ip}:${port}#SS-Rust"
                    echo -e "IP: ${GREEN}${ip}${RESET} | 端口: ${GREEN}${port}${RESET}"
                    echo -e "协议: ${GREEN}${method}${RESET} | 密码: ${GREEN}${password}${RESET}"
                    echo -e "${YELLOW}链接:${RESET}\n${link}"
                    echo -e "---------------------------------"
                    echo -e "${YELLOW}1) 修改端口${RESET} | ${YELLOW}2) 修改密码${RESET} | ${RED}3) 删除节点${RESET} | 0) 返回"
                    read -rp "输入操作: " op
                    if [[ "$op" == "1" ]]; then
                        read -rp "新端口 (1-65535): " np
                        if is_port "$np"; then
                            jq --argjson p "$np" '.server_port = $p' /etc/ss-rust/config.json > /tmp/tmp.json && mv -f /tmp/tmp.json /etc/ss-rust/config.json
                            manage_firewall "del" "$port" "both"
                            manage_firewall "add" "$np" "both"
                            systemctl restart ss-rust 2>/dev/null || true
                            msg_ok "✅ 修改成功"
                        else msg_err "❌ 端口无效"; fi; sleep 1
                    elif [[ "$op" == "2" ]]; then
                        read -rp "新密码: " npwd
                        [[ -z "$npwd" ]] && { msg_err "❌ 密码不能为空"; sleep 1; continue; }
                        jq --arg pwd "$npwd" '.password = $pwd' /etc/ss-rust/config.json > /tmp/tmp.json && mv -f /tmp/tmp.json /etc/ss-rust/config.json
                        systemctl restart ss-rust 2>/dev/null || true
                        msg_ok "✅ 修改成功"; sleep 1
                    elif [[ "$op" == "3" ]]; then
                        manage_firewall "del" "$port" "both"
                        systemctl stop ss-rust 2>/dev/null || true
                        systemctl disable ss-rust 2>/dev/null || true
                        rm -rf /etc/ss-rust /usr/local/bin/ss-rust /etc/systemd/system/ss-rust.service
                        systemctl daemon-reload
                        msg_ok "✅ 已彻底销毁！"; sleep 1
                    fi
                fi
                ;;
            2)
                if [[ $has_vless -eq 1 ]]; then
                    clear
                    local ip port uuid sni
                    ip=$(curl -s4m8 ip.sb 2>/dev/null || curl -s4m8 ifconfig.me 2>/dev/null || echo "0.0.0.0")
                    port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json 2>/dev/null)
                    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' /usr/local/etc/xray/config.json 2>/dev/null)
                    sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' /usr/local/etc/xray/config.json 2>/dev/null)
                    echo -e "IP: ${GREEN}${ip}${RESET} | 端口: ${GREEN}${port}${RESET}"
                    echo -e "UUID: ${GREEN}${uuid}${RESET} | SNI伪装: ${GREEN}${sni}${RESET}"
                    echo -e "---------------------------------"
                    echo -e "${YELLOW}1) 重启节点${RESET} | ${RED}2) 删除节点${RESET} | 0) 返回"
                    read -rp "输入操作: " op
                    if [[ "$op" == "1" ]]; then systemctl restart xray 2>/dev/null || true; msg_ok "✅ 已重启"; sleep 1
                    elif [[ "$op" == "2" ]]; then
                        manage_firewall "del" "$port" "tcp"
                        systemctl stop xray 2>/dev/null || true
                        systemctl disable xray 2>/dev/null || true
                        rm -rf /usr/local/etc/xray /usr/local/bin/xray /etc/systemd/system/xray.service
                        systemctl daemon-reload
                        msg_ok "✅ 已彻底销毁！"; sleep 1
                    fi
                fi
                ;;
            3)
                if [[ $has_stls -eq 1 ]]; then
                    clear
                    local st_ports=(); local idx=1
                    for s in /etc/systemd/system/shadowtls-*.service; do
                        [[ -e "$s" ]] || continue
                        local st_port; st_port=$(basename "$s" | sed 's/shadowtls-//g' | sed 's/.service//g')
                        st_ports[$idx]=$st_port
                        local st_status
                        if systemctl is-active --quiet shadowtls-"$st_port" 2>/dev/null; then st_status="${GREEN}运行中${RESET}"
                        else st_status="${RED}已停止${RESET}"; fi
                        echo -e " ${CYAN}${idx})${RESET} 端口: ${YELLOW}${st_port}${RESET} [${st_status}]"
                        ((idx++))
                    done
                    echo -e "---------------------------------"
                    echo -e "${RED}1) 序号删除实例${RESET} | ${RED}9) ⚠️ 强制核爆所有残留${RESET} | 0) 返回"
                    read -rp "输入操作: " op
                    if [[ "$op" == "1" ]]; then
                        read -rp "输入实例序号 [1-$((idx-1))]: " del_idx
                        local del_port=${st_ports[$del_idx]}
                        if [[ -n "$del_port" && -f "/etc/systemd/system/shadowtls-${del_port}.service" ]]; then
                            manage_firewall "del" "$del_port" "tcp"
                            systemctl stop shadowtls-"$del_port" 2>/dev/null || true
                            systemctl disable shadowtls-"$del_port" 2>/dev/null || true
                            rm -f "/etc/systemd/system/shadowtls-${del_port}.service"
                            systemctl daemon-reload
                            if ! ls /etc/systemd/system/shadowtls-*.service 1> /dev/null 2>&1; then rm -f /usr/local/bin/shadow-tls; fi
                            msg_ok "✅ 已彻底销毁！"; sleep 1
                        fi
                    elif [[ "$op" == "9" ]]; then
                        echo -e "${RED}执行物理核爆...${RESET}"
                        for p in "${st_ports[@]}"; do
                            [[ -z "$p" ]] && continue
                            manage_firewall "del" "$p" "tcp"
                            systemctl stop "shadowtls-$p" 2>/dev/null || true
                            systemctl disable "shadowtls-$p" 2>/dev/null || true
                            rm -f "/etc/systemd/system/shadowtls-${p}.service"
                        done
                        rm -f /usr/local/bin/shadow-tls; systemctl daemon-reload
                        msg_ok "✅ 拔除成功！"; sleep 2
                    fi
                fi
                ;;
            4)
                clear
                echo -e "${CYAN}========= ☢️ 全局强制核爆中心 =========${RESET}"
                echo -e "参考名：${GREEN}ss-rust${RESET} | ${GREEN}xray${RESET} | ${GREEN}shadowtls-端口${RESET}"
                read -rp "请输入要粉碎的服务名 (直接回车取消): " nuke_target
                [[ -n "$nuke_target" ]] && force_kill_service "$nuke_target" "menu"
                ;;
            0) return ;;
        esac
    done
}

# ==============================================================================
# 网络调优 Profiles（NAT/常规）与后台任务
# ==============================================================================
apply_journald_limit() {
    local limit="${1:-50M}"
    if [[ -f /etc/systemd/journald.conf ]]; then
        if grep -qE '^\s*SystemMaxUse=' /etc/systemd/journald.conf; then
            sed -i "s|^\s*SystemMaxUse=.*|SystemMaxUse=${limit}|g" /etc/systemd/journald.conf
        else echo "SystemMaxUse=${limit}" >> /etc/systemd/journald.conf; fi
        systemctl restart systemd-journald 2>/dev/null || true
    fi
}

apply_ssh_keepalive() {
    local interval="${1:-30}"; local count="${2:-3}"
    if [[ -f /etc/ssh/sshd_config ]]; then
        sed -i "s/^#\?ClientAliveInterval.*/ClientAliveInterval ${interval}/g" /etc/ssh/sshd_config
        sed -i "s/^#\?ClientAliveCountMax.*/ClientAliveCountMax ${count}/g" /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    fi
}

ensure_swap() {
    local size_mb="$1"; [[ -z "$size_mb" ]] && size_mb=256
    if grep -q " swap " /etc/fstab 2>/dev/null; then return; fi
    rm -f /var/swap
    if dd if=/dev/zero of=/var/swap bs=1M count="$size_mb" status=none 2>/dev/null; then
        chmod 600 /var/swap; mkswap /var/swap >/dev/null 2>&1
        swapon /var/swap >/dev/null 2>&1 || true
        echo "/var/swap swap swap defaults 0 0" >> /etc/fstab
        msg_ok "✅ ${size_mb}MB Swap 创建成功！"
    else msg_warn "⚠️ Swap 创建失败（可能磁盘不足），已跳过。"; fi
}

apply_nat_profile() {
    local profile="$1"
    rm -f "$CONF_FILE" 2>/dev/null || true
    apply_journald_limit "50M"; apply_ssh_keepalive 30 3

    if [[ "$profile" == "perf" ]]; then dns_set_or_lock "lock" || true; ensure_swap 512
    else dns_set_or_lock "set" || true; ensure_swap 256; fi

    cat > "$NAT_CONF_FILE" << EOF
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 20
net.ipv4.tcp_keepalive_probes = 3
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    if [[ "$profile" == "perf" ]]; then
        cat >> "$NAT_CONF_FILE" << 'EOF'
net.ipv4.tcp_rmem = 4096 16384 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
fs.file-max = 262144
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_notsent_lowat = 16384
EOF
    else
        cat >> "$NAT_CONF_FILE" << 'EOF'
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 8192
fs.file-max = 262144
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_fastopen = 3
EOF
    fi
    sysctl --system >/dev/null 2>&1 || true; meta_set "SYSCTL_PROFILE" "nat-${profile}"
    msg_ok "✅ NAT(${profile}) Profile 已应用！"; sleep 2
}

apply_regular_profile() {
    local profile="$1"
    rm -f "$NAT_CONF_FILE" 2>/dev/null || true
    cat > "$CONF_FILE" << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
EOF
    if [[ "$profile" == "perf" ]]; then
        cat >> "$CONF_FILE" << 'EOF'
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 8192 262144 67108864
net.ipv4.tcp_wmem = 8192 262144 67108864
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
fs.file-max = 1048576
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_notsent_lowat = 16384
EOF
    else
        cat >> "$CONF_FILE" << 'EOF'
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 8192 262144 16777216
net.ipv4.tcp_wmem = 8192 262144 16777216
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 8192
fs.file-max = 524288
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_fastopen = 3
EOF
    fi
    sysctl --system >/dev/null 2>&1 || true; meta_set "SYSCTL_PROFILE" "regular-${profile}"
    msg_ok "✅ 常规(${profile}) Profile 已应用！"; sleep 2
}

opt_menu() {
    while true; do
        clear
        echo -e "${CYAN}========= 网络优化与清理中心 =========${RESET}"
        echo -e "${YELLOW} 1.${RESET} 常规机器：稳定优先 Profile"
        echo -e "${YELLOW} 2.${RESET} 常规机器：极致性能 Profile"
        echo -e "${GREEN} 3.${RESET} NAT 小鸡：稳定优先 Profile"
        echo -e "${GREEN} 4.${RESET} NAT 小鸡：极致性能 Profile"
        echo -e "${CYAN}--------------------------------------------${RESET}"
        echo -e "${YELLOW} 5.${RESET} 手动清理系统垃圾与冗余日志"
        echo -e "${YELLOW} 6.${RESET} DNS 管理中心（锁定/解锁/恢复）"
        echo -e " 0. 返回"
        read -rp "输入数字 [0-6]: " opt_num
        case "$opt_num" in
            1) apply_regular_profile "stable" ;;
            2) apply_regular_profile "perf" ;;
            3) apply_nat_profile "stable" ;;
            4) apply_nat_profile "perf" ;;
            5) auto_clean ;;
            6) dns_menu ;;
            0) return ;;
        esac
    done
}

run_daemon_check() {
    if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^ss-rust\.service'; then
        systemctl is-active --quiet ss-rust 2>/dev/null || systemctl restart ss-rust 2>/dev/null || true
    fi
    if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^xray\.service'; then
        systemctl is-active --quiet xray 2>/dev/null || systemctl restart xray 2>/dev/null || true
    fi
    while read -r svc; do
        [[ -z "$svc" ]] && continue
        systemctl is-active --quiet "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
    done < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep '^shadowtls-.*\.service$' || true)
}

auto_clean() {
    local is_silent=$1
    if have_cmd apt-get; then
        apt-get autoremove -yqq >/dev/null 2>&1 || true
        apt-get clean -qq >/dev/null 2>&1 || true
    fi
    rm -rf /root/.cache/* /tmp/*.tar.xz /tmp/shadow-tls /tmp/ssserver /tmp/my_update* /tmp/xray* /tmp/tmp.json 2>/dev/null || true
    [[ "$is_silent" != "silent" ]] && msg_ok "✅ 垃圾清理完毕！"
}

update_ss_rust_if_needed() {
    [[ -x "/usr/local/bin/ss-rust" ]] || return 1
    local arch; arch=$(uname -m); local ss_arch="x86_64-unknown-linux-gnu"
    [[ "$arch" == "aarch64" ]] && ss_arch="aarch64-unknown-linux-gnu"
    local latest; latest=$(github_latest_tag "shadowsocks/shadowsocks-rust")
    [[ -z "$latest" ]] && return 2
    local current; current=$(meta_get "SS_RUST_TAG" || true)
    if [[ -z "$current" ]]; then
        local v; v=$(/usr/local/bin/ss-rust --version 2>/dev/null | grep -oE '([0-9]+\.){2}[0-9]+' | head -n 1)
        [[ -n "$v" ]] && current="v${v}"
    fi
    [[ -n "$current" && "$current" == "$latest" ]] && return 3

    local tmpdir; tmpdir=$(mktemp -d /tmp/ssr-up-ssrust.XXXXXX)
    local tarball="${tmpdir}/ss-rust.tar.xz"
    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${latest}/shadowsocks-${latest}.${ss_arch}.tar.xz"
    if ! download_file "$url" "$tarball" || [[ ! -s "$tarball" ]] || ! tar -tf "$tarball" >/dev/null 2>&1; then rm -rf "$tmpdir"; return 2; fi
    tar -xf "$tarball" -C "$tmpdir" ssserver >/dev/null 2>&1 || true
    [[ -x "${tmpdir}/ssserver" ]] || { rm -rf "$tmpdir"; return 2; }
    if ! run_with_timeout 3 "${tmpdir}/ssserver" --version >/dev/null 2>&1; then
        run_with_timeout 3 "${tmpdir}/ssserver" -V >/dev/null 2>&1 || { rm -rf "$tmpdir"; return 2; }
    fi
    safe_install_binary "${tmpdir}/ssserver" /usr/local/bin/ss-rust || { rm -rf "$tmpdir"; return 2; }
    meta_set "SS_RUST_TAG" "$latest"; systemctl restart ss-rust 2>/dev/null || true
    rm -rf "$tmpdir"; return 0
}

update_xray_if_needed() {
    [[ -x "/usr/local/bin/xray" ]] || return 1
    local arch; arch=$(uname -m); local xray_arch="64"
    [[ "$arch" == "aarch64" ]] && xray_arch="arm64-v8a"
    local latest; latest=$(github_latest_tag "XTLS/Xray-core")
    [[ -z "$latest" ]] && return 2
    local current; current=$(meta_get "XRAY_TAG" || true)
    if [[ -z "$current" ]]; then
        local v; v=$(/usr/local/bin/xray version 2>/dev/null | head -n 1 | grep -oE '([0-9]+\.){2}[0-9]+' | head -n 1)
        [[ -n "$v" ]] && current="v${v}"
    fi
    [[ -n "$current" && "$current" == "$latest" ]] && return 3

    local tmpdir; tmpdir=$(mktemp -d /tmp/ssr-up-xray.XXXXXX)
    local zipf="${tmpdir}/xray.zip"
    local url="https://github.com/XTLS/Xray-core/releases/download/${latest}/Xray-linux-${xray_arch}.zip"
    if ! download_file "$url" "$zipf" || [[ ! -s "$zipf" ]] || ! unzip -t "$zipf" >/dev/null 2>&1; then rm -rf "$tmpdir"; return 2; fi
    unzip -qo "$zipf" xray -d "$tmpdir" >/dev/null 2>&1 || true
    [[ -x "${tmpdir}/xray" ]] || { rm -rf "$tmpdir"; return 2; }
    run_with_timeout 3 "${tmpdir}/xray" version >/dev/null 2>&1 || { rm -rf "$tmpdir"; return 2; }
    safe_install_binary "${tmpdir}/xray" /usr/local/bin/xray || { rm -rf "$tmpdir"; return 2; }
    meta_set "XRAY_TAG" "$latest"; systemctl restart xray 2>/dev/null || true
    rm -rf "$tmpdir"; return 0
}

update_shadowtls_if_needed() {
    [[ -x "/usr/local/bin/shadow-tls" ]] || return 1
    local arch; arch=$(uname -m); local st_arch="x86_64-unknown-linux-musl"
    [[ "$arch" == "aarch64" ]] && st_arch="aarch64-unknown-linux-musl"
    local latest; latest=$(github_latest_tag "ihciah/shadow-tls")
    [[ -z "$latest" ]] && return 2
    local current; current=$(meta_get "SHADOWTLS_TAG" || true)
    [[ -n "$current" && "$current" == "$latest" ]] && return 3

    local tmpdir; tmpdir=$(mktemp -d /tmp/ssr-up-stls.XXXXXX)
    local binf="${tmpdir}/shadow-tls"
    local url="https://github.com/ihciah/shadow-tls/releases/download/${latest}/shadow-tls-${st_arch}"
    if ! download_file "$url" "$binf" || [[ ! -s "$binf" ]]; then rm -rf "$tmpdir"; return 2; fi
    chmod +x "$binf" >/dev/null 2>&1 || true
    if ! run_with_timeout 3 "$binf" --version >/dev/null 2>&1; then
        run_with_timeout 3 "$binf" -V >/dev/null 2>&1 || run_with_timeout 3 "$binf" --help >/dev/null 2>&1 || { rm -rf "$tmpdir"; return 2; }
    fi
    safe_install_binary "$binf" /usr/local/bin/shadow-tls || { rm -rf "$tmpdir"; return 2; }
    meta_set "SHADOWTLS_TAG" "$latest"

    while read -r svc; do
        [[ -z "$svc" ]] && continue
        systemctl restart "$svc" 2>/dev/null || true
    done < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep '^shadowtls-.*\.service$' || true)
    rm -rf "$tmpdir"; return 0
}

hot_update_components() {
    local is_silent=$1; local updated_any=0
    update_ss_rust_if_needed; local r1=$?
    update_shadowtls_if_needed; local r2=$?
    update_xray_if_needed; local r3=$?
    [[ $r1 -eq 0 || $r2 -eq 0 || $r3 -eq 0 ]] && updated_any=1
    if [[ "$is_silent" != "silent" ]]; then
        if [[ $updated_any -eq 1 ]]; then msg_ok "✅ 核心组件已完成安全热更（仅更新到新版本）。"
        else msg_ok "✅ 核心组件已是最新或无需更新。"; fi
        sleep 2
    fi
}
# ==============================================================================
# 定时任务动态激活 (SSR 与 NFt 分离)
# ==============================================================================
add_ssr_cron() {
    local lock_prefix=""; have_cmd flock && lock_prefix="flock -n ${LOCK_FILE}"
    local crons; crons=$(crontab -l 2>/dev/null || true)
    if ! echo "$crons" | grep -q "${SCRIPT_FILE} --ssr-daily"; then
        (echo "$crons"; echo "0 3 * * * ${lock_prefix} ${SCRIPT_FILE} --ssr-daily > /dev/null 2>&1") | crontab - 2>/dev/null || true
        crons=$(crontab -l 2>/dev/null || true)
    fi
    if ! echo "$crons" | grep -q "${SCRIPT_FILE} --ssr-daemon"; then
        (echo "$crons"; echo "* * * * * ${lock_prefix} ${SCRIPT_FILE} --ssr-daemon > /dev/null 2>&1") | crontab - 2>/dev/null || true
    fi
    if [[ -f "$DDNS_CONF" ]] && ! crontab -l 2>/dev/null | grep -q "${SCRIPT_FILE} --ssr-ddns"; then
        (crontab -l 2>/dev/null || true; echo "*/5 * * * * ${lock_prefix} ${SCRIPT_FILE} --ssr-ddns > /dev/null 2>&1") | crontab - 2>/dev/null || true
    fi
}

# ==============================================================================
# NFt 转发模块 (端口转发、规则加载、DDNS 同步)
# ==============================================================================
ensure_ddns_cron_enabled() {
    if crontab -l 2>/dev/null | grep -Fq "${SCRIPT_FILE} --nft-cron"; then return 0; fi
    (crontab -l 2>/dev/null; echo "* * * * * ${SCRIPT_FILE} --nft-cron > /dev/null 2>&1") | crontab - 2>/dev/null || true
}

has_domain_rules() {
    while IFS='|' read -r lp addr tp last_ip proto; do
        [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
        [[ -z "$addr" ]] && continue
        if ! is_ipv4 "$addr"; then return 0; fi
    done < "$NFT_CONFIG_FILE"
    return 1
}

remove_ddns_cron_task() {
    local cur; cur="$(crontab -l 2>/dev/null || true)"
    [[ -z "$cur" ]] && return 0
    echo "$cur" | grep -v "${SCRIPT_FILE} --nft-cron" | crontab - 2>/dev/null || true
}

ensure_ddns_cron_disabled_if_unused() {
    if has_domain_rules; then return 0; fi
    if crontab -l 2>/dev/null | grep -Fq "${SCRIPT_FILE} --nft-cron"; then
        remove_ddns_cron_task
        msg_ok "已无域名转发规则：已自动移除 NFt DDNS 每分钟检测任务。"
    fi
}

sysctl_set_kv() {
    local key="$1"; local value="$2"
    mkdir -p /etc/sysctl.d 2>/dev/null || true
    touch "$NFT_SYSCTL_FILE" 2>/dev/null || true
    if grep -qE "^\s*${key}\s*=" "$NFT_SYSCTL_FILE" 2>/dev/null; then
        sed -i "s|^\s*${key}\s*=.*|${key} = ${value}|g" "$NFT_SYSCTL_FILE"
    else echo "${key} = ${value}" >> "$NFT_SYSCTL_FILE"; fi
}

ensure_forwarding() {
    local cur; cur="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
    if [[ "$cur" != "1" ]]; then
        sysctl_set_kv "net.ipv4.ip_forward" "1"
        sysctl --system >/dev/null 2>&1 || sysctl -p "$NFT_SYSCTL_FILE" >/dev/null 2>&1 || true
    fi
}

ensure_nft_mgr_service() {
    [[ -d "$NFT_MGR_DIR" ]] || mkdir -p "$NFT_MGR_DIR" 2>/dev/null || true
    [[ -f "$NFT_MGR_CONF" ]] || generate_empty_conf "$NFT_MGR_CONF"
    if ! have_cmd systemctl; then return 0; fi
    local nftbin; nftbin="$(command -v nft 2>/dev/null || echo /usr/sbin/nft)"
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

generate_empty_conf() {
    cat > "$1" << 'EOF'
table ip nft_mgr_nat {
    chain prerouting { type nat hook prerouting priority -100; policy accept; }
    chain postrouting { type nat hook postrouting priority 100; policy accept; }
}
EOF
    chmod 600 "$1" 2>/dev/null || true
}

generate_nft_conf() {
    local out="$1"; local any=0
    {
        echo "table ip nft_mgr_nat {"
        echo "    chain prerouting { type nat hook prerouting priority -100;"
        while IFS='|' read -r lp addr tp last_ip proto; do
            [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
            proto="$(normalize_proto "$proto")"; is_port "$lp" || continue; is_port "$tp" || continue; [[ -z "$addr" ]] && continue
            local ip="$last_ip"; [[ -z "$ip" ]] && ip="$(get_ip "$addr")"; is_ipv4 "$ip" || continue
            case "$proto" in
                tcp) echo "        tcp dport ${lp} counter dnat to ${ip}:${tp}"; any=1 ;;
                udp) echo "        udp dport ${lp} counter dnat to ${ip}:${tp}"; any=1 ;;
                both) echo "        tcp dport ${lp} counter dnat to ${ip}:${tp}"; echo "        udp dport ${lp} counter dnat to ${ip}:${tp}"; any=1 ;;
            esac
        done < "$NFT_CONFIG_FILE"
        echo "    }"
        echo "    chain postrouting { type nat hook postrouting priority 100;"
        while IFS='|' read -r lp addr tp last_ip proto; do
            [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
            proto="$(normalize_proto "$proto")"; is_port "$lp" || continue; is_port "$tp" || continue; [[ -z "$addr" ]] && continue
            local ip="$last_ip"; [[ -z "$ip" ]] && ip="$(get_ip "$addr")"; is_ipv4 "$ip" || continue
            case "$proto" in
                tcp) echo "        ip daddr ${ip} tcp dport ${tp} counter masquerade"; any=1 ;;
                udp) echo "        ip daddr ${ip} udp dport ${tp} counter masquerade"; any=1 ;;
                both) echo "        ip daddr ${ip} tcp dport ${tp} counter masquerade"; echo "        ip daddr ${ip} udp dport ${tp} counter masquerade"; any=1 ;;
            esac
        done < "$NFT_CONFIG_FILE"
        echo "    }"
        echo "}"
    } > "$out"
    chmod 600 "$out" 2>/dev/null || true
    [[ $any -eq 1 ]] || return 2
    return 0
}

apply_rules_impl() {
    ensure_forwarding; ensure_nft_mgr_service
    local tmp; tmp="$(mktemp /tmp/my_nftmgr.XXXXXX)"
    local has_rules=0
    if generate_nft_conf "$tmp"; then has_rules=1; else generate_empty_conf "$tmp"; has_rules=0; fi

    if ! have_cmd nft; then rm -f "$tmp"; return 1; fi
    if ! nft -c -f "$tmp" 2>/dev/null; then
        msg_err "❌ nft 规则语法校验失败：未写入持久化文件。"
        rm -f "$tmp"; return 1
    fi

    nft delete table ip nft_mgr_nat >/dev/null 2>&1 || true
    if ! nft -f "$tmp" 2>/dev/null; then
        msg_err "❌ nft 规则应用失败：未写入持久化文件。"
        rm -f "$tmp"; return 1
    fi

    mkdir -p "$NFT_MGR_DIR" 2>/dev/null || true
    mv -f "$tmp" "$NFT_MGR_CONF"
    chmod 600 "$NFT_MGR_CONF" 2>/dev/null || true

    if have_cmd systemctl; then systemctl enable nft-mgr >/dev/null 2>&1 || true; fi
    [[ $has_rules -eq 1 ]] && msg_ok "✅ 规则已原子化应用并持久化。" || msg_ok "✅ 当前无有效转发规则：已应用空表并持久化。"
    return 0
}

port_in_use() {
    local port="$1"; local proto="$2"; proto="$(normalize_proto "$proto")"; local used=1
    if have_cmd ss; then
        if [[ "$proto" == "tcp" || "$proto" == "both" ]]; then ss -lntH 2>/dev/null | awk '{print $4}' | awk -F: '{print $NF}' | grep -qx "$port" && used=0; fi
        if [[ "$proto" == "udp" || "$proto" == "both" ]]; then ss -lnuH 2>/dev/null | awk '{print $4}' | awk -F: '{print $NF}' | grep -qx "$port" && used=0; fi
    fi
    return $used
}

add_forward_impl() {
    local lport taddr tport proto tip
    read -rp "请输入本地监听端口 (1-65535): " lport
    is_port "$lport" || { msg_err "错误: 本地端口必须是 1-65535 的纯数字。"; sleep 2; return 1; }
    if grep -qE "^${lport}\|" "$NFT_CONFIG_FILE" 2>/dev/null; then
        msg_err "错误: 本地端口 $lport 已存在规则！请先删除旧规则。"; sleep 2; return 1
    fi

    echo -e "${CYAN}选择协议:${RESET}\n 1) TCP\n 2) UDP\n 3) TCP+UDP(默认)\n--------------------------------"
    read -rp "请选择 [1-3]: " psel
    case "$psel" in 1) proto="tcp" ;; 2) proto="udp" ;; *) proto="both" ;; esac

    if port_in_use "$lport" "$proto"; then
        msg_warn "⚠️ 检测到本机已有进程监听该端口。继续添加会导致外部访问被劫持。"
        read -rp "仍要继续？[y/N]: " go; [[ "$go" != "y" && "$go" != "Y" ]] && return 1
    fi

    read -rp "请输入目标地址 (IP 或 域名): " taddr
    [[ -z "$taddr" ]] && { msg_err "错误: 目标地址不能为空。"; sleep 2; return 1; }
    read -rp "请输入目标端口 (1-65535): " tport
    is_port "$tport" || { msg_err "错误: 目标端口必须是纯数字。"; sleep 2; return 1; }

    echo -e "${CYAN}正在解析并验证目标地址...${RESET}"
    tip="$(get_ip "$taddr")"
    [[ -z "$tip" ]] && { msg_err "错误: 解析失败，请检查域名或服务器网络。"; sleep 2; return 1; }

    local conf_bak; conf_bak="$(mktemp /tmp/my_nftmgr-conf.XXXXXX)"
    cp -a "$NFT_CONFIG_FILE" "$conf_bak" 2>/dev/null || true
    echo "${lport}|${taddr}|${tport}|${tip}|${proto}" >> "$NFT_CONFIG_FILE"

    if ! apply_rules_impl; then
        [[ -s "$conf_bak" ]] && mv -f "$conf_bak" "$NFT_CONFIG_FILE" || true
        msg_err "❌ 应用规则失败：已回滚本次新增配置。"; sleep 2; return 1
    fi
    rm -f "$conf_bak" 2>/dev/null || true
    manage_firewall "add" "$lport" "$proto" || true

    if ! is_ipv4 "$taddr"; then ensure_ddns_cron_enabled; msg_ok "已检测到目标为域名：已自动启用 DDNS 每分钟检测。"; fi
    msg_ok "添加成功！映射路径: [本机] ${lport}/${proto} -> [目标] ${taddr}:${tport} (${tip})"
    sleep 2; return 0
}

view_and_del_forward_impl() {
    clear
    if [[ ! -s "$NFT_CONFIG_FILE" ]]; then msg_warn "当前没有任何转发规则。"; read -rp "按回车返回..."; return 0; fi

    echo -e "${CYAN}=========================== 转发规则列表 ===========================${RESET}"
    printf "%-4s | %-6s | %-5s | %-16s | %-6s\n" "序号" "本地" "协议" "目标地址" "目标端口"
    echo "--------------------------------------------------------------------"
    local i=1
    while IFS='|' read -r lp addr tp last_ip proto; do
        [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
        proto="$(normalize_proto "$proto")"; is_port "$lp" || continue; is_port "$tp" || continue
        local short_addr="${addr:0:15}"
        printf "%-4s | %-6s | %-5s | %-16s | %-6s\n" "$i" "$lp" "$proto" "$short_addr" "$tp"
        ((i++))
    done < "$NFT_CONFIG_FILE"
    echo -e "${CYAN}====================================================================${RESET}"
    echo -e "\n${YELLOW}提示: 输入规则前面的【序号】即可删除，输入【0】或直接按回车返回。${RESET}"
    local action; read -rp "请选择操作: " action
    if [[ -z "$action" || "$action" == "0" ]]; then return 0; fi
    if ! [[ "$action" =~ ^[0-9]+$ ]]; then msg_err "输入无效。"; sleep 2; return 1; fi

    local line_no; line_no="$(awk -F'|' -v N="$action" 'BEGIN{c=0} $0!~/^\s*($|#)/{ if($1~/^[0-9]+$/ && $3~/^[0-9]+$/){ c++; if(c==N){print NR; exit} } }' "$NFT_CONFIG_FILE")"
    [[ -z "$line_no" ]] && { msg_err "删除失败：无法定位规则行。"; sleep 2; return 1; }

    local del_line del_port del_proto
    del_line="$(sed -n "${line_no}p" "$NFT_CONFIG_FILE")"
    del_port="$(echo "$del_line" | cut -d'|' -f1)"; del_proto="$(normalize_proto "$(echo "$del_line" | cut -d'|' -f5)")"

    local conf_bak; conf_bak="$(mktemp /tmp/my_nftmgr-conf.XXXXXX)"
    cp -a "$NFT_CONFIG_FILE" "$conf_bak" 2>/dev/null || true
    sed -i "${line_no}d" "$NFT_CONFIG_FILE"

    if ! apply_rules_impl; then
        [[ -s "$conf_bak" ]] && mv -f "$conf_bak" "$NFT_CONFIG_FILE" || true
        msg_err "❌ 应用规则失败：已回滚本次删除操作。"; sleep 2; return 1
    fi
    rm -f "$conf_bak" 2>/dev/null || true
    manage_firewall "del" "$del_port" "$del_proto" || true
    ensure_ddns_cron_disabled_if_unused

    msg_ok "已成功删除本地端口为 ${del_port}/${del_proto} 的转发规则。"
    sleep 2; return 0
}

clear_all_rules_impl() {
    if [[ ! -s "$NFT_CONFIG_FILE" ]]; then msg_warn "当前没有规则，无需清空。"; sleep 1; return 0; fi
    msg_warn "⚠️ 将清空所有转发规则（并移除 ufw/firewalld 放行）。"
    read -rp "确认清空？[y/N]: " confirm; [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return 0

    while IFS='|' read -r lp addr tp last_ip proto; do
        [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
        is_port "$lp" || continue; proto="$(normalize_proto "$proto")"
        manage_firewall "del" "$lp" "$proto" || true
    done < "$NFT_CONFIG_FILE"

    > "$NFT_CONFIG_FILE"
    apply_rules_impl || true
    ensure_ddns_cron_disabled_if_unused
    msg_ok "✅ 所有转发规则已清空。"; sleep 2
}

ddns_update_impl() {
    local changed=0; local temp_file; temp_file="$(mktemp /tmp/my_nftmgr-ddns.XXXXXX)"
    [[ -d "$NFT_LOG_DIR" ]] || mkdir -p "$NFT_LOG_DIR"
    local today_log="$NFT_LOG_DIR/$(date '+%Y-%m-%d').log"

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" || "${line:0:1}" == "#" ]]; then echo "$line" >> "$temp_file"; continue; fi
        local lp addr tp last_ip proto
        IFS='|' read -r lp addr tp last_ip proto <<< "$line"
        if ! is_port "$lp" || ! is_port "$tp" || [[ -z "$addr" ]]; then echo "$line" >> "$temp_file"; continue; fi

        local current_ip; current_ip="$(get_ip "$addr")"
        if [[ -z "$current_ip" ]] && ! is_ipv4 "$addr"; then
            echo "[$(date '+%H:%M:%S')] [ERROR] 端口 ${lp}: 域名 ${addr} 解析失败" >> "$today_log"
            echo "${lp}|${addr}|${tp}|${last_ip}|${proto}" >> "$temp_file"
            continue
        fi
        if [[ -n "$current_ip" && "$current_ip" != "$last_ip" ]]; then
            echo "${lp}|${addr}|${tp}|${current_ip}|${proto}" >> "$temp_file"
            changed=1
            echo "[$(date '+%H:%M:%S')] 端口 ${lp}: ${addr} 变动 (${last_ip:-N/A} -> ${current_ip})" >> "$today_log"
        else echo "${lp}|${addr}|${tp}|${last_ip}|${proto}" >> "$temp_file"; fi
    done < "$NFT_CONFIG_FILE"

    mv -f "$temp_file" "$NFT_CONFIG_FILE"
    if [[ $changed -eq 1 ]]; then apply_rules_impl >/dev/null 2>&1 || true; fi
    find "$NFT_LOG_DIR" -type f -name "*.log" -mtime +7 -exec rm -f {} \; 2>/dev/null || true
    return 0
}

manage_cron() {
    clear
    if crontab -l 2>/dev/null | grep -Fq "${SCRIPT_FILE} --nft-cron"; then echo -e "${GREEN}--- 管理定时监控 (DDNS 同步) --- [已启用]${RESET}"
    else echo -e "${GREEN}--- 管理定时监控 (DDNS 同步) --- [未启用]${RESET}"; fi
    echo "1. 手动添加定时任务 (每分钟检测)"
    echo "2. 一键删除定时任务"
    echo "3. 查看 DDNS 变动日志"
    echo "0. 返回"
    local cron_choice; read -rp "请选择操作 [0-3]: " cron_choice
    case "$cron_choice" in
        1) ensure_ddns_cron_enabled; msg_ok "定时任务已添加！"; sleep 2 ;;
        2) remove_ddns_cron_task; msg_warn "定时任务已清除。"; sleep 2 ;;
        3) clear; if ls "$NFT_LOG_DIR"/*.log >/dev/null 2>&1; then cat "$NFT_LOG_DIR"/*.log | tail -n 20; else msg_warn "暂无记录。"; fi; read -rp "按回车键返回..." ;;
        0) return ;;
        *) msg_err "无效选项"; sleep 1 ;;
    esac
}

# ==============================================================================
# 综合一键卸载中心与自动更新
# ==============================================================================
uninstall_ssr() {
    echo -e "${RED}⚠️ 正在无痕卸载 SSR 模块...${RESET}"
    if [[ -f "/etc/ss-rust/config.json" ]]; then
        local sp; sp=$(jq -r '.server_port' /etc/ss-rust/config.json 2>/dev/null)
        [[ -n "$sp" && "$sp" != "null" ]] && manage_firewall "del" "$sp" "both" >/dev/null 2>&1 || true
    fi
    if [[ -f "/usr/local/etc/xray/config.json" ]]; then
        local xp; xp=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json 2>/dev/null)
        [[ -n "$xp" && "$xp" != "null" ]] && manage_firewall "del" "$xp" "tcp" >/dev/null 2>&1 || true
    fi
    for s in /etc/systemd/system/shadowtls-*.service; do
        [[ -f "$s" ]] || continue
        manage_firewall "del" "$(basename "$s" | sed 's/shadowtls-//g' | sed 's/.service//g')" "tcp" >/dev/null 2>&1 || true
    done

    systemctl stop ss-rust xray 2>/dev/null || true
    systemctl disable ss-rust xray 2>/dev/null || true
    rm -rf /etc/ss-rust /usr/local/bin/ss-rust /etc/systemd/system/ss-rust.service
    rm -rf /usr/local/etc/xray /usr/local/bin/xray /etc/systemd/system/xray.service

    while read -r s; do
        [[ -z "$s" ]] && continue
        systemctl stop "$s" 2>/dev/null || true
        systemctl disable "$s" 2>/dev/null || true
        rm -f "/etc/systemd/system/$s"
    done < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep '^shadowtls-.*\.service$' || true)

    rm -f /usr/local/bin/shadow-tls "$CONF_FILE" "$NAT_CONF_FILE" "$DDNS_CONF" "$DDNS_LOG" "$META_FILE"
    crontab -l 2>/dev/null | grep -vE "${SCRIPT_FILE} --ssr-" | crontab - 2>/dev/null || true
    systemctl daemon-reload
    msg_ok "✅ SSR 模块卸载完成！"
}

uninstall_nft() {
    echo -e "${RED}⚠️ 正在清理 NFt 转发模块...${RESET}"
    while IFS='|' read -r lp addr tp last_ip proto; do
        [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
        is_port "$lp" || continue
        proto="$(normalize_proto "$proto")"
        manage_firewall "del" "$lp" "$proto" >/dev/null 2>&1 || true
    done < "$NFT_CONFIG_FILE" 2>/dev/null || true

    have_cmd nft && nft delete table ip nft_mgr_nat >/dev/null 2>&1 || true
    crontab -l 2>/dev/null | grep -v "${SCRIPT_FILE} --nft-cron" | crontab - 2>/dev/null || true

    if have_cmd systemctl; then
        systemctl disable --now nft-mgr >/dev/null 2>&1 || true
        rm -f "$NFT_MGR_SERVICE" 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    if [[ -f "$NFTABLES_CONF" ]]; then
        sed -i '/# nftmgr include/d' "$NFTABLES_CONF" 2>/dev/null || true
        sed -i '\|include "/etc/nftables.d/nft_mgr.conf"|d' "$NFTABLES_CONF" 2>/dev/null || true
    fi

    rm -f "$NFT_MGR_CONF" "$NFT_CONFIG_FILE" "$NFT_SETTINGS_FILE" "$NFT_SYSCTL_FILE" 2>/dev/null || true
    rm -rf "$NFT_LOG_DIR" "$NFT_MGR_DIR" 2>/dev/null || true
    msg_ok "✅ NFt 转发模块卸载完成！"
}

uninstall_all() {
    uninstall_ssr
    uninstall_nft
    echo -e "${RED}⚠️ 正在移除综合管理框架...${RESET}"
    crontab -l 2>/dev/null | grep -v "${SCRIPT_FILE}" | crontab - 2>/dev/null || true
    rm -f "$LOCK_FILE"
    rm -f "$SCRIPT_FILE" 2>/dev/null || true
    msg_ok "✅ 全部彻底卸载完成！系统已恢复初始状态。"
    exit 0
}

menu_uninstall() {
    while true; do
        clear
        echo -e "${RED}==================================${RESET}"
        echo -e "${RED}          一键卸载菜单          ${RESET}"
        echo -e "${RED}==================================${RESET}"
        echo -e "${YELLOW}  1. 一键卸载所有 (SSR + NFt)${RESET}"
        echo "  2. 仅一键卸载 SSR"
        echo "  3. 仅一键卸载 NFt"
        echo "  0. 返回主菜单"
        echo "=================================="
        read -p "请输入选项 [0-3]: " un_choice
        case "$un_choice" in
            1) 
                read -rp "警告: 此操作将删除所有配置和代理服务！确认？[y/N]: " confirm
                [[ "$confirm" == "y" || "$confirm" == "Y" ]] && uninstall_all 
                ;;
            2) 
                read -rp "确认卸载 SSR 模块？[y/N]: " confirm
                [[ "$confirm" == "y" || "$confirm" == "Y" ]] && { uninstall_ssr; read -p "按回车键返回..." ; return; }
                ;;
            3) 
                read -rp "确认卸载 NFt 转发模块？[y/N]: " confirm
                [[ "$confirm" == "y" || "$confirm" == "Y" ]] && { uninstall_nft; read -p "按回车键返回..." ; return; }
                ;;
            0) return ;;
            *) msg_err "输入错误"; sleep 1 ;;
        esac
    done
}

update_script() {
    clear
    echo -e "${GREEN}==================================${RESET}"
    echo -e "${GREEN}    综合管理脚本自适应更新        ${RESET}"
    echo -e "${GREEN}==================================${RESET}"
    echo -e "${CYAN}正在检测网络环境...${RESET}"
    
    local DOWNLOAD_URL
    if curl -s -m 3 https://google.com > /dev/null; then
        echo -e "检测为 ${YELLOW}海外网络${RESET}，使用 GitHub 直连拉取更新..."
        DOWNLOAD_URL="$SCRIPT_URL"
    else
        echo -e "检测为 ${YELLOW}国内网络${RESET}，使用 ghproxy 加速节点拉取更新..."
        DOWNLOAD_URL="https://ghproxy.net/${SCRIPT_URL}" 
    fi

    local tmpf; tmpf="$(mktemp /tmp/my_update.XXXXXX)"
    echo -e "${CYAN}正在从 $DOWNLOAD_URL 更新脚本...${RESET}"
    if ! download_file "$DOWNLOAD_URL" "$tmpf" || [[ ! -s "$tmpf" ]]; then
        msg_err "更新失败：无法下载脚本或文件为空，请检查网络。"
        rm -f "$tmpf"; sleep 3; return
    fi

    if ! head -n 1 "$tmpf" | grep -q "^#!/bin/bash"; then
        msg_err "更新失败：文件内容非法（缺少 shebang）。"
        rm -f "$tmpf"; sleep 3; return
    fi
    if ! bash -n "$tmpf" >/dev/null 2>&1; then
        msg_err "更新失败：新脚本语法校验失败，已阻止替换。"
        rm -f "$tmpf"; sleep 3; return
    fi
    if ! grep -q "$SCRIPT_FINGERPRINT_1" "$tmpf" || ! grep -q "$SCRIPT_FINGERPRINT_2" "$tmpf"; then
        msg_err "更新失败：特征码不匹配，防止误更新为其他脚本。"
        rm -f "$tmpf"; sleep 3; return
    fi
    
    cp -a "$SCRIPT_FILE" "${SCRIPT_FILE}.bak.$(date +%s)" 2>/dev/null || true
    mv -f "$tmpf" "$SCRIPT_FILE"
    chmod +x "$SCRIPT_FILE"
    
    msg_ok "✅ 综合管理脚本更新成功！"
    sleep 1; exec "$SCRIPT_FILE"
}

# ==============================================================================
# 多级菜单控制流
# ==============================================================================
menu_ssr() {
    add_ssr_cron
    while true; do
        clear
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}          SSR 节点生命周期管理模块          ${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${YELLOW} 1.${RESET} 原生部署 SS-Rust"
        echo -e "${YELLOW} 2.${RESET} 原生部署 VLESS Reality"
        echo -e "${YELLOW} 3.${RESET} 🛡️ 部署 ShadowTLS (保护传统协议)"
        echo -e "${CYAN}--------------------------------------------${RESET}"
        echo -e "${GREEN} 4.${RESET} 🔰 统一节点管控中心 (查看 / 删除 / 核爆)"
        echo -e "${CYAN}--------------------------------------------${RESET}"
        echo -e "${YELLOW} 5.${RESET} 网络优化与系统清理 (Profiles + DNS)"
        echo -e "${YELLOW} 6.${RESET} 基础系统与安全管控 (DDNS / 时间 / SSH)"
        echo -e "${YELLOW} 7.${RESET} 手动安全热更 SSR 核心组件"
        echo -e "${CYAN}============================================${RESET}"
        echo -e " 0. 返回综合管理主菜单"
        read -rp "请输入对应数字 [0-7]: " num
        case "$num" in
            1) install_ss_rust_native ;;
            2) install_vless_native ;;
            3) install_shadowtls_native ;;
            4) unified_node_manager ;;
            5) opt_menu ;;
            6) 
                while true; do
                    clear
                    echo -e "${CYAN}========= 系统与极客管理 =========${RESET}"
                    echo -e " 1. 一键修改 SSH 安全端口\n 2. 一键修改 Root 密码\n 3. 服务器时间防偏移同步\n 4. SSH 密钥登录管理中心\n 5. 原生 Cloudflare DDNS 解析模块\n 0. 返回"
                    read -rp "输入 [0-5]: " sn
                    case "$sn" in
                        1) change_ssh_port ;; 2) change_root_password ;; 3) sync_server_time ;; 4) ssh_key_menu ;; 5) cf_ddns_menu ;; 0) break ;;
                    esac
                done
                ;;
            7) hot_update_components ;;
            0) return ;;
            *) msg_err "请输入正确的选项！"; sleep 1 ;;
        esac
    done
}

menu_nft() {
    # 暂时不强制开启 cron，让用户手动添加规则时联动激活
    while true; do
        clear
        echo -e "${GREEN}==========================================${RESET}"
        echo -e "${GREEN}     nftables 端口转发管理面板 (Pro)      ${RESET}"
        echo -e "${GREEN}==========================================${RESET}"
        echo "1. 新增端口转发 (支持域名/IP，支持TCP/UDP)"
        echo "2. 转发规则管理 (查看/删除)"
        echo "3. 清空所有转发规则"
        echo "4. 管理 DDNS 定时监控与日志"
        echo "0. 返回综合管理主菜单"
        echo "------------------------------------------"
        local choice; read -rp "请选择操作 [0-4]: " choice
        case "$choice" in
            1) with_lock add_forward_impl ;;
            2) with_lock view_and_del_forward_impl ;;
            3) with_lock clear_all_rules_impl ;;
            4) manage_cron ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

menu_main() {
    clear
    echo -e "${CYAN}==========================================${RESET}"
    echo -e "${CYAN}       综合网络管理脚本 (SSR+NFt)         ${RESET}"
    echo -e "${CYAN}            v${SCRIPT_VERSION}            ${RESET}"
    echo -e "${CYAN}==========================================${RESET}"
    echo -e "${GREEN}  1.${RESET} 🚀 进入 SSR 节点与内核优化模块"
    echo -e "${GREEN}  2.${RESET} 🔄 进入 NFt 端口转发模块"
    echo -e "${CYAN}------------------------------------------${RESET}"
    echo -e "${YELLOW}  3.${RESET} 🗑️ 综合脚本一键卸载中心 (多级卸载)"
    echo -e "${YELLOW}  4.${RESET} 🌍 综合脚本自适应安全更新 (国内/海外)"
    echo -e "  0. 退出管理脚本"
    echo -e "${CYAN}==========================================${RESET}"
    read -p "请输入选项 [0-4]: " choice
    case "$choice" in
        1) menu_ssr ;;
        2) menu_nft ;;
        3) menu_uninstall ;;
        4) update_script ;;
        0) echo -e "${GREEN}感谢使用，再见！${RESET}"; exit 0 ;;
        *) msg_err "输入错误，请重新输入"; sleep 1 ;;
    esac
}

# ==============================================================================
# CLI 后台执行入口 (用于接收 Crontab 调度)
# ==============================================================================
cli_router() {
    case "$1" in
        --ssr-daily)  hot_update_components "silent"; auto_clean "silent" ;;
        --ssr-daemon) run_daemon_check ;;
        --ssr-ddns)   run_cf_ddns "auto" ;;
        --nft-cron)   with_lock ddns_update_impl ;;
        *) msg_err "未知或无效的内部指令"; exit 1 ;;
    esac
    exit 0
}

# ==============================================================================
# 执行初始化并启动
# ==============================================================================
init_env

if [[ -n "${1:-}" ]]; then
    cli_router "$1"
else
    init_cron_base
    while true; do
        menu_main
    done
fi
