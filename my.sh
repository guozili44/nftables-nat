#!/bin/bash
# ============================================================
# 综合管理脚本：SSR + nftables
# 快捷命令：my
# 更新地址：https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/my.sh
# 版本：v1.3.0  (build 2026-03-06+acdndd-nginx)
# 指纹：CMD_NAME="my" / MY_SCRIPT_ID="my-manager"
# ============================================================

set -o pipefail

# 兼容 cron/systemd 的精简 PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# --------------------------
# 基本信息
# --------------------------
CMD_NAME="my"
MY_SCRIPT_ID="my-manager"
MY_VERSION="1.3.0"

MY_INSTALL_DIR="/usr/local/lib/my"
SSR_MODULE_FILE="${MY_INSTALL_DIR}/ssr_module.sh"
NFT_MODULE_FILE="${MY_INSTALL_DIR}/nft_module.sh"
NGX_MODULE_FILE="${MY_INSTALL_DIR}/nginx_module.sh"

MY_LOCK_FILE="/var/lock/my.lock"
SSR_LOCK_FILE="/var/lock/ssr.lock"

SSR_DDNS_CONF="/usr/local/etc/ssr_ddns.conf"

UPDATE_URL_DIRECT="https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/my.sh"
UPDATE_URL_PROXY="https://ghproxy.net/https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/my.sh"

REINSTALL_UPSTREAM_GLOBAL="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
REINSTALL_UPSTREAM_CN="https://cnb.cool/bin456789/reinstall/-/git/raw/main/reinstall.sh"
REINSTALL_WORKDIR="/tmp/my-reinstall"
REINSTALL_SCRIPT_PATH="${REINSTALL_WORKDIR}/reinstall.sh"

# --------------------------
# 颜色
# --------------------------
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

require_root() {
    if [[ $EUID -ne 0 ]]; then
        msg_err "错误: 必须使用 root 权限运行！"
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
    echo "$0"
}

# --------------------------
# 安装：快捷命令 my + 模块文件
# --------------------------
install_self_command() {
    local self
    self="$(script_realpath)"
    if [[ "$self" != "/usr/local/bin/${CMD_NAME}" ]]; then
        cp -f "$self" "/usr/local/bin/${CMD_NAME}" 2>/dev/null || true
        chmod +x "/usr/local/bin/${CMD_NAME}" 2>/dev/null || true
    fi

    # 删除旧快捷命令（防冲突）
    rm -f /usr/local/bin/ssr /usr/local/bin/ssr.sh /usr/local/bin/nftmgr /usr/local/bin/nft_mgr.sh 2>/dev/null || true
}

install_modules() {
    mkdir -p "${MY_INSTALL_DIR}" 2>/dev/null || true

    # SSR 模块（已移除脚本自更新/卸载菜单，并适配 my 统一管理）
    cat > "${SSR_MODULE_FILE}" <<'SSR_MODULE_EOF'
#!/bin/bash
# ==============================================================================
# 脚本名称: SSR 综合管理脚本 (稳定优先 + 极致性能 Profiles)
# 核心特性:
#   - 节点部署: SS-Rust / VLESS Reality (Xray) / ShadowTLS
#   - 双档位网络调优: 手动选择 常规机器 / NAT 小鸡 => 稳定优先 / 极致优化
#   - Cloudflare DDNS: 原生 API + 定时守护
#   - 自动任务互斥: cron 使用 flock 防并发踩踏
#   - 自动热更: 仅在有新版本时更新；下载到临时目录校验可运行后再原子替换
#   - DNS 管理: 检测 /etc/resolv.conf 是否 symlink；提供一键解锁/恢复
#
# 命令：ssr regular|nat [stable|extreme] / ssr dns ...
# ==============================================================================

set -o pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly RESET='\033[0m'

readonly SCRIPT_VERSION="21.3-Manual-Tuned"

# Sysctl profile files (互斥写入)
readonly CONF_FILE="/etc/sysctl.d/99-ssr-net.conf"
readonly NAT_CONF_FILE="/etc/sysctl.d/99-ssr-nat.conf"

# CF DDNS
readonly DDNS_CONF="/usr/local/etc/ssr_ddns.conf"
readonly DDNS_LOG="/var/log/ssr_ddns.log"

readonly LOCK_FILE="/var/lock/ssr.lock"

# Meta (用于判断是否有新版本)
readonly META_DIR="/usr/local/etc/ssr_meta"
readonly META_FILE="${META_DIR}/versions.conf"
readonly SHADOWTLS_STATE_DIR="${META_DIR}/shadowtls"
readonly SWAP_MARK_FILE="${META_DIR}/swap_created_by_ssr"
readonly SSHD_BACKUP_FILE="${META_DIR}/sshd_config.bak"
readonly SSH_AUTH_DROPIN="/etc/ssh/sshd_config.d/99-my-auth.conf"
readonly JOURNALD_BACKUP_FILE="${META_DIR}/journald.conf.bak"

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

backup_file_once() {
    local src="$1"; local bak="$2"
    [[ -f "$src" ]] || return 0
    [[ -f "$bak" ]] && return 0
    mkdir -p "$(dirname "$bak")" 2>/dev/null || true
    cp -a "$src" "$bak" 2>/dev/null || true
}

restore_file_if_present() {
    local bak="$1"; local dst="$2"
    [[ -f "$bak" ]] || return 0
    cp -a "$bak" "$dst" 2>/dev/null || true
}

replace_or_append_line() {
    local file="$1"; local regex="$2"; local newline="$3"
    touch "$file" 2>/dev/null || return 1
    if grep -qE "$regex" "$file" 2>/dev/null; then
        sed -i "s|${regex}.*|${newline}|g" "$file"
    else
        printf '%s\n' "$newline" >> "$file"
    fi
}


write_ssh_auth_dropin() {
    local pass_mode="$1" kb_mode="$2" challenge_mode="$3"
    mkdir -p "$(dirname "$SSH_AUTH_DROPIN")" 2>/dev/null || true
    cat > "$SSH_AUTH_DROPIN" <<EOF
# managed by my
PasswordAuthentication ${pass_mode}
KbdInteractiveAuthentication ${kb_mode}
ChallengeResponseAuthentication ${challenge_mode}
PubkeyAuthentication yes
PermitRootLogin prohibit-password
UsePAM yes
EOF
}

remove_ssh_auth_dropin() {
    rm -f "$SSH_AUTH_DROPIN" 2>/dev/null || true
}

restart_ssh_safe() {
    local cfg="/etc/ssh/sshd_config"
    if have_cmd sshd && ! sshd -t -f "$cfg" >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ sshd_config 校验失败，未重启 SSH。${RESET}"
        return 1
    fi
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
}

service_use_systemd() {
    have_cmd systemctl && [[ -d /etc/systemd/system ]]
}

json_get_path() {
    local file="$1" path="$2"
    [[ -f "$file" ]] || return 1
    if have_cmd python3; then
        python3 - "$file" "$path" <<'PYPARSE'
import json, sys
file, path = sys.argv[1], sys.argv[2]
with open(file, 'r', encoding='utf-8') as f:
    obj = json.load(f)
cur = obj
for part in path.split('.'):
    if part.isdigit():
        cur = cur[int(part)]
    else:
        cur = cur[part]
if cur is None:
    print("")
elif isinstance(cur, bool):
    print("true" if cur else "false")
else:
    print(cur)
PYPARSE
        return 0
    fi
    if have_cmd jq; then
        local expr="."
        IFS='.' read -r -a _parts <<< "$path"
        local part
        for part in "${_parts[@]}"; do
            if [[ "$part" =~ ^[0-9]+$ ]]; then
                expr+="[$part]"
            else
                expr+=".$part"
            fi
        done
        jq -r "$expr" "$file" 2>/dev/null
        return 0
    fi
    case "$path" in
        server_port) sed -n 's/.*"server_port": \([0-9][0-9]*\).*/\1/p' "$file" | head -n1 ;;
        method) sed -n 's/.*"method": "\([^"]*\)".*/\1/p' "$file" | head -n1 ;;
        password) sed -n 's/.*"password": "\([^"]*\)".*/\1/p' "$file" | head -n1 ;;
        inbounds.0.port) sed -n 's/.*"port": \([0-9][0-9]*\).*/\1/p' "$file" | head -n1 ;;
        inbounds.0.settings.clients.0.id) sed -n 's/.*"id": "\([^"]*\)".*/\1/p' "$file" | head -n1 ;;
        inbounds.0.streamSettings.realitySettings.serverNames.0) sed -n 's/.*"serverNames": \["\([^"]*\)"\].*/\1/p' "$file" | head -n1 ;;
        inbounds.0.streamSettings.realitySettings.privateKey) sed -n 's/.*"privateKey": "\([^"]*\)".*/\1/p' "$file" | head -n1 ;;
        inbounds.0.streamSettings.realitySettings.shortIds.0) sed -n 's/.*"shortIds": \["\([^"]*\)"\].*/\1/p' "$file" | head -n1 ;;
        *) return 1 ;;
    esac
}


normalize_xray_x25519_output() {
    printf '%s' "$1" | tr -d '\r' | perl -pe 's/(Private\s*[Kk]ey:|Public\s*[Kk]ey:|Password:|Hash32:)/\n$1/g' | sed '/^[[:space:]]*$/d'
}

xray_extract_reality_private_key() {
    local raw norm
    raw="$1"
    norm=$(normalize_xray_x25519_output "$raw")
    printf '%s\n' "$norm" | sed -nE 's/^[[:space:]]*Private([[:space:]]*[Kk]ey|Key):[[:space:]]*//p' | head -n1 | tr -d '[:space:]'
}

xray_extract_reality_public_key() {
    local raw norm
    raw="$1"
    norm=$(normalize_xray_x25519_output "$raw")
    {
        printf '%s\n' "$norm" | sed -nE 's/^[[:space:]]*Public([[:space:]]*[Kk]ey|Key):[[:space:]]*//p'
        printf '%s\n' "$norm" | sed -nE 's/^[[:space:]]*Password:[[:space:]]*//p'
    } | head -n1 | tr -d '[:space:]'
}

json_set_top_value() {
    local file="$1" key="$2" value="$3" kind="$4"
    [[ -f "$file" ]] || return 1
    if have_cmd python3; then
        python3 - "$file" "$key" "$value" "$kind" <<'PYPARSE'
import json, sys
file, key, value, kind = sys.argv[1:5]
with open(file, 'r', encoding='utf-8') as f:
    obj = json.load(f)
obj[key] = int(value) if kind == 'number' else value
with open(file, 'w', encoding='utf-8') as f:
    json.dump(obj, f, ensure_ascii=False)
PYPARSE
        return 0
    fi
    if [[ "$kind" == "number" ]]; then
        sed -i "s|\"${key}\": [0-9][0-9]*|\"${key}\": ${value}|g" "$file"
    else
        local esc
        esc=$(printf '%s' "$value" | sed 's/[&]/\\&/g')
        sed -i "s|\"${key}\": \"[^\"]*\"|\"${key}\": \"${esc}\"|g" "$file"
    fi
}


uri_encode() {
    local raw="$1"
    if have_cmd python3; then
        python3 - "$raw" <<'PYURL'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PYURL
        return 0
    fi
    local out="" i ch hex
    for ((i=0; i<${#raw}; i++)); do
        ch="${raw:i:1}"
        case "$ch" in
            [a-zA-Z0-9.~_-]) out+="$ch" ;;
            *) printf -v hex '%%%02X' "'${ch}"; out+="$hex" ;;
        esac
    done
    printf '%s' "$out"
}

ss_make_userinfo() {
    local method="$1" password="$2"
    if [[ "$method" == 2022-* ]]; then
        printf '%s:%s' "$(uri_encode "$method")" "$(uri_encode "$password")"
    else
        printf '%s' "${method}:${password}" | base64_nw
    fi
}

shadowtls_state_file() {
    printf '%s/%s.conf' "$SHADOWTLS_STATE_DIR" "$1"
}

shadowtls_state_save() {
    local port="$1" up_port="$2" sni="$3" password="$4"
    mkdir -p "$SHADOWTLS_STATE_DIR" 2>/dev/null || true
    cat > "$(shadowtls_state_file "$port")" <<EOF
LISTEN_PORT="$port"
UPSTREAM_PORT="$up_port"
SNI="$sni"
PASSWORD="$password"
VERSION="3"
EOF
    chmod 600 "$(shadowtls_state_file "$port")" 2>/dev/null || true
}

shadowtls_state_get() {
    local port="$1" key="$2" file
    file="$(shadowtls_state_file "$port")"
    [[ -f "$file" ]] || return 1
    grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 | cut -d= -f2- | sed 's/^"//; s/"$//'
}

shadowtls_parse_field_from_text() {
    local text="$1" key="$2"
    case "$key" in
        UPSTREAM_PORT) printf '%s\n' "$text" | sed -n 's/.*--server 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' | head -n1 ;;
        SNI) printf '%s\n' "$text" | sed -n 's/.*--tls \([^: ;][^ ;]*\)\(:[0-9][0-9]*\)\?.*/\1/p' | head -n1 ;;
        PASSWORD) printf '%s\n' "$text" | sed -n 's/.*--password \([^ ]*\).*/\1/p' | head -n1 ;;
        *) return 1 ;;
    esac
}

shadowtls_get_field() {
    local port="$1" key="$2" v="" unit="/etc/systemd/system/shadowtls-${port}.service" pid cmd
    v="$(shadowtls_state_get "$port" "$key" 2>/dev/null || true)"
    if [[ -z "$v" && -f "$unit" ]]; then
        cmd="$(sed -n 's/^ExecStart=//p' "$unit" | head -n1)"
        v="$(shadowtls_parse_field_from_text "$cmd" "$key" 2>/dev/null || true)"
    fi
    if [[ -z "$v" && -f "/var/run/shadowtls-${port}.pid" ]]; then
        pid="$(cat "/var/run/shadowtls-${port}.pid" 2>/dev/null || true)"
        if [[ -n "$pid" && -r "/proc/${pid}/cmdline" ]]; then
            cmd="$(tr '\\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)"
            v="$(shadowtls_parse_field_from_text "$cmd" "$key" 2>/dev/null || true)"
        fi
    fi
    [[ -n "$v" ]] && printf '%s' "$v"
}

