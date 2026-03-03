#!/bin/bash
# ==============================================================================
# 脚本名称: SSR 综合管理脚本 (稳定优先 + 极致性能 Profiles)
# 核心特性:
#   - 节点部署: SS-Rust / VLESS Reality (Xray) / ShadowTLS
#   - 双档位网络调优: NAT / 常规机器 => 稳定优先 / 极致性能
#   - Cloudflare DDNS: 原生 API + 定时守护
#   - 自动任务互斥: cron 使用 flock 防并发踩踏
#   - 安全热更: 仅在有新版本时更新；下载到临时目录校验可运行后再原子替换
#   - DNS 管理: 检测 /etc/resolv.conf 是否 symlink；提供一键解锁/恢复
#
# 全局命令:
#   ssr [bbr|nat] [stable|perf]
#   ssr clean | update | hot_upgrade | daily_task | daemon_check
#   ssr ddns | rmddns | nuke <service>
#   ssr dns [status|set|lock|unlock]
# ==============================================================================

set -o pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly RESET='\033[0m'

readonly SCRIPT_VERSION="21.0-Stable-Perf-Profiles"

# Sysctl profile files (互斥写入)
readonly CONF_FILE="/etc/sysctl.d/99-ssr-net.conf"
readonly NAT_CONF_FILE="/etc/sysctl.d/99-ssr-nat.conf"

# CF DDNS
readonly DDNS_CONF="/usr/local/etc/ssr_ddns.conf"
readonly DDNS_LOG="/var/log/ssr_ddns.log"

# Cron / Task Lock (7.3)
readonly LOCK_FILE="/var/lock/ssr.lock"

# Meta (用于判断是否有新版本)
readonly META_DIR="/usr/local/etc/ssr_meta"
readonly META_FILE="${META_DIR}/versions.conf"

# DNS backup & systemd-resolved drop-in (2.1)
readonly DNS_BACKUP_DIR="/usr/local/etc/ssr_dns_backup"
readonly DNS_META="${DNS_BACKUP_DIR}/meta.conf"
readonly DNS_FILE_BAK="${DNS_BACKUP_DIR}/resolv.conf.bak"
readonly RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/ssr-dns.conf"

trap 'echo -e "\n${GREEN}已安全退出脚本。${RESET}"; exit 0' SIGINT

# ==============================================================================
# 通用工具
# ==============================================================================
have_cmd() { command -v "$1" >/dev/null 2>&1; }

base64_nw() {
    # 输出不换行的 base64
    if base64 --help 2>&1 | grep -q -- '-w'; then
        base64 -w 0
    else
        base64 | tr -d '\n'
    fi
}

run_with_timeout() {
    local seconds="$1"; shift
    if have_cmd timeout; then
        timeout "${seconds}" "$@"
    else
        "$@"
    fi
}

meta_get() {
    local key="$1"
    [[ -f "$META_FILE" ]] || return 1
    grep -E "^${key}=" "$META_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- | sed 's/^"//; s/"$//'
}

meta_set() {
    local key="$1"; local value="$2"
    mkdir -p "$META_DIR"
    touch "$META_FILE"
    chmod 600 "$META_FILE" 2>/dev/null || true
    if grep -qE "^${key}=" "$META_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|g" "$META_FILE"
    else
        echo "${key}=\"${value}\"" >> "$META_FILE"
    fi
}

download_file() {
    # download_file URL DEST
    local url="$1"; local dest="$2"
    rm -f "$dest"
    if have_cmd curl; then
        curl -fsSL --retry 3 --connect-timeout 8 --max-time 120 "$url" -o "$dest" >/dev/null 2>&1
    else
        wget -qO "$dest" "$url" >/dev/null 2>&1
    fi
}

github_latest_tag() {
    # github_latest_tag "owner/repo"
    local repo="$1"
    local tag=""
    if have_cmd curl && have_cmd jq; then
        tag=$(curl -fsSL --max-time 10 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | jq -r '.tag_name' 2>/dev/null)
    fi
    [[ -n "$tag" && "$tag" != "null" ]] && echo "$tag"
}

safe_install_binary() {
    # safe_install_binary NEW_BIN DEST_BIN
    local newbin="$1"; local dest="$2"
    local ts; ts=$(date +%s)
    local backup="${dest}.bak.${ts}"

    [[ -s "$newbin" ]] || return 1

    if [[ -f "$dest" ]]; then
        cp -a "$dest" "$backup" 2>/dev/null || true
    fi

    # 原子替换：同目录 mv
    install -m 755 "$newbin" "${dest}.new" >/dev/null 2>&1 || { rm -f "${dest}.new"; return 1; }
    mv -f "${dest}.new" "$dest" >/dev/null 2>&1 || { rm -f "${dest}.new"; return 1; }
    return 0
}

