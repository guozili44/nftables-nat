#!/bin/bash

# ==========================================
# nftables 端口转发管理面板 (Pro 稳定优化版)
# ==========================================

set -o pipefail

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

CMD_NAME="nf"


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
msg_info() { echo -e "${CYAN}$*${PLAIN}"; }

script_realpath() {
    local src="$0"
    if command -v realpath >/dev/null 2>&1; then
        realpath "$src"
    elif command -v readlink >/dev/null 2>&1; then
        readlink -f "$src" 2>/dev/null || printf '%s\n' "$src"
    else
        printf '%s\n' "$src"
    fi
}

# 基础工具
have_cmd() { command -v "$1" >/dev/null 2>&1; }


# --------------------------
# 环境与依赖
# --------------------------
require_root() {
    [[ $EUID -ne 0 ]] && msg_err "错误: 必须使用 root 权限运行!" && exit 1
}

check_env() {
    # 仅检查依赖，不自动安装，避免产生额外外连和系统改动
    local need=0
    for c in nft dig curl flock ss sysctl; do
        have_cmd "$c" || need=1
    done
    if [[ $need -eq 1 ]]; then
        msg_warn "缺少依赖，请手动安装：nftables dnsutils(bind-utils) curl util-linux iproute2/iproute"
    fi

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
    local self
    self="$(script_realpath)"
    if [[ "$self" != "/usr/local/bin/${CMD_NAME}" ]]; then
        cp -f "$self" "/usr/local/bin/${CMD_NAME}" 2>/dev/null || true
        chmod +x "/usr/local/bin/${CMD_NAME}" 2>/dev/null || true
    fi
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
# DDNS 定时任务辅助函数（默认不自动启用，由用户手动开启）
# --------------------------
ensure_ddns_cron_enabled() {
    local script_path="/usr/local/bin/${CMD_NAME}"
    [[ -x "$script_path" ]] || script_path="$(script_realpath)"

    # 已存在则不重复添加
    if crontab -l 2>/dev/null | grep -Fq "${script_path} --cron"; then
        return 0
    fi

    # 追加定时任务：每 5 分钟运行一次 DDNS 更新
    (crontab -l 2>/dev/null; echo "*/5 * * * * ${script_path} --cron > /dev/null 2>&1") | crontab - 2>/dev/null || true
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
    # 删除所有 nf/nftmgr --cron 的 crontab 行（避免路径差异导致残留）
    local cur
    cur="$(crontab -l 2>/dev/null || true)"
    [[ -z "$cur" ]] && return 0
    echo "$cur" | grep -vE '(^|\s)(/usr/local/bin/(nf|nftmgr)|(nf|nftmgr))\s+--cron(\s|$)' | crontab - 2>/dev/null || true
    return 0
}

ensure_ddns_cron_disabled_if_unused() {
    # 当已无域名转发规则时，自动清理 DDNS 定时任务，避免 crontab 冗余
    if has_domain_rules; then
        return 0
    fi

    # 已无域名规则 -> 清理任务
    local script_path="/usr/local/bin/${CMD_NAME}"
    [[ -x "$script_path" ]] || script_path="$(script_realpath)"

    if crontab -l 2>/dev/null | grep -Fq "${script_path} --cron" || crontab -l 2>/dev/null | grep -Eq '(^|\s)(/usr/local/bin/(nf|nftmgr)|(nf|nftmgr))\s+--cron(\s|$)'; then
        remove_ddns_cron_task
        msg_info "已无域名转发规则：已自动移除 DDNS 定时检测任务（crontab）。"
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
# generated by nf (compat mode)
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
# nf include (added %s)
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
            echo -e "/etc/nftables.conf: ${GREEN}已包含 nf 规则（include）${PLAIN}"
        else
            echo -e "/etc/nftables.conf: ${YELLOW}未包含 nf include${PLAIN}"
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
sysctl_set_kv() {
    local key="$1"; local value="$2"
    mkdir -p /etc/sysctl.d 2>/dev/null || true
    touch "$SYSCTL_FILE" 2>/dev/null || true

    if grep -qE "^\s*${key}\s*=" "$SYSCTL_FILE" 2>/dev/null; then
        sed -i "s|^\s*${key}\s*=.*|${key} = ${value}|g" "$SYSCTL_FILE"
    else
        echo "${key} = ${value}" >> "$SYSCTL_FILE"
    fi
}

ensure_forwarding() {
    local cur
    cur="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
    if [[ "$cur" != "1" ]]; then
        sysctl_set_kv "net.ipv4.ip_forward" "1"
        sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    fi
}

bbr_available() {
    sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr
}

optimize_system() {
    clear
    echo -e "${GREEN}--- 系统优化 (BBR + 转发 + 自启动) ---${PLAIN}"
    echo "1) 稳定推荐：仅开启转发 + 尝试启用 BBR"
    echo "2) 性能增强：在 1 的基础上，适度提升队列/并发（偏高负载）"
    echo "0) 返回"
    echo "--------------------------------"
    read -rp "请选择 [0-2]: " pick

    case "$pick" in
        0) return ;;
        1|2) ;;
        *) msg_err "无效选项"; sleep 1; return ;;
    esac

    echo -e "${CYAN}正在写入 sysctl 配置...${PLAIN}"
    sysctl_set_kv "net.ipv4.ip_forward" "1"

    # BBR: 仅在内核支持时写入，避免误导
    if bbr_available; then
        sysctl_set_kv "net.core.default_qdisc" "fq"
        sysctl_set_kv "net.ipv4.tcp_congestion_control" "bbr"
    else
        msg_warn "⚠️ 当前内核未检测到 bbr（将仅启用转发）。"
    fi

    if [[ "$pick" == "2" ]]; then
        sysctl_set_kv "net.core.somaxconn" "8192"
        sysctl_set_kv "net.core.netdev_max_backlog" "8192"
        sysctl_set_kv "fs.file-max" "524288"
    fi

    sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true

    if have_cmd systemctl; then
        echo -e "${CYAN}正在设置 nftables 开机自启...${PLAIN}"
        systemctl enable --now nftables >/dev/null 2>&1 || true
        ensure_nft_mgr_service
    fi

    msg_ok "✅ 系统优化已应用。"
    sleep 2
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
Description=nftables Port Forwarding Manager (nf)
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

    msg_ok "添加成功！映射路径: [本机] ${lport}/${proto} -> [目标] ${taddr}:${tport} (${tip})"
    sleep 2
    return 0
}