shadowtls_detect_ports() {
    {
        for f in "$SHADOWTLS_STATE_DIR"/*.conf; do
            [[ -e "$f" ]] || continue
            basename "$f" .conf
        done
        for f in /etc/systemd/system/shadowtls-*.service /lib/systemd/system/shadowtls-*.service /usr/lib/systemd/system/shadowtls-*.service; do
            [[ -e "$f" ]] || continue
            basename "$f" | sed 's/^shadowtls-//; s/\.service$//'
        done
        for f in /var/run/shadowtls-*.pid; do
            [[ -e "$f" ]] || continue
            basename "$f" | sed 's/^shadowtls-//; s/\.pid$//'
        done
    } | awk '/^[0-9]+$/' | sort -n -u
}

shadowtls_find_ports_by_upstream() {
    local upstream="$1" p up
    [[ -n "$upstream" ]] || return 0
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        up="$(shadowtls_get_field "$p" UPSTREAM_PORT 2>/dev/null || true)"
        [[ "$up" == "$upstream" ]] && printf '%s
' "$p"
    done < <(shadowtls_detect_ports)
}

shadowtls_is_active() {
    local port="$1" pid
    if service_use_systemd && systemctl is-active --quiet "shadowtls-${port}" 2>/dev/null; then
        return 0
    fi
    if [[ -f "/var/run/shadowtls-${port}.pid" ]]; then
        pid="$(cat "/var/run/shadowtls-${port}.pid" 2>/dev/null || true)"
        [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && return 0
    fi
    pgrep -f "/usr/local/bin/shadow-tls --v3 --strict server --listen 0.0.0.0:${port}" >/dev/null 2>&1
}

port_listening_tcp() {
    local port="$1"
    if have_cmd ss; then
        ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:|\])${port}$"
    elif have_cmd netstat; then
        netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:|\])${port}$"
    else
        return 1
    fi
}

shadowtls_make_ss_link() {
    local listen_port="$1" ip method password st_sni st_pwd plugin_raw plugin_enc userinfo
    ip="${2:-$(ssr_fetch_public_ip)}"
    method=$(json_get_path /etc/ss-rust/config.json method 2>/dev/null)
    password=$(json_get_path /etc/ss-rust/config.json password 2>/dev/null)
    st_sni="$(shadowtls_get_field "$listen_port" SNI 2>/dev/null || true)"
    st_pwd="$(shadowtls_get_field "$listen_port" PASSWORD 2>/dev/null || true)"
    [[ -n "$ip" && -n "$listen_port" && -n "$method" && -n "$password" && -n "$st_sni" && -n "$st_pwd" ]] || return 1
    userinfo="$(ss_make_userinfo "$method" "$password")"
    plugin_raw="shadow-tls;host=${st_sni};passwd=${st_pwd};v3"
    plugin_enc="$(uri_encode "$plugin_raw")"
    printf 'ss://%s@%s:%s/?plugin=%s#SS-Rust-ShadowTLS' "$userinfo" "$ip" "$listen_port" "$plugin_enc"
}

show_shadowtls_summary() {
    local listen_port="$1" ip up_port sni pwd link
    ip=$(ssr_fetch_public_ip)
    up_port="$(shadowtls_get_field "$listen_port" UPSTREAM_PORT 2>/dev/null || true)"
    sni="$(shadowtls_get_field "$listen_port" SNI 2>/dev/null || true)"
    pwd="$(shadowtls_get_field "$listen_port" PASSWORD 2>/dev/null || true)"
    link="$(shadowtls_make_ss_link "$listen_port" "$ip" 2>/dev/null || true)"
    echo -e "外层端口: ${GREEN}${listen_port:-未读取}${RESET}"
    echo -e "上游端口: ${GREEN}${up_port:-未读取}${RESET}"
    echo -e "SNI: ${GREEN}${sni:-未读取}${RESET}"
    echo -e "ShadowTLS 密码: ${GREEN}${pwd:-未读取}${RESET}"
    [[ -n "$link" ]] && echo -e "${YELLOW}链接:${RESET}\n${link}"
}

ssr_fetch_public_ip() {
    curl -s4m8 ip.sb 2>/dev/null || curl -s4m8 ifconfig.me 2>/dev/null || curl -s6m8 ip.sb 2>/dev/null || echo "0.0.0.0"
}

ssr_make_ss_link() {
    local ip port method password userinfo
    ip="${1:-$(ssr_fetch_public_ip)}"
    port=$(json_get_path /etc/ss-rust/config.json server_port 2>/dev/null)
    method=$(json_get_path /etc/ss-rust/config.json method 2>/dev/null)
    password=$(json_get_path /etc/ss-rust/config.json password 2>/dev/null)
    [[ -n "$ip" && -n "$port" && -n "$method" && -n "$password" ]] || return 1
    userinfo=$(ss_make_userinfo "$method" "$password")
    printf 'ss://%s@%s:%s#SS-Rust' "$userinfo" "$ip" "$port"
}

show_ss_rust_summary() {
    local ip port method password link st_link p found_st=0
    local protected_ports=()
    ip=$(ssr_fetch_public_ip)
    port=$(json_get_path /etc/ss-rust/config.json server_port 2>/dev/null)
    method=$(json_get_path /etc/ss-rust/config.json method 2>/dev/null)
    password=$(json_get_path /etc/ss-rust/config.json password 2>/dev/null)
    link=$(ssr_make_ss_link "$ip" 2>/dev/null || true)
    mapfile -t protected_ports < <(shadowtls_find_ports_by_upstream "$port")
    echo -e "IP: ${GREEN}${ip}${RESET}"
    echo -e "端口: ${GREEN}${port:-未读取}${RESET}"
    echo -e "协议: ${GREEN}${method:-未读取}${RESET}"
    echo -e "密码: ${GREEN}${password:-未读取}${RESET}"
    if [[ ${#protected_ports[@]} -gt 0 ]]; then
        echo -e "${GREEN}ShadowTLS 保护:${RESET} 已检测到 ${#protected_ports[@]} 个外层入口"
        for p in "${protected_ports[@]}"; do
            [[ -n "$p" ]] || continue
            st_link="$(shadowtls_make_ss_link "$p" "$ip" 2>/dev/null || true)"
            echo -e "  - 外层端口: ${GREEN}${p}${RESET}"
            if [[ -n "$st_link" ]]; then
                echo -e "${YELLOW}ShadowTLS 链接:${RESET}
${st_link}"
                found_st=1
            else
                echo -e "${RED}ShadowTLS 链接生成失败，请检查该实例状态。${RESET}"
            fi
        done
        echo -e "${CYAN}说明:${RESET} 以上为优先使用的 ShadowTLS 链接；下方为直连 SS2022 链接（仅在需要直连时使用）。"
    fi
    [[ -n "$link" ]] && echo -e "${YELLOW}直连 SS-Rust 链接:${RESET}
${link}"
}

show_vless_summary() {
    local ip port uuid sni priv pub sid link
    ip=$(ssr_fetch_public_ip)
    port=$(json_get_path /usr/local/etc/xray/config.json inbounds.0.port 2>/dev/null)
    uuid=$(json_get_path /usr/local/etc/xray/config.json inbounds.0.settings.clients.0.id 2>/dev/null)
    sni=$(json_get_path /usr/local/etc/xray/config.json inbounds.0.streamSettings.realitySettings.serverNames.0 2>/dev/null)
    priv=$(json_get_path /usr/local/etc/xray/config.json inbounds.0.streamSettings.realitySettings.privateKey 2>/dev/null)
    sid=$(json_get_path /usr/local/etc/xray/config.json inbounds.0.streamSettings.realitySettings.shortIds.0 2>/dev/null)
    if [[ -n "$priv" && -x /usr/local/bin/xray ]]; then
        pub=$(xray_extract_reality_public_key "$(/usr/local/bin/xray x25519 -i "$priv" 2>/dev/null || true)")
    fi
    echo -e "IP: ${GREEN}${ip}${RESET}"
    echo -e "端口: ${GREEN}${port:-未读取}${RESET}"
    echo -e "UUID: ${GREEN}${uuid:-未读取}${RESET}"
    echo -e "SNI: ${GREEN}${sni:-未读取}${RESET}"
    if [[ -n "$ip" && -n "$port" && -n "$uuid" && -n "$sni" && -n "$pub" && -n "$sid" ]]; then
        link="vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${sid}&type=tcp&headerType=none#VLESS-Reality"
        echo -e "${YELLOW}链接:${RESET}
${link}"
    fi
}

start_managed_service() {
    local name="$1" unit_content="$2" bg_cmd="$3" bg_match="$4" log_file="$5" pid_file="$6"
    if service_use_systemd; then
        mkdir -p /etc/systemd/system 2>/dev/null || true
        printf '%s
' "$unit_content" > "/etc/systemd/system/${name}.service"
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable --now "$name" >/dev/null 2>&1 || return 1
        systemctl is-active --quiet "$name" 2>/dev/null || return 1
    else
        [[ -n "$bg_match" ]] && pkill -f "$bg_match" 2>/dev/null || true
        mkdir -p "$(dirname "$pid_file")" 2>/dev/null || true
        nohup sh -c "$bg_cmd" >"$log_file" 2>&1 &
        echo $! > "$pid_file"
        sleep 1
        kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null || return 1
    fi
}

restart_managed_service() {
    local name="$1" bg_cmd="$2" bg_match="$3" log_file="$4" pid_file="$5"
    if service_use_systemd; then
        systemctl restart "$name" >/dev/null 2>&1 || return 1
        systemctl is-active --quiet "$name" 2>/dev/null || return 1
    else
        [[ -n "$bg_match" ]] && pkill -f "$bg_match" 2>/dev/null || true
        mkdir -p "$(dirname "$pid_file")" 2>/dev/null || true
        nohup sh -c "$bg_cmd" >"$log_file" 2>&1 &
        echo $! > "$pid_file"
        sleep 1
        kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null || return 1
    fi
}

stop_managed_service() {
    local name="$1" bg_match="$2" pid_file="$3"
    if service_use_systemd; then
        systemctl stop "$name" >/dev/null 2>&1 || true
        systemctl disable "$name" >/dev/null 2>&1 || true
    fi
    [[ -n "$bg_match" ]] && pkill -f "$bg_match" 2>/dev/null || true
    rm -f "$pid_file" 2>/dev/null || true
}

system_memory_mb() {
    awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null
}

system_cpu_count() {
    getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
}

is_private_ipv4() {
    case "$1" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
        *) return 1 ;;
    esac
}

current_ipv4_for_route() {
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}


detect_machine_tier() {
    local mem cpu
    mem="$(system_memory_mb)"
    cpu="$(system_cpu_count)"
    [[ -z "$mem" ]] && mem=1024
    if (( mem < 1024 || cpu <= 1 )); then
        echo tiny
    elif (( mem < 4096 )); then
        echo small
    elif (( mem < 8192 )); then
        echo medium
    else
        echo large
    fi
}

profile_alias() {
    case "$1" in
        perf|extreme) echo perf ;;
        stable) echo stable ;;
        *) echo stable ;;
    esac
}

profile_title() {
    [[ "$(profile_alias "$1")" == "perf" ]] && echo "极致优化" || echo "稳定优先"
}

best_congestion_control() {
    local avail
    avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    for cc in bbr cubic reno; do
        echo " $avail " | grep -q " ${cc} " && { echo "$cc"; return 0; }
    done
    echo bbr
}

measure_host_latency_ms() {
    local host="$1"
    have_cmd ping || return 1
    ping -4 -n -c 1 -W 1 "$host" 2>/dev/null | awk -F'time=' '/time=/{print $2}' | awk '{print int($1+0.5)}' | head -n 1
}

select_best_dns_pair() {
    local mode="$(profile_alias "${1:-stable}")"
    local candidates=() pair primary secondary lat1 lat2 score
    local best_pair="" best_score=999999

    if [[ "$mode" == "perf" ]]; then
        candidates=(
            "1.1.1.1 1.0.0.1"
            "223.5.5.5 223.6.6.6"
            "119.29.29.29 182.254.116.116"
            "9.9.9.9 149.112.112.112"
            "8.8.8.8 8.8.4.4"
        )
    else
        candidates=(
            "223.5.5.5 223.6.6.6"
            "119.29.29.29 182.254.116.116"
            "1.1.1.1 1.0.0.1"
            "9.9.9.9 149.112.112.112"
            "8.8.8.8 8.8.4.4"
        )
    fi

    for pair in "${candidates[@]}"; do
        primary="${pair%% *}"
        secondary="${pair##* }"
        lat1="$(measure_host_latency_ms "$primary")"
        [[ -z "$lat1" ]] && continue
        lat2="$(measure_host_latency_ms "$secondary")"
        [[ -z "$lat2" ]] && lat2=$lat1
        score=$((lat1 + lat2))
        if (( score < best_score )); then
            best_score=$score
            best_pair="$pair"
        fi
    done

    [[ -n "$best_pair" ]] && echo "$best_pair" || echo "223.5.5.5 223.6.6.6"
}

smart_dns_apply() {
    local mode="$(profile_alias "${1:-stable}")"
    local dns_action="${2:-auto}"
    local pair d1 d2 actual_action

    pair="$(select_best_dns_pair "$mode")"
    d1="${pair%% *}"
    d2="${pair##* }"

    if [[ "$dns_action" == "auto" ]]; then
        [[ "$mode" == "perf" ]] && actual_action=lock || actual_action=set
    else
        actual_action="$dns_action"
    fi

    dns_backup
    if [[ -L /etc/resolv.conf ]] && readlink -f /etc/resolv.conf 2>/dev/null | grep -q '/run/systemd/resolve/'; then
        dns_apply_systemd_resolved_custom "$d1" "$d2"
        [[ "$actual_action" == "lock" ]] && chattr +i /etc/resolv.conf 2>/dev/null || true
    else
        dns_apply_resolvconf_custom "$actual_action" "$d1" "$d2"
    fi

    meta_set "DNS_SELECTED" "${d1},${d2}"
    echo -e "${GREEN}✅ 已自动选择 DNS: ${d1} ${d2} (${actual_action})${RESET}"
}

render_sysctl_profile() {
    local target="$1" env="$2" mode="$(profile_alias "$3")" tier="${4:-medium}" cc
    local rmax wmax rmem wmem somax backlog filemax fin_timeout keepalive_time keepalive_intvl keepalive_probes
    cc="$(best_congestion_control)"
    keepalive_time=60; keepalive_intvl=20; keepalive_probes=3

    case "${env}:${mode}:${tier}" in
        regular:stable:tiny|regular:stable:small)
            rmax=8388608;  wmax=8388608;  rmem=8388608;  wmem=8388608;  somax=4096;  backlog=4096;  filemax=262144; fin_timeout=30 ;;
        regular:stable:medium)
            rmax=16777216; wmax=16777216; rmem=16777216; wmem=16777216; somax=8192;  backlog=8192;  filemax=524288; fin_timeout=30 ;;
        regular:stable:large)
            rmax=33554432; wmax=33554432; rmem=33554432; wmem=33554432; somax=16384; backlog=16384; filemax=524288; fin_timeout=30 ;;
        regular:perf:tiny|regular:perf:small)
            rmax=16777216; wmax=16777216; rmem=16777216; wmem=16777216; somax=16384; backlog=16384; filemax=524288; fin_timeout=20 ;;
        regular:perf:medium)
            rmax=33554432; wmax=33554432; rmem=33554432; wmem=33554432; somax=32768; backlog=32768; filemax=1048576; fin_timeout=20 ;;
        regular:perf:large)
            rmax=67108864; wmax=67108864; rmem=67108864; wmem=67108864; somax=65535; backlog=65535; filemax=1048576; fin_timeout=15 ;;
        nat:stable:tiny|nat:stable:small)
            rmax=8388608;  wmax=8388608;  rmem=8388608;  wmem=8388608;  somax=4096;  backlog=8192;  filemax=262144; fin_timeout=30 ;;
        nat:stable:medium|nat:stable:large)
            rmax=16777216; wmax=16777216; rmem=16777216; wmem=16777216; somax=8192;  backlog=16384; filemax=262144; fin_timeout=30 ;;
        nat:perf:tiny|nat:perf:small)
            rmax=16777216; wmax=16777216; rmem=16777216; wmem=16777216; somax=8192;  backlog=16384; filemax=262144; fin_timeout=15 ;;
        nat:perf:medium)
            rmax=33554432; wmax=33554432; rmem=33554432; wmem=33554432; somax=16384; backlog=32768; filemax=524288; fin_timeout=15 ;;
        nat:perf:large)
            rmax=33554432; wmax=33554432; rmem=33554432; wmem=33554432; somax=32768; backlog=32768; filemax=524288; fin_timeout=15 ;;
        *)
            rmax=16777216; wmax=16777216; rmem=16777216; wmem=16777216; somax=8192; backlog=8192; filemax=524288; fin_timeout=30 ;;
    esac

    cat > "$target" <<EOF
# ssr ${env} $(profile_title "$mode")
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${cc}
net.ipv4.tcp_mtu_probing = 1
net.core.rmem_max = ${rmax}
net.core.wmem_max = ${wmax}
net.ipv4.tcp_rmem = 8192 262144 ${rmem}
net.ipv4.tcp_wmem = 8192 262144 ${wmem}
net.core.somaxconn = ${somax}
net.core.netdev_max_backlog = ${backlog}
fs.file-max = ${filemax}
net.ipv4.tcp_fin_timeout = ${fin_timeout}
net.ipv4.tcp_fastopen = 3
EOF

    if [[ "$env" == "nat" ]]; then
        cat >> "$target" <<EOF
net.ipv4.tcp_keepalive_time = ${keepalive_time}
net.ipv4.tcp_keepalive_intvl = ${keepalive_intvl}
net.ipv4.tcp_keepalive_probes = ${keepalive_probes}
EOF
    fi

    if [[ "$mode" == "perf" ]]; then
        cat >> "$target" <<'EOF'
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_notsent_lowat = 16384
EOF
    fi
}

sysctl_key_supported() {
    local key="$1"
    [[ -e "/proc/sys/${key//./\/}" ]]
}

filter_supported_sysctl_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local tmp
    tmp="$(mktemp)"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line//[[:space:]]/}" ]]; then
            echo "$line" >> "$tmp"
            continue
        fi
        local key="${line%%=*}"
        key="$(echo "$key" | xargs 2>/dev/null || echo "$key")"
        if sysctl_key_supported "$key"; then
            echo "$line" >> "$tmp"
        else
            echo "# unsupported: $line" >> "$tmp"
        fi
    done < "$file"
    mv -f "$tmp" "$file"
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
    local repo="$1" body="" tag=""
    [[ -n "$repo" ]] || return 1
    if have_cmd curl; then
        body=$(curl -fsSL --max-time 10 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null || true)
    fi
    if [[ -n "$body" ]] && have_cmd jq; then
        tag=$(printf '%s' "$body" | jq -r '.tag_name // empty' 2>/dev/null)
    fi
    if [[ -z "$tag" && -n "$body" ]]; then
        tag=$(printf '%s' "$body" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*//p' | head -n1)
    fi
    [[ -n "$tag" && "$tag" != "null" ]] && echo "$tag"
}

github_release_asset_url() {
    # github_release_asset_url "owner/repo" "tag" "asset_name"
    local repo="$1" tag="$2" asset_name="$3" body="" url=""
    [[ -n "$repo" && -n "$tag" && -n "$asset_name" ]] || return 1
    have_cmd curl || return 1
    body=$(curl -fsSL --max-time 12 "https://api.github.com/repos/${repo}/releases/tags/${tag}" 2>/dev/null || true)
    [[ -n "$body" ]] || return 1
    if have_cmd jq; then
        url=$(printf '%s' "$body" | jq -r --arg name "$asset_name" '.assets[]? | select(.name==$name) | .browser_download_url // empty' 2>/dev/null | head -n1)
    fi
    if [[ -z "$url" ]] && have_cmd python3; then
        url=$(python3 - "$asset_name" "$body" <<'PYURL'
import json, sys
asset = sys.argv[1]
body = sys.argv[2]
try:
    data = json.loads(body)
    for item in data.get('assets', []):
        if item.get('name') == asset and item.get('browser_download_url'):
            print(item['browser_download_url'])
            break
except Exception:
    pass
PYURL
)
    fi
    [[ -n "$url" ]] && echo "$url"
}

download_file_any() {
    # download_file_any DEST URL1 URL2 ...
    local dest="$1"; shift
    local u=""
    for u in "$@"; do
        [[ -n "$u" ]] || continue
        if download_file "$u" "$dest" && [[ -s "$dest" ]]; then
            return 0
        fi
        rm -f "$dest" 2>/dev/null || true
    done
    return 1
}

shadowtls_arch_name() {
    local arch="$1"
    case "$arch" in
        x86_64|amd64) echo "x86_64-unknown-linux-musl" ;;
        aarch64|arm64) echo "aarch64-unknown-linux-musl" ;;
        armv7l|armv7|arm) echo "arm-unknown-linux-musleabi" ;;
        *) return 1 ;;
    esac
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
    local deps=(curl bc wget tar openssl unzip ip ping)
    local missing=()
    local dep
    for dep in "${deps[@]}"; do
        have_cmd "$dep" || missing+=("$dep")
    done

    if ((${#missing[@]} > 0)); then
        if have_cmd apt-get; then
            apt-get update -qq >/dev/null 2>&1 || true
            apt-get install -yqq curl jq bc wget tar xz-utils openssl unzip util-linux e2fsprogs iproute2 iputils-ping python3 coreutils >/dev/null 2>&1 || true
        elif have_cmd dnf; then
            dnf install -y curl jq bc wget tar xz openssl unzip util-linux e2fsprogs iproute iputils python3 coreutils >/dev/null 2>&1 || true
        elif have_cmd yum; then
            yum install -yq curl jq bc wget tar xz openssl unzip util-linux e2fsprogs iproute iputils python3 coreutils >/dev/null 2>&1 || true
        elif have_cmd apk; then
            apk add --no-cache curl jq bc wget tar xz openssl unzip util-linux e2fsprogs iproute2 iputils python3 coreutils >/dev/null 2>&1 || true
        fi
    fi
}

install_global_command() {
    # 兼容旧逻辑：不再创建 /usr/local/bin/ssr 快捷命令
    # 统一由综合脚本 my 负责命令入口与定时任务。
    if declare -F my_enable_ssr_cron_tasks >/dev/null 2>&1; then
        my_enable_ssr_cron_tasks
    fi
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
    local target="$1" from_menu="$2"
    local port="" pidfile="" target_desc="$1"
    if [[ -z "$target" ]]; then
        echo -e "${RED}❌ 目标服务名为空！${RESET}"
        [[ "$from_menu" == "menu" ]] && { sleep 2; return; } || exit 1
    fi

    echo -e "${RED}☢️ 正在执行全链路强制核爆: ${target} ...${RESET}"

    if service_use_systemd; then
        systemctl stop "$target" 2>/dev/null || true
        systemctl disable "$target" 2>/dev/null || true
    fi
    have_cmd service && service "$target" stop >/dev/null 2>&1 || true
    have_cmd rc-service && rc-service "$target" stop >/dev/null 2>&1 || true

    case "$target" in
        ss-rust)
            port="$(json_get_path /etc/ss-rust/config.json server_port 2>/dev/null || true)"
            [[ "$port" =~ ^[0-9]+$ ]] && remove_firewall_rule "$port" "both"
            pidfile="/var/run/ss-rust.pid"
            pkill -9 -f '/usr/local/bin/ss-rust -c /etc/ss-rust/config.json' 2>/dev/null || true
            pkill -9 -x ss-rust 2>/dev/null || true
            rm -rf /etc/ss-rust
            rm -f /usr/local/bin/ss-rust /var/log/ss-rust.log
            ;;
        xray)
            port="$(json_get_path /usr/local/etc/xray/config.json inbounds.0.port 2>/dev/null || true)"
            [[ "$port" =~ ^[0-9]+$ ]] && remove_firewall_rule "$port" "tcp"
            pidfile="/var/run/xray.pid"
            pkill -9 -f '/usr/local/bin/xray run -c /usr/local/etc/xray/config.json' 2>/dev/null || true
            pkill -9 -x xray 2>/dev/null || true
            rm -rf /usr/local/etc/xray
            rm -f /usr/local/bin/xray /var/log/xray.log
            ;;
        shadowtls-generic)
            pkill -9 -f '/usr/local/bin/shadow-tls' 2>/dev/null || true
            rm -f /usr/local/bin/shadow-tls /var/log/shadowtls.log
            ;;
        shadowtls-*)
            port="${target#shadowtls-}"
            [[ "$port" =~ ^[0-9]+$ ]] && remove_firewall_rule "$port" "tcp"
            pidfile="/var/run/${target}.pid"
            pkill -9 -f "shadowtls-${port}" 2>/dev/null || true
            pkill -9 -f '/usr/local/bin/shadow-tls' 2>/dev/null || true
            rm -f "/var/log/${target}.log"
            ;;
        *)
            pkill -9 -f "$target" 2>/dev/null || true
            ;;
    esac

    if [[ -n "$pidfile" && -f "$pidfile" ]]; then
        kill -9 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null || true
        rm -f "$pidfile"
    fi

    rm -f \
        "/etc/systemd/system/${target}.service" \
        "/etc/systemd/system/${target}" \
        "/lib/systemd/system/${target}.service" \
        "/lib/systemd/system/${target}" \
        "/usr/lib/systemd/system/${target}.service" \
        "/usr/lib/systemd/system/${target}"

    if service_use_systemd; then
        systemctl reset-failed "$target" >/dev/null 2>&1 || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    if [[ "$target" == shadowtls-* || "$target" == "shadowtls-generic" ]]; then
        if ! ls /etc/systemd/system/shadowtls-*.service /lib/systemd/system/shadowtls-*.service /usr/lib/systemd/system/shadowtls-*.service >/dev/null 2>&1; then
            rm -f /usr/local/bin/shadow-tls
        fi
    fi

    echo -e "${GREEN}✅ 目标服务 [${target_desc}] 已被强制清理完成！${RESET}"
    [[ "$from_menu" == "menu" ]] && sleep 2 || exit 0
}

nuke_index_has_target() {
    local needle="$1" i
    for i in "${NUCLEAR_TARGETS[@]}"; do
        [[ "$i" == "$needle" ]] && return 0
    done
    return 1
}

managed_nuke_build_index() {
    NUCLEAR_TARGETS=()
    NUCLEAR_LABELS=()
    NUCLEAR_PORTS=()
    local idx=1 port unit target

    port="$(json_get_path /etc/ss-rust/config.json server_port 2>/dev/null || true)"
    if [[ -f /etc/ss-rust/config.json || -x /usr/local/bin/ss-rust || -f /etc/systemd/system/ss-rust.service || -f /var/run/ss-rust.pid ]] || pgrep -f '/usr/local/bin/ss-rust' >/dev/null 2>&1; then
        NUCLEAR_TARGETS[$idx]="ss-rust"
        NUCLEAR_LABELS[$idx]="SS-Rust"
        NUCLEAR_PORTS[$idx]="$port"
        ((idx++))
    fi

    port="$(json_get_path /usr/local/etc/xray/config.json inbounds.0.port 2>/dev/null || true)"
    if [[ -f /usr/local/etc/xray/config.json || -x /usr/local/bin/xray || -f /etc/systemd/system/xray.service || -f /var/run/xray.pid ]] || pgrep -f '/usr/local/bin/xray' >/dev/null 2>&1; then
        NUCLEAR_TARGETS[$idx]="xray"
        NUCLEAR_LABELS[$idx]="Xray / VLESS Reality"
        NUCLEAR_PORTS[$idx]="$port"
        ((idx++))
    fi

    for unit in /etc/systemd/system/shadowtls-*.service /lib/systemd/system/shadowtls-*.service /usr/lib/systemd/system/shadowtls-*.service; do
        [[ -e "$unit" ]] || continue
        port="$(basename "$unit" | sed 's/^shadowtls-//' | sed 's/\.service$//')"
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        target="shadowtls-${port}"
        if ! nuke_index_has_target "$target"; then
            NUCLEAR_TARGETS[$idx]="$target"
            NUCLEAR_LABELS[$idx]="ShadowTLS 实例"
            NUCLEAR_PORTS[$idx]="$port"
            ((idx++))
        fi
    done

    if [[ -x /usr/local/bin/shadow-tls ]] && ! pgrep -f '/usr/local/bin/shadow-tls' >/dev/null 2>&1 && ! ls /etc/systemd/system/shadowtls-*.service /lib/systemd/system/shadowtls-*.service /usr/lib/systemd/system/shadowtls-*.service >/dev/null 2>&1; then
        NUCLEAR_TARGETS[$idx]="shadowtls-generic"
        NUCLEAR_LABELS[$idx]="ShadowTLS 残留二进制"
        NUCLEAR_PORTS[$idx]=""
    fi
}

# ==============================================================================
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


dns_apply_resolvconf_custom() {
    # dns_apply_resolvconf_custom set|lock <dns1> [dns2...]
    local lock_mode="$1"; shift
    # 解除不可变
    if have_cmd chattr; then chattr -i /etc/resolv.conf 2>/dev/null || true; fi

    : > /etc/resolv.conf
    local ip
    for ip in "$@"; do
        [[ -n "$ip" ]] && echo "nameserver $ip" >> /etc/resolv.conf
    done

    if [[ "$lock_mode" == "lock" ]] && have_cmd chattr; then
        chattr +i /etc/resolv.conf 2>/dev/null || true
    fi
}

dns_apply_systemd_resolved_custom() {
    # dns_apply_systemd_resolved_custom <dns1> [dns2...]
    local dns_list="$*"
    mkdir -p /etc/systemd/resolved.conf.d
    cat > "$RESOLVED_DROPIN" << EOF
[Resolve]
DNS=${dns_list}
FallbackDNS=9.9.9.9 149.112.112.112
DNSSEC=no
EOF
    chmod 644 "$RESOLVED_DROPIN" 2>/dev/null || true
    systemctl restart systemd-resolved 2>/dev/null || true
}

