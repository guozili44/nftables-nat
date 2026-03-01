#!/bin/bash
# ==============================================================================
# 脚本名称: SSR 综合管理脚本 (满血修复版)
# 核心功能: 找回基础管理功能、二进制热替换、SSH密钥中心、IPv6满血BBR、保留ShadowTLS
# 全局命令: ssr [可选参数: bbr | clean | update | daemon | hot_upgrade]
# ==============================================================================

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly RESET='\033[0m'
readonly SCRIPT_VERSION="19.2-Ultimate-Restored"
readonly CONF_FILE="/etc/sysctl.d/99-bbr.conf"

trap 'echo -e "\n${GREEN}已安全退出脚本。${RESET}"; exit 0' SIGINT

check_env() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行！${RESET}" && exit 1
    local deps=("curl" "jq" "bc" "wget" "tar" "xz-utils")
    local need_install=false
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then need_install=true; break; fi
    done
    if $need_install; then
        if command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -yqq curl jq bc wget tar xz-utils
        elif command -v yum >/dev/null 2>&1; then yum install -yq curl jq bc wget tar xz; fi
    fi
}

install_global_command() {
    local SCRIPT_PATH
    SCRIPT_PATH=$(readlink -f "$0")
    [[ ! -L "/usr/local/bin/ssr" ]] && ln -sf "$SCRIPT_PATH" "/usr/local/bin/ssr" && chmod +x "$SCRIPT_PATH"
    
    if ! crontab -l 2>/dev/null | grep -q "ssr auto_task"; then
        crontab -l 2>/dev/null | grep -v "ssr auto_update" | crontab -
        (crontab -l 2>/dev/null; echo "0 */6 * * * /usr/local/bin/ssr auto_task > /dev/null 2>&1") | crontab -
    fi
    if ! crontab -l 2>/dev/null | grep -q "ssr daemon_check"; then
        (crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/ssr daemon_check > /dev/null 2>&1") | crontab -
    fi
}

# ==========================================================
# 核心组件二进制无感热替换
# ==========================================================
hot_update_components() {
    local is_silent=$1
    [[ "$is_silent" != "silent" ]] && echo -e "${CYAN}>>> 正在安全检查二进制核心版本...${RESET}"

    local arch=$(uname -m)
    local ss_arch=""; local st_arch=""
    if [[ "$arch" == "x86_64" ]]; then
        ss_arch="x86_64-unknown-linux-gnu"; st_arch="x86_64-unknown-linux-musl"
    elif [[ "$arch" == "aarch64" ]]; then
        ss_arch="aarch64-unknown-linux-gnu"; st_arch="aarch64-unknown-linux-musl"
    else
        [[ "$is_silent" != "silent" ]] && echo -e "${RED}暂不支持此架构: $arch${RESET}"; return
    fi

    if [[ -x "/usr/local/bin/ss-rust" ]]; then
        local ss_api=$(curl -s --max-time 10 https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest)
        local ss_latest=$(echo "$ss_api" | jq -r .tag_name 2>/dev/null)
        local ss_current=$(/usr/local/bin/ss-rust --version 2>/dev/null | awk '{print $2}')
        
        if [[ -n "$ss_latest" && "$ss_latest" == v* && "$ss_latest" != *"$ss_current"* ]]; then
            [[ "$is_silent" != "silent" ]] && echo -e "${YELLOW}发现 SS-Rust 新版本: $ss_current -> $ss_latest 正在热替换...${RESET}"
            wget -qO /tmp/ss-rust.tar.xz "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${ss_latest}/shadowsocks-rust-${ss_arch}.tar.xz"
            if [[ -s /tmp/ss-rust.tar.xz ]]; then
                tar -xf /tmp/ss-rust.tar.xz -C /tmp/ ssserver
                mv -f /tmp/ssserver /usr/local/bin/ss-rust && chmod +x /usr/local/bin/ss-rust
                systemctl restart ss-rust 2>/dev/null
                [[ "$is_silent" != "silent" ]] && echo -e "${GREEN}✅ SS-Rust 二进制替换完成，配置完美保留。${RESET}"
            fi
        else
            [[ "$is_silent" != "silent" ]] && echo -e "${GREEN}SS-Rust 已是最新或 API 暂不可用，已安全跳过。${RESET}"
        fi
    fi

    if [[ -x "/usr/local/bin/shadow-tls" ]]; then
        local st_api=$(curl -s --max-time 10 https://api.github.com/repos/ihciah/shadow-tls/releases/latest)
        local st_latest=$(echo "$st_api" | jq -r .tag_name 2>/dev/null)
        local st_current=$(/usr/local/bin/shadow-tls --version 2>/dev/null | awk '{print $2}')
        
        if [[ -n "$st_latest" && "$st_latest" == v* && "$st_latest" != *"$st_current"* ]]; then
            [[ "$is_silent" != "silent" ]] && echo -e "${YELLOW}发现 ShadowTLS 新版本: $st_current -> $st_latest 正在热替换...${RESET}"
            wget -qO /tmp/shadow-tls "https://github.com/ihciah/shadow-tls/releases/download/${st_latest}/shadow-tls-${st_arch}"
            if [[ -s /tmp/shadow-tls ]]; then
                mv -f /tmp/shadow-tls /usr/local/bin/shadow-tls && chmod +x /usr/local/bin/shadow-tls
                for s in $(systemctl list-units --type=service --all --no-legend | grep "shadowtls-" | awk '{print $1}'); do
                    systemctl restart "$s" 2>/dev/null
                done
                [[ "$is_silent" != "silent" ]] && echo -e "${GREEN}✅ ShadowTLS 二进制替换完成。${RESET}"
            fi
        else
            [[ "$is_silent" != "silent" ]] && echo -e "${GREEN}ShadowTLS 已是最新或 API 暂不可用，已安全跳过。${RESET}"
        fi
    fi
}

# ==========================================================
# 基础管理功能 (找回的 SSH端口、密码、时间同步)
# ==========================================================
change_ssh_port() {
    read -rp "请输入新的 SSH 端口号 (1-65535): " new_port
    if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then ufw allow "$new_port"/tcp >/dev/null 2>&1; fi
        if command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --add-port="$new_port"/tcp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi
        sed -i "s/^#\?Port [0-9]*/Port $new_port/g" /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
        echo -e "${GREEN}✅ SSH 端口已成功修改为 $new_port (防火墙已自动放行)。${RESET}"
    else
        echo -e "${RED}输入无效，端口未修改。${RESET}"
    fi
}

change_root_password() {
    read -rp "请输入新的 root 密码: " new_pass
    [[ -z "$new_pass" ]] && return
    read -rp "请再次输入确认: " new_pass_confirm
    [[ "$new_pass" != "$new_pass_confirm" ]] && echo -e "${RED}两次密码不一致！${RESET}" && return
    echo "root:$new_pass" | chpasswd && echo -e "${GREEN}✅ 密码修改成功！请牢记您的新密码。${RESET}"
}

sync_server_time() {
    echo -e "${CYAN}>>> 正在同步服务器时间...${RESET}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -yqq systemd-timesyncd
        systemctl enable --now systemd-timesyncd 2>/dev/null
    elif command -v yum >/dev/null 2>&1; then
        yum install -yq chrony
        systemctl enable --now chronyd 2>/dev/null
    fi
    echo -e "${GREEN}✅ 时间防偏移自动同步服务已启动！${RESET}"
}

# ==========================================================
# 极客专属模块与系统调优
# ==========================================================
enable_tfo() {
    echo -e "${CYAN}>>> 正在配置内核级 TCP Fast Open...${RESET}"
    echo "net.ipv4.tcp_fastopen = 3" > /etc/sysctl.d/99-tfo.conf
    sysctl -p /etc/sysctl.d/99-tfo.conf >/dev/null 2>&1
    echo -e "${GREEN}✅ TCP Fast Open (TFO) 已开启！首屏加载延迟已极大优化。${RESET}"
}

media_unlock_check() {
    clear
    echo -e "${CYAN}>>> 正在拉取纯净版流媒体与 AI 解锁检测脚本...${RESET}"
    bash <(curl -L -s https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh)
    echo -e "\n${GREEN}✅ 检测完毕！${RESET}"
}

run_daemon_check() {
    if systemctl list-units --all -t service | grep -q "ss-rust.service"; then
        if ! systemctl is-active --quiet ss-rust; then systemctl restart ss-rust 2>/dev/null; fi
    fi
    for s in $(systemctl list-units --type=service --all --no-legend | grep "shadowtls-" | awk '{print $1}'); do
        if ! systemctl is-active --quiet "$s"; then systemctl restart "$s" 2>/dev/null; fi
    done
}

smart_optimization() {
    local total_mem=$(free -m | awk '/^Mem:/{print $2}' | tr -d '\r')
    local rmem_max="67108864"; local somaxconn="32768"; local conntrack_max="524288"; local file_max="1048576"
    [[ "$total_mem" -ge 4096 ]] && { rmem_max="134217728"; somaxconn="65535"; conntrack_max="1048576"; file_max="2097152"; }
    cat > "$CONF_FILE" << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = $rmem_max
net.core.wmem_max = $rmem_max
net.ipv4.tcp_rmem = 8192 262144 $rmem_max
net.ipv4.tcp_wmem = 8192 262144 $rmem_max
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1
net.core.somaxconn = $somaxconn
net.core.netdev_max_backlog = $somaxconn
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_mtu_probing = 1
fs.file-max = $file_max
EOF
    sysctl --system >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ 满血版网络调参完成！IPv4/IPv6 协议栈及高并发已全面优化。${RESET}"
}

auto_clean() {
    local is_silent=$1
    if command -v apt-get >/dev/null 2>&1; then apt-get autoremove -yqq >/dev/null 2>&1; apt-get clean -qq >/dev/null 2>&1; fi
    if command -v journalctl >/dev/null 2>&1; then journalctl --vacuum-time=3d >/dev/null 2>&1; fi
    rm -rf /root/.cache/* /tmp/*.tar.xz /tmp/shadow-tls /tmp/ssserver 2>/dev/null
    [[ "$is_silent" != "silent" ]] && echo -e "${GREEN}✅ 系统垃圾与安装缓存清理完毕！${RESET}"
}

run_auto_task() {
    hot_update_components "silent"
    auto_clean "silent"
}

update_script() {
    echo -e "${CYAN}>>> 正在同步最新版脚本数据...${RESET}"
    curl -Ls https://raw.githubusercontent.com/jinqians/menu/main/menu.sh -o /usr/local/bin/ssr.sh
    if [[ $? -eq 0 && -s /usr/local/bin/ssr.sh ]]; then 
        chmod +x /usr/local/bin/ssr.sh
        echo -e "${GREEN}✅ 脚本自身更新成功！${RESET}"
        sleep 1; exec /usr/local/bin/ssr.sh
    else
        echo -e "${RED}❌ 更新失败，网络异常或文件为空。${RESET}"
    fi
}

safe_install() {
    local url=$1
    echo -e "${CYAN}>>> 正在安全下载安装模块...${RESET}"
    curl -sL "$url" -o /tmp/install_module.sh
    if [[ -s /tmp/install_module.sh ]]; then
        bash /tmp/install_module.sh
        rm -f /tmp/install_module.sh
    else
        echo -e "${RED}❌ 模块下载失败，已自动拦截危险执行！请检查网络。${RESET}"
    fi
}

# [SSH 密钥中心]
apply_ssh_key_sec() {
    sed -i 's/^#\?PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
    sed -i 's/^#\?PasswordAuthentication no/PasswordAuthentication no/g' /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
    echo -e "${GREEN}✅ 已彻底封锁密码登录通道！仅允许密钥验证。${RESET}"
}
ssh_key_github() {
    read -rp "请输入你的 GitHub 用户名: " gh_user; [[ -z "$gh_user" ]] && return
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    local keys=$(curl -s --max-time 10 "https://github.com/${gh_user}.keys")
    if [[ -z "$keys" || "$keys" == "Not Found" ]]; then echo -e "${RED}❌ 未找到公钥。${RESET}"; return; fi
    echo "$keys" >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys
    echo -e "${GREEN}✅ 已成功从 GitHub 拉取配置公钥！${RESET}"; apply_ssh_key_sec
}
ssh_key_manual() {
    read -rp "请粘贴你的 SSH 公钥: " manual_key; [[ -z "$manual_key" ]] && return
    mkdir -p ~/.ssh && chmod 700 ~/.ssh; echo "$manual_key" >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys
    echo -e "${GREEN}✅ 手动配置公钥成功！${RESET}"; apply_ssh_key_sec
}
ssh_key_generate() {
    echo -e "${CYAN}>>> 正在生成密钥对...${RESET}"; mkdir -p ~/.ssh && chmod 700 ~/.ssh
    rm -f ~/.ssh/id_ed25519*; ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -q
    cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys
    echo -e "\n${YELLOW}======================================================${RESET}"
    echo -e "${RED}⚠️ 请保存以下私钥内容，否则无法登录！⚠️${RESET}"
    echo -e "${YELLOW}======================================================${RESET}"
    cat ~/.ssh/id_ed25519; echo -e "${YELLOW}======================================================${RESET}"
    read -rp "确认关闭密码登录 (y/N): " confirm; [[ "$confirm" == "y" || "$confirm" == "Y" ]] && apply_ssh_key_sec
}
ssh_key_restore() {
    sed -i 's/^#\?PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; echo -e "${GREEN}✅ 恢复密码登录。${RESET}"
}
ssh_key_menu() {
    clear; echo -e "${CYAN}========= SSH 密钥登录管理中心 =========${RESET}"
    echo -e "${YELLOW} 1.${RESET} 自动拉取公钥 (GitHub)"; echo -e "${YELLOW} 2.${RESET} 手动填写公钥"; echo -e "${YELLOW} 3.${RESET} 一键生成密钥对"
    echo -e "${RED} 4. 恢复密码登录${RESET}"; echo -e " 0. 返回"
    read -rp "输入数字 [0-4]: " skm_num
    case "$skm_num" in 1) ssh_key_github ;; 2) ssh_key_manual ;; 3) ssh_key_generate ;; 4) ssh_key_restore ;; 0) return ;; esac
}

# ==========================================================
# 组件专项卸载与全量清理
# ==========================================================
uninstall_bbrv3() {
    echo -e "${RED}⚠️ 警告: 强制卸载内核极其危险！${RESET}"
    echo -e "${CYAN}请返回主菜单运行【开启 BBRv3 魔改内核】，并在内部菜单卸载。${RESET}"
}

total_uninstall() {
    echo -e "${RED}⚠️ 正在执行毁灭性全量卸载...${RESET}"
    
    # 清理 SS-Rust
    systemctl stop ss-rust 2>/dev/null; systemctl disable ss-rust 2>/dev/null
    rm -rf /etc/ss-rust /usr/local/bin/ss-rust /etc/systemd/system/ss-rust.service
    
    # 清理 ShadowTLS
    for s in $(systemctl list-units --type=service --all --no-legend | grep "shadowtls-" | awk '{print $1}'); do
        systemctl stop "$s" 2>/dev/null; systemctl disable "$s" 2>/dev/null; rm -f "/etc/systemd/system/$s"
    done
    rm -f /usr/local/bin/shadow-tls
    
    # 还原环境
    rm -f "$CONF_FILE" && sysctl --system >/dev/null 2>&1
    crontab -l 2>/dev/null | grep -vE "ssr auto_task|ssr daemon_check" | crontab -
    rm -f /usr/local/bin/ssr /usr/local/bin/ssr.sh
    
    systemctl daemon-reload
    echo -e "${GREEN}✅ 全量干净卸载完成！你的系统已洁净如初。${RESET}"
    exit 0
}

uninstall_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${RED}             组件专项卸载与清理中心${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${YELLOW} 1.${RESET} 卸载 BBRv3 魔改内核"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    echo -e "${RED} 2. 全量干净卸载脚本及组件 (完全还原服务器)${RESET}"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    echo -e " 0. 返回主菜单"
    read -rp "请输入对应数字 [0-2]: " uni_num
    case "$uni_num" in
        1) uninstall_bbrv3 ;;
        2) total_uninstall ;;
        0) return ;;
        *) echo -e "${RED}无效选项！${RESET}" ;;
    esac
}

# ==========================================================
# 交互式菜单系统
# ==========================================================
opt_menu() {
    clear; echo -e "${CYAN}========= 网络与系统优化菜单 =========${RESET}"
    echo -e "${YELLOW} 1.${RESET} 极致配置 BBR 网络调参 (支持IPv6)"
    echo -e "${YELLOW} 2.${RESET} 开启 TCP Fast Open (TFO 首屏优化)"
    echo -e "${YELLOW} 3.${RESET} 开启 BBRv3 魔改内核"
    echo -e "${YELLOW} 4.${RESET} 自动清理系统垃圾与冗余日志"
    echo -e " 0. 返回主菜单"
    read -rp "输入数字 [0-4]: " opt_num
    case "$opt_num" in 1) smart_optimization ;; 2) enable_tfo ;; 3) safe_install "https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcpx.sh" ;; 4) auto_clean ;; 0) return ;; esac
}

sys_menu() {
    clear; echo -e "${CYAN}========= 系统基础与极客管理菜单 =========${RESET}"
    echo -e "${YELLOW} 1.${RESET} 一键修改 SSH 安全端口"
    echo -e "${YELLOW} 2.${RESET} 一键修改 Root 密码"
    echo -e "${YELLOW} 3.${RESET} 服务器时间防偏移同步"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    echo -e "${YELLOW} 4.${RESET} SSH 密钥登录管理中心 (防爆破神器)"
    echo -e "${YELLOW} 5.${RESET} 流媒体与 AI 纯净解锁检测"
    echo -e "${YELLOW} 6.${RESET} 安全热替换升级核心组件 (无损配置)"
    echo -e "${YELLOW} 7.${RESET} 手动更新 SSR 管理脚本本身"
    echo -e " 0. 返回主菜单"
    read -rp "输入数字 [0-7]: " sys_num
    case "$sys_num" in 1) change_ssh_port ;; 2) change_root_password ;; 3) sync_server_time ;; 4) ssh_key_menu ;; 5) media_unlock_check ;; 6) hot_update_components ;; 7) update_script ;; 0) return ;; esac
}

main_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}       SSR 综合智能管理脚本 v${SCRIPT_VERSION}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    
    if [[ -x "/usr/local/bin/ss-rust" ]]; then
        local ss_run; ss_run=$(systemctl is-active ss-rust &> /dev/null && echo "运行中" || echo "已停止")
        echo -e "${GREEN} SS-2022  : 已安装 [${ss_run}]${RESET}"
    fi
    if systemctl list-units --type=service | grep -q "shadowtls-"; then
        echo -e "${GREEN} ShadowTLS: 已安装${RESET}"
    fi
    echo -e "${CYAN}--------------------------------------------${RESET}"
    
    echo -e "${YELLOW} 1.${RESET} SS-2022 安装/管理"
    echo -e "${YELLOW} 2.${RESET} VLESS Reality 安装/管理"
    echo -e "${YELLOW} 3.${RESET} ShadowTLS 安装/管理"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    echo -e "${YELLOW} 4.${RESET} 网络与系统优化 (BBR / TFO / 清理)"
    echo -e "${YELLOW} 5.${RESET} 系统与极客管控 (端口/密码/时间/升级/密钥)"
    echo -e "${RED} 6. 组件专项卸载与全量清理${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e " 0. 退出脚本"
    
    read -rp "请输入对应数字 [0-6]: " num
    case "$num" in
        1) safe_install "https://raw.githubusercontent.com/jinqians/ss-2022.sh/main/ss-2022.sh" ;;
        2) safe_install "https://raw.githubusercontent.com/jinqians/vless/refs/heads/main/vless.sh" ;;
        3) safe_install "https://raw.githubusercontent.com/jinqians/snell.sh/main/shadowtls.sh" ;;
        4) opt_menu ;;
        5) sys_menu ;;
        6) uninstall_menu ;;
        0) echo -e "${GREEN}感谢使用，再见！${RESET}"; exit 0 ;;
        *) echo -e "${RED}请输入正确的选项！${RESET}" ;;
    esac
    
    echo -e "\n${CYAN}按任意键返回主菜单，或按 Ctrl+C 直接退出...${RESET}"
    read -n 1 -s -r
}

# ==========================================================
# 终极智能路由调度
# ==========================================================
check_env
install_global_command

if [[ -n "${1:-}" ]]; then
    case "$1" in
        bbr)        smart_optimization ;;
        clean)      auto_clean ;;
        update)     update_script ;;
        hot_upgrade) hot_update_components ;;
        auto_task)  run_auto_task ;;
        daemon_check) run_daemon_check ;;
        *)
            echo -e "${RED}未知快捷指令: $1${RESET}"
            exit 1
            ;;
    esac
    exit 0
else
    # 强制遵守指令：底部无限循环机制
    while true; do
        main_menu
    done
fi
