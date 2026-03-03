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
CYAN='\033[0;36m'
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

# --- 流量格式化辅助函数 ---
function format_bytes() {
    local bytes=$1
    if [[ -z "$bytes" || "$bytes" -eq 0 ]]; then
        echo "0 B"
    elif [ "$bytes" -lt 1024 ]; then
        echo "${bytes} B"
    elif [ "$bytes" -lt 1048576 ]; then
        echo "$(( bytes / 1024 )) KB"
    elif [ "$bytes" -lt 1073741824 ]; then
        echo "$(( bytes / 1048576 )) MB"
    elif [ "$bytes" -lt 1099511627776 ]; then
        # 两位小数的 GB
        awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
    else
        # 两位小数的 TB
        awk "BEGIN {printf \"%.2f TB\", $bytes/1099511627776}"
    fi
}

# --- 系统优化与 BBR ---
function optimize_system() {
    echo -e "${YELLOW}正在配置 BBR 和内核转发...${PLAIN}"
    echo "net.core.default_qdisc=fq" > /etc/sysctl.d/99-sys-opt.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/99-sys-opt.conf
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/99-sys-opt.conf
    echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/99-sys-opt.conf
    
    sudo sysctl --system >/dev/null 2>&1
    
    echo -e "${YELLOW}正在设置 nftables 开机自启...${PLAIN}"
    systemctl enable --now nftables >/dev/null 2>&1
    
    echo -e "${GREEN}系统优化配置及开机自启已应用。${PLAIN}"
    sleep 2
}