dns_manual_set() {
    dns_backup
    clear
    echo -e "${CYAN}========= 手动设置 DNS =========${RESET}"
    echo -e "请输入 DNS 服务器地址（空格/逗号分隔），例如：${YELLOW}1.1.1.1 8.8.8.8${RESET}"
    echo -e "支持 IPv4/IPv6；留空回车取消。\n"
    local dns_line
    read -rp "DNS: " dns_line
    dns_line="${dns_line//,/ }"
    dns_line="$(echo "$dns_line" | xargs 2>/dev/null || echo "$dns_line")"
    [[ -z "$dns_line" ]] && echo -e "${YELLOW}已取消。${RESET}" && return 1

    local arr=()
    local ip
    for ip in $dns_line; do
        if is_ipv4 "$ip" || [[ "$ip" == *:* ]]; then
            arr+=("$ip")
        else
            echo -e "${RED}❌ 无效 DNS 地址: ${ip}${RESET}"
            return 1
        fi
    done
    [[ "${#arr[@]}" -eq 0 ]] && echo -e "${RED}❌ 未输入有效 DNS。${RESET}" && return 1

    local lock_mode="set"
    if [[ ! -L /etc/resolv.conf ]]; then
        read -rp "是否锁定 /etc/resolv.conf（chattr +i，防止被覆盖）? [y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] && lock_mode="lock"
    fi

    if [[ -L /etc/resolv.conf ]]; then
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            dns_apply_systemd_resolved_custom "${arr[@]}"
        else
            echo -e "${YELLOW}⚠️ 检测到 /etc/resolv.conf 为 symlink，但 systemd-resolved 未运行。"
            echo -e "   建议：启用 systemd-resolved 或将 resolv.conf 变为普通文件后再设置。${RESET}"
            return 1
        fi
    else
        dns_apply_resolvconf_custom "$lock_mode" "${arr[@]}"
    fi
    return 0
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
        echo -e "${GREEN} 1.${RESET} 查看 DNS 状态"
        echo -e "${GREEN} 2.${RESET} 智能选优：稳定优先"
        echo -e "${GREEN} 3.${RESET} 智能选优：极致优化"
        echo -e "${YELLOW} 4.${RESET} 一键设置标准 DNS（不锁）"
        echo -e "${YELLOW} 5.${RESET} 手动设置 DNS（自定义）"
        echo -e "${YELLOW} 6.${RESET} 锁定 DNS（尽可能稳健）"
        echo -e "${YELLOW} 7.${RESET} 一键解锁并恢复（回滚至备份）"
        echo -e " 0. 返回"
        read -rp "输入 [0-7]: " dn
        case "$dn" in
            1)
                clear
                dns_status
                echo ""
                read -n 1 -s -r -p "按任意键返回..."
                ;;
            2|3)
                local profile="stable" dns_mode
                [[ "$dn" == "3" ]] && profile="extreme"
                read -rp "DNS 模式 [auto/set/lock, 回车 auto]: " dns_mode
                smart_dns_apply "$profile" "${dns_mode:-auto}"
                sleep 2
                ;;
            4)
                dns_set_or_lock "set" && echo -e "${GREEN}✅ DNS 已设置。${RESET}" || echo -e "${YELLOW}⚠️ 未修改 DNS。${RESET}"
                sleep 2
                ;;
            5)
                dns_manual_set && echo -e "${GREEN}✅ DNS 已设置。${RESET}" || echo -e "${YELLOW}⚠️ 未修改 DNS。${RESET}"
                sleep 2
                ;;
            6)
                dns_set_or_lock "lock" && echo -e "${GREEN}✅ DNS 已锁定/固定。${RESET}" || echo -e "${YELLOW}⚠️ 未修改 DNS。${RESET}"
                sleep 2
                ;;
            7)
                dns_unlock_restore
                echo -e "${GREEN}✅ 已解锁并恢复。${RESET}"
                sleep 2
                ;;
            0) return ;;
        esac
    done
}

# ==============================================================================
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

    record_id=$(echo "$record_response" | jq -r '.result[0].id' 2>/dev/null)

    if [[ -n "$record_id" && "$record_id" != "null" ]]; then
        curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}" \
            -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" > /dev/null 2>&1 || true
        echo -e "${GREEN}✅ 云端记录已删除（若 API 权限允许）。${RESET}"
    fi

    rm -f "$DDNS_CONF" "$DDNS_LOG"
    crontab -l 2>/dev/null | grep -vE "(^|\s)(/usr/local/bin/my\s+ssr\s+ddns|/usr/local/bin/ssr\s+ddns)(\s|$)" | crontab - 2>/dev/null || true

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
# ==============================================================================
change_ssh_port() {
    read -rp "新的 SSH 端口号 (1-65535): " new_port
    if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
        backup_file_once /etc/ssh/sshd_config "$SSHD_BACKUP_FILE"
        if have_cmd ufw && ufw status | grep -qw "active"; then ufw allow "$new_port"/tcp >/dev/null 2>&1; fi
        if have_cmd firewall-cmd; then firewall-cmd --add-port="$new_port"/tcp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi
        replace_or_append_line /etc/ssh/sshd_config '^#?Port ' "Port $new_port"
        if restart_ssh_safe; then
            echo -e "${GREEN}✅ SSH 端口已修改为 $new_port 。${RESET}"
        else
            restore_file_if_present "$SSHD_BACKUP_FILE" /etc/ssh/sshd_config
            restart_ssh_safe >/dev/null 2>&1 || true
            echo -e "${RED}❌ SSH 配置校验失败，已回滚。${RESET}"
        fi
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
    backup_file_once /etc/ssh/sshd_config "$SSHD_BACKUP_FILE"
    replace_or_append_line /etc/ssh/sshd_config '^#?PasswordAuthentication ' 'PasswordAuthentication no'
    replace_or_append_line /etc/ssh/sshd_config '^#?KbdInteractiveAuthentication ' 'KbdInteractiveAuthentication no'
    replace_or_append_line /etc/ssh/sshd_config '^#?ChallengeResponseAuthentication ' 'ChallengeResponseAuthentication no'
    replace_or_append_line /etc/ssh/sshd_config '^#?PubkeyAuthentication ' 'PubkeyAuthentication yes'
    replace_or_append_line /etc/ssh/sshd_config '^#?UsePAM ' 'UsePAM yes'
    replace_or_append_line /etc/ssh/sshd_config '^#?PermitRootLogin ' 'PermitRootLogin prohibit-password'
    write_ssh_auth_dropin no no no
    if ! restart_ssh_safe; then
        remove_ssh_auth_dropin
        restore_file_if_present "$SSHD_BACKUP_FILE" /etc/ssh/sshd_config
        restart_ssh_safe >/dev/null 2>&1 || true
        echo -e "${RED}❌ SSH 配置校验失败，已回滚。${RESET}"
        sleep 2
        return 1
    fi
    echo -e "${GREEN}✅ 已启用密钥登录并禁止密码登录。${RESET}"
    sleep 2
}

restore_password_login() {
    backup_file_once /etc/ssh/sshd_config "$SSHD_BACKUP_FILE"
    replace_or_append_line /etc/ssh/sshd_config '^#?PasswordAuthentication ' 'PasswordAuthentication yes'
    replace_or_append_line /etc/ssh/sshd_config '^#?KbdInteractiveAuthentication ' 'KbdInteractiveAuthentication yes'
    replace_or_append_line /etc/ssh/sshd_config '^#?ChallengeResponseAuthentication ' 'ChallengeResponseAuthentication yes'
    replace_or_append_line /etc/ssh/sshd_config '^#?PubkeyAuthentication ' 'PubkeyAuthentication yes'
    remove_ssh_auth_dropin
    if ! restart_ssh_safe; then
        write_ssh_auth_dropin no no no
        restore_file_if_present "$SSHD_BACKUP_FILE" /etc/ssh/sshd_config
        restart_ssh_safe >/dev/null 2>&1 || true
        echo -e "${RED}❌ SSH 配置校验失败，已回滚。${RESET}"
        sleep 2
        return 1
    fi
    echo -e "${GREEN}✅ 已恢复密码登录。${RESET}"
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
            restore_password_login
            ;;
        0) return ;;
    esac
}

# ==============================================================================
# ==============================================================================
install_ss_rust_native() {
    clear
    echo -e "${CYAN}========= 原生交互安装 SS-Rust =========${RESET}"
    rm -f /etc/systemd/system/ss-rust.service 2>/dev/null || true

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

    local pwd="" input_pwd=""
    if [[ "$pwd_len" -ne 0 ]]; then
        read -rp "密码 (留空自动生成安全密钥): " input_pwd
        if [[ -z "$input_pwd" ]]; then
            if have_cmd openssl; then
                pwd=$(openssl rand "$pwd_len" 2>/dev/null | base64_nw)
            else
                pwd=$(head -c "$pwd_len" /dev/urandom 2>/dev/null | base64_nw)
            fi
        else
            local raw_len decoded_len=0 tmp_dec="/tmp/ssr-key.$$"
            raw_len=$(printf '%s' "$input_pwd" | wc -c | tr -d ' ')
            if printf '%s' "$input_pwd" | base64 -d >"$tmp_dec" 2>/dev/null; then
                decoded_len=$(wc -c <"$tmp_dec" | tr -d ' ')
            fi
            rm -f "$tmp_dec" 2>/dev/null || true
            if [[ "$decoded_len" == "$pwd_len" ]]; then
                pwd="$input_pwd"
            elif [[ "$raw_len" == "$pwd_len" ]]; then
                pwd=$(printf '%s' "$input_pwd" | base64_nw)
            else
                echo -e "${RED}❌ 2022 协议密钥长度错误：需要 ${pwd_len} 字节原始密钥，或对应的 Base64 密钥。${RESET}"
                sleep 3
                return
            fi
        fi
        [[ -n "$pwd" ]] || { echo -e "${RED}❌ 密钥生成失败。${RESET}"; sleep 3; return; }
    else
        read -rp "传统密码 (留空随机): " input_pwd
        if [[ -z "$input_pwd" ]]; then
            if have_cmd openssl; then
                pwd=$(openssl rand -hex 12 2>/dev/null)
            else
                pwd=$(head -c 12 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')
            fi
        else
            pwd="$input_pwd"
        fi
    fi

    local arch; arch=$(uname -m)
    local ss_arch_primary="x86_64-unknown-linux-musl"
    local ss_arch_fallback="x86_64-unknown-linux-gnu"
    case "$arch" in
        aarch64|arm64)
            ss_arch_primary="aarch64-unknown-linux-musl"
            ss_arch_fallback="aarch64-unknown-linux-gnu"
            ;;
        armv7l|armv7|arm)
            ss_arch_primary="arm-unknown-linux-musleabi"
            ss_arch_fallback="arm-unknown-linux-gnueabi"
            ;;
    esac

    echo -e "${CYAN}>>> 正在获取 SS-Rust 最新版本信息...${RESET}"
    local ss_latest
    ss_latest=$(github_latest_tag "shadowsocks/shadowsocks-rust")
    [[ -z "$ss_latest" ]] && ss_latest="v1.24.0"

    local tmpdir; tmpdir=$(mktemp -d /tmp/ssr-ssrust.XXXXXX)
    local tarball="${tmpdir}/ss-rust.tar.xz"
    local url=""
    local ss_arch=""

    for candidate_arch in "$ss_arch_primary" "$ss_arch_fallback"; do
        url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${ss_latest}/shadowsocks-${ss_latest}.${candidate_arch}.tar.xz"
        echo -e "${CYAN}>>> 下载核心: ${ss_latest} (${candidate_arch}) ...${RESET}"
        rm -f "$tarball" "${tmpdir}/ssserver" >/dev/null 2>&1 || true
        if ! download_file "$url" "$tarball" || [[ ! -s "$tarball" ]] || ! tar -tf "$tarball" >/dev/null 2>&1; then
            continue
        fi
        tar -xf "$tarball" -C "$tmpdir" ssserver >/dev/null 2>&1 || true
        [[ -x "${tmpdir}/ssserver" ]] || continue
        if run_with_timeout 3 "${tmpdir}/ssserver" --version >/dev/null 2>&1 || run_with_timeout 3 "${tmpdir}/ssserver" -V >/dev/null 2>&1; then
            ss_arch="$candidate_arch"
            break
        fi
    done

    if [[ -z "$ss_arch" || ! -x "${tmpdir}/ssserver" ]]; then
        echo -e "${RED}❌ SS-Rust 新核心自检失败。已自动尝试 musl/gnu 两种构建，当前环境均无法运行。${RESET}"
        echo -e "${YELLOW}提示：这通常是 glibc/运行时兼容问题，musl 静态版已优先尝试。${RESET}"
        rm -rf "$tmpdir"
        sleep 3
        return
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

    run_with_timeout 2 /usr/local/bin/ss-rust -c /etc/ss-rust/config.json >/dev/null 2>&1
    local rc=$?
    if [[ "$rc" -ne 0 && "$rc" -ne 124 && "$rc" -ne 137 ]]; then
        echo -e "${RED}❌ 配置自检失败，已中止启动。${RESET}"
        rm -rf "$tmpdir"
        sleep 3
        return
    fi

    local ss_unit='[Unit]
Description=Shadowsocks-Rust Server
After=network.target

[Service]
ExecStart=/usr/local/bin/ss-rust -c /etc/ss-rust/config.json
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target'

    if ! start_managed_service "ss-rust" "$ss_unit" "/usr/local/bin/ss-rust -c /etc/ss-rust/config.json" '/usr/local/bin/ss-rust -c /etc/ss-rust/config.json' "/var/log/ss-rust.log" "/var/run/ss-rust.pid"; then
        echo -e "${RED}❌ SS-Rust 启动失败。请检查 /var/log/ss-rust.log${RESET}"
        rm -rf "$tmpdir"
        sleep 3
        return
    fi

    if have_cmd ufw; then ufw allow "$port"/tcp >/dev/null 2>&1; ufw allow "$port"/udp >/dev/null 2>&1; fi
    if have_cmd firewall-cmd; then
        firewall-cmd --add-port="$port"/tcp --permanent >/dev/null 2>&1
        firewall-cmd --add-port="$port"/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi

    meta_set "SS_RUST_TAG" "$ss_latest"

    echo -e "${GREEN}✅ SS-Rust (${ss_latest}) 安装完成！${RESET}"
    show_ss_rust_summary
    rm -rf "$tmpdir"
    read -n 1 -s -r -p "按任意键返回上一层..."
}


