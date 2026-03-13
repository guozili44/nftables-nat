#!/bin/bash
# 综合管理脚本：SSR + nftables
# 快捷命令：my
# 更新地址：https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/my.sh
# 版本：v1.3.3  (build 2026-03-13+fixed-optimized)
# 指纹：CMD_NAME="my" / MY_SCRIPT_ID="my-manager"

set -o pipefail

# 兼容 cron/systemd 的精简 PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# --------------------------
# 基本信息
# --------------------------
CMD_NAME="my"
MY_SCRIPT_ID="my-manager"
MY_VERSION="1.3.3"

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

    # SSR 模块（修复：原子化写入）
    cat > "${SSR_MODULE_FILE}.tmp" <<'SSR_MODULE_EOF'
#!/bin/bash
# 脚本名称: SSR 综合管理脚本 (稳定优先 + 极致性能 Profiles)
# 核心特性:
#   - 节点部署: SS-Rust / SS2022 + v2ray-plugin / SS2022 + obfs-local / VLESS Reality (Xray)
#   - 双档位网络调优: 手动选择 常规机器 / NAT 小鸡 => 稳定优先 / 极致优化
#   - Cloudflare DDNS: 原生 API + 定时守护
#   - 自动任务互斥: cron 使用 flock 防并发踩踏
#   - 自动热更: 仅在有新版本时更新；下载到临时目录校验可运行后再原子替换
#   - DNS 管理: 检测 /etc/resolv.conf 是否 symlink；提供一键解锁/恢复
#
# 命令：ssr regular|nat [stable|extreme] / ssr dns ...

set -o pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly RESET='\033[0m'

readonly SCRIPT_VERSION="21.4-Manual-Tuned"

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
readonly SS_V2RAY_CONF="/etc/ss-v2ray/config.json"
readonly SS_V2RAY_STATE="${META_DIR}/ss_v2ray.conf"
readonly SS_OBFS_CONF="/etc/ss-obfs/config.json"
readonly SS_OBFS_STATE="${META_DIR}/ss_obfs.conf"
readonly SWAP_MARK_FILE="${META_DIR}/swap_created_by_ssr"
readonly SSHD_BACKUP_FILE="${META_DIR}/sshd_config.bak"
readonly SSH_AUTH_DROPIN="/etc/ssh/sshd_config.d/99-my-auth.conf"
readonly JOURNALD_BACKUP_FILE="${META_DIR}/journald.conf.bak"

readonly DNS_BACKUP_DIR="/usr/local/etc/ssr_dns_backup"
readonly DNS_META="${DNS_BACKUP_DIR}/meta.conf"
readonly DNS_FILE_BAK="${DNS_BACKUP_DIR}/resolv.conf.bak"
readonly RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/ssr-dns.conf"

trap 'echo -e "\n${GREEN}已安全退出脚本。${RESET}"; exit 0' SIGINT

# 通用工具
have_cmd() { command -v "$1" >/dev/null 2>&1; }

base64_nw() {
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

readonly CORE_CACHE_DIR="/usr/local/lib/my/cache"
readonly CORE_TAG_CACHE_DIR="${CORE_CACHE_DIR}/tags"
readonly CORE_TAG_TTL=259200

core_cache_component_dir() {
    local comp="$1"
    echo "${CORE_CACHE_DIR}/${comp}"
}

core_cache_bin_name() {
    case "$1" in
        ss-rust) echo "ss-rust" ;;
        xray) echo "xray" ;;
        *) return 1 ;;
    esac
}

cache_current_binary_path() {
    local comp="$1"
    local name
    name=$(core_cache_bin_name "$comp") || return 1
    echo "$(core_cache_component_dir "$comp")/current/${name}"
}

cache_tag_binary_path() {
    local comp="$1" tag="$2"
    local name
    name=$(core_cache_bin_name "$comp") || return 1
    echo "$(core_cache_component_dir "$comp")/${tag}/${name}"
}

cache_store_binary() {
    local comp="$1" tag="$2" src="$3"
    local dir name current_path
    [[ -n "$comp" && -n "$tag" && -x "$src" ]] || return 1
    name=$(core_cache_bin_name "$comp") || return 1
    dir="$(core_cache_component_dir "$comp")/${tag}"
    current_path="$(cache_current_binary_path "$comp")"
    mkdir -p "$dir" "$(dirname "$current_path")" 2>/dev/null || return 1
    install -m 755 "$src" "${dir}/${name}" >/dev/null 2>&1 || return 1
    install -m 755 "$src" "$current_path" >/dev/null 2>&1 || return 1
}

cache_restore_binary() {
    local comp="$1" dest="$2"
    local current_path
    current_path="$(cache_current_binary_path "$comp")"
    [[ -x "$current_path" ]] || return 1
    safe_install_binary "$current_path" "$dest"
}

cache_restore_binary_tag() {
    local comp="$1" tag="$2" dest="$3"
    local src
    src="$(cache_tag_binary_path "$comp" "$tag")"
    [[ -x "$src" ]] || return 1
    safe_install_binary "$src" "$dest"
}

cached_latest_tag() {
    local repo="$1" key="$2" file now mtime tag=""
    [[ -n "$repo" && -n "$key" ]] || return 1
    mkdir -p "$CORE_TAG_CACHE_DIR" 2>/dev/null || true
    file="${CORE_TAG_CACHE_DIR}/${key}.tag"
    now=$(date +%s)
    if [[ -s "$file" ]]; then
        mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
        if [[ -n "$mtime" ]] && (( now - mtime < CORE_TAG_TTL )); then
            cat "$file"
            return 0
        fi
    fi
    tag=$(github_latest_tag "$repo" 2>/dev/null || true)
    if [[ -n "$tag" && "$tag" != "null" ]]; then
        printf '%s' "$tag" > "$file"
        echo "$tag"
        return 0
    fi
    [[ -s "$file" ]] && cat "$file"
}

ss_rust_current_tag() {
    local v
    v=$(/usr/local/bin/ss-rust --version 2>/dev/null | grep -oE '([0-9]+\.){2}[0-9]+' | head -n1)
    [[ -n "$v" ]] && echo "v${v}"
}

xray_current_tag() {
    local v
    v=$(/usr/local/bin/xray version 2>/dev/null | head -n1 | grep -oE '([0-9]+\.){2}[0-9]+' | head -n1)
    [[ -n "$v" ]] && echo "v${v}"
}

core_cache_clear_all() {
    rm -rf "$CORE_CACHE_DIR" 2>/dev/null || true
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
    printf '%s' "$1" | tr -d '\r' | \
        sed -E \
            -e 's/Private[[:space:]]*[Kk]ey:/\nPrivateKey:/g' \
            -e 's/Public[[:space:]]*[Kk]ey:/\nPublicKey:/g' \
            -e 's/PrivateKey:/\nPrivateKey:/g' \
            -e 's/PublicKey:/\nPublicKey:/g' \
            -e 's/Password:/\nPassword:/g' \
            -e 's/Hash32:/\nHash32:/g' | \
        sed '/^[[:space:]]*$/d'
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
    local ip port method password link
    ip=$(ssr_fetch_public_ip)
    port=$(json_get_path /etc/ss-rust/config.json server_port 2>/dev/null)
    method=$(json_get_path /etc/ss-rust/config.json method 2>/dev/null)
    password=$(json_get_path /etc/ss-rust/config.json password 2>/dev/null)
    link=$(ssr_make_ss_link "$ip" 2>/dev/null || true)
    echo -e "IP: ${GREEN}${ip}${RESET}"
    echo -e "端口: ${GREEN}${port:-未读取}${RESET}"
    echo -e "协议: ${GREEN}${method:-未读取}${RESET}"
    echo -e "密码: ${GREEN}${password:-未读取}${RESET}"
    [[ -n "$link" ]] && echo -e "${YELLOW}链接:${RESET}\n${link}"
}

plugin_state_get() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 1
    grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 | cut -d= -f2- | sed 's/^"//; s/"$//'
}

