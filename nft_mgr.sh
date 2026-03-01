#!/bin/bash

# ==========================================
# nftables 端口转发管理面板 (Pro 完美版)
# ==========================================

# 配置文件路径
CONFIG_FILE="/etc/nft_forward_list.conf"
NFT_CONF="/etc/nftables.conf"
LOG_DIR="/var/log/nft_ddns"

# Github 脚本更新链接
RAW_URL="https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/nft_mgr.sh"
PROXY_URL="https://ghproxy.net/https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/nft_mgr.sh"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行!${PLAIN}" && exit 1

# 确保配置文件存在
[ ! -f "$CONFIG_FILE" ] && touch "$CONFIG_FILE"

# --- 自动设置快捷命令 ---
function setup_alias() {
    local shell_rc="$HOME/.bashrc"
    local current_path=$(realpath "$0" 2>/dev/null || readlink -f "$0")
    
    if [[ ! -t 0 ]]; then return; fi

    if ! grep -q "alias nft=" "$shell_rc" 2>/dev/null; then
        echo "alias nft='bash \"$current_path\"'" >> "$shell_rc"
        echo -e "${GREEN}[系统提示] 快捷命令 'nft' 已添加！下次登录可直接输入 nft 打开面板。${PLAIN}"
        sleep 2
    else
        sed -i "s|alias nft=.*|alias nft='bash \"$current_path\"'|g" "$shell_rc"
    fi
}
setup_alias

# --- 系统优化与 BBR ---
function optimize_system() {
    echo -e "${YELLOW}正在配置 BBR 和内核转发...${PLAIN}"
    sudo tee /etc/sysctl.d/99-sys-opt.conf > /dev/null <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sudo sysctl --system >/dev/null 2>&1
    
    echo -e "${YELLOW}正在设置 nftables 开机自启...${PLAIN}"
    systemctl enable --now nftables >/dev/null 2>&1
    
    echo -e "${GREEN}系统优化配置及开机自启已应用。${PLAIN}"
    sleep 2
}

# --- 域名解析函数 (强化版) ---
function get_ip() {
    local addr=$1
    if [[ $addr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$addr"
    else
        # 强制提取有效的 IPv4 地址，屏蔽 CNAME 和多余输出
        dig +short -t A "$addr" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -n1
    fi
}

# --- 原子化应用规则到内核 (极致性能) ---
function apply_rules() {
    local temp_nft=$(mktemp)
    
    # 构建基础表结构
    cat <<EOF > "$temp_nft"
flush ruleset
table ip nat {
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
EOF

    # 批量注入目标转发规则
    while IFS='|' read -r lp addr tp last_ip; do
        local current_ip=$(get_ip "$addr")
        if [ -n "$current_ip" ]; then
            echo "        tcp dport $lp dnat to $current_ip:$tp" >> "$temp_nft"
            echo "        udp dport $lp dnat to $current_ip:$tp" >> "$temp_nft"
        fi
    done < "$CONFIG_FILE"

    # 构建回程 SNAT (Masquerade)
    cat <<EOF >> "$temp_nft"
    }
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
EOF

    while IFS='|' read -r lp addr tp last_ip; do
        local current_ip=$(get_ip "$addr")
        if [ -n "$current_ip" ]; then
            echo "        ip daddr $current_ip masquerade" >> "$temp_nft"
        fi
    done < "$CONFIG_FILE"

    # 闭合表结构
    cat <<EOF >> "$temp_nft"
    }
}
EOF

    # 一次性原子化加载，0丢包断流
    nft -f "$temp_nft"
    
    # 固化到系统配置，确保开机生效
    cat "$temp_nft" > "$NFT_CONF"
    rm -f "$temp_nft"
}

# --- 新增转发 ---
function add_forward() {
    local lport taddr tport tip
    read -p "请输入本地监听端口 (1-65535): " lport
    
    if [[ ! "$lport" =~ ^[0-9]+$ ]] || [ "$lport" -lt 1 ] || [ "$lport" -gt 65535 ]; then
        echo -e "${RED}错误: 本地端口必须是 1 到 65535 之间的纯数字。${PLAIN}"
        sleep 2; return
    fi

    if grep -q "^$lport|" "$CONFIG_FILE" 2>/dev/null; then
        echo -e "${RED}错误: 本地端口 $lport 已被占用！请先删除旧规则。${PLAIN}"
        sleep 2; return
    fi

    read -p "请输入目标地址 (IP 或 域名): " taddr
    if [ -z "$taddr" ]; then
        echo -e "${RED}错误: 目标地址不能为空。${PLAIN}"
        sleep 2; return
    fi

    read -p "请输入目标端口 (1-65535): " tport
    if [[ ! "$tport" =~ ^[0-9]+$ ]] || [ "$tport" -lt 1 ] || [ "$tport" -gt 65535 ]; then
        echo -e "${RED}错误: 目标端口必须是纯数字。${PLAIN}"
        sleep 2; return
    fi

    echo -e "${YELLOW}正在解析并验证目标地址...${PLAIN}"
    tip=$(get_ip "$taddr")
    if [ -z "$tip" ]; then
        echo -e "${RED}错误: 解析失败，请检查域名或服务器网络。${PLAIN}"
        sleep 2; return
    fi

    echo "$lport|$taddr|$tport|$tip" >> "$CONFIG_FILE"
    apply_rules
    echo -e "${GREEN}添加成功！映射路径: [本机] $lport -> [目标] $taddr:$tport (${tip})。${PLAIN}"
    sleep 2
}