install_vless_native() {
    clear
    echo -e "${CYAN}========= 原生交互安装 VLESS Reality =========${RESET}"
    rm -f /etc/systemd/system/xray.service

    read -rp "伪装域名 [默认 publicassets.cdn-apple.com]: " sni_domain
    [[ -z "$sni_domain" ]] && sni_domain="publicassets.cdn-apple.com"

    read -rp "监听端口 [留空随机]: " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        port=$((RANDOM % 55535 + 10000))
    fi

    local arch; arch=$(uname -m)
    local xray_arch="64"
    case "$arch" in
        aarch64|arm64) xray_arch="arm64-v8a" ;;
        armv7l|armv7|arm) xray_arch="arm32-v7a" ;;
    esac

    echo -e "${CYAN}>>> 正在获取 Xray 最新版本信息...${RESET}"
    local xray_latest
    xray_latest=$(github_latest_tag "XTLS/Xray-core")
    [[ -z "$xray_latest" ]] && xray_latest="v26.2.6"

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
    uuid=$(/usr/local/bin/xray uuid 2>/dev/null | head -n1 | tr -d '
')
    keys=$(/usr/local/bin/xray x25519 2>&1 | tr -d '
')
    priv=$(xray_extract_reality_private_key "$keys")
    pub=$(xray_extract_reality_public_key "$keys")
    if have_cmd openssl; then
        short_id=$(openssl rand -hex 8 2>/dev/null)
    else
        short_id=$(head -c 8 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' 
')
    fi
    if [[ -z "$uuid" || -z "$priv" || -z "$pub" || -z "$short_id" ]]; then
        echo -e "${RED}❌ Xray 密钥材料生成失败。${RESET}"
        echo -e "${YELLOW}x25519 输出:${RESET}"
        normalize_xray_x25519_output "$keys"
        rm -rf "$tmpdir"
        sleep 5
        return
    fi

    cat > /usr/local/etc/xray/config.json << EOF
{ "inbounds": [{ "listen": "::", "port": $port, "protocol": "vless", "settings": { "clients": [{"id": "$uuid", "flow": "xtls-rprx-vision"}], "decryption": "none" }, "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "dest": "${sni_domain}:443", "serverNames": ["${sni_domain}"], "privateKey": "$priv", "shortIds": ["$short_id"] } } }], "outbounds": [{"protocol": "freedom"}] }
EOF

    if ! /usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json >/dev/null 2>&1; then
        echo -e "${RED}❌ Xray 配置自检失败，已中止启动。${RESET}"
        rm -rf "$tmpdir"
        sleep 3
        return
    fi

    local xray_unit='[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target'

    if ! start_managed_service "xray" "$xray_unit" "/usr/local/bin/xray run -c /usr/local/etc/xray/config.json" '/usr/local/bin/xray run -c /usr/local/etc/xray/config.json' "/var/log/xray.log" "/var/run/xray.pid"; then
        echo -e "${RED}❌ Xray 启动失败。请检查 /var/log/xray.log${RESET}"
        rm -rf "$tmpdir"
        sleep 3
        return
    fi

    if have_cmd ufw; then ufw allow "$port"/tcp >/dev/null 2>&1; fi
    if have_cmd firewall-cmd; then firewall-cmd --add-port="$port"/tcp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi

    meta_set "XRAY_TAG" "$xray_latest"

    echo -e "${GREEN}✅ VLESS Reality (${xray_latest}) 安装成功！${RESET}"
    show_vless_summary
    rm -rf "$tmpdir"
    read -n 1 -s -r -p "按任意键返回上一层..."
}

install_shadowtls_native() {
    clear
    echo -e "${CYAN}========= 原生安装 ShadowTLS =========${RESET}"

    local ss_port=""
    if [[ -f "/etc/ss-rust/config.json" ]]; then
        ss_port=$(json_get_path /etc/ss-rust/config.json server_port 2>/dev/null)
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

    read -rp "伪装域名 (SNI) [留空默认 publicassets.cdn-apple.com]: " sni_domain
    [[ -z "$sni_domain" ]] && sni_domain="publicassets.cdn-apple.com"

    local pwd
    if have_cmd openssl; then
        pwd=$(openssl rand -base64 8 2>/dev/null | tr -d '
')
    else
        pwd=$(head -c 8 /dev/urandom 2>/dev/null | base64_nw)
    fi
    [[ -n "$pwd" ]] || { echo -e "${RED}❌ ShadowTLS 密码生成失败。${RESET}"; sleep 3; return; }
    local arch; arch=$(uname -m)
    local st_arch
    st_arch=$(shadowtls_arch_name "$arch") || {
        echo -e "${RED}❌ 当前架构暂不支持自动安装 ShadowTLS: ${arch}${RESET}"
        sleep 3
        return
    }

    echo -e "${CYAN}>>> 正在获取 ShadowTLS 最新版本信息...${RESET}"
    local st_latest
    st_latest=$(github_latest_tag "ihciah/shadow-tls")
    [[ -z "$st_latest" ]] && st_latest="v0.2.25"

    local tmpdir; tmpdir=$(mktemp -d /tmp/ssr-stls.XXXXXX)
    local binf="${tmpdir}/shadow-tls"
    local asset_name="shadow-tls-${st_arch}"
    local official_url="https://github.com/ihciah/shadow-tls/releases/download/${st_latest}/${asset_name}"
    local api_url=""
    api_url=$(github_release_asset_url "ihciah/shadow-tls" "$st_latest" "$asset_name" 2>/dev/null || true)
    local proxy_url="https://ghproxy.net/${official_url}"

    echo -e "${CYAN}>>> 下载核心: ${st_latest} (${st_arch}) ...${RESET}"
    if ! download_file_any "$binf" "$api_url" "$official_url" "$proxy_url" || [[ ! -s "$binf" ]]; then
        echo -e "${RED}❌ 下载失败。已尝试 GitHub 直连与代理地址。${RESET}"
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

    local st_cmd="/usr/local/bin/shadow-tls --v3 --strict server --listen 0.0.0.0:${listen_port} --server 127.0.0.1:${up_port} --tls ${sni_domain}:443 --password ${pwd}"
    local st_cmd_legacy="env MONOIO_FORCE_LEGACY_DRIVER=1 ${st_cmd}"
    if service_use_systemd; then
        mkdir -p /etc/systemd/system
        cat > /etc/systemd/system/shadowtls-${listen_port}.service << EOF
[Unit]
Description=ShadowTLS Service on port ${listen_port}
After=network.target

[Service]
ExecStart=${st_cmd}
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload >/dev/null 2>&1 || true
        if ! systemctl enable --now shadowtls-"${listen_port}" >/dev/null 2>&1 || ! systemctl is-active --quiet shadowtls-"${listen_port}" 2>/dev/null; then
            cat > /etc/systemd/system/shadowtls-${listen_port}.service << EOF
[Unit]
Description=ShadowTLS Service on port ${listen_port}
After=network.target

[Service]
Environment=MONOIO_FORCE_LEGACY_DRIVER=1
ExecStart=${st_cmd}
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl restart shadowtls-"${listen_port}" >/dev/null 2>&1 || systemctl enable --now shadowtls-"${listen_port}" >/dev/null 2>&1 || {
                echo -e "${RED}❌ ShadowTLS 服务启动失败。${RESET}"
                rm -rf "$tmpdir"
                sleep 3
                return
            }
            systemctl is-active --quiet shadowtls-"${listen_port}" 2>/dev/null || {
                echo -e "${RED}❌ ShadowTLS 未处于运行状态。${RESET}"
                rm -rf "$tmpdir"
                sleep 3
                return
            }
        fi
    else
        restart_managed_service "shadowtls-${listen_port}" "$st_cmd" '/usr/local/bin/shadow-tls --v3 --strict server' "/var/log/shadowtls.log" "/var/run/shadowtls-${listen_port}.pid" ||         restart_managed_service "shadowtls-${listen_port}" "$st_cmd_legacy" '/usr/local/bin/shadow-tls --v3 --strict server' "/var/log/shadowtls.log" "/var/run/shadowtls-${listen_port}.pid" || {
            echo -e "${RED}❌ ShadowTLS 后台启动失败（无 systemd 环境）。${RESET}"
            rm -rf "$tmpdir"
            sleep 3
            return
        }
    fi

    if have_cmd ufw; then ufw allow "$listen_port"/tcp >/dev/null 2>&1; fi
    if have_cmd firewall-cmd; then firewall-cmd --add-port="$listen_port"/tcp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi

    sleep 1
    if ! shadowtls_is_active "$listen_port" || ! port_listening_tcp "$listen_port"; then
        echo -e "${RED}❌ ShadowTLS 进程未稳定监听在 ${listen_port}/tcp。${RESET}"
        if [[ -f /var/log/shadowtls.log ]]; then
            echo -e "${YELLOW}最近日志:${RESET}"
            tail -n 20 /var/log/shadowtls.log 2>/dev/null || true
        fi
        rm -rf "$tmpdir"
        sleep 5
        return
    fi

    meta_set "SHADOWTLS_TAG" "$st_latest"
    shadowtls_state_save "$listen_port" "$up_port" "$sni_domain" "$pwd"

    echo -e "${GREEN}✅ ShadowTLS (${st_latest}) 安装成功！已挂载在 ${up_port} 上层。${RESET}"
    show_shadowtls_summary "$listen_port"
    echo -e "${YELLOW}手动参数:${RESET} 外层端口=${listen_port} | 上游端口=${up_port} | SNI=${sni_domain} | ShadowTLS密码=${pwd}"
    rm -rf "$tmpdir"
    read -n 1 -s -r -p "按任意键返回上一层..."
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
                service_use_systemd && systemctl stop "$(basename "$s")" 2>/dev/null || true
                service_use_systemd && systemctl disable "$(basename "$s")" 2>/dev/null || true
                rm -f "$s"
                service_use_systemd && systemctl daemon-reload >/dev/null 2>&1 || true
            fi
        done

        local has_ss=0 has_vless=0 has_stls=0
        local shadowtls_ports=()
        mapfile -t shadowtls_ports < <(shadowtls_detect_ports)
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

        if [[ ${#shadowtls_ports[@]} -gt 0 ]]; then
            echo -e "${GREEN} 3) 🛡️ ShadowTLS 防阻断保护实例 (${#shadowtls_ports[@]})${RESET}"
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
                    local port method password link
                    show_ss_rust_summary
                    port=$(json_get_path /etc/ss-rust/config.json server_port 2>/dev/null)
                    method=$(json_get_path /etc/ss-rust/config.json method 2>/dev/null)
                    password=$(json_get_path /etc/ss-rust/config.json password 2>/dev/null)
                    link=$(ssr_make_ss_link 2>/dev/null || true)
                    echo -e "---------------------------------"
                    echo -e "${YELLOW}1) 修改端口${RESET} | ${YELLOW}2) 修改密码${RESET} | ${RED}3) 删除节点${RESET} | 0) 返回"
                    read -rp "输入操作: " op
                    if [[ "$op" == "1" ]]; then
                        read -rp "新端口 (1-65535): " np
                        if [[ "$np" =~ ^[0-9]+$ ]] && [ "$np" -ge 1 ] && [ "$np" -le 65535 ]; then
                            json_set_top_value /etc/ss-rust/config.json server_port "$np" number
                            remove_firewall_rule "$port" "both"
                            if have_cmd ufw; then ufw allow "$np"/tcp >/dev/null 2>&1; ufw allow "$np"/udp >/dev/null 2>&1; fi
                            if have_cmd firewall-cmd; then
                                firewall-cmd --add-port="$np"/tcp --permanent >/dev/null 2>&1
                                firewall-cmd --add-port="$np"/udp --permanent >/dev/null 2>&1
                                firewall-cmd --reload >/dev/null 2>&1
                            fi
                            restart_managed_service "ss-rust" "/usr/local/bin/ss-rust -c /etc/ss-rust/config.json" '/usr/local/bin/ss-rust -c /etc/ss-rust/config.json' "/var/log/ss-rust.log" "/var/run/ss-rust.pid" >/dev/null 2>&1 || true
                            echo -e "${GREEN}✅ 修改成功${RESET}"
                        else
                            echo -e "${RED}❌ 端口无效${RESET}"
                        fi
                        sleep 1
                    elif [[ "$op" == "2" ]]; then
                        read -rp "新密码: " npwd
                        [[ -z "$npwd" ]] && { echo -e "${RED}❌ 密码不能为空${RESET}"; sleep 1; continue; }
                        json_set_top_value /etc/ss-rust/config.json password "$npwd" string
                        restart_managed_service "ss-rust" "/usr/local/bin/ss-rust -c /etc/ss-rust/config.json" '/usr/local/bin/ss-rust -c /etc/ss-rust/config.json' "/var/log/ss-rust.log" "/var/run/ss-rust.pid" >/dev/null 2>&1 || true
                        echo -e "${GREEN}✅ 修改成功${RESET}"
                        sleep 1
                    elif [[ "$op" == "3" ]]; then
                        remove_firewall_rule "$port" "both"
                        stop_managed_service "ss-rust" '/usr/local/bin/ss-rust -c /etc/ss-rust/config.json' "/var/run/ss-rust.pid"
                        rm -rf /etc/ss-rust /usr/local/bin/ss-rust /etc/systemd/system/ss-rust.service /var/log/ss-rust.log
                        service_use_systemd && systemctl daemon-reload >/dev/null 2>&1 || true
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
                    port=$(json_get_path /usr/local/etc/xray/config.json inbounds.0.port 2>/dev/null)
                    uuid=$(json_get_path /usr/local/etc/xray/config.json inbounds.0.settings.clients.0.id 2>/dev/null)
                    sni=$(json_get_path /usr/local/etc/xray/config.json inbounds.0.streamSettings.realitySettings.serverNames.0 2>/dev/null)
                    echo -e "IP: ${GREEN}${ip}${RESET}"
                    echo -e "端口: ${GREEN}${port}${RESET}"
                    echo -e "UUID: ${GREEN}${uuid}${RESET}"
                    echo -e "SNI伪装: ${GREEN}${sni}${RESET}"
                    echo -e "---------------------------------"
                    echo -e "${YELLOW}1) 重启节点${RESET} | ${RED}2) 删除节点${RESET} | 0) 返回"
                    read -rp "输入操作: " op
                    if [[ "$op" == "1" ]]; then
                        restart_managed_service "xray" "/usr/local/bin/xray run -c /usr/local/etc/xray/config.json" '/usr/local/bin/xray run -c /usr/local/etc/xray/config.json' "/var/log/xray.log" "/var/run/xray.pid" >/dev/null 2>&1 || true
                        echo -e "${GREEN}✅ 已重启${RESET}"
                        sleep 1
                    elif [[ "$op" == "2" ]]; then
                        remove_firewall_rule "$port" "tcp"
                        stop_managed_service "xray" '/usr/local/bin/xray run -c /usr/local/etc/xray/config.json' "/var/run/xray.pid"
                        rm -rf /usr/local/etc/xray /usr/local/bin/xray /etc/systemd/system/xray.service /var/log/xray.log
                        service_use_systemd && systemctl daemon-reload >/dev/null 2>&1 || true
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
                    mapfile -t st_ports < <(shadowtls_detect_ports)
                    for st_port in "${st_ports[@]}"; do
                        [[ -n "$st_port" ]] || continue
                        local st_status
                        if shadowtls_is_active "$st_port"; then
                            st_status="${GREEN}运行中${RESET}"
                        else
                            st_status="${RED}已停止${RESET}"
                        fi
                        echo -e " ${CYAN}${idx})${RESET} 外层端口: ${YELLOW}${st_port}${RESET} [${st_status}]"
                        ((idx++))
                    done
                    echo -e "---------------------------------"
                    echo -e "${YELLOW}1) 序号查看实例详情${RESET} | ${RED}2) 序号删除实例${RESET} | ${RED}9) ⚠️ 强制核爆所有残留${RESET} | 0) 返回"
                    read -rp "输入操作: " op
                    if [[ "$op" == "1" ]]; then
                        read -rp "输入实例序号 [1-$((idx-1))]: " view_idx
                        local view_port="${st_ports[$((view_idx-1))]}"
                        if [[ -n "$view_port" ]]; then
                            clear
                            show_shadowtls_summary "$view_port"
                            echo
                            echo -e "${CYAN}提示:${RESET} ShadowTLS 链接必须带 plugin=shadow-tls 参数；如果客户端只看到普通 SS 链接，请优先使用这里显示的 ShadowTLS 链接。"
                            read -n 1 -s -r -p "按任意键返回上一层..."
                        fi
                    elif [[ "$op" == "2" ]]; then
                        read -rp "输入实例序号 [1-$((idx-1))]: " del_idx
                        local del_port="${st_ports[$((del_idx-1))]}"
                        if [[ -n "$del_port" ]]; then
                            remove_firewall_rule "$del_port" "tcp"
                            stop_managed_service "shadowtls-${del_port}" '/usr/local/bin/shadow-tls --v3 --strict server' "/var/run/shadowtls-${del_port}.pid"
                            rm -f "/etc/systemd/system/shadowtls-${del_port}.service"
                            rm -f "$(shadowtls_state_file "$del_port")"
                            service_use_systemd && systemctl daemon-reload >/dev/null 2>&1 || true
                            if [[ $(shadowtls_detect_ports | wc -l | tr -d ' ') -eq 0 ]]; then
                                rm -f /usr/local/bin/shadow-tls /var/log/shadowtls.log
                            fi
                            echo -e "${GREEN}✅ 已彻底销毁！${RESET}"
                            sleep 1
                        fi
                    elif [[ "$op" == "9" ]]; then
                        echo -e "${RED}执行物理核爆...${RESET}"
                        for p in "${st_ports[@]}"; do
                            [[ -z "$p" ]] && continue
                            remove_firewall_rule "$p" "tcp"
                            stop_managed_service "shadowtls-${p}" '/usr/local/bin/shadow-tls --v3 --strict server' "/var/run/shadowtls-${p}.pid"
                            rm -f "/etc/systemd/system/shadowtls-${p}.service"
                            rm -f "$(shadowtls_state_file "$p")"
                        done
                        rm -f /usr/local/bin/shadow-tls /var/log/shadowtls.log
                        service_use_systemd && systemctl daemon-reload >/dev/null 2>&1 || true
                        echo -e "${GREEN}✅ 拔除成功！${RESET}"
                        sleep 2
                    fi
                fi
                ;;
            4)
                while true; do
                    clear
                    echo -e "${CYAN}========= ☢️ 全局强制核爆中心 =========${RESET}"
                    echo -e "${YELLOW}已改为序号选择，直接核爆已识别到的节点残留。${RESET}"
                    echo -e "---------------------------------"
                    managed_nuke_build_index
                    local nuke_count=0 i target label port
                    for i in "${!NUCLEAR_TARGETS[@]}"; do
                        [[ -n "${NUCLEAR_TARGETS[$i]}" ]] || continue
                        target="${NUCLEAR_TARGETS[$i]}"
                        label="${NUCLEAR_LABELS[$i]}"
                        port="${NUCLEAR_PORTS[$i]}"
                        if [[ -n "$port" ]]; then
                            echo -e " ${CYAN}${i})${RESET} ${label} ${YELLOW}${target}${RESET} [端口 ${GREEN}${port}${RESET}]"
                        else
                            echo -e " ${CYAN}${i})${RESET} ${label} ${YELLOW}${target}${RESET}"
                        fi
                        ((nuke_count++))
                    done
                    if [[ "$nuke_count" -eq 0 ]]; then
                        echo -e "${RED}未识别到可核爆的节点残留。${RESET}"
                        read -n1 -rsp "按任意键返回..." _
                        break
                    fi
                    echo -e "---------------------------------"
                    echo -e "${RED} 9) ⚠️ 核爆全部已识别残留${RESET}"
                    echo -e " 0) 返回"
                    read -rp "请选择序号: " nuke_choice
                    case "$nuke_choice" in
                        0) break ;;
                        9)
                            for i in "${!NUCLEAR_TARGETS[@]}"; do
                                [[ -n "${NUCLEAR_TARGETS[$i]}" ]] || continue
                                force_kill_service "${NUCLEAR_TARGETS[$i]}" "menu"
                            done
                            ;;
                        *)
                            if [[ -n "${NUCLEAR_TARGETS[$nuke_choice]}" ]]; then
                                force_kill_service "${NUCLEAR_TARGETS[$nuke_choice]}" "menu"
                            else
                                echo -e "${RED}❌ 序号无效${RESET}"
                                sleep 1
                            fi
                            ;;
                    esac
                done
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
    local limit="${1:-50M}"
    [[ -f /etc/systemd/journald.conf ]] || return 0
    backup_file_once /etc/systemd/journald.conf "$JOURNALD_BACKUP_FILE"
    replace_or_append_line /etc/systemd/journald.conf '^\s*SystemMaxUse=' "SystemMaxUse=${limit}"
    systemctl restart systemd-journald 2>/dev/null || true
}

apply_ssh_keepalive() {
    local interval="${1:-30}" count="${2:-3}"
    [[ -f /etc/ssh/sshd_config ]] || return 0
    backup_file_once /etc/ssh/sshd_config "$SSHD_BACKUP_FILE"
    replace_or_append_line /etc/ssh/sshd_config '^#?ClientAliveInterval ' "ClientAliveInterval ${interval}"
    replace_or_append_line /etc/ssh/sshd_config '^#?ClientAliveCountMax ' "ClientAliveCountMax ${count}"
    restart_ssh_safe || true
}

ensure_swap() {
    local size_mb="${1:-256}"
    local active_swap
    active_swap="$(awk 'NR>1 {print $1}' /proc/swaps 2>/dev/null | head -n 1)"
    [[ -n "$active_swap" ]] && return 0
    grep -qE '^[^#].+[[:space:]]swap[[:space:]]+swap[[:space:]]' /etc/fstab 2>/dev/null && return 0
    if [[ -f /var/swap && ! -f "$SWAP_MARK_FILE" ]]; then
        echo -e "${YELLOW}⚠️ 检测到现有 /var/swap，且非本脚本创建，已跳过。${RESET}"
        return 0
    fi

    rm -f /var/swap
    if dd if=/dev/zero of=/var/swap bs=1M count="$size_mb" status=none 2>/dev/null; then
        chmod 600 /var/swap
        mkswap /var/swap >/dev/null 2>&1
        swapon /var/swap >/dev/null 2>&1 || true
        grep -qF '/var/swap swap swap defaults 0 0' /etc/fstab 2>/dev/null || echo '/var/swap swap swap defaults 0 0' >> /etc/fstab
        mkdir -p "$META_DIR" 2>/dev/null || true
        echo "1" > "$SWAP_MARK_FILE"
        echo -e "${GREEN}✅ ${size_mb}MB Swap 创建成功！${RESET}"
    else
        rm -f /var/swap
        echo -e "${YELLOW}⚠️ Swap 创建失败（可能磁盘不足），已跳过。${RESET}"
    fi
}

apply_profile_core() {
    local env="$1" mode="$(profile_alias "$2")" tier target swap_size
    tier="$(detect_machine_tier)"
    [[ "$env" == "nat" ]] && { target="$NAT_CONF_FILE"; rm -f "$CONF_FILE" 2>/dev/null || true; } || { target="$CONF_FILE"; rm -f "$NAT_CONF_FILE" 2>/dev/null || true; }

    if [[ "$env" == "nat" ]]; then
        apply_journald_limit "50M"
        apply_ssh_keepalive 30 3
        if [[ "$mode" == "perf" ]]; then
            dns_set_or_lock "lock" || true
            case "$tier" in
                tiny|small) swap_size=512 ;;
                medium) swap_size=768 ;;
                large) swap_size=1024 ;;
                *) swap_size=512 ;;
            esac
        else
            dns_set_or_lock "set" || true
            case "$tier" in
                tiny|small) swap_size=256 ;;
                medium|large) swap_size=512 ;;
                *) swap_size=256 ;;
            esac
        fi
        ensure_swap "$swap_size"
    fi

    render_sysctl_profile "$target" "$env" "$mode" "$tier"
    filter_supported_sysctl_file "$target"
    sysctl --system >/dev/null 2>&1 || true
    meta_set "SYSCTL_PROFILE" "${env}-${mode}"
    meta_set "SYSCTL_TIER" "$tier"
    echo -e "${GREEN}✅ 已应用 ${env} / $(profile_title "$mode") / ${tier} 档调优。${RESET}"
    sleep 2
}

apply_nat_profile() {
    apply_profile_core nat "$1"
}

apply_regular_profile() {
    apply_profile_core regular "$1"
}

opt_menu() {
    while true; do
        clear
        echo -e "${CYAN}========= 网络优化与系统清理中心 =========${RESET}"
        echo -e "${GREEN} 1.${RESET} 常规机器调优：稳定优先"
        echo -e "${GREEN} 2.${RESET} 常规机器调优：极致优化"
        echo -e "${YELLOW} 3.${RESET} NAT 小鸡调优：稳定优先"
        echo -e "${YELLOW} 4.${RESET} NAT 小鸡调优：极致优化"
        echo -e "${CYAN} 5.${RESET} 手动清理系统垃圾与冗余日志"
        echo -e " 0. 返回主菜单"
        read -rp "输入数字 [0-5]: " opt_num
        case "$opt_num" in
            1) apply_regular_profile "stable" ;;
            2) apply_regular_profile "extreme" ;;
            3) apply_nat_profile "stable" ;;
            4) apply_nat_profile "extreme" ;;
            5) auto_clean ;;
            0) return ;;
        esac
    done
}

# ==============================================================================
# ==============================================================================
run_daemon_check() {
    if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^ss-rust\.service'; then
        systemctl is-active --quiet ss-rust 2>/dev/null || restart_managed_service "ss-rust" "/usr/local/bin/ss-rust -c /etc/ss-rust/config.json" '/usr/local/bin/ss-rust -c /etc/ss-rust/config.json' "/var/log/ss-rust.log" "/var/run/ss-rust.pid" >/dev/null 2>&1 || true
    fi

    if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^xray\.service'; then
        systemctl is-active --quiet xray 2>/dev/null || restart_managed_service "xray" "/usr/local/bin/xray run -c /usr/local/etc/xray/config.json" '/usr/local/bin/xray run -c /usr/local/etc/xray/config.json' "/var/log/xray.log" "/var/run/xray.pid" >/dev/null 2>&1 || true
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
    local ss_arch_primary="x86_64-unknown-linux-musl"
    local ss_arch_fallback="x86_64-unknown-linux-gnu"
    case "$arch" in
        aarch64|arm64)
            ss_arch_primary="aarch64-unknown-linux-musl"
            ss_arch_fallback="aarch64-unknown-linux-gnu"
            ;;
        armv7l|armv7|arm)
            ss_arch_primary="arm-unknown-linux-musleabi"
            ss_arch_fallback="arm-unknown-linux-gnueabi"
            ;;
    esac

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
    local ss_arch=""
    local url=""

    for candidate_arch in "$ss_arch_primary" "$ss_arch_fallback"; do
        url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${latest}/shadowsocks-${latest}.${candidate_arch}.tar.xz"
        rm -f "$tarball" "${tmpdir}/ssserver" >/dev/null 2>&1 || true
        if ! download_file "$url" "$tarball" || [[ ! -s "$tarball" ]] || ! tar -tf "$tarball" >/dev/null 2>&1; then
            continue
        fi
        tar -xf "$tarball" -C "$tmpdir" ssserver >/dev/null 2>&1 || true
        [[ -x "${tmpdir}/ssserver" ]] || continue
        if run_with_timeout 3 "${tmpdir}/ssserver" --version >/dev/null 2>&1 || run_with_timeout 3 "${tmpdir}/ssserver" -V >/dev/null 2>&1; then
            ss_arch="$candidate_arch"
            break
        fi
    done

    [[ -n "$ss_arch" && -x "${tmpdir}/ssserver" ]] || { rm -rf "$tmpdir"; return 2; }

    safe_install_binary "${tmpdir}/ssserver" /usr/local/bin/ss-rust || { rm -rf "$tmpdir"; return 2; }

    meta_set "SS_RUST_TAG" "$latest"
    restart_managed_service "ss-rust" "/usr/local/bin/ss-rust -c /etc/ss-rust/config.json" '/usr/local/bin/ss-rust -c /etc/ss-rust/config.json' "/var/log/ss-rust.log" "/var/run/ss-rust.pid" >/dev/null 2>&1 || true
    rm -rf "$tmpdir"
    return 0
}

update_xray_if_needed() {
    [[ -x "/usr/local/bin/xray" ]] || return 1

    local arch; arch=$(uname -m)
    local xray_arch="64"
    case "$arch" in
        aarch64|arm64) xray_arch="arm64-v8a" ;;
        armv7l|armv7|arm) xray_arch="arm32-v7a" ;;
    esac

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
    restart_managed_service "xray" "/usr/local/bin/xray run -c /usr/local/etc/xray/config.json" '/usr/local/bin/xray run -c /usr/local/etc/xray/config.json' "/var/log/xray.log" "/var/run/xray.pid" >/dev/null 2>&1 || true
    rm -rf "$tmpdir"
    return 0
}

update_shadowtls_if_needed() {
    [[ -x "/usr/local/bin/shadow-tls" ]] || return 1

    local arch; arch=$(uname -m)
    local st_arch
    st_arch=$(shadowtls_arch_name "$arch") || return 2

    local latest; latest=$(github_latest_tag "ihciah/shadow-tls")
    [[ -z "$latest" ]] && return 2

    local current; current=$(meta_get "SHADOWTLS_TAG" || true)
    [[ -n "$current" && "$current" == "$latest" ]] && return 3

    local tmpdir; tmpdir=$(mktemp -d /tmp/ssr-up-stls.XXXXXX)
    local binf="${tmpdir}/shadow-tls"
    local asset_name="shadow-tls-${st_arch}"
    local official_url="https://github.com/ihciah/shadow-tls/releases/download/${latest}/${asset_name}"
    local api_url=""
    api_url=$(github_release_asset_url "ihciah/shadow-tls" "$latest" "$asset_name" 2>/dev/null || true)
    local proxy_url="https://ghproxy.net/${official_url}"

    if ! download_file_any "$binf" "$api_url" "$official_url" "$proxy_url" || [[ ! -s "$binf" ]]; then
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

daily_task() {
    # 例行任务：安全热更（有新版本才更）+ 清理
    hot_update_components "silent"
    auto_clean "silent"
}

# ==============================================================================
# 完全卸载
# ==============================================================================
ssr_cleanup_artifacts() {
    if [[ -f "/etc/ss-rust/config.json" ]]; then
        local sp; sp=$(json_get_path /etc/ss-rust/config.json server_port 2>/dev/null)
        [[ -n "$sp" && "$sp" != "null" ]] && remove_firewall_rule "$sp" "both"
    fi
    if [[ -f "/usr/local/etc/xray/config.json" ]]; then
        local xp; xp=$(json_get_path /usr/local/etc/xray/config.json inbounds.0.port 2>/dev/null)
        [[ -n "$xp" && "$xp" != "null" ]] && remove_firewall_rule "$xp" "tcp"
    fi
    for s in /etc/systemd/system/shadowtls-*.service; do
        [[ -f "$s" ]] || continue
        remove_firewall_rule "$(basename "$s" | sed 's/shadowtls-//g' | sed 's/.service//g')" "tcp"
    done

    stop_managed_service "ss-rust" '/usr/local/bin/ss-rust -c /etc/ss-rust/config.json' "/var/run/ss-rust.pid"
    stop_managed_service "xray" '/usr/local/bin/xray run -c /usr/local/etc/xray/config.json' "/var/run/xray.pid"
    rm -rf /etc/ss-rust /usr/local/bin/ss-rust /etc/systemd/system/ss-rust.service /var/log/ss-rust.log
    rm -rf /usr/local/etc/xray /usr/local/bin/xray /etc/systemd/system/xray.service /var/log/xray.log

    while read -r s; do
        [[ -z "$s" ]] && continue
        systemctl stop "$s" 2>/dev/null || true
        systemctl disable "$s" 2>/dev/null || true
        rm -f "/etc/systemd/system/$s"
    done < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep '^shadowtls-.*\.service$' || true)

    [[ -f "$DDNS_CONF" ]] && remove_cf_ddns "force" 2>/dev/null || true
    rm -f /usr/local/bin/shadow-tls "$CONF_FILE" "$NAT_CONF_FILE" "$DDNS_CONF" "$DDNS_LOG" "$META_FILE"
    rm -f /usr/local/bin/ssr /usr/local/bin/ssr.sh 2>/dev/null || true
    crontab -l 2>/dev/null | grep -vE "/usr/local/bin/ssr (auto_update|auto_task|daemon_check|auto_core_update|clean|daily_task|ddns)" | crontab - 2>/dev/null || true
    dns_unlock_restore 2>/dev/null || true

    if [[ -f "$SWAP_MARK_FILE" ]]; then
        swapoff /var/swap 2>/dev/null || true
        rm -f /var/swap
        sed -i '/^\/var\/swap[[:space:]]\+swap[[:space:]]\+swap[[:space:]]\+defaults[[:space:]]\+0[[:space:]]\+0$/d' /etc/fstab 2>/dev/null || true
        rm -f "$SWAP_MARK_FILE" 2>/dev/null || true
    fi

    restore_file_if_present "$SSHD_BACKUP_FILE" /etc/ssh/sshd_config
    restore_file_if_present "$JOURNALD_BACKUP_FILE" /etc/systemd/journald.conf
    restart_ssh_safe >/dev/null 2>&1 || true
    systemctl restart systemd-journald 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    rm -f "$SSHD_BACKUP_FILE" "$JOURNALD_BACKUP_FILE" 2>/dev/null || true
    rm -rf "$META_DIR" "$DNS_BACKUP_DIR" 2>/dev/null || true
    rm -f "$RESOLVED_DROPIN" "$SSH_AUTH_DROPIN" 2>/dev/null || true
}