# ==============================================================================
# 环境检查与全局命令安装
# ==============================================================================
check_env() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行！${RESET}" && exit 1

    # 依赖：尽量保守安装；缺啥装啥
    local deps=(curl jq bc wget tar openssl unzip)
    local missing=()
    for dep in "${deps[@]}"; do
        have_cmd "$dep" || missing+=("$dep")
    done

    if ((${#missing[@]} > 0)); then
        if have_cmd apt-get; then
            apt-get update -qq
            # xz-utils: 解 tar.xz；util-linux: flock；e2fsprogs: chattr/lsattr
            apt-get install -yqq curl jq bc wget tar xz-utils openssl unzip util-linux e2fsprogs >/dev/null 2>&1 || true
        elif have_cmd yum; then
            yum install -yq curl jq bc wget tar xz openssl unzip util-linux e2fsprogs >/dev/null 2>&1 || true
        fi
    fi
}

install_global_command() {
    # 将当前脚本复制到 /usr/local/bin/ssr
    if [[ "$(readlink -f "$0")" != "/usr/local/bin/ssr" ]]; then
        cp -f "$0" /usr/local/bin/ssr
        chmod +x /usr/local/bin/ssr
    fi

    # 7.3: 任务互斥锁（cron 入口统一 flock）
    local lock_prefix=""
    if have_cmd flock; then
        lock_prefix="flock -n ${LOCK_FILE}"
    fi

    # 清理旧任务（避免重复/历史格式）
    crontab -l 2>/dev/null | grep -vE "/usr/local/bin/ssr (auto_update|auto_task|daemon_check|hot_upgrade|clean|daily_task|ddns)" | crontab - 2>/dev/null || true

    # 每天 03:00 例行：检查更新（仅新版本才更）+ 清理
    (crontab -l 2>/dev/null; echo "0 3 * * * ${lock_prefix} /usr/local/bin/ssr daily_task > /dev/null 2>&1") | crontab - 2>/dev/null || true

    # 每分钟守护：仅补刀 systemd 未能拉起的情况（避免并发踩踏）
    (crontab -l 2>/dev/null; echo "* * * * * ${lock_prefix} /usr/local/bin/ssr daemon_check > /dev/null 2>&1") | crontab - 2>/dev/null || true

    # DDNS：仅在配置存在时启用
    if [[ -f "$DDNS_CONF" ]]; then
        (crontab -l 2>/dev/null; echo "*/5 * * * * ${lock_prefix} /usr/local/bin/ssr ddns > /dev/null 2>&1") | crontab - 2>/dev/null || true
    fi

    meta_set "SCRIPT_VERSION" "$SCRIPT_VERSION"
}

# ==============================================================================
# 防火墙/服务清理
# ==============================================================================
remove_firewall_rule() {
    local port=$1; local proto=$2
    if have_cmd ufw; then
        [[ "$proto" == "both" || "$proto" == "tcp" ]] && ufw delete allow "$port"/tcp >/dev/null 2>&1
        [[ "$proto" == "both" || "$proto" == "udp" ]] && ufw delete allow "$port"/udp >/dev/null 2>&1
    fi
    if have_cmd firewall-cmd; then
        [[ "$proto" == "both" || "$proto" == "tcp" ]] && firewall-cmd --remove-port="$port"/tcp --permanent >/dev/null 2>&1
        [[ "$proto" == "both" || "$proto" == "udp" ]] && firewall-cmd --remove-port="$port"/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
}

force_kill_service() {
    local target=$1; local from_menu=$2
    if [[ -z "$target" ]]; then
        echo -e "${RED}❌ 目标服务名为空！${RESET}"
        [[ "$from_menu" == "menu" ]] && { sleep 2; return; } || exit 1
    fi
    echo -e "${RED}☢️ 正在执行系统级物理粉碎: ${target} ...${RESET}"
    systemctl stop "$target" 2>/dev/null
    systemctl disable "$target" 2>/dev/null
    rm -f "/etc/systemd/system/${target}.service" "/etc/systemd/system/${target}"
    systemctl daemon-reload
    echo -e "${GREEN}✅ 目标服务 [${target}] 已彻底蒸发！${RESET}"
    [[ "$from_menu" == "menu" ]] && sleep 2 || exit 0
}

# ==============================================================================
# DNS 管理 (2.1): symlink 检测 + 一键解锁/恢复
# ==============================================================================
dns_backup() {
    mkdir -p "$DNS_BACKUP_DIR"
    local is_symlink=0
    local target=""
    if [[ -L /etc/resolv.conf ]]; then
        is_symlink=1
        target="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
    else
        cp -a /etc/resolv.conf "$DNS_FILE_BAK" 2>/dev/null || true
    fi

    local immutable=0
    if have_cmd lsattr; then
        if lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
            immutable=1
        fi
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
    local lock_mode="$1"  # "lock" or "set"
    # 解除不可变
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
    # 使用 systemd-resolved 时，不建议对 resolv.conf 做 chattr（常为 symlink）
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
    # dns_set_or_lock set|lock
    local mode="$1"
    dns_backup

    if [[ -L /etc/resolv.conf ]]; then
        # symlink：优先走 systemd-resolved（若可用），否则不强行破坏 symlink
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            dns_apply_systemd_resolved
        else
            echo -e "${YELLOW}⚠️ 检测到 /etc/resolv.conf 为 symlink，但 systemd-resolved 未运行，已跳过强制写入以避免破坏系统 DNS 机制。${RESET}"
            return 1
        fi
    else
        dns_apply_resolvconf "$mode"
    fi
    return 0
}

dns_unlock_restore() {
    # 一键解锁 + 恢复备份（若存在）
    if have_cmd chattr; then chattr -i /etc/resolv.conf 2>/dev/null || true; fi

    # 先移除 resolved drop-in
    if [[ -f "$RESOLVED_DROPIN" ]]; then
        rm -f "$RESOLVED_DROPIN"
        systemctl restart systemd-resolved 2>/dev/null || true
    fi

    if [[ -f "$DNS_META" ]]; then
        # shellcheck disable=SC1090
        source "$DNS_META" 2>/dev/null || true

        if [[ "${IS_SYMLINK:-0}" == "1" ]]; then
            if [[ -n "${SYMLINK_TARGET:-}" ]]; then
                rm -f /etc/resolv.conf
                ln -sf "${SYMLINK_TARGET}" /etc/resolv.conf
            fi
        else
            if [[ -f "$DNS_FILE_BAK" ]]; then
                cp -a "$DNS_FILE_BAK" /etc/resolv.conf 2>/dev/null || true
            fi
        fi

        # 是否恢复不可变属性
        if [[ "${WAS_IMMUTABLE:-0}" == "1" ]] && have_cmd chattr; then
            chattr +i /etc/resolv.conf 2>/dev/null || true
        fi
    fi
}

dns_status() {
    echo -e "${CYAN}========= DNS 状态 =========${RESET}"
    if [[ -L /etc/resolv.conf ]]; then
        echo -e "resolv.conf: ${YELLOW}symlink${RESET} -> $(readlink -f /etc/resolv.conf 2>/dev/null || echo "unknown")"
    else
        echo -e "resolv.conf: ${GREEN}regular file${RESET}"
    fi

    if have_cmd lsattr; then
        local attr; attr=$(lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}')
        if echo "$attr" | grep -q 'i'; then
            echo -e "immutable: ${YELLOW}ON${RESET}"
        else
            echo -e "immutable: ${GREEN}OFF${RESET}"
        fi
    fi

    if [[ -f "$RESOLVED_DROPIN" ]]; then
        echo -e "systemd-resolved drop-in: ${YELLOW}enabled${RESET} (${RESOLVED_DROPIN})"
    else
        echo -e "systemd-resolved drop-in: ${GREEN}disabled${RESET}"
    fi

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
            2) dns_set_or_lock "set"; echo -e "${GREEN}✅ DNS 已设置。${RESET}"; sleep 2 ;;
            3) dns_set_or_lock "lock"; echo -e "${GREEN}✅ DNS 已锁定/固定。${RESET}"; sleep 2 ;;
            4) dns_unlock_restore; echo -e "${GREEN}✅ 已解锁并恢复。${RESET}"; sleep 2 ;;
            0) return ;;
        esac
    done
}

# ==============================================================================
# Cloudflare DDNS (7.5: 隐藏 token + 权限收紧)
# ==============================================================================
setup_cf_ddns() {
    clear
    echo -e "${CYAN}========= 🌐 原生 Cloudflare DDNS 配置 =========${RESET}"
    echo -e "${YELLOW}前提：域名已托管到 Cloudflare，并准备好 API Token（需 Zone.DNS 读写权限）。${RESET}\n"

    read -rsp "1. 请输入 Cloudflare API Token: " cf_token
    echo ""
    [[ -z "$cf_token" ]] && return

    read -rp "2. 请输入根域名 (例如: example.com): " cf_zone
    [[ -z "$cf_zone" ]] && return

    read -rp "3. 请输入要绑定的子域名 (例如: ddns.example.com): " cf_record
    [[ -z "$cf_record" ]] && return

    echo -e "${CYAN}>>> 正在验证 Token 并获取 Zone ID...${RESET}"
    local zone_response zone_id
    zone_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$cf_zone" \
        -H "Authorization: Bearer $cf_token" -H "Content-Type: application/json")
    zone_id=$(echo "$zone_response" | jq -r '.result[0].id')

    if [[ -z "$zone_id" || "$zone_id" == "null" ]]; then
        echo -e "${RED}❌ 验证失败！请检查 Token 或根域名。${RESET}"
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

    # 7.3: cron 写入时使用 flock；这里调用 install_global_command 会自动补齐 ddns cron
    install_global_command

    echo -e "${GREEN}✅ DDNS 配置保存成功！${RESET}\n${CYAN}>>> 正在进行首次推送...${RESET}"
    run_cf_ddns "manual"
    sleep 2
}

run_cf_ddns() {
    local mode=$1
    if [[ ! -f "$DDNS_CONF" ]]; then
        [[ "$mode" == "manual" ]] && echo -e "${RED}❌ DDNS 未配置。${RESET}"
        return
    fi

    # shellcheck disable=SC1090
    source "$DDNS_CONF"

    local current_ip
    current_ip=$(curl -s4m8 https://api.ipify.org 2>/dev/null || curl -s4m8 ifconfig.me 2>/dev/null || true)

    if [[ -z "$current_ip" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [错误] 无法获取公网 IP" >> "$DDNS_LOG"
        return
    fi

    if [[ "$current_ip" == "$LAST_IP" && "$mode" != "manual" ]]; then
        return
    fi

    [[ "$mode" == "manual" ]] && echo -e "${YELLOW}获取到当前 IP: $current_ip ，正在通信...${RESET}"

    local record_response record_id api_result success
    record_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?name=${CF_RECORD}&type=A" \
        -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json")
    record_id=$(echo "$record_response" | jq -r '.result[0].id' 2>/dev/null)

    if [[ -z "$record_id" || "$record_id" == "null" ]]; then
        api_result=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
            -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"${CF_RECORD}\",\"content\":\"${current_ip}\",\"ttl\":60,\"proxied\":false}")
    else
        api_result=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}" \
            -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"${CF_RECORD}\",\"content\":\"${current_ip}\",\"ttl\":60,\"proxied\":false}")
    fi

    success=$(echo "$api_result" | jq -r '.success' 2>/dev/null)
    if [[ "$success" == "true" ]]; then
        sed -i "s/^LAST_IP=.*/LAST_IP=\"${current_ip}\"/g" "$DDNS_CONF"
        chmod 600 "$DDNS_CONF" 2>/dev/null || true
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [成功] IP 更新为: $current_ip" >> "$DDNS_LOG"
        [[ "$mode" == "manual" ]] && echo -e "${GREEN}✅ 解析已更新为: $current_ip${RESET}"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [失败] API响应: $api_result" >> "$DDNS_LOG"
        [[ "$mode" == "manual" ]] && echo -e "${RED}❌ 更新失败！${RESET}"
    fi
}

