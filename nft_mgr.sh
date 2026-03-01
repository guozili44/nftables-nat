#!/bin/bash

# 配置文件路径
CONFIG_FILE="/etc/nft_forward_list.conf"
NFT_CONF="/etc/nftables.conf"

# Github 脚本更新链接
RAW_URL="https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/nft_mgr.sh"
PROXY_URL="https://ghproxy.net/https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/nft_mgr.sh"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行!${PLAIN}" && exit 1

# --- 自动设置快捷命令 ---
function setup_alias() {
    local shell_rc="$HOME/.bashrc"
    local current_path=$(realpath "$0" 2>/dev/null || readlink -f "$0")
    
    if [[ ! -t 0 ]]; then return; fi

    if ! grep -q "alias nft=" "$shell_rc" 2>/dev/null; then
        echo "alias nft='bash \"$current_path\"'" >> "$shell_rc"
        echo -e "${GREEN}[系统提示] 快捷命令 'nft' 已添加！下次重新连接 SSH 后，可直接输入 nft 打开面板。${PLAIN}"
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
    sudo sysctl --system
    echo -e "${GREEN}系统优化配置已应用。${PLAIN}"
    sleep 2
}

# --- 域名解析函数 ---
function get_ip() {
    local addr=$1
    if [[ $addr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$addr"
    else
        dig +short "$addr" | tail -n1
    fi
}

# --- 初始化 nftables 结构 ---
function init_nft() {
    nft flush ruleset
    nft add table ip nat
    nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; }
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; }
    touch $CONFIG_FILE
}

# --- 新增转发 ---
function add_forward() {
    read -p "请输入本地监听端口: " lport
    read -p "请输入目标地址 (IP 或 域名): " taddr
    read -p "请输入目标端口: " tport

    tip=$(get_ip "$taddr")
    if [ -z "$tip" ]; then
        echo -e "${RED}无法解析地址，请检查输入。${PLAIN}"
        sleep 2
        return
    fi

    echo "$lport|$taddr|$tport|$tip" >> $CONFIG_FILE
    apply_rules
    echo -e "${GREEN}添加成功！${PLAIN}"
    sleep 2
}

# --- 应用规则到内核 ---
function apply_rules() {
    nft flush ruleset
    nft add table ip nat
    nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; }
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; }

    while IFS='|' read -r lp addr tp last_ip; do
        current_ip=$(get_ip "$addr")
        if [ ! -z "$current_ip" ]; then
            nft add rule ip nat prerouting tcp dport $lp dnat to $current_ip:$tp
            nft add rule ip nat prerouting udp dport $lp dnat to $current_ip:$tp
            nft add rule ip nat postrouting ip daddr $current_ip masquerade
        fi
    done < $CONFIG_FILE
    
    nft list ruleset > $NFT_CONF
}

# --- 查看与删除功能合并 ---
function view_and_del_forward() {
    clear
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}当前没有任何转发规则。${PLAIN}"
        read -p "按回车返回主菜单..."
        return
    fi

    echo -e "${GREEN}--- 当前转发列表 ---${PLAIN}"
    echo "----------------------------------------------------------------------"
    printf "%-5s | %-10s | %-20s | %-10s | %-15s\n" "序号" "本地端口" "目标地址" "目标端口" "当前映射IP"
    
    local i=1
    while IFS='|' read -r lp addr tp last_ip; do
        current_ip=$(get_ip "$addr")
        printf "%-5s | %-10s | %-20s | %-10s | %-15s\n" "$i" "$lp" "$addr" "$tp" "$current_ip"
        ((i++))
    done < "$CONFIG_FILE"
    echo "----------------------------------------------------------------------"

    echo -e "${YELLOW}提示: 输入规则前面的【序号】即可删除，输入【0】或直接按回车返回。${PLAIN}"
    read -p "请选择操作: " action

    if [ -z "$action" ] || [ "$action" == "0" ]; then
        return
    fi

    if [[ ! "$action" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}输入无效，请输入正确的数字序号。${PLAIN}"
        sleep 2
        return
    fi

    local total_lines=$(wc -l < "$CONFIG_FILE")
    if [ "$action" -lt 1 ] || [ "$action" -gt "$total_lines" ]; then
        echo -e "${RED}序号超出范围，没有该规则！${PLAIN}"
        sleep 2
        return
    fi

    local del_port=$(sed -n "${action}p" "$CONFIG_FILE" | cut -d'|' -f1)
    
    sed -i "${action}d" "$CONFIG_FILE"
    apply_rules
    echo -e "${GREEN}已成功删除序号 $action (本地端口: $del_port) 的转发规则。${PLAIN}"
    sleep 2
}

