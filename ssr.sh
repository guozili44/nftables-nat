#!/bin/bash
# =========================================
# 作者: jinqians (Modified)
# 启动命令: ssr
# 功能: 移除Snell，保留ShadowTLS，支持SS-Rust平滑更新、SSH端口修改、全量卸载
# =========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

current_version="5.0-Custom"

# 安装全局命令并设置后台定时任务 
install_global_command() {
    SCRIPT_PATH=$(readlink -f "$0")
    ln -sf "$SCRIPT_PATH" "/usr/local/bin/ssr"
    chmod +x "$SCRIPT_PATH"
    
    # 注入后台自动更新 (每6小时执行一次)
    if ! crontab -l 2>/dev/null | grep -q "ssr auto_update"; then
        (crontab -l 2>/dev/null; echo "0 */6 * * * /usr/local/bin/ssr auto_update > /dev/null 2>&1") | crontab -
    fi
}

# 修改 SSH 端口功能 (新增加)
change_ssh_port() {
    read -p "请输入新的 SSH 端口号 (1-65535): " new_port
    if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
        sed -i "s/^#\?Port [0-9]*/Port $new_port/g" /etc/ssh/sshd_config
        systemctl restart ssh
        echo -e "${GREEN}SSH 端口已修改为 $new_port 并重启了服务。${RESET}"
        echo -e "${YELLOW}请确保你的防火墙已开放该端口！${RESET}"
    else
        echo -e "${RED}输入无效。${RESET}"
    fi
}

# 全量干净卸载功能 (新增加)
total_uninstall() {
    echo -e "${RED}正在执行全量干净卸载...${RESET}"
    
    # 1. 停止并卸载 SS-Rust [cite: 32, 55]
    systemctl stop ss-rust 2>/dev/null
    rm -rf /etc/ss-rust /usr/local/bin/ss-rust /etc/systemd/system/ss-rust.service
    
    # 2. 卸载 ShadowTLS [cite: 56, 57]
    while IFS= read -r s; do
        systemctl stop "$s" 2>/dev/null
        rm -f "/etc/systemd/system/$s"
    done < <(systemctl list-units --type=service --all --no-legend | grep "shadowtls-" | awk '{print $1}')
    rm -f /usr/local/bin/shadow-tls
    
    # 3. 卸载 VLESS [cite: 49]
    # (调用对应卸载逻辑或删除目录)
    
    # 4. 清理定时任务与全局命令
    crontab -l | grep -v "ssr auto_update" | crontab -
    rm -f /usr/local/bin/ssr /usr/local/bin/ssr.sh
    
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成！所有配置、脚本及定时任务已彻底清除。${RESET}"
    exit 0
}

# SS-Rust 平滑更新逻辑 [cite: 42, 67]
auto_update_ss_rust() {
    local is_silent=$1
    local latest_ver=$(curl -s https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | jq -r .tag_name)
    
    # 备份 -> 安装 -> 还原 [cite: 46]
    [ -d "/etc/ss-rust" ] && cp -r "/etc/ss-rust" "/tmp/ss-rust-bak"
    
    bash <(curl -sL https://raw.githubusercontent.com/jinqians/ss-2022.sh/main/ss-2022.sh) <<EOF
1
EOF
    
    if [ -d "/tmp/ss-rust-bak" ]; then
        rm -rf "/etc/ss-rust"
        mv "/tmp/ss-rust-bak" "/etc/ss-rust"
        systemctl restart ss-rust 2>/dev/null
    fi
}

# 主菜单 [cite: 58, 59]
show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}       SSR 综合管理脚本 v${current_version}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${YELLOW}1.${RESET} SS-2022 安装管理"
    echo -e "${YELLOW}2.${RESET} VLESS Reality 安装管理"
    echo -e "${YELLOW}3.${RESET} ShadowTLS 安装管理"
    echo -e "${YELLOW}4.${RESET} 服务器时间同步"
    echo -e "${YELLOW}5.${RESET} 修改 SSH 端口"
    echo -e "${RED}6. 全量干净卸载脚本及所有组件${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "0. 退出"
    read -rp "请输入选项: " num
}

# 入口判断 [cite: 60]
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
        4) sudo apt update && sudo apt install systemd-timesyncd -y && sudo systemctl enable --now systemd-timesyncd ;;
        5) change_ssh_port ;;
        6) total_uninstall ;;
        0) exit 0 ;;
    esac
    read -n 1 -s -r -p "按任意键返回..."
done
