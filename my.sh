#!/bin/bash
# 综合管理脚本：SSR + nftables
# 快捷命令：my
# 更新地址：https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/my.sh
# 版本：v1.3.4  (build 2026-03-15+txn-state-tree)
# 指纹：CMD_NAME="my" / MY_SCRIPT_ID="my-manager"

set -o pipefail

# 兼容 cron/systemd 的精简 PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# --------------------------
# 基本信息
# --------------------------
CMD_NAME="my"
MY_SCRIPT_ID="my-manager"
MY_VERSION="1.3.4"

MY_INSTALL_DIR="/usr/local/lib/my"
MY_STATE_DIR="${MY_INSTALL_DIR}/state"
MY_SSR_STATE_DIR="${MY_STATE_DIR}/ssr"
MY_NGX_STATE_DIR="${MY_STATE_DIR}/nginx"
COMMON_MODULE_FILE="${MY_INSTALL_DIR}/common_module.sh"
SSR_MODULE_FILE="${MY_INSTALL_DIR}/ssr_module.sh"
NFT_MODULE_FILE="${MY_INSTALL_DIR}/nft_module.sh"
NGX_MODULE_FILE="${MY_INSTALL_DIR}/nginx_module.sh"

MY_LOCK_FILE="/var/lock/my.lock"
SSR_LOCK_FILE="/var/lock/ssr.lock"

SSR_DDNS_CONF="${MY_SSR_STATE_DIR}/ddns.conf"

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

    # 公共工具模块（供 SSR / NFT / Nginx 共享，避免跨模块函数丢失）
    cat > "${COMMON_MODULE_FILE}.tmp" <<'COMMON_MODULE_EOF'
#!/bin/bash
set -o pipefail

have_cmd() { command -v "$1" >/dev/null 2>&1; }

state_dir_ensure() {
    mkdir -p "$1" >/dev/null 2>&1 || return 1
}

state_kv_get() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 1
    grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 | cut -d= -f2- | sed 's/^"//; s/"$//'
}

state_kv_set() {
    local file="$1" key="$2" value="$3"
    state_dir_ensure "$(dirname "$file")" || return 1
    touch "$file" 2>/dev/null || return 1
    chmod 600 "$file" 2>/dev/null || true
    if grep -qE "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}="${value}"|g" "$file"
    else
        printf '%s="%s"
' "$key" "$value" >> "$file"
    fi
}

state_write_pairs() {
    local file="$1"; shift
    state_dir_ensure "$(dirname "$file")" || return 1
    : > "$file"
    while [[ $# -ge 2 ]]; do
        printf '%s="%s"
' "$1" "$2" >> "$file"
        shift 2
    done
    chmod 600 "$file" 2>/dev/null || true
}

state_migrate_file() {
    local old="$1" new="$2"
    [[ -e "$old" ]] || return 0
    state_dir_ensure "$(dirname "$new")" || return 1
    if [[ ! -e "$new" || ! -s "$new" ]]; then
        cp -a "$old" "$new" >/dev/null 2>&1 || return 1
    fi
}

state_migrate_dir() {
    local old="$1" new="$2"
    [[ -d "$old" ]] || return 0
    state_dir_ensure "$new" || return 1
    cp -a "$old"/. "$new"/ >/dev/null 2>&1 || true
}

txn_begin() {
    local dir
    dir=$(mktemp -d /tmp/my-txn.XXXXXX) || return 1
    : > "$dir/stack"
    echo "$dir"
}

txn_register() {
    local txn="$1"; shift
    local out="" q
    [[ -n "$txn" ]] || return 1
    for q in "$@"; do
        printf -v q '%q' "$q"
        out+="$q "
    done
    printf '%s
' "${out% }" >> "$txn/stack"
}

_txn_restore_file() {
    local dst="$1" bak="$2"
    [[ -f "$bak" ]] || return 1
    cp -a "$bak" "$dst" >/dev/null 2>&1 || return 1
}

_txn_remove_path() {
    rm -rf "$1" >/dev/null 2>&1 || true
}

txn_backup_file() {
    local txn="$1" target="$2" bak=""
    mkdir -p "$txn/files" >/dev/null 2>&1 || return 1
    if [[ -e "$target" ]]; then
        bak=$(mktemp "$txn/files/$(basename "$target").XXXXXX") || return 1
        cp -a "$target" "$bak" >/dev/null 2>&1 || { rm -f "$bak"; return 1; }
        txn_register "$txn" _txn_restore_file "$target" "$bak"
        echo "$bak"
    else
        txn_register "$txn" _txn_remove_path "$target"
        echo ""
    fi
}

txn_reverse_read() {
    local file="$1"
    if have_cmd tac; then
        tac "$file"
    else
        awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}' "$file"
    fi
}

txn_abort() {
    local txn="$1" line
    [[ -n "$txn" && -f "$txn/stack" ]] || { rm -rf "$txn" >/dev/null 2>&1 || true; return 0; }
    while IFS= read -r line; do
        eval "$line" >/dev/null 2>&1 || true
    done < <(txn_reverse_read "$txn/stack")
    rm -rf "$txn" >/dev/null 2>&1 || true
}

txn_commit() {
    rm -rf "$1" >/dev/null 2>&1 || true
}

is_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    ((p >= 1 && p <= 65535))
}

is_ipv4() {
    local ip="$1" o1 o2 o3 o4 octet
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    for octet in "$o1" "$o2" "$o3" "$o4"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        ((octet >= 0 && octet <= 255)) || return 1
    done
}

normalize_proto() {
    local p="${1,,}"
    case "$p" in
        tcp|udp|both) echo "$p" ;;
        *) echo "both" ;;
    esac
}

proto_to_list() {
    local p
    p=$(normalize_proto "$1")
    case "$p" in
        both) printf '%s
' tcp udp ;;
        *) printf '%s
' "$p" ;;
    esac
}

port_in_use() {
    local port="$1" proto="${2:-both}"
    local used=1
    proto="$(normalize_proto "$proto")"
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

resolve_ipv4_first() {
    local addr="$1" out=""
    if is_ipv4 "$addr"; then
        echo "$addr"
        return 0
    fi
    if have_cmd dig; then
        out=$(dig +time=2 +tries=1 +short -4 A "$addr" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n1)
        [[ -n "$out" ]] && { echo "$out"; return 0; }
    fi
    if have_cmd getent; then
        out=$(getent ahostsv4 "$addr" 2>/dev/null | awk '/STREAM/ {print $1; exit}')
        [[ -n "$out" ]] && { echo "$out"; return 0; }
    fi
    if have_cmd host; then
        out=$(host -4 "$addr" 2>/dev/null | awk '/has address/ {print $NF; exit}')
        [[ -n "$out" ]] && { echo "$out"; return 0; }
    fi
    if have_cmd nslookup; then
        out=$(nslookup "$addr" 2>/dev/null | awk '/^Address: / {print $2; exit}')
        [[ -n "$out" ]] && { echo "$out"; return 0; }
    fi
    return 1
}
COMMON_MODULE_EOF
mv -f "${COMMON_MODULE_FILE}.tmp" "${COMMON_MODULE_FILE}"

    # SSR 模块（已移除脚本自更新/卸载菜单，并适配 my 统一管理）
    cat > "${SSR_MODULE_FILE}.tmp" <<'SSR_MODULE_EOF'
#!/bin/bash
# 脚本名称: SSR 综合管理脚本 (稳定优先 + 极致性能 Profiles)
# 核心特性:
#   - 节点部署: SS-Rust / SS2022 + v2ray-plugin / VLESS Reality (Xray)
#   - 双档位网络调优: 手动选择 常规机器 / NAT 小鸡 => 稳定优先 / 极致优化
#   - Cloudflare DDNS: 原生 API + 定时守护
#   - 自动任务互斥: cron 使用 flock 防并发踩踏
#   - 稳定更新: 仅在有新版本时更新；先校验候选二进制，再重启服务，失败自动回滚
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
readonly SSR_STATE_DIR="${MY_STATE_DIR:-/usr/local/lib/my/state}/ssr"
readonly DDNS_CONF="${SSR_STATE_DIR}/ddns.conf"
readonly DDNS_LOG="/var/log/ssr_ddns.log"
readonly LEGACY_DDNS_CONF="/usr/local/etc/ssr_ddns.conf"

readonly LOCK_FILE="/var/lock/ssr.lock"

# Meta (用于判断是否有新版本)
readonly META_DIR="${SSR_STATE_DIR}"
readonly META_FILE="${META_DIR}/versions.conf"
readonly SS_V2RAY_CONF="/etc/ss-v2ray/config.json"
readonly SS_V2RAY_STATE="${META_DIR}/ss_v2ray.conf"
readonly SWAP_MARK_FILE="${META_DIR}/swap_created_by_ssr"
readonly SSHD_BACKUP_FILE="${META_DIR}/sshd_config.bak"
readonly LEGACY_META_DIR="/usr/local/etc/ssr_meta"
COMMON_MODULE_FILE="${MY_INSTALL_DIR:-/usr/local/lib/my}/common_module.sh"
[[ -f "$COMMON_MODULE_FILE" ]] && source "$COMMON_MODULE_FILE"
readonly SSH_AUTH_DROPIN="/etc/ssh/sshd_config.d/00-my-auth.conf"
readonly SSH_PORT_DROPIN="/etc/ssh/sshd_config.d/00-my-port.conf"
readonly ROOT_SSH_DIR="/root/.ssh"
readonly ROOT_AUTH_KEYS_FILE="${ROOT_SSH_DIR}/authorized_keys"
readonly JOURNALD_BACKUP_FILE="${META_DIR}/journald.conf.bak"
readonly QUIC_STATE_FILE="${SSR_STATE_DIR}/quic.conf"
readonly QUIC_NFT_TABLE="my_quic"
readonly QUIC_RULE_COMMENT="my-quic-udp443"

readonly DNS_BACKUP_DIR="${SSR_STATE_DIR}/dns"
readonly LEGACY_DNS_BACKUP_DIR="/usr/local/etc/ssr_dns_backup"
readonly DNS_META="${DNS_BACKUP_DIR}/meta.conf"
readonly DNS_FILE_BAK="${DNS_BACKUP_DIR}/resolv.conf.bak"
readonly RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/99-ssr-dns.conf"

trap 'echo -e "\n${GREEN}已安全退出脚本。${RESET}"; exit 0' SIGINT

# 通用工具
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

ssr_state_init_if_needed() {
    state_dir_ensure "$SSR_STATE_DIR" >/dev/null 2>&1 || true
    state_dir_ensure "$DNS_BACKUP_DIR" >/dev/null 2>&1 || true
    state_migrate_file "$LEGACY_DDNS_CONF" "$DDNS_CONF" >/dev/null 2>&1 || true
    state_migrate_dir "$LEGACY_META_DIR" "$META_DIR" >/dev/null 2>&1 || true
    state_migrate_dir "$LEGACY_DNS_BACKUP_DIR" "$DNS_BACKUP_DIR" >/dev/null 2>&1 || true
}

meta_get() {
    local key="$1"
    ssr_state_init_if_needed
    state_kv_get "$META_FILE" "$key"
}

meta_set() {
    local key="$1" value="$2"
    ssr_state_init_if_needed
    state_kv_set "$META_FILE" "$key" "$value"
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
            tag=$(tr -d '[:space:]' < "$file" 2>/dev/null || true)
            [[ -n "$tag" ]] && { echo "$tag"; return 0; }
        fi
    fi
    tag=$(github_latest_tag "$repo" 2>/dev/null || true)
    tag=$(printf '%s' "$tag" | tr -d '[:space:]')
    if [[ -n "$tag" && "$tag" != "null" ]]; then
        printf '%s' "$tag" > "$file"
        echo "$tag"
        return 0
    fi
    if [[ -s "$file" ]]; then
        tag=$(tr -d '[:space:]' < "$file" 2>/dev/null || true)
        [[ -n "$tag" ]] && echo "$tag"
    fi
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

readonly XRAY_FALLBACK_TAG="v26.2.6"

xray_normalize_tag() {
    local raw="$1" tag=""
    tag=$(printf '%s' "$raw" | tr -d '
[:space:]')
    [[ -n "$tag" ]] || return 1
    [[ "$tag" =~ ^v[0-9]+(\.[0-9]+){1,3}([._-][A-Za-z0-9]+)?$ ]] || return 1
    printf '%s' "$tag"
}

xray_tag_plausible() {
    local tag="$1"
    [[ -n "$tag" ]] || return 1
    [[ "$tag" =~ ^v([0-9]+)(\.[0-9]+){1,3}([._-][A-Za-z0-9]+)?$ ]] || return 1
}

xray_linux_asset_arch() {
    local arch="${1:-$(uname -m)}"
    case "$arch" in
        x86_64|amd64) echo "64" ;;
        i386|i486|i586|i686) echo "32" ;;
        armv5tel|armv5) echo "arm32-v5" ;;
        armv6l|armv6)
            if grep -s 'Features' /proc/cpuinfo 2>/dev/null | grep -qw 'vfp'; then
                echo "arm32-v6"
            else
                echo "arm32-v5"
            fi
            ;;
        armv7|armv7l|armhf|arm)
            if grep -s 'Features' /proc/cpuinfo 2>/dev/null | grep -qw 'vfp'; then
                echo "arm32-v7a"
            else
                echo "arm32-v5"
            fi
            ;;
        armv8|aarch64|arm64) echo "arm64-v8a" ;;
        mips) echo "mips32" ;;
        mipsle) echo "mips32le" ;;
        mips64)
            if lscpu 2>/dev/null | grep -q 'Little Endian'; then
                echo "mips64le"
            else
                echo "mips64"
            fi
            ;;
        mips64le) echo "mips64le" ;;
        ppc64) echo "ppc64" ;;
        ppc64le) echo "ppc64le" ;;
        s390x) echo "s390x" ;;
        riscv64) echo "riscv64" ;;
        *) echo "64" ;;
    esac
}

xray_release_asset_name() {
    local asset_arch="$1"
    [[ -n "$asset_arch" ]] || return 1
    printf 'Xray-linux-%s.zip' "$asset_arch"
}

zip_list_entries() {
    local zipf="$1"
    [[ -s "$zipf" ]] || return 1
    if have_cmd python3; then
        python3 - "$zipf" <<'PY'
import sys, zipfile
zf = sys.argv[1]
try:
    with zipfile.ZipFile(zf, 'r') as z:
        for name in z.namelist():
            print(name)
except Exception:
    raise SystemExit(1)
PY
        return $?
    fi
    if have_cmd bsdtar; then
        bsdtar -tf "$zipf" 2>/dev/null
        return $?
    fi
    if unzip -Z1 "$zipf" >/dev/null 2>&1; then
        unzip -Z1 "$zipf" 2>/dev/null
        return $?
    fi
    unzip -l "$zipf" 2>/dev/null | awk 'NR>3 {print $4}' | sed '/^$/d;/^Name$/d;/^--------/d'
}

zip_test_valid() {
    local zipf="$1"
    [[ -s "$zipf" ]] || return 1
    if unzip -t "$zipf" >/dev/null 2>&1; then
        return 0
    fi
    if have_cmd python3; then
        python3 - "$zipf" <<'PY'
import sys, zipfile
zf = sys.argv[1]
try:
    with zipfile.ZipFile(zf, 'r') as z:
        bad = z.testzip()
        raise SystemExit(0 if bad is None else 1)
except Exception:
    raise SystemExit(1)
PY
        return $?
    fi
    if have_cmd bsdtar; then
        bsdtar -tf "$zipf" >/dev/null 2>&1
        return $?
    fi
    return 1
}

xray_zip_has_binary() {
    local zipf="$1"
    [[ -s "$zipf" ]] || return 1
    zip_list_entries "$zipf" 2>/dev/null | sed 's#^\./##; s#/*$##' | grep -Eiq '(^|/)xray$'
}

xray_zip_looks_like_html() {
    local zipf="$1"
    [[ -s "$zipf" ]] || return 1
    head -c 512 "$zipf" 2>/dev/null | tr -d '\000' | grep -Eiq '<(html|!doctype html|head|body)|<?xml'
}

xray_zip_valid() {
    local zipf="$1"
    [[ -s "$zipf" ]] || return 1
    zip_test_valid "$zipf" || return 1
    xray_zip_has_binary "$zipf"
}

file_sha256_hex() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    if have_cmd sha256sum; then
        sha256sum "$file" 2>/dev/null | awk '{print $1}'
        return 0
    fi
    if have_cmd shasum; then
        shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
        return 0
    fi
    if have_cmd openssl; then
        openssl dgst -sha256 "$file" 2>/dev/null | sed -n 's/^.*= //p'
        return 0
    fi
    return 1
}

xray_dgst_expected_sha256() {
    local dgst_file="$1" expected=""
    [[ -s "$dgst_file" ]] || return 1
    expected=$(grep -oE 'sha256:[0-9a-fA-F]{64}' "$dgst_file" | head -n1 | cut -d: -f2)
    [[ -n "$expected" ]] || expected=$(grep -oE '[0-9a-fA-F]{64}' "$dgst_file" | head -n1)
    [[ -n "$expected" ]] || return 1
    printf '%s' "${expected,,}"
}

xray_zip_matches_dgst() {
    local zipf="$1" dgst_file="$2" expected="" actual=""
    expected=$(xray_dgst_expected_sha256 "$dgst_file" 2>/dev/null || true)
    [[ -n "$expected" ]] || return 1
    actual=$(file_sha256_hex "$zipf" 2>/dev/null || true)
    [[ -n "$actual" ]] || return 1
    [[ "${actual,,}" == "$expected" ]]
}

XRAY_LAST_DOWNLOAD_URL=""
XRAY_LAST_DOWNLOAD_REASON=""
XRAY_DOWNLOAD_LOG="${TMPDIR:-/tmp}/xray-download.log"

xray_download_log_reset() {
    : > "$XRAY_DOWNLOAD_LOG" 2>/dev/null || true
}

xray_download_log_append() {
    local msg="$1"
    [[ -n "$msg" ]] || return 0
    printf '%s %s\n' "$(date '+%F %T' 2>/dev/null || echo '-')" "$msg" >> "$XRAY_DOWNLOAD_LOG" 2>/dev/null || true
}

extract_xray_from_zip() {
    local zipf="$1" outdir="$2" member=""
    [[ -s "$zipf" && -n "$outdir" ]] || return 1
    mkdir -p "$outdir" >/dev/null 2>&1 || true
    if unzip -qo "$zipf" xray -d "$outdir" >/dev/null 2>&1 && [[ -x "$outdir/xray" || -f "$outdir/xray" ]]; then
        chmod +x "$outdir/xray" 2>/dev/null || true
        return 0
    fi
    member=$(zip_list_entries "$zipf" 2>/dev/null | sed 's#^\./##; s#/*$##' | awk 'tolower($0) ~ /(^|\/)xray$/ {print; exit}')
    [[ -n "$member" ]] || return 1
    if have_cmd python3; then
        python3 - "$zipf" "$member" "$outdir/xray" <<'PY'
import os, stat, sys, zipfile
zf_path, member, out_path = sys.argv[1:4]
os.makedirs(os.path.dirname(out_path), exist_ok=True)
with zipfile.ZipFile(zf_path, 'r') as zf:
    with zf.open(member) as src, open(out_path, 'wb') as dst:
        dst.write(src.read())
os.chmod(out_path, os.stat(out_path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
PY
        return $?
    fi
    unzip -p "$zipf" "$member" > "$outdir/xray" 2>/dev/null || return 1
    chmod +x "$outdir/xray" 2>/dev/null || true
    [[ -s "$outdir/xray" ]]
}

xray_related_url() {
    local url="$1" suffix="$2"
    local base="" query=""
    [[ -n "$url" && -n "$suffix" ]] || return 1
    base="${url%%\?*}"
    if [[ "$url" == *\?* ]]; then
        query="?${url#*\?}"
    fi
    case "$base" in
        */download)
            base="${base%/download}${suffix}/download"
            ;;
        *)
            base="${base}${suffix}"
            ;;
    esac
    printf '%s%s' "$base" "$query"
}

xray_download_zip_any() {
    local dest="$1"; shift
    local u="" dgst_tmp="" dgst_url="" expected=""
    XRAY_LAST_DOWNLOAD_URL=""
    XRAY_LAST_DOWNLOAD_REASON=""
    xray_download_log_reset
    [[ -n "$dest" ]] || { XRAY_LAST_DOWNLOAD_REASON="missing destination"; xray_download_log_append "[error] missing destination"; return 1; }
    for u in "$@"; do
        [[ -n "$u" ]] || continue
        XRAY_LAST_DOWNLOAD_URL="$u"
        XRAY_LAST_DOWNLOAD_REASON="download failed"
        xray_download_log_append "[try] $u"
        rm -f "$dest" 2>/dev/null || true
        if ! download_file "$u" "$dest"; then
            xray_download_log_append "[fail] download failed"
            rm -f "$dest" 2>/dev/null || true
            continue
        fi
        XRAY_LAST_DOWNLOAD_REASON="invalid zip or xray binary missing"
        if ! xray_zip_valid "$dest"; then
            if xray_zip_looks_like_html "$dest"; then
                XRAY_LAST_DOWNLOAD_REASON="html landing page returned instead of zip"
            fi
            xray_download_log_append "[fail] $XRAY_LAST_DOWNLOAD_REASON"
            rm -f "$dest" 2>/dev/null || true
            continue
        fi
        dgst_tmp=$(mktemp /tmp/xray-dgst.XXXXXX 2>/dev/null || true)
        dgst_url=$(xray_related_url "$u" ".dgst" 2>/dev/null || true)
        if [[ -n "$dgst_tmp" && -n "$dgst_url" ]] && download_file "$dgst_url" "$dgst_tmp"; then
            expected=$(xray_dgst_expected_sha256 "$dgst_tmp" 2>/dev/null || true)
            if [[ -n "$expected" ]] && ! xray_zip_matches_dgst "$dest" "$dgst_tmp"; then
                XRAY_LAST_DOWNLOAD_REASON="sha256 mismatch"
                xray_download_log_append "[fail] $XRAY_LAST_DOWNLOAD_REASON :: $dgst_url"
                rm -f "$dgst_tmp" "$dest" 2>/dev/null || true
                continue
            fi
            [[ -n "$expected" ]] && xray_download_log_append "[ok] sha256 matched :: $dgst_url"
        else
            [[ -n "$dgst_url" ]] && xray_download_log_append "[skip] dgst unavailable :: $dgst_url"
        fi
        rm -f "$dgst_tmp" 2>/dev/null || true
        XRAY_LAST_DOWNLOAD_REASON=""
        xray_download_log_append "[ok] zip accepted"
        [[ -s "$dest" ]] && return 0
    done
    rm -f "$dest" 2>/dev/null || true
    [[ -n "$XRAY_LAST_DOWNLOAD_REASON" ]] || XRAY_LAST_DOWNLOAD_REASON="all candidate urls failed"
    xray_download_log_append "[done] all candidate urls failed"
    return 1
}
xray_remote_latest_tag() {
    local file tag=""
    file="${CORE_TAG_CACHE_DIR}/xray.tag"
    mkdir -p "$CORE_TAG_CACHE_DIR" 2>/dev/null || true
    tag=$(xray_normalize_tag "$(github_latest_release_redirect_tag "XTLS/Xray-core" 2>/dev/null || true)" 2>/dev/null || true)
    if [[ -z "$tag" ]]; then
        tag=$(xray_normalize_tag "$(github_latest_tag "XTLS/Xray-core" 2>/dev/null || true)" 2>/dev/null || true)
    fi
    if xray_tag_plausible "$tag"; then
        printf '%s' "$tag" > "$file" 2>/dev/null || true
        printf '%s' "$tag"
        return 0
    fi
    return 1
}