total_uninstall() {
    echo -e "${RED}⚠️ 正在进行无痕毁灭性全量卸载...${RESET}"
    ssr_cleanup_artifacts
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
        echo -e "${YELLOW} 6.${RESET} DNS 管理中心（智能/手动/锁定/恢复）"
        echo -e " 0. 返回上级菜单"
        read -rp "输入数字 [0-6]: " sys_num
        case "$sys_num" in
            1) change_ssh_port ;;
            2) change_root_password ;;
            3) sync_server_time ;;
            4) ssh_key_menu ;;
            5) cf_ddns_menu ;;
            6) dns_menu ;;
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
    echo -e "${YELLOW} 5.${RESET} 网络优化与系统清理 (手动常规/NAT + 清理)"
    echo -e "${CYAN}============================================${RESET}"
    echo -e " 0. 返回上级菜单"
    read -rp "请输入对应数字 [0-5]: " num
    case "$num" in
        1) install_ss_rust_native ;;
        2) install_vless_native ;;
        3) install_shadowtls_native ;;
        4) unified_node_manager ;;
        5) opt_menu ;;
        0) return 1 ;;
        *) echo -e "${RED}请输入正确的选项！${RESET}" ;;
    esac
    echo -e "
${CYAN}按任意键返回上一层...${RESET}"
    read -n 1 -s -r
}

SSR_MODULE_EOF

    # NFT 模块（已移除脚本自更新/卸载菜单，并适配 my 统一管理）
    cat > "${NFT_MODULE_FILE}" <<'NFT_MODULE_EOF'
#!/bin/bash

# ==========================================
# nftables 端口转发管理面板 (Pro 智能优化版)
# ==========================================

set -o pipefail

# 脚本签名（用于安全自更新，防止误更新到其它脚本）
SCRIPT_ID="nftmgr-pro"
SCRIPT_FINGERPRINT_1="CMD_NAME=\"nftmgr\""
SCRIPT_FINGERPRINT_2="nft_mgr_nat"
SCRIPT_FINGERPRINT_3="update_script()"

# 兼容 cron/systemd 的精简 PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# --------------------------
# 可配置常量
# --------------------------
CONFIG_FILE="/etc/nft_forward_list.conf"
SETTINGS_FILE="/etc/nft_forward_settings.conf"

NFT_MGR_DIR="/etc/nftables.d"
# 持久化兼容模式（解决部分“节点管理/面板”只认 /etc/nftables.conf 的问题）
#  - service: 使用 nft-mgr oneshot service 加载 /etc/nftables.d/nft_mgr.conf（默认，最不干扰系统）
#  - system : 向 /etc/nftables.conf 注入 include "/etc/nftables.d/nft_mgr.conf" 并用 nftables.service 持久化（兼容性更好）
NFTABLES_CONF="/etc/nftables.conf"
NFTABLES_CREATED_MARK="/etc/nftables.conf.nftmgr_created"
PERSIST_MODE_DEFAULT="service"
NFT_MGR_CONF="${NFT_MGR_DIR}/nft_mgr.conf"
NFT_MGR_SERVICE="/etc/systemd/system/nft-mgr.service"

SYSCTL_FILE="/etc/sysctl.d/99-nft-mgr.conf"

LOG_DIR="/var/log/nft_ddns"
LOCK_FILE="/var/lock/nft_mgr.lock"

CMD_NAME="nftmgr"

RAW_URL="https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/ssr.sh"
PROXY_URL="https://ghproxy.net/https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/nft_mgr.sh"
RAW_URL_FALLBACK="https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/nft_mgr.sh"
PROXY_URL_FALLBACK="https://ghproxy.net/https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/ssr.sh"
# 可选：自定义更新地址（写入 SETTINGS_FILE：/etc/nft_forward_settings.conf）
# UPDATE_URL_DIRECT="https://raw.githubusercontent.com/<you>/<repo>/main/nftmgr.sh"
# UPDATE_URL_PROXY="https://ghproxy.net/https://raw.githubusercontent.com/<you>/<repo>/main/nftmgr.sh"


# --------------------------
# 设置读写（用于持久化模式开关）
# --------------------------
settings_get() {
    local key="$1"
    [[ -f "$SETTINGS_FILE" ]] || return 1
    grep -E "^${key}=" "$SETTINGS_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- | sed 's/^"//; s/"$//'
}
settings_set() {
    local key="$1"; local value="$2"
    touch "$SETTINGS_FILE" 2>/dev/null || true
    chmod 600 "$SETTINGS_FILE" 2>/dev/null || true
    if grep -qE "^${key}=" "$SETTINGS_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}="${value}"|g" "$SETTINGS_FILE"
    else
        echo "${key}="${value}"" >> "$SETTINGS_FILE"
    fi
}
PERSIST_MODE="$(settings_get "PERSIST_MODE" || true)"
[[ -z "$PERSIST_MODE" ]] && PERSIST_MODE="$PERSIST_MODE_DEFAULT"

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

# 基础工具
have_cmd() { command -v "$1" >/dev/null 2>&1; }


# --------------------------
# 环境与依赖
# --------------------------
require_root() {
    [[ $EUID -ne 0 ]] && msg_err "错误: 必须使用 root 权限运行!" && exit 1
}


# 获取脚本真实路径（兼容不支持 readlink -f 的环境）
script_realpath() {
    local p="$0"
    if command -v readlink >/dev/null 2>&1; then
        readlink -f "$p" 2>/dev/null && return 0
    fi
    if command -v realpath >/dev/null 2>&1; then
        realpath "$p" 2>/dev/null && return 0
    fi
    echo "$p"
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
    for c in nft dig curl flock ss sysctl; do
        have_cmd "$c" || need=1
    done
    [[ $need -eq 1 ]] && install_deps

    # 再次检查
    for c in nft dig curl flock ss sysctl; do
        have_cmd "$c" || msg_warn "⚠️ 未找到依赖命令: $c（部分功能可能不可用）"
    done

    mkdir -p "$(dirname "$CONFIG_FILE")" "$LOG_DIR" "$NFT_MGR_DIR" 2>/dev/null || true
    [[ -f "$CONFIG_FILE" ]] || touch "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    [[ -f "$SETTINGS_FILE" ]] || touch "$SETTINGS_FILE"
    chmod 600 "$SETTINGS_FILE" 2>/dev/null || true
}

install_global_command() {
    # 已由综合脚本 my 统一安装命令入口，不再创建 /usr/local/bin/nftmgr
    return 0
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
# DDNS 定时任务联动（当新增规则目标为域名时，自动启用每分钟检测）
# --------------------------
ensure_ddns_cron_enabled() {
    local my_cmd="/usr/local/bin/my"

    # 已存在则不重复添加
    if crontab -l 2>/dev/null | grep -Fq "${my_cmd} nft --cron"; then
        return 0
    fi

    # 清理旧版 nftmgr --cron（避免重复）
    remove_ddns_cron_task || true

    # 追加定时任务：每分钟运行一次 DDNS 更新
    (crontab -l 2>/dev/null; echo "* * * * * ${my_cmd} nft --cron > /dev/null 2>&1") | crontab - 2>/dev/null || true
    return 0
}
has_domain_rules() {
    # 如果配置中仍存在“目标为域名（非纯 IPv4）”的规则，则返回 0，否则返回 1
    while IFS='|' read -r lp addr tp last_ip proto; do
        [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
        [[ -z "$addr" ]] && continue
        if ! is_ipv4 "$addr"; then
            return 0
        fi
    done < "$CONFIG_FILE"
    return 1
}

remove_ddns_cron_task() {
    # 删除所有（my nft --cron / nftmgr --cron）的 crontab 行（避免路径差异导致残留）
    local cur
    cur="$(crontab -l 2>/dev/null || true)"
    [[ -z "$cur" ]] && return 0
    echo "$cur" | grep -vE '(^|\s)(/usr/local/bin/my\s+nft\s+--cron|/usr/local/bin/nftmgr|nftmgr)\s+--cron(\s|$)' | crontab - 2>/dev/null || true
    return 0
}
ensure_ddns_cron_disabled_if_unused() {
    # 当已无域名转发规则时，自动清理 DDNS 定时任务，避免 crontab 冗余
    if has_domain_rules; then
        return 0
    fi
    if crontab -l 2>/dev/null | grep -Eq '(^|\s)(/usr/local/bin/my\s+nft\s+--cron|/usr/local/bin/nftmgr|nftmgr)\s+--cron(\s|$)'; then
        remove_ddns_cron_task || true
    fi
    return 0
}
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
# 防火墙放行（优先 ufw/firewalld；避免强行改 nft 防火墙）
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

    return 0
}

# --------------------------
# sysctl 写入（只写本脚本自己的文件）

# --------------------------
# 持久化兼容：/etc/nftables.conf include 注入/回滚
# --------------------------
nftables_conf_includes_mgr() {
    # 已经包含 nft_mgr.conf 或通配包含 /etc/nftables.d/*.conf
    [[ -f "$NFTABLES_CONF" ]] || return 1
    grep -E '^[[:space:]]*include[[:space:]]+"?/etc/nftables\.d/\*\.conf"?[[:space:]]*$' "$NFTABLES_CONF" >/dev/null 2>&1 && return 0
    grep -E '^[[:space:]]*include[[:space:]]+"?/etc/nftables\.d/nft_mgr\.conf"?[[:space:]]*$' "$NFTABLES_CONF" >/dev/null 2>&1 && return 0
    return 1
}

enable_persist_system() {
    # 兼容模式：把 nft_mgr.conf 纳入 nftables.service 的持久化体系
    mkdir -p "$NFT_MGR_DIR" 2>/dev/null || true
    [[ -f "$NFT_MGR_CONF" ]] || generate_empty_conf "$NFT_MGR_CONF"

    if [[ -e "$NFTABLES_CONF" && ! -f "$NFTABLES_CONF" ]]; then
        msg_err "❌ ${NFTABLES_CONF} 存在但不是普通文件，无法注入 include。"
        return 1
    fi

    if [[ ! -f "$NFTABLES_CONF" ]]; then
        # 最小化创建（不 flush ruleset，避免破坏系统其它规则；如你本来就有系统防火墙规则，请手动合并）
        cat > "$NFTABLES_CONF" << EOF
#!/usr/sbin/nft -f
# generated by nftmgr (compat mode)
include "${NFT_MGR_CONF}"
EOF
        chmod 644 "$NFTABLES_CONF" 2>/dev/null || true
        echo "1" > "$NFTABLES_CREATED_MARK" 2>/dev/null || true
    else
        # 备份并注入 include
        local bak="${NFTABLES_CONF}.nftmgr.bak.$(date +%s)"
        cp -a "$NFTABLES_CONF" "$bak" 2>/dev/null || true

        if ! nftables_conf_includes_mgr; then
            printf "
# nftmgr include (added %s)
include "%s"
" "$(date '+%F %T')" "$NFT_MGR_CONF" >> "$NFTABLES_CONF"
        fi
    fi

    # 校验 & 启用 nftables 持久化
    if have_cmd nft; then
        if ! nft -c -f "$NFTABLES_CONF" >/dev/null 2>&1; then
            msg_err "❌ 注入后 ${NFTABLES_CONF} 语法校验失败，已保留备份文件，请手动检查。"
            return 1
        fi
    fi

    if have_cmd systemctl; then
        systemctl enable --now nftables >/dev/null 2>&1 || true
        systemctl restart nftables >/dev/null 2>&1 || true
        # 为避免双重加载导致困惑，兼容模式下默认停用 nft-mgr oneshot
        systemctl disable --now nft-mgr >/dev/null 2>&1 || true
    else
        # 无 systemd：至少立即加载一次
        nft -f "$NFTABLES_CONF" >/dev/null 2>&1 || true
    fi
    PERSIST_MODE="system"
    msg_ok "✅ 已启用【系统持久化兼容模式】：/etc/nftables.conf 已包含 nft_mgr.conf。"
    return 0
}

enable_persist_service() {
    # 回到默认：由 nft-mgr oneshot service 负责持久化加载
    if have_cmd systemctl; then
        ensure_nft_mgr_service
        systemctl enable --now nft-mgr >/dev/null 2>&1 || true
    fi
    PERSIST_MODE="service"
    msg_ok "✅ 已启用【服务持久化模式】：由 nft-mgr.service 加载 nft_mgr.conf。"
    return 0
}

persist_status() {
    echo -e "${CYAN}========= 持久化状态 =========${PLAIN}"
    echo -e "当前模式: ${YELLOW}${PERSIST_MODE}${PLAIN}"
    if [[ -f "$NFT_MGR_CONF" ]]; then
        echo -e "规则文件: ${GREEN}${NFT_MGR_CONF}${PLAIN}"
    else
        echo -e "规则文件: ${RED}${NFT_MGR_CONF} 不存在${PLAIN}"
    fi
    if [[ -f "$NFTABLES_CONF" ]]; then
        if nftables_conf_includes_mgr; then
            echo -e "/etc/nftables.conf: ${GREEN}已包含 nftmgr 规则（include）${PLAIN}"
        else
            echo -e "/etc/nftables.conf: ${YELLOW}未包含 nftmgr include${PLAIN}"
        fi
    else
        echo -e "/etc/nftables.conf: ${YELLOW}不存在${PLAIN}"
    fi
    if have_cmd systemctl; then
        systemctl is-enabled nftables >/dev/null 2>&1 && echo -e "nftables.service: ${GREEN}enabled${PLAIN}" || echo -e "nftables.service: ${YELLOW}disabled${PLAIN}"
        systemctl is-enabled nft-mgr >/dev/null 2>&1 && echo -e "nft-mgr.service: ${GREEN}enabled${PLAIN}" || echo -e "nft-mgr.service: ${YELLOW}disabled${PLAIN}"
    fi
    echo -e "${CYAN}==============================${PLAIN}"
}

auto_persist_setup() {
    # 自动检测并完成持久化设置（无需菜单项）
    # 优先规则：
    #  1) 若系统启用了 nftables.service 或 /etc/nftables.conf 已 include nft_mgr.conf -> system 模式
    #  2) 否则使用 nft-mgr.service（service 模式）
    PERSIST_MODE="$PERSIST_MODE_DEFAULT"

    if [[ -f "$NFTABLES_CONF" ]] && nftables_conf_includes_mgr; then
        PERSIST_MODE="system"
    elif have_cmd systemctl && systemctl is-enabled nftables >/dev/null 2>&1; then
        PERSIST_MODE="system"
    fi

    if [[ "$PERSIST_MODE" == "system" ]]; then
        enable_persist_system >/dev/null 2>&1 || true
    else
        enable_persist_service >/dev/null 2>&1 || true
    fi
}
# --------------------------
nft_profile_alias() {
    case "${1:-stable}" in
        perf|extreme|turbo) echo "perf" ;;
        *) echo "stable" ;;
    esac
}

nft_profile_title() {
    [[ "$(nft_profile_alias "$1")" == "perf" ]] && echo "极致优化" || echo "稳定优先"
}

nft_detect_machine_tier() {
    local mem_mb
    mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    if (( mem_mb < 700 )); then
        echo tiny
    elif (( mem_mb < 1400 )); then
        echo small
    elif (( mem_mb < 3000 )); then
        echo medium
    else
        echo large
    fi
}

nft_best_congestion_control() {
    local avail
    avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    [[ " $avail " == *" bbr "* ]] && { echo bbr; return 0; }
    [[ " $avail " == *" cubic "* ]] && { echo cubic; return 0; }
    [[ " $avail " == *" reno "* ]] && { echo reno; return 0; }
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic
}

nft_sysctl_key_supported() {
    local key="$1"
    [[ -e "/proc/sys/${key//./\/}" ]]
}

nft_write_sysctl_line() {
    local out="$1" key="$2" value="$3"
    nft_sysctl_key_supported "$key" || return 0
    echo "${key} = ${value}" >> "$out"
}

ensure_forwarding() {
    local cur
    cur="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
    if [[ "$cur" != "1" ]]; then
        mkdir -p /etc/sysctl.d 2>/dev/null || true
        touch "$SYSCTL_FILE" 2>/dev/null || true
        if grep -qE "^\s*net\.ipv4\.ip_forward\s*=" "$SYSCTL_FILE" 2>/dev/null; then
            sed -i 's|^\s*net\.ipv4\.ip_forward\s*=.*|net.ipv4.ip_forward = 1|g' "$SYSCTL_FILE"
        else
            echo "net.ipv4.ip_forward = 1" >> "$SYSCTL_FILE"
        fi
        sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    fi
}

nft_apply_profile() {
    local mode="$(nft_profile_alias "${1:-stable}")" tier cc
    local somax backlog filemax rmax wmax fin_timeout conntrack
    tier="$(nft_detect_machine_tier)"
    cc="$(nft_best_congestion_control)"

    case "${mode}:${tier}" in
        stable:tiny|stable:small)
            somax=4096; backlog=4096; filemax=262144; rmax=8388608;  wmax=8388608;  fin_timeout=30; conntrack=131072 ;;
        stable:medium)
            somax=8192; backlog=8192; filemax=524288; rmax=16777216; wmax=16777216; fin_timeout=25; conntrack=262144 ;;
        stable:large)
            somax=16384; backlog=16384; filemax=524288; rmax=33554432; wmax=33554432; fin_timeout=20; conntrack=524288 ;;
        perf:tiny|perf:small)
            somax=16384; backlog=16384; filemax=524288; rmax=16777216; wmax=16777216; fin_timeout=20; conntrack=262144 ;;
        perf:medium)
            somax=32768; backlog=32768; filemax=1048576; rmax=33554432; wmax=33554432; fin_timeout=15; conntrack=524288 ;;
        perf:large)
            somax=65535; backlog=65535; filemax=1048576; rmax=67108864; wmax=67108864; fin_timeout=15; conntrack=1048576 ;;
        *)
            somax=8192; backlog=8192; filemax=524288; rmax=16777216; wmax=16777216; fin_timeout=25; conntrack=262144 ;;
    esac

    mkdir -p /etc/sysctl.d 2>/dev/null || true
    : > "$SYSCTL_FILE"
    chmod 644 "$SYSCTL_FILE" 2>/dev/null || true
    echo "# nftmgr $(nft_profile_title "$mode") / ${tier}" >> "$SYSCTL_FILE"

    nft_write_sysctl_line "$SYSCTL_FILE" "net.ipv4.ip_forward" "1"
    [[ "$cc" == "bbr" ]] && nft_write_sysctl_line "$SYSCTL_FILE" "net.core.default_qdisc" "fq"
    nft_write_sysctl_line "$SYSCTL_FILE" "net.ipv4.tcp_congestion_control" "$cc"
    nft_write_sysctl_line "$SYSCTL_FILE" "net.ipv4.tcp_mtu_probing" "1"
    nft_write_sysctl_line "$SYSCTL_FILE" "net.core.somaxconn" "$somax"
    nft_write_sysctl_line "$SYSCTL_FILE" "net.core.netdev_max_backlog" "$backlog"
    nft_write_sysctl_line "$SYSCTL_FILE" "fs.file-max" "$filemax"
    nft_write_sysctl_line "$SYSCTL_FILE" "net.core.rmem_max" "$rmax"
    nft_write_sysctl_line "$SYSCTL_FILE" "net.core.wmem_max" "$wmax"
    nft_write_sysctl_line "$SYSCTL_FILE" "net.ipv4.tcp_rmem" "8192 262144 ${rmax}"
    nft_write_sysctl_line "$SYSCTL_FILE" "net.ipv4.tcp_wmem" "8192 262144 ${wmax}"
    nft_write_sysctl_line "$SYSCTL_FILE" "net.ipv4.tcp_fin_timeout" "$fin_timeout"
    nft_write_sysctl_line "$SYSCTL_FILE" "net.ipv4.ip_local_port_range" "10240 65535"
    nft_write_sysctl_line "$SYSCTL_FILE" "net.netfilter.nf_conntrack_max" "$conntrack"

    if [[ "$mode" == "perf" ]]; then
        nft_write_sysctl_line "$SYSCTL_FILE" "net.ipv4.tcp_fastopen" "3"
        nft_write_sysctl_line "$SYSCTL_FILE" "net.ipv4.tcp_tw_reuse" "1"
        nft_write_sysctl_line "$SYSCTL_FILE" "net.ipv4.tcp_notsent_lowat" "16384"
    fi

    sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true

    if have_cmd systemctl; then
        systemctl enable --now nftables >/dev/null 2>&1 || true
        ensure_nft_mgr_service
    fi
    auto_persist_setup

    msg_ok "✅ 已应用 NFT 智能调优：$(nft_profile_title "$mode") / ${tier} / ${cc}"
    sleep 2
}

