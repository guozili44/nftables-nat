#!/bin/bash
# =========================================
# 作者: jinqians (Modified)
# 启动命令: ssr
# 功能: 移除Snell，保留ShadowTLS，支持SS-Rust后台静默平滑更新
# =========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

current_version="4.0-Custom"

# 1. 安装全局命令并设置后台定时任务
install_global_command() {
    SCRIPT_PATH=$(readlink -f "$0")
    
    # 设置快捷启动 ssr
    if [ ! -L "/usr/local/bin/ssr" ]; then
        ln -sf "$SCRIPT_PATH" "/usr/local/bin/ssr"
        chmod +x "$SCRIPT_PATH"
    fi

    # 注入后台自动更新定时任务 (每6小时执行一次)
    if ! crontab -l 2>/dev/null | grep -q "ssr auto_update"; then
        (crontab -l 2>/dev/null; echo "0 */6 * * * /usr/local/bin/ssr auto_update > /dev/null 2>&1") | crontab -
    fi
}

# 2. 核心功能：自动更新并保留配置
auto_update_ss_rust() {
    local is_silent=$1
    [ "$is_silent" != "silent" ] && echo -e "${CYAN}正在检查 Shadowsocks-Rust 最新版本...${RESET}"
    
    local latest_ver=$(curl -s https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | jq -r .tag_name)
    [ -z "$latest_ver" ] || [ "$latest_ver" == "null" ] && return 1

    # 如果是后台运行，对比版本，相同则跳过
    if [ "$is_silent" == "silent" ] && [ -f "/usr/local/bin/ss-rust" ]; then
        local current_ver=$(/usr/local/bin/ss-rust --version | awk '{print $2}')
        [[ "$latest_ver" == *"$current_ver"* ]] && return 0
    fi

    # 平滑更新逻辑：备份配置 -> 安装 -> 还原配置
    [ -d "/etc/ss-rust" ] && cp -r "/etc/ss-rust" "/tmp/ss-rust-bak"
    
    # 执行原作者安装脚本 [cite: 48]
    bash <(curl -sL https://raw.githubusercontent.com/jinqians/ss-2022.sh/main/ss-2022.sh) <<EOF
1
EOF

    if [ -d "/tmp/ss-rust-bak" ]; then
        rm -rf "/etc/ss-rust"
        mv "/tmp/ss-rust-bak" "/etc/ss-rust"
        systemctl restart ss-rust 2>/dev/null
    fi
    [ "$is_silent" != "silent" ] && echo -e "${GREEN}SS-Rust 已平滑更新至 $latest_ver${RESET}"
}

# 3. 服务器时间同步
sync_time() {
    echo -e "${CYAN}正在同步服务器时间...${RESET}"
    sudo apt update && sudo apt install systemd-timesyncd -y && sudo systemctl enable --now systemd-timesyncd [cite: 5, 6, 8]
    echo -e "${GREEN}时间同步已完成并开启自动同步${RESET}"
}

# 4. 服务状态检查 (保留 ShadowTLS，移除 Snell)
check_and_show_status() {
    echo -e "\n${CYAN}=== 服务状态检查 ===${RESET}"
    # SS-Rust 状态 [cite: 32, 33, 34, 35]
    if [[ -e "/usr/local/bin/ss-rust" ]]; then
        local ss_running=$(systemctl is-active ss-rust &> /dev/null && echo 1 || echo 0)
        echo -e "${GREEN}SS-2022 已安装${RESET}  运行中：${ss_running}/1"
    fi
    # ShadowTLS 状态 
    if systemctl list-units --type=service | grep -q "shadowtls-"; then
        echo -e "${GREEN}ShadowTLS 已安装${RESET}"
    fi
}

# 主菜单 [cite: 58, 60]
show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}       SSR 综合管理脚本 (自动更新版)${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    check_and_show_status
    echo -e "\n${YELLOW}=== 核心功能 ===${RESET}"
    echo -e "${GREEN}1.${RESET} SS-2022 安装/管理"
    echo -e "${GREEN}2.${RESET} VLESS Reality 安装/管理"
    echo -e "${GREEN}3.${RESET} ShadowTLS 安装/管理"
    echo -e "${GREEN}4.${RESET} 服务器时间同步 (systemd-timesyncd)"
    echo -e "\n${YELLOW}=== 系统与卸载 ===${RESET}"
    echo -e "${GREEN}5.${RESET} 卸载 SS-2022"
    echo -e "${GREEN}6.${RESET} 卸载 ShadowTLS"
    echo -e "${GREEN}0.${RESET} 退出"
    read -rp "请输入选项: " num
}

# 脚本入口逻辑
if [ "$1" == "auto_update" ]; then
    auto_update_ss_rust "silent"
    exit 0
fi

install_global_command
while true; do
    show_menu
    case "$num" in
        1) bash <(curl -sL https://raw.githubusercontent.com/jinqians/ss-2022.sh/main/ss-2022.sh) ;;
        2) bash <(curl -sL https://raw.githubusercontent.com/jinqians/vless/refs/heads/main/vless.sh) ;;
        3) bash <(curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/shadowtls.sh) ;;
        4) sync_time ;;
        5) 
            systemctl stop ss-rust && rm -rf /etc/ss-rust /usr/local/bin/ss-rust
            echo -e "${GREEN}SS-2022 卸载完成${RESET}" ;;
        6) # 卸载 ShadowTLS [cite: 56, 57]
           while IFS= read -r s; do systemctl stop "$s"; rm -f "/etc/systemd/system/$s"; done < <(systemctl list-units --type=service --all --no-legend | grep "shadowtls-" | awk '{print $1}')
           echo -e "${GREEN}ShadowTLS 卸载完成${RESET}" ;;
        0) exit 0 ;;
    esac
    read -n 1 -s -r -p "按任意键返回..."
done