remove_cf_ddns() {
    local cli_mode=$1
    if [[ ! -f "$DDNS_CONF" ]]; then
        echo -e "${RED}❌ DDNS 未配置。${RESET}"
        [[ "$cli_mode" != "force" ]] && sleep 2
        return
    fi

    # shellcheck disable=SC1090
    source "$DDNS_CONF"

    if [[ "$cli_mode" != "force" ]]; then
        echo -e "${RED}⚠️ 警告：这将删除本地配置并尝试粉碎 Cloudflare 云端记录 [${CF_RECORD}]！${RESET}"
        read -rp "确定要执行吗？(y/N): " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    fi

    echo -e "${CYAN}>>> 正在销毁云端解析记录...${RESET}"
    local record_response record_id
    record_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?name=${CF_RECORD}&type=A" \
        -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json")

    # 6.3 修复：2>/dev/null 必须在 jq 外
    record_id=$(echo "$record_response" | jq -r '.result[0].id' 2>/dev/null)

    if [[ -n "$record_id" && "$record_id" != "null" ]]; then
        curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}" \
            -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" > /dev/null 2>&1 || true
        echo -e "${GREEN}✅ 云端记录已删除（若 API 权限允许）。${RESET}"
    fi

    rm -f "$DDNS_CONF" "$DDNS_LOG"
    crontab -l 2>/dev/null | grep -v "/usr/local/bin/ssr ddns" | crontab - 2>/dev/null || true

    echo -e "${GREEN}✅ 本地 DDNS 任务已撤销。${RESET}"
    [[ "$cli_mode" != "force" ]] && sleep 2
}

cf_ddns_menu() {
    while true; do
        clear
        echo -e "${CYAN}========= 🌐 动态域名解析 (Cloudflare DDNS) =========${RESET}"
        if [[ -f "$DDNS_CONF" ]]; then
            # shellcheck disable=SC1090
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
# 基础系统管理（7.5: 密码输入隐藏）
# ==============================================================================
change_ssh_port() {
    read -rp "新的 SSH 端口号 (1-65535): " new_port
    if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
        if have_cmd ufw && ufw status | grep -qw "active"; then ufw allow "$new_port"/tcp >/dev/null 2>&1; fi
        if have_cmd firewall-cmd; then firewall-cmd --add-port="$new_port"/tcp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi
        sed -i "s/^#\?Port [0-9]*/Port $new_port/g" /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
        echo -e "${GREEN}✅ SSH 端口已修改为 $new_port 。${RESET}"
    else
        echo -e "${RED}❌ 端口无效。${RESET}"
    fi
    sleep 2
}

change_root_password() {
    read -rsp "新的 root 密码: " new_pass
    echo ""
    [[ -z "$new_pass" ]] && return
    read -rsp "再次输入确认: " new_pass_confirm
    echo ""
    [[ "$new_pass" != "$new_pass_confirm" ]] && echo -e "${RED}两次密码不一致！${RESET}" && sleep 2 && return
    echo "root:$new_pass" | chpasswd && echo -e "${GREEN}✅ 密码修改成功！${RESET}"
    sleep 2
}

sync_server_time() {
    echo -e "${CYAN}>>> 正在同步时间...${RESET}"
    if have_cmd apt-get; then
        apt-get update -qq
        apt-get install -yqq systemd-timesyncd >/dev/null 2>&1 || true
        systemctl enable --now systemd-timesyncd 2>/dev/null || true
    elif have_cmd yum; then
        yum install -yq chrony >/dev/null 2>&1 || true
        systemctl enable --now chronyd 2>/dev/null || true
    fi
    echo -e "${GREEN}✅ 同步服务已启动（若系统支持）。${RESET}"
    sleep 2
}

apply_ssh_key_sec() {
    sed -i 's/^#\?PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
    sed -i 's/^#\?PasswordAuthentication no/PasswordAuthentication no/g' /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
    echo -e "${GREEN}✅ 密码登录已封锁。${RESET}"
    sleep 2
}

ssh_key_menu() {
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
                local keys
                keys=$(curl -s "https://github.com/${gh_user}.keys" 2>/dev/null || true)
                [[ -n "$keys" && "$keys" != "Not Found" ]] && {
                    echo "$keys" >> ~/.ssh/authorized_keys
                    chmod 600 ~/.ssh/authorized_keys
                    echo -e "${GREEN}✅ 拉取成功！${RESET}"
                    apply_ssh_key_sec
                } || { echo -e "${RED}❌ 未找到公钥。${RESET}"; sleep 2; }
            }
            ;;
        2)
            read -rp "粘贴公钥: " manual_key
            [[ -n "$manual_key" ]] && {
                mkdir -p ~/.ssh && chmod 700 ~/.ssh
                echo "$manual_key" >> ~/.ssh/authorized_keys
                chmod 600 ~/.ssh/authorized_keys
                echo -e "${GREEN}✅ 成功！${RESET}"
                apply_ssh_key_sec
            }
            ;;
        3)
            mkdir -p ~/.ssh && chmod 700 ~/.ssh
            rm -f ~/.ssh/id_ed25519*
            ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -q
            cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
            chmod 600 ~/.ssh/authorized_keys
            echo -e "${RED}⚠️ 请保存以下私钥（只显示一次）！⚠️${RESET}\n"
            cat ~/.ssh/id_ed25519
            echo -e "\n${YELLOW}========================${RESET}"
            read -rp "关闭密码登录 (y/N): " confirm
            [[ "$confirm" == "y" || "$confirm" == "Y" ]] && apply_ssh_key_sec
            ;;
        4)
            sed -i 's/^#\?PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config
            systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
            echo -e "${GREEN}✅ 已恢复密码登录。${RESET}"
            sleep 2
            ;;
        0) return ;;
    esac
}