optimize_system() {
    clear
    echo -e "${GREEN}--- NFT 智能调优中心 ---${PLAIN}"
    echo "1) 稳定优先：保守提升转发与并发"
    echo "2) 极致优化：激进提升队列/并发/连接追踪"
    echo "0) 返回"
    echo "--------------------------------"
    read -rp "请选择 [0-2]: " pick
    case "$pick" in
        0) return ;;
        1) nft_apply_profile "stable" ;;
        2) nft_apply_profile "extreme" ;;
        *) msg_err "无效选项"; sleep 1 ;;
    esac
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
        echo "        type nat hook prerouting priority -100;"

        while IFS='|' read -r lp addr tp last_ip proto; do
            [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
            proto="$(normalize_proto "$proto")"
            is_port "$lp" || continue
            is_port "$tp" || continue
            [[ -z "$addr" ]] && continue

            local ip
            ip="$last_ip"
            [[ -z "$ip" ]] && ip="$(get_ip "$addr")"
            is_ipv4 "$ip" || continue

            case "$proto" in
                tcp)
                    echo "        tcp dport ${lp} counter dnat to ${ip}:${tp}"
                    any=1
                    ;;
                udp)
                    echo "        udp dport ${lp} counter dnat to ${ip}:${tp}"
                    any=1
                    ;;
                both)
                    echo "        tcp dport ${lp} counter dnat to ${ip}:${tp}"
                    echo "        udp dport ${lp} counter dnat to ${ip}:${tp}"
                    any=1
                    ;;
            esac
        done < "$CONFIG_FILE"

        echo "    }"
        echo "    chain postrouting {"
        echo "        type nat hook postrouting priority 100;"

        while IFS='|' read -r lp addr tp last_ip proto; do
            [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
            proto="$(normalize_proto "$proto")"
            is_port "$lp" || continue
            is_port "$tp" || continue
            [[ -z "$addr" ]] && continue

            local ip
            ip="$last_ip"
            [[ -z "$ip" ]] && ip="$(get_ip "$addr")"
            is_ipv4 "$ip" || continue

            case "$proto" in
                tcp)
                    echo "        ip daddr ${ip} tcp dport ${tp} counter masquerade"
                    any=1
                    ;;
                udp)
                    echo "        ip daddr ${ip} udp dport ${tp} counter masquerade"
                    any=1
                    ;;
                both)
                    echo "        ip daddr ${ip} tcp dport ${tp} counter masquerade"
                    echo "        ip daddr ${ip} udp dport ${tp} counter masquerade"
                    any=1
                    ;;
            esac
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
        generate_empty_conf "$tmp"
        has_rules=0
    fi

    if ! have_cmd nft; then
        rm -f "$tmp"
        return 1
    fi

    # 语法检查
    local chk_err
    chk_err="$(nft -c -f "$tmp" 2>&1)"
    if [[ $? -ne 0 ]]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || true
        echo "[$(date '+%F %T')] nft -c error:" > "${LOG_DIR}/last_nft_error.log"
        echo "$chk_err" >> "${LOG_DIR}/last_nft_error.log"
        msg_err "❌ nft 规则语法校验失败：未应用、未写入持久化文件。"
        msg_err "   详情: ${LOG_DIR}/last_nft_error.log"
        rm -f "$tmp"
        return 1
    fi


    # 应用（只动自己的表）
    nft delete table ip nft_mgr_nat >/dev/null 2>&1 || true
    local apply_err
    apply_err="$(nft -f "$tmp" 2>&1)"
    if [[ $? -ne 0 ]]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || true
        echo "[$(date '+%F %T')] nft apply error:" > "${LOG_DIR}/last_nft_error.log"
        echo "$apply_err" >> "${LOG_DIR}/last_nft_error.log"
        msg_err "❌ nft 规则应用失败：未写入持久化文件。"
        msg_err "   详情: ${LOG_DIR}/last_nft_error.log"
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

    # 持久化策略：
    #  - service: 启用 nft-mgr oneshot（默认，最不干扰系统）
    #  - system : 注入 /etc/nftables.conf include，并通过 nftables.service 持久化（兼容部分面板/节点管理）
    if [[ "$PERSIST_MODE" == "system" ]]; then
        # 仅确保 include 存在，不强行重写系统规则
        enable_persist_system >/dev/null 2>&1 || true
    else
        if have_cmd systemctl; then
            systemctl enable nft-mgr >/dev/null 2>&1 || true
        fi
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

    echo -e "${CYAN}正在解析并验证目标地址...${PLAIN}"
    tip="$(get_ip "$taddr")"
    [[ -z "$tip" ]] && { msg_err "错误: 解析失败，请检查域名或服务器网络/DNS。"; sleep 2; return 1; }

    local conf_bak
    conf_bak="$(mktemp /tmp/nftmgr-conf.XXXXXX)"
    cp -a "$CONFIG_FILE" "$conf_bak" 2>/dev/null || true

    echo "${lport}|${taddr}|${tport}|${tip}|${proto}" >> "$CONFIG_FILE"

    if ! apply_rules_impl; then
        [[ -s "$conf_bak" ]] && mv -f "$conf_bak" "$CONFIG_FILE" || true
        msg_err "❌ 应用规则失败：已回滚本次新增配置。"
        sleep 2
        return 1
    fi
    rm -f "$conf_bak" 2>/dev/null || true

    manage_firewall "add" "$lport" "$proto" || true

    # 目标为域名：自动启用 DDNS 每分钟检测（联动）
    if ! is_ipv4 "$taddr"; then
        ensure_ddns_cron_enabled
        msg_info "已检测到目标为域名：已自动启用 DDNS 每分钟检测（crontab）。"
    fi

    msg_ok "添加成功！映射路径: [本机] ${lport}/${proto} -> [目标] ${taddr}:${tport} (${tip})"
    sleep 2
    return 0
}

add_forward() { with_lock add_forward_impl; }

# --------------------------
# 规则管理（查看/删除）
# --------------------------
view_and_del_forward_impl() {
    clear
    if [[ ! -s "$CONFIG_FILE" ]]; then
        msg_warn "当前没有任何转发规则。"
        read -rp "按回车返回主菜单..."
        return 0
    fi

    # 规则列表（已移除实时流量看板 / Traffic Counters）
    echo -e "${CYAN}=========================== 规则管理 (查看/删除) ===========================${PLAIN}"
    printf "%-4s | %-6s | %-5s | %-32s | %-6s\n" "序号" "本地" "协议" "目标地址" "目标"
    echo "--------------------------------------------------------------------------"

    local i=1
    while IFS='|' read -r lp addr tp last_ip proto; do
        [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
        proto="$(normalize_proto "$proto")"
        is_port "$lp" || continue
        is_port "$tp" || continue

        local short_addr="${addr:0:31}"
        printf "%-4s | %-6s | %-5s | %-32s | %-6s\n" "$i" "$lp" "$proto" "$short_addr" "$tp"
        ((i++))
    done < "$CONFIG_FILE"

    echo "--------------------------------------------------------------------------"
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

    # 联动：若已无域名规则，则自动清理 DDNS 定时任务
    ensure_ddns_cron_disabled_if_unused

    msg_ok "已成功删除本地端口为 ${del_port}/${del_proto} 的转发规则。"
    sleep 2
    return 0
}

view_and_del_forward() { with_lock view_and_del_forward_impl; }

# --------------------------
# DDNS 追踪更新（域名 -> IP 变化） + 严格模式失败通知
# --------------------------
ddns_update_impl() {
    local changed=0
    local temp_file
    temp_file="$(mktemp /tmp/nftmgr-ddns.XXXXXX)"

    [[ -d "$LOG_DIR" ]] || mkdir -p "$LOG_DIR"
    local today_log="$LOG_DIR/$(date '+%Y-%m-%d').log"

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" ]]; then
            echo "" >> "$temp_file"
            continue
        fi
        if [[ "${line:0:1}" == "#" ]]; then
            echo "$line" >> "$temp_file"
            continue
        fi

        local lp addr tp last_ip proto
        IFS='|' read -r lp addr tp last_ip proto <<< "$line"
        proto="$(normalize_proto "$proto")"

        if ! is_port "$lp" || ! is_port "$tp" || [[ -z "$addr" ]]; then
            echo "$line" >> "$temp_file"
            continue
        fi

        local current_ip
        current_ip="$(get_ip "$addr")"

        if [[ -z "$current_ip" ]] && ! is_ipv4 "$addr"; then
            # 域名解析失败：记录并（严格模式）判定失败
            echo "[$(date '+%H:%M:%S')] [ERROR] 端口 ${lp}: 域名 ${addr} 解析失败（保持 last_ip=${last_ip:-N/A}）" >> "$today_log"
            echo "${lp}|${addr}|${tp}|${last_ip}|${proto}" >> "$temp_file"
            continue
        fi

        if [[ -n "$current_ip" && "$current_ip" != "$last_ip" ]]; then
            echo "${lp}|${addr}|${tp}|${current_ip}|${proto}" >> "$temp_file"
            changed=1
            echo "[$(date '+%H:%M:%S')] 端口 ${lp}: ${addr} 变动 (${last_ip:-N/A} -> ${current_ip})" >> "$today_log"
        else
            echo "${lp}|${addr}|${tp}|${last_ip}|${proto}" >> "$temp_file"
        fi
    done < "$CONFIG_FILE"

    mv -f "$temp_file" "$CONFIG_FILE"

    if [[ $changed -eq 1 ]]; then
        if ! apply_rules_impl; then
            echo "[$(date '+%H:%M:%S')] [ERROR] 应用 nft 规则失败（已保留配置，但规则未更新）" >> "$today_log"
        fi
    fi

    # 日志保留
    find "$LOG_DIR" -type f -name "*.log" -mtime +7 -exec rm -f {} \; 2>/dev/null || true
    return 0
}

ddns_update() { with_lock ddns_update_impl; }


# --------------------------
# 定时任务管理（DDNS）
# --------------------------
manage_cron() {
    clear
    local my_cmd="/usr/local/bin/my"
    if crontab -l 2>/dev/null | grep -Fq "${my_cmd} nft --cron"; then
        echo -e "${GREEN}--- 管理定时监控 (DDNS 同步) --- [已启用]${PLAIN}"
    else
        echo -e "${GREEN}--- 管理定时监控 (DDNS 同步) --- [未启用]${PLAIN}"
    fi
    echo "1. 自动添加定时任务 (每分钟检测，默认非严格)"
    echo "2. 一键删除定时任务"
    echo "3. 查看 DDNS 变动历史日志 (仅保留最近7天)"
    echo "0. 返回主菜单"
    echo "--------------------------------"
    local cron_choice
    read -rp "请选择操作 [0-3]: " cron_choice

    case "$cron_choice" in
        1)
            if crontab -l 2>/dev/null | grep -Fq "${my_cmd} nft --cron"; then
                msg_warn "定时任务已存在。"
                sleep 2
                return
            fi
            remove_ddns_cron_task || true
            (crontab -l 2>/dev/null; echo "* * * * * ${my_cmd} nft --cron > /dev/null 2>&1") | crontab - 2>/dev/null || true
            msg_ok "定时任务已添加！将自动检查 IP 并生成日志。"
            sleep 2
            ;;
        2)
            remove_ddns_cron_task || true
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
    ensure_ddns_cron_disabled_if_unused

msg_ok "✅ 所有规则已清空。"
    sleep 2
}

clear_all_rules() { with_lock clear_all_rules_impl; }

# --------------------------
# 完全卸载
# --------------------------
cleanup_nft_artifacts() {
    while IFS='|' read -r lp addr tp last_ip proto; do
        [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
        is_port "$lp" || continue
        proto="$(normalize_proto "$proto")"
        manage_firewall "del" "$lp" "$proto" || true
    done < "$CONFIG_FILE" 2>/dev/null || true

    have_cmd nft && nft delete table ip nft_mgr_nat >/dev/null 2>&1 || true
    remove_ddns_cron_task || true

    if have_cmd systemctl; then
        systemctl disable --now nft-mgr >/dev/null 2>&1 || true
        rm -f "$NFT_MGR_SERVICE" 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    if [[ -f "$NFTABLES_CONF" ]]; then
        sed -i '/# nftmgr include (added .*$/d' "$NFTABLES_CONF" 2>/dev/null || true
        sed -i '/# nftmgr persistent include$/d' "$NFTABLES_CONF" 2>/dev/null || true
        sed -i '\|include "/etc/nftables.d/nft_mgr.conf"|d' "$NFTABLES_CONF" 2>/dev/null || true
    fi

    if [[ -f "$NFTABLES_CREATED_MARK" ]]; then
        rm -f "$NFTABLES_CREATED_MARK" 2>/dev/null || true
        local latest_bak=""
        latest_bak="$(ls -1t ${NFTABLES_CONF}.nftmgr.bak.* 2>/dev/null | head -n 1)"
        if [[ -n "$latest_bak" && -f "$latest_bak" ]]; then
            cp -a "$latest_bak" "$NFTABLES_CONF" 2>/dev/null || true
        else
            rm -f "$NFTABLES_CONF" 2>/dev/null || true
            if have_cmd systemctl; then
                systemctl disable --now nftables >/dev/null 2>&1 || true
            fi
        fi
    fi

    rm -f ${NFTABLES_CONF}.nftmgr.bak.* 2>/dev/null || true
    rm -f "$NFT_MGR_CONF" "$CONFIG_FILE" "$SETTINGS_FILE" "$SYSCTL_FILE" "$LOCK_FILE" 2>/dev/null || true
    rm -rf "$LOG_DIR" 2>/dev/null || true
    rmdir "$NFT_MGR_DIR" 2>/dev/null || true

    if have_cmd systemctl; then
        systemctl restart nftables >/dev/null 2>&1 || true
    fi
}

uninstall_script_impl() {
    clear
    echo -e "${RED}--- 卸载 nftables 端口转发管理面板 ---${PLAIN}"
    read -rp "警告: 此操作将删除本脚本、规则配置、定时任务、systemd 服务，并移除本脚本创建的 nft 表。确认？[y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return 0

    cleanup_nft_artifacts
    msg_ok "✅ 卸载完成（已清理脚本残留）。"

    rm -f "/usr/local/bin/${CMD_NAME}" 2>/dev/null || true
    exit 0
}

uninstall_script() { with_lock uninstall_script_impl; }
# --------------------------
# 主菜单
# --------------------------
main_menu() {
    clear
    echo -e "${GREEN}==========================================${PLAIN}"
    echo -e "${GREEN}     nftables 端口转发管理面板 (Pro)      ${PLAIN}"
    echo -e "${GREEN}==========================================${PLAIN}"
    echo "1. 智能系统调优 (稳定/极致)"
    echo "2. 新增端口转发 (支持域名/IP，支持TCP/UDP选择)"
    echo "3. 规则管理 (查看/删除)"
    echo "4. 清空所有转发规则"
    echo "5. 管理 DDNS 定时监控与日志"
    echo "0. 退出面板"
    echo "------------------------------------------"
    local choice
    read -rp "请选择操作 [0-5]: " choice

    case "$choice" in
        1) optimize_system ;;
        2) add_forward ;;
        3) view_and_del_forward ;;
        4) clear_all_rules ;;
        5) manage_cron ;;
        0) exit 0 ;;
        *) msg_err "无效选项"; sleep 1 ;;
    esac
}

NFT_MODULE_EOF

    # Nginx 反向代理模块（并入 my 统一管理，避免与 Certbot/多站点冲突）
    cat > "${NGX_MODULE_FILE}" <<'NGX_MODULE_EOF'
#!/bin/bash
set -o pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly RESET='\033[0m'

readonly MY_NGX_ID="my-nginx-proxy"
readonly NGX_META_DIR="/usr/local/etc/my_nginx_proxy"
readonly NGX_STATE_FILE="${NGX_META_DIR}/state.conf"
readonly NGX_COMMON_CONF="/etc/nginx/conf.d/00-my-rproxy-common.conf"
readonly NGX_CONF_PREFIX="/etc/nginx/conf.d/my-rproxy"
readonly NGX_WEBROOT="/var/lib/my-nginx-proxy/acme"
readonly NGX_WORKDIR="/var/lib/my-nginx-proxy"
readonly NGX_TMP_DIR="${NGX_WORKDIR}/tmp"
readonly NGX_LOG_DIR="/var/log/nginx"

ngx_have_cmd() { command -v "$1" >/dev/null 2>&1; }
ngx_msg_ok() { echo -e "${GREEN}$*${RESET}"; }
ngx_msg_warn() { echo -e "${YELLOW}$*${RESET}"; }
ngx_msg_err() { echo -e "${RED}$*${RESET}"; }
ngx_msg_info() { echo -e "${CYAN}$*${RESET}"; }
ngx_pause() { read -n 1 -s -r -p "按任意键继续..."; echo; }

ngx_state_get() {
    local key="$1"
    [[ -f "$NGX_STATE_FILE" ]] || return 1
    grep -E "^${key}=" "$NGX_STATE_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- | sed 's/^"//; s/"$//'
}

ngx_state_set() {
    local key="$1" value="$2"
    mkdir -p "$NGX_META_DIR" 2>/dev/null || true
    touch "$NGX_STATE_FILE"
    chmod 600 "$NGX_STATE_FILE" 2>/dev/null || true
    if grep -qE "^${key}=" "$NGX_STATE_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|g" "$NGX_STATE_FILE"
    else
        echo "${key}=\"${value}\"" >> "$NGX_STATE_FILE"
    fi
}

ngx_pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

ngx_state_init_if_needed() {
    [[ "$(ngx_state_get STATE_INIT)" == "1" ]] && return 0
    ngx_state_set STATE_INIT 1
    ngx_pkg_installed nginx && ngx_state_set PKG_NGINX_BY_MY 0 || ngx_state_set PKG_NGINX_BY_MY 1
    ngx_pkg_installed certbot && ngx_state_set PKG_CERTBOT_BY_MY 0 || ngx_state_set PKG_CERTBOT_BY_MY 1
    ngx_pkg_installed python3-certbot-nginx && ngx_state_set PKG_CERTBOT_NGINX_BY_MY 0 || ngx_state_set PKG_CERTBOT_NGINX_BY_MY 1
}

ngx_require_apt() {
    ngx_have_cmd apt-get || { ngx_msg_err "当前仅支持 Debian/Ubuntu 系 apt 环境。"; return 1; }
}