plugin_state_write() {
    local file="$1"; shift
    mkdir -p "$META_DIR" 2>/dev/null || true
    : > "$file"
    while [[ $# -ge 2 ]]; do
        printf '%s="%s"\n' "$1" "$2" >> "$file"
        shift 2
    done
    chmod 600 "$file" 2>/dev/null || true
}

random_token() {
    local len="${1:-8}"
    if have_cmd openssl; then
        openssl rand -hex "$(( (len+1)/2 ))" 2>/dev/null | cut -c1-"$len"
    else
        tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c "$len"
    fi
}

ss_pick_method_password() {
    local methods=(
        "2022-blake3-aes-128-gcm"
        "2022-blake3-aes-256-gcm"
        "2022-blake3-chacha20-poly1305"
        "aes-256-gcm"
    )
    echo -e "${YELLOW}加密协议:${RESET}"
    local i=1 msel input_pwd pwd_len=0 raw_len decoded_len tmp_dec
    for m in "${methods[@]}"; do echo " $i) $m"; i=$((i+1)); done
    read -rp "选择 [1-4] (默认1): " msel
    [[ "$msel" =~ ^[1-4]$ ]] || msel=1
    SS_PICK_METHOD="${methods[$((msel-1))]}"
    case "$SS_PICK_METHOD" in
        2022-blake3-aes-128-gcm) pwd_len=16 ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) pwd_len=32 ;;
    esac
    SS_PICK_PASSWORD=""
    if [[ "$pwd_len" -ne 0 ]]; then
        read -rp "密码 (留空自动生成，输入时可填 Base64 密钥或原始密钥): " input_pwd
        if [[ -z "$input_pwd" ]]; then
            if have_cmd openssl; then
                SS_PICK_PASSWORD=$(openssl rand "$pwd_len" 2>/dev/null | base64_nw)
            else
                SS_PICK_PASSWORD=$(head -c "$pwd_len" /dev/urandom 2>/dev/null | base64_nw)
            fi
        else
            tmp_dec="/tmp/ssr-key.$$"
            raw_len=$(printf '%s' "$input_pwd" | wc -c | tr -d ' ')
            decoded_len=0
            if printf '%s' "$input_pwd" | base64 -d >"$tmp_dec" 2>/dev/null; then
                decoded_len=$(wc -c <"$tmp_dec" | tr -d ' ')
            fi
            rm -f "$tmp_dec" 2>/dev/null || true
            if [[ "$decoded_len" == "$pwd_len" ]]; then
                SS_PICK_PASSWORD="$input_pwd"
            elif [[ "$raw_len" == "$pwd_len" ]]; then
                SS_PICK_PASSWORD=$(printf '%s' "$input_pwd" | base64_nw)
            else
                echo -e "${RED}❌ 2022 协议密钥长度错误：需要 ${pwd_len} 字节原始密钥，或对应的 Base64 密钥。${RESET}"
                sleep 3
                return 1
            fi
        fi
        [[ -n "$SS_PICK_PASSWORD" ]] || { echo -e "${RED}❌ 密钥生成失败。${RESET}"; sleep 3; return 1; }
    else
        read -rp "传统密码 (留空随机): " input_pwd
        if [[ -z "$input_pwd" ]]; then
            if have_cmd openssl; then
                SS_PICK_PASSWORD=$(openssl rand -hex 12 2>/dev/null)
            else
                SS_PICK_PASSWORD=$(head -c 12 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')
            fi
        else
            SS_PICK_PASSWORD="$input_pwd"
        fi
    fi
}

ensure_ss_rust_binary() {
    local arch ss_arch_primary="x86_64-unknown-linux-musl" ss_arch_fallback="x86_64-unknown-linux-gnu"
    local ss_latest="" tmpdir="" tarball="" url="" ss_arch=""
    arch=$(uname -m)
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
    if [[ -x /usr/local/bin/ss-rust ]] && (run_with_timeout 3 /usr/local/bin/ss-rust --version >/dev/null 2>&1 || run_with_timeout 3 /usr/local/bin/ss-rust -V >/dev/null 2>&1); then
        ENSURED_SS_RUST_TAG=$(meta_get "SS_RUST_TAG" || true)
        [[ -z "$ENSURED_SS_RUST_TAG" ]] && ENSURED_SS_RUST_TAG=$(ss_rust_current_tag || true)
        [[ -n "$ENSURED_SS_RUST_TAG" ]] && cache_store_binary "ss-rust" "$ENSURED_SS_RUST_TAG" /usr/local/bin/ss-rust >/dev/null 2>&1 || true
        return 0
    fi
    if cache_restore_binary "ss-rust" /usr/local/bin/ss-rust && (run_with_timeout 3 /usr/local/bin/ss-rust --version >/dev/null 2>&1 || run_with_timeout 3 /usr/local/bin/ss-rust -V >/dev/null 2>&1); then
        ENSURED_SS_RUST_TAG=$(meta_get "SS_RUST_TAG" || true)
        [[ -z "$ENSURED_SS_RUST_TAG" ]] && ENSURED_SS_RUST_TAG=$(ss_rust_current_tag || true)
        return 0
    fi
    echo -e "${CYAN}>>> 本地无可用 SS-Rust 核心，开始联网下载...${RESET}"
    ss_latest=$(cached_latest_tag "shadowsocks/shadowsocks-rust" "ss-rust")
    [[ -z "$ss_latest" ]] && ss_latest="v1.24.0"
    tmpdir=$(mktemp -d /tmp/ssr-ssrust.XXXXXX)
    tarball="${tmpdir}/ss-rust.tar.xz"
    for candidate_arch in "$ss_arch_primary" "$ss_arch_fallback"; do
        url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${ss_latest}/shadowsocks-${ss_latest}.${candidate_arch}.tar.xz"
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
        rm -rf "$tmpdir"
        sleep 3
        return 1
    fi
    safe_install_binary "${tmpdir}/ssserver" /usr/local/bin/ss-rust || {
        echo -e "${RED}❌ 安装失败（写入 /usr/local/bin/ss-rust 失败）。${RESET}"
        rm -rf "$tmpdir"
        sleep 3
        return 1
    }
    cache_store_binary "ss-rust" "$ss_latest" /usr/local/bin/ss-rust >/dev/null 2>&1 || true
    meta_set "SS_RUST_TAG" "$ss_latest"
    ENSURED_SS_RUST_TAG="$ss_latest"
    rm -rf "$tmpdir"
    return 0
}

ss_v2ray_make_link() {
    local ip port method password host path plugin_raw plugin_enc userinfo
    ip="${1:-$(ssr_fetch_public_ip)}"
    port=$(json_get_path "$SS_V2RAY_CONF" server_port 2>/dev/null)
    method=$(json_get_path "$SS_V2RAY_CONF" method 2>/dev/null)
    password=$(json_get_path "$SS_V2RAY_CONF" password 2>/dev/null)
    host=$(plugin_state_get "$SS_V2RAY_STATE" HOST 2>/dev/null || true)
    path=$(plugin_state_get "$SS_V2RAY_STATE" PATH 2>/dev/null || true)
    [[ -n "$ip" && -n "$port" && -n "$method" && -n "$password" && -n "$host" && -n "$path" ]] || return 1
    userinfo=$(ss_make_userinfo "$method" "$password")
    plugin_raw="v2ray-plugin;mode=websocket;host=${host};path=${path}"
    plugin_enc=$(uri_encode "$plugin_raw")
    printf 'ss://%s@%s:%s/?plugin=%s#SS2022-v2ray-plugin' "$userinfo" "$ip" "$port" "$plugin_enc"
}

show_ss_v2ray_summary() {
    local ip port method password host path link
    ip=$(ssr_fetch_public_ip)
    port=$(json_get_path "$SS_V2RAY_CONF" server_port 2>/dev/null)
    method=$(json_get_path "$SS_V2RAY_CONF" method 2>/dev/null)
    password=$(json_get_path "$SS_V2RAY_CONF" password 2>/dev/null)
    host=$(plugin_state_get "$SS_V2RAY_STATE" HOST 2>/dev/null || true)
    path=$(plugin_state_get "$SS_V2RAY_STATE" PATH 2>/dev/null || true)
    link=$(ss_v2ray_make_link "$ip" 2>/dev/null || true)
    echo -e "IP: ${GREEN}${ip}${RESET}"
    echo -e "端口: ${GREEN}${port:-未读取}${RESET}"
    echo -e "协议: ${GREEN}${method:-未读取}${RESET}"
    echo -e "密码: ${GREEN}${password:-未读取}${RESET}"
    echo -e "Host: ${GREEN}${host:-未读取}${RESET}"
    echo -e "Path: ${GREEN}${path:-未读取}${RESET}"
    [[ -n "$link" ]] && echo -e "${YELLOW}链接:${RESET}\n${link}"
}

ss_obfs_make_link() {
    local ip port method password host obfs plugin_raw plugin_enc userinfo
    ip="${1:-$(ssr_fetch_public_ip)}"
    port=$(json_get_path "$SS_OBFS_CONF" server_port 2>/dev/null)
    method=$(json_get_path "$SS_OBFS_CONF" method 2>/dev/null)
    password=$(json_get_path "$SS_OBFS_CONF" password 2>/dev/null)
    host=$(plugin_state_get "$SS_OBFS_STATE" HOST 2>/dev/null || true)
    obfs=$(plugin_state_get "$SS_OBFS_STATE" MODE 2>/dev/null || true)
    [[ -n "$ip" && -n "$port" && -n "$method" && -n "$password" && -n "$host" && -n "$obfs" ]] || return 1
    userinfo=$(ss_make_userinfo "$method" "$password")
    plugin_raw="obfs-local;obfs=${obfs};obfs-host=${host}"
    plugin_enc=$(uri_encode "$plugin_raw")
    printf 'ss://%s@%s:%s/?plugin=%s#SS2022-obfs' "$userinfo" "$ip" "$port" "$plugin_enc"
}

show_ss_obfs_summary() {
    local ip port method password host obfs link
    ip=$(ssr_fetch_public_ip)
    port=$(json_get_path "$SS_OBFS_CONF" server_port 2>/dev/null)
    method=$(json_get_path "$SS_OBFS_CONF" method 2>/dev/null)
    password=$(json_get_path "$SS_OBFS_CONF" password 2>/dev/null)
    host=$(plugin_state_get "$SS_OBFS_STATE" HOST 2>/dev/null || true)
    obfs=$(plugin_state_get "$SS_OBFS_STATE" MODE 2>/dev/null || true)
    link=$(ss_obfs_make_link "$ip" 2>/dev/null || true)
    echo -e "IP: ${GREEN}${ip}${RESET}"
    echo -e "端口: ${GREEN}${port:-未读取}${RESET}"
    echo -e "协议: ${GREEN}${method:-未读取}${RESET}"
    echo -e "密码: ${GREEN}${password:-未读取}${RESET}"
    echo -e "混淆模式: ${GREEN}${obfs:-未读取}${RESET}"
    echo -e "伪装域名: ${GREEN}${host:-未读取}${RESET}"
    [[ -n "$link" ]] && echo -e "${YELLOW}链接:${RESET}\n${link}"
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
        echo -e "${YELLOW}链接:${RESET}\n${link}"
    fi
}

start_managed_service() {
    local name="$1" unit_content="$2" bg_cmd="$3" bg_match="$4" log_file="$5" pid_file="$6"
    if service_use_systemd; then
        mkdir -p /etc/systemd/system 2>/dev/null || true
        printf '%s\n' "$unit_content" > "/etc/systemd/system/${name}.service"
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

    # 修复：补全端口范围以防高并发耗尽
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
net.ipv4.ip_local_port_range = 10240 65535
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
    local url="$1"; local dest="$2"
    rm -f "$dest"
    if have_cmd curl; then
        curl -fsSL --retry 3 --connect-timeout 8 --max-time 120 "$url" -o "$dest" >/dev/null 2>&1
    else
        wget -qO "$dest" "$url" >/dev/null 2>&1
    fi
}

github_latest_tag() {
    local repo="$1" body="" tag=""
    [[ -n "$repo" ]] || return 1
    if have_cmd curl; then
        body=$(curl -fsSL --max-time 10 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null || true)
    fi
    if [[ -n "$body" ]] && have_cmd jq; then
        tag=$(printf '%s' "$body" | jq -r '.tag_name // empty' 2>/dev/null)
    fi
    if [[ -z "$tag" && -n "$body" ]]; then
        tag=$(printf '%s' "$body" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
    fi
    [[ -n "$tag" && "$tag" != "null" ]] && echo "$tag"
}

github_release_asset_url() {
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

safe_install_binary() {
    local newbin="$1"; local dest="$2"
    local ts; ts=$(date +%s)
    local backup="${dest}.bak.${ts}"

    [[ -s "$newbin" ]] || return 1

    if [[ -f "$dest" ]]; then
        cp -a "$dest" "$backup" 2>/dev/null || true
    fi

    install -m 755 "$newbin" "${dest}.new" >/dev/null 2>&1 || { rm -f "${dest}.new"; return 1; }
    mv -f "${dest}.new" "$dest" >/dev/null 2>&1 || { rm -f "${dest}.new"; return 1; }
    return 0
}

check_env() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行！${RESET}" && exit 1
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
    if declare -F my_enable_ssr_cron_tasks >/dev/null 2>&1; then
        my_enable_ssr_cron_tasks
    fi
}

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
        ss-v2ray)
            port="$(json_get_path "$SS_V2RAY_CONF" server_port 2>/dev/null || true)"
            [[ "$port" =~ ^[0-9]+$ ]] && remove_firewall_rule "$port" "tcp"
            pidfile="/var/run/ss-v2ray.pid"
            pkill -9 -f '/usr/local/bin/ss-rust -c /etc/ss-v2ray/config.json' 2>/dev/null || true
            rm -rf /etc/ss-v2ray
            rm -f /var/log/ss-v2ray.log "$SS_V2RAY_STATE"
            ;;
        ss-obfs)
            port="$(json_get_path "$SS_OBFS_CONF" server_port 2>/dev/null || true)"
            [[ "$port" =~ ^[0-9]+$ ]] && remove_firewall_rule "$port" "tcp"
            pidfile="/var/run/ss-obfs.pid"
            pkill -9 -f '/usr/local/bin/ss-rust -c /etc/ss-obfs/config.json' 2>/dev/null || true
            rm -rf /etc/ss-obfs
            rm -f /var/log/ss-obfs.log "$SS_OBFS_STATE"
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
    local idx=1 port

    port="$(json_get_path /etc/ss-rust/config.json server_port 2>/dev/null || true)"
    if [[ -f /etc/ss-rust/config.json || -x /usr/local/bin/ss-rust || -f /etc/systemd/system/ss-rust.service || -f /var/run/ss-rust.pid ]] || pgrep -f '/usr/local/bin/ss-rust -c /etc/ss-rust/config.json' >/dev/null 2>&1; then
        NUCLEAR_TARGETS[$idx]="ss-rust"
        NUCLEAR_LABELS[$idx]="SS-Rust"
        NUCLEAR_PORTS[$idx]="$port"
        ((idx++))
    fi
    port="$(json_get_path "$SS_V2RAY_CONF" server_port 2>/dev/null || true)"
    if [[ -f "$SS_V2RAY_CONF" || -f /etc/systemd/system/ss-v2ray.service || -f /var/run/ss-v2ray.pid ]] || pgrep -f '/usr/local/bin/ss-rust -c /etc/ss-v2ray/config.json' >/dev/null 2>&1; then
        NUCLEAR_TARGETS[$idx]="ss-v2ray"
        NUCLEAR_LABELS[$idx]="SS2022 + v2ray-plugin"
        NUCLEAR_PORTS[$idx]="$port"
        ((idx++))
    fi
    port="$(json_get_path "$SS_OBFS_CONF" server_port 2>/dev/null || true)"
    if [[ -f "$SS_OBFS_CONF" || -f /etc/systemd/system/ss-obfs.service || -f /var/run/ss-obfs.pid ]] || pgrep -f '/usr/local/bin/ss-rust -c /etc/ss-obfs/config.json' >/dev/null 2>&1; then
        NUCLEAR_TARGETS[$idx]="ss-obfs"
        NUCLEAR_LABELS[$idx]="SS2022 + obfs-local"
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
}

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