xray_cached_or_latest_tag() {
    local file tag=""
    file="${CORE_TAG_CACHE_DIR}/xray.tag"

    tag=$(xray_remote_latest_tag 2>/dev/null || true)
    if xray_tag_plausible "$tag"; then
        printf '%s' "$tag"
        return 0
    fi

    tag=$(xray_normalize_tag "$(xray_current_tag 2>/dev/null || true)" 2>/dev/null || true)
    if xray_tag_plausible "$tag"; then
        printf '%s' "$tag"
        return 0
    fi

    if [[ -s "$file" ]]; then
        tag=$(xray_normalize_tag "$(tr -d '[:space:]' < "$file" 2>/dev/null || true)" 2>/dev/null || true)
        if xray_tag_plausible "$tag"; then
            printf '%s' "$tag"
            return 0
        fi
        rm -f "$file" 2>/dev/null || true
    fi

    tag=$(xray_normalize_tag "$(meta_get "XRAY_TAG" 2>/dev/null || true)" 2>/dev/null || true)
    if xray_tag_plausible "$tag"; then
        printf '%s' "$tag"
        return 0
    fi

    printf '%s' "$XRAY_FALLBACK_TAG"
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

make_runtime_backup() {
    local src="$1" bak
    [[ -e "$src" ]] || return 1
    bak=$(mktemp "/tmp/$(basename "$src").XXXXXX") || return 1
    cp -a "$src" "$bak" 2>/dev/null || { rm -f "$bak"; return 1; }
    echo "$bak"
}

restore_file_if_present() {
    local bak="$1"; local dst="$2"
    [[ -f "$bak" ]] || return 0
    cp -a "$bak" "$dst" 2>/dev/null || true
}

restore_file_strict() {
    local bak="$1"; local dst="$2"
    [[ -f "$bak" ]] || return 1
    cp -a "$bak" "$dst" 2>/dev/null || return 1
}

restore_or_remove_file() {
    local bak="$1"; local dst="$2"
    if [[ -n "$bak" && -e "$bak" ]]; then
        cp -a "$bak" "$dst" 2>/dev/null || return 1
    else
        rm -f "$dst" 2>/dev/null || true
    fi
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
    local pass_mode="$1" kb_mode="$2" challenge_mode="$3" root_mode="${4:-prohibit-password}"
    ensure_sshd_dropin_include || true
    mkdir -p "$(dirname "$SSH_AUTH_DROPIN")" 2>/dev/null || true
    cat > "$SSH_AUTH_DROPIN" <<EOF
# managed by my
PasswordAuthentication ${pass_mode}
KbdInteractiveAuthentication ${kb_mode}
ChallengeResponseAuthentication ${challenge_mode}
PubkeyAuthentication yes
PermitRootLogin ${root_mode}
UsePAM yes
EOF
}

remove_ssh_auth_dropin() {
    rm -f "$SSH_AUTH_DROPIN" 2>/dev/null || true
}

ensure_sshd_dropin_include() {
    local cfg="/etc/ssh/sshd_config" tmp
    [[ -f "$cfg" ]] || return 1
    grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf([[:space:]]|$)' "$cfg" 2>/dev/null && return 0
    tmp=$(mktemp /tmp/sshd_config.include.XXXXXX) || return 1
    {
        printf '%s
' 'Include /etc/ssh/sshd_config.d/*.conf'
        cat "$cfg"
    } > "$tmp"
    cat "$tmp" > "$cfg" && rm -f "$tmp"
}

write_ssh_port_dropin() {
    local port="$1"
    ensure_sshd_dropin_include || true
    mkdir -p "$(dirname "$SSH_PORT_DROPIN")" 2>/dev/null || true
    cat > "$SSH_PORT_DROPIN" <<EOF
# managed by my
Port ${port}
EOF
}

remove_ssh_port_dropin() {
    rm -f "$SSH_PORT_DROPIN" 2>/dev/null || true
}

sshd_effective_port() {
    local port
    port=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')
    [[ "$port" =~ ^[0-9]+$ ]] || port=$(get_sshd_effective_value Port 2>/dev/null || true)
    [[ "$port" =~ ^[0-9]+$ ]] || port=22
    printf %s "$port"
}

sshd_runtime_dump() {
    have_cmd sshd || return 1
    sshd -T -C user=root -C host=localhost -C addr=127.0.0.1 2>/dev/null && return 0
    sshd -T 2>/dev/null && return 0
    return 1
}

sshd_effective_value_runtime() {
    local key="$1"
    sshd_runtime_dump 2>/dev/null | awk -v k="$key" '$1==tolower(k) { $1=""; sub(/^[[:space:]]+/, ""); print; exit }'
}

normalize_ssh_root_login_mode() {
    local mode="$1"
    mode=$(printf %s "$mode" | tr '[:upper:]' '[:lower:]')
    case "$mode" in
        prohibit-password|without-password) printf %s "prohibit-password" ;;
        forced-commands-only) printf %s "forced-commands-only" ;;
        yes|no) printf %s "$mode" ;;
        *) printf %s "$mode" ;;
    esac
}

port_listening_tcp() {
    local port="$1"
    if have_cmd ss; then
        ss -lnt "( sport = :${port} )" 2>/dev/null | tail -n +2 | grep -q . && return 0
    fi
    if have_cmd netstat; then
        netstat -lnt 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {found=1} END{exit !found}' && return 0
    fi
    if have_cmd lsof; then
        lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | tail -n +2 | grep -q . && return 0
    fi
    return 1
}

ensure_root_authorized_keys() {
    mkdir -p "$ROOT_SSH_DIR" 2>/dev/null || return 1
    chmod 700 "$ROOT_SSH_DIR" 2>/dev/null || true
    touch "$ROOT_AUTH_KEYS_FILE" 2>/dev/null || return 1
    chmod 600 "$ROOT_AUTH_KEYS_FILE" 2>/dev/null || true
    return 0
}

verify_ssh_runtime() {
    local expected_port="$1" expected_pass="$2" expected_root="$3"
    local got_port got_pass got_root got_pub ok="0" i
    have_cmd sshd || return 1
    sshd -t >/dev/null 2>&1 || return 1
    expected_root=$(normalize_ssh_root_login_mode "$expected_root")
    for i in 1 2 3 4 5; do
        got_port=$(sshd_effective_port)
        got_pass=$(sshd_effective_value_runtime passwordauthentication | tr '[:upper:]' '[:lower:]')
        got_pub=$(sshd_effective_value_runtime pubkeyauthentication | tr '[:upper:]' '[:lower:]')
        got_root=$(normalize_ssh_root_login_mode "$(sshd_effective_value_runtime permitrootlogin)")
        [[ -z "$got_pass" ]] && got_pass="yes"
        [[ -z "$got_pub" ]] && got_pub="yes"
        if [[ "$got_port" == "$expected_port" ]]            && [[ -z "$expected_pass" || "$got_pass" == "$expected_pass" ]]            && [[ "$got_pub" == "yes" ]]            && [[ -z "$expected_root" || "$got_root" == "$expected_root" ]]            && port_listening_tcp "$expected_port"; then
            ok="1"
            break
        fi
        sleep 1
    done
    [[ "$ok" == "1" ]]
}

service_use_systemd() {
    have_cmd systemctl && [[ -d /run/systemd/system ]]
}

ssh_service_name() {
    if service_use_systemd; then
        if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^sshd\.service'; then
            echo sshd
            return 0
        fi
        if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^ssh\.service'; then
            echo ssh
            return 0
        fi
    fi
    echo sshd
}

restart_ssh_safe() {
    local cfg="/etc/ssh/sshd_config" svc
    if have_cmd sshd && ! sshd -t -f "$cfg" >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ sshd_config 校验失败，未重启 SSH。${RESET}"
        return 1
    fi
    if service_use_systemd; then
        svc="$(ssh_service_name)"
        systemctl restart "$svc" >/dev/null 2>&1 || return 1
        systemctl is-active --quiet "$svc" >/dev/null 2>&1 || return 1
        return 0
    fi
    if have_cmd service; then
        service ssh restart >/dev/null 2>&1 || service sshd restart >/dev/null 2>&1 || return 1
        return 0
    fi
    return 1
}

ssh_takeover_socket_activation() {
    local svc=""
    have_cmd systemctl || return 0

    if systemctl list-unit-files --type=socket 2>/dev/null | grep -q '^ssh\.socket'; then
        if systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
            systemctl disable --now ssh.socket >/dev/null 2>&1 || true
        fi
    fi

    if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^ssh\.service'; then
        svc="ssh"
    elif systemctl list-unit-files --type=service 2>/dev/null | grep -q '^sshd\.service'; then
        svc="sshd"
    fi

    if [[ -n "$svc" ]]; then
        systemctl enable "$svc" >/dev/null 2>&1 || true
        systemctl start "$svc" >/dev/null 2>&1 || true
    fi
    return 0
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
    printf '%s' "$1" | tr '\r' '\n' | awk '
        {
            gsub(/Private[[:space:]]*[Kk]ey[[:space:]]*:/, "\nPrivateKey:")
            gsub(/Public[[:space:]]*[Kk]ey[[:space:]]*:/, "\nPublicKey:")
            gsub(/Password[[:space:]]*:/, "\nPassword:")
            gsub(/Hash32[[:space:]]*:/, "\nHash32:")
            print
        }
    ' | tr -s '\n' | sed '/^[[:space:]]*$/d'
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

json_set_path() {
    local file="$1" path="$2" value="$3" kind="$4"
    [[ -f "$file" ]] || return 1
    if have_cmd python3; then
        python3 - "$file" "$path" "$value" "$kind" <<'PYPARSE'
import json, os, sys
file, path, value, kind = sys.argv[1:5]

def convert(v, k):
    if k == 'number':
        return int(v)
    if k == 'bool':
        return str(v).strip().lower() in ('1', 'true', 'yes', 'on')
    if k == 'null':
        return None
    return v

with open(file, 'r', encoding='utf-8') as f:
    obj = json.load(f)
cur = obj
parts = path.split('.')
for part in parts[:-1]:
    cur = cur[int(part)] if part.isdigit() else cur[part]
last = parts[-1]
cur[int(last) if last.isdigit() else last] = convert(value, kind)
tmp = file + '.tmp'
with open(tmp, 'w', encoding='utf-8') as f:
    json.dump(obj, f, ensure_ascii=False)
os.replace(tmp, file)
PYPARSE
        return $?
    fi
    if have_cmd jq; then
        local tmp
        tmp=$(mktemp /tmp/json-set.XXXXXX) || return 1
        if jq --arg path "$path" --arg val "$value" --arg kind "$kind" '
            def conv($v; $k):
                if $k == "number" then ($v | tonumber)
                elif $k == "bool" then (($v | ascii_downcase) | test("^(true|1|yes|on)$"))
                elif $k == "null" then null
                else $v end;
            ($path | split(".") | map(if test("^[0-9]+$") then tonumber else . end)) as $p
            | setpath($p; conv($val; $kind))
        ' "$file" > "$tmp" 2>/dev/null; then
            mv -f "$tmp" "$file" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
            return 0
        fi
        rm -f "$tmp"
    fi
    return 1
}

json_set_top_value() {
    json_set_path "$1" "$2" "$3" "$4"
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
    [[ -n "$link" ]] && echo -e "${YELLOW}链接:${RESET}
${link}"
}

plugin_state_get() {
    local file="$1" key="$2"
    ssr_state_init_if_needed
    state_kv_get "$file" "$key"
}

plugin_state_write() {
    local file="$1"; shift
    ssr_state_init_if_needed
    state_write_pairs "$file" "$@"
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
        local asset_name official_url api_url proxy_url
        asset_name="shadowsocks-${ss_latest}.${candidate_arch}.tar.xz"
        official_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${ss_latest}/${asset_name}"
        api_url=$(github_release_asset_url "shadowsocks/shadowsocks-rust" "$ss_latest" "$asset_name" 2>/dev/null || true)
        proxy_url=$(github_proxy_wrap "$official_url")
        rm -f "$tarball" "${tmpdir}/ssserver" >/dev/null 2>&1 || true
        if ! download_file_any "$tarball" "$api_url" "$official_url" "$proxy_url" || [[ ! -s "$tarball" ]] || ! tar -tf "$tarball" >/dev/null 2>&1; then
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
    [[ -n "$link" ]] && echo -e "${YELLOW}链接:${RESET}
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

service_unit_exists() {
    local name="$1"
    service_use_systemd || return 1
    systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${name}\.service"
}

service_is_running() {
    local name="$1" bg_match="$2" pid_file="$3"
    if service_use_systemd; then
        systemctl is-active --quiet "$name" 2>/dev/null
        return $?
    fi
    if [[ -s "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && return 0
    fi
    [[ -n "$bg_match" ]] && pgrep -f "$bg_match" >/dev/null 2>&1
}

managed_service_present() {
    local name="$1" bg_match="$2" pid_file="$3"
    service_unit_exists "$name" && return 0
    [[ -f "$pid_file" ]] && return 0
    [[ -n "$bg_match" ]] && pgrep -f "$bg_match" >/dev/null 2>&1
}

start_managed_service() {
    local name="$1" unit_content="$2" bg_cmd="$3" bg_match="$4" log_file="$5" pid_file="$6"
    if service_use_systemd; then
        mkdir -p /etc/systemd/system 2>/dev/null || true
        printf '%s\n' "$unit_content" > "/etc/systemd/system/${name}.service"
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable --now "$name" >/dev/null 2>&1 || return 1
        sleep 1
        service_is_running "$name" "$bg_match" "$pid_file" || return 1
    else
        [[ -n "$bg_match" ]] && pkill -f "$bg_match" 2>/dev/null || true
        mkdir -p "$(dirname "$pid_file")" 2>/dev/null || true
        nohup sh -c "$bg_cmd" >"$log_file" 2>&1 &
        echo $! > "$pid_file"
        sleep 1
        service_is_running "$name" "$bg_match" "$pid_file" || return 1
    fi
}

restart_managed_service() {
    local name="$1" bg_cmd="$2" bg_match="$3" log_file="$4" pid_file="$5"
    if service_use_systemd; then
        systemctl restart "$name" >/dev/null 2>&1 || return 1
        sleep 1
        service_is_running "$name" "$bg_match" "$pid_file" || return 1
    else
        [[ -n "$bg_match" ]] && pkill -f "$bg_match" 2>/dev/null || true
        mkdir -p "$(dirname "$pid_file")" 2>/dev/null || true
        nohup sh -c "$bg_cmd" >"$log_file" 2>&1 &
        echo $! > "$pid_file"
        sleep 1
        service_is_running "$name" "$bg_match" "$pid_file" || return 1
    fi
}

controlled_restart_service() {
    local name="$1" bg_cmd="$2" bg_match="$3" log_file="$4" pid_file="$5"
    restart_managed_service "$name" "$bg_cmd" "$bg_match" "$log_file" "$pid_file"
}

# The script now uses a temporary front-layer redirect plus standby instance
# during binary upgrades. This alias remains for compatibility with older call
# sites and still performs a verified restart for non-upgrade paths.
smooth_handoff_service() {
    local name="$1" bg_cmd="$2" bg_match="$3" log_file="$4" pid_file="$5"
    controlled_restart_service "$name" "$bg_cmd" "$bg_match" "$log_file" "$pid_file"
}

frontlayer_engine() {
    if have_cmd nft; then
        printf %s nft
        return 0
    fi
    if have_cmd iptables; then
        printf %s iptables
        return 0
    fi
    return 1
}

frontlayer_chain_token() {
    case "$1" in
        ss-rust) printf %s SSRH ;;
        ss-v2ray) printf %s SSV2 ;;
        xray) printf %s XRAY ;;
        *) printf %s HOTX ;;
    esac
}

nft_frontlayer_comment() {
    local name="$1" proto="$2" public_port="$3"
    printf 'ssr-hot:%s:%s:%s' "$name" "$proto" "$public_port"
}

nft_frontlayer_ensure() {
    nft list table inet ssr_hot >/dev/null 2>&1 || nft add table inet ssr_hot >/dev/null 2>&1 || return 1
    nft list chain inet ssr_hot prerouting >/dev/null 2>&1 || nft 'add chain inet ssr_hot prerouting { type nat hook prerouting priority -105; policy accept; }' >/dev/null 2>&1 || return 1
    return 0
}

nft_frontlayer_delete_proto() {
    local name="$1" proto="$2" public_port="$3" comment handle
    comment=$(nft_frontlayer_comment "$name" "$proto" "$public_port")
    while read -r handle; do
        [[ "$handle" =~ ^[0-9]+$ ]] || continue
        nft delete rule inet ssr_hot prerouting handle "$handle" >/dev/null 2>&1 || true
    done < <(nft -a list chain inet ssr_hot prerouting 2>/dev/null | awk -v c="$comment" '$0 ~ "comment \"" c "\"" {for (i=1;i<=NF;i++) if ($i=="handle") print $(i+1)}')
}

nft_frontlayer_upsert() {
    local name="$1" public_port="$2" standby_port="$3" proto="$4"
    local comment
    comment=$(nft_frontlayer_comment "$name" "$proto" "$public_port")
    nft_frontlayer_ensure || return 1
    nft_frontlayer_delete_proto "$name" "$proto" "$public_port"
    nft add rule inet ssr_hot prerouting "$proto" dport "$public_port" redirect to :"$standby_port" comment "$comment" >/dev/null 2>&1
}

nft_frontlayer_remove() {
    local name="$1" public_port="$2" proto="$3"
    nft_frontlayer_ensure || return 1
    nft_frontlayer_delete_proto "$name" "$proto" "$public_port"
}

iptables_frontlayer_chain() {
    local name="$1" proto="$2"
    printf '%s_%s' "$(frontlayer_chain_token "$name")" "${proto^^}"
}

iptables_frontlayer_upsert_proto() {
    local cmd="$1" name="$2" public_port="$3" standby_port="$4" proto="$5"
    local chain
    chain=$(iptables_frontlayer_chain "$name" "$proto")
    "$cmd" -t nat -N "$chain" >/dev/null 2>&1 || true
    "$cmd" -t nat -C PREROUTING -p "$proto" --dport "$public_port" -j "$chain" >/dev/null 2>&1 || \
        "$cmd" -t nat -I PREROUTING -p "$proto" --dport "$public_port" -j "$chain" >/dev/null 2>&1 || return 1
    "$cmd" -t nat -F "$chain" >/dev/null 2>&1 || return 1
    "$cmd" -t nat -A "$chain" -j REDIRECT --to-ports "$standby_port" >/dev/null 2>&1
}

iptables_frontlayer_remove_proto() {
    local cmd="$1" name="$2" public_port="$3" proto="$4"
    local chain
    chain=$(iptables_frontlayer_chain "$name" "$proto")
    while "$cmd" -t nat -C PREROUTING -p "$proto" --dport "$public_port" -j "$chain" >/dev/null 2>&1; do
        "$cmd" -t nat -D PREROUTING -p "$proto" --dport "$public_port" -j "$chain" >/dev/null 2>&1 || break
    done
    "$cmd" -t nat -F "$chain" >/dev/null 2>&1 || true
    "$cmd" -t nat -X "$chain" >/dev/null 2>&1 || true
}

frontlayer_redirect_upsert() {
    local name="$1" public_port="$2" standby_port="$3" proto="$4" engine p
    engine=$(frontlayer_engine) || return 1
    proto=$(normalize_proto "$proto")
    case "$engine" in
        nft)
            for p in $(proto_to_list "$proto"); do
                nft_frontlayer_upsert "$name" "$public_port" "$standby_port" "$p" || return 1
            done
            ;;
        iptables)
            for p in $(proto_to_list "$proto"); do
                iptables_frontlayer_upsert_proto iptables "$name" "$public_port" "$standby_port" "$p" || return 1
                if have_cmd ip6tables; then
                    iptables_frontlayer_upsert_proto ip6tables "$name" "$public_port" "$standby_port" "$p" || true
                fi
            done
            ;;
        *) return 1 ;;
    esac
}

frontlayer_redirect_remove() {
    local name="$1" public_port="$2" proto="$3" engine p
    engine=$(frontlayer_engine) || return 1
    proto=$(normalize_proto "$proto")
    case "$engine" in
        nft)
            for p in $(proto_to_list "$proto"); do
                nft_frontlayer_remove "$name" "$public_port" "$p" || true
            done
            ;;
        iptables)
            for p in $(proto_to_list "$proto"); do
                iptables_frontlayer_remove_proto iptables "$name" "$public_port" "$p" || true
                if have_cmd ip6tables; then
                    iptables_frontlayer_remove_proto ip6tables "$name" "$public_port" "$p" || true
                fi
            done
            ;;
        *) return 1 ;;
    esac
}

managed_service_validate_with_binary() {
    local name="$1" bin_path="$2" cfg="$3" rc
    case "$name" in
        ss-rust|ss-v2ray)
            run_with_timeout 2 "$bin_path" -c "$cfg" >/dev/null 2>&1
            rc=$?
            [[ "$rc" -eq 0 || "$rc" -eq 124 || "$rc" -eq 137 ]]
            ;;
        xray)
            "$bin_path" run -test -c "$cfg" >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

managed_service_launch_temp() {
    local name="$1" bin_path="$2" cfg="$3" log_file="$4" pid_file="$5"
    mkdir -p "$(dirname "$log_file")" "$(dirname "$pid_file")" >/dev/null 2>&1 || true
    case "$name" in
        ss-rust|ss-v2ray)
            nohup "$bin_path" -c "$cfg" >"$log_file" 2>&1 &
            ;;
        xray)
            nohup "$bin_path" run -c "$cfg" >"$log_file" 2>&1 &
            ;;
        *) return 1 ;;
    esac
    echo $! > "$pid_file"
}

managed_service_stop_temp() {
    local pid_file="$1"
    if [[ -s "$pid_file" ]]; then
        kill "$(cat "$pid_file" 2>/dev/null)" >/dev/null 2>&1 || true
        sleep 1
        kill -9 "$(cat "$pid_file" 2>/dev/null)" >/dev/null 2>&1 || true
    fi
    rm -f "$pid_file" >/dev/null 2>&1 || true
}

is_listening_port() {
    local port="$1" proto="$2" ok=0
    proto=$(normalize_proto "$proto")
    if have_cmd ss; then
        if [[ "$proto" == "tcp" || "$proto" == "both" ]]; then
            ss -lntH 2>/dev/null | awk '{print $4}' | awk -F: '{print $NF}' | grep -qx "$port" || return 1
        fi
        if [[ "$proto" == "udp" || "$proto" == "both" ]]; then
            ss -lnuH 2>/dev/null | awk '{print $4}' | awk -F: '{print $NF}' | grep -qx "$port" || return 1
        fi
        return 0
    fi
    return 1
}

wait_port_listening() {
    local port="$1" proto="$2" timeout="${3:-15}" i=0
    while (( i < timeout )); do
        is_listening_port "$port" "$proto" && return 0
        sleep 1
        i=$((i+1))
    done
    return 1
}

pick_handoff_port() {
    local public_port="$1" proto="$2" try=0 cand
    while (( try < 256 )); do
        cand=$(( RANDOM % 20000 + 40000 ))
        if [[ "$cand" == "$public_port" ]]; then
            try=$((try+1))
            continue
        fi
        if port_in_use "$cand" "$proto"; then
            try=$((try+1))
            continue
        fi
        printf %s "$cand"
        return 0
    done
    return 1
}

active_tcp_conn_count() {
    local port="$1"
    if have_cmd ss; then
        ss -Htan state established 2>/dev/null | awk -v p=":${port}" '$4 ~ (p "$") {c++} END {print c+0}'
        return 0
    fi
    printf %s 0
}

wait_backend_drain() {
    local port="$1" proto="$2"
    local tcp_timeout="${HOT_TCP_DRAIN_TIMEOUT:-120}" udp_grace="${HOT_UDP_DRAIN_GRACE:-45}"
    local elapsed=0 current=0
    proto=$(normalize_proto "$proto")
    if [[ "$proto" == "tcp" || "$proto" == "both" ]]; then
        while (( elapsed < tcp_timeout )); do
            current=$(active_tcp_conn_count "$port")
            [[ "$current" =~ ^[0-9]+$ ]] || current=0
            (( current == 0 )) && break
            sleep 1
            elapsed=$((elapsed+1))
        done
    fi
    if [[ "$proto" == "udp" || "$proto" == "both" ]]; then
        sleep "$udp_grace"
    fi
}

hot_handoff_named_service() {
    local name="$1" bin_path="$2"
    local cfg port_path public_port proto match pid_file log_file
    local standby_port temp_cfg temp_pid temp_log

    cfg=$(managed_service_config_path "$name") || return 1
    port_path=$(managed_service_port_json_path "$name") || return 1
    proto=$(managed_service_proto "$name") || return 1
    match=$(managed_service_match "$name") || return 1
    pid_file=$(managed_service_pid "$name") || return 1
    log_file=$(managed_service_log "$name") || return 1
    [[ -f "$cfg" && -x "$bin_path" ]] || return 1
    public_port=$(json_get_path "$cfg" "$port_path" 2>/dev/null || true)
    [[ "$public_port" =~ ^[0-9]+$ ]] || return 1

    if ! service_is_running "$name" "$match" "$pid_file"; then
        start_named_service "$name" >/dev/null 2>&1 || restart_named_service "$name" >/dev/null 2>&1
        return $?
    fi

    standby_port=$(pick_handoff_port "$public_port" "$proto") || return 1
    temp_cfg=$(mktemp "/tmp/${name}.handoff.XXXXXX.json") || return 1
    temp_pid=$(mktemp "/tmp/${name}.handoff.XXXXXX.pid") || { rm -f "$temp_cfg"; return 1; }
    temp_log="/var/log/${name}.handoff.${standby_port}.log"
    cp -a "$cfg" "$temp_cfg" 2>/dev/null || { rm -f "$temp_cfg" "$temp_pid" "$temp_log"; return 1; }
    json_set_path "$temp_cfg" "$port_path" "$standby_port" number || { rm -f "$temp_cfg" "$temp_pid" "$temp_log"; return 1; }
    managed_service_validate_with_binary "$name" "$bin_path" "$temp_cfg" || { rm -f "$temp_cfg" "$temp_pid" "$temp_log"; return 1; }
    managed_service_launch_temp "$name" "$bin_path" "$temp_cfg" "$temp_log" "$temp_pid" || { rm -f "$temp_cfg" "$temp_pid" "$temp_log"; return 1; }
    wait_port_listening "$standby_port" "$proto" 15 || {
        managed_service_stop_temp "$temp_pid"
        rm -f "$temp_cfg" "$temp_pid" "$temp_log"
        return 1
    }

    add_firewall_rule "$standby_port" "$proto" >/dev/null 2>&1 || true
    if ! frontlayer_redirect_upsert "$name" "$public_port" "$standby_port" "$proto"; then
        managed_service_stop_temp "$temp_pid"
        remove_firewall_rule "$standby_port" "$proto" >/dev/null 2>&1 || true
        rm -f "$temp_cfg" "$temp_pid" "$temp_log"
        return 1
    fi

    wait_backend_drain "$public_port" "$proto"
    stop_named_service "$name" >/dev/null 2>&1 || true
    [[ -n "$match" ]] && pkill -f "$match" >/dev/null 2>&1 || true
    rm -f "$pid_file" >/dev/null 2>&1 || true
    sleep 1

    if ! start_named_service "$name" >/dev/null 2>&1; then
        frontlayer_redirect_remove "$name" "$public_port" "$proto" >/dev/null 2>&1 || true
        managed_service_stop_temp "$temp_pid"
        remove_firewall_rule "$standby_port" "$proto" >/dev/null 2>&1 || true
        rm -f "$temp_cfg" "$temp_pid" "$temp_log"
        return 1
    fi

    frontlayer_redirect_remove "$name" "$public_port" "$proto" >/dev/null 2>&1 || true
    wait_backend_drain "$standby_port" "$proto"
    managed_service_stop_temp "$temp_pid"
    remove_firewall_rule "$standby_port" "$proto" >/dev/null 2>&1 || true
    rm -f "$temp_cfg" "$temp_pid" "$temp_log"
    return 0
}

activate_binary_with_rollback() {
    local component="$1" tag="$2" candidate="$3" dest="$4" meta_key="$5"
    local name="$6" bg_cmd="$7" bg_match="$8" log_file="$9" pid_file="${10}"
    local backup="" svc rc applied_any=0
    local -a targets=() switched=()
    [[ -x "$candidate" ]] || return 2

    case "$component" in
        ss-rust) targets=(ss-rust ss-v2ray) ;;
        xray) targets=(xray) ;;
        *) [[ -n "$name" ]] && targets=("$name") ;;
    esac

    if [[ -x "$dest" ]]; then
        backup=$(mktemp "/tmp/${component:-bin}.rollback.XXXXXX") || return 2
        cp -a "$dest" "$backup" 2>/dev/null || { rm -f "$backup"; return 2; }
    fi

    safe_install_binary "$candidate" "$dest" || { rm -f "$backup"; return 2; }

    for svc in "${targets[@]}"; do
        managed_service_exists "$svc" || continue
        if hot_handoff_named_service "$svc" "$dest"; then
            switched+=("$svc")
            applied_any=1
            continue
        fi
        if [[ -n "$backup" && -s "$backup" ]]; then
            safe_install_binary "$backup" "$dest" >/dev/null 2>&1 || true
            for (( rc=${#switched[@]}-1; rc>=0; rc-- )); do
                hot_handoff_named_service "${switched[$rc]}" "$dest" >/dev/null 2>&1 || start_named_service "${switched[$rc]}" >/dev/null 2>&1 || true
            done
            managed_service_exists "$svc" && start_named_service "$svc" >/dev/null 2>&1 || true
        fi
        rm -f "$backup"
        return 2
    done

    if (( applied_any == 0 )) && managed_service_present "$name" "$bg_match" "$pid_file"; then
        if ! controlled_restart_service "$name" "$bg_cmd" "$bg_match" "$log_file" "$pid_file"; then
            if [[ -n "$backup" && -s "$backup" ]]; then
                safe_install_binary "$backup" "$dest" >/dev/null 2>&1 || true
                controlled_restart_service "$name" "$bg_cmd" "$bg_match" "$log_file" "$pid_file" >/dev/null 2>&1 || true
            fi
            rm -f "$backup"
            return 2
        fi
    fi

    [[ -n "$component" && -n "$tag" ]] && cache_store_binary "$component" "$tag" "$dest" >/dev/null 2>&1 || true
    [[ -n "$meta_key" && -n "$tag" ]] && meta_set "$meta_key" "$tag"
    rm -f "$backup"
    return 0
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

system_nofile_hard() {
    local n
    n="$(sh -c 'ulimit -Hn' 2>/dev/null || true)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=65535
    echo "$n"
}

tier_step_up() {
    case "$1" in
        tiny) echo small ;;
        small) echo medium ;;
        medium) echo large ;;
        *) echo large ;;
    esac
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
    local mem cpu nofile tier
    mem="$(system_memory_mb)"
    cpu="$(system_cpu_count)"
    nofile="$(system_nofile_hard)"
    [[ "$mem" =~ ^[0-9]+$ ]] || mem=1024
    [[ "$cpu" =~ ^[0-9]+$ ]] || cpu=1
    [[ "$nofile" =~ ^[0-9]+$ ]] || nofile=65535

    if (( mem < 1024 || cpu <= 1 )); then
        tier=tiny
    elif (( mem < 4096 || cpu <= 2 )); then
        tier=small
    elif (( mem < 8192 || cpu <= 4 )); then
        tier=medium
    else
        tier=large
    fi

    if (( nofile >= 1048576 && mem >= 4096 && cpu >= 4 )); then
        tier="$(tier_step_up "$tier")"
    fi

    echo "$tier"
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

cc_available_list() {
    sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true
}

cc_in_list() {
    local cc="$1" avail="${2:-$(cc_available_list)}"
    [[ " $avail " == *" ${cc} "* ]]
}

try_activate_bbr_stack() {
    modprobe -q sch_fq >/dev/null 2>&1 || true
    modprobe -q tcp_bbr >/dev/null 2>&1 || true
}

best_congestion_control() {
    local avail current
    avail="$(cc_available_list)"
    if cc_in_list bbr "$avail"; then
        echo bbr
        return 0
    fi

    try_activate_bbr_stack
    avail="$(cc_available_list)"
    if cc_in_list bbr "$avail"; then
        echo bbr
        return 0
    fi

    for cc in cubic reno; do
        cc_in_list "$cc" "$avail" && { echo "$cc"; return 0; }
    done

    current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    [[ -n "$current" ]] && echo "$current" || echo cubic
}

best_default_qdisc() {
    local cc="${1:-$(best_congestion_control)}" current_qdisc
    if [[ "$cc" == "bbr" ]]; then
        modprobe -q sch_fq >/dev/null 2>&1 || true
        echo fq
        return 0
    fi
    current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    [[ -n "$current_qdisc" ]] && echo "$current_qdisc" || echo fq_codel
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
    local target="$1" env="$2" mode="$(profile_alias "$3")" tier="${4:-medium}" cc qdisc
    local rmax wmax rmem wmem somax backlog filemax fin_timeout keepalive_time keepalive_intvl keepalive_probes
    cc="$(best_congestion_control)"
    qdisc="$(best_default_qdisc "$cc")"
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
net.core.default_qdisc = ${qdisc}
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
    # download_file URL DEST
    local url="$1"; local dest="$2"
    local curl_supports_retry_all=0
    rm -f "$dest"
    [[ -n "$url" && -n "$dest" ]] || return 1
    if have_cmd curl; then
        curl --help all 2>/dev/null | grep -q -- '--retry-all-errors' && curl_supports_retry_all=1 || true
        if [[ $curl_supports_retry_all -eq 1 ]]; then
            curl -A 'Mozilla/5.0' --http1.1 -fL --retry 3 --retry-delay 1 --retry-all-errors --connect-timeout 8 --max-time 300 "$url" -o "$dest" >/dev/null 2>&1
        else
            curl -A 'Mozilla/5.0' --http1.1 -fL --retry 3 --retry-delay 1 --connect-timeout 8 --max-time 300 "$url" -o "$dest" >/dev/null 2>&1
        fi
    elif have_cmd wget; then
        wget --user-agent='Mozilla/5.0' --tries=3 --waitretry=1 --timeout=30 --read-timeout=300 -qO "$dest" "$url" >/dev/null 2>&1
    else
        return 1
    fi
}

fetch_text_url() {
    local url="$1"
    [[ -n "$url" ]] || return 1
    if have_cmd curl; then
        curl -A 'Mozilla/5.0' -fsSL --connect-timeout 8 --max-time 20 "$url" 2>/dev/null && return 0
    fi
    if have_cmd wget; then
        wget --user-agent='Mozilla/5.0' -qO- "$url" 2>/dev/null && return 0
    fi
    return 1
}

fetch_github_user_keys() {
    local gh_user="$1" body="" keys=""
    [[ -n "$gh_user" ]] || return 1
    body=$(fetch_text_url "https://github.com/${gh_user}.keys" || true)
    if [[ -n "$body" && "$body" != "Not Found" ]]; then
        printf '%s\n' "$body" | sed 's/\r$//' | sed '/^[[:space:]]*$/d'
        return 0
    fi
    body=$(fetch_text_url "https://api.github.com/users/${gh_user}/keys" || true)
    [[ -n "$body" ]] || return 1
    if have_cmd jq; then
        keys=$(printf '%s' "$body" | jq -r '.[].key // empty' 2>/dev/null)
    elif have_cmd python3; then
        keys=$(python3 - <<'PYKEYS' "$body" 2>/dev/null || true
import json, sys
body = sys.argv[1]
try:
    data = json.loads(body)
    for item in data if isinstance(data, list) else []:
        key = item.get("key")
        if key:
            print(key)
except Exception:
    pass
PYKEYS
)
    fi
    [[ -n "$keys" ]] || return 1
    printf '%s\n' "$keys" | sed 's/\r$//' | sed '/^[[:space:]]*$/d'
}

github_proxy_wrap() {
    local url="$1"
    [[ -n "$url" ]] || return 1
    case "$url" in
        https://*|http://*) printf '%s
' "https://ghproxy.net/${url}" ;;
        *) printf '%s
' "$url" ;;
    esac
}

github_proxy_candidate_urls() {
    local url="$1" base="" extra_prefixes=""
    [[ -n "$url" ]] || return 1
    printf '%s\n' "$url"
    case "$url" in
        https://github.com/*|http://github.com/*)
            extra_prefixes=$(printf '%s\n' "${GITHUB_PROXY_PREFIXES:-}" | tr ',\r' '  ')
            for base in $extra_prefixes \
                "https://ghproxy.net/" \
                "https://gh-proxy.com/" \
                "https://mirror.ghproxy.com/"
            do
                [[ -n "$base" ]] || continue
                [[ "$base" == */ ]] || base="${base}/"
                printf '%s%s\n' "$base" "$url"
            done
            ;;
    esac
}