# ==============================================================================
# 节点原生部署模块（6.1: unit 修复；2.3: 临时下载校验 + 原子替换）
# ==============================================================================
install_ss_rust_native() {
    clear
    echo -e "${CYAN}========= 原生交互安装 SS-Rust =========${RESET}"
    rm -f /etc/systemd/system/ss-rust.service

    read -rp "自定义端口 (1-65535) [留空随机]: " custom_port
    local port=$custom_port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        port=$((RANDOM % 55535 + 10000))
    fi

    echo -e "\n${CYAN}加密协议:${RESET}"
    echo -e " 1) 2022-blake3-aes-128-gcm"
    echo -e " 2) 2022-blake3-aes-256-gcm"
    echo -e " 3) 2022-blake3-chacha20-poly1305"
    echo -e " 4) aes-256-gcm"
    read -rp "选择 [1-4] (默认1): " method_choice

    local method="2022-blake3-aes-128-gcm"
    local pwd_len=16
    case "$method_choice" in
        2) method="2022-blake3-aes-256-gcm"; pwd_len=32 ;;
        3) method="2022-blake3-chacha20-poly1305"; pwd_len=32 ;;
        4) method="aes-256-gcm"; pwd_len=0 ;;
    esac

    local pwd=""
    if [[ "$pwd_len" -ne 0 ]]; then
        read -rp "密码 (留空生成 Base64): " input_pwd
        if [[ -z "$input_pwd" ]]; then
            pwd=$(openssl rand -base64 "$pwd_len" 2>/dev/null | tr -d '\n')
        else
            pwd=$(echo -n "$input_pwd" | base64_nw)
        fi
    else
        read -rp "传统密码 (留空随机): " input_pwd
        if [[ -z "$input_pwd" ]]; then
            pwd=$(openssl rand -hex 12 2>/dev/null)
        else
            pwd="$input_pwd"
        fi
    fi

    local arch; arch=$(uname -m)
    local ss_arch="x86_64-unknown-linux-gnu"
    [[ "$arch" == "aarch64" ]] && ss_arch="aarch64-unknown-linux-gnu"

    echo -e "${CYAN}>>> 正在获取 SS-Rust 最新版本信息...${RESET}"
    local ss_latest
    ss_latest=$(github_latest_tag "shadowsocks/shadowsocks-rust")
    [[ -z "$ss_latest" ]] && ss_latest="v1.22.0"

    local tmpdir; tmpdir=$(mktemp -d /tmp/ssr-ssrust.XXXXXX)
    local tarball="${tmpdir}/ss-rust.tar.xz"
    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${ss_latest}/shadowsocks-${ss_latest}.${ss_arch}.tar.xz"

    echo -e "${CYAN}>>> 下载核心: ${ss_latest} (${ss_arch}) ...${RESET}"
    if ! download_file "$url" "$tarball" || [[ ! -s "$tarball" ]] || ! tar -tf "$tarball" >/dev/null 2>&1; then
        echo -e "${RED}❌ 核心下载或校验失败，请重试。${RESET}"
        rm -rf "$tmpdir"
        sleep 3
        return
    fi

    tar -xf "$tarball" -C "$tmpdir" ssserver >/dev/null 2>&1 || true
    if [[ ! -x "${tmpdir}/ssserver" ]]; then
        echo -e "${RED}❌ 解压失败：未找到 ssserver。${RESET}"
        rm -rf "$tmpdir"
        sleep 3
        return
    fi

    # 可运行校验
    if ! run_with_timeout 3 "${tmpdir}/ssserver" --version >/dev/null 2>&1; then
        # 尝试 -V
        run_with_timeout 3 "${tmpdir}/ssserver" -V >/dev/null 2>&1 || {
            echo -e "${RED}❌ 新核心自检失败（无法运行）。已中止替换。${RESET}"
            rm -rf "$tmpdir"
            sleep 3
            return
        }
    fi

    safe_install_binary "${tmpdir}/ssserver" /usr/local/bin/ss-rust || {
        echo -e "${RED}❌ 安装失败（写入 /usr/local/bin/ss-rust 失败）。${RESET}"
        rm -rf "$tmpdir"
        sleep 3
        return
    }

    mkdir -p /etc/ss-rust
    cat > /etc/ss-rust/config.json << EOF
{ "server": "::", "server_port": $port, "password": "$pwd", "method": "$method", "mode": "tcp_and_udp", "fast_open": true }
EOF

    # 6.1 修复：systemd unit 必须真实换行
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

    if have_cmd ufw; then ufw allow "$port"/tcp >/dev/null 2>&1; ufw allow "$port"/udp >/dev/null 2>&1; fi
    if have_cmd firewall-cmd; then
        firewall-cmd --add-port="$port"/tcp --permanent >/dev/null 2>&1
        firewall-cmd --add-port="$port"/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi

    meta_set "SS_RUST_TAG" "$ss_latest"

    echo -e "${GREEN}✅ SS-Rust (${ss_latest}) 安装完成！${RESET}"
    rm -rf "$tmpdir"
    sleep 2
}