dns_apply_resolvconf_custom() {
    local lock_mode="$1"; shift
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
    local mode="$1"
    dns_backup

    if [[ -L /etc/resolv.conf ]]; then
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
    if have_cmd chattr; then chattr -i /etc/resolv.conf 2>/dev/null || true; fi

    if [[ -f "$RESOLVED_DROPIN" ]]; then
        rm -f "$RESOLVED_DROPIN"
        systemctl restart systemd-resolved 2>/dev/null || true
    fi

    if [[ -f "$DNS_META" ]]; then
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
            1) clear; dns_status; echo ""; read -n 1 -s -r -p "按任意键返回..." ;;
            2|3)
                local profile="stable" dns_mode
                [[ "$dn" == "3" ]] && profile="extreme"
                read -rp "DNS 模式 [auto/set/lock, 回车 auto]: " dns_mode
                smart_dns_apply "$profile" "${dns_mode:-auto}"
                sleep 2
                ;;
            4) dns_set_or_lock "set" && echo -e "${GREEN}✅ DNS 已设置。${RESET}" || echo -e "${YELLOW}⚠️ 未修改 DNS。${RESET}"; sleep 2 ;;
            5) dns_manual_set && echo -e "${GREEN}✅ DNS 已设置。${RESET}" || echo -e "${YELLOW}⚠️ 未修改 DNS。${RESET}"; sleep 2 ;;
            6) dns_set_or_lock "lock" && echo -e "${GREEN}✅ DNS 已锁定/固定。${RESET}" || echo -e "${YELLOW}⚠️ 未修改 DNS。${RESET}"; sleep 2 ;;
            7) dns_unlock_restore; echo -e "${GREEN}✅ 已解锁并恢复。${RESET}"; sleep 2 ;;
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
    read -rsp "新的 root 密码: " new_pass; echo ""
    [[ -z "$new_pass" ]] && return
    read -rsp "再次输入确认: " new_pass_confirm; echo ""
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
        4) restore_password_login ;;
        0) return ;;
    esac
}

install_ss_rust_native() {
    clear
    echo -e "${CYAN}========= 原生交互安装 SS-Rust =========${RESET}"
    read -rp "端口 [留空随机]: " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then port=$((RANDOM % 55535 + 10000)); fi
    ss_pick_method_password || return
    ensure_ss_rust_binary || return
    mkdir -p /etc/ss-rust
    cat > /etc/ss-rust/config.json << EOF
{ "server": "::", "server_port": $port, "password": "${SS_PICK_PASSWORD}", "method": "${SS_PICK_METHOD}", "mode": "tcp_and_udp", "fast_open": true }
EOF
    run_with_timeout 2 /usr/local/bin/ss-rust -c /etc/ss-rust/config.json >/dev/null 2>&1
    local rc=$?
    if [[ "$rc" -ne 0 && "$rc" -ne 124 && "$rc" -ne 137 ]]; then
        echo -e "${RED}❌ 配置自检失败，已中止启动。${RESET}"; sleep 3; return
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
        echo -e "${RED}❌ SS-Rust 启动失败。请检查 /var/log/ss-rust.log${RESET}"; sleep 3; return
    fi
    if have_cmd ufw; then ufw allow "$port"/tcp >/dev/null 2>&1; ufw allow "$port"/udp >/dev/null 2>&1; fi
    if have_cmd firewall-cmd; then firewall-cmd --add-port="$port"/tcp --permanent >/dev/null 2>&1; firewall-cmd --add-port="$port"/udp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi
    [[ -n "$ENSURED_SS_RUST_TAG" ]] && meta_set "SS_RUST_TAG" "$ENSURED_SS_RUST_TAG"
    echo -e "${GREEN}✅ SS-Rust (${ENSURED_SS_RUST_TAG:-local}) 安装完成！${RESET}"
    show_ss_rust_summary
    read -n 1 -s -r -p "按任意键返回上一层..."
}