xray_sourceforge_candidate_urls() {
    local tag="$1" asset_name="$2"
    local project="xray-core.mirror"
    local rel_path="${tag}/${asset_name}"
    local mirror=""
    [[ -n "$tag" && -n "$asset_name" ]] || return 1
    printf '%s
' "https://sourceforge.net/projects/${project}/files/${rel_path}/download"
    for mirror in twds zenlayer phoenixnap pilotfiber psychz cfhcable onboardcloud yer sitsa netactuate gigenet cytranet netix altushost excellmedia ixaustralia unlimited; do
        printf '%s
' "https://sourceforge.net/projects/${project}/files/${rel_path}/download?use_mirror=${mirror}"
    done
    for mirror in master twds zenlayer phoenixnap pilotfiber psychz cfhcable onboardcloud yer sitsa netactuate gigenet cytranet netix altushost excellmedia ixaustralia unlimited; do
        printf '%s
' "https://${mirror}.dl.sourceforge.net/project/${project}/${rel_path}?viasf=1"
    done
}

xray_download_candidate_urls() {
    local preferred_tag="$1" asset_name="$2" fallback_tag="$3"
    local api_url="" official_url="" latest_url="" fallback_url="" manual_url=""
    [[ -n "$asset_name" ]] || return 1
    manual_url=$(printf '%s' "${XRAY_DOWNLOAD_URL:-}" | tr -d '\r[:space:]')
    latest_url="https://github.com/XTLS/Xray-core/releases/latest/download/${asset_name}"
    if [[ -n "$preferred_tag" ]]; then
        official_url="https://github.com/XTLS/Xray-core/releases/download/${preferred_tag}/${asset_name}"
        api_url=$(github_release_asset_url "XTLS/Xray-core" "$preferred_tag" "$asset_name" 2>/dev/null || true)
    fi
    if [[ -n "$fallback_tag" ]]; then
        fallback_url="https://github.com/XTLS/Xray-core/releases/download/${fallback_tag}/${asset_name}"
    fi
    {
        [[ -n "$manual_url" ]] && printf '%s\n' "$manual_url"
        [[ -n "$api_url" ]] && github_proxy_candidate_urls "$api_url"
        [[ -n "$official_url" ]] && github_proxy_candidate_urls "$official_url"
        github_proxy_candidate_urls "$latest_url"
        [[ -n "$fallback_url" ]] && github_proxy_candidate_urls "$fallback_url"
        [[ -n "$preferred_tag" ]] && xray_sourceforge_candidate_urls "$preferred_tag" "$asset_name"
        [[ -n "$fallback_tag" && "$fallback_tag" != "$preferred_tag" ]] && xray_sourceforge_candidate_urls "$fallback_tag" "$asset_name"
    } | awk 'NF && !seen[$0]++'
}

github_latest_release_redirect_tag() {
    # github_latest_release_redirect_tag "owner/repo"
    local repo="$1" final_url="" tag=""
    [[ -n "$repo" ]] || return 1
    if have_cmd curl; then
        final_url=$(curl -A 'Mozilla/5.0' -fsSL -o /dev/null -w '%{url_effective}' --connect-timeout 8 --max-time 20 "https://github.com/${repo}/releases/latest" 2>/dev/null || true)
    elif have_cmd wget; then
        final_url=$(wget --user-agent='Mozilla/5.0' -O /dev/null -S "https://github.com/${repo}/releases/latest" 2>&1 | awk '/^  Location: /{loc=$2} END{gsub(/\r/,"",loc); gsub(/\n/,"",loc); print loc}' || true)
    fi
    [[ -n "$final_url" ]] || return 1
    tag=$(printf '%s' "$final_url" | sed -n 's#.*\/releases\/tag\/##p' | head -n1)
    [[ -n "$tag" ]] && echo "$tag"
}

github_latest_tag() {
    # github_latest_tag "owner/repo"
    local repo="$1" body="" tag=""
    [[ -n "$repo" ]] || return 1
    body=$(fetch_text_url "https://api.github.com/repos/${repo}/releases/latest" || true)
    if [[ -n "$body" && "$body" != *"rate limit exceeded"* && "$body" != *"API rate limit exceeded"* ]]; then
        if have_cmd jq; then
            tag=$(printf '%s' "$body" | jq -r '.tag_name // empty' 2>/dev/null)
        fi
        if [[ -z "$tag" && -n "$body" ]] && have_cmd python3; then
            tag=$(python3 - "$body" <<'PYTAG'
import json, sys
try:
    data = json.loads(sys.argv[1])
    tag = data.get('tag_name') or ''
    if tag:
        print(tag)
except Exception:
    pass
PYTAG
)
        fi
        if [[ -z "$tag" && -n "$body" ]]; then
            tag=$(printf '%s' "$body" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
        fi
    fi
    if [[ -z "$tag" || "$tag" == "null" ]]; then
        tag=$(github_latest_release_redirect_tag "$repo" || true)
    fi
    [[ -n "$tag" && "$tag" != "null" ]] && echo "$tag"
}

github_release_asset_url() {
    # github_release_asset_url "owner/repo" "tag" "asset_name"
    local repo="$1" tag="$2" asset_name="$3" body="" url=""
    [[ -n "$repo" && -n "$tag" && -n "$asset_name" ]] || return 1
    body=$(fetch_text_url "https://api.github.com/repos/${repo}/releases/tags/${tag}" || true)
    if [[ -n "$body" ]] && have_cmd jq; then
        url=$(printf '%s' "$body" | jq -r --arg name "$asset_name" '.assets[]? | select(.name==$name) | .browser_download_url // empty' 2>/dev/null | head -n1)
    fi
    if [[ -z "$url" && -n "$body" ]] && have_cmd python3; then
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
    if [[ -z "$url" ]]; then
        url="https://github.com/${repo}/releases/download/${tag}/${asset_name}"
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

# 环境检查与全局命令安装
check_env() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行！${RESET}" && exit 1

    ssr_state_init_if_needed

    local deps=(curl bc wget tar openssl unzip ip ping jq python3)
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

    missing=()
    for dep in "${deps[@]}"; do
        have_cmd "$dep" || missing+=("$dep")
    done
    if ((${#missing[@]} > 0)); then
        echo -e "${RED}❌ 缺少关键依赖：${missing[*]}${RESET}"
        echo -e "${YELLOW}请先安装以上依赖后再运行脚本。${RESET}"
        exit 1
    fi
}

install_global_command() {
    # 兼容旧逻辑：不再创建 /usr/local/bin/ssr 快捷命令
    # 统一由综合脚本 my 负责命令入口与定时任务。
    if declare -F my_enable_ssr_cron_tasks >/dev/null 2>&1; then
        my_enable_ssr_cron_tasks
    fi
}

add_firewall_rule() {
    local port="$1" proto="$2"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    if have_cmd ufw && ufw status | grep -qw "active"; then
        [[ "$proto" == "both" || "$proto" == "tcp" ]] && ufw allow "$port"/tcp >/dev/null 2>&1 || true
        [[ "$proto" == "both" || "$proto" == "udp" ]] && ufw allow "$port"/udp >/dev/null 2>&1 || true
    fi
    if have_cmd firewall-cmd; then
        [[ "$proto" == "both" || "$proto" == "tcp" ]] && firewall-cmd --add-port="$port"/tcp --permanent >/dev/null 2>&1 || true
        [[ "$proto" == "both" || "$proto" == "udp" ]] && firewall-cmd --add-port="$port"/udp --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

remove_firewall_rule() {
    local port="$1" proto="$2"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    if have_cmd ufw; then
        [[ "$proto" == "both" || "$proto" == "tcp" ]] && ufw delete allow "$port"/tcp >/dev/null 2>&1 || true
        [[ "$proto" == "both" || "$proto" == "udp" ]] && ufw delete allow "$port"/udp >/dev/null 2>&1 || true
    fi
    if have_cmd firewall-cmd; then
        [[ "$proto" == "both" || "$proto" == "tcp" ]] && firewall-cmd --remove-port="$port"/tcp --permanent >/dev/null 2>&1 || true
        [[ "$proto" == "both" || "$proto" == "udp" ]] && firewall-cmd --remove-port="$port"/udp --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

managed_service_exec() {
    case "$1" in
        ss-rust) printf %s "/usr/local/bin/ss-rust -c /etc/ss-rust/config.json" ;;
        ss-v2ray) printf %s "/usr/local/bin/ss-rust -c /etc/ss-v2ray/config.json" ;;
        xray) printf %s "/usr/local/bin/xray run -c /usr/local/etc/xray/config.json" ;;
        *) return 1 ;;
    esac
}

managed_service_match() {
    managed_service_exec "$1"
}

managed_service_log() {
    case "$1" in
        ss-rust) printf %s "/var/log/ss-rust.log" ;;
        ss-v2ray) printf %s "/var/log/ss-v2ray.log" ;;
        xray) printf %s "/var/log/xray.log" ;;
        *) return 1 ;;
    esac
}

managed_service_pid() {
    case "$1" in
        ss-rust) printf %s "/var/run/ss-rust.pid" ;;
        ss-v2ray) printf %s "/var/run/ss-v2ray.pid" ;;
        xray) printf %s "/var/run/xray.pid" ;;
        *) return 1 ;;
    esac
}

managed_service_proto() {
    case "$1" in
        ss-rust) printf %s both ;;
        ss-v2ray|xray) printf %s tcp ;;
        *) return 1 ;;
    esac
}

managed_service_description() {
    case "$1" in
        ss-rust) printf %s "Shadowsocks-Rust Server" ;;
        ss-v2ray) printf %s "Shadowsocks-Rust + v2ray-plugin Server" ;;
        xray) printf %s "Xray Service" ;;
        *) return 1 ;;
    esac
}

managed_service_label() {
    case "$1" in
        ss-rust) printf %s "SS-Rust" ;;
        ss-v2ray) printf %s "SS2022 + v2ray-plugin" ;;
        xray) printf %s "Xray / VLESS Reality" ;;
        *) return 1 ;;
    esac
}

managed_service_config_path() {
    case "$1" in
        ss-rust) printf %s "/etc/ss-rust/config.json" ;;
        ss-v2ray) printf %s "$SS_V2RAY_CONF" ;;
        xray) printf %s "/usr/local/etc/xray/config.json" ;;
        *) return 1 ;;
    esac
}