install_vless_native() {
    clear
    echo -e "${CYAN}========= 原生交互安装 VLESS Reality =========${RESET}"
    rm -f /etc/systemd/system/xray.service

    read -rp "伪装域名 [默认 updates.cdn-apple.com]: " sni_domain
    [[ -z "$sni_domain" ]] && sni_domain="updates.cdn-apple.com"

    read -rp "监听端口 [留空随机]: " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        port=$((RANDOM % 55535 + 10000))
    fi

    local arch; arch=$(uname -m)
    local xray_arch="64"
    [[ "$arch" == "aarch64" ]] && xray_arch="arm64-v8a"

    echo -e "${CYAN}>>> 正在获取 Xray 最新版本信息...${RESET}"
    local xray_latest
    xray_latest=$(github_latest_tag "XTLS/Xray-core")
    [[ -z "$xray_latest" ]] && xray_latest="v1.8.24"

    local tmpdir; tmpdir=$(mktemp -d /tmp/ssr-xray.XXXXXX)
    local zipf="${tmpdir}/xray.zip"
    local url="https://github.com/XTLS/Xray-core/releases/download/${xray_latest}/Xray-linux-${xray_arch}.zip"

    echo -e "${CYAN}>>> 下载核心: ${xray_latest} (linux-${xray_arch}) ...${RESET}"
    if ! download_file "$url" "$zipf" || [[ ! -s "$zipf" ]] || ! unzip -t "$zipf" >/dev/null 2>&1; then
        echo -e "${RED}❌ 核心下载或校验失败。${RESET}"
        rm -rf "$tmpdir"
        sleep 3
        return
    fi

    unzip -qo "$zipf" xray -d "$tmpdir" >/dev/null 2>&1 || true
    if [[ ! -x "${tmpdir}/xray" ]]; then
        echo -e "${RED}❌ 解压失败：未找到 xray。${RESET}"
        rm -rf "$tmpdir"
        sleep 3
        return
    fi

    if ! run_with_timeout 3 "${tmpdir}/xray" version >/dev/null 2>&1; then
        echo -e "${RED}❌ 新核心自检失败（无法运行）。已中止替换。${RESET}"
        rm -rf "$tmpdir"
        sleep 3
        return
    fi

    safe_install_binary "${tmpdir}/xray" /usr/local/bin/xray || {
        echo -e "${RED}❌ 安装失败（写入 /usr/local/bin/xray 失败）。${RESET}"
        rm -rf "$tmpdir"
        sleep 3
        return
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

    # 6.1 修复：unit 换行
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

    if have_cmd ufw; then ufw allow "$port"/tcp >/dev/null 2>&1; fi
    if have_cmd firewall-cmd; then firewall-cmd --add-port="$port"/tcp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi

    meta_set "XRAY_TAG" "$xray_latest"

    echo -e "${GREEN}✅ VLESS Reality (${xray_latest}) 安装成功！${RESET}"
    rm -rf "$tmpdir"
    sleep 2
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
        if [[ "$protect_choice" == "1" ]]; then
            up_port=$ss_port
        else
            read -rp "需要保护的上游端口: " up_port
        fi
    else
        read -rp "需要保护的上游端口: " up_port
    fi

    [[ -z "$up_port" ]] && echo -e "${RED}端口无效！${RESET}" && sleep 2 && return

    read -rp "ShadowTLS 伪装端口 [留空随机]: " listen_port
    if ! [[ "$listen_port" =~ ^[0-9]+$ ]] || [ "$listen_port" -lt 1 ] || [ "$listen_port" -gt 65535 ]; then
        listen_port=$((RANDOM % 55535 + 10000))
    fi

    read -rp "伪装域名 (SNI) [留空默认 updates.cdn-apple.com]: " sni_domain
    [[ -z "$sni_domain" ]] && sni_domain="updates.cdn-apple.com"

    local pwd; pwd=$(openssl rand -base64 8 2>/dev/null | tr -d '\n')
    local arch; arch=$(uname -m)
    local st_arch="x86_64-unknown-linux-musl"
    [[ "$arch" == "aarch64" ]] && st_arch="aarch64-unknown-linux-musl"

    echo -e "${CYAN}>>> 正在获取 ShadowTLS 最新版本信息...${RESET}"
    local st_latest
    st_latest=$(github_latest_tag "ihciah/shadow-tls")
    [[ -z "$st_latest" ]] && st_latest="v0.2.25"

    local tmpdir; tmpdir=$(mktemp -d /tmp/ssr-stls.XXXXXX)
    local binf="${tmpdir}/shadow-tls"
    local url="https://github.com/ihciah/shadow-tls/releases/download/${st_latest}/shadow-tls-${st_arch}"

    echo -e "${CYAN}>>> 下载核心: ${st_latest} (${st_arch}) ...${RESET}"
    if ! download_file "$url" "$binf" || [[ ! -s "$binf" ]]; then
        echo -e "${RED}❌ 下载失败。${RESET}"
        rm -rf "$tmpdir"
        sleep 3
        return
    fi
    chmod +x "$binf" >/dev/null 2>&1 || true

    # 可运行校验
    if ! run_with_timeout 3 "$binf" --version >/dev/null 2>&1; then
        run_with_timeout 3 "$binf" -V >/dev/null 2>&1 || run_with_timeout 3 "$binf" --help >/dev/null 2>&1 || {
            echo -e "${RED}❌ 新核心自检失败（无法运行）。已中止替换。${RESET}"
            rm -rf "$tmpdir"
            sleep 3
            return
        }
    fi

    safe_install_binary "$binf" /usr/local/bin/shadow-tls || {
        echo -e "${RED}❌ 安装失败（写入 /usr/local/bin/shadow-tls 失败）。${RESET}"
        rm -rf "$tmpdir"
        sleep 3
        return
    }

    # 6.1 修复：unit 换行
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

    if have_cmd ufw; then ufw allow "$listen_port"/tcp >/dev/null 2>&1; fi
    if have_cmd firewall-cmd; then firewall-cmd --add-port="$listen_port"/tcp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi

    meta_set "SHADOWTLS_TAG" "$st_latest"

    echo -e "${GREEN}✅ ShadowTLS (${st_latest}) 安装成功！已挂载在 ${up_port} 上层。${RESET}"
    rm -rf "$tmpdir"
    sleep 2
}

# ==============================================================================
# 统一节点生命周期管控中心
# ==============================================================================
unified_node_manager() {
    while true; do
        clear
        echo -e "${CYAN}========= 🔰 统一节点生命周期管控中心 =========${RESET}"

        # 清理异常 shadowtls unit 文件（端口名异常）
        for s in /etc/systemd/system/shadowtls-*.service; do
            [[ -e "$s" ]] || continue
            local check_port
            check_port=$(basename "$s" | sed 's/shadowtls-//g' | sed 's/.service//g')
            if ! [[ "$check_port" =~ ^[0-9]+$ ]]; then
                systemctl stop "$(basename "$s")" 2>/dev/null || true
                systemctl disable "$(basename "$s")" 2>/dev/null || true
                rm -f "$s"
                systemctl daemon-reload
            fi
        done

        local has_ss=0 has_vless=0 has_stls=0
        if [[ -f "/etc/ss-rust/config.json" ]]; then
            echo -e "${GREEN} 1) ⚡ SS-Rust 节点${RESET}"
            has_ss=1
        else
            echo -e "${RED} 1) ❌ 未部署 SS-Rust${RESET}"
        fi

        if [[ -f "/usr/local/etc/xray/config.json" ]]; then
            echo -e "${GREEN} 2) 🔮 VLESS Reality 节点${RESET}"
            has_vless=1
        else
            echo -e "${RED} 2) ❌ 未部署 VLESS Reality${RESET}"
        fi

        if ls /etc/systemd/system/shadowtls-*.service 1> /dev/null 2>&1; then
            echo -e "${GREEN} 3) 🛡️ ShadowTLS 防阻断保护实例${RESET}"
            has_stls=1
        else
            echo -e "${RED} 3) ❌ 未部署 ShadowTLS${RESET}"
        fi

        echo -e "${CYAN}--------------------------------------------${RESET}"
        echo -e "${RED} 4) ☢️ 全局强制核爆 (清理任意卡死/幽灵服务)${RESET}"
        echo -e " 0) 返回主菜单"
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
                    echo -e "IP: ${GREEN}${ip}${RESET}"
                    echo -e "端口: ${GREEN}${port}${RESET}"
                    echo -e "协议: ${GREEN}${method}${RESET}"
                    echo -e "密码: ${GREEN}${password}${RESET}"
                    echo -e "${YELLOW}链接:${RESET}\n${link}"
                    echo -e "---------------------------------"
                    echo -e "${YELLOW}1) 修改端口${RESET} | ${YELLOW}2) 修改密码${RESET} | ${RED}3) 删除节点${RESET} | 0) 返回"
                    read -rp "输入操作: " op
                    if [[ "$op" == "1" ]]; then
                        read -rp "新端口 (1-65535): " np
                        if [[ "$np" =~ ^[0-9]+$ ]] && [ "$np" -ge 1 ] && [ "$np" -le 65535 ]; then
                            jq --argjson p "$np" '.server_port = $p' /etc/ss-rust/config.json > /tmp/tmp.json && mv -f /tmp/tmp.json /etc/ss-rust/config.json
                            remove_firewall_rule "$port" "both"
                            if have_cmd ufw; then ufw allow "$np"/tcp >/dev/null 2>&1; ufw allow "$np"/udp >/dev/null 2>&1; fi
                            if have_cmd firewall-cmd; then
                                firewall-cmd --add-port="$np"/tcp --permanent >/dev/null 2>&1
                                firewall-cmd --add-port="$np"/udp --permanent >/dev/null 2>&1
                                firewall-cmd --reload >/dev/null 2>&1
                            fi
                            systemctl restart ss-rust 2>/dev/null || true
                            echo -e "${GREEN}✅ 修改成功${RESET}"
                        else
                            echo -e "${RED}❌ 端口无效${RESET}"
                        fi
                        sleep 1
                    elif [[ "$op" == "2" ]]; then
                        read -rp "新密码: " npwd
                        [[ -z "$npwd" ]] && { echo -e "${RED}❌ 密码不能为空${RESET}"; sleep 1; continue; }
                        jq --arg pwd "$npwd" '.password = $pwd' /etc/ss-rust/config.json > /tmp/tmp.json && mv -f /tmp/tmp.json /etc/ss-rust/config.json
                        systemctl restart ss-rust 2>/dev/null || true
                        echo -e "${GREEN}✅ 修改成功${RESET}"
                        sleep 1
                    elif [[ "$op" == "3" ]]; then
                        remove_firewall_rule "$port" "both"
                        systemctl stop ss-rust 2>/dev/null || true
                        systemctl disable ss-rust 2>/dev/null || true
                        rm -rf /etc/ss-rust /usr/local/bin/ss-rust /etc/systemd/system/ss-rust.service
                        systemctl daemon-reload
                        echo -e "${GREEN}✅ 已彻底销毁！${RESET}"
                        sleep 1
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
                    echo -e "IP: ${GREEN}${ip}${RESET}"
                    echo -e "端口: ${GREEN}${port}${RESET}"
                    echo -e "UUID: ${GREEN}${uuid}${RESET}"
                    echo -e "SNI伪装: ${GREEN}${sni}${RESET}"
                    echo -e "---------------------------------"
                    echo -e "${YELLOW}1) 重启节点${RESET} | ${RED}2) 删除节点${RESET} | 0) 返回"
                    read -rp "输入操作: " op
                    if [[ "$op" == "1" ]]; then
                        systemctl restart xray 2>/dev/null || true
                        echo -e "${GREEN}✅ 已重启${RESET}"
                        sleep 1
                    elif [[ "$op" == "2" ]]; then
                        remove_firewall_rule "$port" "tcp"
                        systemctl stop xray 2>/dev/null || true
                        systemctl disable xray 2>/dev/null || true
                        rm -rf /usr/local/etc/xray /usr/local/bin/xray /etc/systemd/system/xray.service
                        systemctl daemon-reload
                        echo -e "${GREEN}✅ 已彻底销毁！${RESET}"
                        sleep 1
                    fi
                fi
                ;;
            3)
                if [[ $has_stls -eq 1 ]]; then
                    clear
                    local st_ports=()
                    local idx=1
                    for s in /etc/systemd/system/shadowtls-*.service; do
                        [[ -e "$s" ]] || continue
                        local st_port
                        st_port=$(basename "$s" | sed 's/shadowtls-//g' | sed 's/.service//g')
                        st_ports[$idx]=$st_port
                        local st_status
                        if systemctl is-active --quiet shadowtls-"$st_port" 2>/dev/null; then
                            st_status="${GREEN}运行中${RESET}"
                        else
                            st_status="${RED}已停止${RESET}"
                        fi
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
                            remove_firewall_rule "$del_port" "tcp"
                            systemctl stop shadowtls-"$del_port" 2>/dev/null || true
                            systemctl disable shadowtls-"$del_port" 2>/dev/null || true
                            rm -f "/etc/systemd/system/shadowtls-${del_port}.service"
                            systemctl daemon-reload
                            if ! ls /etc/systemd/system/shadowtls-*.service 1> /dev/null 2>&1; then
                                rm -f /usr/local/bin/shadow-tls
                            fi
                            echo -e "${GREEN}✅ 已彻底销毁！${RESET}"
                            sleep 1
                        fi
                    elif [[ "$op" == "9" ]]; then
                        echo -e "${RED}执行物理核爆...${RESET}"
                        for p in "${st_ports[@]}"; do
                            [[ -z "$p" ]] && continue
                            remove_firewall_rule "$p" "tcp"
                            systemctl stop "shadowtls-$p" 2>/dev/null || true
                            systemctl disable "shadowtls-$p" 2>/dev/null || true
                            rm -f "/etc/systemd/system/shadowtls-${p}.service"
                        done
                        rm -f /usr/local/bin/shadow-tls
                        systemctl daemon-reload
                        echo -e "${GREEN}✅ 拔除成功！${RESET}"
                        sleep 2
                    fi
                fi
                ;;
            4)
                clear
                echo -e "${CYAN}========= ☢️ 全局强制核爆中心 =========${RESET}"
                echo -e "${YELLOW}支持强制抹除系统中任何卡死、报错或残留的服务。${RESET}"
                echo -e "参考名：${GREEN}ss-rust${RESET} | ${GREEN}xray${RESET} | ${GREEN}shadowtls-端口${RESET}"
                echo -e "---------------------------------"
                read -rp "请输入要粉碎的服务名 (直接回车取消): " nuke_target
                [[ -n "$nuke_target" ]] && force_kill_service "$nuke_target" "menu"
                ;;
            0) return ;;
        esac
    done
}

