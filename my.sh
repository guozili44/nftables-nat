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
        bak=$(mktemp "$txn/files/$(basename "$target").XXXXXX") || ret