# --- 域名解析函数 ---
function get_ip() {
    local addr=$1
    if [[ $addr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$addr"
    else
        dig +short -t A "$addr" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -n1
    fi
}

# --- 本地防火墙智能放行 ---
function manage_firewall() {
    local action=$1
    local port=$2
    
    if command -v ufw &> /dev/null && ufw status | grep -qw active; then
        if [ "$action" == "add" ]; then
            ufw allow "$port"/tcp >/dev/null 2>&1; ufw allow "$port"/udp >/dev/null 2>&1
        else
            ufw delete allow "$port"/tcp >/dev/null 2>&1; ufw delete allow "$port"/udp >/dev/null 2>&1
        fi
    elif command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
        if [ "$action" == "add" ]; then
            firewall-cmd --add-port="${port}/tcp" --permanent >/dev/null 2>&1; firewall-cmd --add-port="${port}/udp" --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1
        else
            firewall-cmd --remove-port="${port}/tcp" --permanent >/dev/null 2>&1; firewall-cmd --remove-port="${port}/udp" --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1
        fi
    elif command -v iptables &> /dev/null; then
        if [ "$action" == "add" ]; then
            iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1
            iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1
        else
            while iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; do :; done
            while iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null; do :; done
        fi
    fi
}

# --- 原子化应用规则到内核 (包含流量统计表) ---
function apply_rules() {
    local temp_nft=$(mktemp)
    
    echo "flush ruleset" > "$temp_nft"
    
    # 构建 NAT 转发规则表
    echo "table ip nat {" >> "$temp_nft"
    echo "    chain prerouting {" >> "$temp_nft"
    echo "        type nat hook prerouting priority -100; policy accept;" >> "$temp_nft"

    while IFS='|' read -r lp addr tp last_ip; do
        local current_ip=$(get_ip "$addr")
        if [ -n "$current_ip" ]; then
            echo "        tcp dport $lp dnat to $current_ip:$tp" >> "$temp_nft"
            echo "        udp dport $lp dnat to $current_ip:$tp" >> "$temp_nft"
        fi
    done < "$CONFIG_FILE"

    echo "    }" >> "$temp_nft"
    echo "    chain postrouting {" >> "$temp_nft"
    echo "        type nat hook postrouting priority 100; policy accept;" >> "$temp_nft"

    while IFS='|' read -r lp addr tp last_ip; do
        local current_ip=$(get_ip "$addr")
        if [ -n "$current_ip" ]; then
            echo "        ip daddr $current_ip masquerade" >> "$temp_nft"
        fi
    done < "$CONFIG_FILE"

    echo "    }" >> "$temp_nft"
    echo "}" >> "$temp_nft"

    # 构建 Traffic 看板专用过滤表 (基于连接跟踪方向精准统计)
    echo "table ip nft_mgr_traffic {" >> "$temp_nft"
    echo "    chain forward {" >> "$temp_nft"
    echo "        type filter hook forward priority 0; policy accept;" >> "$temp_nft"
    
    while IFS='|' read -r lp addr tp last_ip; do
        if [ -n "$last_ip" ]; then
            # 统计接收流量 (外部访问本机)
            echo "        ct original dport $lp ct direction original counter comment \"in_${lp}\"" >> "$temp_nft"
            # 统计发送流量 (目标机返回数据)
            echo "        ct original dport $lp ct direction reply counter comment \"out_${lp}\"" >> "$temp_nft"
        fi
    done < "$CONFIG_FILE"
    
    echo "    }" >> "$temp_nft"
    echo "}" >> "$temp_nft"

    # 原子化加载并保存
    nft -f "$temp_nft"
    cat "$temp_nft" > "$NFT_CONF"
    rm -f "$temp_nft"
}

# --- 新增转发 ---
function add_forward() {
    local lport taddr tport tip
    read -p "请输入本地监听端口 (1-65535): " lport
    
    if [[ ! "$lport" =~ ^[0-9]+$ ]] || [ "$lport" -lt 1 ] || [ "$lport" -gt 65535 ]; then
        echo -e "${RED}错误: 本地端口必须是 1 到 65535 之间的纯数字。${PLAIN}"; sleep 2; return
    fi

    if grep -q "^$lport|" "$CONFIG_FILE" 2>/dev/null; then
        echo -e "${RED}错误: 本地端口 $lport 已被占用！请先删除旧规则。${PLAIN}"; sleep 2; return
    fi

    read -p "请输入目标地址 (IP 或 域名): " taddr
    if [ -z "$taddr" ]; then echo -e "${RED}错误: 目标地址不能为空。${PLAIN}"; sleep 2; return; fi

    read -p "请输入目标端口 (1-65535): " tport
    if [[ ! "$tport" =~ ^[0-9]+$ ]] || [ "$tport" -lt 1 ] || [ "$tport" -gt 65535 ]; then
        echo -e "${RED}错误: 目标端口必须是纯数字。${PLAIN}"; sleep 2; return
    fi

    echo -e "${YELLOW}正在解析并验证目标地址...${PLAIN}"
    tip=$(get_ip "$taddr")
    if [ -z "$tip" ]; then echo -e "${RED}错误: 解析失败，请检查域名或服务器网络。${PLAIN}"; sleep 2; return; fi

    echo "$lport|$taddr|$tport|$tip" >> "$CONFIG_FILE"
    apply_rules
    manage_firewall "add" "$lport"
    echo -e "${GREEN}添加成功！映射路径: [本机] $lport -> [目标] $taddr:$tport (${tip})。${PLAIN}"
    sleep 2
}

# --- 流量看板与规则管理 ---
function view_and_del_forward() {
    clear
    if [ ! -s "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}当前没有任何转发规则。${PLAIN}"
        read -p "按回车返回主菜单..."
        return
    fi

    # 提取当前内核中的实时流量数据
    local traffic_data=$(nft list table ip nft_mgr_traffic 2>/dev/null)
    local total_in=0
    local total_out=0

    echo -e "${CYAN}=========================== 实时流量看板 ===========================${PLAIN}"
    printf "%-4s | %-6s | %-16s | %-6s | %-10s | %-10s\n" "序号" "本地" "目标地址" "目标" "接收(RX)" "发送(TX)"
    echo "--------------------------------------------------------------------"
    
    local i=1
    while IFS='|' read -r lp addr tp last_ip; do
        # 利用 sed 精准从规则注释中提取字节数
        local in_bytes=$(echo "$traffic_data" | grep "comment \"in_${lp}\"" | sed -n 's/.*bytes \([0-9]*\).*/\1/p')
        local out_bytes=$(echo "$traffic_data" | grep "comment \"out_${lp}\"" | sed -n 's/.*bytes \([0-9]*\).*/\1/p')
        
        [ -z "$in_bytes" ] && in_bytes=0
        [ -z "$out_bytes" ] && out_bytes=0
        
        # 累加总流量
        total_in=$((total_in + in_bytes))
        total_out=$((total_out + out_bytes))
        
        # 格式化为人能读懂的 KB/MB/GB
        local in_str=$(format_bytes "$in_bytes")
        local out_str=$(format_bytes "$out_bytes")

        # 截断过长的域名以保持表格美观
        local short_addr="${addr:0:15}"
        
        printf "%-4s | %-6s | %-16s | %-6s | %-10s | %-10s\n" "$i" "$lp" "$short_addr" "$tp" "$in_str" "$out_str"
        ((i++))
    done < "$CONFIG_FILE"
    
    echo "--------------------------------------------------------------------"
    echo -e "${CYAN}[ 全局总流量 ]  接收(RX): ${GREEN}$(format_bytes "$total_in")${CYAN}  |  发送(TX): ${YELLOW}$(format_bytes "$total_out")${PLAIN}"
    echo -e "${CYAN}====================================================================${PLAIN}"

    echo -e "\n${YELLOW}提示: 输入规则前面的【序号】即可删除，输入【0】或直接按回车返回。${PLAIN}"
    local action
    read -p "请选择操作: " action

    if [ -z "$action" ] || [ "$action" == "0" ]; then return; fi

    if [[ ! "$action" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}输入无效，请输入正确的数字。${PLAIN}"; sleep 2; return
    fi

    local total_lines=$(wc -l < "$CONFIG_FILE")
    if [ "$action" -lt 1 ] || [ "$action" -gt "$total_lines" ]; then
        echo -e "${RED}序号超出范围！${PLAIN}"; sleep 2; return
    fi

    local del_port=$(sed -n "${action}p" "$CONFIG_FILE" | cut -d'|' -f1)
    sed -i "${action}d" "$CONFIG_FILE"
    apply_rules
    manage_firewall "del" "$del_port"
    echo -e "${GREEN}已成功删除本地端口为 $del_port 的转发规则及防火墙放行。${PLAIN}"
    sleep 2
}

# --- 监控脚本 (DDNS 追踪更新与日志切割清理) ---
function ddns_update() {
    local changed=0
    local temp_file=$(mktemp)
    
    [ ! -d "$LOG_DIR" ] && mkdir -p "$LOG_DIR"
    local today_log="$LOG_DIR/$(date '+%Y-%m-%d').log"
    
    while IFS='|' read -r lp addr tp last_ip; do
        local current_ip=$(get_ip "$addr")
        if [ "$current_ip" != "$last_ip" ] && [ -n "$current_ip" ]; then
            echo "$lp|$addr|$tp|$current_ip" >> "$temp_file"
            changed=1
            echo "[$(date '+%H:%M:%S')] 端口 $lp: $addr 变动 ($last_ip -> $current_ip)" >> "$today_log"
        else
            echo "$lp|$addr|$tp|$last_ip" >> "$temp_file"
        fi
    done < "$CONFIG_FILE"
    mv "$temp_file" "$CONFIG_FILE"
    
    if [ $changed -eq 1 ]; then apply_rules; fi
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
            if [ -d "$LOG_DIR" ] && ls "$LOG_DIR"/*.log >/dev/null 2>&1; then
                echo -e "${GREEN}--- 近 7 天 DDNS 变动日志 ---${PLAIN}"
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

    echo -e "${YELLOW}正在清理系统防火墙放行规则...${PLAIN}"
    while IFS='|' read -r lp addr tp last_ip; do
        manage_firewall "del" "$lp"
    done < "$CONFIG_FILE"

    echo -e "${YELLOW}正在清空内核转发规则及关联组件...${PLAIN}"
    nft flush ruleset 2>/dev/null
    > "$NFT_CONF" 2>/dev/null

    local SCRIPT_PATH=$(realpath "$0")
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH --cron" | crontab -

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
    echo "3. 流量看板与规则管理"
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
        4) 
            while IFS='|' read -r lp addr tp last_ip; do manage_firewall "del" "$lp"; done < "$CONFIG_FILE"
            > "$CONFIG_FILE" ; apply_rules ; echo -e "${GREEN}所有规则已清空。${PLAIN}" ; sleep 2 ;;
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