install_vless_native() {
    clear
    echo -e "${CYAN}========= 原生交互安装 VLESS Reality =========${RESET}"
    rm -f /etc/systemd/system/xray.service
    read -rp "伪装域名 [默认 publicassets.cdn-apple.com]: " sni_domain
    [[ -z "$sni_domain" ]] && sni_domain="publicassets.cdn-apple.com"
    read -rp "监听端口 [留空随机]: " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then port=$((RANDOM % 55535 + 10000)); fi
    local arch; arch=$(uname -m); local xray_arch="64"
    case "$arch" in aarch64|arm64) xray_arch="arm64-v8a" ;; armv7l|armv7|arm) xray_arch="arm32-v7a" ;; esac
    local xray_latest="" tmpdir="" zipf=""
    if [[ -x /usr/local/bin/xray ]] && run_with_timeout 3 /usr/local/bin/xray version >/dev/null 2>&1 && run_with_timeout 3 /usr/local/bin/xray x25519 >/dev/null 2>&1; then
        echo -e "${CYAN}>>> 复用本地已安装 Xray 核心（不重新下载）...${RESET}"
        xray_latest=$(meta_get "XRAY_TAG" || true)
        [[ -z "$xray_latest" ]] && xray_latest=$(xray_current_tag || true)
        [[ -n "$xray_latest" ]] && cache_store_binary "xray" "$xray_latest" /usr/local/bin/xray >/dev/null 2>&1 || true
    elif cache_restore_binary "xray" /usr/local/bin/xray && run_with_timeout 3 /usr/local/bin/xray version >/dev/null 2>&1 && run_with_timeout 3 /usr/local/bin/xray x25519 >/dev/null 2>&1; then
        echo -e "${CYAN}>>> 从本地缓存恢复 Xray 核心（不重新下载）...${RESET}"
        xray_latest=$(meta_get "XRAY_TAG" || true)
        [[ -z "$xray_latest" ]] && xray_latest=$(xray_current_tag || true)
    else
        echo -e "${CYAN}>>> 本地无可用 Xray 核心，开始联网下载...${RESET}"
        xray_latest=$(cached_latest_tag "XTLS/Xray-core" "xray")
        [[ -z "$xray_latest" ]] && xray_latest="v26.2.6"
        tmpdir=$(mktemp -d /tmp/ssr-xray.XXXXXX); zipf="${tmpdir}/xray.zip"
        local url="https://github.com/XTLS/Xray-core/releases/download/${xray_latest}/Xray-linux-${xray_arch}.zip"
        echo -e "${CYAN}>>> 下载核心: ${xray_latest} (linux-${xray_arch}) ...${RESET}"
        if ! download_file "$url" "$zipf" || [[ ! -s "$zipf" ]] || ! unzip -t "$zipf" >/dev/null 2>&1; then
            echo -e "${RED}❌ 核心下载或校验失败。${RESET}"; rm -rf "$tmpdir"; sleep 3; return
        fi
        unzip -qo "$zipf" xray -d "$tmpdir" >/dev/null 2>&1 || true
        if [[ ! -x "${tmpdir}/xray" ]]; then echo -e "${RED}❌ 解压失败：未找到 xray。${RESET}"; rm -rf "$tmpdir"; sleep 3; return; fi
        if ! run_with_timeout 3 "${tmpdir}/xray" version >/dev/null 2>&1 || ! run_with_timeout 3 "${tmpdir}/xray" x25519 >/dev/null 2>&1; then
            echo -e "${RED}❌ 新核心自检失败（无法运行或缺少 x25519）。已中止替换。${RESET}"; rm -rf "$tmpdir"; sleep 3; return
        fi
        safe_install_binary "${tmpdir}/xray" /usr/local/bin/xray || { echo -e "${RED}❌ 安装失败。${RESET}"; rm -rf "$tmpdir"; sleep 3; return; }
        cache_store_binary "xray" "$xray_latest" /usr/local/bin/xray >/dev/null 2>&1 || true
    fi
    [[ -n "$xray_latest" ]] || xray_latest=$(xray_current_tag || true)
    [[ -n "$xray_latest" ]] && meta_set "XRAY_TAG" "$xray_latest"
    mkdir -p /usr/local/etc/xray
    local uuid keys priv pub short_id
    uuid=$(/usr/local/bin/xray uuid 2>/dev/null | head -n1 | tr -d '\r')
    keys=$(/usr/local/bin/xray x25519 2>&1 | tr -d '\r')
    priv=$(xray_extract_reality_private_key "$keys")
    pub=$(xray_extract_reality_public_key "$keys")
    if have_cmd openssl; then short_id=$(openssl rand -hex 8 2>/dev/null); else short_id=$(head -c 8 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n'); fi
    if [[ -z "$uuid" || -z "$priv" || -z "$pub" || -z "$short_id" ]]; then
        echo -e "${RED}❌ Xray 密钥材料生成失败。${RESET}"; echo -e "${YELLOW}x25519 输出:${RESET}"; normalize_xray_x25519_output "$keys"; rm -rf "$tmpdir"; sleep 5; return
    fi
    cat > /usr/local/etc/xray/config.json << EOF
{ "inbounds": [{ "listen": "::", "port": $port, "protocol": "vless", "settings": { "clients": [{"id": "$uuid", "flow": "xtls-rprx-vision"}], "decryption": "none" }, "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "dest": "${sni_domain}:443", "serverNames": ["${sni_domain}"], "privateKey": "$priv", "shortIds": ["$short_id"] } } }], "outbounds": [{"protocol": "freedom"}] }
EOF
    if ! /usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json >/dev/null 2>&1; then
        echo -e "${RED}❌ Xray 配置自检失败，已中止启动。${RESET}"; rm -rf "$tmpdir"; sleep 3; return
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
        echo -e "${RED}❌ Xray 启动失败。请检查 /var/log/xray.log${RESET}"; rm -rf "$tmpdir"; sleep 3; return
    fi
    if have_cmd ufw; then ufw allow "$port"/tcp >/dev/null 2>&1; fi
    if have_cmd firewall-cmd; then firewall-cmd --add-port="$port"/tcp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi
    [[ -n "$xray_latest" ]] && meta_set "XRAY_TAG" "$xray_latest"
    echo -e "${GREEN}✅ VLESS Reality (${xray_latest:-local}) 安装成功！${RESET}"
    show_vless_summary
    rm -rf "$tmpdir"
    read -n 1 -s -r -p "按任意键返回上一层..."
}

install_ss_v2ray_plugin_native() {
    clear
    echo -e "${CYAN}========= 自动部署 SS2022 + v2ray-plugin =========${RESET}"
    read -rp "端口 [留空随机]: " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then port=$((RANDOM % 55535 + 10000)); fi
    ss_pick_method_password || return
    ensure_ss_rust_binary || return
    read -rp "伪装域名 Host [默认 www.microsoft.com]: " host
    [[ -z "$host" ]] && host="www.microsoft.com"
    read -rp "WebSocket Path [默认随机]: " path
    [[ -z "$path" ]] && path="/$(random_token 8)"
    [[ "$path" == /* ]] || path="/${path}"
    if [[ ! -x /usr/local/bin/v2ray-plugin ]]; then
        local arch vp_latest tmpdir tarf asset_name official_url api_url proxy_url binf
        arch=$(uname -m)
        case "$arch" in
            x86_64|amd64) asset_name="v2ray-plugin-linux-amd64" ;;
            aarch64|arm64) asset_name="v2ray-plugin-linux-arm64" ;;
            armv7l|armv7|arm) asset_name="v2ray-plugin-linux-arm" ;;
            *) echo -e "${RED}❌ 当前架构暂不支持自动安装 v2ray-plugin: ${arch}${RESET}"; sleep 3; return ;;
        esac
        vp_latest=$(cached_latest_tag "shadowsocks/v2ray-plugin" "v2ray-plugin")
        [[ -z "$vp_latest" ]] && vp_latest="v1.3.2"
        tmpdir=$(mktemp -d /tmp/ssr-v2ray-plugin.XXXXXX); tarf="${tmpdir}/v2ray-plugin.tar.gz"; asset_name="${asset_name}-${vp_latest}.tar.gz"
        official_url="https://github.com/shadowsocks/v2ray-plugin/releases/download/${vp_latest}/${asset_name}"
        api_url=$(github_release_asset_url "shadowsocks/v2ray-plugin" "$vp_latest" "$asset_name" 2>/dev/null || true)
        proxy_url="https://ghproxy.net/${official_url#https://}"
        echo -e "${CYAN}>>> 正在准备 v2ray-plugin: ${vp_latest} ...${RESET}"
        if ! download_file_any "$tarf" "$api_url" "$official_url" "$proxy_url" || [[ ! -s "$tarf" ]] || ! tar -tf "$tarf" >/dev/null 2>&1; then
            echo -e "${RED}❌ v2ray-plugin 下载失败。${RESET}"; rm -rf "$tmpdir"; sleep 3; return
        fi
        tar -xf "$tarf" -C "$tmpdir" >/dev/null 2>&1 || true
        binf="$(find "$tmpdir" -maxdepth 1 -type f -name 'v2ray-plugin*' ! -name '*.tar.gz' | head -n1)"
        [[ -x "$binf" ]] || { echo -e "${RED}❌ v2ray-plugin 解压失败。${RESET}"; rm -rf "$tmpdir"; sleep 3; return; }
        safe_install_binary "$binf" /usr/local/bin/v2ray-plugin || { echo -e "${RED}❌ v2ray-plugin 安装失败。${RESET}"; rm -rf "$tmpdir"; sleep 3; return; }
        rm -rf "$tmpdir"
    fi
    mkdir -p /etc/ss-v2ray
    cat > "$SS_V2RAY_CONF" << EOF
{ "server": "::", "server_port": $port, "password": "${SS_PICK_PASSWORD}", "method": "${SS_PICK_METHOD}", "mode": "tcp_only", "fast_open": true, "plugin": "v2ray-plugin", "plugin_opts": "server;mode=websocket;host=${host};path=${path};loglevel=none" }
EOF
    plugin_state_write "$SS_V2RAY_STATE" HOST "$host" PATH "$path"
    run_with_timeout 3 /usr/local/bin/ss-rust -c "$SS_V2RAY_CONF" >/dev/null 2>&1
    local rc=$?
    if [[ "$rc" -ne 0 && "$rc" -ne 124 && "$rc" -ne 137 ]]; then
        echo -e "${RED}❌ 配置自检失败，已中止启动。${RESET}"; sleep 3; return
    fi
    local unit='[Unit]
Description=Shadowsocks-Rust + v2ray-plugin Server
After=network.target

[Service]
ExecStart=/usr/local/bin/ss-rust -c /etc/ss-v2ray/config.json
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target'
    if ! start_managed_service "ss-v2ray" "$unit" "/usr/local/bin/ss-rust -c /etc/ss-v2ray/config.json" '/usr/local/bin/ss-rust -c /etc/ss-v2ray/config.json' "/var/log/ss-v2ray.log" "/var/run/ss-v2ray.pid"; then
        echo -e "${RED}❌ SS2022 + v2ray-plugin 启动失败。${RESET}"; sleep 3; return
    fi
    if have_cmd ufw; then ufw allow "$port"/tcp >/dev/null 2>&1; fi
    if have_cmd firewall-cmd; then firewall-cmd --add-port="$port"/tcp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi
    echo -e "${GREEN}✅ SS2022 + v2ray-plugin 部署完成！${RESET}"
    show_ss_v2ray_summary
    read -n 1 -s -r -p "按任意键返回上一层..."
}
install_ss_obfs_native() {
    clear
    echo -e "${CYAN}========= 自动部署 SS2022 + obfs-local =========${RESET}"
    read -rp "端口 [留空随机]: " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then port=$((RANDOM % 55535 + 10000)); fi
    ss_pick_method_password || return
    ensure_ss_rust_binary || return
    echo -e "${YELLOW}混淆模式:${RESET}\n 1) tls\n 2) http"
    read -rp "选择 [1-2] (默认1): " obsel
    [[ "$obsel" == "2" ]] && obfs_mode="http" || obfs_mode="tls"
    read -rp "伪装域名 [默认 www.bing.com]: " host
    [[ -z "$host" ]] && host="www.bing.com"
    if [[ ! -x /usr/local/bin/obfs-server || ! -x /usr/local/bin/obfs-local ]]; then
        echo -e "${CYAN}>>> 正在准备 simple-obfs (obfs-server / obfs-local)...${RESET}"
        if have_cmd apt-get; then
            apt-get update >/dev/null 2>&1 || true
            apt-get install -y simple-obfs >/dev/null 2>&1 || true
        elif have_cmd apk; then
            apk add --no-cache simple-obfs >/dev/null 2>&1 || true
        elif have_cmd dnf; then
            dnf install -y simple-obfs >/dev/null 2>&1 || true
        elif have_cmd yum; then
            yum install -y epel-release >/dev/null 2>&1 || true
            yum install -y simple-obfs >/dev/null 2>&1 || true
        fi
        for b in /usr/bin/obfs-server /usr/local/bin/obfs-server; do [[ -x "$b" ]] && install -m 755 "$b" /usr/local/bin/obfs-server >/dev/null 2>&1 && break; done
        for b in /usr/bin/obfs-local /usr/local/bin/obfs-local; do [[ -x "$b" ]] && install -m 755 "$b" /usr/local/bin/obfs-local >/dev/null 2>&1 && break; done
        if [[ ! -x /usr/local/bin/obfs-server || ! -x /usr/local/bin/obfs-local ]]; then
            echo -e "${RED}❌ simple-obfs 安装失败或当前系统源未提供 obfs-server / obfs-local。${RESET}"; sleep 3; return
        fi
    fi
    mkdir -p /etc/ss-obfs
    cat > "$SS_OBFS_CONF" << EOF
{ "server": "::", "server_port": $port, "password": "${SS_PICK_PASSWORD}", "method": "${SS_PICK_METHOD}", "mode": "tcp_only", "fast_open": true, "plugin": "obfs-server", "plugin_opts": "obfs=${obfs_mode}" }
EOF
    plugin_state_write "$SS_OBFS_STATE" HOST "$host" MODE "$obfs_mode"
    run_with_timeout 3 /usr/local/bin/ss-rust -c "$SS_OBFS_CONF" >/dev/null 2>&1
    local rc=$?
    if [[ "$rc" -ne 0 && "$rc" -ne 124 && "$rc" -ne 137 ]]; then echo -e "${RED}❌ 配置自检失败，已中止启动。${RESET}"; sleep 3; return; fi
    local unit='[Unit]
Description=Shadowsocks-Rust + simple-obfs Server
After=network.target

[Service]
ExecStart=/usr/local/bin/ss-rust -c /etc/ss-obfs/config.json
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target'
    if ! start_managed_service "ss-obfs" "$unit" "/usr/local/bin/ss-rust -c /etc/ss-obfs/config.json" '/usr/local/bin/ss-rust -c /etc/ss-obfs/config.json' "/var/log/ss-obfs.log" "/var/run/ss-obfs.pid"; then
        echo -e "${RED}❌ SS2022 + obfs-local 启动失败。${RESET}"; sleep 3; return
    fi
    if have_cmd ufw; then ufw allow "$port"/tcp >/dev/null 2>&1; fi
    if have_cmd firewall-cmd; then firewall-cmd --add-port="$port"/tcp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi
    echo -e "${GREEN}✅ SS2022 + obfs-local 部署完成！${RESET}"
    show_ss_obfs_summary
    read -n 1 -s -r -p "按任意键返回上一层..."
}

unified_node_manager() {
    while true; do
        clear
        local has_ss=0 has_v2=0 has_obfs=0 has_vless=0
        ([[ -f /etc/ss-rust/config.json || -f /etc/systemd/system/ss-rust.service || -f /var/run/ss-rust.pid ]] || pgrep -f '/usr/local/bin/ss-rust -c /etc/ss-rust/config.json' >/dev/null 2>&1) && has_ss=1
        ([[ -f "$SS_V2RAY_CONF" || -f /etc/systemd/system/ss-v2ray.service || -f /var/run/ss-v2ray.pid ]] || pgrep -f '/usr/local/bin/ss-rust -c /etc/ss-v2ray/config.json' >/dev/null 2>&1) && has_v2=1
        ([[ -f "$SS_OBFS_CONF" || -f /etc/systemd/system/ss-obfs.service || -f /var/run/ss-obfs.pid ]] || pgrep -f '/usr/local/bin/ss-rust -c /etc/ss-obfs/config.json' >/dev/null 2>&1) && has_obfs=1
        ([[ -f /usr/local/etc/xray/config.json || -f /etc/systemd/system/xray.service || -f /var/run/xray.pid ]] || pgrep -f '/usr/local/bin/xray run -c /usr/local/etc/xray/config.json' >/dev/null 2>&1) && has_vless=1
        echo -e "${CYAN}========= 统一节点生命周期管控中心 =========${RESET}"
        if [[ $has_ss -eq 1 ]]; then echo -e "${GREEN} 1) ⚡ SS-Rust 节点${RESET}"; else echo -e "${RED} 1) ❌ 未部署 SS-Rust${RESET}"; fi
        if [[ $has_v2 -eq 1 ]]; then echo -e "${GREEN} 2) 🌐 SS2022 + v2ray-plugin${RESET}"; else echo -e "${RED} 2) ❌ 未部署 SS2022 + v2ray-plugin${RESET}"; fi
        if [[ $has_obfs -eq 1 ]]; then echo -e "${GREEN} 3) ☁️ SS2022 + obfs-local${RESET}"; else echo -e "${RED} 3) ❌ 未部署 SS2022 + obfs-local${RESET}"; fi
        if [[ $has_vless -eq 1 ]]; then echo -e "${GREEN} 4) 🔮 VLESS Reality 节点${RESET}"; else echo -e "${RED} 4) ❌ 未部署 VLESS Reality${RESET}"; fi
        echo -e "${RED} 5) ☢️ 全局强制核爆 (清理任意卡死/幽灵服务)${RESET}"
        echo -e " 0) 返回主菜单"
        read -rp "请选择 [0-5]: " node_choice
        case "$node_choice" in
            1)
                if [[ $has_ss -eq 1 ]]; then
                    clear
                    local port; show_ss_rust_summary; port=$(json_get_path /etc/ss-rust/config.json server_port 2>/dev/null)
                    echo -e "---------------------------------"
                    echo -e "${YELLOW}1) 修改端口${RESET} | ${YELLOW}2) 修改密码${RESET} | ${RED}3) 删除节点${RESET} | 0) 返回"
                    read -rp "输入操作: " op
                    if [[ "$op" == "1" ]]; then
                        read -rp "新端口 (1-65535): " np
                        if [[ "$np" =~ ^[0-9]+$ ]] && [ "$np" -ge 1 ] && [ "$np" -le 65535 ]; then
                            json_set_top_value /etc/ss-rust/config.json server_port "$np" number; remove_firewall_rule "$port" "both"
                            if have_cmd ufw; then ufw allow "$np"/tcp >/dev/null 2>&1; ufw allow "$np"/udp >/dev/null 2>&1; fi
                            if have_cmd firewall-cmd; then firewall-cmd --add-port="$np"/tcp --permanent >/dev/null 2>&1; firewall-cmd --add-port="$np"/udp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi
                            restart_managed_service "ss-rust" "/usr/local/bin/ss-rust -c /etc/ss-rust/config.json" '/usr/local/bin/ss-rust -c /etc/ss-rust/config.json' "/var/log/ss-rust.log" "/var/run/ss-rust.pid" >/dev/null 2>&1 || true
                            echo -e "${GREEN}✅ 修改成功${RESET}"
                        else echo -e "${RED}❌ 端口无效${RESET}"; fi
                        sleep 1
                    elif [[ "$op" == "2" ]]; then
                        read -rp "新密码: " npwd
                        [[ -z "$npwd" ]] && { echo -e "${RED}❌ 密码不能为空${RESET}"; sleep 1; continue; }
                        json_set_top_value /etc/ss-rust/config.json password "$npwd" string
                        restart_managed_service "ss-rust" "/usr/local/bin/ss-rust -c /etc/ss-rust/config.json" '/usr/local/bin/ss-rust -c /etc/ss-rust/config.json' "/var/log/ss-rust.log" "/var/run/ss-rust.pid" >/dev/null 2>&1 || true
                        echo -e "${GREEN}✅ 修改成功${RESET}"; sleep 1
                    elif [[ "$op" == "3" ]]; then
                        remove_firewall_rule "$port" "both"; stop_managed_service "ss-rust" '/usr/local/bin/ss-rust -c /etc/ss-rust/config.json' "/var/run/ss-rust.pid"
                        rm -rf /etc/ss-rust /usr/local/bin/ss-rust /etc/systemd/system/ss-rust.service /var/log/ss-rust.log
                        service_use_systemd && systemctl daemon-reload >/dev/null 2>&1 || true
                        echo -e "${GREEN}✅ 已彻底销毁！${RESET}"; sleep 1
                    fi
                fi
                ;;
            2)
                if [[ $has_v2 -eq 1 ]]; then
                    clear
                    local port; show_ss_v2ray_summary; port=$(json_get_path "$SS_V2RAY_CONF" server_port 2>/dev/null)
                    echo -e "---------------------------------"
                    echo -e "${YELLOW}1) 修改端口${RESET} | ${YELLOW}2) 修改密码${RESET} | ${RED}3) 删除节点${RESET} | 0) 返回"
                    read -rp "输入操作: " op
                    if [[ "$op" == "1" ]]; then
                        read -rp "新端口 (1-65535): " np
                        if [[ "$np" =~ ^[0-9]+$ ]] && [ "$np" -ge 1 ] && [ "$np" -le 65535 ]; then
                            json_set_top_value "$SS_V2RAY_CONF" server_port "$np" number; remove_firewall_rule "$port" "tcp"
                            if have_cmd ufw; then ufw allow "$np"/tcp >/dev/null 2>&1; fi
                            if have_cmd firewall-cmd; then firewall-cmd --add-port="$np"/tcp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi
                            restart_managed_service "ss-v2ray" "/usr/local/bin/ss-rust -c /etc/ss-v2ray/config.json" '/usr/local/bin/ss-rust -c /etc/ss-v2ray/config.json' "/var/log/ss-v2ray.log" "/var/run/ss-v2ray.pid" >/dev/null 2>&1 || true
                            echo -e "${GREEN}✅ 修改成功${RESET}"
                        else echo -e "${RED}❌ 端口无效${RESET}"; fi; sleep 1
                    elif [[ "$op" == "2" ]]; then
                        read -rp "新密码: " npwd
                        [[ -z "$npwd" ]] && { echo -e "${RED}❌ 密码不能为空${RESET}"; sleep 1; continue; }
                        json_set_top_value "$SS_V2RAY_CONF" password "$npwd" string
                        restart_managed_service "ss-v2ray" "/usr/local/bin/ss-rust -c /etc/ss-v2ray/config.json" '/usr/local/bin/ss-rust -c /etc/ss-v2ray/config.json' "/var/log/ss-v2ray.log" "/var/run/ss-v2ray.pid" >/dev/null 2>&1 || true
                        echo -e "${GREEN}✅ 修改成功${RESET}"; sleep 1
                    elif [[ "$op" == "3" ]]; then
                        remove_firewall_rule "$port" "tcp"; stop_managed_service "ss-v2ray" '/usr/local/bin/ss-rust -c /etc/ss-v2ray/config.json' "/var/run/ss-v2ray.pid"
                        rm -rf /etc/ss-v2ray /etc/systemd/system/ss-v2ray.service /var/log/ss-v2ray.log "$SS_V2RAY_STATE"
                        service_use_systemd && systemctl daemon-reload >/dev/null 2>&1 || true
                        echo -e "${GREEN}✅ 已彻底销毁！${RESET}"; sleep 1
                    fi
                fi
                ;;
            3)
                if [[ $has_obfs -eq 1 ]]; then
                    clear
                    local port; show_ss_obfs_summary; port=$(json_get_path "$SS_OBFS_CONF" server_port 2>/dev/null)
                    echo -e "---------------------------------"
                    echo -e "${YELLOW}1) 修改端口${RESET} | ${YELLOW}2) 修改密码${RESET} | ${RED}3) 删除节点${RESET} | 0) 返回"
                    read -rp "输入操作: " op
                    if [[ "$op" == "1" ]]; then
                        read -rp "新端口 (1-65535): " np
                        if [[ "$np" =~ ^[0-9]+$ ]] && [ "$np" -ge 1 ] && [ "$np" -le 65535 ]; then
                            json_set_top_value "$SS_OBFS_CONF" server_port "$np" number; remove_firewall_rule "$port" "tcp"
                            if have_cmd ufw; then ufw allow "$np"/tcp >/dev/null 2>&1; fi
                            if have_cmd firewall-cmd; then firewall-cmd --add-port="$np"/tcp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi
                            restart_managed_service "ss-obfs" "/usr/local/bin/ss-rust -c /etc/ss-obfs/config.json" '/usr/local/bin/ss-rust -c /etc/ss-obfs/config.json' "/var/log/ss-obfs.log" "/var/run/ss-obfs.pid" >/dev/null 2>&1 || true
                            echo -e "${GREEN}✅ 修改成功${RESET}"
                        else echo -e "${RED}❌ 端口无效${RESET}"; fi; sleep 1
                    elif [[ "$op" == "2" ]]; then
                        read -rp "新密码: " npwd
                        [[ -z "$npwd" ]] && { echo -e "${RED}❌ 密码不能为空${RESET}"; sleep 1; continue; }
                        json_set_top_value "$SS_OBFS_CONF" password "$npwd" string
                        restart_managed_service "ss-obfs" "/usr/local/bin/ss-rust -c /etc/ss-obfs/config.json" '/usr/local/bin/ss-rust -c /etc/ss-obfs/config.json' "/var/log/ss-obfs.log" "/var/run/ss-obfs.pid" >/dev/null 2>&1 || true
                        echo -e "${GREEN}✅ 修改成功${RESET}"; sleep 1
                    elif [[ "$op" == "3" ]]; then
                        remove_firewall_rule "$port" "tcp"; stop_managed_service "ss-obfs" '/usr/local/bin/ss-rust -c /etc/ss-obfs/config.json' "/var/run/ss-obfs.pid"
                        rm -rf /etc/ss-obfs /etc/systemd/system/ss-obfs.service /var/log/ss-obfs.log "$SS_OBFS_STATE"
                        service_use_systemd && systemctl daemon-reload >/dev/null 2>&1 || true
                        echo -e "${GREEN}✅ 已彻底销毁！${RESET}"; sleep 1
                    fi
                fi
                ;;
            4)
                if [[ $has_vless -eq 1 ]]; then
                    clear
                    local port; show_vless_summary; port=$(json_get_path /usr/local/etc/xray/config.json inbounds.0.port 2>/dev/null)
                    echo -e "---------------------------------"
                    echo -e "${YELLOW}1) 修改端口${RESET} | ${YELLOW}2) 重启节点${RESET} | ${RED}3) 删除节点${RESET} | 0) 返回"
                    read -rp "输入操作: " op
                    if [[ "$op" == "1" ]]; then
                        read -rp "新端口 (1-65535): " np
                        if [[ "$np" =~ ^[0-9]+$ ]] && [ "$np" -ge 1 ] && [ "$np" -le 65535 ]; then
                            json_set_path /usr/local/etc/xray/config.json inbounds.0.port "$np" number; remove_firewall_rule "$port" "tcp"
                            if have_cmd ufw; then ufw allow "$np"/tcp >/dev/null 2>&1; fi
                            if have_cmd firewall-cmd; then firewall-cmd --add-port="$np"/tcp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi
                            restart_managed_service "xray" "/usr/local/bin/xray run -c /usr/local/etc/xray/config.json" '/usr/local/bin/xray run -c /usr/local/etc/xray/config.json' "/var/log/xray.log" "/var/run/xray.pid" >/dev/null 2>&1 || true
                            echo -e "${GREEN}✅ 修改成功${RESET}"
                        else echo -e "${RED}❌ 端口无效${RESET}"; fi; sleep 1
                    elif [[ "$op" == "2" ]]; then
                        restart_managed_service "xray" "/usr/local/bin/xray run -c /usr/local/etc/xray/config.json" '/usr/local/bin/xray run -c /usr/local/etc/xray/config.json' "/var/log/xray.log" "/var/run/xray.pid" >/dev/null 2>&1 || true
                        echo -e "${GREEN}✅ 已重启${RESET}"; sleep 1
                    elif [[ "$op" == "3" ]]; then
                        remove_firewall_rule "$port" "tcp"; stop_managed_service "xray" '/usr/local/bin/xray run -c /usr/local/etc/xray/config.json' "/var/run/xray.pid"
                        rm -rf /usr/local/etc/xray /usr/local/bin/xray /etc/systemd/system/xray.service /var/log/xray.log
                        service_use_systemd && systemctl daemon-reload >/dev/null 2>&1 || true
                        echo -e "${GREEN}✅ 已彻底销毁！${RESET}"; sleep 1
                    fi
                fi
                ;;
            5)
                while true; do
                    clear
                    echo -e "${CYAN}========= ☢️ 全局强制核爆中心 =========${RESET}"
                    echo -e "${YELLOW}已改为序号选择，直接核爆已识别到的节点残留。${RESET}"
                    echo -e "---------------------------------"
                    managed_nuke_build_index
                    local nuke_count=0 i target label port
                    for i in "${!NUCLEAR_TARGETS[@]}"; do
                        [[ -n "${NUCLEAR_TARGETS[$i]}" ]] || continue
                        target="${NUCLEAR_TARGETS[$i]}"; label="${NUCLEAR_LABELS[$i]}"; port="${NUCLEAR_PORTS[$i]}"
                        if [[ -n "$port" ]]; then echo -e " ${CYAN}${i})${RESET} ${label} ${YELLOW}${target}${RESET} [端口 ${GREEN}${port}${RESET}]"
                        else echo -e " ${CYAN}${i})${RESET} ${label} ${YELLOW}${target}${RESET}"; fi
                        ((nuke_count++))
                    done
                    if [[ "$nuke_count" -eq 0 ]]; then
                        echo -e "${RED}未识别到可核爆的节点残留。${RESET}"; read -n1 -rsp "按任意键返回..." _; break
                    fi
                    echo -e "---------------------------------"
                    echo -e "${RED} 9) ⚠️ 核爆全部已识别残留${RESET}"
                    echo -e " 0) 返回"
                    read -rp "请选择序号: " nuke_choice
                    case "$nuke_choice" in
                        0) break ;;
                        9) for i in "${!NUCLEAR_TARGETS[@]}"; do [[ -n "${NUCLEAR_TARGETS[$i]}" ]] && force_kill_service "${NUCLEAR_TARGETS[$i]}" "menu"; done ;;
                        *) if [[ -n "${NUCLEAR_TARGETS[$nuke_choice]}" ]]; then force_kill_service "${NUCLEAR_TARGETS[$nuke_choice]}" "menu"; else echo -e "${RED}❌ 序号无效${RESET}"; sleep 1; fi ;;
                    esac
                done
                ;;
            0) return ;;
        esac
    done
}

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
        chmod 600 /var/swap; mkswap /var/swap >/dev/null 2>&1; swapon /var/swap >/dev/null 2>&1 || true
        grep -qF '/var/swap swap swap defaults 0 0' /etc/fstab 2>/dev/null || echo '/var/swap swap swap defaults 0 0' >> /etc/fstab
        mkdir -p "$META_DIR" 2>/dev/null || true; echo "1" > "$SWAP_MARK_FILE"
        echo -e "${GREEN}✅ ${size_mb}MB Swap 创建成功！${RESET}"
    else
        rm -f /var/swap; echo -e "${YELLOW}⚠️ Swap 创建失败（可能磁盘不足），已跳过。${RESET}"
    fi
}

apply_profile_core() {
    local env="$1" mode="$(profile_alias "$2")" tier target swap_size
    tier="$(detect_machine_tier)"
    [[ "$env" == "nat" ]] && { target="$NAT_CONF_FILE"; rm -f "$CONF_FILE" 2>/dev/null || true; } || { target="$CONF_FILE"; rm -f "$NAT_CONF_FILE" 2>/dev/null || true; }
    if [[ "$env" == "nat" ]]; then
        apply_journald_limit "50M"; apply_ssh_keepalive 30 3
        if [[ "$mode" == "perf" ]]; then
            dns_set_or_lock "lock" || true
            case "$tier" in tiny|small) swap_size=512 ;; medium) swap_size=768 ;; large) swap_size=1024 ;; *) swap_size=512 ;; esac
        else
            dns_set_or_lock "set" || true
            case "$tier" in tiny|small) swap_size=256 ;; medium|large) swap_size=512 ;; *) swap_size=256 ;; esac
        fi
        ensure_swap "$swap_size"
    fi
    render_sysctl_profile "$target" "$env" "$mode" "$tier"
    filter_supported_sysctl_file "$target"
    sysctl --system >/dev/null 2>&1 || true
    meta_set "SYSCTL_PROFILE" "${env}-${mode}"; meta_set "SYSCTL_TIER" "$tier"
    echo -e "${GREEN}✅ 已应用 ${env} / $(profile_title "$mode") / ${tier} 档调优。${RESET}"; sleep 2
}

apply_nat_profile() { apply_profile_core nat "$1"; }
apply_regular_profile() { apply_profile_core regular "$1"; }

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
            1) apply_regular_profile "stable" ;; 2) apply_regular_profile "extreme" ;;
            3) apply_nat_profile "stable" ;; 4) apply_nat_profile "extreme" ;;
            5) auto_clean ;; 0) return ;;
        esac
    done
}

run_daemon_check() {
    if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^ss-rust\.service'; then
        systemctl is-active --quiet ss-rust 2>/dev/null || restart_managed_service "ss-rust" "/usr/local/bin/ss-rust -c /etc/ss-rust/config.json" '/usr/local/bin/ss-rust -c /etc/ss-rust/config.json' "/var/log/ss-rust.log" "/var/run/ss-rust.pid" >/dev/null 2>&1 || true
    fi
    if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^ss-v2ray\.service'; then
        systemctl is-active --quiet ss-v2ray 2>/dev/null || restart_managed_service "ss-v2ray" "/usr/local/bin/ss-rust -c /etc/ss-v2ray/config.json" '/usr/local/bin/ss-rust -c /etc/ss-v2ray/config.json' "/var/log/ss-v2ray.log" "/var/run/ss-v2ray.pid" >/dev/null 2>&1 || true
    fi
    if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^ss-obfs\.service'; then
        systemctl is-active --quiet ss-obfs 2>/dev/null || restart_managed_service "ss-obfs" "/usr/local/bin/ss-rust -c /etc/ss-obfs/config.json" '/usr/local/bin/ss-rust -c /etc/ss-obfs/config.json' "/var/log/ss-obfs.log" "/var/run/ss-obfs.pid" >/dev/null 2>&1 || true
    fi
    if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^xray\.service'; then
        systemctl is-active --quiet xray 2>/dev/null || restart_managed_service "xray" "/usr/local/bin/xray run -c /usr/local/etc/xray/config.json" '/usr/local/bin/xray run -c /usr/local/etc/xray/config.json' "/var/log/xray.log" "/var/run/xray.pid" >/dev/null 2>&1 || true
    fi
}

auto_clean() {
    local is_silent=$1
    if have_cmd apt-get; then apt-get autoremove -yqq >/dev/null 2>&1 || true; apt-get clean -qq >/dev/null 2>&1 || true; fi
    rm -rf /root/.cache/* /tmp/*.tar.xz /tmp/ssserver /tmp/ssr_update.sh /tmp/xray* /tmp/tmp.json /tmp/ssr-v2ray-plugin.* 2>/dev/null || true
    [[ "$is_silent" != "silent" ]] && echo -e "${GREEN}✅ 垃圾清理完毕！${RESET}"
}

update_ss_rust_if_needed() {
    [[ -x "/usr/local/bin/ss-rust" ]] || return 1
    local arch; arch=$(uname -m); local ss_arch_primary="x86_64-unknown-linux-musl"; local ss_arch_fallback="x86_64-unknown-linux-gnu"
    case "$arch" in aarch64|arm64) ss_arch_primary="aarch64-unknown-linux-musl"; ss_arch_fallback="aarch64-unknown-linux-gnu" ;; armv7l|armv7|arm) ss_arch_primary="arm-unknown-linux-musleabi"; ss_arch_fallback="arm-unknown-linux-gnueabi" ;; esac
    local latest; latest=$(cached_latest_tag "shadowsocks/shadowsocks-rust" "ss-rust")
    [[ -z "$latest" ]] && return 2
    local current; current=$(meta_get "SS_RUST_TAG" || true); [[ -z "$current" ]] && current=$(ss_rust_current_tag || true)
    [[ -n "$current" && "$current" == "$latest" ]] && return 3
    if cache_restore_binary_tag "ss-rust" "$latest" /usr/local/bin/ss-rust && (run_with_timeout 3 /usr/local/bin/ss-rust --version >/dev/null 2>&1 || run_with_timeout 3 /usr/local/bin/ss-rust -V >/dev/null 2>&1); then
        meta_set "SS_RUST_TAG" "$latest"; restart_managed_service "ss-rust" "/usr/local/bin/ss-rust -c /etc/ss-rust/config.json" '/usr/local/bin/ss-rust -c /etc/ss-rust/config.json' "/var/log/ss-rust.log" "/var/run/ss-rust.pid" >/dev/null 2>&1 || true
        return 0
    fi
    local tmpdir; tmpdir=$(mktemp -d /tmp/ssr-up-ssrust.XXXXXX); local tarball="${tmpdir}/ss-rust.tar.xz" url="" ok=""
    for candidate_arch in "$ss_arch_primary" "$ss_arch_fallback"; do
        url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${latest}/shadowsocks-${latest}.${candidate_arch}.tar.xz"
        rm -f "$tarball" "${tmpdir}/ssserver" >/dev/null 2>&1 || true
        if ! download_file "$url" "$tarball" || [[ ! -s "$tarball" ]] || ! tar -tf "$tarball" >/dev/null 2>&1; then continue; fi
        tar -xf "$tarball" -C "$tmpdir" ssserver >/dev/null 2>&1 || true
        [[ -x "${tmpdir}/ssserver" ]] || continue
        if run_with_timeout 3 "${tmpdir}/ssserver" --version >/dev/null 2>&1 || run_with_timeout 3 "${tmpdir}/ssserver" -V >/dev/null 2>&1; then ok=1; break; fi
    done
    [[ -n "$ok" ]] || { rm -rf "$tmpdir"; return 2; }
    safe_install_binary "${tmpdir}/ssserver" /usr/local/bin/ss-rust || { rm -rf "$tmpdir"; return 2; }
    cache_store_binary "ss-rust" "$latest" /usr/local/bin/ss-rust >/dev/null 2>&1 || true; meta_set "SS_RUST_TAG" "$latest"
    restart_managed_service "ss-rust" "/usr/local/bin/ss-rust -c /etc/ss-rust/config.json" '/usr/local/bin/ss-rust -c /etc/ss-rust/config.json' "/var/log/ss-rust.log" "/var/run/ss-rust.pid" >/dev/null 2>&1 || true
    rm -rf "$tmpdir"; return 0
}

update_xray_if_needed() {
    [[ -x "/usr/local/bin/xray" ]] || return 1
    local arch; arch=$(uname -m); local xray_arch="64"
    case "$arch" in aarch64|arm64) xray_arch="arm64-v8a" ;; armv7l|armv7|arm) xray_arch="arm32-v7a" ;; esac
    local latest; latest=$(cached_latest_tag "XTLS/Xray-core" "xray")
    [[ -z "$latest" ]] && return 2
    local current; current=$(meta_get "XRAY_TAG" || true); [[ -z "$current" ]] && current=$(xray_current_tag || true)
    [[ -n "$current" && "$current" == "$latest" ]] && return 3
    if cache_restore_binary_tag "xray" "$latest" /usr/local/bin/xray && run_with_timeout 3 /usr/local/bin/xray version >/dev/null 2>&1 && run_with_timeout 3 /usr/local/bin/xray x25519 >/dev/null 2>&1; then
        meta_set "XRAY_TAG" "$latest"; restart_managed_service "xray" "/usr/local/bin/xray run -c /usr/local/etc/xray/config.json" '/usr/local/bin/xray run -c /usr/local/etc/xray/config.json' "/var/log/xray.log" "/var/run/xray.pid" >/dev/null 2>&1 || true
        return 0
    fi
    local tmpdir; tmpdir=$(mktemp -d /tmp/ssr-up-xray.XXXXXX); local zipf="${tmpdir}/xray.zip"
    local url="https://github.com/XTLS/Xray-core/releases/download/${latest}/Xray-linux-${xray_arch}.zip"
    if ! download_file "$url" "$zipf" || [[ ! -s "$zipf" ]] || ! unzip -t "$zipf" >/dev/null 2>&1; then rm -rf "$tmpdir"; return 2; fi
    unzip -qo "$zipf" xray -d "$tmpdir" >/dev/null 2>&1 || true
    [[ -x "${tmpdir}/xray" ]] || { rm -rf "$tmpdir"; return 2; }
    run_with_timeout 3 "${tmpdir}/xray" version >/dev/null 2>&1 || { rm -rf "$tmpdir"; return 2; }
    run_with_timeout 3 "${tmpdir}/xray" x25519 >/dev/null 2>&1 || { rm -rf "$tmpdir"; return 2; }
    safe_install_binary "${tmpdir}/xray" /usr/local/bin/xray || { rm -rf "$tmpdir"; return 2; }
    cache_store_binary "xray" "$latest" /usr/local/bin/xray >/dev/null 2>&1 || true; meta_set "XRAY_TAG" "$latest"
    restart_managed_service "xray" "/usr/local/bin/xray run -c /usr/local/etc/xray/config.json" '/usr/local/bin/xray run -c /usr/local/etc/xray/config.json' "/var/log/xray.log" "/var/run/xray.pid" >/dev/null 2>&1 || true
    rm -rf "$tmpdir"; return 0
}

hot_update_components() {
    local is_silent=$1; local updated_any=0
    update_ss_rust_if_needed; local r1=$?
    update_xray_if_needed; local r3=$?
    [[ $r1 -eq 0 || $r3 -eq 0 ]] && updated_any=1
    if [[ "$is_silent" != "silent" ]]; then
        if [[ $updated_any -eq 1 ]]; then echo -e "${GREEN}✅ 核心组件已完成安全热更（仅更新到新版本）。${RESET}"
        else echo -e "${GREEN}✅ 核心组件已是最新或无需更新。${RESET}"; fi; sleep 2
    fi
}

report_update_result() {
    local name="$1" rc="$2"
    case "$rc" in
        0) echo -e "${GREEN}✅ ${name} 已更新到最新版本。${RESET}" ;; 1) echo -e "${YELLOW}⚠️ ${name} 当前未安装，跳过。${RESET}" ;;
        2) echo -e "${RED}❌ ${name} 更新失败。${RESET}" ;; 3) echo -e "${GREEN}✅ ${name} 已是最新版本。${RESET}" ;;
        *) echo -e "${YELLOW}⚠️ ${name} 状态未知（返回码 ${rc}）。${RESET}" ;;
    esac
}

show_core_cache_status() {
    local ss_inst="未安装" xr_inst="未安装" ss_cache="无" xr_cache="无"
    [[ -x /usr/local/bin/ss-rust ]] && ss_inst="$(ss_rust_current_tag || echo installed)"
    [[ -x /usr/local/bin/xray ]] && xr_inst="$(xray_current_tag || echo installed)"
    [[ -x "$(cache_current_binary_path ss-rust 2>/dev/null)" ]] && ss_cache="有"
    [[ -x "$(cache_current_binary_path xray 2>/dev/null)" ]] && xr_cache="有"
    echo -e "${CYAN}SS-Rust${RESET}    已安装: ${GREEN}${ss_inst}${RESET} | 缓存: ${YELLOW}${ss_cache}${RESET}"
    echo -e "${CYAN}Xray${RESET}       已安装: ${GREEN}${xr_inst}${RESET} | 缓存: ${YELLOW}${xr_cache}${RESET}"
    echo -e "${CYAN}说明:${RESET} 创建节点时会优先复用【已安装核心】->【本地缓存】->【联网下载】"
}

core_cache_menu() {
    while true; do
        clear
        echo -e "${CYAN}========= 核心缓存与更新中心 =========${RESET}"; show_core_cache_status; echo
        echo -e "${GREEN} 1.${RESET} 更新 SS-Rust 核心"
        echo -e "${GREEN} 2.${RESET} 更新 Xray 核心"
        echo -e "${YELLOW} 3.${RESET} 一键更新全部核心"
        echo -e "${YELLOW} 4.${RESET} 清理全部核心缓存"
        echo -e " 0. 返回主菜单"
        read -rp "输入数字 [0-4]: " cache_num
        case "$cache_num" in
            1) update_ss_rust_if_needed; report_update_result "SS-Rust" "$?"; read -n 1 -s -r -p "按任意键继续..." ;;
            2) update_xray_if_needed; report_update_result "Xray" "$?"; read -n 1 -s -r -p "按任意键继续..." ;;
            3) update_ss_rust_if_needed; report_update_result "SS-Rust" "$?"; update_xray_if_needed; report_update_result "Xray" "$?"; read -n 1 -s -r -p "按任意键继续..." ;;
            4) core_cache_clear_all; echo -e "${GREEN}✅ 本地核心缓存已清理。${RESET}"; read -n 1 -s -r -p "按任意键继续..." ;;
            0) return ;;
        esac
    done
}

daily_task() { auto_clean "silent"; }

ssr_cleanup_artifacts() {
    if [[ -f "/etc/ss-rust/config.json" ]]; then local sp; sp=$(json_get_path /etc/ss-rust/config.json server_port 2>/dev/null); [[ -n "$sp" && "$sp" != "null" ]] && remove_firewall_rule "$sp" "both"; fi
    if [[ -f "$SS_V2RAY_CONF" ]]; then local vp; vp=$(json_get_path "$SS_V2RAY_CONF" server_port 2>/dev/null); [[ -n "$vp" && "$vp" != "null" ]] && remove_firewall_rule "$vp" "tcp"; fi
    if [[ -f "$SS_OBFS_CONF" ]]; then local op; op=$(json_get_path "$SS_OBFS_CONF" server_port 2>/dev/null); [[ -n "$op" && "$op" != "null" ]] && remove_firewall_rule "$op" "tcp"; fi
    if [[ -f "/usr/local/etc/xray/config.json" ]]; then local xp; xp=$(json_get_path /usr/local/etc/xray/config.json inbounds.0.port 2>/dev/null); [[ -n "$xp" && "$xp" != "null" ]] && remove_firewall_rule "$xp" "tcp"; fi
    stop_managed_service "ss-rust" '/usr/local/bin/ss-rust -c /etc/ss-rust/config.json' "/var/run/ss-rust.pid"
    stop_managed_service "ss-v2ray" '/usr/local/bin/ss-rust -c /etc/ss-v2ray/config.json' "/var/run/ss-v2ray.pid"
    stop_managed_service "ss-obfs" '/usr/local/bin/ss-rust -c /etc/ss-obfs/config.json' "/var/run/ss-obfs.pid"
    stop_managed_service "xray" '/usr/local/bin/xray run -c /usr/local/etc/xray/config.json' "/var/run/xray.pid"
    rm -rf /etc/ss-rust /etc/ss-v2ray /etc/ss-obfs /usr/local/bin/ss-rust /etc/systemd/system/ss-rust.service /etc/systemd/system/ss-v2ray.service /etc/systemd/system/ss-obfs.service /var/log/ss-rust.log /var/log/ss-v2ray.log /var/log/ss-obfs.log
    rm -rf /usr/local/etc/xray /usr/local/bin/xray /etc/systemd/system/xray.service /var/log/xray.log
    [[ -f "$DDNS_CONF" ]] && remove_cf_ddns "force" 2>/dev/null || true
    rm -f /usr/local/bin/v2ray-plugin /usr/local/bin/obfs-server /usr/local/bin/obfs-local "$CONF_FILE" "$NAT_CONF_FILE" "$DDNS_CONF" "$DDNS_LOG" "$META_FILE" "$SS_V2RAY_STATE" "$SS_OBFS_STATE"
    rm -f /usr/local/bin/ssr /usr/local/bin/ssr.sh 2>/dev/null || true
    crontab -l 2>/dev/null | grep -vE "/usr/local/bin/ssr (auto_update|auto_task|daemon_check|auto_core_update|clean|daily_task|ddns)" | crontab - 2>/dev/null || true
    dns_unlock_restore 2>/dev/null || true
    if [[ -f "$SWAP_MARK_FILE" ]]; then swapoff /var/swap 2>/dev/null || true; rm -f /var/swap; sed -i '/^\/var\/swap[[:space:]]\+swap[[:space:]]\+swap[[:space:]]\+defaults[[:space:]]\+0[[:space:]]\+0$/d' /etc/fstab 2>/dev/null || true; rm -f "$SWAP_MARK_FILE" 2>/dev/null || true; fi
    restore_file_if_present "$SSHD_BACKUP_FILE" /etc/ssh/sshd_config; restore_file_if_present "$JOURNALD_BACKUP_FILE" /etc/systemd/journald.conf
    restart_ssh_safe >/dev/null 2>&1 || true; systemctl restart systemd-journald 2>/dev/null || true; systemctl daemon-reload 2>/dev/null || true
    rm -f "$SSHD_BACKUP_FILE" "$JOURNALD_BACKUP_FILE" 2>/dev/null || true; rm -rf "$META_DIR" "$DNS_BACKUP_DIR" 2>/dev/null || true
    rm -f "$RESOLVED_DROPIN" "$SSH_AUTH_DROPIN" 2>/dev/null || true
}

total_uninstall() {
    echo -e "${RED}⚠️ 正在进行无痕毁灭性全量卸载...${RESET}"; ssr_cleanup_artifacts; echo -e "${GREEN}✅ 完美无痕卸载完成！系统已彻底洁净退水。${RESET}"; exit 0
}

sys_menu() {
    while true; do
        clear
        echo -e "${CYAN}========= 系统基础与极客管理 =========${RESET}"
        echo -e "${YELLOW} 1.${RESET} 一键修改 SSH 安全端口\n${YELLOW} 2.${RESET} 一键修改 Root 密码\n${YELLOW} 3.${RESET} 服务器时间防偏移同步\n${YELLOW} 4.${RESET} SSH 密钥登录管理中心\n${GREEN} 5.${RESET} 原生 Cloudflare DDNS 解析模块\n${YELLOW} 6.${RESET} DNS 管理中心（智能/手动/锁定/恢复）\n 0. 返回上级菜单"
        read -rp "输入数字 [0-6]: " sys_num
        case "$sys_num" in
            1) change_ssh_port ;; 2) change_root_password ;; 3) sync_server_time ;; 4) ssh_key_menu ;; 5) cf_ddns_menu ;; 6) dns_menu ;; 0) return ;;
        esac
    done
}

main_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}       SSR 综合智能管理脚本 v${SCRIPT_VERSION}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${YELLOW} 1.${RESET} 原生部署 SS-Rust"
    echo -e "${YELLOW} 2.${RESET} 自动部署 SS2022 + v2ray-plugin"
    echo -e "${YELLOW} 3.${RESET} 自动部署 SS2022 + obfs-local"
    echo -e "${YELLOW} 4.${RESET} 原生部署 VLESS Reality"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    echo -e "${GREEN} 5.${RESET} 🔰 统一节点管控中心 (查看 / 修改端口 / 删除 / 核爆)"
    echo -e "${YELLOW} 6.${RESET} 网络优化与系统清理 (手动常规/NAT + 清理)"
    echo -e "${GREEN} 7.${RESET} 核心缓存与更新中心"
    echo -e "${CYAN}============================================${RESET}"
    echo -e " 0. 返回上级菜单"
    read -rp "请输入对应数字 [0-7]: " num
    case "$num" in
        1) install_ss_rust_native ;; 2) install_ss_v2ray_plugin_native ;; 3) install_ss_obfs_native ;; 4) install_vless_native ;;
        5) unified_node_manager ;; 6) opt_menu ;; 7) core_cache_menu ;; 0) return 1 ;; *) echo -e "${RED}请输入正确的选项！${RESET}" ;;
    esac
    echo -e "\n${CYAN}按任意键返回上一层...${RESET}"
    read -n 1 -s -r
}

SSR_MODULE_EOF
    mv -f "${SSR_MODULE_FILE}.tmp" "${SSR_MODULE_FILE}"

    # NFT 模块（修复：原子化写入）
    cat > "${NFT_MODULE_FILE}.tmp" <<'NFT_MODULE_EOF'
#!/bin/bash

# nftables 端口转发管理面板 (Pro 智能优化版)

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
NFTABLES_CONF="/etc/nftables.conf"
NFTABLES_CREATED_MARK="/etc/nftables.conf.nftmgr_created"
PERSIST_MODE_DEFAULT="service"
NFT_MGR_CONF="${NFT_MGR_DIR}/nft_mgr.conf"
NFT_MGR_SERVICE="/etc/systemd/system/nft-mgr.service"
SYSCTL_FILE="/etc/sysctl.d/99-nft-mgr.conf"
LOG_DIR="/var/log/nft_ddns"
LOCK_FILE="/var/lock/nft_mgr.lock"

CMD_NAME="nftmgr"

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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

msg_ok()   { echo -e "${GREEN}$*${PLAIN}"; }
msg_warn() { echo -e "${YELLOW}$*${PLAIN}"; }
msg_err()  { echo -e "${RED}$*${PLAIN}"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() { [[ $EUID -ne 0 ]] && msg_err "错误: 必须使用 root 权限运行!" && exit 1; }

script_realpath() {
    local p="$0"
    if command -v readlink >/dev/null 2>&1; then readlink -f "$p" 2>/dev/null && return 0; fi
    if command -v realpath >/dev/null 2>&1; then realpath "$p" 2>/dev/null && return 0; fi
    echo "$p"
}
detect_pkg_mgr() {
    if have_cmd apt-get; then echo "apt"
    elif have_cmd dnf; then echo "dnf"
    elif have_cmd yum; then echo "yum"
    else echo ""; fi
}

install_deps() {
    local mgr; mgr="$(detect_pkg_mgr)"
    [[ -z "$mgr" ]] && return 1
    if [[ "$mgr" == "apt" ]]; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -yqq nftables dnsutils curl util-linux iproute2 >/dev/null 2>&1 || true
    else
        "$mgr" install -y nftables bind-utils curl util-linux iproute >/dev/null 2>&1 || true
    fi
}

check_env() {
    local need=0
    for c in nft dig curl flock ss sysctl; do have_cmd "$c" || need=1; done
    [[ $need -eq 1 ]] && install_deps
    for c in nft dig curl flock ss sysctl; do have_cmd "$c" || msg_warn "⚠️ 未找到依赖命令: $c（部分功能可能不可用）"; done
    mkdir -p "$(dirname "$CONFIG_FILE")" "$LOG_DIR" "$NFT_MGR_DIR" 2>/dev/null || true
    [[ -f "$CONFIG_FILE" ]] || touch "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    [[ -f "$SETTINGS_FILE" ]] || touch "$SETTINGS_FILE"; chmod 600 "$SETTINGS_FILE" 2>/dev/null || true
}

install_global_command() { return 0; }

with_lock() {
    if have_cmd flock; then
        ( flock -n 200 || { msg_warn "⚠️ 任务繁忙：已有实例在运行，已跳过本次操作。"; exit 99; }; "$@" ) 200>"$LOCK_FILE"
        return $?
    else
        "$@"; return $?
    fi
}

ensure_ddns_cron_enabled() {
    local my_cmd="/usr/local/bin/my"
    if crontab -l 2>/dev/null | grep -Fq "${my_cmd} nft --cron"; then return 0; fi
    remove_ddns_cron_task || true
    (crontab -l 2>/dev/null; echo "* * * * * ${my_cmd} nft --cron > /dev/null 2>&1") | crontab - 2>/dev/null || true
    return 0
}
has_domain_rules() {
    while IFS='|' read -r lp addr tp last_ip proto; do
        [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
        [[ -z "$addr" ]] && continue
        if ! is_ipv4 "$addr"; then return 0; fi
    done < "$CONFIG_FILE"
    return 1
}

remove_ddns_cron_task() {
    local cur; cur="$(crontab -l 2>/dev/null || true)"
    [[ -z "$cur" ]] && return 0
    echo "$cur" | grep -vE '(^|\s)(/usr/local/bin/my\s+nft\s+--cron|/usr/local/bin/nftmgr|nftmgr)\s+--cron(\s|$)' | crontab - 2>/dev/null || true
    return 0
}
ensure_ddns_cron_disabled_if_unused() {
    if has_domain_rules; then return 0; fi
    if crontab -l 2>/dev/null | grep -Eq '(^|\s)(/usr/local/bin/my\s+nft\s+--cron|/usr/local/bin/nftmgr|nftmgr)\s+--cron(\s|$)'; then remove_ddns_cron_task || true; fi
    return 0
}

is_port() { local p="$1"; [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; }
is_ipv4() { local ip="$1"; [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
normalize_proto() {
    local p="${1,,}"
    case "$p" in tcp|udp|both) echo "$p" ;; "") echo "both" ;; *) echo "both" ;; esac
}

get_ip() {
    local addr="$1"
    if is_ipv4 "$addr"; then echo "$addr"; return 0; fi
    dig +time=2 +tries=1 +short -4 A "$addr" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n 1
}

manage_firewall() {
    local action="$1" port="$2" proto="$3"
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

nftables_conf_includes_mgr() {
    [[ -f "$NFTABLES_CONF" ]] || return 1
    grep -E '^[[:space:]]*include[[:space:]]+"?/etc/nftables\.d/\*\.conf"?[[:space:]]*$' "$NFTABLES_CONF" >/dev/null 2>&1 && return 0
    grep -E '^[[:space:]]*include[[:space:]]+"?/etc/nftables\.d/nft_mgr\.conf"?[[:space:]]*$' "$NFTABLES_CONF" >/dev/null 2>&1 && return 0
    return 1
}

enable_persist_system() {
    mkdir -p "$NFT_MGR_DIR" 2>/dev/null || true
    [[ -f "$NFT_MGR_CONF" ]] || generate_empty_conf "$NFT_MGR_CONF"
    if [[ -e "$NFTABLES_CONF" && ! -f "$NFTABLES_CONF" ]]; then msg_err "❌ ${NFTABLES_CONF} 存在但不是普通文件，无法注入 include。"; return 1; fi
    if [[ ! -f "$NFTABLES_CONF" ]]; then
        cat > "$NFTABLES_CONF" << EOF
#!/usr/sbin/nft -f
# generated by nftmgr (compat mode)
include "${NFT_MGR_CONF}"
EOF
        chmod 644 "$NFTABLES_CONF" 2>/dev/null || true
        echo "1" > "$NFTABLES_CREATED_MARK" 2>/dev/null || true
    else
        local bak="${NFTABLES_CONF}.nftmgr.bak.$(date +%s)"
        cp -a "$NFTABLES_CONF" "$bak" 2>/dev/null || true
        if ! nftables_conf_includes_mgr; then
            printf "\n# nftmgr include (added %s)\ninclude \"%s\"\n" "$(date '+%F %T')" "$NFT_MGR_CONF" >> "$NFTABLES_CONF"
        fi
    fi
    if have_cmd nft; then
        if ! nft -c -f "$NFTABLES_CONF" >/dev/null 2>&1; then msg_err "❌ 注入后 ${NFTABLES_CONF} 语法校验失败，已保留备份文件，请手动检查。"; return 1; fi
    fi
    if have_cmd systemctl; then
        systemctl enable --now nftables >/dev/null 2>&1 || true
        systemctl restart nftables >/dev/null 2>&1 || true
        systemctl disable --now nft-mgr >/dev/null 2>&1 || true
    else
        nft -f "$NFTABLES_CONF" >/dev/null 2>&1 || true
    fi
    PERSIST_MODE="system"
    msg_ok "✅ 已启用【系统持久化兼容模式】：/etc/nftables.conf 已包含 nft_mgr.conf。"
    return 0
}

enable_persist_service() {
    if have_cmd systemctl; then ensure_nft_mgr_service; systemctl enable --now nft-mgr >/dev/null 2>&1 || true; fi
    PERSIST_MODE="service"
    msg_ok "✅ 已启用【服务持久化模式】：由 nft-mgr.service 加载 nft_mgr.conf。"
    return 0
}

persist_status() {
    echo -e "${CYAN}========= 持久化状态 =========${PLAIN}"
    echo -e "当前模式: ${YELLOW}${PERSIST_MODE}${PLAIN}"
    if [[ -f "$NFT_MGR_CONF" ]]; then echo -e "规则文件: ${GREEN}${NFT_MGR_CONF}${PLAIN}"; else echo -e "规则文件: ${RED}${NFT_MGR_CONF} 不存在${PLAIN}"; fi
    if [[ -f "$NFTABLES_CONF" ]]; then
        if nftables_conf_includes_mgr; then echo -e "/etc/nftables.conf: ${GREEN}已包含 nftmgr 规则（include）${PLAIN}"
        else echo -e "/etc/nftables.conf: ${YELLOW}未包含 nftmgr include${PLAIN}"; fi
    else echo -e "/etc/nftables.conf: ${YELLOW}不存在${PLAIN}"; fi
    if have_cmd systemctl; then
        systemctl is-enabled nftables >/dev/null 2>&1 && echo -e "nftables.service: ${GREEN}enabled${PLAIN}" || echo -e "nftables.service: ${YELLOW}disabled${PLAIN}"
        systemctl is-enabled nft-mgr >/dev/null 2>&1 && echo -e "nft-mgr.service: ${GREEN}enabled${PLAIN}" || echo -e "nft-mgr.service: ${YELLOW}disabled${PLAIN}"
    fi
    echo -e "${CYAN}==============================${PLAIN}"
}

auto_persist_setup() {
    PERSIST_MODE="$PERSIST_MODE_DEFAULT"
    if [[ -f "$NFTABLES_CONF" ]] && nftables_conf_includes_mgr; then PERSIST_MODE="system"
    elif have_cmd systemctl && systemctl is-enabled nftables >/dev/null 2>&1; then PERSIST_MODE="system"; fi
    if [[ "$PERSIST_MODE" == "system" ]]; then enable_persist_system >/dev/null 2>&1 || true; else enable_persist_service >/dev/null 2>&1 || true; fi
}

nft_profile_alias() { case "${1:-stable}" in perf|extreme|turbo) echo "perf" ;; *) echo "stable" ;; esac }
nft_profile_title() { [[ "$(nft_profile_alias "$1")" == "perf" ]] && echo "极致优化" || echo "稳定优先"; }

nft_detect_machine_tier() {
    local mem_mb
    mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    if (( mem_mb < 700 )); then echo tiny; elif (( mem_mb < 1400 )); then echo small; elif (( mem_mb < 3000 )); then echo medium; else echo large; fi
}

nft_best_congestion_control() {
    local avail; avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    [[ " $avail " == *" bbr "* ]] && { echo bbr; return 0; }
    [[ " $avail " == *" cubic "* ]] && { echo cubic; return 0; }
    [[ " $avail " == *" reno "* ]] && { echo reno; return 0; }
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic
}

nft_sysctl_key_supported() { local key="$1"; [[ -e "/proc/sys/${key//./\/}" ]]; }
nft_write_sysctl_line() { local out="$1" key="$2" value="$3"; nft_sysctl_key_supported "$key" || return 0; echo "${key} = ${value}" >> "$out"; }

ensure_forwarding() {
    local cur; cur="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
    if [[ "$cur" != "1" ]]; then
        mkdir -p /etc/sysctl.d 2>/dev/null || true
        touch "$SYSCTL_FILE" 2>/dev/null || true
        if grep -qE "^\s*net\.ipv4\.ip_forward\s*=" "$SYSCTL_FILE" 2>/dev/null; then sed -i 's|^\s*net\.ipv4\.ip_forward\s*=.*|net.ipv4.ip_forward = 1|g' "$SYSCTL_FILE"
        else echo "net.ipv4.ip_forward = 1" >> "$SYSCTL_FILE"; fi
        sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    fi
}

nft_apply_profile() {
    local mode="$(nft_profile_alias "${1:-stable}")" tier cc somax backlog filemax rmax wmax fin_timeout conntrack
    tier="$(nft_detect_machine_tier)"
    cc="$(nft_best_congestion_control)"

    case "${mode}:${tier}" in
        stable:tiny|stable:small) somax=4096; backlog=4096; filemax=262144; rmax=8388608;  wmax=8388608;  fin_timeout=30; conntrack=131072 ;;
        stable:medium) somax=8192; backlog=8192; filemax=524288; rmax=16777216; wmax=16777216; fin_timeout=25; conntrack=262144 ;;
        stable:large) somax=16384; backlog=16384; filemax=524288; rmax=33554432; wmax=33554432; fin_timeout=20; conntrack=524288 ;;
        perf:tiny|perf:small) somax=16384; backlog=16384; filemax=524288; rmax=16777216; wmax=16777216; fin_timeout=20; conntrack=262144 ;;
        perf:medium) somax=32768; backlog=32768; filemax=1048576; rmax=33554432; wmax=33554432; fin_timeout=15; conntrack=524288 ;;
        perf:large) somax=65535; backlog=65535; filemax=1048576; rmax=67108864; wmax=67108864; fin_timeout=15; conntrack=1048576 ;;
        *) somax=8192; backlog=8192; filemax=524288; rmax=16777216; wmax=16777216; fin_timeout=25; conntrack=262144 ;;
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
    if have_cmd systemctl; then systemctl enable --now nftables >/dev/null 2>&1 || true; ensure_nft_mgr_service; fi
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
    case "$pick" in 0) return ;; 1) nft_apply_profile "stable" ;; 2) nft_apply_profile "extreme" ;; *) msg_err "无效选项"; sleep 1 ;; esac
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
    local out="$1" any=0
    {
        echo "# nft-mgr ruleset (generated at $(date '+%F %T'))"
        echo "table ip nft_mgr_nat {"
        echo "    chain prerouting {"
        echo "        type nat hook prerouting priority -100;"
        while IFS='|' read -r lp addr tp last_ip proto; do
            [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
            proto="$(normalize_proto "$proto")"
            is_port "$lp" || continue; is_port "$tp" || continue; [[ -z "$addr" ]] && continue
            local ip="$last_ip"; [[ -z "$ip" ]] && ip="$(get_ip "$addr")"
            is_ipv4 "$ip" || continue
            case "$proto" in
                tcp) echo "        tcp dport ${lp} counter dnat to ${ip}:${tp}"; any=1 ;;
                udp) echo "        udp dport ${lp} counter dnat to ${ip}:${tp}"; any=1 ;;
                both) echo "        tcp dport ${lp} counter dnat to ${ip}:${tp}"; echo "        udp dport ${lp} counter dnat to ${ip}:${tp}"; any=1 ;;
            esac
        done < "$CONFIG_FILE"
        echo "    }"
        echo "    chain postrouting {"
        echo "        type nat hook postrouting priority 100;"
        while IFS='|' read -r lp addr tp last_ip proto; do
            [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
            proto="$(normalize_proto "$proto")"
            is_port "$lp" || continue; is_port "$tp" || continue; [[ -z "$addr" ]] && continue
            local ip="$last_ip"; [[ -z "$ip" ]] && ip="$(get_ip "$addr")"
            is_ipv4 "$ip" || continue
            case "$proto" in
                tcp) echo "        ip daddr ${ip} tcp dport ${tp} counter masquerade"; any=1 ;;
                udp) echo "        ip daddr ${ip} udp dport ${tp} counter masquerade"; any=1 ;;
                both) echo "        ip daddr ${ip} tcp dport ${tp} counter masquerade"; echo "        ip daddr ${ip} udp dport ${tp} counter masquerade"; any=1 ;;
            esac
        done < "$CONFIG_FILE"
        echo "    }"
        echo "}"
    } > "$out"
    chmod 600 "$out" 2>/dev/null || true
    [[ $any -eq 1 ]] || return 2
    return 0
}

apply_rules_impl() {
    ensure_forwarding
    ensure_nft_mgr_service

    local tmp; tmp="$(mktemp /tmp/nftmgr.XXXXXX)"
    local has_rules=0

    if generate_nft_conf "$tmp"; then has_rules=1; else generate_empty_conf "$tmp"; has_rules=0; fi
    if ! have_cmd nft; then rm -f "$tmp"; return 1; fi

    local chk_err; chk_err="$(nft -c -f "$tmp" 2>&1)"
    if [[ $? -ne 0 ]]; then
        mkdir -p "$