add_forward() { with_lock add_forward_impl; }

# --------------------------
# 规则管理（查看/删除）
# --------------------------
list_and_del_forward_impl() {
    clear
    if [[ ! -s "$CONFIG_FILE" ]]; then
        msg_warn "当前没有任何转发规则。"
        read -rp "按回车返回主菜单..."
        return 0
    fi

    echo -e "${CYAN}=========================== 规则管理 ===========================${PLAIN}"
    printf "%-4s | %-6s | %-5s | %-24s | %-6s\n" "序号" "本地" "协议" "目标地址" "目标"
    echo "----------------------------------------------------------------"

    local i=1
    while IFS='|' read -r lp addr tp last_ip proto; do
        [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
        proto="$(normalize_proto "$proto")"
        is_port "$lp" || continue
        is_port "$tp" || continue
        printf "%-4s | %-6s | %-5s | %-24s | %-6s\n" "$i" "$lp" "$proto" "$addr" "$tp"
        ((i++))
    done < "$CONFIG_FILE"

    echo "----------------------------------------------------------------"
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
    total_lines="$(awk -F'|' 'BEGIN{c=0}
        $0!~/^[[:space:]]*($|#)/{
            if($1~/^[0-9]+$/ && $1>=1 && $1<=65535 && $3~/^[0-9]+$/ && $3>=1 && $3<=65535){
                c++
            }
        }
        END{print c+0}' "$CONFIG_FILE" 2>/dev/null)"

    if [[ "$action" -lt 1 || "$action" -gt "$total_lines" ]]; then
        msg_err "序号超出范围！"
        sleep 2
        return 1
    fi

    local line_no
    line_no="$(awk -F'|' -v N="$action" 'BEGIN{c=0}
        $0!~/^[[:space:]]*($|#)/{
            if($1~/^[0-9]+$/ && $1>=1 && $1<=65535 && $3~/^[0-9]+$/ && $3>=1 && $3<=65535){
                c++
                if(c==N){print NR; exit}
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
    ensure_ddns_cron_disabled_if_unused

    msg_ok "已成功删除本地端口为 ${del_port}/${del_proto} 的转发规则。"
    sleep 2
    return 0
}

list_and_del_forward() { with_lock list_and_del_forward_impl; }

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
    local script_path="/usr/local/bin/${CMD_NAME}"
    [[ -x "$script_path" ]] || script_path="$(script_realpath)"
    if crontab -l 2>/dev/null | grep -Fq "${script_path} --cron"; then
        echo -e "${GREEN}--- 管理定时监控 (DDNS 同步) --- [已启用]${PLAIN}"
    else
        echo -e "${GREEN}--- 管理定时监控 (DDNS 同步) --- [未启用]${PLAIN}"
    fi
    echo "1. 手动添加定时任务 (每 5 分钟检测)"
    echo "2. 一键删除定时任务"
    echo "3. 查看 DDNS 变动历史日志 (仅保留最近7天)"
    echo "0. 返回主菜单"
    echo "--------------------------------"
    local cron_choice
    read -rp "请选择操作 [0-3]: " cron_choice

    local SCRIPT_PATH="/usr/local/bin/${CMD_NAME}"

    case "$cron_choice" in
        1)
            if crontab -l 2>/dev/null | grep -q "${SCRIPT_PATH} --cron"; then
                msg_warn "定时任务已存在。"
                sleep 2
                return
            fi
            (crontab -l 2>/dev/null; echo "*/5 * * * * ${SCRIPT_PATH} --cron > /dev/null 2>&1") | crontab - 2>/dev/null
            msg_ok "定时任务已添加！将每 5 分钟检查 IP 并生成日志。"
            sleep 2
            ;;
        2)
            crontab -l 2>/dev/null | grep -v "${SCRIPT_PATH} --cron" | crontab - 2>/dev/null
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
uninstall_script_impl() {
    clear
    echo -e "${RED}--- 卸载 nftables 端口转发管理面板 ---${PLAIN}"
    read -rp "警告: 此操作将删除本脚本、规则配置、定时任务、systemd 服务，并移除本脚本创建的 nft 表。确认？[y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return 0

    # 1) 删除防火墙放行（尽量清理）
    while IFS='|' read -r lp addr tp last_ip proto; do
        [[ -z "$lp" || "${lp:0:1}" == "#" ]] && continue
        is_port "$lp" || continue
        proto="$(normalize_proto "$proto")"
        manage_firewall "del" "$lp" "$proto" || true
    done < "$CONFIG_FILE" 2>/dev/null || true

    # 2) 删除 nft 表（仅本脚本的表）
    have_cmd nft && nft delete table ip nft_mgr_nat >/dev/null 2>&1 || true

    # 3) 删除 DDNS cron（无论路径差异）
    remove_ddns_cron_task || true

    # 4) systemd：停用并删除 nft-mgr 服务
    if have_cmd systemctl; then
        systemctl disable --now nft-mgr >/dev/null 2>&1 || true
        rm -f "$NFT_MGR_SERVICE" 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    # 5) 还原 /etc/nftables.conf 中的 include（只删我们添加的 include 行及标注）
    if [[ -f "$NFTABLES_CONF" ]]; then
        sed -i '/# nf include (added .*$/d' "$NFTABLES_CONF" 2>/dev/null || true
        sed -i '/# nftmgr persistent include$/d' "$NFTABLES_CONF" 2>/dev/null || true
        sed -i '\|include "/etc/nftables.d/nft_mgr.conf"|d' "$NFTABLES_CONF" 2>/dev/null || true
    fi

    # 6) 如果 /etc/nftables.conf 是我们创建的（marker 存在），则尝试恢复备份，否则删除并关闭 nftables.service
    if [[ -f "$NFTABLES_CREATED_MARK" ]]; then
        rm -f "$NFTABLES_CREATED_MARK" 2>/dev/null || true
        local latest_bak
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

    # 7) 删除我们创建的备份（仅 nftmgr 命名的）
    rm -f ${NFTABLES_CONF}.nftmgr.bak.* 2>/dev/null || true

    # 8) 删除脚本相关文件与目录（不留残留）
    rm -f "$NFT_MGR_CONF" "$CONFIG_FILE" "$SETTINGS_FILE" "$SYSCTL_FILE" "$LOCK_FILE" 2>/dev/null || true
    rm -rf "$LOG_DIR" 2>/dev/null || true
    rmdir "$NFT_MGR_DIR" 2>/dev/null || true

    # 9) 刷新 nftables（可选）
    if have_cmd systemctl; then
        systemctl restart nftables >/dev/null 2>&1 || true
    fi

    msg_ok "✅ 卸载完成（已清理脚本残留）。"

    # 10) 删除自身
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
    echo "1. 开启 BBR + 转发 + 自启动 (稳定/性能)"
    echo "2. 新增端口转发 (支持域名/IP，支持TCP/UDP选择)"
    echo "3. 规则管理 (查看/删除)"
    echo "4. 清空所有转发规则"
    echo "5. 管理 DDNS 定时监控与日志"
    echo "6. 一键完全卸载本脚本"
    echo "0. 退出面板"
    echo "------------------------------------------"
    local choice
    read -rp "请选择操作 [0-6]: " choice

    case "$choice" in
        1) optimize_system ;;
        2) add_forward ;;
        3) list_and_del_forward ;;
        4) clear_all_rules ;;
        5) manage_cron ;;
        6) uninstall_script ;;
        0) exit 0 ;;
        *) msg_err "无效选项"; sleep 1 ;;
    esac
}

# --------------------------
# 入口
# --------------------------
require_root
check_env
install_global_command

# 自动检测并完成持久化设置（无单独菜单项）
auto_persist_setup

# CLI 模式
case "${1:-}" in
    --cron)
        # DDNS 更新（温和模式：失败只记录日志，不中断）
        ddns_update
        exit $?
        ;;
esac

# 菜单循环
while true; do
    main_menu
done
