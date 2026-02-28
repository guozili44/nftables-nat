#!/bin/bash
# =========================================
# 作者: jinqians (Modified)
# 描述: 统一管理脚本 - 移除 Snell，支持 SS-Rust 平滑更新（保留配置）
# 启动命令: ssr
# =========================================

# [cite_start]定义颜色代码 [cite: 1]
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# [cite_start]当前版本号 [cite: 1]
current_version="3.6-Custom"

# [cite_start]安装全局命令 (由 menu 改为 ssr) [cite: 2]
install_global_command() {
    echo -e "${CYAN}正在配置全局命令 'ssr'...${RESET}"
    SCRIPT_PATH=$(readlink -f "$0")
    if [ -f "/usr/local/bin/ssr" ]; then
        rm -f "/usr/local/bin/ssr"
    fi
    ln -s "$SCRIPT_PATH" "/usr/local/bin/ssr"
    chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}配置成功！现在可以使用 'ssr' 命令启动脚本${RESET}"
}

# [cite_start]检查依赖 [cite: 3]
check_dependencies() {
    local deps=("bc" "curl" "jq")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            if [ -x "$(command -v apt)" ]; then
                apt update && apt install -y bc curl jq
            elif [ -x "$(command -v yum)" ]; then
                yum install -y bc curl jq
            fi
            break
        fi
    done
}

# 服务器时间同步 (新增)
sync_time() {
    echo -e "${CYAN}正在同步服务器时间...${RESET}"
    sudo apt update && sudo apt install systemd-timesyncd -y && sudo systemctl enable --now systemd-timesyncd
    echo -e "${GREEN}时间同步已完成并开启自动同步。${RESET}"
}

# [cite_start]自动更新 SS-Rust (优化：更新并保留配置) [cite: 46]
auto_update_ss_rust() {
    echo -e "${CYAN}正在检查 Shadowsocks-Rust 最新版本...${RESET}"
    local latest_ver=$(curl -s https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | jq -r .tag_name)
    
    if [ -z "$latest_ver" ] || [ "$latest_ver" == "null" ]; then
        echo -e "${RED}获取版本失败，请检查网络${RESET}"
        return
    fi

    echo -e "${YELLOW}发现新版本: $latest_ver，准备平滑更新...${RESET}"

    # 1. 备份现有配置目录 (如果存在)
    if [ -d "/etc/ss-rust" ]; then
        echo -e "${CYAN}发现现有配置，正在临时备份...${RESET}"
        cp -r "/etc/ss-rust" "/tmp/ss-rust-bak"
    fi

    # [cite_start]2. 调用原安装脚本进行覆盖安装 [cite: 48]
    manage_ss_rust

    # 3. 还原配置
    if [ -d "/tmp/ss-rust-bak" ]; then
        echo -e "${CYAN}正在还原旧配置...${RESET}"
        rm -rf "/etc/ss-rust"
        mv "/tmp/ss-rust-bak" "/etc/ss-rust"
        systemctl restart ss-rust 2>/dev/null
        echo -e "${GREEN}配置已成功沿用，服务已重启。${RESET}"
    fi
}

# [cite_start]检查服务状态 (移除 Snell 部分) [cite: 16, 31, 32]
check_and_show_status() {
    echo -e "\n${CYAN}=== 服务状态检查 ===${RESET}"
    if [[ -e "/usr/local/bin/ss-rust" ]]; then
        local ss_running=$(systemctl is-active ss-rust &> /dev/null && echo 1 || echo 0)
        echo -e "${GREEN}SS-2022 已安装${RESET}  ${GREEN}运行中：${ss_running}/1${RESET}"
    else
        echo -e "${YELLOW}SS-2022 未安装${RESET}"
    fi
}

# [cite_start]管理函数 [cite: 48, 49]
manage_ss_rust() { bash <(curl -sL https://raw.githubusercontent.com/jinqians/ss-2022.sh/main/ss-2022.sh); }
manage_vless() { bash <(curl -sL https://raw.githubusercontent.com/jinqians/vless/refs/heads/main/vless.sh); }
manage_shadowtls() { bash <(curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/shadowtls.sh); }

# [cite_start]卸载 SS-Rust (根据需求，卸载仍需彻底清理) [cite: 55]
uninstall_ss_rust() {
    echo -e "${CYAN}正在卸载 SS-2022...${RESET}"
    systemctl stop ss-rust 2>/dev/null
    rm -f "/usr/local/bin/ss-rust"
    rm -rf "/etc/ss-rust"
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成！${RESET}"
}

# [cite_start]主菜单 [cite: 58, 59]
show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}          SSR 综合管理脚本 v${current_version}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    check_and_show_status
    echo -e "\n${YELLOW}=== 核心功能 ===${RESET}"
    echo -e "${GREEN}1.${RESET} SS-2022 安装管理"
    echo -e "${GREEN}2.${RESET} 自动更新 SS-Rust (自动沿用旧配置)"
    echo -e "${GREEN}3.${RESET} 服务器时间同步"
    echo -e "${GREEN}4.${RESET} VLESS Reality 安装管理"
    echo -e "${GREEN}5.${RESET} ShadowTLS 安装管理"
    echo -e "\n${YELLOW}=== 卸载功能 ===${RESET}"
    echo -e "${GREEN}6.${RESET} 卸载 SS-2022"
    echo -e "${GREEN}7.${RESET} 卸载 ShadowTLS"
    echo -e "\n${YELLOW}=== 系统功能 ===${RESET}"
    echo -e "${GREEN}0.${RESET} 退出"
    echo -e "${CYAN}============================================${RESET}"
    read -rp "请输入选项: " num
}

# [cite_start]初始检查 [cite: 15]
if [ "$(id -u)" != "0" ]; then echo -e "${RED}请以 root 权限运行${RESET}"; exit 1; fi
check_dependencies
install_global_command

while true; do
    show_menu
    case "$num" in
        1) manage_ss_rust ;;
        2) auto_update_ss_rust ;;
        3) sync_time ;;
        4) manage_vless ;;
        5) manage_shadowtls ;;
        6) uninstall_ss_rust ;;
        [cite_start]7) # 卸载 ShadowTLS [cite: 56, 57]
           while IFS= read -r s; do systemctl stop "$s"; rm -f "/etc/systemd/system/$s"; done < <(systemctl list-units --type=service --all --no-legend | grep "shadowtls-" | awk '{print $1}')
           rm -f "/usr/local/bin/shadow-tls"
           echo -e "${GREEN}ShadowTLS 卸载完成${RESET}" ;;
        0) exit 0 ;;
        *) echo -e "${RED}请输入正确选项${RESET}" ;;
    esac
    echo -e "\n${CYAN}按任意键返回主菜单...${RESET}"
    read -n 1 -s -r
done