# --- 监控脚本 (DDNS 追踪更新) ---
function ddns_update() {
    local changed=0
    temp_file=$(mktemp)
    while IFS='|' read -r lp addr tp last_ip; do
        current_ip=$(get_ip "$addr")
        if [ "$current_ip" != "$last_ip" ] && [ ! -z "$current_ip" ]; then
            echo "$lp|$addr|$tp|$current_ip" >> "$temp_file"
            changed=1
        else
            echo "$lp|$addr|$tp|$last_ip" >> "$temp_file"
        fi
    done < $CONFIG_FILE
    mv "$temp_file" $CONFIG_FILE
    
    if [ $changed -eq 1 ]; then
        apply_rules
        echo "[$(date)] 检测到域名 IP 变动，规则已更新。"
    fi
}

# --- 管理定时监控 (DDNS 同步) ---
function manage_cron() {
    clear
    echo -e "${GREEN}--- 管理定时监控 (DDNS 同步) ---${PLAIN}"
    echo "1. 自动添加定时任务 (每分钟检测)"
    echo "2. 一键删除定时任务"
    echo "0. 返回主菜单"
    echo "--------------------------------"
    read -p "请选择操作 [0-2]: " cron_choice

    case $cron_choice in
        1)
            SCRIPT_PATH=$(realpath "$0")
            (crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH --cron") && echo -e "${YELLOW}定时任务已存在。${PLAIN}" && sleep 2 && return
            (crontab -l 2>/dev/null; echo "* * * * * $SCRIPT_PATH --cron > /dev/null 2>&1") | crontab -
            echo -e "${GREEN}定时任务已添加！每分钟将自动执行 IP 同步。${PLAIN}"
            sleep 2
            ;;
        2)
            SCRIPT_PATH=$(realpath "$0")
            crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH --cron" | crontab -
            echo -e "${YELLOW}定时任务已清除。${PLAIN}"
            sleep 2
            ;;
        0) return ;;
        *) echo "无效选项" ; sleep 1 ;;
    esac
}

# --- 手动跟随 GitHub 更新脚本 ---
function update_script() {
    clear
    echo -e "${GREEN}--- 脚本更新 ---${PLAIN}"
    echo "1. 从 GitHub 官方直连更新 (推荐海外机)"
    echo "2. 从 GHProxy 代理更新 (推荐国内机)"
    echo "0. 取消并返回主菜单"
    echo "--------------------------------"
    read -p "请选择更新线路 [0-2]: " up_choice

    local target_url=""
    case $up_choice in
        1) target_url="$RAW_URL" ;;
        2) target_url="$PROXY_URL" ;;
        0) return ;;
        *) echo -e "${RED}无效选项。${PLAIN}" ; sleep 1 ; return ;;
    esac

    echo -e "${YELLOW}正在拉取最新代码...${PLAIN}"
    SCRIPT_PATH=$(realpath "$0")
    TEMP_FILE=$(mktemp)

    if curl -sL "$target_url" -o "$TEMP_FILE"; then
        # 严格校验下载内容是否为 bash 脚本
        if grep -q "#!/bin/bash" "$TEMP_FILE"; then
            cat "$TEMP_FILE" > "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
            rm -f "$TEMP_FILE"
            echo -e "${GREEN}更新成功！脚本已替换为最新版本。${PLAIN}"
            echo -e "${YELLOW}面板即将自动退出以应用新版本，请稍后重新执行 'nft' 启动。${PLAIN}"
            sleep 3
            exit 0
        else
            echo -e "${RED}更新失败: 下载的文件格式不正确 (未检测到脚本头)。这可能是代理失效或仓库地址有误。${PLAIN}"
            rm -f "$TEMP_FILE"
            sleep 3
        fi
    else
        echo -e "${RED}更新失败: 网络连接超时或链接无效。${PLAIN}"
        rm -f "$TEMP_FILE"
        sleep 3
    fi
}

# --- 主菜单 ---
function main_menu() {
    clear
    echo -e "${GREEN}--- nftables 端口转发管理面板 ---${PLAIN}"
    echo "1. 开启 BBR + 系统转发优化"
    echo "2. 新增端口转发 (支持域名/IP)"
    echo "3. 查看 / 删除端口转发"
    echo "4. 清空所有转发规则"
    echo "5. 管理定时监控 (DDNS 同步)"
    echo "6. 从 GitHub 更新当前脚本"
    echo "0. 退出"
    echo "--------------------------------"
    read -p "请选择操作 [0-6]: " choice

    case $choice in
        1) optimize_system ;;
        2) add_forward ;;
        3) view_and_del_forward ;;
        4) > $CONFIG_FILE ; apply_rules ; echo -e "${GREEN}所有转发规则已清空。${PLAIN}" ; sleep 2 ;;
        5) manage_cron ;;
        6) update_script ;;
        0) exit 0 ;;
        *) echo "无效选项" ; sleep 1 ;;
    esac
}

# 检查依赖
if ! command -v dig &> /dev/null; then
    apt-get update && apt-get install -y dnsutils || yum install -y bind-utils
fi

# 如果带参数运行（用于定时任务）
if [ "$1" == "--cron" ]; then
    ddns_update
    exit 0
fi

# 保持循环
while true; do main_menu; done