managed_service_port_json_path() {
    case "$1" in
        ss-rust|ss-v2ray) printf %s "server_port" ;;
        xray) printf %s "inbounds.0.port" ;;
        *) return 1 ;;
    esac
}

managed_service_current_port() {
    local name="$1" cfg json_path
    cfg=$(managed_service_config_path "$name") || return 1
    json_path=$(managed_service_port_json_path "$name") || return 1
    [[ -f "$cfg" ]] || return 1
    json_get_path "$cfg" "$json_path" 2>/dev/null || true
}

managed_service_exists() {
    local name="$1" cfg match pid_file
    cfg=$(managed_service_config_path "$name" 2>/dev/null || true)
    match=$(managed_service_match "$name" 2>/dev/null || true)
    pid_file=$(managed_service_pid "$name" 2>/dev/null || true)
    [[ -n "$cfg" && -f "$cfg" ]] && return 0
    service_unit_exists "$name" && return 0
    [[ -n "$pid_file" && -f "$pid_file" ]] && return 0
    [[ -n "$match" ]] && pgrep -f "$match" >/dev/null 2>&1 && return 0
    [[ "$name" == "xray" && -x /usr/local/bin/xray ]] && return 0
    return 1
}

named_service_add_firewall() {
    local name="$1" port="${2:-}" proto
    [[ -n "$port" ]] || port=$(managed_service_current_port "$name" 2>/dev/null || true)
    proto=$(managed_service_proto "$name") || return 1
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    add_firewall_rule "$port" "$proto"
}

named_service_remove_firewall() {
    local name="$1" port="${2:-}" proto
    [[ -n "$port" ]] || port=$(managed_service_current_port "$name" 2>/dev/null || true)
    proto=$(managed_service_proto "$name") || return 1
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    remove_firewall_rule "$port" "$proto"
}

managed_service_unit() {
    local name="$1" desc exec_cmd
    desc=$(managed_service_description "$name") || return 1
    exec_cmd=$(managed_service_exec "$name") || return 1
    cat <<EOF
[Unit]
Description=${desc}
After=network.target

[Service]
ExecStart=${exec_cmd}
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

start_named_service() {
    local name="$1"
    start_managed_service "$name" "$(managed_service_unit "$name")" "$(managed_service_exec "$name")" "$(managed_service_match "$name")" "$(managed_service_log "$name")" "$(managed_service_pid "$name")"
}

restart_named_service() {
    local name="$1"
    restart_managed_service "$name" "$(managed_service_exec "$name")" "$(managed_service_match "$name")" "$(managed_service_log "$name")" "$(managed_service_pid "$name")"
}

stop_named_service() {
    local name="$1"
    stop_managed_service "$name" "$(managed_service_match "$name")" "$(managed_service_pid "$name")"
}

apply_json_named_service_change() {
    local file="$1" path="$2" value="$3" type="$4" svc="$5"
    apply_json_service_change "$file" "$path" "$value" "$type" "$svc" "$(managed_service_exec "$svc")" "$(managed_service_match "$svc")" "$(managed_service_log "$svc")" "$(managed_service_pid "$svc")"
}

apply_json_named_service_port_change() {
    local file="$1" path="$2" new_port="$3" old_port="$4" svc="$5"
    apply_json_service_port_change "$file" "$path" "$new_port" "$old_port" "$svc" "$(managed_service_exec "$svc")" "$(managed_service_match "$svc")" "$(managed_service_log "$svc")" "$(managed_service_pid "$svc")"
}

ss_rust_binary_still_needed() {
    local exclude="$1"
    [[ "$exclude" != "ss-rust" && ( -f /etc/ss-rust/config.json || -f /etc/systemd/system/ss-rust.service || -f /var/run/ss-rust.pid ) ]] && return 0
    [[ "$exclude" != "ss-v2ray" && ( -f "$SS_V2RAY_CONF" || -f /etc/systemd/system/ss-v2ray.service || -f /var/run/ss-v2ray.pid ) ]] && return 0
    pgrep -f '/usr/local/bin/ss-rust -c /etc/ss-rust/config.json' >/dev/null 2>&1 && [[ "$exclude" != "ss-rust" ]] && return 0
    pgrep -f '/usr/local/bin/ss-rust -c /etc/ss-v2ray/config.json' >/dev/null 2>&1 && [[ "$exclude" != "ss-v2ray" ]] && return 0
    return 1
}

cleanup_ss_rust_binary_if_unused() {
    local exclude="$1"
    ss_rust_binary_still_needed "$exclude" && return 0
    rm -f /usr/local/bin/ss-rust >/dev/null 2>&1 || true
}

apply_json_service_change() {
    local file="$1" path="$2" value="$3" type="$4"
    local svc="$5" bg_cmd="$6" bg_match="$7" log_file="$8" pid_file="$9"
    local txn=""
    txn=$(txn_begin) || return 1
    txn_register "$txn" restart_managed_service "$svc" "$bg_cmd" "$bg_match" "$log_file" "$pid_file"
    txn_backup_file "$txn" "$file" >/dev/null || { txn_abort "$txn"; return 1; }
    json_set_path "$file" "$path" "$value" "$type" || { txn_abort "$txn"; return 1; }
    if restart_managed_service "$svc" "$bg_cmd" "$bg_match" "$log_file" "$pid_file"; then
        txn_commit "$txn"
        return 0
    fi
    txn_abort "$txn"
    return 1
}

apply_json_service_port_change() {
    local file="$1" path="$2" new_port="$3" old_port="$4" svc="$5"
    local bg_cmd="$6" bg_match="$7" log_file="$8" pid_file="$9"
    local txn="" proto
    [[ "$new_port" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$old_port" && "$old_port" == "$new_port" ]] && return 0
    proto=$(managed_service_proto "$svc") || return 1
    txn=$(txn_begin) || return 1
    txn_register "$txn" remove_firewall_rule "$new_port" "$proto"
    txn_register "$txn" restart_managed_service "$svc" "$bg_cmd" "$bg_match" "$log_file" "$pid_file"
    txn_backup_file "$txn" "$file" >/dev/null || { txn_abort "$txn"; return 1; }
    add_firewall_rule "$new_port" "$proto" || true
    json_set_path "$file" "$path" "$new_port" number || { txn_abort "$txn"; return 1; }
    if restart_managed_service "$svc" "$bg_cmd" "$bg_match" "$log_file" "$pid_file"; then
        [[ "$old_port" =~ ^[0-9]+$ ]] && remove_firewall_rule "$old_port" "$proto"
        txn_commit "$txn"
        return 0
    fi
    txn_abort "$txn"
    return 1
}

managed_service_remove_artifacts() {
    local name="$1"
    case "$name" in
        ss-rust)
            rm -rf /etc/ss-rust
            rm -f /var/log/ss-rust.log
            cleanup_ss_rust_binary_if_unused "ss-rust"
            ;;
        ss-v2ray)
            rm -rf /etc/ss-v2ray
            rm -f /var/log/ss-v2ray.log "$SS_V2RAY_STATE"
            cleanup_ss_rust_binary_if_unused "ss-v2ray"
            ;;
        xray)
            rm -rf /usr/local/etc/xray
            rm -f /usr/local/bin/xray /var/log/xray.log
            ;;
        *) return 1 ;;
    esac
}

managed_service_purge_unit() {
    local name="$1"
    rm -f         "/etc/systemd/system/${name}.service"         "/etc/systemd/system/${name}"         "/lib/systemd/system/${name}.service"         "/lib/systemd/system/${name}"         "/usr/lib/systemd/system/${name}.service"         "/usr/lib/systemd/system/${name}"
}

managed_service_destroy() {
    local name="$1" mode="${2:-normal}" quiet="${3:-0}"
    local port="" pidfile="" match="" label=""
    [[ -n "$name" ]] || return 1
    label=$(managed_service_label "$name" 2>/dev/null || printf %s "$name")
    port=$(managed_service_current_port "$name" 2>/dev/null || true)
    pidfile=$(managed_service_pid "$name" 2>/dev/null || true)
    match=$(managed_service_match "$name" 2>/dev/null || true)

    if [[ "$mode" == "force" ]]; then
        service_use_systemd && { systemctl stop "$name" >/dev/null 2>&1 || true; systemctl disable "$name" >/dev/null 2>&1 || true; }
        have_cmd service && service "$name" stop >/dev/null 2>&1 || true
        have_cmd rc-service && rc-service "$name" stop >/dev/null 2>&1 || true
    fi

    named_service_remove_firewall "$name" "$port" >/dev/null 2>&1 || true
    stop_named_service "$name" >/dev/null 2>&1 || true

    if [[ "$mode" == "force" ]]; then
        [[ -n "$match" ]] && pkill -9 -f "$match" >/dev/null 2>&1 || true
        [[ "$name" == "xray" ]] && pkill -9 -x xray >/dev/null 2>&1 || true
    fi

    if [[ -n "$pidfile" && -f "$pidfile" ]]; then
        kill -9 "$(cat "$pidfile" 2>/dev/null)" >/dev/null 2>&1 || true
        rm -f "$pidfile" >/dev/null 2>&1 || true
    fi

    managed_service_remove_artifacts "$name" >/dev/null 2>&1 || true
    managed_service_purge_unit "$name"

    if service_use_systemd; then
        systemctl reset-failed "$name" >/dev/null 2>&1 || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    [[ "$quiet" == "1" ]] || echo -e "${GREEN}✅ ${label} 已彻底销毁！${RESET}"
    return 0
}

force_kill_service() {
    local target="$1" from_menu="$2"
    if [[ -z "$target" ]]; then
        echo -e "${RED}❌ 目标服务名为空！${RESET}"
        [[ "$from_menu" == "menu" ]] && { sleep 2; return; } || exit 1
    fi
    echo -e "${RED}☢️ 正在执行全链路强制核爆: ${target} ...${RESET}"
    managed_service_destroy "$target" force 1
    local target_desc
    target_desc=$(managed_service_label "$target" 2>/dev/null || printf %s "$target")
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
    local idx=1 svc port
    for svc in ss-rust ss-v2ray xray; do
        managed_service_exists "$svc" || continue
        port=$(managed_service_current_port "$svc" 2>/dev/null || true)
        NUCLEAR_TARGETS[$idx]="$svc"
        NUCLEAR_LABELS[$idx]="$(managed_service_label "$svc")"
        NUCLEAR_PORTS[$idx]="$port"
        ((idx++))
    done
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
    clear 2>/dev/null || true
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
        clear 2>/dev/null || true
        echo -e "${CYAN}========= DNS 管理中心 =========${RESET}"
        echo -e "${GREEN} 1.${RESET} 智能选优：稳定优先"
        echo -e "${GREEN} 2.${RESET} 智能选优：极致优化"
        echo -e "${YELLOW} 3.${RESET} 一键设置标准 DNS（不锁）"
        echo -e "${YELLOW} 4.${RESET} 手动设置 DNS（自定义）"
        echo -e "${YELLOW} 5.${RESET} 锁定 DNS（尽可能稳健）"
        echo -e "${YELLOW} 6.${RESET} 一键解锁并恢复（回滚至备份）"
        echo -e " 0. 返回"
        read -rp "输入 [0-6]: " dn
        case "$dn" in
            1|2)
                local profile="stable" dns_mode
                [[ "$dn" == "2" ]] && profile="extreme"
                read -rp "DNS 模式 [auto/set/lock, 回车 auto]: " dns_mode
                smart_dns_apply "$profile" "${dns_mode:-auto}"
                sleep 2
                ;;
            3)
                dns_set_or_lock "set" && echo -e "${GREEN}✅ DNS 已设置。${RESET}" || echo -e "${YELLOW}⚠️ 未修改 DNS。${RESET}"
                sleep 2
                ;;
            4)
                dns_manual_set && echo -e "${GREEN}✅ DNS 已设置。${RESET}" || echo -e "${YELLOW}⚠️ 未修改 DNS。${RESET}"
                sleep 2
                ;;
            5)
                dns_set_or_lock "lock" && echo -e "${GREEN}✅ DNS 已锁定/固定。${RESET}" || echo -e "${YELLOW}⚠️ 未修改 DNS。${RESET}"
                sleep 2
                ;;
            6)
                dns_unlock_restore
                echo -e "${GREEN}✅ 已解锁并恢复。${RESET}"
                sleep 2
                ;;
            0) return ;;
        esac
    done
}

setup_cf_ddns() {
    clear 2>/dev/null || true
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
LAST_TYPE=""
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

    local current_v4="" current_v6="" current_ip="" record_type=""
    current_v4=$(curl -s4m8 https://api.ipify.org 2>/dev/null || curl -s4m8 ifconfig.me 2>/dev/null || true)
    current_v6=$(curl -s6m8 https://api64.ipify.org 2>/dev/null || curl -s6m8 ifconfig.me 2>/dev/null || true)

    if [[ -n "$current_v4" ]]; then
        current_ip="$current_v4"
        record_type="A"
    elif [[ -n "$current_v6" ]]; then
        current_ip="$current_v6"
        record_type="AAAA"
    fi

    if [[ -z "$current_ip" || -z "$record_type" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [错误] 无法获取公网 IP" >> "$DDNS_LOG"
        [[ "$mode" == "manual" ]] && echo -e "${RED}❌ 无法获取公网 IPv4/IPv6。${RESET}"
        return
    fi

    if [[ "$current_ip" == "$LAST_IP" && "$record_type" == "${LAST_TYPE:-}" && "$mode" != "manual" ]]; then
        return
    fi

    [[ "$mode" == "manual" ]] && echo -e "${YELLOW}获取到当前 ${record_type} IP: $current_ip ，正在通信...${RESET}"

    local record_response record_id api_result success
    record_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?name=${CF_RECORD}&type=${record_type}"         -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json")
    record_id=$(echo "$record_response" | jq -r '.result[0].id' 2>/dev/null)

    if [[ -z "$record_id" || "$record_id" == "null" ]]; then
        api_result=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records"             -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json"             --data "{"type":"${record_type}","name":"${CF_RECORD}","content":"${current_ip}","ttl":60,"proxied":false}")
    else
        api_result=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}"             -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json"             --data "{"type":"${record_type}","name":"${CF_RECORD}","content":"${current_ip}","ttl":60,"proxied":false}")
    fi

    success=$(echo "$api_result" | jq -r '.success' 2>/dev/null)
    if [[ "$success" == "true" ]]; then
        sed -i "s/^LAST_IP=.*/LAST_IP="${current_ip}"/g" "$DDNS_CONF"
        if grep -q '^LAST_TYPE=' "$DDNS_CONF" 2>/dev/null; then
            sed -i "s/^LAST_TYPE=.*/LAST_TYPE="${record_type}"/g" "$DDNS_CONF"
        else
            printf 'LAST_TYPE="%s"
' "$record_type" >> "$DDNS_CONF"
        fi
        chmod 600 "$DDNS_CONF" 2>/dev/null || true
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [成功] ${record_type} 更新为: $current_ip" >> "$DDNS_LOG"
        [[ "$mode" == "manual" ]] && echo -e "${GREEN}✅ ${record_type} 解析已更新为: $current_ip${RESET}"
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
    for _rtype in A AAAA; do
        record_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?name=${CF_RECORD}&type=${_rtype}"             -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json")
        while IFS= read -r record_id; do
            [[ -z "$record_id" || "$record_id" == "null" ]] && continue
            curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}"                 -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" > /dev/null 2>&1 || true
        done < <(echo "$record_response" | jq -r '.result[]?.id' 2>/dev/null)
    done
    echo -e "${GREEN}✅ 云端记录已删除（若 API 权限允许）。${RESET}"

    rm -f "$DDNS_CONF" "$DDNS_LOG"
    crontab -l 2>/dev/null | grep -vE "(^|\s)(/usr/local/bin/my\s+ssr\s+ddns|/usr/local/bin/ssr\s+ddns)(\s|$)" | crontab - 2>/dev/null || true

    echo -e "${GREEN}✅ 本地 DDNS 任务已撤销。${RESET}"
    [[ "$cli_mode" != "force" ]] && sleep 2
}

cf_ddns_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}========= 🌐 动态域名解析 (Cloudflare DDNS) =========${RESET}"
        if [[ -f "$DDNS_CONF" ]]; then
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
        local cfg_bak dropin_bak="" old_port
        backup_file_once /etc/ssh/sshd_config "$SSHD_BACKUP_FILE"
        cfg_bak=$(make_runtime_backup /etc/ssh/sshd_config) || { echo -e "${RED}❌ SSH 配置备份失败。${RESET}"; sleep 2; return 1; }
        [[ -f "$SSH_PORT_DROPIN" ]] && dropin_bak=$(make_runtime_backup "$SSH_PORT_DROPIN" 2>/dev/null || true)
        old_port=$(sshd_effective_port 2>/dev/null || echo 22)
        ssh_takeover_socket_activation >/dev/null 2>&1 || true
        add_firewall_rule "$new_port" tcp || true
        write_ssh_port_dropin "$new_port"
        if restart_ssh_safe && verify_ssh_runtime "$new_port" "" ""; then
            [[ "$old_port" =~ ^[0-9]+$ && "$old_port" != "$new_port" ]] && remove_firewall_rule "$old_port" tcp
            rm -f "$cfg_bak" "$dropin_bak"
            echo -e "${GREEN}✅ SSH 端口已修改为 $new_port ，并已生效。${RESET}"
        else
            restore_file_strict "$cfg_bak" /etc/ssh/sshd_config >/dev/null 2>&1 || true
            restore_or_remove_file "$dropin_bak" "$SSH_PORT_DROPIN" >/dev/null 2>&1 || true
            restart_ssh_safe >/dev/null 2>&1 || true
            [[ "$old_port" != "$new_port" ]] && remove_firewall_rule "$new_port" tcp
            rm -f "$cfg_bak" "$dropin_bak"
            echo -e "${RED}❌ SSH 端口修改未生效，已回滚。${RESET}"
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
    if printf 'root:%s\n' "$new_pass" | chpasswd 2>/dev/null; then
        echo -e "${GREEN}✅ Root 密码修改成功！${RESET}"
        echo -e "${YELLOW}提示：若需通过 SSH 使用密码登录，请确认 SSH 密码登录已开启。${RESET}"
    else
        echo -e "${RED}❌ Root 密码修改失败。${RESET}"
    fi
    sleep 2
}

timesync_unit_exists() {
    local svc="$1"
    [[ -z "$svc" ]] && return 1
    if have_cmd systemctl; then
        systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 && return 0
        systemctl cat "${svc}.service" >/dev/null 2>&1 && return 0
    fi
    case "$svc" in
        systemd-timesyncd)
            [[ -f /lib/systemd/system/systemd-timesyncd.service || -f /usr/lib/systemd/system/systemd-timesyncd.service || -x /lib/systemd/systemd-timesyncd || -x /usr/lib/systemd/systemd-timesyncd ]] && return 0
            ;;
        chronyd|chrony)
            [[ -f /lib/systemd/system/chronyd.service || -f /usr/lib/systemd/system/chronyd.service || -f /lib/systemd/system/chrony.service || -f /usr/lib/systemd/system/chrony.service || -x /usr/sbin/chronyd || -x /usr/bin/chronyd ]] && return 0
            ;;
        ntpd|ntp)
            [[ -f /lib/systemd/system/ntpd.service || -f /usr/lib/systemd/system/ntpd.service || -f /lib/systemd/system/ntp.service || -f /usr/lib/systemd/system/ntp.service || -x /usr/sbin/ntpd || -x /usr/bin/ntpd ]] && return 0
            ;;
    esac
    return 1
}

timesync_active_service() {
    local svc
    for svc in systemd-timesyncd chronyd chrony ntpd ntp; do
        if have_cmd systemctl; then
            if systemctl is-active --quiet "$svc" 2>/dev/null || systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
                printf '%s' "$svc"
                return 0
            fi
        else
            pgrep -x "$svc" >/dev/null 2>&1 && { printf '%s' "$svc"; return 0; }
        fi
    done
    return 1
}

timesync_enabled_service() {
    local svc
    for svc in systemd-timesyncd chronyd chrony ntpd ntp; do
        if have_cmd systemctl; then
            if systemctl is-enabled --quiet "$svc" 2>/dev/null || systemctl is-enabled --quiet "${svc}.service" 2>/dev/null; then
                printf '%s' "$svc"
                return 0
            fi
        fi
    done
    return 1
}

timesync_preferred_service() {
    local svc
    for svc in systemd-timesyncd chronyd chrony ntpd ntp; do
        timesync_unit_exists "$svc" && { printf '%s' "$svc"; return 0; }
    done
    return 1
}

timesync_enable_service() {
    local svc="$1"
    [[ -z "$svc" ]] && return 1
    if have_cmd systemctl; then
        systemctl enable --now "$svc" >/dev/null 2>&1 && return 0
        systemctl enable --now "${svc}.service" >/dev/null 2>&1 && return 0
    fi
    if have_cmd service; then
        service "$svc" start >/dev/null 2>&1 && return 0
    fi
    if have_cmd rc-service; then
        rc-service "$svc" start >/dev/null 2>&1 && return 0
    fi
    return 1
}

timesync_probe_status() {
    local virt active_svc enabled_svc ntp synced
    virt="$(ddtool_get_virt_type 2>/dev/null || echo unknown)"
    active_svc="$(timesync_active_service 2>/dev/null || true)"
    enabled_svc="$(timesync_enabled_service 2>/dev/null || true)"
    ntp=""
    synced=""
    if have_cmd timedatectl; then
        ntp="$(timedatectl show -p NTP --value 2>/dev/null | tr '[:upper:]' '[:lower:]')"
        synced="$(timedatectl show -p NTPSynchronized --value 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    fi
    if [[ "$synced" == "yes" ]]; then
        printf 'synced|%s|%s|%s' "${active_svc:-${enabled_svc:-ntp}}" "$ntp" "$virt"
        return 0
    fi
    if [[ -n "$active_svc" ]]; then
        if [[ "$ntp" == "yes" ]]; then
            printf 'running|%s|%s|%s' "$active_svc" "$ntp" "$virt"
        else
            printf 'service_only|%s|%s|%s' "$active_svc" "$ntp" "$virt"
        fi
        return 0
    fi
    if [[ "$ntp" == "yes" ]]; then
        case "$virt" in
            openvz|lxc|lxc-libvirt|docker|podman|container-other|container)
                printf 'host|%s|%s|%s' "${enabled_svc:-host}" "$ntp" "$virt"
                return 0
                ;;
        esac
        printf 'enabled|%s|%s|%s' "${enabled_svc:-ntp}" "$ntp" "$virt"
        return 0
    fi
    if [[ -n "$enabled_svc" ]]; then
        printf 'enabled|%s|%s|%s' "$enabled_svc" "$ntp" "$virt"
        return 0
    fi
    case "$virt" in
        openvz|lxc|lxc-libvirt|docker|podman|container-other|container)
            printf 'container|%s|%s|%s' "-" "$ntp" "$virt"
            return 0
            ;;
    esac
    printf 'off|-|%s|%s' "$ntp" "$virt"
}

status_timesync_brief() {
    local state svc _ntp virt
    IFS='|' read -r state svc _ntp virt <<<"$(timesync_probe_status 2>/dev/null || echo 'off|-|-|unknown')"
    case "$state" in
        synced) printf '已同步(%s)' "$svc" ;;
        running) printf '运行中/待同步(%s)' "$svc" ;;
        service_only) printf '服务运行中(%s)' "$svc" ;;
        enabled) printf '已启用/待同步(%s)' "$svc" ;;
        host) printf '宿主管理/已启用(%s)' "$virt" ;;
        container) printf '容器受限/宿主管理(%s)' "$virt" ;;
        *) printf %s '未启用' ;;
    esac
}