# ==============================================================================
# 网络调优 Profiles（NAT/常规：稳定优先 vs 极致性能）
#   - NAT: 附带 journald 限制、SSH Keepalive、DNS 设置/锁定（可回滚）
#   - sysctl: 统一写入专用文件 + sysctl --system (要求)
# ==============================================================================
apply_journald_limit() {
    # NAT 小鸡常见：磁盘小，journald 爆盘风险；稳定优先采用温和限制
    local limit="${1:-50M}"
    if [[ -f /etc/systemd/journald.conf ]]; then
        if grep -qE '^\s*SystemMaxUse=' /etc/systemd/journald.conf; then
            sed -i "s|^\s*SystemMaxUse=.*|SystemMaxUse=${limit}|g" /etc/systemd/journald.conf
        else
            echo "SystemMaxUse=${limit}" >> /etc/systemd/journald.conf
        fi
        systemctl restart systemd-journald 2>/dev/null || true
    fi
}

apply_ssh_keepalive() {
    local interval="${1:-30}"
    local count="${2:-3}"
    if [[ -f /etc/ssh/sshd_config ]]; then
        sed -i "s/^#\?ClientAliveInterval.*/ClientAliveInterval ${interval}/g" /etc/ssh/sshd_config
        sed -i "s/^#\?ClientAliveCountMax.*/ClientAliveCountMax ${count}/g" /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    fi
}

ensure_swap() {
    # NAT 小鸡：提供轻量 swap，避免 OOM；稳定优先：256M，性能档：512M
    local size_mb="$1"
    [[ -z "$size_mb" ]] && size_mb=256
    if grep -q " swap " /etc/fstab 2>/dev/null; then
        return
    fi

    rm -f /var/swap
    if dd if=/dev/zero of=/var/swap bs=1M count="$size_mb" status=none 2>/dev/null; then
        chmod 600 /var/swap
        mkswap /var/swap >/dev/null 2>&1
        swapon /var/swap >/dev/null 2>&1 || true
        echo "/var/swap swap swap defaults 0 0" >> /etc/fstab
        echo -e "${GREEN}✅ ${size_mb}MB Swap 创建成功！${RESET}"
    else
        rm -f /var/swap
        echo -e "${YELLOW}⚠️ Swap 创建失败（可能磁盘不足），已跳过。${RESET}"
    fi
}

apply_nat_profile() {
    local profile="$1"  # stable|perf
    rm -f "$CONF_FILE" 2>/dev/null || true

    # NAT 相关附加措施
    apply_journald_limit "50M"
    apply_ssh_keepalive 30 3

    # DNS：稳定档仅设置不锁；性能档尽量锁定（symlink 则走 systemd-resolved）
    if [[ "$profile" == "perf" ]]; then
        dns_set_or_lock "lock" || true
        ensure_swap 512
    else
        dns_set_or_lock "set" || true
        ensure_swap 256
    fi

    # sysctl：写入专用文件 + sysctl --system
    cat > "$NAT_CONF_FILE" << EOF
# SSR NAT Profile: ${profile}
# 说明：
#  - 稳定优先：更保守的队列/超时；减少边缘副作用
#  - 极致性能：更激进的队列/复用；更适合高并发/大吞吐

net.ipv4.tcp_mtu_probing = 1

# NAT/小鸡：保活，减少空闲断流
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 20
net.ipv4.tcp_keepalive_probes = 3

# 队列与拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 连接与缓冲（按档位调整）
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

# 稳定优先：不强行启用 tw_reuse，避免极端边缘环境问题
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_fastopen = 3
EOF
    fi

    sysctl --system >/dev/null 2>&1 || true
    meta_set "SYSCTL_PROFILE" "nat-${profile}"

    echo -e "${GREEN}✅ NAT(${profile}) Profile 已应用！${RESET}"
    sleep 2
}