ngx_validate_domain() {
    local d="${1,,}"
    [[ -n "$d" ]] || return 1
    [[ "$d" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || return 1
    [[ "$d" == *.* ]] || return 1
    [[ "$d" != *..* ]] || return 1
    return 0
}

ngx_is_ip_literal() {
    local h="$1"
    [[ "$h" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0
    [[ "$h" =~ ^\[[0-9a-fA-F:]+\]$ ]] && return 0
    return 1
}

ngx_parse_backend() {
    local input="$1"
    NGX_BACKEND_PROTO="http"
    local rest="$input"
    if [[ "$input" == https://* ]]; then
        NGX_BACKEND_PROTO="https"
        rest="${input#https://}"
    elif [[ "$input" == http://* ]]; then
        NGX_BACKEND_PROTO="http"
        rest="${input#http://}"
    fi
    rest="${rest%/}"
    [[ -n "$rest" ]] || return 1

    local host port
    if [[ "$rest" =~ ^\[[0-9a-fA-F:]+\]:[0-9]+$ ]]; then
        host="${rest%%]:*}]"
        port="${rest##*:}"
    else
        host="${rest%:*}"
        port="${rest##*:}"
        [[ "$host" != "$rest" ]] || return 1
    fi

    [[ -n "$host" && "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1

    NGX_BACKEND_RAW="$input"
    NGX_BACKEND_HOST="$host"
    NGX_BACKEND_PORT="$port"
    NGX_BACKEND_ADDR="$rest"
    return 0
}

ngx_proxy_ssl_block() {
    if [[ "$NGX_BACKEND_PROTO" == "https" ]]; then
        if ngx_is_ip_literal "$NGX_BACKEND_HOST"; then
            printf '%s\n' '        proxy_ssl_server_name off;'
        else
            printf '%s\n' '        proxy_ssl_server_name on;'
            printf '        proxy_ssl_name %s;\n' "$NGX_BACKEND_HOST"
        fi
    fi
}

ngx_site_conf() {
    printf '%s\n' "${NGX_CONF_PREFIX}.${1}.conf"
}

ngx_write_common_conf() {
    mkdir -p /etc/nginx/conf.d "$NGX_WEBROOT" "$NGX_TMP_DIR" "$NGX_META_DIR" 2>/dev/null || true
    cat > "$NGX_COMMON_CONF" <<'EOF'
# managed-by=my-nginx-proxy
map $http_upgrade $my_proxy_connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
}

ngx_test_reload() {
    nginx -t >/dev/null 2>&1 || return 1
    systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || return 1
    return 0
}

ngx_install_dependencies() {
    ngx_require_apt || return 1
    ngx_state_init_if_needed
    export DEBIAN_FRONTEND=noninteractive
    ngx_msg_info "检查并安装 Nginx / Certbot 环境..."
    apt-get update -qq || return 1
    apt-get install -y -qq nginx certbot curl ca-certificates >/dev/null || return 1
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl start nginx >/dev/null 2>&1 || true
    ngx_write_common_conf
    ngx_msg_ok "环境依赖就绪。"
}

ngx_domain_dns_hint() {
    local domain="$1" pub4="" pub6="" dns4="" dns6=""
    ngx_have_cmd curl && pub4="$(curl -4 -fsS --connect-timeout 3 --max-time 6 https://api.ip.sb/ip 2>/dev/null || true)"
    ngx_have_cmd curl && pub6="$(curl -6 -fsS --connect-timeout 3 --max-time 6 https://api64.ipify.org 2>/dev/null || true)"
    dns4="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd ',' -)"
    dns6="$(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd ',' -)"
    [[ -n "$dns4$dns6" ]] || { ngx_msg_warn "提示：当前本机未解析到 ${domain} 的 DNS 记录，证书申请可能失败。"; return 0; }
    [[ -n "$pub4" && ",$dns4," != *",$pub4,"* ]] && ngx_msg_warn "提示：${domain} 的 IPv4 DNS 未命中本机公网 IPv4 ${pub4}。"
    [[ -n "$pub6" && -n "$dns6" && ",$dns6," != *",$pub6,"* ]] && ngx_msg_warn "提示：${domain} 的 IPv6 DNS 未命中本机公网 IPv6 ${pub6}。"
}

ngx_render_http_conf() {
    local domain="$1"
    cat <<EOF
# managed-by=${MY_NGX_ID}
# domain=${domain}
# backend=${NGX_BACKEND_RAW}
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    access_log ${NGX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGX_LOG_DIR}/${domain}_error.log;

    location ^~ /.well-known/acme-challenge/ {
        root ${NGX_WEBROOT};
        default_type "text/plain";
    }

    location / {
        proxy_pass ${NGX_BACKEND_PROTO}://${NGX_BACKEND_ADDR};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$my_proxy_connection_upgrade;
        proxy_connect_timeout 90s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        proxy_buffering off;
        proxy_cache off;
$(ngx_proxy_ssl_block)
    }
}
EOF
}

ngx_render_https_conf() {
    local domain="$1"
    cat <<EOF
# managed-by=${MY_NGX_ID}
# domain=${domain}
# backend=${NGX_BACKEND_RAW}
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    location ^~ /.well-known/acme-challenge/ {
        root ${NGX_WEBROOT};
        default_type "text/plain";
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain};

    access_log ${NGX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGX_LOG_DIR}/${domain}_error.log;

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    client_max_body_size 0;
    server_tokens off;
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 5;
    gzip_types text/plain text/css text/xml application/json application/javascript application/rss+xml application/atom+xml image/svg+xml;

    location / {
        proxy_pass ${NGX_BACKEND_PROTO}://${NGX_BACKEND_ADDR};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$my_proxy_connection_upgrade;
        proxy_connect_timeout 90s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        proxy_buffering off;
        proxy_cache off;
$(ngx_proxy_ssl_block)
    }
}
EOF
}

ngx_install_conf_from_stdin() {
    local dst="$1"
    local tmp
    tmp="$(mktemp "${NGX_TMP_DIR}/conf.XXXXXX")" || return 1
    cat > "$tmp"
    install -m 644 "$tmp" "$dst" 2>/dev/null || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

ngx_delete_cert_if_exists() {
    local domain="$1"
    certbot delete --cert-name "$domain" --non-interactive --quiet >/dev/null 2>&1 || true
}

ngx_delete_proxy_domain() {
    local domain="${1,,}"
    ngx_validate_domain "$domain" || { ngx_msg_err "域名格式无效。"; return 1; }
    local conf
    conf="$(ngx_site_conf "$domain")"
    [[ -f "$conf" ]] || { ngx_msg_err "未找到由本脚本管理的域名 ${domain}。"; return 1; }

    ngx_delete_cert_if_exists "$domain"
    rm -f "$conf" "${NGX_LOG_DIR}/${domain}_access.log" "${NGX_LOG_DIR}/${domain}_error.log" 2>/dev/null || true
    if ngx_have_cmd nginx && ngx_test_reload; then
        ngx_msg_ok "域名 ${domain} 的反代与证书已清理。"
    else
        ngx_msg_warn "配置文件已删除，但 Nginx 重载失败，请检查其它非本脚本配置。"
    fi
    return 0
}

ngx_list_proxies() {
    echo -e "${CYAN}=== 当前由本脚本管理的反向代理 ===${RESET}"
    local conf count=0 domain backend
    shopt -s nullglob
    for conf in /etc/nginx/conf.d/my-rproxy.*.conf; do
        domain="$(basename "$conf")"
        domain="${domain#my-rproxy.}"
        domain="${domain%.conf}"
        backend="$(grep -E '^# backend=' "$conf" 2>/dev/null | head -n1 | cut -d= -f2-)"
        [[ -n "$backend" ]] || backend="未知"
        count=$((count+1))
        echo -e " ${GREEN}${count}.${RESET} ${domain}  ==>  ${YELLOW}${backend}${RESET}"
    done
    shopt -u nullglob
    [[ $count -eq 0 ]] && echo -e "${YELLOW}当前未发现任何由本脚本管理的 Nginx 代理配置。${RESET}"
    echo "------------------------------------------------"
}

ngx_delete_proxy_pick() {
    local conf domain backend idx=0 pick
    local -a domains backends
    shopt -s nullglob
    for conf in /etc/nginx/conf.d/my-rproxy.*.conf; do
        domain="$(basename "$conf")"
        domain="${domain#my-rproxy.}"
        domain="${domain%.conf}"
        backend="$(grep -E '^# backend=' "$conf" 2>/dev/null | head -n1 | cut -d= -f2-)"
        [[ -n "$backend" ]] || backend="未知"
        domains[idx]="$domain"
        backends[idx]="$backend"
        idx=$((idx+1))
    done
    shopt -u nullglob

    if [[ ${#domains[@]} -eq 0 ]]; then
        ngx_msg_warn "当前没有可删除的反向代理。"
        return 1
    fi

    echo -e "${CYAN}=== 按序号删除反向代理 ===${RESET}"
    local i display
    for ((i=0; i<${#domains[@]}; i++)); do
        display=$((i+1))
        echo -e " ${GREEN}${display}.${RESET} ${domains[i]}  ==>  ${YELLOW}${backends[i]}${RESET}"
    done
    read -rp "请输入要删除的序号 [1-${#domains[@]}]，直接回车取消: " pick
    [[ -z "$pick" ]] && { ngx_msg_warn "已取消删除。"; return 1; }
    [[ "$pick" =~ ^[0-9]+$ ]] || { ngx_msg_err "请输入有效序号。"; return 1; }
    (( pick >= 1 && pick <= ${#domains[@]} )) || { ngx_msg_err "序号超出范围。"; return 1; }

    local target="${domains[$((pick-1))]}"
    read -rp "确认删除 ${target} ? [y/N]: " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { ngx_msg_warn "已取消删除。"; return 1; }
    ngx_delete_proxy_domain "$target"
}

ngx_add_proxy() {
    local backend_input domain_name cert_email conf tmp_final
    echo -e "${CYAN}=== 添加新的反向代理 ===${RESET}"
    ngx_install_dependencies || { ngx_msg_err "依赖安装失败。"; sleep 2; return 1; }

    while :; do
        read -rp "后端服务地址（格式: IP:端口 / 域名:端口 / http:// / https://）: " backend_input
        ngx_parse_backend "$backend_input" && break
        ngx_msg_err "后端地址格式无效，请重新输入。"
    done
    while :; do
        read -rp "绑定域名（请确保已解析到本机）: " domain_name
        domain_name="${domain_name,,}"
        ngx_validate_domain "$domain_name" && break
        ngx_msg_err "域名格式无效，请重新输入。"
    done
    read -rp "申请证书邮箱（可留空）: " cert_email

    conf="$(ngx_site_conf "$domain_name")"
    if [[ -f "$conf" ]]; then
        ngx_msg_err "域名 ${domain_name} 的配置已存在，请先删除或更换域名。"
        sleep 2
        return 1
    fi

    ngx_domain_dns_hint "$domain_name"
    ngx_write_common_conf
    mkdir -p "$NGX_WEBROOT" "$NGX_TMP_DIR" 2>/dev/null || true

    ngx_render_http_conf "$domain_name" | ngx_install_conf_from_stdin "$conf" || { ngx_msg_err "写入 HTTP 配置失败。"; return 1; }
    if ! ngx_test_reload; then
        rm -f "$conf"
        ngx_msg_err "Nginx 配置验证失败，已回滚。"
        sleep 2
        return 1
    fi

    local email_args=()
    if [[ -n "$cert_email" ]]; then
        email_args=(--email "$cert_email")
    else
        email_args=(--register-unsafely-without-email)
    fi

    ngx_msg_info "开始申请 SSL 证书..."
    if ! certbot certonly --webroot -w "$NGX_WEBROOT" --non-interactive --agree-tos "${email_args[@]}" -d "$domain_name" >/dev/null 2>&1; then
        rm -f "$conf"
        ngx_test_reload >/dev/null 2>&1 || true
        ngx_delete_cert_if_exists "$domain_name"
        ngx_msg_err "SSL 证书申请失败，已自动回滚配置。"
        sleep 2
        return 1
    fi

    tmp_final="$(mktemp "${NGX_TMP_DIR}/final.XXXXXX")" || { ngx_delete_cert_if_exists "$domain_name"; rm -f "$conf"; return 1; }
    ngx_render_https_conf "$domain_name" > "$tmp_final"
    install -m 644 "$tmp_final" "$conf" 2>/dev/null || { rm -f "$tmp_final"; ngx_delete_cert_if_exists "$domain_name"; rm -f "$conf"; return 1; }
    rm -f "$tmp_final"

    if ! ngx_test_reload; then
        rm -f "$conf"
        ngx_delete_cert_if_exists "$domain_name"
        ngx_test_reload >/dev/null 2>&1 || true
        ngx_msg_err "最终 HTTPS 配置校验失败，已回滚。"
        sleep 2
        return 1
    fi

    ngx_msg_ok "✅ 部署完成：https://${domain_name}"
    return 0
}

nginx_cleanup_artifacts() {
    local conf domain
    shopt -s nullglob
    for conf in /etc/nginx/conf.d/my-rproxy.*.conf; do
        domain="$(basename "$conf")"
        domain="${domain#my-rproxy.}"
        domain="${domain%.conf}"
        ngx_delete_cert_if_exists "$domain"
        rm -f "$conf" "${NGX_LOG_DIR}/${domain}_access.log" "${NGX_LOG_DIR}/${domain}_error.log" 2>/dev/null || true
    done
    shopt -u nullglob

    rm -f "$NGX_COMMON_CONF" 2>/dev/null || true

    if ngx_have_cmd nginx; then
        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx >/dev/null 2>&1 || true
        fi
    fi

    if [[ "$(ngx_state_get PKG_CERTBOT_NGINX_BY_MY)" == "1" || "$(ngx_state_get PKG_CERTBOT_BY_MY)" == "1" || "$(ngx_state_get PKG_NGINX_BY_MY)" == "1" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        [[ "$(ngx_state_get PKG_CERTBOT_NGINX_BY_MY)" == "1" ]] && apt-get purge -y -qq python3-certbot-nginx >/dev/null 2>&1 || true
        [[ "$(ngx_state_get PKG_CERTBOT_BY_MY)" == "1" ]] && apt-get purge -y -qq certbot >/dev/null 2>&1 || true
        [[ "$(ngx_state_get PKG_NGINX_BY_MY)" == "1" ]] && apt-get purge -y -qq nginx nginx-common nginx-core >/dev/null 2>&1 || true
        apt-get autoremove -y -qq >/dev/null 2>&1 || true
        apt-get clean -qq >/dev/null 2>&1 || true
        [[ "$(ngx_state_get PKG_NGINX_BY_MY)" == "1" ]] && rm -rf /etc/nginx /var/log/nginx 2>/dev/null || true
        [[ "$(ngx_state_get PKG_CERTBOT_BY_MY)" == "1" ]] && rm -rf /var/lib/letsencrypt 2>/dev/null || true
    fi

    rm -rf "$NGX_META_DIR" "$NGX_WORKDIR" 2>/dev/null || true
}

nginx_menu() {
    while true; do
        clear
        echo -e "${CYAN}================================================${RESET}"
        echo -e "${GREEN}      Nginx 反向代理与 HTTPS 管理中心         ${RESET}"
        echo -e "${CYAN}================================================${RESET}"
        echo "  1. ➕ 添加新的反向代理 (含 HTTPS)"
        echo "  2. 🔍 查看已配置的代理列表"
        echo "  3. 🗑️  按序号删除反向代理"
        echo "  4. 🔧 重新安装/修复依赖环境"
        echo "  0. 返回上级菜单"
        echo -e "${CYAN}================================================${RESET}"
        read -rp "请输入选项 [0-4]: " choice
        case "$choice" in
            1) ngx_add_proxy; ngx_pause ;;
            2) ngx_list_proxies; ngx_pause ;;
            3) ngx_delete_proxy_pick; ngx_pause ;;
            4) ngx_install_dependencies; ngx_pause ;;
            0) return ;;
            *) ngx_msg_err "无效的选项，请重新输入。"; sleep 1 ;;
        esac
    done
}
NGX_MODULE_EOF

    chmod 755 "${SSR_MODULE_FILE}" "${NFT_MODULE_FILE}" "${NGX_MODULE_FILE}" 2>/dev/null || true
}

# --------------------------
# Cron 管理
# --------------------------
_cron_dump() {
    crontab -l 2>/dev/null || true
}

cron_remove_regex() {
    local reg="$1"
    _cron_dump | grep -vE "$reg" | crontab - 2>/dev/null || true
}

cron_add_line_once() {
    local line="$1"
    # 已存在则跳过
    _cron_dump | grep -Fq "$line" && return 0
    ( _cron_dump; echo "$line" ) | crontab - 2>/dev/null || true
}

ensure_global_clean_cron() {
    local my_cmd="/usr/local/bin/${CMD_NAME}"
    local lock_prefix=""
    if have_cmd flock; then
        lock_prefix="flock -n ${MY_LOCK_FILE}"
    fi

    # 先清理旧的 clean 任务（仅匹配 my clean/daily_clean）
    cron_remove_regex '(^|\s)/usr/local/bin/my\s+(clean|daily_clean)(\s|$)'

    local line="0 2 * * * ${lock_prefix} ${my_cmd} clean > /dev/null 2>&1"
    cron_add_line_once "$line"
}

# SSR 自动任务：在进入 SSR 管理后才启用（符合要求 4）
my_enable_ssr_cron_tasks() {
    local my_cmd="/usr/local/bin/${CMD_NAME}"
    local lock_prefix=""
    if have_cmd flock; then
        lock_prefix="flock -n ${SSR_LOCK_FILE}"
    fi

    # 清理旧任务（ssr/旧脚本）
    cron_remove_regex '(^|\s)(/usr/local/bin/ssr|/usr/local/bin/my\s+ssr)\s+(auto_update|auto_task|daemon_check|auto_core_update|clean|daily_task|ddns)(\s|$)'

    # 守护检查（每分钟）
    cron_add_line_once "* * * * * ${lock_prefix} ${my_cmd} ssr daemon_check > /dev/null 2>&1"

    # 核心组件安全热更（每天 3 点；清理由全局 2 点任务负责）
    cron_add_line_once "0 3 * * * ${lock_prefix} ${my_cmd} ssr auto_core_update > /dev/null 2>&1"

    # DDNS（存在配置才启用）
    if [[ -f "${SSR_DDNS_CONF}" ]]; then
        cron_add_line_once "*/5 * * * * ${lock_prefix} ${my_cmd} ssr ddns > /dev/null 2>&1"
    else
        cron_remove_regex '(^|\s)/usr/local/bin/my\s+ssr\s+ddns(\s|$)'
    fi
}

my_disable_ssr_cron_tasks() {
    cron_remove_regex '(^|\s)(/usr/local/bin/ssr|/usr/local/bin/my\s+ssr)\s+(auto_update|auto_task|daemon_check|auto_core_update|clean|daily_task|ddns)(\s|$)'
}

my_remove_nft_cron_tasks() {
    cron_remove_regex '(^|\s)(/usr/local/bin/my\s+nft\s+--cron|/usr/local/bin/nftmgr|nftmgr)\s+--cron(\s|$)'
}

# --------------------------
# 全局每日清理（2:00）
# --------------------------
daily_clean() {
    local silent="$1"
    if have_cmd apt-get; then
        apt-get autoremove -yqq >/dev/null 2>&1 || true
        apt-get clean -qq >/dev/null 2>&1 || true
    fi

    # 清理临时文件/缓存
    rm -rf /root/.cache/* /tmp/*.tar.xz /tmp/shadow-tls /tmp/ssserver /tmp/ssr_update.sh /tmp/xray* /tmp/tmp.json 2>/dev/null || true

    # 清理 ddns / nginx 模块日志与临时文件
    rm -rf /var/lib/my-nginx-proxy/tmp/* 2>/dev/null || true

    # 清理 ddns 日志：保留最近 7 天
    if [[ -d /var/log/nft_ddns ]]; then
        find /var/log/nft_ddns -type f -name '*.log' -mtime +7 -delete 2>/dev/null || true
    fi
    if [[ -f /var/log/ssr_ddns.log ]]; then
        # 只保留最后 2000 行，避免无上限增长
        tail -n 2000 /var/log/ssr_ddns.log > /var/log/ssr_ddns.log.tmp 2>/dev/null && mv -f /var/log/ssr_ddns.log.tmp /var/log/ssr_ddns.log 2>/dev/null || true
    fi

    [[ "$silent" != "silent" ]] && msg_ok "✅ 系统清理完成。"
}

# --------------------------
# GitHub 一键更新（选项 4）
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

verify_update_file() {
    local f="$1"

    # 1) 基础校验
    grep -q '^#!/bin/bash' "$f" || return 11
    grep -q 'CMD_NAME="my"' "$f" || return 12
    grep -q 'MY_SCRIPT_ID="my-manager"' "$f" || return 13

    # 2) 语法校验
    bash -n "$f" >/dev/null 2>&1 || return 14

    return 0
}

github_update() {
    require_root

    local tmp
    tmp="$(mktemp /tmp/my.update.XXXXXX)"
    local used=""

    msg_info "开始更新：自动检测国内/国外网络..."

    if download_to "${UPDATE_URL_DIRECT}" "$tmp"; then
        used="direct"
    elif download_to "${UPDATE_URL_PROXY}" "$tmp"; then
        used="proxy"
    else
        rm -f "$tmp"
        msg_err "更新失败：无法从 GitHub 拉取脚本（直连与代理都失败）。"
        return 1
    fi

    if ! verify_update_file "$tmp"; then
        local rc=$?
        rm -f "$tmp"
        msg_err "更新失败：下载文件校验不通过（错误码 $rc），已终止替换。"
        return 1
    fi

    local dst="/usr/local/bin/${CMD_NAME}"
    mkdir -p "$(dirname "$dst")" 2>/dev/null || true

    if [[ -f "$dst" ]]; then
        local bak="${dst}.bak.$(date +%s)"
        cp -f "$dst" "$bak" 2>/dev/null || true
        msg_info "已备份旧版本：$bak"
    fi

    install -m 755 "$tmp" "$dst" 2>/dev/null || { rm -f "$tmp"; msg_err "安装新版本失败。"; return 1; }
    rm -f "$tmp"

    msg_ok "✅ 更新成功（来源：${used}）。正在重启脚本..."
    exec "$dst"
}

# --------------------------
# 一键卸载（选项 3）
# --------------------------
uninstall_ssr() {
    require_root
    msg_warn "⚠️ 开始卸载 SSR 相关组件..."

    (
      source "${SSR_MODULE_FILE}" 2>/dev/null || exit 0
      ssr_cleanup_artifacts
    )

    my_disable_ssr_cron_tasks
    rm -f /usr/local/bin/ssr /usr/local/bin/ssr.sh 2>/dev/null || true
    msg_ok "✅ SSR 卸载完成。"
}

uninstall_nft() {
    require_root
    msg_warn "⚠️ 开始卸载 NFT 转发相关组件..."

    (
      source "${NFT_MODULE_FILE}" 2>/dev/null || exit 0
      cleanup_nft_artifacts
    )

    my_remove_nft_cron_tasks
    rm -f /usr/local/bin/nftmgr /usr/local/bin/nft_mgr.sh 2>/dev/null || true

    msg_ok "✅ NFT 转发卸载完成。"
}

uninstall_nginx() {
    require_root
    msg_warn "⚠️ 开始卸载 Nginx 反向代理相关组件..."

    (
      source "${NGX_MODULE_FILE}" 2>/dev/null || exit 0
      nginx_cleanup_artifacts
    )

    msg_ok "✅ Nginx 反向代理卸载完成。"
}

uninstall_all() {
    require_root
    msg_warn "⚠️ 将卸载 SSR + NFT 转发 + Nginx 反代 + DD 临时文件 + 本综合脚本本身（my）..."

    uninstall_ssr || true
    uninstall_nft || true
    uninstall_nginx || true

    # 清理全局 cron（clean）
    cron_remove_regex '(^|\s)/usr/local/bin/my\s+(clean|daily_clean)(\s|$)'

    # 删除模块与自身
    rm -rf "${MY_INSTALL_DIR}" "$REINSTALL_WORKDIR" 2>/dev/null || true
    rm -f "/usr/local/bin/${CMD_NAME}" 2>/dev/null || true

    msg_ok "✅ 已卸载全部。"
    exit 0
}

uninstall_menu() {
    while true; do
        clear
        echo -e "${CYAN}========= 一键卸载中心 =========${RESET}"
        echo -e "${YELLOW} 1.${RESET} 一键卸载所有（SSR + NFT + Nginx + DD 临时文件 + my）"
        echo -e "${YELLOW} 2.${RESET} 一键卸载 SSR"
        echo -e "${YELLOW} 3.${RESET} 一键卸载 NFT 转发"
        echo -e "${YELLOW} 4.${RESET} 一键卸载 Nginx 反向代理"
        echo -e " 0. 返回主菜单"
        read -rp "请输入数字 [0-4]: " u

        case "$u" in
            1)
                read -rp "确认卸载所有？此操作不可恢复 [y/N]: " c
                [[ "$c" =~ ^[yY]$ ]] && uninstall_all
                ;;
            2)
                read -rp "确认卸载 SSR？[y/N]: " c
                [[ "$c" =~ ^[yY]$ ]] && uninstall_ssr
                ;;
            3)
                read -rp "确认卸载 NFT 转发？[y/N]: " c
                [[ "$c" =~ ^[yY]$ ]] && uninstall_nft
                ;;
            4)
                read -rp "确认卸载 Nginx 反向代理？[y/N]: " c
                [[ "$c" =~ ^[yY]$ ]] && uninstall_nginx
                ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

run_ssr_module_menu() {
    my_enable_ssr_cron_tasks
    (
      source "${SSR_MODULE_FILE}" || exit 1
      check_env
      while true; do
          main_menu || break
      done
    )
}

run_system_module_menu() {
    (
      source "${SSR_MODULE_FILE}" || exit 1
      check_env
      sys_menu
    )
}

run_nft_module_menu() {
    (
      source "${NFT_MODULE_FILE}" || exit 1
      require_root
      check_env
      # 自动检测并完成持久化设置（无单独菜单项）
      auto_persist_setup
      while true; do
          main_menu
      done
    )
}


run_nginx_module_menu() {
    (
      source "${NGX_MODULE_FILE}" || exit 1
      nginx_menu
    )
}

# --------------------------
# DD / 重装系统工具（基于 bin456789/reinstall）
# --------------------------
DDTOOL_UPSTREAM_LABEL=""
DDTOOL_UPSTREAM_URL=""
DDTOOL_LAST_PASSWORD=""

_ddtool_rand_pass() {
    if have_cmd openssl; then
        openssl rand -base64 12 2>/dev/null | tr -d '=+/
' | cut -c1-14
    else
        tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 14
    fi
}

ddtool_is_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 && "$1" -le 65535 ]]
}

ddtool_need_downloader() {
    have_cmd curl || have_cmd wget
}

ddtool_human_size() {
    local n="$1"
    if have_cmd numfmt && [[ "$n" =~ ^[0-9]+$ ]]; then
        numfmt --to=iec --suffix=B "$n" 2>/dev/null || echo "$n"
    else
        echo "$n"
    fi
}

ddtool_get_boot_mode() {
    [[ -d /sys/firmware/efi ]] && echo "UEFI" || echo "Legacy BIOS"
}

ddtool_get_virt_type() {
    if have_cmd systemd-detect-virt; then
        local vt
        vt="$(systemd-detect-virt 2>/dev/null || true)"
        [[ -n "$vt" && "$vt" != "none" ]] && echo "$vt" || echo "physical/unknown"
    else
        echo "unknown"
    fi
}

ddtool_get_root_disk() {
    local root_src base pk
    root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    [[ -z "$root_src" ]] && return 1
    base="${root_src#/dev/}"
    pk="$(lsblk -ndo PKNAME "$root_src" 2>/dev/null | head -n1)"
    if [[ -n "$pk" ]]; then
        echo "/dev/$pk"
        return 0
    fi
    case "$base" in
        nvme*n*p[0-9]*|mmcblk*p[0-9]*) echo "/dev/${base%p[0-9]*}" ;;
        sd[a-z][0-9]*|vd[a-z][0-9]*|xvd[a-z][0-9]*) echo "/dev/${base%%[0-9]*}" ;;
        *) echo "$root_src" ;;
    esac
}

ddtool_cleanup_temp() {
    rm -rf "$REINSTALL_WORKDIR" 2>/dev/null || true
    DDTOOL_UPSTREAM_LABEL=""
    DDTOOL_UPSTREAM_URL=""
    DDTOOL_LAST_PASSWORD=""
}

ddtool_fail_and_return() {
    local msg="$1"
    ddtool_cleanup_temp
    [[ -n "$msg" ]] && msg_err "$msg"
    read -n 1 -s -r -p "按任意键返回..."
    echo
    return 1
}

ddtool_preflight() {
    require_root
    if ! ddtool_need_downloader; then
        msg_err "缺少 curl 或 wget，无法拉取 reinstall.sh。"
        return 1
    fi
    if have_cmd systemd-detect-virt; then
        local vt
        vt="$(systemd-detect-virt 2>/dev/null || true)"
        case "$vt" in
            openvz|lxc|lxc-libvirt)
                msg_err "检测到当前环境为 ${vt}。上游脚本明确不支持 OpenVZ/LXC，已停止执行。"
                return 1
                ;;
        esac
    fi
    return 0
}

ddtool_measure_url_ms() {
    local url="$1"
    if have_cmd curl; then
        local out code total
        out="$(curl -k -L -o /dev/null -sS --connect-timeout 4 --max-time 8 -w '%{http_code} %{time_total}' "$url" 2>/dev/null)" || return 1
        code="${out%% *}"
        total="${out##* }"
        [[ "$code" =~ ^2|3 ]] || return 1
        awk -v t="$total" 'BEGIN{printf "%d", t*1000}'
        return 0
    fi
    if have_cmd wget; then
        local start end
        start=$(date +%s%3N 2>/dev/null || echo 0)
        wget -qO /dev/null --timeout=8 "$url" >/dev/null 2>&1 || return 1
        end=$(date +%s%3N 2>/dev/null || echo 0)
        if [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$end" -ge "$start" ]]; then
            echo $((end - start))
        else
            echo 9999
        fi
        return 0
    fi
    return 1
}

ddtool_pick_upstream() {
    local gms="" cms=""
    gms="$(ddtool_measure_url_ms "$REINSTALL_UPSTREAM_GLOBAL" 2>/dev/null || true)"
    cms="$(ddtool_measure_url_ms "$REINSTALL_UPSTREAM_CN" 2>/dev/null || true)"
    if [[ -n "$gms" && -n "$cms" ]]; then
        if (( cms + 80 < gms )); then
            echo "国内镜像|$REINSTALL_UPSTREAM_CN|${cms}ms"
        else
            echo "国际直连|$REINSTALL_UPSTREAM_GLOBAL|${gms}ms"
        fi
        return 0
    fi
    if [[ -n "$gms" ]]; then
        echo "国际直连|$REINSTALL_UPSTREAM_GLOBAL|${gms}ms"
        return 0
    fi
    if [[ -n "$cms" ]]; then
        echo "国内镜像|$REINSTALL_UPSTREAM_CN|${cms}ms"
        return 0
    fi
    return 1
}

ddtool_download_upstream() {
    local choice label url latency
    choice="$(ddtool_pick_upstream)" || {
        msg_err "无法连接 bin456789/reinstall 的 GitHub 直连或国内镜像地址。"
        return 1
    }
    label="${choice%%|*}"
    url="${choice#*|}"
    latency="${url##*|}"
    url="${url%|*}"
    mkdir -p "$REINSTALL_WORKDIR" 2>/dev/null || true
    msg_info "已自动选择上游源：${label}（${latency}）"
    if have_cmd curl; then
        curl -fsSL "$url" -o "$REINSTALL_SCRIPT_PATH" || {
            msg_err "下载 reinstall.sh 失败。"
            ddtool_cleanup_temp
            return 1
        }
    else
        wget -qO "$REINSTALL_SCRIPT_PATH" "$url" || {
            msg_err "下载 reinstall.sh 失败。"
            ddtool_cleanup_temp
            return 1
        }
    fi
    chmod 700 "$REINSTALL_SCRIPT_PATH" 2>/dev/null || true
    bash -n "$REINSTALL_SCRIPT_PATH" >/dev/null 2>&1 || {
        msg_err "下载到的 reinstall.sh 语法校验失败。"
        ddtool_cleanup_temp
        return 1
    }
    DDTOOL_UPSTREAM_LABEL="$label"
    DDTOOL_UPSTREAM_URL="$url"
    return 0
}

ddtool_preview_cmd() {
    local out=""
    printf -v out '%q ' "$@"
    echo "${out% }"
}

ddtool_confirm_exec() {
    local prompt="${1:-确认继续请输入 YES: }"
    local ans
    read -rp "$prompt" ans
    [[ "$ans" == "YES" ]]
}

ddtool_health_check() {
    local interactive="${1:-yes}"
    local virt boot root_disk root_size mem_total cpu_model default_route def_if gw dns_list ip4 ip6
    local global_ms cn_ms warn_count=0 fatal_count=0
    virt="$(ddtool_get_virt_type)"
    boot="$(ddtool_get_boot_mode)"
    root_disk="$(ddtool_get_root_disk 2>/dev/null || true)"
    root_size="$(lsblk -bdno SIZE "$root_disk" 2>/dev/null | head -n1)"
    mem_total="$(awk '/MemTotal/ {printf "%.1f GiB", $2/1024/1024}' /proc/meminfo 2>/dev/null | head -n1)"
    cpu_model="$(awk -F: '/model name/ {gsub(/^[ 	]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    default_route="$(ip route show default 2>/dev/null | head -n1)"
    def_if="$(awk '/^default/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' <<< "$default_route")"
    gw="$(awk '/^default/ {for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' <<< "$default_route")"
    dns_list="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | paste -sd ',' -)"
    [[ -z "$dns_list" ]] && dns_list="未检测到"
    if have_cmd curl; then
        ip4="$(curl -4 -fsS --connect-timeout 3 --max-time 6 https://api.ip.sb/ip 2>/dev/null || true)"
        ip6="$(curl -6 -fsS --connect-timeout 3 --max-time 6 https://api64.ipify.org 2>/dev/null || true)"
    fi
    global_ms="$(ddtool_measure_url_ms "$REINSTALL_UPSTREAM_GLOBAL" 2>/dev/null || true)"
    cn_ms="$(ddtool_measure_url_ms "$REINSTALL_UPSTREAM_CN" 2>/dev/null || true)"

    clear
    echo -e "${CYAN}========= 安装前网络与磁盘条件体检 =========${RESET}"
    echo -e "虚拟化: ${GREEN}${virt}${RESET}"
    echo -e "启动模式: ${GREEN}${boot}${RESET}"
    echo -e "系统盘: ${GREEN}${root_disk:-未知}${RESET}  大小: ${GREEN}$(ddtool_human_size "$root_size")${RESET}"
    echo -e "内存: ${GREEN}${mem_total:-未知}${RESET}"
    echo -e "CPU: ${GREEN}${cpu_model:-未知}${RESET}"
    echo -e "默认网卡: ${GREEN}${def_if:-未知}${RESET}  网关: ${GREEN}${gw:-未知}${RESET}"
    echo -e "DNS: ${GREEN}${dns_list}${RESET}"
    [[ -n "$ip4" ]] && echo -e "IPv4 出口: ${GREEN}${ip4}${RESET}"
    [[ -n "$ip6" ]] && echo -e "IPv6 出口: ${GREEN}${ip6}${RESET}"
    [[ -n "$global_ms" ]] && echo -e "GitHub 直连测速: ${GREEN}${global_ms}ms${RESET}" || { echo -e "GitHub 直连测速: ${RED}失败${RESET}"; warn_count=$((warn_count+1)); }
    [[ -n "$cn_ms" ]] && echo -e "国内镜像测速: ${GREEN}${cn_ms}ms${RESET}" || { echo -e "国内镜像测速: ${RED}失败${RESET}"; warn_count=$((warn_count+1)); }

    if [[ -z "$default_route" ]]; then
        echo -e "${RED}失败：未检测到默认路由。${RESET}"
        fatal_count=$((fatal_count+1))
    fi
    if [[ -z "$root_disk" ]]; then
        echo -e "${RED}失败：未能明确识别系统盘，已阻止继续执行。${RESET}"
        fatal_count=$((fatal_count+1))
    fi
    if [[ -n "$root_size" && "$root_size" =~ ^[0-9]+$ && "$root_size" -lt 21474836480 ]]; then
        echo -e "${YELLOW}提示：系统盘小于 20GiB，建议确认镜像占用与分区策略。${RESET}"
        warn_count=$((warn_count+1))
    fi

    echo
    if (( fatal_count > 0 )); then
        echo -e "${RED}体检未通过：存在 ${fatal_count} 个阻断项。${RESET}"
        [[ "$interactive" == "yes" ]] && read -n 1 -s -r -p "按任意键返回..."
        return 1
    fi
    if (( warn_count > 0 )); then
        echo -e "${YELLOW}体检通过，但有 ${warn_count} 个提醒项。${RESET}"
    else
        echo -e "${GREEN}体检通过，未发现明显阻断项。${RESET}"
    fi
    [[ "$interactive" == "yes" ]] && read -n 1 -s -r -p "按任意键继续..."
    return 0
}

ddtool_prompt_linux_access() {
    local mode_title="$1"
    DDTOOL_LAST_PASSWORD=""
    DDTOOL_PASSWORD=""
    DDTOOL_SSH_PORT="22"

    echo -e "${CYAN}>>> ${mode_title}：仅需填写 root 密码与 SSH 端口${RESET}"
    read -rp "root 密码（回车自动生成随机密码）: " DDTOOL_PASSWORD
    if [[ -z "$DDTOOL_PASSWORD" ]]; then
        DDTOOL_PASSWORD="$(_ddtool_rand_pass)"
        msg_warn "已自动生成随机 root 密码：${DDTOOL_PASSWORD}"
    fi
    DDTOOL_LAST_PASSWORD="$DDTOOL_PASSWORD"

    read -rp "SSH 端口（回车默认 22）: " DDTOOL_SSH_PORT
    DDTOOL_SSH_PORT="${DDTOOL_SSH_PORT:-22}"
    if ! ddtool_is_port "$DDTOOL_SSH_PORT"; then
        msg_err "SSH 端口无效。"
        return 1
    fi
    return 0
}

ddtool_execute() {
    local action_desc="$1"
    shift
    local cmd=("$@")

    ddtool_preflight || return 1
    ddtool_download_upstream || return 1
    ddtool_health_check no || { ddtool_fail_and_return "安装前体检未通过，已清理临时文件并返回菜单。"; return 1; }

    echo
    echo -e "${CYAN}========= DD / 重装系统执行确认 =========${RESET}"
    echo -e "任务: ${GREEN}${action_desc}${RESET}"
    echo -e "上游源: ${YELLOW}${DDTOOL_UPSTREAM_LABEL}${RESET}"
    [[ -n "$DDTOOL_LAST_PASSWORD" ]] && echo -e "root 密码: ${YELLOW}${DDTOOL_LAST_PASSWORD}${RESET}"
    [[ -n "$DDTOOL_SSH_PORT" ]] && echo -e "SSH 端口: ${YELLOW}${DDTOOL_SSH_PORT}${RESET}"
    echo -e "命令: ${CYAN}$(ddtool_preview_cmd "${cmd[@]}")${RESET}"
    echo -e "${RED}警告：该操作会清空整块硬盘及全部分区数据。${RESET}"
    echo -e "${RED}如机器可用 IPMI/U盘/控制台，优先使用更稳妥的方式。${RESET}"
    echo
    ddtool_confirm_exec "确认继续请输入 YES: " || { ddtool_cleanup_temp; msg_warn "已取消，临时文件已清理。"; sleep 1; return 1; }
    clear
    echo -e "${CYAN}>>> 已开始执行：${action_desc}${RESET}"
    "${cmd[@]}"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        ddtool_cleanup_temp
        msg_err "上游命令返回非 0：$rc，临时文件已清理。"
        read -n 1 -s -r -p "按任意键返回..."
        echo
        return $rc
    fi
    DDTOOL_LAST_PASSWORD=""
    return 0
}

ddtool_run_linux_reinstall() {
    local distro="$1" version="$2" title="$3"
    shift 3
    local extra=("$@")
    ddtool_prompt_linux_access "$title" || return 1
    local cmd=(bash "$REINSTALL_SCRIPT_PATH" "$distro")
    [[ -n "$version" ]] && cmd+=("$version")
    [[ ${#extra[@]} -gt 0 ]] && cmd+=("${extra[@]}")
    cmd+=(--password "$DDTOOL_PASSWORD" --ssh-port "$DDTOOL_SSH_PORT")
    ddtool_execute "$title" "${cmd[@]}"
}

dd_menu() {
    while true; do
        clear
        echo -e "${CYAN}========= DD / 重装系统中心 =========${RESET}"
        echo -e "${GREEN} 1.${RESET} 一键重装 Debian 13"
        echo -e "${GREEN} 2.${RESET} 一键重装 Debian 12"
        echo -e "${GREEN} 3.${RESET} 一键重装 Ubuntu 24.04"
        echo -e " 0. 返回主菜单"
        read -rp "请输入数字 [0-3]: " ddn
        case "$ddn" in
            1) ddtool_run_linux_reinstall debian 13 "一键重装 Debian 13" ;;
            2) ddtool_run_linux_reinstall debian 12 "一键重装 Debian 12" ;;
            3) ddtool_run_linux_reinstall ubuntu 24.04 "一键重装 Ubuntu 24.04" ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

# --------------------------
# CLI（供 cron/脚本调用）
# --------------------------
nginx_cli() {
    local action="${1:-menu}"
    case "$action" in
        menu|"")
            ( source "${NGX_MODULE_FILE}" || exit 1; nginx_menu )
            ;;
        list)
            ( source "${NGX_MODULE_FILE}" || exit 1; ngx_list_proxies )
            ;;
        delete)
            shift
            ( source "${NGX_MODULE_FILE}" || exit 1; ngx_delete_proxy_domain "$1" )
            ;;
        repair|install)
            ( source "${NGX_MODULE_FILE}" || exit 1; ngx_install_dependencies )
            ;;
        *)
            msg_err "用法: my nginx <menu|list|delete <domain>|repair>"
            return 1
            ;;
    esac
}

ssr_cli() {
    local action="${1:-}"
    case "$action" in
        daemon_check)
            ( source "${SSR_MODULE_FILE}" || exit 1; run_daemon_check )
            ;;
        ddns)
            my_enable_ssr_cron_tasks
            ( source "${SSR_MODULE_FILE}" || exit 1; run_cf_ddns "auto" )
            ;;
        auto_core_update|hot_upgrade|hot_update)
            ( source "${SSR_MODULE_FILE}" || exit 1; hot_update_components "silent" )
            ;;
        regular|bbr)
            ( source "${SSR_MODULE_FILE}" || exit 1; check_env; apply_regular_profile "${2:-stable}" )
            ;;
        nat)
            ( source "${SSR_MODULE_FILE}" || exit 1; check_env; apply_nat_profile "${2:-stable}" )
            ;;
        dns)
            case "${2:-}" in
                status)
                    ( source "${SSR_MODULE_FILE}" || exit 1; dns_status )
                    ;;
                set|lock)
                    ( source "${SSR_MODULE_FILE}" || exit 1; dns_set_or_lock "${2}" )
                    ;;
                unlock)
                    ( source "${SSR_MODULE_FILE}" || exit 1; dns_unlock_restore )
                    ;;
                auto|smart|"")
                    ( source "${SSR_MODULE_FILE}" || exit 1; check_env; smart_dns_apply "${3:-stable}" "${4:-auto}" )
                    ;;
                *)
                    msg_err "用法: my ssr dns [status|set|lock|unlock|auto [stable|extreme] [auto|set|lock]]"
                    return 1
                    ;;
            esac
            ;;
        *)
            msg_err "用法: my ssr <daemon_check|ddns|regular [stable|extreme]|nat [stable|extreme]|dns ...>"
            return 1
            ;;
    esac
}

dd_cli() {
    local action="${1:-}"
    shift || true
    case "$action" in
        debian13)
            local cmd=(bash "$REINSTALL_SCRIPT_PATH" debian 13 "$@")
            ddtool_execute "CLI 一键重装 Debian 13" "${cmd[@]}"
            ;;
        debian12)
            local cmd=(bash "$REINSTALL_SCRIPT_PATH" debian 12 "$@")
            ddtool_execute "CLI 一键重装 Debian 12" "${cmd[@]}"
            ;;
        ubuntu2404)
            local cmd=(bash "$REINSTALL_SCRIPT_PATH" ubuntu 24.04 "$@")
            ddtool_execute "CLI 一键重装 Ubuntu 24.04" "${cmd[@]}"
            ;;
        menu|"")
            dd_menu
            ;;
        *)
            msg_err "用法: my dd <menu|debian13|debian12|ubuntu2404> ..."
            return 1
            ;;
    esac
}

nft_cli() {
    local action="${1:-}"
    case "$action" in
        --cron)
            ( source "${NFT_MODULE_FILE}" || exit 1; ddns_update )
            ;;
        optimize|auto)
            ( source "${NFT_MODULE_FILE}" || exit 1; check_env; nft_apply_profile "${2:-stable}" )
            ;;
        *)
            msg_err "用法: my nft <--cron|optimize [stable|extreme]>"
            return 1
            ;;
    esac
}

# --------------------------
# 综合管理目录
# --------------------------
comprehensive_menu() {
    while true; do
        clear
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}          综合管理目录                      ${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${YELLOW} 1.${RESET} 系统底层管控"
        echo -e "${YELLOW} 2.${RESET} Nginx 反向代理"
        echo -e "${GREEN} 3.${RESET} DD / 重装系统中心"
        echo -e " 0. 返回主菜单"
        echo -e "${CYAN}--------------------------------------------${RESET}"
        read -rp "请输入数字 [0-3]: " choice
        case "$choice" in
            1) run_system_module_menu ;;
            2) run_nginx_module_menu ;;
            3) dd_menu ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

# --------------------------
# 主菜单
# --------------------------
main_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}      综合管理脚本 my  v${MY_VERSION}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${YELLOW} 1.${RESET} SSR 管理"
    echo -e "${YELLOW} 2.${RESET} NFT 转发"
    echo -e "${YELLOW} 3.${RESET} 综合管理目录"
    echo -e "${YELLOW} 4.${RESET} 一键卸载"
    echo -e "${YELLOW} 5.${RESET} GitHub 一键更新"
    echo -e " 0. 退出"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    read -rp "请输入数字 [0-5]: " choice
    case "$choice" in
        1) run_ssr_module_menu ;;
        2) run_nft_module_menu ;;
        3) comprehensive_menu ;;
        4) uninstall_menu ;;
        5) github_update ;;
        0) exit 0 ;;
        *) msg_err "无效选项"; sleep 1 ;;
    esac
}

# --------------------------
# 初始化（不添加 SSR/NFT 额外任务，仅全局 2:00 清理）
# --------------------------
init() {
    require_root
    install_self_command
    install_modules
    ensure_global_clean_cron

    # 兼容清理旧脚本遗留 cron（只删旧 ssr/nftmgr 任务，不新增）
    cron_remove_regex '(^|\s)(/usr/local/bin/ssr|/usr/local/bin/nftmgr|nftmgr)\s+--cron(\s|$)'
    cron_remove_regex '(^|\s)/usr/local/bin/ssr\s+(auto_update|auto_task|daemon_check|auto_core_update|clean|daily_task|ddns)(\s|$)'
}

# --------------------------
# 入口
# --------------------------
ensure_runtime_ready_for_cli() {
    require_root
    install_self_command
    [[ -f "${SSR_MODULE_FILE}" && -f "${NFT_MODULE_FILE}" && -f "${NGX_MODULE_FILE}" ]] || install_modules
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        clean|daily_clean)
            daily_clean "silent"
            exit 0
            ;;
        ssr)
            ensure_runtime_ready_for_cli
            shift
            ssr_cli "$@"
            exit $?
            ;;
        nft)
            ensure_runtime_ready_for_cli
            shift
            nft_cli "$@"
            exit $?
            ;;
        nginx)
            ensure_runtime_ready_for_cli
            shift
            nginx_cli "$@"
            exit $?
            ;;
        dd)
            require_root
            install_self_command
            shift
            dd_cli "$@"
            exit $?
            ;;
        update)
            ensure_runtime_ready_for_cli
            github_update
            exit $?
            ;;
        *)
            msg_err "未知参数。可用: my clean | my ssr ... | my nft ... | my nginx <menu|list|delete <domain>|repair> | my dd <menu|debian13|debian12|ubuntu2404> | my update"
            exit 1
            ;;
    esac
fi

init
while true; do
    main_menu
done
