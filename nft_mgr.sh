#!/bin/bash

# 配置文件路径
CONFIG_FILE="/etc/nft_forward_list.conf"
NFT_CONF="/etc/nftables.conf"
SHORTCUT_PATH="/usr/local/bin/nft"
SYS_OPT_CONF="/etc/sysctl.d/99-sys-opt.conf"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行!${PLAIN}" && exit 1

# --- 快捷命令注册 ---
function register_shortcut() {
    local script_path=$(realpath "$0")
    if [ "$script_path" != "$SHORTCUT_PATH" ]; then
        cp "$script_path" "$SHORTCUT_PATH" && chmod +x "$SHORTCUT_PATH"
    fi
}

# --- 改进的解析函数 (增加超时控制) ---
function get_ip() {
    local addr=$1
    if [[ $addr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$addr"
    else
        # 使用 +time=2 +tries=1 防止因 DNS 不通导致脚本卡死
        local res=$(dig +short +time=2 +tries=1 "$addr" | grep -E '^[0-9.]+$' | tail -n1)
        echo "$res"
    fi
}

# --- 优化规则应用 (增加错误容灾) ---
function apply_rules() {
    # 确保基础表存在
    nft add table ip nat 2>/dev/null
    nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; } 2>/dev/null
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null

    # 清空旧规则
    nft flush chain ip nat prerouting 2>/dev/null
    nft flush chain ip nat postrouting 2>/dev/null

    if [ -f "$CONFIG_FILE" ]; then
        while IFS='|' read -r lp addr tp last_ip; do
            [ -z "$lp" ] && continue
            current_ip=$(get_ip "$addr")
            
            # 如果解析失败，回退使用上次记录的 IP
            if [ -z "$current_ip" ]; then
                current_ip="$last_ip"
            fi

            if [ ! -z "$current_ip" ]; then
                nft add rule ip nat prerouting tcp dport $lp dnat to $current_ip:$tp 2>/dev/null
                nft add rule ip nat prerouting udp dport $lp dnat to $current_ip:$tp 2>/dev/null
                nft add rule ip nat postrouting ip daddr $current_ip masquerade 2>/dev/null
            fi
        done < "$CONFIG_FILE"
    fi
    # 保存规则，防止重启失效
    nft list ruleset > "$NFT_CONF" 2>/dev/null
}

# --- 菜单功能 ---
function add_forward() {
    read -p "本地监听端口: " lp
    read -p "目标地址: " ad
    read -p "目标端口: " tp
    
    echo -e "${YELLOW}正在尝试解析并应用规则...${PLAIN}"
    tip=$(get_ip "$ad")
    
    if [ -z "$tip" ]; then
        echo -e "${RED}无法解析地址，请检查网络或更换 DNS。${PLAIN}"
        # 允许用户强制添加，后续靠 DDNS 自动修复
        read -p "是否强制添加并在后台重试？(y/n): " force
        [[ "$force" != [yY] ]] && return
        tip="0.0.0.0" 
    fi

    echo "$lp|$ad|$tp|$tip" >> "$CONFIG_FILE"
    apply_rules
    echo -e "${GREEN}添加任务成功！${PLAIN}"
}

function uninstall_all() {
    echo -e "${RED}正在卸载...${PLAIN}"
    crontab -l 2>/dev/null | grep -v "$SHORTCUT_PATH" | crontab -
    nft flush table ip nat 2>/dev/null
    rm -f "$CONFIG_FILE" "$NFT_CONF" "$SYS_OPT_CONF" "$SHORTCUT_PATH"
    echo -e "${GREEN}卸载完成。${PLAIN}"
    rm -f "$0"
    exit 0
}

# --- 主入口逻辑 (省略重复部分) ---
# ... (此处包含原有 optimize_system, show_forward, manage_cron 等函数) ...