apply_regular_profile() {
    local profile="$1"  # stable|perf
    rm -f "$NAT_CONF_FILE" 2>/dev/null || true

    # sysctl：写入专用文件 + sysctl --system
    cat > "$CONF_FILE" << EOF
# SSR Regular Profile: ${profile}

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1

# 注意：默认不改 IPv6 forwarding，避免影响 RA/IPv6 正常上网
EOF

    if [[ "$profile" == "perf" ]]; then
        cat >> "$CONF_FILE" << 'EOF'
# 极致性能：更高的 buffer/队列上限（适合大内存/高并发）
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
# 稳定优先：更保守的 buffer/队列（适合大多数机器）
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

    sysctl --system >/dev/null 2>&1 || true
    meta_set "SYSCTL_PROFILE" "regular-${profile}"

    echo -e "${GREEN}✅ 常规(${profile}) Profile 已应用！${RESET}"
    sleep 2
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
        echo -e " 0. 返回主菜单"
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

# ==============================================================================
# 守护、清理与安全热更（2.2 / 2.3）
# ==============================================================================
run_daemon_check() {
    # 6.2 修复：用退出码判断，而不是 [[ $(grep -q) ]]
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
    rm -rf /root/.cache/* /tmp/*.tar.xz /tmp/shadow-tls /tmp/ssserver /tmp/ssr_update.sh /tmp/xray* /tmp/tmp.json 2>/dev/null || true
    [[ "$is_silent" != "silent" ]] && echo -e "${GREEN}✅ 垃圾清理完毕！${RESET}"
}

update_ss_rust_if_needed() {
    [[ -x "/usr/local/bin/ss-rust" ]] || return 1

    local arch; arch=$(uname -m)
    local ss_arch="x86_64-unknown-linux-gnu"
    [[ "$arch" == "aarch64" ]] && ss_arch="aarch64-unknown-linux-gnu"

    local latest; latest=$(github_latest_tag "shadowsocks/shadowsocks-rust")
    [[ -z "$latest" ]] && return 2

    local current; current=$(meta_get "SS_RUST_TAG" || true)

    if [[ -z "$current" ]]; then
        # 尝试从二进制版本推断
        local v
        v=$(/usr/local/bin/ss-rust --version 2>/dev/null | grep -oE '([0-9]+\.){2}[0-9]+' | head -n 1)
        [[ -n "$v" ]] && current="v${v}"
    fi

    [[ -n "$current" && "$current" == "$latest" ]] && return 3

    local tmpdir; tmpdir=$(mktemp -d /tmp/ssr-up-ssrust.XXXXXX)
    local tarball="${tmpdir}/ss-rust.tar.xz"
    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${latest}/shadowsocks-${latest}.${ss_arch}.tar.xz"

    if ! download_file "$url" "$tarball" || [[ ! -s "$tarball" ]] || ! tar -tf "$tarball" >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        return 2
    fi

    tar -xf "$tarball" -C "$tmpdir" ssserver >/dev/null 2>&1 || true
    [[ -x "${tmpdir}/ssserver" ]] || { rm -rf "$tmpdir"; return 2; }

    if ! run_with_timeout 3 "${tmpdir}/ssserver" --version >/dev/null 2>&1; then
        run_with_timeout 3 "${tmpdir}/ssserver" -V >/dev/null 2>&1 || { rm -rf "$tmpdir"; return 2; }
    fi

    safe_install_binary "${tmpdir}/ssserver" /usr/local/bin/ss-rust || { rm -rf "$tmpdir"; return 2; }

    meta_set "SS_RUST_TAG" "$latest"
    systemctl restart ss-rust 2>/dev/null || true
    rm -rf "$tmpdir"
    return 0
}

update_xray_if_needed() {
    [[ -x "/usr/local/bin/xray" ]] || return 1

    local arch; arch=$(uname -m)
    local xray_arch="64"
    [[ "$arch" == "aarch64" ]] && xray_arch="arm64-v8a"

    local latest; latest=$(github_latest_tag "XTLS/Xray-core")
    [[ -z "$latest" ]] && return 2

    local current; current=$(meta_get "XRAY_TAG" || true)
    if [[ -z "$current" ]]; then
        local v
        v=$(/usr/local/bin/xray version 2>/dev/null | head -n 1 | grep -oE '([0-9]+\.){2}[0-9]+' | head -n 1)
        [[ -n "$v" ]] && current="v${v}"
    fi

    [[ -n "$current" && "$current" == "$latest" ]] && return 3

    local tmpdir; tmpdir=$(mktemp -d /tmp/ssr-up-xray.XXXXXX)
    local zipf="${tmpdir}/xray.zip"
    local url="https://github.com/XTLS/Xray-core/releases/download/${latest}/Xray-linux-${xray_arch}.zip"

    if ! download_file "$url" "$zipf" || [[ ! -s "$zipf" ]] || ! unzip -t "$zipf" >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        return 2
    fi

    unzip -qo "$zipf" xray -d "$tmpdir" >/dev/null 2>&1 || true
    [[ -x "${tmpdir}/xray" ]] || { rm -rf "$tmpdir"; return 2; }

    run_with_timeout 3 "${tmpdir}/xray" version >/dev/null 2>&1 || { rm -rf "$tmpdir"; return 2; }

    safe_install_binary "${tmpdir}/xray" /usr/local/bin/xray || { rm -rf "$tmpdir"; return 2; }

    meta_set "XRAY_TAG" "$latest"
    systemctl restart xray 2>/dev/null || true
    rm -rf "$tmpdir"
    return 0
}

update_shadowtls_if_needed() {
    [[ -x "/usr/local/bin/shadow-tls" ]] || return 1

    local arch; arch=$(uname -m)
    local st_arch="x86_64-unknown-linux-musl"
    [[ "$arch" == "aarch64" ]] && st_arch="aarch64-unknown-linux-musl"

    local latest; latest=$(github_latest_tag "ihciah/shadow-tls")
    [[ -z "$latest" ]] && return 2

    local current; current=$(meta_get "SHADOWTLS_TAG" || true)
    [[ -n "$current" && "$current" == "$latest" ]] && return 3

    local tmpdir; tmpdir=$(mktemp -d /tmp/ssr-up-stls.XXXXXX)
    local binf="${tmpdir}/shadow-tls"
    local url="https://github.com/ihciah/shadow-tls/releases/download/${latest}/shadow-tls-${st_arch}"

    if ! download_file "$url" "$binf" || [[ ! -s "$binf" ]]; then
        rm -rf "$tmpdir"
        return 2
    fi
    chmod +x "$binf" >/dev/null 2>&1 || true

    if ! run_with_timeout 3 "$binf" --version >/dev/null 2>&1; then
        run_with_timeout 3 "$binf" -V >/dev/null 2>&1 || run_with_timeout 3 "$binf" --help >/dev/null 2>&1 || { rm -rf "$tmpdir"; return 2; }
    fi

    safe_install_binary "$binf" /usr/local/bin/shadow-tls || { rm -rf "$tmpdir"; return 2; }

    meta_set "SHADOWTLS_TAG" "$latest"

    # 重启所有 shadowtls-* 服务
    while read -r svc; do
        [[ -z "$svc" ]] && continue
        systemctl restart "$svc" 2>/dev/null || true
    done < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep '^shadowtls-.*\.service$' || true)

    rm -rf "$tmpdir"
    return 0
}

hot_update_components() {
    # 2.2/2.3：仅有新版本才更新；下载到临时文件校验可运行后再原子替换
    local is_silent=$1
    local updated_any=0

    update_ss_rust_if_needed; local r1=$?
    update_shadowtls_if_needed; local r2=$?
    update_xray_if_needed; local r3=$?

    [[ $r1 -eq 0 || $r2 -eq 0 || $r3 -eq 0 ]] && updated_any=1

    if [[ "$is_silent" != "silent" ]]; then
        if [[ $updated_any -eq 1 ]]; then
            echo -e "${GREEN}✅ 核心组件已完成安全热更（仅更新到新版本）。${RESET}"
        else
            echo -e "${GREEN}✅ 核心组件已是最新或无需更新。${RESET}"
        fi
        sleep 2
    fi
}

update_script() {
    # 手动更新脚本本身：下载到临时文件 -> bash -n -> 原子替换
    echo -e "${CYAN}>>> 同步最新版脚本数据...${RESET}"
    local tmpdir; tmpdir=$(mktemp -d /tmp/ssr-up-self.XXXXXX)
    local newf="${tmpdir}/ssr.new"

    local url="https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/ssr.sh"
    if ! download_file "$url" "$newf" || [[ ! -s "$newf" ]]; then
        echo -e "${RED}❌ 下载失败。${RESET}"
        rm -rf "$tmpdir"
        return
    fi

    # 语法校验
    if ! bash -n "$newf" >/dev/null 2>&1; then
        echo -e "${RED}❌ 新脚本语法校验失败，已中止替换。${RESET}"
        rm -rf "$tmpdir"
        return
    fi

    # 简单特征校验：必须包含 main_menu
    if ! grep -q "main_menu" "$newf" 2>/dev/null; then
        echo -e "${RED}❌ 新脚本内容疑似异常（缺少 main_menu），已中止替换。${RESET}"
        rm -rf "$tmpdir"
        return
    fi

    safe_install_binary "$newf" /usr/local/bin/ssr || {
        echo -e "${RED}❌ 替换失败。${RESET}"
        rm -rf "$tmpdir"
        return
    }

    echo -e "${GREEN}✅ 更新成功！${RESET}"
    rm -rf "$tmpdir"
    exec /usr/local/bin/ssr
}

daily_task() {
    # 例行任务：安全热更（有新版本才更）+ 清理
    hot_update_components "silent"
    auto_clean "silent"
}

# ==============================================================================
# 完全卸载
# ==============================================================================
total_uninstall() {
    echo -e "${RED}⚠️ 正在进行无痕毁灭性全量卸载...${RESET}"

    if [[ -f "/etc/ss-rust/config.json" ]]; then
        local sp; sp=$(jq -r '.server_port' /etc/ss-rust/config.json 2>/dev/null)
        [[ -n "$sp" && "$sp" != "null" ]] && remove_firewall_rule "$sp" "both"
    fi
    if [[ -f "/usr/local/etc/xray/config.json" ]]; then
        local xp; xp=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json 2>/dev/null)
        [[ -n "$xp" && "$xp" != "null" ]] && remove_firewall_rule "$xp" "tcp"
    fi
    for s in /etc/systemd/system/shadowtls-*.service; do
        [[ -f "$s" ]] || continue
        remove_firewall_rule "$(basename "$s" | sed 's/shadowtls-//g' | sed 's/.service//g')" "tcp"
    done

    systemctl stop ss-rust xray 2>/dev/null || true
    rm -rf /etc/ss-rust /usr/local/bin/ss-rust /etc/systemd/system/ss-rust.service
    rm -rf /usr/local/etc/xray /usr/local/bin/xray /etc/systemd/system/xray.service

    while read -r s; do
        [[ -z "$s" ]] && continue
        systemctl stop "$s" 2>/dev/null || true
        systemctl disable "$s" 2>/dev/null || true
        rm -f "/etc/systemd/system/$s"
    done < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep '^shadowtls-.*\.service$' || true)

    if [[ -f "$DDNS_CONF" ]]; then
        remove_cf_ddns "force"
    fi

    rm -f /usr/local/bin/shadow-tls "$CONF_FILE" "$NAT_CONF_FILE" "$DDNS_CONF" "$DDNS_LOG" "$META_FILE"
    rm -f /usr/local/bin/ssr /usr/local/bin/ssr.sh 2>/dev/null || true

    crontab -l 2>/dev/null | grep -vE "/usr/local/bin/ssr (auto_update|auto_task|daemon_check|hot_upgrade|clean|daily_task|ddns)" | crontab - 2>/dev/null || true

    dns_unlock_restore 2>/dev/null || true

    if grep -q "/var/swap" /etc/fstab 2>/dev/null; then
        swapoff /var/swap 2>/dev/null || true
        rm -f /var/swap
        sed -i 's|/var/swap swap swap defaults 0 0||g' /etc/fstab
    fi

    systemctl daemon-reload
    echo -e "${GREEN}✅ 完美无痕卸载完成！系统已彻底洁净退水。${RESET}"
    exit 0
}

# ==============================================================================
# 系统菜单
# ==============================================================================
sys_menu() {
    while true; do
        clear
        echo -e "${CYAN}========= 系统基础与极客管理 =========${RESET}"
        echo -e "${YELLOW} 1.${RESET} 一键修改 SSH 安全端口"
        echo -e "${YELLOW} 2.${RESET} 一键修改 Root 密码"
        echo -e "${YELLOW} 3.${RESET} 服务器时间防偏移同步"
        echo -e "${YELLOW} 4.${RESET} SSH 密钥登录管理中心"
        echo -e "${GREEN} 5.${RESET} 原生 Cloudflare DDNS 解析模块"
        echo -e "${CYAN}--------------------------------------------${RESET}"
        echo -e "${YELLOW} 6.${RESET} 手动安全热更升级核心组件"
        echo -e "${YELLOW} 7.${RESET} 手动更新 SSR 管理脚本本身"
        echo -e "${YELLOW} 8.${RESET} DNS 管理中心（锁定/解锁/恢复）"
        echo -e " 0. 返回主菜单"
        read -rp "输入数字 [0-8]: " sys_num
        case "$sys_num" in
            1) change_ssh_port ;;
            2) change_root_password ;;
            3) sync_server_time ;;
            4) ssh_key_menu ;;
            5) cf_ddns_menu ;;
            6) hot_update_components ;;
            7) update_script ;;
            8) dns_menu ;;
            0) return ;;
        esac
    done
}

main_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}       SSR 综合智能管理脚本 v${SCRIPT_VERSION}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${YELLOW} 1.${RESET} 原生部署 SS-Rust"
    echo -e "${YELLOW} 2.${RESET} 原生部署 VLESS Reality"
    echo -e "${YELLOW} 3.${RESET} 🛡️ 部署 ShadowTLS (保护传统协议)"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    echo -e "${GREEN} 4.${RESET} 🔰 统一节点管控中心 (查看 / 删除 / 核爆)"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    echo -e "${YELLOW} 5.${RESET} 网络优化与系统清理 (Profiles + DNS)"
    echo -e "${YELLOW} 6.${RESET} 系统底层管控 (DDNS / 安全 / 更新)"
    echo -e "${RED} 7.${RESET} 完美无痕毁灭性卸载中心"
    echo -e "${CYAN}============================================${RESET}"
    echo -e " 0. 退出脚本"
    read -rp "请输入对应数字 [0-7]: " num
    case "$num" in
        1) install_ss_rust_native ;;
        2) install_vless_native ;;
        3) install_shadowtls_native ;;
        4) unified_node_manager ;;
        5) opt_menu ;;
        6) sys_menu ;;
        7) total_uninstall ;;
        0) echo -e "${GREEN}感谢使用，再见！${RESET}"; exit 0 ;;
        *) echo -e "${RED}请输入正确的选项！${RESET}" ;;
    esac
    echo -e "\n${CYAN}按任意键返回主菜单，或按 Ctrl+C 直接退出...${RESET}"
    read -n 1 -s -r
}

# ==============================================================================
# 入口
# ==============================================================================
check_env
install_global_command

# CLI 调度
if [[ -n "${1:-}" ]]; then
    case "$1" in
        bbr)
            case "${2:-stable}" in
                stable|s) apply_regular_profile "stable" ;;
                perf|p)   apply_regular_profile "perf" ;;
                *)        echo -e "${RED}用法: ssr bbr [stable|perf]${RESET}"; exit 1 ;;
            esac
            ;;
        nat)
            case "${2:-stable}" in
                stable|s) apply_nat_profile "stable" ;;
                perf|p)   apply_nat_profile "perf" ;;
                *)        echo -e "${RED}用法: ssr nat [stable|perf]${RESET}"; exit 1 ;;
            esac
            ;;
        dns)
            case "${2:-status}" in
                status) dns_status ;;
                set)    dns_set_or_lock "set" ;;
                lock)   dns_set_or_lock "lock" ;;
                unlock|restore) dns_unlock_restore ;;
                *) echo -e "${RED}用法: ssr dns [status|set|lock|unlock]${RESET}"; exit 1 ;;
            esac
            ;;
        clean)        auto_clean "silent" ;;
        update)       update_script ;;
        hot_upgrade)  hot_update_components "silent" ;;
        daily_task)   daily_task ;;
        daemon_check) run_daemon_check ;;
        ddns)         run_cf_ddns "auto" ;;
        rmddns)       remove_cf_ddns "force" ;;
        nuke)         force_kill_service "$2" "cli" ;;
        *)            echo -e "${RED}未知指令: $1${RESET}"; exit 1 ;;
    esac
    exit 0
else
    while true; do main_menu; done
fi