# --- 查看与删除功能合并 ---
function view_and_del_forward() {
    clear
    if [ ! -s "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}当前没有任何转发规则。${PLAIN}"
        read -p "按回车返回主菜单..."
        return
    fi

    echo -e "${GREEN}--- 当前转发列表 ---${PLAIN}"
    echo "----------------------------------------------------------------------"
    printf "%-5s | %-10s | %-20s | %-10s | %-15s\n" "序号" "本地端口" "目标地址" "目标端口" "当前映射IP"
    
    local i=1
    while IFS='|' read -r lp addr tp last_ip; do
        local current_ip=$(get_ip "$addr")
        printf "%-5s | %-10s | %-20s | %-10s | %-15s\n" "$i" "$lp" "$addr" "$tp" "$current_ip"
        ((i++))
    done < "$CONFIG_FILE"
    echo "----------------------------------------------------------------------"

    local action
    read -p "输入【序号】删除指定规则，输入【0】或直接回车返回: " action

    if [ -z "$action" ] || [ "$action" == "0" ]; then return; fi

    if [[ ! "$action" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}输入无效，请输入正确的数字。${PLAIN}"
        sleep 2; return
    fi

    local total_lines=$(wc -l < "$CONFIG_FILE")
    if [ "$action" -lt 1 ] || [ "$action" -gt "$total_lines" ]; then
        echo -e "${RED}序号超出范围！${PLAIN}"
        sleep 2; return
    fi

    local del_port=$(sed -n "${action}p" "$CONFIG_FILE" | cut -d'|' -f1)
    sed -i "${action}d" "$CONFIG_FILE"
    apply_rules
    echo -e "${GREEN}已成功删除本地端口为 $del_port 的转发规则。${PLAIN}"
    sleep 2
}

# --- 监控脚本 (DDNS 追踪更新与日志切割清理) ---
function ddns_update() {
    local changed=0
    local temp_file=$(mktemp)
    
    # 确保日志存储目录存在
    [ ! -d "$LOG_DIR" ] && mkdir -p "$LOG_DIR"
    # 当天的日志文件名，例如: /var/log/nft_ddns/2026-03-01.log
    local today_log="$LOG_DIR/$(date '+%Y-%m-%d').log"
    
    while IFS='|' read -r lp addr tp last_ip; do
        local current_ip=$(get_ip "$addr")
        if [ "$current_ip" != "$last_ip" ] && [ -n "$current_ip" ]; then
            echo "$lp|$addr|$tp|$current_ip" >> "$temp_file"
            changed=1
            # 记录变动到当天的日志文件
            echo "[$(date '+%H:%M:%S')] 端口 $lp: $addr 变动 ($last_ip -> $current_ip)" >> "$today_log"
        else
            echo "$lp|$addr|$tp|$last_ip" >> "$temp_file"
        fi
    done < "$CONFIG_FILE"
    mv "$temp_file" "$CONFIG_FILE"
    
    if [ $changed -eq 1 ]; then apply_rules; fi

    # 核心优化：每次巡检时，静默清理 7 天前生成的过期日志文件
    find "$LOG_DIR" -type f -name "*.log" -mtime +7 -exec rm -f {} \; 2>/dev/null
}

# --- 管理定时监控 (DDNS 同步) ---
function manage_cron() {
    clear
    echo -e "${GREEN}--- 管理定时监控 (DDNS 同步) ---${PLAIN}"
    echo "1. 自动添加定时任务 (每分钟检测)"
    echo "2. 一键删除定时任务"
    echo "3. 查看 DDNS 变动历史日志 (仅保留最近7天)"
    echo "0. 返回主菜单"
    echo "--------------------------------"
    local cron_choice
    read -p "请选择操作 [0-3]: " cron_choice

    local SCRIPT_PATH=$(realpath "$0")
    case $cron_choice in
        1)
            (crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH --cron") && echo -e "${YELLOW}定时任务已存在。${PLAIN}" && sleep 2 && return
            (crontab -l 2>/dev/null; echo "* * * * * $SCRIPT_PATH --cron > /dev/null 2>&1") | crontab -
            echo -e "${GREEN}定时任务已添加！将自动检查 IP 并生成日志。${PLAIN}"
            sleep 2 ;;
        2)
            crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH --cron" | crontab -
            echo -e "${YELLOW}定时任务已清除。${PLAIN}"
            sleep 2 ;;
        3)
            clear
            # 检查是否有日志文件存在
            if [ -d "$LOG_DIR" ] && ls "$LOG_DIR"/*.log >/dev/null 2>&1; then
                echo -e "${GREEN}--- 近 7 天 DDNS 变动日志 ---${PLAIN}"
                # 按照文件名升序(即时间顺序)读取所有日志，并输出最后20行
                cat "$LOG_DIR"/*.log | tail -n 20
            else
                echo -e "${YELLOW}暂无 IP 变动记录。${PLAIN}"
            fi
            echo ""
            read -p "按回车键返回..." ;;
        0) return ;;
        *) echo "无效选项" ; sleep 1 ;;
    esac
}

# --- 手动跟随 GitHub 更新脚本 (热重启) ---
function update_script() {
    clear
    echo -e "${GREEN}--- 脚本更新 ---${PLAIN}"
    echo "1. 从 GitHub 官方直连更新 (推荐海外机)"
    echo "2. 从 GHProxy 代理更新 (推荐国内机)"
    echo "0. 取消并返回主菜单"
    echo "--------------------------------"
    local up_choice target_url
    read -p "请选择更新线路 [0-2]: " up_choice

    case $up_choice in
        1) target_url="$RAW_URL" ;;
        2) target_url="$PROXY_URL" ;;
        0) return ;;
        *) echo -e "${RED}无效选项。${PLAIN}" ; sleep 1 ; return ;;
    esac

    echo -e "${YELLOW}正在拉取最新代码...${PLAIN}"
    local SCRIPT_PATH=$(realpath "$0")
    local TEMP_FILE=$(mktemp)

    if curl -sL "$target_url" -o "$TEMP_FILE"; then
        if grep -q "#!/bin/bash" "$TEMP_FILE"; then
            cat "$TEMP_FILE" > "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
            rm -f "$TEMP_FILE"
            echo -e "${GREEN}代码更新成功！面板正在热重启...${PLAIN}"
            sleep 1
            # 使用 exec 替换当前进程，实现无缝重启
            exec bash "$SCRIPT_PATH"
        else
            echo -e "${RED}失败: 文件内容非法。可能是代理或网络错误。${PLAIN}"
            rm -f "$TEMP_FILE"; sleep 3
        fi
    else
        echo -e "${RED}失败: 无法连接服务器。${PLAIN}"
        rm -f "$TEMP_FILE"; sleep 3
    fi
}

# --- 完全卸载脚本 ---
function uninstall_script() {
    clear
    echo -e "${RED}--- 卸载 nftables 端口转发面板 ---${PLAIN}"
    local confirm
    read -p "警告: 此操作将抹除所有转发规则及本脚本！确认？[y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then return; fi

    echo -e "${YELLOW}清理中...${PLAIN}"
    nft flush ruleset 2>/dev/null
    > "$NFT_CONF" 2>/dev/null

    local SCRIPT_PATH=$(realpath "$0")
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH --cron" | crontab -

    # 同步清理日志文件夹
    rm -rf "$CONFIG_FILE" "$LOG_DIR"
    sed -i '/alias nft=/d' "$HOME/.bashrc"
    rm -f "$SCRIPT_PATH"

    echo -e "${GREEN}彻底卸载完成，干干净净。${PLAIN}"
    exit 0
}

# --- 主菜单 ---
function main_menu() {
    clear
    echo -e "${GREEN}==========================================${PLAIN}"
    echo -e "${GREEN}      nftables 端口转发管理面板 (Pro)     ${PLAIN}"
    echo -e "${GREEN}==========================================${PLAIN}"
    echo "1. 开启 BBR + 系统优化及开机自启"
    echo "2. 新增端口转发 (支持域名/IP)"
    echo "3. 查看 / 删除端口转发"
    echo "4. 清空所有转发规则"
    echo "5. 管理 DDNS 定时监控与日志"
    echo "6. 从 GitHub 更新当前脚本"
    echo "7. 一键完全卸载本脚本"
    echo "0. 退出面板"
    echo "------------------------------------------"
    local choice
    read -p "请选择操作 [0-7]: " choice

    case $choice in
        1) optimize_system ;;
        2) add_forward ;;
        3) view_and_del_forward ;;
        4) > "$CONFIG_FILE" ; apply_rules ; echo -e "${GREEN}已清空。${PLAIN}" ; sleep 2 ;;
        5) manage_cron ;;
        6) update_script ;;
        7) uninstall_script ;;
        0) exit 0 ;;
        *) echo "无效选项" ; sleep 1 ;;
    esac
}

# 检查依赖
if ! command -v dig &> /dev/null; then
    apt-get update && apt-get install -y dnsutils || yum install -y bind-utils
fi

# 隐藏运行模式 (Crontab触发)
if [ "$1" == "--cron" ]; then
    ddns_update
    exit 0
fi

# 保持交互菜单循环
while true; do main_menu; done