status_timesync_line() {
    local text
    text="$(status_timesync_brief)"
    case "$text" in
        已同步*) echo -e "  时间同步服务: $(status_colorize ok \"$text\")" ;;
        运行中/*|服务运行中*|已启用/*|宿主管理/*|容器受限/*) echo -e "  时间同步服务: $(status_colorize info \"$text\")" ;;
        *) echo -e "  时间同步服务: $(status_colorize warn \"$text\")" ;;
    esac
}

sync_server_time() {
    local svc state svc_name _ntp virt
    echo -e "${CYAN}>>> 正在启用时间同步服务...${RESET}"
    if have_cmd timedatectl; then
        timedatectl set-ntp true >/dev/null 2>&1 || true
    fi
    svc="$(timesync_preferred_service 2>/dev/null || true)"
    if [[ -z "$svc" ]]; then
        if have_cmd apt-get; then
            apt-get update -qq >/dev/null 2>&1 || true
            apt-get install -yqq systemd-timesyncd >/dev/null 2>&1 || apt-get install -yqq chrony >/dev/null 2>&1 || true
        elif have_cmd dnf; then
            dnf install -y chrony >/dev/null 2>&1 || true
        elif have_cmd yum; then
            yum install -yq chrony >/dev/null 2>&1 || true
        elif have_cmd apk; then
            apk add --no-cache chrony >/dev/null 2>&1 || true
        fi
        svc="$(timesync_preferred_service 2>/dev/null || true)"
    fi
    if [[ -n "$svc" ]]; then
        timesync_enable_service "$svc" >/dev/null 2>&1 || true
    fi
    if have_cmd timedatectl; then
        timedatectl set-ntp true >/dev/null 2>&1 || true
    fi
    sleep 2
    IFS='|' read -r state svc_name _ntp virt <<<"$(timesync_probe_status 2>/dev/null || echo 'off|-|-|unknown')"
    case "$state" in
        synced)
            echo -e "${GREEN}✅ 时间同步已生效：${svc_name}（已同步）。${RESET}"
            ;;
        running|service_only|enabled)
            echo -e "${GREEN}✅ 时间同步服务已启动：${svc_name}。${RESET}"
            echo -e "${YELLOW}提示：服务已启用，但可能需要等待几十秒到几分钟完成首次同步。${RESET}"
            ;;
        host|container)
            echo -e "${YELLOW}⚠ 当前环境为 ${virt}，时间可能由宿主机统一管理。${RESET}"
            echo -e "${YELLOW}状态检测：$(status_timesync_brief)${RESET}"
            ;;
        *)
            echo -e "${RED}❌ 未检测到可用的时间同步服务生效。${RESET}"
            if [[ -n "$svc" ]]; then
                echo -e "${YELLOW}已尝试启用：${svc}${RESET}"
            fi
            ;;
    esac
    sleep 2
}

apply_ssh_key_sec() {
    local cfg_bak dropin_bak="" port_bak=""
    local eff_port
    ensure_root_authorized_keys || { echo -e "${RED}❌ 无法初始化 root 的 authorized_keys。${RESET}"; sleep 2; return 1; }
    if ! grep -qE '^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)) ' "$ROOT_AUTH_KEYS_FILE" 2>/dev/null; then
        echo -e "${RED}❌ 未找到有效的 root 公钥，未启用仅密钥登录。${RESET}"
        sleep 2
        return 1
    fi
    backup_file_once /etc/ssh/sshd_config "$SSHD_BACKUP_FILE"
    cfg_bak=$(make_runtime_backup /etc/ssh/sshd_config) || { echo -e "${RED}❌ SSH 配置备份失败。${RESET}"; sleep 2; return 1; }
    [[ -f "$SSH_AUTH_DROPIN" ]] && dropin_bak=$(make_runtime_backup "$SSH_AUTH_DROPIN" 2>/dev/null || true)
    [[ -f "$SSH_PORT_DROPIN" ]] && port_bak=$(make_runtime_backup "$SSH_PORT_DROPIN" 2>/dev/null || true)
    eff_port=$(sshd_effective_port 2>/dev/null || echo 22)
    replace_or_append_line /etc/ssh/sshd_config '^#?PubkeyAuthentication ' 'PubkeyAuthentication yes'
    replace_or_append_line /etc/ssh/sshd_config '^#?UsePAM ' 'UsePAM yes'
    write_ssh_auth_dropin no no no prohibit-password
    if ! restart_ssh_safe || ! verify_ssh_runtime "$eff_port" no prohibit-password; then
        restore_file_strict "$cfg_bak" /etc/ssh/sshd_config >/dev/null 2>&1 || true
        restore_or_remove_file "$dropin_bak" "$SSH_AUTH_DROPIN" >/dev/null 2>&1 || true
        restore_or_remove_file "$port_bak" "$SSH_PORT_DROPIN" >/dev/null 2>&1 || true
        restart_ssh_safe >/dev/null 2>&1 || true
        rm -f "$cfg_bak" "$dropin_bak" "$port_bak"
        echo -e "${RED}❌ SSH 密钥登录配置未生效，已回滚。${RESET}"
        sleep 2
        return 1
    fi
    rm -f "$cfg_bak" "$dropin_bak" "$port_bak"
    echo -e "${GREEN}✅ 已启用密钥登录并禁止密码登录。${RESET}"
    sleep 2
}

restore_password_login() {
    local cfg_bak dropin_bak="" port_bak=""
    local eff_port
    backup_file_once /etc/ssh/sshd_config "$SSHD_BACKUP_FILE"
    cfg_bak=$(make_runtime_backup /etc/ssh/sshd_config) || { echo -e "${RED}❌ SSH 配置备份失败。${RESET}"; sleep 2; return 1; }
    [[ -f "$SSH_AUTH_DROPIN" ]] && dropin_bak=$(make_runtime_backup "$SSH_AUTH_DROPIN" 2>/dev/null || true)
    [[ -f "$SSH_PORT_DROPIN" ]] && port_bak=$(make_runtime_backup "$SSH_PORT_DROPIN" 2>/dev/null || true)
    eff_port=$(sshd_effective_port 2>/dev/null || echo 22)
    replace_or_append_line /etc/ssh/sshd_config '^#?PubkeyAuthentication ' 'PubkeyAuthentication yes'
    replace_or_append_line /etc/ssh/sshd_config '^#?UsePAM ' 'UsePAM yes'
    write_ssh_auth_dropin yes yes yes yes
    if ! restart_ssh_safe || ! verify_ssh_runtime "$eff_port" yes yes; then
        restore_file_strict "$cfg_bak" /etc/ssh/sshd_config >/dev/null 2>&1 || true
        restore_or_remove_file "$dropin_bak" "$SSH_AUTH_DROPIN" >/dev/null 2>&1 || true
        restore_or_remove_file "$port_bak" "$SSH_PORT_DROPIN" >/dev/null 2>&1 || true
        restart_ssh_safe >/dev/null 2>&1 || true
        rm -f "$cfg_bak" "$dropin_bak" "$port_bak"
        echo -e "${RED}❌ SSH 密码登录恢复未生效，已回滚。${RESET}"
        sleep 2
        return 1
    fi
    rm -f "$cfg_bak" "$dropin_bak" "$port_bak"
    echo -e "${GREEN}✅ 已恢复密码登录。${RESET}"
    sleep 2
}

ssh_key_menu() {
    clear 2>/dev/null || true
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
            if [[ -n "$gh_user" ]]; then
                ensure_root_authorized_keys || { echo -e "${RED}❌ 无法初始化 root 的 SSH 目录。${RESET}"; sleep 2; return; }
                local keys
                keys=$(fetch_github_user_keys "$gh_user" 2>/dev/null || true)
                if [[ -n "$keys" ]]; then
                    printf '%s
' "$keys" >> "$ROOT_AUTH_KEYS_FILE"
                    sort -u "$ROOT_AUTH_KEYS_FILE" -o "$ROOT_AUTH_KEYS_FILE" 2>/dev/null || true
                    echo -e "${GREEN}✅ 拉取成功！${RESET}"
                    apply_ssh_key_sec
                else
                    echo -e "${RED}❌ 未找到公钥。${RESET}"
                    sleep 2
                fi
            fi
            ;;
        2)
            read -rp "粘贴公钥: " manual_key
            [[ -n "$manual_key" ]] && {
                ensure_root_authorized_keys || { echo -e "${RED}❌ 无法初始化 root 的 SSH 目录。${RESET}"; sleep 2; return; }
                echo "$manual_key" >> "$ROOT_AUTH_KEYS_FILE"
                sort -u "$ROOT_AUTH_KEYS_FILE" -o "$ROOT_AUTH_KEYS_FILE" 2>/dev/null || true
                chmod 600 "$ROOT_AUTH_KEYS_FILE"
                echo -e "${GREEN}✅ 成功！${RESET}"
                apply_ssh_key_sec
            }
            ;;
        3)
            ensure_root_authorized_keys || { echo -e "${RED}❌ 无法初始化 root 的 SSH 目录。${RESET}"; sleep 2; return; }
            rm -f "$ROOT_SSH_DIR"/id_ed25519*
            ssh-keygen -t ed25519 -f "$ROOT_SSH_DIR/id_ed25519" -N "" -q
            cat "$ROOT_SSH_DIR/id_ed25519.pub" >> "$ROOT_AUTH_KEYS_FILE"
            sort -u "$ROOT_AUTH_KEYS_FILE" -o "$ROOT_AUTH_KEYS_FILE" 2>/dev/null || true
            chmod 600 "$ROOT_AUTH_KEYS_FILE"
            echo -e "${RED}⚠️ 请保存以下私钥（只显示一次）！⚠️${RESET}
"
            cat "$ROOT_SSH_DIR/id_ed25519"
            echo -e "
${YELLOW}========================${RESET}"
            read -rp "关闭密码登录 (y/N): " confirm
            [[ "$confirm" == "y" || "$confirm" == "Y" ]] && apply_ssh_key_sec
            ;;
        4)
            restore_password_login
            ;;
        0) return ;;
    esac
}

install_ss_rust_native() {
    clear 2>/dev/null || true
    echo -e "${CYAN}========= 原生交互安装 SS-Rust =========${RESET}"
    read -rp "端口 [留空随机]: " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        port=$((RANDOM % 55535 + 10000))
    fi
    ss_pick_method_password || return
    ensure_ss_rust_binary || return
    mkdir -p /etc/ss-rust
    cat > /etc/ss-rust/config.json << EOF
{ "server": "::", "server_port": $port, "password": "${SS_PICK_PASSWORD}", "method": "${SS_PICK_METHOD}", "mode": "tcp_and_udp", "fast_open": true }
EOF
    run_with_timeout 2 /usr/local/bin/ss-rust -c /etc/ss-rust/config.json >/dev/null 2>&1
    local rc=$?
    if [[ "$rc" -ne 0 && "$rc" -ne 124 && "$rc" -ne 137 ]]; then
        echo -e "${RED}❌ 配置自检失败，已中止启动。${RESET}"
        sleep 3
        return
    fi
    if ! start_named_service "ss-rust"; then
        echo -e "${RED}❌ SS-Rust 启动失败。请检查 /var/log/ss-rust.log${RESET}"
        sleep 3
        return
    fi
    named_service_add_firewall "ss-rust" "$port" >/dev/null 2>&1 || true
    [[ -n "$ENSURED_SS_RUST_TAG" ]] && meta_set "SS_RUST_TAG" "$ENSURED_SS_RUST_TAG"
    echo -e "${GREEN}✅ SS-Rust (${ENSURED_SS_RUST_TAG:-local}) 安装完成！${RESET}"
    show_ss_rust_summary
    read -n 1 -s -r -p "按任意键返回上一层..."
}

install_vless_native() {
    clear 2>/dev/null || true
    echo -e "${CYAN}========= 原生交互安装 VLESS Reality =========${RESET}"
    rm -f /etc/systemd/system/xray.service

    read -rp "伪装域名 [默认 updates.cdn-apple.com]: " sni_domain
    [[ -z "$sni_domain" ]] && sni_domain="updates.cdn-apple.com"

    read -rp "监听端口 [留空随机]: " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        port=$((RANDOM % 55535 + 10000))
    fi

    local arch; arch=$(uname -m)
    local xray_arch=""
    xray_arch=$(xray_linux_asset_arch "$arch")

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
        xray_latest=$(xray_remote_latest_tag 2>/dev/null || true)
        if ! xray_tag_plausible "$xray_latest"; then
            xray_latest=$(xray_cached_or_latest_tag 2>/dev/null || true)
        fi
        if ! xray_tag_plausible "$xray_latest"; then
            xray_latest="$XRAY_FALLBACK_TAG"
        fi

        tmpdir=$(mktemp -d /tmp/ssr-xray.XXXXXX)
        zipf="${tmpdir}/xray.zip"
        local asset_name chosen_tag="" ok_url="" display_tag=""
        local -a xray_urls=()
        asset_name=$(xray_release_asset_name "$xray_arch")
        display_tag="$xray_latest"
        [[ -n "$display_tag" ]] || display_tag="latest"

        mapfile -t xray_urls < <(xray_download_candidate_urls "$xray_latest" "$asset_name" "$XRAY_FALLBACK_TAG")

        echo -e "${CYAN}>>> 下载核心: ${display_tag} (linux-${xray_arch}) ...${RESET}"

        if xray_download_zip_any "$zipf" "${xray_urls[@]}"; then
            ok_url=1
            chosen_tag="$xray_latest"
            [[ -n "$chosen_tag" ]] || chosen_tag="$XRAY_FALLBACK_TAG"
        fi
        if [[ -z "$ok_url" ]]; then
            echo -e "${RED}❌ 核心下载或校验失败（候选下载地址全部失败，或 ZIP / SHA256 校验未通过）。${RESET}"
            [[ -n "$XRAY_LAST_DOWNLOAD_URL" ]] && echo -e "${YELLOW}最后失败地址: ${XRAY_LAST_DOWNLOAD_URL}${RESET}"
            [[ -n "$XRAY_LAST_DOWNLOAD_REASON" ]] && echo -e "${YELLOW}最后失败原因: ${XRAY_LAST_DOWNLOAD_REASON}${RESET}"
            [[ -n "$XRAY_DOWNLOAD_LOG" ]] && echo -e "${YELLOW}下载诊断日志: ${XRAY_DOWNLOAD_LOG}${RESET}"
            rm -rf "$tmpdir"
            sleep 3
            return
        fi

        extract_xray_from_zip "$zipf" "$tmpdir" >/dev/null 2>&1 || true
        if [[ ! -x "${tmpdir}/xray" ]]; then
            echo -e "${RED}❌ 解压失败：未找到 xray。${RESET}"
            rm -rf "$tmpdir"
            sleep 3
            return
        fi

        if ! run_with_timeout 3 "${tmpdir}/xray" version >/dev/null 2>&1 || ! run_with_timeout 3 "${tmpdir}/xray" x25519 >/dev/null 2>&1; then
            echo -e "${RED}❌ 新核心自检失败（无法运行或缺少 x25519）。已中止替换。${RESET}"
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
        xray_latest=$(run_with_timeout 3 "${tmpdir}/xray" version 2>/dev/null | head -n1 | grep -oE '([0-9]+\.){2}[0-9]+' | head -n1)
        [[ -n "$xray_latest" ]] && xray_latest="v${xray_latest}" || xray_latest="$chosen_tag"
        [[ -n "$xray_latest" ]] && cache_store_binary "xray" "$xray_latest" /usr/local/bin/xray >/dev/null 2>&1 || true
    fi

    [[ -n "$xray_latest" ]] || xray_latest=$(xray_current_tag || true)
    [[ -n "$xray_latest" ]] && meta_set "XRAY_TAG" "$xray_latest"

    mkdir -p /usr/local/etc/xray
    local uuid keys priv pub short_id
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        uuid=$(tr -d '\r\n' < /proc/sys/kernel/random/uuid 2>/dev/null)
    elif have_cmd uuidgen; then
        uuid=$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z' | tr -d '\r\n')
    elif have_cmd python3; then
        uuid=$(python3 - <<'PYUUID' 2>/dev/null
import uuid
print(uuid.uuid4())
PYUUID
)
        uuid=$(printf '%s' "$uuid" | tr -d '\r\n')
    else
        uuid=$(/usr/local/bin/xray uuid 2>/dev/null | head -n1 | tr -d '\r')
    fi
    keys=$(/usr/local/bin/xray x25519 2>&1 | tr -d '\r')
    priv=$(xray_extract_reality_private_key "$keys")
    pub=$(xray_extract_reality_public_key "$keys")
    if have_cmd openssl; then
        short_id=$(openssl rand -hex 8 2>/dev/null)
    else
        short_id=$(head -c 8 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')
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

    if ! start_named_service "xray"; then
        echo -e "${RED}❌ Xray 启动失败。请检查 /var/log/xray.log${RESET}"
        rm -rf "$tmpdir"
        sleep 3
        return
    fi

    named_service_add_firewall "xray" "$port" >/dev/null 2>&1 || true

    [[ -n "$xray_latest" ]] && meta_set "XRAY_TAG" "$xray_latest"

    echo -e "${GREEN}✅ VLESS Reality (${xray_latest:-local}) 安装成功！${RESET}"
    show_vless_summary
    rm -rf "$tmpdir"
    read -n 1 -s -r -p "按任意键返回上一层..."
}

install_ss_v2ray_plugin_native() {
    clear 2>/dev/null || true
    echo -e "${CYAN}========= 自动部署 SS2022 + v2ray-plugin =========${RESET}"
    read -rp "端口 [留空随机]: " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        port=$((RANDOM % 55535 + 10000))
    fi
    ss_pick_method_password || return
    ensure_ss_rust_binary || return
    read -rp "伪装域名 Host [默认 updates.cdn-apple.com]: " host
    [[ -z "$host" ]] && host="updates.cdn-apple.com"
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
        [[ -z "$vp_latest" ]] && vp_latest="v1.3.4"
        tmpdir=$(mktemp -d /tmp/ssr-v2ray-plugin.XXXXXX)
        tarf="${tmpdir}/v2ray-plugin.tar.gz"
        asset_name="${asset_name}-${vp_latest}.tar.gz"
        official_url="https://github.com/shadowsocks/v2ray-plugin/releases/download/${vp_latest}/${asset_name}"
        api_url=$(github_release_asset_url "shadowsocks/v2ray-plugin" "$vp_latest" "$asset_name" 2>/dev/null || true)
        proxy_url=$(github_proxy_wrap "$official_url")
        echo -e "${CYAN}>>> 正在准备 v2ray-plugin: ${vp_latest} ...${RESET}"
        if ! download_file_any "$tarf" "$api_url" "$official_url" "$proxy_url" || [[ ! -s "$tarf" ]] || ! tar -tf "$tarf" >/dev/null 2>&1; then
            echo -e "${RED}❌ v2ray-plugin 下载失败。${RESET}"
            rm -rf "$tmpdir"
            sleep 3
            return
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
        echo -e "${RED}❌ 配置自检失败，已中止启动。${RESET}"
        sleep 3
        return
    fi
    if ! start_named_service "ss-v2ray"; then
        echo -e "${RED}❌ SS2022 + v2ray-plugin 启动失败。${RESET}"
        sleep 3
        return
    fi
    named_service_add_firewall "ss-v2ray" "$port" >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ SS2022 + v2ray-plugin 部署完成！${RESET}"
    show_ss_v2ray_summary
    read -n 1 -s -r -p "按任意键返回上一层..."
}

# 统一节点生命周期管控中心

unified_node_manager() {
    while true; do
        clear 2>/dev/null || true
        local has_ss=0 has_v2=0 has_vless=0
        managed_service_exists "ss-rust" && has_ss=1
        managed_service_exists "ss-v2ray" && has_v2=1
        managed_service_exists "xray" && has_vless=1
        echo -e "${CYAN}========= 统一节点生命周期管控中心 =========${RESET}"
        echo -e "${YELLOW} 1)${RESET} SS-Rust 节点管理"
        echo -e "${YELLOW} 2)${RESET} SS2022 + v2ray-plugin 管理"
        echo -e "${YELLOW} 3)${RESET} VLESS Reality 节点管理"
        echo -e "${RED} 4) ☢️ 全局强制核爆${RESET}"
        echo -e " 0) 返回主菜单"
        read -rp "请选择 [0-4]: " node_choice
        case "$node_choice" in
            1)
                if [[ $has_ss -eq 1 ]]; then
                    clear 2>/dev/null || true
                    local port
                    port=$(json_get_path /etc/ss-rust/config.json server_port 2>/dev/null)
                    echo -e "---------------------------------"
                    echo -e "${YELLOW}1) 查看节点链接信息${RESET} | ${YELLOW}2) 修改端口${RESET} | ${YELLOW}3) 修改密码${RESET} | ${RED}4) 删除节点${RESET} | 0) 返回"
                    read -rp "输入操作: " op
                    if [[ "$op" == "1" ]]; then
                        show_ss_rust_summary
                        read -n1 -rsp "按任意键返回..." _
                    elif [[ "$op" == "2" ]]; then
                        read -rp "新端口 (1-65535): " np
                        if [[ "$np" =~ ^[0-9]+$ ]] && [ "$np" -ge 1 ] && [ "$np" -le 65535 ]; then
                            if apply_json_named_service_port_change /etc/ss-rust/config.json server_port "$np" "$port" "ss-rust"; then
                                echo -e "${GREEN}✅ 修改成功${RESET}"
                            else
                                echo -e "${RED}❌ 修改失败，已自动回滚${RESET}"
                            fi
                        else
                            echo -e "${RED}❌ 端口无效${RESET}"
                        fi
                        sleep 1
                    elif [[ "$op" == "3" ]]; then
                        read -rp "新密码: " npwd
                        [[ -z "$npwd" ]] && { echo -e "${RED}❌ 密码不能为空${RESET}"; sleep 1; continue; }
                        if apply_json_named_service_change /etc/ss-rust/config.json password "$npwd" string "ss-rust"; then
                            echo -e "${GREEN}✅ 修改成功${RESET}"
                        else
                            echo -e "${RED}❌ 修改失败，已自动回滚${RESET}"
                        fi
                        sleep 1
                    elif [[ "$op" == "4" ]]; then
                        managed_service_destroy "ss-rust"
                        sleep 1
                    fi
                fi
                ;;
            2)
                if [[ $has_v2 -eq 1 ]]; then
                    clear 2>/dev/null || true
                    local port
                    port=$(json_get_path "$SS_V2RAY_CONF" server_port 2>/dev/null)
                    echo -e "---------------------------------"
                    echo -e "${YELLOW}1) 查看节点链接信息${RESET} | ${YELLOW}2) 修改端口${RESET} | ${YELLOW}3) 修改密码${RESET} | ${RED}4) 删除节点${RESET} | 0) 返回"
                    read -rp "输入操作: " op
                    if [[ "$op" == "1" ]]; then
                        show_ss_v2ray_summary
                        read -n1 -rsp "按任意键返回..." _
                    elif [[ "$op" == "2" ]]; then
                        read -rp "新端口 (1-65535): " np
                        if [[ "$np" =~ ^[0-9]+$ ]] && [ "$np" -ge 1 ] && [ "$np" -le 65535 ]; then
                            if apply_json_named_service_port_change "$SS_V2RAY_CONF" server_port "$np" "$port" "ss-v2ray"; then
                                echo -e "${GREEN}✅ 修改成功${RESET}"
                            else
                                echo -e "${RED}❌ 修改失败，已自动回滚${RESET}"
                            fi
                        else
                            echo -e "${RED}❌ 端口无效${RESET}"
                        fi
                        sleep 1
                    elif [[ "$op" == "3" ]]; then
                        read -rp "新密码: " npwd
                        [[ -z "$npwd" ]] && { echo -e "${RED}❌ 密码不能为空${RESET}"; sleep 1; continue; }
                        if apply_json_named_service_change "$SS_V2RAY_CONF" password "$npwd" string "ss-v2ray"; then
                            echo -e "${GREEN}✅ 修改成功${RESET}"
                        else
                            echo -e "${RED}❌ 修改失败，已自动回滚${RESET}"
                        fi
                        sleep 1
                    elif [[ "$op" == "4" ]]; then
                        managed_service_destroy "ss-v2ray"
                        sleep 1
                    fi
                fi
                ;;
            3)
                if [[ $has_vless -eq 1 ]]; then
                    clear 2>/dev/null || true
                    local port
                    port=$(json_get_path /usr/local/etc/xray/config.json inbounds.0.port 2>/dev/null)
                    echo -e "---------------------------------"
                    echo -e "${YELLOW}1) 查看节点链接信息${RESET} | ${YELLOW}2) 修改端口${RESET} | ${YELLOW}3) 重启节点${RESET} | ${RED}4) 删除节点${RESET} | 0) 返回"
                    read -rp "输入操作: " op
                    if [[ "$op" == "1" ]]; then
                        show_vless_summary
                        read -n1 -rsp "按任意键返回..." _
                    elif [[ "$op" == "2" ]]; then
                        read -rp "新端口 (1-65535): " np
                        if [[ "$np" =~ ^[0-9]+$ ]] && [ "$np" -ge 1 ] && [ "$np" -le 65535 ]; then
                            if apply_json_named_service_port_change /usr/local/etc/xray/config.json inbounds.0.port "$np" "$port" "xray"; then
                                echo -e "${GREEN}✅ 修改成功${RESET}"
                            else
                                echo -e "${RED}❌ 修改失败，已自动回滚${RESET}"
                            fi
                        else
                            echo -e "${RED}❌ 端口无效${RESET}"
                        fi
                        sleep 1
                    elif [[ "$op" == "3" ]]; then
                        if restart_named_service "xray" >/dev/null 2>&1; then
                            echo -e "${GREEN}✅ 已重启${RESET}"
                        else
                            echo -e "${RED}❌ 重启失败，请检查配置或日志${RESET}"
                        fi
                        sleep 1
                    elif [[ "$op" == "4" ]]; then
                        managed_service_destroy "xray"
                        sleep 1
                    fi
                fi
                ;;
            4)
                while true; do
                    clear 2>/dev/null || true
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

# 网络调优 Profiles（NAT/常规：稳定优先 vs 极致性能）
#   - NAT: 附带 journald 限制、SSH Keepalive、DNS 设置/锁定（可回滚）
#   - sysctl: 统一写入专用文件 + sysctl --system (要求)
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
    sysctl -e --system >/dev/null 2>&1 || true
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
        clear 2>/dev/null || true
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

run_daemon_check() {
    if managed_service_present "ss-rust" '/usr/local/bin/ss-rust -c /etc/ss-rust/config.json' "/var/run/ss-rust.pid" && ! service_is_running "ss-rust" '/usr/local/bin/ss-rust -c /etc/ss-rust/config.json' "/var/run/ss-rust.pid"; then
        restart_named_service "ss-rust" >/dev/null 2>&1 || true
    fi
    if managed_service_present "ss-v2ray" '/usr/local/bin/ss-rust -c /etc/ss-v2ray/config.json' "/var/run/ss-v2ray.pid" && ! service_is_running "ss-v2ray" '/usr/local/bin/ss-rust -c /etc/ss-v2ray/config.json' "/var/run/ss-v2ray.pid"; then
        restart_named_service "ss-v2ray" >/dev/null 2>&1 || true
    fi
    if managed_service_present "xray" '/usr/local/bin/xray run -c /usr/local/etc/xray/config.json' "/var/run/xray.pid" && ! service_is_running "xray" '/usr/local/bin/xray run -c /usr/local/etc/xray/config.json' "/var/run/xray.pid"; then
        restart_named_service "xray" >/dev/null 2>&1 || true
    fi
}

auto_clean() {
    local is_silent=$1
    if have_cmd apt-get; then
        apt-get autoremove -yqq >/dev/null 2>&1 || true
        apt-get clean -qq >/dev/null 2>&1 || true
    fi
    rm -rf /root/.cache/* /tmp/*.tar.xz /tmp/ssserver /tmp/ssr_update.sh /tmp/xray* /tmp/tmp.json /tmp/ssr-v2ray-plugin.* 2>/dev/null || true
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

    local latest; latest=$(cached_latest_tag "shadowsocks/shadowsocks-rust" "ss-rust")
    [[ -z "$latest" ]] && return 2

    local current; current=$(meta_get "SS_RUST_TAG" || true)
    [[ -z "$current" ]] && current=$(ss_rust_current_tag || true)
    [[ -n "$current" && "$current" == "$latest" ]] && return 3

    local tmpdir; tmpdir=$(mktemp -d /tmp/ssr-up-ssrust.XXXXXX)
    local tarball="${tmpdir}/ss-rust.tar.xz" candidate="${tmpdir}/ssserver" url="" ok=""

    if cache_restore_binary_tag "ss-rust" "$latest" "$candidate" && (run_with_timeout 3 "$candidate" --version >/dev/null 2>&1 || run_with_timeout 3 "$candidate" -V >/dev/null 2>&1); then
        ok=1
    else
        for candidate_arch in "$ss_arch_primary" "$ss_arch_fallback"; do
            local asset_name official_url api_url proxy_url
            asset_name="shadowsocks-${latest}.${candidate_arch}.tar.xz"
            official_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${latest}/${asset_name}"
            api_url=$(github_release_asset_url "shadowsocks/shadowsocks-rust" "$latest" "$asset_name" 2>/dev/null || true)
            proxy_url=$(github_proxy_wrap "$official_url")
            rm -f "$tarball" "$candidate" >/dev/null 2>&1 || true
            if ! download_file_any "$tarball" "$api_url" "$official_url" "$proxy_url" || [[ ! -s "$tarball" ]] || ! tar -tf "$tarball" >/dev/null 2>&1; then
                continue
            fi
            tar -xf "$tarball" -C "$tmpdir" ssserver >/dev/null 2>&1 || true
            [[ -x "$candidate" ]] || continue
            if run_with_timeout 3 "$candidate" --version >/dev/null 2>&1 || run_with_timeout 3 "$candidate" -V >/dev/null 2>&1; then
                ok=1
                break
            fi
        done
    fi
    [[ -n "$ok" ]] || { rm -rf "$tmpdir"; return 2; }

    activate_binary_with_rollback "ss-rust" "$latest" "$candidate" /usr/local/bin/ss-rust "SS_RUST_TAG" "ss-rust" "/usr/local/bin/ss-rust -c /etc/ss-rust/config.json" '/usr/local/bin/ss-rust -c /etc/ss-rust/config.json' "/var/log/ss-rust.log" "/var/run/ss-rust.pid"
    local rc=$?
    rm -rf "$tmpdir"
    return $rc
}

update_xray_if_needed() {
    [[ -x "/usr/local/bin/xray" ]] || return 1

    local arch; arch=$(uname -m)
    local xray_arch=""
    xray_arch=$(xray_linux_asset_arch "$arch")

    local latest; latest=$(xray_remote_latest_tag 2>/dev/null || true)
    if ! xray_tag_plausible "$latest"; then
        latest=$(xray_cached_or_latest_tag 2>/dev/null || true)
    fi
    if ! xray_tag_plausible "$latest"; then
        latest="$XRAY_FALLBACK_TAG"
    fi

    local current; current=$(meta_get "XRAY_TAG" || true)
    current=$(xray_normalize_tag "$current" 2>/dev/null || true)
    if ! xray_tag_plausible "$current"; then
        current=""
    fi
    [[ -z "$current" ]] && current=$(xray_current_tag || true)
    [[ -n "$latest" && -n "$current" && "$current" == "$latest" ]] && return 3

    local tmpdir; tmpdir=$(mktemp -d /tmp/ssr-up-xray.XXXXXX)
    local zipf="${tmpdir}/xray.zip" candidate="${tmpdir}/xray"
    local asset_name ok_tag=""
    local -a xray_urls=()
    asset_name=$(xray_release_asset_name "$xray_arch")
    mapfile -t xray_urls < <(xray_download_candidate_urls "$latest" "$asset_name" "$XRAY_FALLBACK_TAG")

    if [[ -n "$latest" ]] && cache_restore_binary_tag "xray" "$latest" "$candidate" && run_with_timeout 3 "$candidate" version >/dev/null 2>&1 && run_with_timeout 3 "$candidate" x25519 >/dev/null 2>&1; then
        ok_tag="$latest"
    else
        rm -f "$zipf" "$candidate" >/dev/null 2>&1 || true
        if ! xray_download_zip_any "$zipf" "${xray_urls[@]}"; then
            [[ -n "$XRAY_LAST_DOWNLOAD_URL" ]] && echo -e "${YELLOW}Xray 更新下载失败地址: ${XRAY_LAST_DOWNLOAD_URL}${RESET}" >&2
            [[ -n "$XRAY_LAST_DOWNLOAD_REASON" ]] && echo -e "${YELLOW}Xray 更新下载失败原因: ${XRAY_LAST_DOWNLOAD_REASON}${RESET}" >&2
            [[ -n "$XRAY_DOWNLOAD_LOG" ]] && echo -e "${YELLOW}Xray 更新下载诊断日志: ${XRAY_DOWNLOAD_LOG}${RESET}" >&2
            rm -rf "$tmpdir"
            return 2
        fi
        extract_xray_from_zip "$zipf" "$tmpdir" >/dev/null 2>&1 || true
        [[ -x "$candidate" ]] || { rm -rf "$tmpdir"; return 2; }
        run_with_timeout 3 "$candidate" version >/dev/null 2>&1 || { rm -rf "$tmpdir"; return 2; }
        run_with_timeout 3 "$candidate" x25519 >/dev/null 2>&1 || { rm -rf "$tmpdir"; return 2; }
        ok_tag=$(run_with_timeout 3 "$candidate" version 2>/dev/null | head -n1 | grep -oE '([0-9]+\.){2}[0-9]+' | head -n1)
        [[ -n "$ok_tag" ]] && ok_tag="v${ok_tag}" || ok_tag="$latest"
        xray_tag_plausible "$ok_tag" || ok_tag="$XRAY_FALLBACK_TAG"
    fi
    latest="$ok_tag"

    activate_binary_with_rollback "xray" "$latest" "$candidate" /usr/local/bin/xray "XRAY_TAG" "xray" "/usr/local/bin/xray run -c /usr/local/etc/xray/config.json" '/usr/local/bin/xray run -c /usr/local/etc/xray/config.json' "/var/log/xray.log" "/var/run/xray.pid"
    local rc=$?
    rm -rf "$tmpdir"
    return $rc
}

update_components_with_rollback() {
    local is_silent=$1
    local updated_any=0

    update_ss_rust_if_needed; local r1=$?
    update_xray_if_needed; local r3=$?

    [[ $r1 -eq 0 || $r3 -eq 0 ]] && updated_any=1

    if [[ "$is_silent" != "silent" ]]; then
        if [[ $updated_any -eq 1 ]]; then
            echo -e "${GREEN}✅ 核心组件已完成稳定更新（受控重启，失败自动回滚）。${RESET}"
        else
            echo -e "${GREEN}✅ 核心组件已是最新或无需更新。${RESET}"
        fi
        sleep 2
    fi
}

hot_update_components() {
    update_components_with_rollback "$@"
}

report_update_result() {
    local name="$1" rc="$2"
    case "$rc" in
        0) echo -e "${GREEN}✅ ${name} 已更新到最新版本。${RESET}" ;;
        1) echo -e "${YELLOW}⚠️ ${name} 当前未安装，跳过。${RESET}" ;;
        2) echo -e "${RED}❌ ${name} 更新失败。${RESET}" ;;
        3) echo -e "${GREEN}✅ ${name} 已是最新版本。${RESET}" ;;
        *) echo -e "${YELLOW}⚠️ ${name} 状态未知（返回码 ${rc}）。${RESET}" ;;
    esac
}

core_cache_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}========= 核心缓存与更新中心 =========${RESET}"
        echo
        echo -e "${GREEN} 1.${RESET} 更新 SS-Rust 核心"
        echo -e "${GREEN} 2.${RESET} 更新 Xray 核心"
        echo -e "${YELLOW} 3.${RESET} 一键更新全部核心"
        echo -e "${YELLOW} 4.${RESET} 清理全部核心缓存"
        echo -e " 0. 返回主菜单"
        read -rp "输入数字 [0-4]: " cache_num
        case "$cache_num" in
            1) update_ss_rust_if_needed; report_update_result "SS-Rust" "$?"; read -n 1 -s -r -p "按任意键继续..." ;;
            2) update_xray_if_needed; report_update_result "Xray" "$?"; read -n 1 -s -r -p "按任意键继续..." ;;
            3)
                update_ss_rust_if_needed; report_update_result "SS-Rust" "$?"
                update_xray_if_needed; report_update_result "Xray" "$?"
                read -n 1 -s -r -p "按任意键继续..."
                ;;
            4)
                core_cache_clear_all
                echo -e "${GREEN}✅ 本地核心缓存已清理。${RESET}"
                read -n 1 -s -r -p "按任意键继续..."
                ;;
            0) return ;;
        esac
    done
}

daily_task() {
    # 例行任务：仅清理，不自动更新核心（更新已独立到核心缓存与更新中心）
    auto_clean "silent"
}

# 完全卸载
ssr_cleanup_artifacts() {
    local svc
    for svc in ss-rust ss-v2ray xray; do
        managed_service_destroy "$svc" force 1 >/dev/null 2>&1 || true
    done

    [[ -f "$DDNS_CONF" ]] && remove_cf_ddns "force" 2>/dev/null || true
    rm -f /usr/local/bin/v2ray-plugin "$CONF_FILE" "$NAT_CONF_FILE" "$DDNS_CONF" "$DDNS_LOG" "$META_FILE" "$SS_V2RAY_STATE"
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


get_sshd_effective_value() {
    local key="$1" file value=""
    for file in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$file" ]] || continue
        local found
        found=$(awk -v key="$key" '
            $0 !~ /^[[:space:]]*#/ && tolower($1) == tolower(key) {
                $1=""
                sub(/^[[:space:]]+/, "")
                val=$0
            }
            END { if (val != "") print val }
        ' "$file" 2>/dev/null)
        [[ -n "$found" ]] && value="$found"
    done
    [[ -n "$value" ]] && printf %s "$value"
}

get_ssh_port_brief() {
    local port
    if have_cmd sshd && sshd -t >/dev/null 2>&1; then
        port=$(sshd_effective_port 2>/dev/null || true)
    else
        port=$(get_sshd_effective_value Port)
    fi
    [[ "$port" =~ ^[0-9]+$ ]] || port=22
    printf %s "$port"
}

get_ssh_auth_brief() {
    local pass pub has_keys="0"
    if have_cmd sshd && sshd -t >/dev/null 2>&1; then
        pass=$(sshd_effective_value_runtime passwordauthentication)
        pub=$(sshd_effective_value_runtime pubkeyauthentication)
    else
        pass=$(get_sshd_effective_value PasswordAuthentication)
        pub=$(get_sshd_effective_value PubkeyAuthentication)
    fi
    [[ -s "$ROOT_AUTH_KEYS_FILE" ]] && has_keys="1"
    [[ -z "$pass" ]] && pass="yes"
    [[ -z "$pub" ]] && pub="yes"
    pass=$(printf %s "$pass" | tr '[:upper:]' '[:lower:]')
    pub=$(printf %s "$pub" | tr '[:upper:]' '[:lower:]')
    if [[ "$pass" == "no" && "$pub" == "yes" ]]; then
        if [[ "$has_keys" == "1" ]]; then
            printf %s "仅密钥"
        else
            printf %s "配置异常"
        fi
    elif [[ "$pass" == "yes" && "$pub" == "yes" ]]; then
        if [[ "$has_keys" == "1" ]]; then
            printf %s "密码+密钥"
        else
            printf %s "密码登录"
        fi
    elif [[ "$pass" == "yes" ]]; then
        printf %s "仅密码"
    else
        printf %s "自定义"
    fi
}

get_dns_brief_status() {
    local immutable="0" attr
    if have_cmd lsattr; then
        attr=$(lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}')
        [[ "$attr" == *i* ]] && immutable="1"
    fi
    if [[ "$immutable" == "1" ]]; then
        printf %s "已锁定"
    elif [[ -f "$RESOLVED_DROPIN" ]]; then
        printf %s "resolved 托管"
    elif [[ -L /etc/resolv.conf ]]; then
        printf %s "系统托管"
    else
        printf %s "普通/自定义"
    fi
}

get_dns_servers_brief() {
    local dns_line="" servers=""
    if [[ -f "$RESOLVED_DROPIN" ]]; then
        dns_line=$(grep -E '^DNS=' "$RESOLVED_DROPIN" 2>/dev/null | tail -n1 | cut -d= -f2-)
        dns_line=$(printf '%s' "$dns_line" | xargs 2>/dev/null || printf '%s' "$dns_line")
        if [[ -n "$dns_line" ]]; then
            printf %s "$dns_line"
            return 0
        fi
    fi
    servers=$(awk '/^nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf 2>/dev/null | paste -sd ' ' -)
    servers=$(printf '%s' "$servers" | xargs 2>/dev/null || printf '%s' "$servers")
    if [[ -n "$servers" ]]; then
        printf %s "$servers"
    else
        printf %s "未探测到"
    fi
}

get_cf_ddns_brief_status() {
    if [[ -f "$DDNS_CONF" ]]; then
        local record
        record=$(grep -E '^CF_RECORD=' "$DDNS_CONF" 2>/dev/null | tail -n1 | cut -d= -f2- | sed 's/^"//; s/"$//')
        [[ -n "$record" ]] && printf %s "已启用(${record})" || printf %s "已启用"
    else
        printf %s "未启用"
    fi
}

quic_state_init_if_needed() {
    state_dir_ensure "$SSR_STATE_DIR" >/dev/null 2>&1 || true
    touch "$QUIC_STATE_FILE" >/dev/null 2>&1 || true
    chmod 600 "$QUIC_STATE_FILE" >/dev/null 2>&1 || true
}

quic_meta_get() {
    local key="$1"
    quic_state_init_if_needed
    state_kv_get "$QUIC_STATE_FILE" "$key"
}

quic_meta_set() {
    local key="$1" value="$2"
    quic_state_init_if_needed
    state_kv_set "$QUIC_STATE_FILE" "$key" "$value"
}

quic_rule_blocked_ufw() {
    have_cmd ufw || return 1
    ufw status 2>/dev/null | grep -F '443/udp' | grep -qi 'DENY'
}

quic_rule_blocked_firewalld() {
    have_cmd firewall-cmd || return 1
    firewall-cmd --permanent --list-rich-rules 2>/dev/null | grep -q 'port="443" protocol="udp" drop'
}

quic_rule_blocked_iptables() {
    have_cmd iptables && iptables -C INPUT -p udp --dport 443 -j DROP >/dev/null 2>&1 && return 0
    have_cmd iptables && iptables -C OUTPUT -p udp --dport 443 -j DROP >/dev/null 2>&1 && return 0
    have_cmd ip6tables && ip6tables -C INPUT -p udp --dport 443 -j DROP >/dev/null 2>&1 && return 0
    have_cmd ip6tables && ip6tables -C OUTPUT -p udp --dport 443 -j DROP >/dev/null 2>&1 && return 0
    return 1
}

quic_rule_blocked_nft() {
    have_cmd nft || return 1
    nft list table inet "$QUIC_NFT_TABLE" >/dev/null 2>&1 || return 1
    nft list table inet "$QUIC_NFT_TABLE" 2>/dev/null | grep -q "$QUIC_RULE_COMMENT"
}

quic_detect_block_backend() {
    if quic_rule_blocked_ufw; then
        printf %s "ufw"
    elif quic_rule_blocked_firewalld; then
        printf %s "firewalld"
    elif quic_rule_blocked_nft; then
        printf %s "nftables"
    elif quic_rule_blocked_iptables; then
        printf %s "iptables"
    else
        printf %s "none"
    fi
}

get_quic_backend() {
    local actual saved
    actual=$(quic_detect_block_backend)
    if [[ "$actual" != "none" ]]; then
        printf %s "$actual"
        return 0
    fi
    saved=$(quic_meta_get BACKEND 2>/dev/null || true)
    case "$saved" in
        ufw|firewalld|nftables|iptables) printf %s "$saved" ;;
        *) printf %s "none" ;;
    esac
}

get_quic_state() {
    local actual
    actual=$(quic_detect_block_backend)
    if [[ "$actual" != "none" ]]; then
        printf %s "blocked"
    else
        printf %s "open"
    fi
}

get_quic_status_brief() {
    local state backend managed
    state=$(get_quic_state)
    backend=$(get_quic_backend)
    managed=$(quic_meta_get MANAGED 2>/dev/null || true)
    if [[ "$state" == "blocked" ]]; then
        printf %s "已阻断(${backend})"
    else
        if [[ "$backend" == "none" ]]; then
            printf %s "默认放行(未托管)"
        elif [[ "$managed" == "1" ]]; then
            printf %s "已放行(${backend})"
        else
            printf %s "默认放行(${backend})"
        fi
    fi
}

count_proxy_nodes_brief() {
    local c=0 name
    for name in ss-rust ss-v2ray xray; do
        managed_service_exists "$name" && c=$((c+1))
    done
    printf %s "$c"
}

get_nft_rules_brief() {
    local c=0
    if [[ -f "$CONFIG_FILE" ]]; then
        c=$(grep -cvE '^[[:space:]]*($|#)' "$CONFIG_FILE" 2>/dev/null || echo 0)
    fi
    printf %s "$c"
}

get_nginx_domains_brief() {
    local c=0
    if [[ -d /etc/nginx/sites-enabled ]]; then
        c=$(find /etc/nginx/sites-enabled -maxdepth 1 \( -type l -o -type f \) ! -name default 2>/dev/null | wc -l)
        c=${c//[[:space:]]/}
    fi
    printf %s "$c"
}

get_nginx_status_brief() {
    local domains
    domains=$(get_nginx_domains_brief)
    if systemctl is-active --quiet nginx 2>/dev/null; then
        printf %s "运行中(${domains}站点)"
    elif [[ "$domains" =~ ^[0-9]+$ && "$domains" -gt 0 ]]; then
        printf %s "已配${domains}站点/未运行"
    else
        printf %s "未启用"
    fi
}

select_quic_backend() {
    if have_cmd ufw && ufw status 2>/dev/null | grep -qw active; then
        printf %s "ufw"
    elif have_cmd firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
        printf %s "firewalld"
    elif have_cmd iptables || have_cmd ip6tables; then
        printf %s "iptables"
    elif have_cmd nft; then
        printf %s "nftables"
    else
        printf %s "none"
    fi
}

quic_apply_backend() {
    local backend="$1" action="$2"
    case "$backend" in
        ufw)
            if [[ "$action" == "block" ]]; then
                ufw deny in 443/udp >/dev/null 2>&1
                ufw deny out 443/udp >/dev/null 2>&1
            else
                ufw delete deny in 443/udp >/dev/null 2>&1
                ufw delete deny out 443/udp >/dev/null 2>&1
            fi
            ufw reload >/dev/null 2>&1
            ;;
        firewalld)
            if [[ "$action" == "block" ]]; then
                firewall-cmd --permanent --add-rich-rule='rule family="ipv4" port port="443" protocol="udp" drop' >/dev/null 2>&1
                firewall-cmd --permanent --add-rich-rule='rule family="ipv6" port port="443" protocol="udp" drop' >/dev/null 2>&1
            else
                firewall-cmd --permanent --remove-rich-rule='rule family="ipv4" port port="443" protocol="udp" drop' >/dev/null 2>&1
                firewall-cmd --permanent --remove-rich-rule='rule family="ipv6" port port="443" protocol="udp" drop' >/dev/null 2>&1
            fi
            firewall-cmd --reload >/dev/null 2>&1
            ;;
        iptables)
            if [[ "$action" == "block" ]]; then
                have_cmd iptables && iptables -I INPUT -p udp --dport 443 -j DROP 2>/dev/null || true
                have_cmd iptables && iptables -I OUTPUT -p udp --dport 443 -j DROP 2>/dev/null || true
                have_cmd ip6tables && ip6tables -I INPUT -p udp --dport 443 -j DROP 2>/dev/null || true
                have_cmd ip6tables && ip6tables -I OUTPUT -p udp --dport 443 -j DROP 2>/dev/null || true
                have_cmd netfilter-persistent && netfilter-persistent save >/dev/null 2>&1 || true
            else
                if have_cmd iptables; then
                    while iptables -D INPUT -p udp --dport 443 -j DROP 2>/dev/null; do :; done
                    while iptables -D OUTPUT -p udp --dport 443 -j DROP 2>/dev/null; do :; done
                fi
                if have_cmd ip6tables; then
                    while ip6tables -D INPUT -p udp --dport 443 -j DROP 2>/dev/null; do :; done
                    while ip6tables -D OUTPUT -p udp --dport 443 -j DROP 2>/dev/null; do :; done
                fi
                have_cmd netfilter-persistent && netfilter-persistent save >/dev/null 2>&1 || true
            fi
            ;;
        nftables)
            if [[ "$action" == "block" ]]; then
                nft list table inet "$QUIC_NFT_TABLE" >/dev/null 2>&1 && nft delete table inet "$QUIC_NFT_TABLE" >/dev/null 2>&1 || true
                nft add table inet "$QUIC_NFT_TABLE" >/dev/null 2>&1 || return 1
                nft 'add chain inet '"$QUIC_NFT_TABLE"' input { type filter hook input priority 0; policy accept; }' >/dev/null 2>&1 || return 1
                nft 'add chain inet '"$QUIC_NFT_TABLE"' output { type filter hook output priority 0; policy accept; }' >/dev/null 2>&1 || return 1
                nft add rule inet "$QUIC_NFT_TABLE" input udp dport 443 drop comment "$QUIC_RULE_COMMENT" >/dev/null 2>&1 || return 1
                nft add rule inet "$QUIC_NFT_TABLE" output udp dport 443 drop comment "$QUIC_RULE_COMMENT" >/dev/null 2>&1 || return 1
            else
                nft list table inet "$QUIC_NFT_TABLE" >/dev/null 2>&1 && nft delete table inet "$QUIC_NFT_TABLE" >/dev/null 2>&1 || true
            fi
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

quic_unblock_all_backends() {
    quic_apply_backend "ufw" "unblock" || true
    quic_apply_backend "firewalld" "unblock" || true
    quic_apply_backend "iptables" "unblock" || true
    quic_apply_backend "nftables" "unblock" || true
}

manage_quic_udp443() {
    local action="$1" backend actual
    if [[ "$action" == "block" ]]; then
        backend=$(select_quic_backend)
        if [[ "$backend" == "none" ]]; then
            echo -e "${RED}❌ 未找到可用防火墙后端（ufw / firewalld / iptables / nftables）。${RESET}"
            sleep 2
            return 1
        fi
        quic_apply_backend "$backend" "block" || true
        actual=$(quic_detect_block_backend)
        if [[ "$actual" == "none" ]]; then
            echo -e "${RED}❌ UDP 443 阻断未生效：后端 ${backend} 未成功写入规则。${RESET}"
            sleep 2
            return 1
        fi
        quic_meta_set MANAGED 1
        quic_meta_set BACKEND "$actual"
        quic_meta_set LAST_ACTION block
        echo -e "${GREEN}✅ 已成功阻断 UDP 443 端口 (QUIC 已关闭) / 后端: ${actual}${RESET}"
    else
        backend=$(get_quic_backend)
        quic_unblock_all_backends
        actual=$(quic_detect_block_backend)
        if [[ "$actual" != "none" ]]; then
            echo -e "${RED}❌ UDP 443 放行未完全生效：当前仍检测到阻断后端 ${actual}。${RESET}"
            sleep 2
            return 1
        fi
        case "$backend" in
            ufw|firewalld|iptables|nftables) quic_meta_set MANAGED 1; quic_meta_set BACKEND "$backend" ;;
            *) quic_meta_set MANAGED 0; quic_meta_set BACKEND none ;;
        esac
        quic_meta_set LAST_ACTION unblock
        echo -e "${GREEN}✅ 已成功放行 UDP 443 端口 (QUIC 已开启)。${RESET}"
    fi
    sleep 2
}

quic_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}========= QUIC 防火墙管理 (防 QoS) =========${RESET}"
        echo -e "${YELLOW}说明：阻断 UDP 443 可有效防止运营商对 UDP 流量的 QoS 和阻断，${RESET}"
        echo -e "${YELLOW}      强制科学代理流量回退至更稳定的 TCP 协议。${RESET}"
        echo -e "------------------------------------------------"
        echo -e "${RED} 1.${RESET} 一键阻断 UDP 443 (关闭 QUIC - 推荐稳定)${RESET}"
        echo -e "${GREEN} 2.${RESET} 一键放行 UDP 443 (开启 QUIC - 默认状态)${RESET}"
        echo -e " 0. 返回上一级"
        read -rp "请选择 [0-2]: " q_num
        case "$q_num" in
            1) manage_quic_udp443 "block" ;;
            2) manage_quic_udp443 "unblock" ;;
            0) return ;;
            *) echo -e "${RED}无效选项${RESET}"; sleep 1 ;;
        esac
    done
}

# =======================================================
# 系统菜单
# =======================================================
# 系统菜单
sys_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}================== 系统基础与极客管理 ==================${RESET}"
        echo -e "--------------------------------------------------------"
        echo -e "  ${YELLOW}1.${RESET} SSH 端口管理               ${GREEN}5.${RESET} Cloudflare DDNS 管理"
        echo -e "  ${YELLOW}2.${RESET} Root 密码修改              ${YELLOW}6.${RESET} DNS 管理中心（智能/锁定/恢复）"
        echo -e "  ${YELLOW}3.${RESET} 服务器时间防偏移同步       ${RED}7.${RESET} QUIC / UDP 443 防火墙管理"
        echo -e "  ${YELLOW}4.${RESET} SSH 密钥登录管理中心"
        echo -e "  0. 返回上级菜单"
        echo -e "${CYAN}========================================================${RESET}"
        read -rp "请输入数字 [0-7]: " sys_num
        case "$sys_num" in
            1) change_ssh_port ;;
            2) change_root_password ;;
            3) sync_server_time ;;
            4) ssh_key_menu ;;
            5) cf_ddns_menu ;;
            6) dns_menu ;;
            7) quic_menu ;;
            0) return ;;
            *) echo -e "${RED}无效选项${RESET}"; sleep 1 ;;
        esac
    done
}

SSR_MODULE_EOF
mv -f "${SSR_MODULE_FILE}.tmp" "${SSR_MODULE_FILE}"

    # NFT 模块（已移除脚本自更新/卸载菜单，并适配 my 统一管理）
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
# 持久化兼容模式（解决部分“节点管理/面板”只认 /etc/nftables.conf 的问题）
#  - service: 使用 nft-mgr oneshot service 加载 /etc/nftables.d/nft_mgr.conf（默认，最不干扰系统）
#  - system : 向 /etc/nftables.conf 注入 include "/etc/nftables.d/nft_mgr.conf" 并用 nftables.service 持久化（兼容性更好）
NFTABLES_CONF="/etc/nftables.conf"
NFTABLES_CREATED_MARK="/etc/nftables.conf.nftmgr_created"
PERSIST_MODE_DEFAULT="service"
NFT_MGR_CONF="${NFT_MGR_DIR}/nft_mgr.conf"
COMMON_MODULE_FILE="${MY_INSTALL_DIR:-/usr/local/lib/my}/common_module.sh"
[[ -f "$COMMON_MODULE_FILE" ]] && source "$COMMON_MODULE_FILE"
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
        sed -i "s|^${key}=.*|${key}=\"${value}\"|g" "$SETTINGS_FILE"
    else
        echo "${key}=\"${value}\"" >> "$SETTINGS_FILE"
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

    # 依赖：nft/curl/flock/ss（域名解析允许 dig/getent/host/nslookup 任一）
    if [[ "$mgr" == "apt" ]]; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -yqq nftables dnsutils curl util-linux iproute2 >/dev/null 2>&1 || true
    else
        # dnf/yum
        "$mgr" install -y nftables bind-utils curl util-linux iproute >/dev/null 2>&1 || true
    fi
}

have_dns_resolver() {
    have_cmd dig || have_cmd getent || have_cmd host || have_cmd nslookup
}

check_env() {
    # 自动装依赖（尽量温和），dig 不再作为必需项，避免仅因缺少 dnsutils 就卡在进入菜单时
    local need=0
    for c in nft curl flock ss sysctl; do
        have_cmd "$c" || need=1
    done
    [[ $need -eq 1 ]] && install_deps

    # 再次检查关键依赖
    for c in nft curl flock ss sysctl; do
        have_cmd "$c" || msg_warn "⚠️ 未找到依赖命令: $c（部分功能可能不可用）"
    done
    have_dns_resolver || msg_warn "⚠️ 未找到 dig/getent/host/nslookup，域名转发将不可用。"

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

# --------------------------
# DNS 解析
# --------------------------
get_ip() {
    local addr="$1"
    resolve_ipv4_first "$addr"
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

nft_system_cpu_count() {
    getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
}

nft_system_nofile_hard() {
    local n
    n="$(sh -c 'ulimit -Hn' 2>/dev/null || true)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=65535
    echo "$n"
}

nft_tier_step_up() {
    case "$1" in
        tiny) echo small ;;
        small) echo medium ;;
        medium) echo large ;;
        *) echo large ;;
    esac
}

nft_detect_machine_tier() {
    local mem_mb cpu nofile tier
    mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    cpu="$(nft_system_cpu_count)"
    nofile="$(nft_system_nofile_hard)"
    [[ "$mem_mb" =~ ^[0-9]+$ ]] || mem_mb=1024
    [[ "$cpu" =~ ^[0-9]+$ ]] || cpu=1
    [[ "$nofile" =~ ^[0-9]+$ ]] || nofile=65535

    if (( mem_mb < 1024 || cpu <= 1 )); then
        tier=tiny
    elif (( mem_mb < 4096 || cpu <= 2 )); then
        tier=small
    elif (( mem_mb < 8192 || cpu <= 4 )); then
        tier=medium
    else
        tier=large
    fi

    if (( nofile >= 1048576 && mem_mb >= 4096 && cpu >= 4 )); then
        tier="$(nft_tier_step_up "$tier")"
    fi

    echo "$tier"
}

nft_cc_available_list() {
    sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true
}

nft_cc_in_list() {
    local cc="$1" avail="${2:-$(nft_cc_available_list)}"
    [[ " $avail " == *" ${cc} "* ]]
}

nft_try_activate_bbr_stack() {
    modprobe -q sch_fq >/dev/null 2>&1 || true
    modprobe -q tcp_bbr >/dev/null 2>&1 || true
}

nft_best_congestion_control() {
    local avail current
    avail="$(nft_cc_available_list)"
    if nft_cc_in_list bbr "$avail"; then
        echo bbr
        return 0
    fi

    nft_try_activate_bbr_stack
    avail="$(nft_cc_available_list)"
    if nft_cc_in_list bbr "$avail"; then
        echo bbr
        return 0
    fi

    for cc in cubic reno; do
        nft_cc_in_list "$cc" "$avail" && { echo "$cc"; return 0; }
    done

    current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    [[ -n "$current" ]] && echo "$current" || echo cubic
}

nft_best_default_qdisc() {
    local cc="${1:-$(nft_best_congestion_control)}" current_qdisc
    if [[ "$cc" == "bbr" ]]; then
        modprobe -q sch_fq >/dev/null 2>&1 || true
        echo fq
        return 0
    fi
    current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    [[ -n "$current_qdisc" ]] && echo "$current_qdisc" || echo fq_codel
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
        sysctl -e --system >/dev/null 2>&1 || sysctl -e -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    fi
}

is_loopback_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^127\.([0-9]{1,3}\.){2}[0-9]{1,3}$ ]]
}

nft_primary_uplink_iface() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}'
}

nft_config_requires_route_localnet() {
    local lp addr tp last_ip proto ip
    while IFS='|' read -r lp addr tp last_ip proto; do
        [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
        ip="$last_ip"
        [[ -z "$ip" ]] && ip="$(get_ip "$addr")"
        is_loopback_ipv4 "$ip" && return 0
    done < "$CONFIG_FILE"
    return 1
}

nft_enable_route_localnet() {
    local iface key val
    mkdir -p /etc/sysctl.d 2>/dev/null || true
    touch "$SYSCTL_FILE" 2>/dev/null || true

    for key in net.ipv4.conf.all.route_localnet net.ipv4.conf.default.route_localnet; do
        nft_sysctl_key_supported "$key" || continue
        if grep -qE "^\s*${key//./\.}\s*=" "$SYSCTL_FILE" 2>/dev/null; then
            sed -i "s|^\s*${key//./\.}\s*=.*|${key} = 1|g" "$SYSCTL_FILE"
        else
            echo "${key} = 1" >> "$SYSCTL_FILE"
        fi
        sysctl -w "${key}=1" >/dev/null 2>&1 || true
    done

    iface="$(nft_primary_uplink_iface)"
    if [[ -n "$iface" ]]; then
        key="net.ipv4.conf.${iface}.route_localnet"
        if nft_sysctl_key_supported "$key"; then
            if grep -qE "^\s*${key//./\.}\s*=" "$SYSCTL_FILE" 2>/dev/null; then
                sed -i "s|^\s*${key//./\.}\s*=.*|${key} = 1|g" "$SYSCTL_FILE"
            else
                echo "${key} = 1" >> "$SYSCTL_FILE"
            fi
            sysctl -w "${key}=1" >/dev/null 2>&1 || true
        fi
    fi

    sysctl -e --system >/dev/null 2>&1 || sysctl -e -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
}

nft_apply_profile() {
    local mode="$(nft_profile_alias "${1:-stable}")" tier cc qdisc
    local somax backlog filemax rmax wmax fin_timeout conntrack
    tier="$(nft_detect_machine_tier)"
    cc="$(nft_best_congestion_control)"
    qdisc="$(nft_best_default_qdisc "$cc")"

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
    nft_write_sysctl_line "$SYSCTL_FILE" "net.core.default_qdisc" "$qdisc"
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

    sysctl -e --system >/dev/null 2>&1 || sysctl -e -p "$SYSCTL_FILE" >/dev/null 2>&1 || true

    if have_cmd systemctl; then
        systemctl enable --now nftables >/dev/null 2>&1 || true
        ensure_nft_mgr_service
    fi
    auto_persist_setup

    msg_ok "✅ 已应用 NFT 智能调优：$(nft_profile_title "$mode") / ${tier} / ${cc}"
    sleep 2
}

optimize_system() {
    clear 2>/dev/null || true
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
    nft_config_requires_route_localnet && nft_enable_route_localnet
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

    if is_loopback_ipv4 "$tip"; then
        msg_info "检测到目标为本地回环地址 ${tip}：将自动开启 route_localnet 以允许外部流量 DNAT 到本机回环服务。"
    fi

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
    clear 2>/dev/null || true
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
    clear 2>/dev/null || true
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
            clear 2>/dev/null || true
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
    clear 2>/dev/null || true
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
# 菜单拆分
# --------------------------
count_forward_rules_brief() {
    local c=0
    if [[ -f "$CONFIG_FILE" ]]; then
        c=$(grep -cvE '^[[:space:]]*($|#)' "$CONFIG_FILE" 2>/dev/null || echo 0)
    fi
    printf %s "$c"
}

nft_rule_center_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${GREEN}==========================================${PLAIN}"
        echo -e "${GREEN}                NFT 规则中心               ${PLAIN}"
        echo -e "${GREEN}==========================================${PLAIN}"
        echo "1. 新增端口转发 (支持域名/IP，支持TCP/UDP选择)"
        echo "2. 规则管理 (查看/删除)"
        echo "3. 清空所有转发规则"
        echo "0. 返回上一级"
        echo "------------------------------------------"
        local choice
        read -rp "请选择操作 [0-3]: " choice
        case "$choice" in
            1) add_forward ;;
            2) view_and_del_forward ;;
            3) clear_all_rules ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

nft_tools_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${GREEN}==========================================${PLAIN}"
        echo -e "${GREEN}             NFT 工具与维护中心            ${PLAIN}"
        echo -e "${GREEN}==========================================${PLAIN}"
        echo "1. 智能系统调优 (稳定/极致)"
        echo "2. 管理 DDNS 定时监控与日志"
        echo "0. 返回上一级"
        echo "------------------------------------------"
        local choice
        read -rp "请选择操作 [0-2]: " choice
        case "$choice" in
            1) optimize_system ;;
            2) manage_cron ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

# --------------------------
# 主菜单
# --------------------------
main_menu() {
    clear 2>/dev/null || true
    echo -e "${GREEN}==========================================${PLAIN}"
    echo -e "${GREEN}     nftables 端口转发管理面板 (Pro)      ${PLAIN}"
    echo -e "${GREEN}==========================================${PLAIN}"
    echo "1. NFT 规则中心"
    echo "2. NFT 工具与维护中心"
    echo "0. 退出面板"
    echo "------------------------------------------"
    local choice
    read -rp "请选择操作 [0-2]: " choice

    case "$choice" in
        1) nft_rule_center_menu ;;
        2) nft_tools_menu ;;
        0) exit 0 ;;
        *) msg_err "无效选项"; sleep 1 ;;
    esac
}

NFT_MODULE_EOF
mv -f "${NFT_MODULE_FILE}.tmp" "${NFT_MODULE_FILE}"

    # Nginx 反向代理模块（并入 my 统一管理，避免与 Certbot/多站点冲突）
    cat > "${NGX_MODULE_FILE}.tmp" <<'NGX_MODULE_EOF'
#!/bin/bash
set -o pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly RESET='\033[0m'

readonly MY_NGX_ID="my-nginx-proxy"
readonly NGX_STATE_DIR="${MY_STATE_DIR:-/usr/local/lib/my/state}/nginx"
readonly LEGACY_NGX_STATE_DIR="/usr/local/etc/my_nginx_proxy"
readonly NGX_META_DIR="${NGX_STATE_DIR}"
readonly NGX_STATE_FILE="${NGX_STATE_DIR}/state.conf"
readonly NGX_COMMON_CONF="/etc/nginx/conf.d/00-my-rproxy-common.conf"
readonly NGX_CONF_PREFIX="/etc/nginx/conf.d/my-rproxy"
readonly NGX_WEBROOT="/var/lib/my-nginx-proxy/acme"
readonly NGX_WORKDIR="/var/lib/my-nginx-proxy"
readonly NGX_TMP_DIR="${NGX_WORKDIR}/tmp"
readonly NGX_LOG_DIR="/var/log/nginx"

ngx_have_cmd() { command -v "$1" >/dev/null 2>&1; }
ngx_certbot_deploy_hook_cmd() {
    cat <<'EOF'
sh -c 'if command -v nginx >/dev/null 2>&1; then nginx -s reload >/dev/null 2>&1 && exit 0; fi; if command -v systemctl >/dev/null 2>&1; then systemctl reload nginx >/dev/null 2>&1 && exit 0; systemctl restart nginx >/dev/null 2>&1 && exit 0; fi; if command -v service >/dev/null 2>&1; then service nginx reload >/dev/null 2>&1 && exit 0; service nginx restart >/dev/null 2>&1 && exit 0; fi; if command -v rc-service >/dev/null 2>&1; then rc-service nginx reload >/dev/null 2>&1 && exit 0; rc-service nginx restart >/dev/null 2>&1 && exit 0; fi; exit 0'
EOF
}
ngx_msg_ok() { echo -e "${GREEN}$*${RESET}"; }
ngx_msg_warn() { echo -e "${YELLOW}$*${RESET}"; }
ngx_msg_err() { echo -e "${RED}$*${RESET}"; }
ngx_msg_info() { echo -e "${CYAN}$*${RESET}"; }
ngx_pause() { read -n 1 -s -r -p "按任意键继续..."; echo; }

ngx_system_memory_mb() {
    awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null
}

ngx_system_cpu_count() {
    getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
}

ngx_system_nofile_hard() {
    local n
    n="$(sh -c 'ulimit -Hn' 2>/dev/null || true)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=65535
    echo "$n"
}

ngx_detect_machine_tier() {
    local mem cpu nofile
    mem="$(ngx_system_memory_mb)"
    cpu="$(ngx_system_cpu_count)"
    nofile="$(ngx_system_nofile_hard)"
    [[ "$mem" =~ ^[0-9]+$ ]] || mem=1024
    [[ "$cpu" =~ ^[0-9]+$ ]] || cpu=1
    [[ "$nofile" =~ ^[0-9]+$ ]] || nofile=65535

    if (( mem < 2048 || cpu <= 1 )); then
        echo small
    elif (( mem < 8192 || cpu <= 4 )); then
        echo medium
    elif (( nofile >= 262144 )); then
        echo large
    else
        echo medium
    fi
}

ngx_pick_perf_profile() {
    local tier="$(ngx_detect_machine_tier)"
    case "$tier" in
        small)  echo "$tier 4096 65535 65535" ;;
        medium) echo "$tier 8192 262144 262144" ;;
        large)  echo "$tier 16384 524288 524288" ;;
        *)      echo "medium 8192 262144 262144" ;;
    esac
}

ngx_state_get() {
    local key="$1"
    state_kv_get "$NGX_STATE_FILE" "$key"
}

ngx_state_set() {
    local key="$1" value="$2"
    state_kv_set "$NGX_STATE_FILE" "$key" "$value"
}

ngx_pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

ngx_state_init_if_needed() {
    state_dir_ensure "$NGX_STATE_DIR" >/dev/null 2>&1 || true
    state_migrate_dir "$LEGACY_NGX_STATE_DIR" "$NGX_STATE_DIR" >/dev/null 2>&1 || true
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

ngx_patch_main_conf() {
    local conf="/etc/nginx/nginx.conf" worker_conn="$1" worker_rlimit="$2" tmp
    [[ -f "$conf" ]] || return 1
    tmp="$(mktemp "${NGX_TMP_DIR}/nginx.conf.XXXXXX")" || return 1
    awk -v wc="$worker_conn" -v wr="$worker_rlimit" '
        BEGIN { in_events=0; saw_events=0; saw_rl=0; events_wc_done=0 }
        /^[[:space:]]*worker_rlimit_nofile[[:space:]]+[0-9]+;/ {
            if (!saw_rl) {
                print "worker_rlimit_nofile " wr ";"
                saw_rl=1
            }
            next
        }
        {
            line=$0
            if (!saw_rl && line ~ /^[[:space:]]*worker_processes[[:space:]]+/) {
                print line
                print "worker_rlimit_nofile " wr ";"
                saw_rl=1
                next
            }
            if (line ~ /^[[:space:]]*events[[:space:]]*\{/) {
                in_events=1
                saw_events=1
                events_wc_done=0
            }
            if (in_events && line ~ /^[[:space:]]*worker_connections[[:space:]]+[0-9]+;/) {
                print "    worker_connections " wc ";"
                events_wc_done=1
                next
            }
            if (in_events && line ~ /^[[:space:]]*}/) {
                if (!events_wc_done) {
                    print "    worker_connections " wc ";"
                    events_wc_done=1
                }
                print line
                in_events=0
                next
            }
            print line
        }
        END {
            if (!saw_rl) {
                print "worker_rlimit_nofile " wr ";"
            }
            if (!saw_events) {
                print "events {"
                print "    worker_connections " wc ";"
                print "}"
            }
        }
    ' "$conf" > "$tmp" || { rm -f "$tmp"; return 1; }
    install -m 644 "$tmp" "$conf" 2>/dev/null || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

ngx_apply_runtime_profile() {
    local tier worker_conn worker_rlimit limit_nofile
    local conf="/etc/nginx/nginx.conf"
    local conf_bak="${NGX_TMP_DIR}/nginx.conf.bak"
    local override_dir="/etc/systemd/system/nginx.service.d"
    local override_file="${override_dir}/override.conf"
    local override_tmp="${NGX_TMP_DIR}/nginx.override.tmp"
    local override_bak="${NGX_TMP_DIR}/nginx.override.bak"
    local had_override=0

    read -r tier worker_conn worker_rlimit limit_nofile <<EOF
$(ngx_pick_perf_profile)
EOF

    [[ -f "$conf" ]] || return 0
    mkdir -p "$NGX_TMP_DIR" "$override_dir" 2>/dev/null || true
    cp -f "$conf" "$conf_bak" 2>/dev/null || return 1
    if [[ -f "$override_file" ]]; then
        had_override=1
        cp -f "$override_file" "$override_bak" 2>/dev/null || true
    fi

    if ! ngx_patch_main_conf "$worker_conn" "$worker_rlimit"; then
        cp -f "$conf_bak" "$conf" 2>/dev/null || true
        return 1
    fi

    cat > "$override_tmp" <<EOF
[Service]
LimitNOFILE=${limit_nofile}
EOF
    install -m 644 "$override_tmp" "$override_file" 2>/dev/null || { cp -f "$conf_bak" "$conf" 2>/dev/null || true; rm -f "$override_tmp"; return 1; }
    rm -f "$override_tmp"
    systemctl daemon-reload >/dev/null 2>&1 || true

    if ! nginx -t >/dev/null 2>&1; then
        cp -f "$conf_bak" "$conf" 2>/dev/null || true
        if (( had_override )); then
            cp -f "$override_bak" "$override_file" 2>/dev/null || true
        else
            rm -f "$override_file" 2>/dev/null || true
        fi
        systemctl daemon-reload >/dev/null 2>&1 || true
        return 1
    fi

    if ! systemctl reload nginx >/dev/null 2>&1 && ! systemctl restart nginx >/dev/null 2>&1; then
        cp -f "$conf_bak" "$conf" 2>/dev/null || true
        if (( had_override )); then
            cp -f "$override_bak" "$override_file" 2>/dev/null || true
        else
            rm -f "$override_file" 2>/dev/null || true
        fi
        systemctl daemon-reload >/dev/null 2>&1 || true
        nginx -t >/dev/null 2>&1 || true
        systemctl reload nginx >/dev/null 2>&1 || true
        return 1
    fi

    ngx_state_set NGINX_TIER "$tier"
    ngx_state_set NGINX_WORKER_CONNECTIONS "$worker_conn"
    ngx_state_set NGINX_LIMIT_NOFILE "$limit_nofile"
    ngx_msg_ok "已按 ${tier} 档应用 Nginx 并发参数：worker_connections=${worker_conn}, LimitNOFILE=${limit_nofile}"
    return 0
}

ngx_write_common_conf() {
    mkdir -p /etc/nginx/conf.d "$NGX_WEBROOT" "$NGX_TMP_DIR" "$NGX_META_DIR" 2>/dev/null || true
    chmod 755 "$NGX_WEBROOT" 2>/dev/null || true
    cat > "$NGX_COMMON_CONF" <<'EOF'
# managed-by=my-nginx-proxy
server_names_hash_bucket_size 128;
server_names_hash_max_size 4096;
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
    if ! ngx_apply_runtime_profile; then
        ngx_msg_warn "Nginx 并发优化应用失败，已回滚到原配置。"
    fi
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

ngx_ipv6_supported() {
    [[ -s /proc/net/if_inet6 ]]
}

ngx_render_http_conf() {
    local domain="$1" v6_http=""
    if ngx_ipv6_supported; then
        v6_http='    listen [::]:80;'
    fi
    cat <<EOF
# managed-by=${MY_NGX_ID}
# domain=${domain}
# backend=${NGX_BACKEND_RAW}
server {
    listen 80;
${v6_http}
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
    local domain="$1" v6_http="" v6_https=""
    if ngx_ipv6_supported; then
        v6_http='    listen [::]:80;'
        v6_https='    listen [::]:443 ssl http2 fastopen=256;'
    fi
    cat <<EOF
# managed-by=${MY_NGX_ID}
# domain=${domain}
# backend=${NGX_BACKEND_RAW}
server {
    listen 80;
${v6_http}
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
    listen 443 ssl http2 fastopen=256;
${v6_https}
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

_ngx_reload_quiet() {
    ngx_test_reload >/dev/null 2>&1 || true
}

ngx_apply_conf_file_txn() {
    local conf="$1" src="$2" txn
    [[ -n "$conf" && -f "$src" ]] || return 1
    txn="$(txn_begin)" || return 1
    txn_register "$txn" _ngx_reload_quiet
    txn_backup_file "$txn" "$conf" >/dev/null || { txn_abort "$txn"; return 1; }
    install -m 644 "$src" "$conf" 2>/dev/null || { txn_abort "$txn"; return 1; }
    if ngx_test_reload; then
        txn_commit "$txn"
        return 0
    fi
    txn_abort "$txn"
    return 1
}

ngx_remove_conf_txn() {
    local conf="$1" txn
    [[ -n "$conf" ]] || return 1
    txn="$(txn_begin)" || return 1
    txn_register "$txn" _ngx_reload_quiet
    txn_backup_file "$txn" "$conf" >/dev/null || { txn_abort "$txn"; return 1; }
    rm -f "$conf" 2>/dev/null || { txn_abort "$txn"; return 1; }
    if ngx_test_reload; then
        txn_commit "$txn"
        return 0
    fi
    txn_abort "$txn"
    return 1
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

    if ngx_remove_conf_txn "$conf"; then
        ngx_delete_cert_if_exists "$domain"
        rm -f "${NGX_LOG_DIR}/${domain}_access.log" "${NGX_LOG_DIR}/${domain}_error.log" 2>/dev/null || true
        ngx_msg_ok "域名 ${domain} 的反代已移除，证书已清理。"
        return 0
    fi

    ngx_msg_warn "配置回滚已完成，Nginx 重载失败，域名 ${domain} 的证书与配置均已保留。"
    return 1
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
    local backend_input domain_name cert_email conf tmp_http tmp_final txn
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

    tmp_http="$(mktemp "${NGX_TMP_DIR}/http.XXXXXX")" || { ngx_msg_err "创建临时 HTTP 配置失败。"; return 1; }
    ngx_render_http_conf "$domain_name" > "$tmp_http" || { rm -f "$tmp_http"; ngx_msg_err "生成 HTTP 配置失败。"; return 1; }

    txn="$(txn_begin)" || { rm -f "$tmp_http"; ngx_msg_err "初始化事务失败。"; return 1; }
    txn_register "$txn" _ngx_reload_quiet
    txn_backup_file "$txn" "$conf" >/dev/null || { rm -f "$tmp_http"; txn_abort "$txn"; ngx_msg_err "备份现有站点配置失败。"; return 1; }
    install -m 644 "$tmp_http" "$conf" 2>/dev/null || { rm -f "$tmp_http"; txn_abort "$txn"; ngx_msg_err "写入 HTTP 配置失败。"; return 1; }
    rm -f "$tmp_http"

    if ! ngx_test_reload; then
        txn_abort "$txn"
        ngx_msg_err "Nginx HTTP 预配置校验失败，已回滚。"
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
    if ! certbot certonly --webroot -w "$NGX_WEBROOT" --non-interactive --agree-tos --deploy-hook "$(ngx_certbot_deploy_hook_cmd)" "${email_args[@]}" -d "$domain_name" >/dev/null 2>&1; then
        ngx_delete_cert_if_exists "$domain_name"
        txn_abort "$txn"
        ngx_msg_err "SSL 证书申请失败，站点配置已通过事务回滚。"
        sleep 2
        return 1
    fi

    tmp_final="$(mktemp "${NGX_TMP_DIR}/final.XXXXXX")" || {
        txn_abort "$txn"
        ngx_msg_err "创建最终 HTTPS 配置失败，证书已保留，站点配置已回滚。"
        return 1
    }
    ngx_render_https_conf "$domain_name" > "$tmp_final" || {
        rm -f "$tmp_final"
        txn_abort "$txn"
        ngx_msg_err "生成最终 HTTPS 配置失败，证书已保留，站点配置已回滚。"
        return 1
    }
    install -m 644 "$tmp_final" "$conf" 2>/dev/null || {
        rm -f "$tmp_final"
        txn_abort "$txn"
        ngx_msg_err "安装最终 HTTPS 配置失败，证书已保留，站点配置已回滚。"
        return 1
    }
    rm -f "$tmp_final"

    if ! ngx_test_reload; then
        txn_abort "$txn"
        ngx_msg_err "最终 HTTPS 配置校验失败，证书已保留，站点配置已通过事务回滚。"
        sleep 2
        return 1
    fi

    txn_commit "$txn"
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
        clear 2>/dev/null || true
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
mv -f "${NGX_MODULE_FILE}.tmp" "${NGX_MODULE_FILE}"

    chmod 755 "${COMMON_MODULE_FILE}" "${SSR_MODULE_FILE}" "${NFT_MODULE_FILE}" "${NGX_MODULE_FILE}" 2>/dev/null || true
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

    cron_remove_regex '(^|\s)(/usr/local/bin/ssr|/usr/local/bin/my\s+ssr)\s+(auto_update|auto_task|daemon_check|auto_core_update|clean|daily_task|ddns)(\s|$)'

    cron_add_line_once "* * * * * ${lock_prefix} ${my_cmd} ssr daemon_check > /dev/null 2>&1"

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
        clear 2>/dev/null || true
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

ssr_deploy_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}           代理节点部署中心 (SSR)          ${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${YELLOW} 1.${RESET} 安装 SS-Rust"
        echo -e "${YELLOW} 2.${RESET} 安装 SS2022 + v2ray-plugin"
        echo -e "${YELLOW} 3.${RESET} 安装 VLESS Reality"
        echo -e " 0. 返回上一级"
        echo -e "${CYAN}--------------------------------------------${RESET}"
        read -rp "请输入数字 [0-3]: " choice
        case "$choice" in
            1) install_ss_rust_native ;;
            2) install_ss_v2ray_plugin_native ;;
            3) install_vless_native ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

ssr_hub_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}           代理节点与热更中心 (SSR)       ${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${YELLOW} 1.${RESET} 节点部署中心"
        echo -e "${YELLOW} 2.${RESET} 节点运维中心"
        echo -e "${YELLOW} 3.${RESET} 网络优化与系统清理中心"
        echo -e "${YELLOW} 4.${RESET} 核心缓存与更新中心"
        echo -e "${YELLOW} 5.${RESET} 系统基础与极客管理"
        echo -e " 0. 返回主菜单"
        echo -e "${CYAN}--------------------------------------------${RESET}"
        read -rp "请输入数字 [0-5]: " choice
        case "$choice" in
            1) ssr_deploy_menu ;;
            2) unified_node_manager ;;
            3) opt_menu ;;
            4) core_cache_menu ;;
            5) sys_menu ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

run_ssr_module_menu() {
    my_enable_ssr_cron_tasks
    (
      source "${SSR_MODULE_FILE}" || exit 1
      ssr_hub_menu
    )
}

run_system_module_menu() {
    (
      source "${SSR_MODULE_FILE}" || exit 1
      sys_menu
    )
}

run_nft_module_menu() {
    (
      source "${NFT_MODULE_FILE}" || exit 1
      require_root
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
        openssl rand -base64 12 2>/dev/null | tr -d '=+/\n' | cut -c1-14
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

    clear 2>/dev/null || true
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
    clear 2>/dev/null || true
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
        clear 2>/dev/null || true
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

nft_status_eval() {
    ( source "${NFT_MODULE_FILE}" >/dev/null 2>&1 || exit 1; "$@" )
}

nginx_status_eval() {
    ( source "${NGX_MODULE_FILE}" >/dev/null 2>&1 || exit 1; "$@" )
}

status_cc_brief() {
    local cc qdisc
    cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo unknown)
    qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo unknown)
    printf '%s + %s' "$cc" "$qdisc"
}

status_colorize() {
    local level="$1" text="$2"
    case "$level" in
        ok) echo -e "${GREEN}${text}${RESET}" ;;
        warn) echo -e "${YELLOW}${text}${RESET}" ;;
        bad) echo -e "${RED}${text}${RESET}" ;;
        info|*) echo -e "${CYAN}${text}${RESET}" ;;
    esac
}

status_cc_colored() {
    local cc qdisc
    cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo unknown)
    qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo unknown)
    if [[ "$cc" == "bbr" && "$qdisc" == "fq" ]]; then
        status_colorize ok "${cc} + ${qdisc}"
    elif [[ "$cc" == "bbr" || "$qdisc" == "fq" ]]; then
        status_colorize warn "${cc} + ${qdisc}"
    else
        status_colorize bad "${cc} + ${qdisc}"
    fi
}

status_service_brief_line() {
    local name="$1" label="$2"
    local match pid_file port state extra="" level="info"
    match=$(managed_service_match "$name" 2>/dev/null || true)
    pid_file=$(managed_service_pid "$name" 2>/dev/null || true)
    if managed_service_exists "$name"; then
        port=$(managed_service_current_port "$name" 2>/dev/null || true)
        [[ "$port" =~ ^[0-9]+$ ]] && extra=" / 端口 ${port}"
        if service_is_running "$name" "$match" "$pid_file"; then
            if [[ "$port" =~ ^[0-9]+$ ]] && ! port_in_use "$port" tcp 2>/dev/null; then
                state="配置异常/端口未监听"
                level="bad"
            else
                state="运行中"
                level="ok"
            fi
        else
            if [[ "$port" =~ ^[0-9]+$ ]] && port_in_use "$port" tcp 2>/dev/null; then
                state="端口冲突"
                level="bad"
            else
                state="已部署/未运行"
                level="warn"
            fi
        fi
    else
        state="未部署"
        level="bad"
    fi
    echo -e "  ${CYAN}${label}${RESET}: $(status_colorize "$level" "$state")${extra}"
}

status_ssh_line() {
    local ssh_port ssh_auth
    ssh_port=$(get_ssh_port_brief 2>/dev/null || echo 22)
    ssh_auth=$(get_ssh_auth_brief 2>/dev/null || echo 未知)
    if have_cmd sshd && ! sshd -t >/dev/null 2>&1; then
        echo -e "  SSH: 端口 ${YELLOW}${ssh_port}${RESET} / $(status_colorize bad '配置异常') / ${YELLOW}${ssh_auth}${RESET}"
    elif [[ "$ssh_port" =~ ^[0-9]+$ ]] && ! port_in_use "$ssh_port" tcp 2>/dev/null; then
        echo -e "  SSH: 端口 ${YELLOW}${ssh_port}${RESET} / $(status_colorize bad '端口未监听') / ${YELLOW}${ssh_auth}${RESET}"
    else
        echo -e "  SSH: 端口 ${YELLOW}${ssh_port}${RESET} / $(status_colorize ok '正常') / ${YELLOW}${ssh_auth}${RESET}"
    fi
}

status_nginx_line() {
    local domains
    domains=$(nginx_status_eval get_nginx_domains_brief 2>/dev/null || echo 0)
    if have_cmd nginx && ! nginx -t >/dev/null 2>&1; then
        echo -e "  Nginx 状态: $(status_colorize bad '配置异常') / 站点 ${YELLOW}${domains}${RESET}"
    elif systemctl is-active --quiet nginx 2>/dev/null; then
        echo -e "  Nginx 状态: $(status_colorize ok '运行中') / 站点 ${YELLOW}${domains}${RESET}"
    elif [[ "$domains" =~ ^[0-9]+$ && "$domains" -gt 0 ]]; then
        echo -e "  Nginx 状态: $(status_colorize warn '已配置未运行') / 站点 ${YELLOW}${domains}${RESET}"
    else
        echo -e "  Nginx 状态: $(status_colorize bad '未部署') / 站点 ${YELLOW}${domains}${RESET}"
    fi
}

status_quic_line() {
    local quic quic_backend
    quic=$(get_quic_status_brief 2>/dev/null || echo 未知)
    quic_backend=$(get_quic_backend 2>/dev/null || echo unknown)
    [[ "$quic_backend" == "none" ]] && quic_backend="未托管"
    if [[ "$quic" == 已阻断* ]]; then
        echo -e "  QUIC / UDP443: $(status_colorize ok "$quic") / 后端 ${YELLOW}${quic_backend}${RESET}"
    elif [[ "$quic" == 默认放行* ]]; then
        echo -e "  QUIC / UDP443: $(status_colorize warn "$quic") / 后端 ${YELLOW}${quic_backend}${RESET}"
    elif [[ "$quic" == 未知* || "$quic_backend" == "unknown" ]]; then
        echo -e "  QUIC / UDP443: $(status_colorize bad '配置异常') / 后端 ${YELLOW}${quic_backend}${RESET}"
    else
        echo -e "  QUIC / UDP443: $(status_colorize info "$quic") / 后端 ${YELLOW}${quic_backend}${RESET}"
    fi
}

status_page_loop() {
    while true; do
        local cc_brief ddns dns dns_servers nft_rules nft_mode timesync ss_ver xr_ver
        cc_brief=$(status_cc_brief)
        ddns=$(get_cf_ddns_brief_status 2>/dev/null || echo "未知")
        dns=$(get_dns_brief_status 2>/dev/null || echo "未知")
        dns_servers=$(get_dns_servers_brief 2>/dev/null || echo "未探测到")
        nft_rules=$(nft_status_eval count_forward_rules_brief 2>/dev/null || echo 0)
        nft_mode=$(nft_status_eval settings_get "PERSIST_MODE" 2>/dev/null || echo "service")
        timesync=$(status_timesync_brief)
        ss_ver=$(ss_rust_current_tag 2>/dev/null || echo "-")
        xr_ver=$(xray_current_tag 2>/dev/null || echo "-")

        clear 2>/dev/null || true
        echo -e "${CYAN}============================================================${RESET}"
        echo -e "${CYAN}                    统一状态页 / 管理导航                   ${RESET}"
        echo -e "${CYAN}============================================================${RESET}"
        echo -e "${GREEN}网络调优${RESET}"
        echo -e "  拥塞控制 / 队列: $(status_cc_colored)"
        status_timesync_line
        echo -e ""
        echo -e "${GREEN}代理节点${RESET}"
        status_service_brief_line "ss-rust" "SS-Rust"
        echo -e "  ${CYAN}SS-Rust 版本${RESET}: ${YELLOW}${ss_ver}${RESET}"
        status_service_brief_line "ss-v2ray" "SS2022 + v2ray-plugin"
        status_service_brief_line "xray" "VLESS Reality"
        echo -e "  ${CYAN}Xray 版本${RESET}: ${YELLOW}${xr_ver}${RESET}"
        echo -e ""
        echo -e "${GREEN}端口转发 / Nginx${RESET}"
        if [[ "$nft_rules" =~ ^[0-9]+$ && "$nft_rules" -gt 0 ]]; then
            echo -e "  NFT 转发规则: $(status_colorize ok "$nft_rules 条") / 持久化模式 ${YELLOW}${nft_mode}${RESET}"
        else
            echo -e "  NFT 转发规则: $(status_colorize warn "0 条") / 持久化模式 ${YELLOW}${nft_mode}${RESET}"
        fi
        status_quic_line
        status_nginx_line
        echo -e ""
        echo -e "${GREEN}系统基础与极客管理${RESET}"
        status_ssh_line
        echo -e "  DDNS: ${YELLOW}${ddns}${RESET}"
        echo -e "  DNS: ${YELLOW}${dns}${RESET} / 当前 ${YELLOW}${dns_servers}${RESET}"
        echo -e ""
        echo -e "${CYAN}快捷导航${RESET}"
        echo -e "  ${YELLOW}1.${RESET} 代理节点与热更中心    ${YELLOW}4.${RESET} Nginx 反向代理"
        echo -e "  ${YELLOW}2.${RESET} 端口转发 / NFT 中心  ${YELLOW}5.${RESET} DD / 重装系统中心"
        echo -e "  ${YELLOW}3.${RESET} 系统基础与极客管理  ${YELLOW}6.${RESET} 刷新状态页"
        echo -e "  0. 返回主菜单"
        echo -e "${CYAN}============================================================${RESET}"
        read -rp "请输入数字 [0-6]: " choice
        case "$choice" in
            1) run_ssr_module_menu ;;
            2) run_nft_module_menu ;;
            3) run_system_module_menu ;;
            4) run_nginx_module_menu ;;
            5) dd_menu ;;
            6) ;;
            0) return ;;
            *) msg_err "无效选项"; sleep 1 ;;
        esac
    done
}

run_status_page() {
    ensure_runtime_ready_for_cli
    (
      source "${COMMON_MODULE_FILE}" || exit 1
      source "${SSR_MODULE_FILE}" || exit 1
      status_page_loop
    )
}

# --------------------------
# 综合管理目录
# --------------------------
comprehensive_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}         系统 / 建站 / 重装中心            ${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${YELLOW} 1.${RESET} 系统基础与极客管理"
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
    clear 2>/dev/null || true
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}      综合管理脚本 my  v${MY_VERSION}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${YELLOW} 1.${RESET} 统一状态页 / 管理导航"
    echo -e "${YELLOW} 2.${RESET} 代理节点与热更中心 (SSR)"
    echo -e "${YELLOW} 3.${RESET} 端口转发 / NFT 中心"
    echo -e "${YELLOW} 4.${RESET} 系统 / 建站 / 重装中心"
    echo -e "${YELLOW} 5.${RESET} GitHub 一键更新"
    echo -e "${YELLOW} 6.${RESET} 一键卸载"
    echo -e " 0. 退出"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    read -rp "请输入数字 [0-6]: " choice
    case "$choice" in
        1) run_status_page ;;
        2) run_ssr_module_menu ;;
        3) run_nft_module_menu ;;
        4) comprehensive_menu ;;
        5) github_update ;;
        6) uninstall_menu ;;
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
    mkdir -p "${MY_STATE_DIR}" "${MY_SSR_STATE_DIR}" "${MY_NGX_STATE_DIR}" 2>/dev/null || true
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
    mkdir -p "${MY_STATE_DIR}" "${MY_SSR_STATE_DIR}" "${MY_NGX_STATE_DIR}" 2>/dev/null || true
    install_modules
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
        status)
            run_status_page
            exit $?
            ;;
        update)
            ensure_runtime_ready_for_cli
            github_update
            exit $?
            ;;
        *)
            msg_err "未知参数。可用: my clean | my status | my ssr ... | my nft ... | my nginx <menu|list|delete <domain>|repair> | my dd <menu|debian13|debian12|ubuntu2404> | my update"
            exit 1
            ;;
    esac
fi

init
while true; do
    main_menu
done
