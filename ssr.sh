cat > /usr/local/bin/ssr << 'EOF_MAGIC_END'
#!/bin/bash
# ==============================================================================
# 脚本名称: SSR 综合管理脚本 (终极链接修复版)
# 核心功能: 修复 SS-Rust 动态版本号下载链接、防爆校验、全集成核爆、无痕卸载
# 全局命令: ssr [可选参数: bbr | nat | clean | update | daemon | nuke | daily_task]
# ==============================================================================

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly RESET='\033[0m'
readonly SCRIPT_VERSION="20.15-URL-Fixed"
readonly CONF_FILE="/etc/sysctl.d/99-bbr.conf"
readonly NAT_CONF_FILE="/etc/sysctl.d/99-nat.conf"

trap 'echo -e "\n${GREEN}已安全退出脚本。${RESET}"; exit 0' SIGINT

check_env() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行！${RESET}" && exit 1
    local deps=("curl" "jq" "bc" "wget" "tar" "xz-utils" "openssl" "unzip")
    local need_install=false
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then need_install=true; break; fi
    done
    if $need_install; then
        if command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -yqq curl jq bc wget tar xz-utils openssl unzip
        elif command -v yum >/dev/null 2>&1; then yum install -yq curl jq bc wget tar xz openssl unzip; fi
    fi
}

install_global_command() {
    if [[ "$(readlink -f "$0")" != "/usr/local/bin/ssr" ]]; then
        cp -f "$0" /usr/local/bin/ssr; chmod +x /usr/local/bin/ssr
    fi
    crontab -l 2>/dev/null | grep -vE "ssr auto_update|ssr auto_task|ssr daemon_check|ssr hot_upgrade|ssr clean|ssr daily_task" | crontab -
    if ! crontab -l 2>/dev/null | grep -q "ssr daily_task"; then (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/ssr daily_task > /dev/null 2>&1") | crontab -; fi
    if ! crontab -l 2>/dev/null | grep -q "ssr daemon_check"; then (crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/ssr daemon_check > /dev/null 2>&1") | crontab -; fi
}

remove_firewall_rule() {
    local port=$1; local proto=$2
    if command -v ufw >/dev/null 2>&1; then
        [[ "$proto" == "both" || "$proto" == "tcp" ]] && ufw delete allow "$port"/tcp >/dev/null 2>&1
        [[ "$proto" == "both" || "$proto" == "udp" ]] && ufw delete allow "$port"/udp >/dev/null 2>&1
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        [[ "$proto" == "both" || "$proto" == "tcp" ]] && firewall-cmd --remove-port="$port"/tcp --permanent >/dev/null 2>&1
        [[ "$proto" == "both" || "$proto" == "udp" ]] && firewall-cmd --remove-port="$port"/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
}

force_kill_service() {
    local target=$1
    local from_menu=$2
    if [[ -z "$target" ]]; then
        echo -e "${RED}❌ 目标服务名为空！${RESET}"
        [[ "$from_menu" == "menu" ]] && { sleep 2; return; } || exit 1
    fi
    echo -e "${RED}☢️ 正在执行系统级物理粉碎: ${target} ...${RESET}"
    systemctl stop "$target" 2>/dev/null
    systemctl disable "$target" 2>/dev/null
    rm -f "/etc/systemd/system/${target}.service"
    rm -f "/etc/systemd/system/${target}"
    systemctl daemon-reload
    echo -e "${GREEN}✅ 目标服务 [${target}] 已彻底蒸发！${RESET}"
    [[ "$from_menu" == "menu" ]] && sleep 2 || exit 0
}

change_ssh_port() {
    read -rp "请输入新的 SSH 端口号 (1-65535): " new_port
    if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then ufw allow "$new_port"/tcp >/dev/null 2>&1; fi
        if command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --add-port="$new_port"/tcp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi
        sed -i "s/^#\?Port [0-9]*/Port $new_port/g" /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
        echo -e "${GREEN}✅ SSH 端口已修改为 $new_port 。${RESET}"
    else echo -e "${RED}输入无效。${RESET}"; fi; sleep 2
}
change_root_password() {
    read -rp "请输入新的 root 密码: " new_pass; [[ -z "$new_pass" ]] && return
    read -rp "请再次输入确认: " new_pass_confirm
    [[ "$new_pass" != "$new_pass_confirm" ]] && echo -e "${RED}两次密码不一致！${RESET}" && sleep 2 && return
    echo "root:$new_pass" | chpasswd && echo -e "${GREEN}✅ 密码修改成功！${RESET}"; sleep 2
}
sync_server_time() {
    echo -e "${CYAN}>>> 正在同步服务器时间...${RESET}"
    if command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -yqq systemd-timesyncd && systemctl enable --now systemd-timesyncd 2>/dev/null
    elif command -v yum >/dev/null 2>&1; then yum install -yq chrony && systemctl enable --now chronyd 2>/dev/null; fi
    echo -e "${GREEN}✅ 时间同步已启动！${RESET}"; sleep 2
}
apply_ssh_key_sec() {
    sed -i 's/^#\?PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
    sed -i 's/^#\?PasswordAuthentication no/PasswordAuthentication no/g' /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; echo -e "${GREEN}✅ 密码登录已封锁。${RESET}"; sleep 2
}
ssh_key_github() {
    read -rp "请输入你的 GitHub 用户名: " gh_user; [[ -z "$gh_user" ]] && return
    mkdir -p ~/.ssh && chmod 700 ~/.ssh; local keys=$(curl -s --max-time 10 "https://github.com/${gh_user}.keys")
    if [[ -z "$keys" || "$keys" == "Not Found" ]]; then echo -e "${RED}❌ 未找到公钥。${RESET}"; sleep 2; return; fi
    echo "$keys" >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; echo -e "${GREEN}✅ 拉取成功！${RESET}"; apply_ssh_key_sec
}
ssh_key_manual() {
    read -rp "请粘贴你的 SSH 公钥: " manual_key; [[ -z "$manual_key" ]] && return
    mkdir -p ~/.ssh && chmod 700 ~/.ssh; echo "$manual_key" >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; echo -e "${GREEN}✅ 成功！${RESET}"; apply_ssh_key_sec
}
ssh_key_generate() {
    mkdir -p ~/.ssh && chmod 700 ~/.ssh; rm -f ~/.ssh/id_ed25519*; ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -q
    cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys
    echo -e "${RED}⚠️ 保存以下私钥！⚠️${RESET}\n"; cat ~/.ssh/id_ed25519; echo -e "\n${YELLOW}========================${RESET}"
    read -rp "关闭密码登录 (y/N): " confirm; [[ "$confirm" == "y" || "$confirm" == "Y" ]] && apply_ssh_key_sec
}
ssh_key_restore() {
    sed -i 's/^#\?PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; echo -e "${GREEN}✅ 已恢复密码登录。${RESET}"; sleep 2
}
ssh_key_menu() {
    clear; echo -e "${CYAN}========= SSH 密钥登录管理 =========${RESET}\n${YELLOW} 1.${RESET} 自动拉取公钥 (GitHub)\n${YELLOW} 2.${RESET} 手动填写公钥\n${YELLOW} 3.${RESET} 一键生成密钥对\n${RED} 4. 恢复密码登录${RESET}\n 0. 返回"
    read -rp "输入 [0-4]: " skm_num
    case "$skm_num" in 1) ssh_key_github ;; 2) ssh_key_manual ;; 3) ssh_key_generate ;; 4) ssh_key_restore ;; 0) return ;; esac
}

# ==========================================================
# 节点原生部署模块 (核心下载链接 100% 修复)
# ==========================================================
install_ss_rust_native() {
    clear; echo -e "${CYAN}========= 原生交互安装 SS-Rust =========${RESET}"
    rm -f /etc/systemd/system/ss-rust.service
    read -rp "自定义端口 (1-65535) [留空随机]: " custom_port
    local port=$custom_port; if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then port=$((RANDOM % 55535 + 10000)); fi
    echo -e "\n${CYAN}加密协议:${RESET}\n 1) 2022-blake3-aes-128-gcm\n 2) 2022-blake3-aes-256-gcm\n 3) 2022-blake3-chacha20-poly1305\n 4) aes-256-gcm"
    read -rp "选择 [1-4] (默认1): " method_choice
    local method="2022-blake3-aes-128-gcm"; local pwd_len=16
    case "$method_choice" in 2) method="2022-blake3-aes-256-gcm"; pwd_len=32 ;; 3) method="2022-blake3-chacha20-poly1305"; pwd_len=32 ;; 4) method="aes-256-gcm"; pwd_len=0 ;; esac
    
    local pwd=""; if [[ "$pwd_len" -ne 0 ]]; then read -rp "密码 (留空生成Base64): " input_pwd; [[ -z "$input_pwd" ]] && pwd=$(openssl rand -base64 $pwd_len) || pwd=$(echo -n "$input_pwd" | base64 -w 0 | cut -c 1-$(($pwd_len * 4 / 3 + 4)))
    else read -rp "传统密码 (留空随机): " input_pwd; [[ -z "$input_pwd" ]] && pwd=$(openssl rand -hex 12) || pwd="$input_pwd"; fi
    
    local arch=$(uname -m); local ss_arch="x86_64-unknown-linux-gnu"; [[ "$arch" == "aarch64" ]] && ss_arch="aarch64-unknown-linux-gnu"
    
    echo -e "${CYAN}>>> 正在获取 SS-Rust 核心...${RESET}"
    local ss_latest=$(curl -s --max-time 10 https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | grep '"tag_name":' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    [[ -z "$ss_latest" ]] && ss_latest="v1.22.0"
    
    # 修复关键点：正确拼接带有版本号的文件名
    wget -qO /tmp/ss-rust.tar.xz "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${ss_latest}/shadowsocks-${ss_latest}.${ss_arch}.tar.xz"
    
    # 防爆文件校验
    if [[ ! -s /tmp/ss-rust.tar.xz ]] || ! tar -tf /tmp/ss-rust.tar.xz >/dev/null 2>&1; then 
        echo -e "${RED}❌ 核心下载失败 (网络异常或架构不支持)。${RESET}"
        rm -f /tmp/ss-rust.tar.xz; sleep 3; return
    fi
    
    tar -xf /tmp/ss-rust.tar.xz -C /tmp/ ssserver; mv -f /tmp/ssserver /usr/local/bin/ss-rust && chmod +x /usr/local/bin/ss-rust
    mkdir -p /etc/ss-rust
    cat > /etc/ss-rust/config.json << EOF
{
    "server": "::",
    "server_port": $port,
    "password": "$pwd",
    "method": "$method",
    "mode": "tcp_and_udp",
    "fast_open": true
}
EOF
    cat > /etc/systemd/system/ss-rust.service << EOF
[Unit]
Description=Shadowsocks-Rust Server
After=network.target

[Service]
ExecStart=/usr/local/bin/ss-rust -c /etc/ss-rust/config.json
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now ss-rust
    if command -v ufw >/dev/null 2>&1; then ufw allow "$port"/tcp >/dev/null 2>&1; ufw allow "$port"/udp >/dev/null 2>&1; fi
    if command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --add-port="$port"/tcp --permanent >/dev/null 2>&1; firewall-cmd --add-port="$port"/udp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi
    echo -e "${GREEN}✅ SS-Rust ($ss_latest) 安装完成！${RESET}"; sleep 2
}

install_vless_native() {
    clear; echo -e "${CYAN}========= 原生交互安装 VLESS Reality =========${RESET}"
    rm -f /etc/systemd/system/xray.service
    read -rp "伪装域名 [默认 updates.cdn-apple.com]: " sni_domain; [[ -z "$sni_domain" ]] && sni_domain="updates.cdn-apple.com"
    read -rp "监听端口 [留空随机]: " port; if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then port=$((RANDOM % 55535 + 10000)); fi
    local arch=$(uname -m); local xray_arch="64"; [[ "$arch" == "aarch64" ]] && xray_arch="arm64-v8a"
    local xray_latest=$(curl -s --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name":' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    [[ -z "$xray_latest" ]] && xray_latest="v1.8.24"
    wget -qO /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${xray_latest}/Xray-linux-${xray_arch}.zip"
    if [[ ! -s /tmp/xray.zip ]] || ! unzip -t /tmp/xray.zip >/dev/null 2>&1; then echo -e "${RED}❌ 核心下载失败。${RESET}"; rm -f /tmp/xray.zip; sleep 3; return; fi
    unzip -qo /tmp/xray.zip xray -d /tmp/; mv -f /tmp/xray /usr/local/bin/xray && chmod +x /usr/local/bin/xray
    mkdir -p /usr/local/etc/xray
    local uuid=$(/usr/local/bin/xray uuid); local keys=$(/usr/local/bin/xray x25519); local priv=$(echo "$keys" | grep "Private" | awk '{print $3}'); local pub=$(echo "$keys" | grep "Public" | awk '{print $3}'); local short_id=$(openssl rand -hex 8)
    cat > /usr/local/etc/xray/config.json << EOF
{
    "inbounds": [{
        "port": $port,
        "protocol": "vless",
        "settings": { "clients": [{"id": "$uuid", "flow": "xtls-rprx-vision"}], "decryption": "none" },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "dest": "${sni_domain}:443",
                "serverNames": ["${sni_domain}"],
                "privateKey": "$priv",
                "shortIds": ["$short_id"]
            }
        }
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOF
    cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now xray
    if command -v ufw >/dev/null 2>&1; then ufw allow "$port"/tcp >/dev/null 2>&1; fi
    if command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --add-port="$port"/tcp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi
    echo -e "${GREEN}✅ VLESS Reality ($xray_latest) 安装成功！${RESET}"; sleep 2
}

install_shadowtls_native() {
    clear; echo -e "${CYAN}========= 原生安装 ShadowTLS =========${RESET}"
    local ss_port=""; [[ -f "/etc/ss-rust/config.json" ]] && ss_port=$(jq -r '.server_port' /etc/ss-rust/config.json 2>/dev/null)
    if [[ -n "$ss_port" && "$ss_port" != "null" ]]; then
        echo -e "${YELLOW}检测到本地 SS-Rust 节点，推荐进行保护：${RESET}\n${CYAN} 1) 保护本地 SS-Rust (端口: $ss_port)${RESET}\n${CYAN} 2) 手动输入其他自定义端口${RESET}"
        read -rp "选择 [1-2]: " protect_choice; if [[ "$protect_choice" == "1" ]]; then up_port=$ss_port; else read -rp "需要保护的上游端口: " up_port; fi
    else read -rp "需要保护的上游端口: " up_port; fi
    [[ -z "$up_port" ]] && echo -e "${RED}端口无效！${RESET}" && sleep 2 && return

    read -rp "ShadowTLS 伪装端口 [留空自动随机]: " listen_port
    if ! [[ "$listen_port" =~ ^[0-9]+$ ]] || [ "$listen_port" -lt 1 ] || [ "$listen_port" -gt 65535 ]; then listen_port=$((RANDOM % 55535 + 10000)); fi
    read -rp "伪装域名 (SNI) [留空默认 updates.cdn-apple.com]: " sni_domain; [[ -z "$sni_domain" ]] && sni_domain="updates.cdn-apple.com"
    local pwd=$(openssl rand -base64 8); local arch=$(uname -m); local st_arch="x86_64-unknown-linux-musl"; [[ "$arch" == "aarch64" ]] && st_arch="aarch64-unknown-linux-musl"
    local st_latest=$(curl -s --max-time 10 https://api.github.com/repos/ihciah/shadow-tls/releases/latest | grep '"tag_name":' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    [[ -z "$st_latest" ]] && st_latest="v0.2.25"
    wget -qO /tmp/shadow-tls "https://github.com/ihciah/shadow-tls/releases/download/${st_latest}/shadow-tls-${st_arch}"
    if [[ ! -s /tmp/shadow-tls ]]; then echo -e "${RED}❌ 下载失败。${RESET}"; rm -f /tmp/shadow-tls; sleep 3; return; fi
    mv -f /tmp/shadow-tls /usr/local/bin/shadow-tls && chmod +x /usr/local/bin/shadow-tls
    
    cat > /etc/systemd/system/shadowtls-${listen_port}.service << EOF
[Unit]
Description=ShadowTLS Service on port ${listen_port}
After=network.target

[Service]
ExecStart=/usr/local/bin/shadow-tls --v3 --strict server --listen 0.0.0.0:${listen_port} --server 127.0.0.1:${up_port} --tls ${sni_domain}:443 --password ${pwd}
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now shadowtls-${listen_port}
    if command -v ufw >/dev/null 2>&1; then ufw allow "$listen_port"/tcp >/dev/null 2>&1; fi
    if command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --add-port="$listen_port"/tcp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi
    echo -e "${GREEN}✅ ShadowTLS ($st_latest) 安装成功！已挂载在 ${up_port} 上层。${RESET}"; sleep 2
}

unified_node_manager() {
    while true; do
        clear; echo -e "${CYAN}========= 🔰 统一节点生命周期管控中心 =========${RESET}"
        for s in /etc/systemd/system/shadowtls-*.service; do
            [[ -e "$s" ]] || continue
            local check_port=$(basename "$s" | sed 's/shadowtls-//g' | sed 's/.service//g')
            if ! [[ "$check_port" =~ ^[0-9]+$ ]]; then systemctl stop "$(basename "$s")" 2>/dev/null; systemctl disable "$(basename "$s")" 2>/dev/null; rm -f "$s"; systemctl daemon-reload; fi
        done

        local has_ss=0; local has_vless=0; local has_stls=0
        if [[ -f "/etc/ss-rust/config.json" ]]; then echo -e "${GREEN} 1) ⚡ SS-Rust 节点${RESET}"; has_ss=1; else echo -e "${RED} 1) ❌ 未部署 SS-Rust${RESET}"; fi
        if [[ -f "/usr/local/etc/xray/config.json" ]]; then echo -e "${GREEN} 2) 🔮 VLESS Reality 节点${RESET}"; has_vless=1; else echo -e "${RED} 2) ❌ 未部署 VLESS Reality${RESET}"; fi
        if ls /etc/systemd/system/shadowtls-*.service 1> /dev/null 2>&1; then echo -e "${GREEN} 3) 🛡️ ShadowTLS 防阻断保护实例${RESET}"; has_stls=1; else echo -e "${RED} 3) ❌ 未部署 ShadowTLS${RESET}"; fi
        echo -e "${CYAN}--------------------------------------------${RESET}\n${RED} 4) ☢️ 全局强制核爆 (清理任意卡死/幽灵服务)${RESET}\n 0) 返回主菜单"
        read -rp "请选择 [0-4]: " node_choice
        case "$node_choice" in
            1)
                if [[ $has_ss -eq 1 ]]; then
                    clear; local ip=$(curl -s4m8 ip.sb || curl -s4m8 ifconfig.me); local port=$(jq -r '.server_port' /etc/ss-rust/config.json); local method=$(jq -r '.method' /etc/ss-rust/config.json); local password=$(jq -r '.password' /etc/ss-rust/config.json); local b64=$(echo -n "${method}:${password}" | base64 -w 0); local link="ss://${b64}@${ip}:${port}#SS-Rust"
                    echo -e "IP: ${GREEN}${ip}${RESET}\n端口: ${GREEN}${port}${RESET}\n协议: ${GREEN}${method}${RESET}\n密码: ${GREEN}${password}${RESET}\n${YELLOW}链接:${RESET}\n${link}\n---------------------------------\n${YELLOW}1) 修改端口 | 2) 修改密码 | ${RED}3) 删除节点${RESET} | 0) 返回"; read -rp "输入操作: " op
                    if [[ "$op" == "1" ]]; then read -rp "新端口: " np; jq --argjson p "$np" '.server_port = $p' /etc/ss-rust/config.json > /tmp/tmp.json && mv -f /tmp/tmp.json /etc/ss-rust/config.json; remove_firewall_rule "$port" "both"; if command -v ufw >/dev/null 2>&1; then ufw allow "$np"/tcp >/dev/null 2>&1; ufw allow "$np"/udp >/dev/null 2>&1; fi; if command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --add-port="$np"/tcp --permanent >/dev/null 2>&1; firewall-cmd --add-port="$np"/udp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi; systemctl restart ss-rust 2>/dev/null; echo -e "${GREEN}✅ 修改成功${RESET}"; sleep 1
                    elif [[ "$op" == "2" ]]; then read -rp "新密码: " npwd; jq --arg pwd "$npwd" '.password = $pwd' /etc/ss-rust/config.json > /tmp/tmp.json && mv -f /tmp/tmp.json /etc/ss-rust/config.json; systemctl restart ss-rust 2>/dev/null; echo -e "${GREEN}✅ 修改成功${RESET}"; sleep 1
                    elif [[ "$op" == "3" ]]; then remove_firewall_rule "$port" "both"; systemctl stop ss-rust 2>/dev/null; systemctl disable ss-rust 2>/dev/null; rm -rf /etc/ss-rust /usr/local/bin/ss-rust /etc/systemd/system/ss-rust.service; systemctl daemon-reload; echo -e "${GREEN}✅ 已彻底销毁！${RESET}"; sleep 1; fi
                fi ;;
            2)
                if [[ $has_vless -eq 1 ]]; then
                    clear; local ip=$(curl -s4m8 ip.sb || curl -s4m8 ifconfig.me); local port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json); local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' /usr/local/etc/xray/config.json); local sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' /usr/local/etc/xray/config.json)
                    echo -e "IP: ${GREEN}${ip}${RESET}\n端口: ${GREEN}${port}${RESET}\nUUID: ${GREEN}${uuid}${RESET}\nSNI伪装: ${GREEN}${sni}${RESET}\n---------------------------------\n${YELLOW}1) 重启节点 | ${RED}2) 删除节点${RESET} | 0) 返回"; read -rp "输入操作: " op
                    if [[ "$op" == "1" ]]; then systemctl restart xray 2>/dev/null; echo -e "${GREEN}✅ 已重启${RESET}"; sleep 1
                    elif [[ "$op" == "2" ]]; then remove_firewall_rule "$port" "tcp"; systemctl stop xray 2>/dev/null; systemctl disable xray 2>/dev/null; rm -rf /usr/local/etc/xray /usr/local/bin/xray /etc/systemd/system/xray.service; systemctl daemon-reload; echo -e "${GREEN}✅ 已彻底销毁！${RESET}"; sleep 1; fi
                fi ;;
            3)
                if [[ $has_stls -eq 1 ]]; then
                    clear; local st_ports=(); local idx=1
                    for s in /etc/systemd/system/shadowtls-*.service; do [[ -e "$s" ]] || continue; local st_port=$(basename "$s" | sed 's/shadowtls-//g' | sed 's/.service//g'); st_ports[$idx]=$st_port; local st_status=$(systemctl is-active --quiet shadowtls-"$st_port" && echo -e "${GREEN}运行中${RESET}" || echo -e "${RED}已停止${RESET}"); echo -e " ${CYAN}${idx})${RESET} 端口: ${YELLOW}${st_port}${RESET} [${st_status}]"; ((idx++)); done
                    echo -e "---------------------------------\n${RED}1) 序号删除实例 | 9) ⚠️ 强制核爆所有残留${RESET} | 0) 返回"; read -rp "输入操作: " op
                    if [[ "$op" == "1" ]]; then read -rp "输入实例序号 [1-$((idx-1))]: " del_idx; local del_port=${st_ports[$del_idx]}; if [[ -n "$del_port" && -f "/etc/systemd/system/shadowtls-${del_port}.service" ]]; then remove_firewall_rule "$del_port" "tcp"; systemctl stop shadowtls-"$del_port" 2>/dev/null; systemctl disable shadowtls-"$del_port" 2>/dev/null; rm -f "/etc/systemd/system/shadowtls-${del_port}.service"; systemctl daemon-reload; if ! ls /etc/systemd/system/shadowtls-*.service 1> /dev/null 2>&1; then rm -f /usr/local/bin/shadow-tls; fi; echo -e "${GREEN}✅ 已彻底销毁！${RESET}"; sleep 1; fi; fi
                    if [[ "$op" == "9" ]]; then echo -e "${RED}执行物理核爆...${RESET}"; for p in "${st_ports[@]}"; do remove_firewall_rule "$p" "tcp"; systemctl stop "shadowtls-$p" 2>/dev/null; systemctl disable "shadowtls-$p" 2>/dev/null; rm -f "/etc/systemd/system/shadowtls-${p}.service"; done; rm -f /usr/local/bin/shadow-tls; systemctl daemon-reload; echo -e "${GREEN}✅ 拔除成功！${RESET}"; sleep 2; fi
                fi ;;
            4)
                clear; echo -e "${CYAN}========= ☢️ 全局强制核爆中心 =========${RESET}\n${YELLOW}支持强制抹除系统中任何卡死、报错或残留的服务。${RESET}\n参考名：${GREEN}ss-rust${RESET} | ${GREEN}xray${RESET} | ${GREEN}shadowtls-错误端口${RESET}\n---------------------------------"
                read -rp "请输入要粉碎的服务名 (直接回车取消): " nuke_target
                [[ -n "$nuke_target" ]] && force_kill_service "$nuke_target" "menu" ;;
            0) return ;;
        esac
    done
}

nat_vps_optimization() { clear; echo -e "${CYAN}========= NAT 小鸡全方位极限优化 =========${RESET}"; if command -v chattr >/dev/null 2>&1; then chattr -i /etc/resolv.conf 2>/dev/null; fi; echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1\nnameserver 2606:4700:4700::1111" > /etc/resolv.conf; if command -v chattr >/dev/null 2>&1; then chattr +i /etc/resolv.conf 2>/dev/null; fi; if ! grep -q "swap" /etc/fstab; then rm -f /var/swap; if dd if=/dev/zero of=/var/swap bs=1M count=512 status=none 2>/dev/null; then chmod 600 /var/swap; mkswap /var/swap >/dev/null 2>&1; swapon /var/swap >/dev/null 2>&1; echo "/var/swap swap swap defaults 0 0" >> /etc/fstab; echo -e "${GREEN}✅ 512MB Swap 创建成功！${RESET}"; elif dd if=/dev/zero of=/var/swap bs=1M count=256 status=none 2>/dev/null; then chmod 600 /var/swap; mkswap /var/swap >/dev/null 2>&1; swapon /var/swap >/dev/null 2>&1; echo "/var/swap swap swap defaults 0 0" >> /etc/fstab; echo -e "${YELLOW}✅ 降级创建 256MB Swap！${RESET}"; else rm -f /var/swap; echo -e "${YELLOW}⚠️ 磁盘满跳过Swap。${RESET}"; fi; fi; sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=50M/g' /etc/systemd/journald.conf; systemctl restart systemd-journald 2>/dev/null; sed -i 's/^#\?ClientAliveInterval.*/ClientAliveInterval 30/g' /etc/ssh/sshd_config; sed -i 's/^#\?ClientAliveCountMax.*/ClientAliveCountMax 3/g' /etc/ssh/sshd_config; systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; rm -f /etc/sysctl.d/99-bbr.conf /etc/sysctl.d/99-tfo.conf; cat > "$NAT_CONF_FILE" << EOF
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_rmem = 4096 16384 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 8192
fs.file-max = 262144
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl -p "$NAT_CONF_FILE" >/dev/null 2>&1 || true; echo -e "${GREEN}✅ NAT 优化完毕！${RESET}"; sleep 2; }

smart_optimization() { local rmem_max="67108864"; local somaxconn="32768"; local file_max="1048576"; rm -f /etc/sysctl.d/99-tfo.conf /etc/sysctl.d/99-nat.conf; cat > "$CONF_FILE" << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = $rmem_max
net.core.wmem_max = $rmem_max
net.ipv4.tcp_rmem = 8192 262144 $rmem_max
net.ipv4.tcp_wmem = 8192 262144 $rmem_max
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1
net.core.somaxconn = $somaxconn
net.core.netdev_max_backlog = $somaxconn
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_fastopen = 3
fs.file-max = $file_max
EOF
sysctl --system >/dev/null 2>&1 || true; echo -e "${GREEN}✅ 常规调参完成！${RESET}"; }

real_time_traffic_monitor() { clear; echo -e "${CYAN}========= 极客级实时网卡流量监视器 (按 Ctrl+C 退出) =========${RESET}"; local interface=$(ip route | grep default | awk '{print $5}' | head -n 1); if [[ -z "$interface" ]]; then echo -e "${RED}未找到网卡！${RESET}"; sleep 2; return; fi; while true; do local rx1=$(cat /sys/class/net/$interface/statistics/rx_bytes 2>/dev/null || echo 0); local tx1=$(cat /sys/class/net/$interface/statistics/tx_bytes 2>/dev/null || echo 0); sleep 1; local rx2=$(cat /sys/class/net/$interface/statistics/rx_bytes 2>/dev/null || echo 0); local tx2=$(cat /sys/class/net/$interface/statistics/tx_bytes 2>/dev/null || echo 0); local rx_speed=$(( (rx2 - rx1) / 1024 )); local tx_speed=$(( (tx2 - tx1) / 1024 )); echo -ne "\r\033[K${YELLOW}网卡 [${interface}]${RESET}  ⬇️ 下载: ${GREEN}${rx_speed} KB/s${RESET}  |  ⬆️ 上传: ${CYAN}${tx_speed} KB/s${RESET}"; done; }

run_daemon_check() { [[ $(systemctl list-units --all -t service | grep -q "ss-rust.service") ]] && { systemctl is-active --quiet ss-rust || systemctl restart ss-rust 2>/dev/null; }; [[ $(systemctl list-units --all -t service | grep -q "xray.service") ]] && { systemctl is-active --quiet xray || systemctl restart xray 2>/dev/null; }; for s in $(systemctl list-units --type=service --all --no-legend | grep "shadowtls-" | awk '{print $1}'); do systemctl is-active --quiet "$s" || systemctl restart "$s" 2>/dev/null; done; }

auto_clean() { local is_silent=$1; if command -v apt-get >/dev/null 2>&1; then apt-get autoremove -yqq >/dev/null 2>&1; apt-get clean -qq >/dev/null 2>&1; fi; rm -rf /root/.cache/* /tmp/*.tar.xz /tmp/shadow-tls /tmp/ssserver /tmp/ssr_update.sh /tmp/xray* /tmp/tmp.json 2>/dev/null; [[ "$is_silent" != "silent" ]] && echo -e "${GREEN}✅ 垃圾清理完毕！${RESET}"; }

hot_update_components() {
    local is_silent=$1
    [[ "$is_silent" != "silent" ]] && echo -e "${CYAN}>>> 正在安全检查官方二进制核心版本...${RESET}"
    local arch=$(uname -m); local ss_arch="x86_64-unknown-linux-gnu"; local st_arch="x86_64-unknown-linux-musl"; local xray_arch="64"; if [[ "$arch" == "aarch64" ]]; then ss_arch="aarch64-unknown-linux-gnu"; st_arch="aarch64-unknown-linux-musl"; xray_arch="arm64-v8a"; fi
    
    if [[ -x "/usr/local/bin/ss-rust" ]]; then
        local ss_latest=$(curl -s --max-time 10 https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | grep '"tag_name":' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
        [[ -n "$ss_latest" ]] && wget -qO /tmp/ss-rust.tar.xz "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${ss_latest}/shadowsocks-${ss_latest}.${ss_arch}.tar.xz" && tar -xf /tmp/ss-rust.tar.xz -C /tmp/ ssserver 2>/dev/null && mv -f /tmp/ssserver /usr/local/bin/ss-rust && systemctl restart ss-rust 2>/dev/null
    fi
    if [[ -x "/usr/local/bin/shadow-tls" ]]; then
        local st_latest=$(curl -s --max-time 10 https://api.github.com/repos/ihciah/shadow-tls/releases/latest | grep '"tag_name":' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
        [[ -n "$st_latest" ]] && wget -qO /tmp/shadow-tls "https://github.com/ihciah/shadow-tls/releases/download/${st_latest}/shadow-tls-${st_arch}" && mv -f /tmp/shadow-tls /usr/local/bin/shadow-tls && chmod +x /usr/local/bin/shadow-tls && for s in $(systemctl list-units --type=service --all --no-legend | grep "shadowtls-" | awk '{print $1}'); do systemctl restart "$s" 2>/dev/null; done
    fi
    if [[ -x "/usr/local/bin/xray" ]]; then
        local xr_latest=$(curl -s --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name":' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
        [[ -n "$xr_latest" ]] && wget -qO /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${xr_latest}/Xray-linux-${xray_arch}.zip" && unzip -qo /tmp/xray.zip xray -d /tmp/ 2>/dev/null && mv -f /tmp/xray /usr/local/bin/xray && systemctl restart xray 2>/dev/null
    fi
    [[ "$is_silent" != "silent" ]] && echo -e "${GREEN}✅ 官方同步完毕！本地核心热更已完成。${RESET}" && sleep 2
}

update_script() { echo -e "${CYAN}>>> 同步最新版脚本数据...${RESET}"; curl -sL "https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/ssr.sh" -o /tmp/ssr_update.sh; if [[ -s /tmp/ssr_update.sh ]]; then mv -f /tmp/ssr_update.sh /usr/local/bin/ssr && chmod +x /usr/local/bin/ssr; echo -e "${GREEN}✅ 更新成功！${RESET}"; sleep 1; exec /usr/local/bin/ssr; else echo -e "${RED}❌ 更新失败。${RESET}"; fi; }

total_uninstall() {
    echo -e "${RED}⚠️ 正在进行无痕毁灭性全量卸载...${RESET}"
    if [[ -f "/etc/ss-rust/config.json" ]]; then local sp=$(jq -r '.server_port' /etc/ss-rust/config.json); remove_firewall_rule "$sp" "both"; fi
    if [[ -f "/usr/local/etc/xray/config.json" ]]; then local xp=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json); remove_firewall_rule "$xp" "tcp"; fi
    for s in /etc/systemd/system/shadowtls-*.service; do [[ -f "$s" ]] && remove_firewall_rule "$(basename "$s" | sed 's/shadowtls-//g' | sed 's/.service//g')" "tcp"; done
    systemctl stop ss-rust xray 2>/dev/null; rm -rf /etc/ss-rust /usr/local/bin/ss-rust /etc/systemd/system/ss-rust.service; rm -rf /usr/local/etc/xray /usr/local/bin/xray /etc/systemd/system/xray.service; for s in $(systemctl list-units --type=service --all --no-legend | grep "shadowtls-" | awk '{print $1}'); do systemctl stop "$s" 2>/dev/null; rm -f "/etc/systemd/system/$s"; done
    rm -f /usr/local/bin/shadow-tls "$CONF_FILE" "$NAT_CONF_FILE" /usr/local/bin/ssr /usr/local/bin/ssr.sh; crontab -l 2>/dev/null | grep -vE "ssr auto_update|ssr auto_task|ssr daemon_check|ssr hot_upgrade|ssr clean|ssr daily_task" | crontab -
    if command -v chattr >/dev/null 2>&1; then chattr -i /etc/resolv.conf 2>/dev/null; fi; echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf
    if grep -q "/var/swap" /etc/fstab; then swapoff /var/swap 2>/dev/null; rm -f /var/swap; sed -i 's|/var/swap swap swap defaults 0 0||g' /etc/fstab; fi
    systemctl daemon-reload; echo -e "${GREEN}✅ 完美无痕卸载完成！${RESET}"; exit 0
}

opt_menu() { clear; echo -e "${CYAN}========= 网络优化与监视中心 =========${RESET}\n${YELLOW} 1.${RESET} 常规机器极致 BBR 网络调参\n${GREEN} 2. NAT 小鸡专属极限优化 (防断流 / 智能Swap / 锁DNS / 防爆盘)${RESET}\n${CYAN}--------------------------------------------${RESET}\n${YELLOW} 3.${RESET} 启动实时网卡流量监视器 (Traffic Monitor)\n${YELLOW} 4.${RESET} 手动清理系统垃圾与冗余日志\n 0. 返回主菜单"; read -rp "输入数字 [0-4]: " opt_num; case "$opt_num" in 1) smart_optimization ;; 2) nat_vps_optimization ;; 3) real_time_traffic_monitor ;; 4) auto_clean ;; 0) return ;; esac; }

sys_menu() { clear; echo -e "${CYAN}========= 系统基础与极客管理 =========${RESET}\n${YELLOW} 1.${RESET} 一键修改 SSH 安全端口\n${YELLOW} 2.${RESET} 一键修改 Root 密码\n${YELLOW} 3.${RESET} 服务器时间防偏移同步\n${YELLOW} 4.${RESET} SSH 密钥登录管理中心 (防爆破神器)\n${CYAN}--------------------------------------------${RESET}\n${YELLOW} 5.${RESET} 手动热替换升级核心组件 (系统已设每日凌晨3点自动热更与清理)\n${YELLOW} 6.${RESET} 手动更新 SSR 管理脚本本身\n 0. 返回主菜单"; read -rp "输入数字 [0-6]: " sys_num; case "$sys_num" in 1) change_ssh_port ;; 2) change_root_password ;; 3) sync_server_time ;; 4) ssh_key_menu ;; 5) hot_update_components ;; 6) update_script ;; 0) return ;; esac; }

main_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}       SSR 综合智能管理脚本 v${SCRIPT_VERSION}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${YELLOW} 1.${RESET} 原生极客部署 SS-Rust"
    echo -e "${YELLOW} 2.${RESET} 原生极客部署 VLESS Reality"
    echo -e "${YELLOW} 3.${RESET} 🛡️ 部署 ShadowTLS (仅保护传统协议)"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    echo -e "${GREEN} 4. 🔰 统一节点管控中心 (节点查看 / ☢️ 全局强制核爆)${RESET}"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    echo -e "${YELLOW} 5.${RESET} 网络优化与流量监视 (NAT专属压榨 / 流量嗅探)"
    echo -e "${YELLOW} 6.${RESET} 极客系统底层管控 (系统管理 / 节点热更)"
    echo -e "${RED} 7. 完美无痕毁灭性卸载中心 (退水清扫)${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e " 0. 退出脚本"
    read -rp "请输入对应数字 [0-7]: " num
    case "$num" in 1) install_ss_rust_native ;; 2) install_vless_native ;; 3) install_shadowtls_native ;; 4) unified_node_manager ;; 5) opt_menu ;; 6) sys_menu ;; 7) total_uninstall ;; 0) echo -e "${GREEN}感谢使用，再见！${RESET}"; exit 0 ;; *) echo -e "${RED}请输入正确的选项！${RESET}" ;; esac
    echo -e "\n${CYAN}按任意键返回主菜单，或按 Ctrl+C 直接退出...${RESET}"; read -n 1 -s -r
}

check_env
install_global_command

if [[ -n "${1:-}" ]]; then
    case "$1" in
        bbr)          smart_optimization ;;
        nat)          nat_vps_optimization ;;
        clean)        auto_clean "silent" ;;
        update)       update_script ;;
        hot_upgrade)  hot_update_components "silent" ;;
        daily_task)   hot_update_components "silent"; auto_clean "silent" ;;
        daemon_check) run_daemon_check ;;
        nuke)         force_kill_service "$2" "cli" ;;
        *)            echo -e "${RED}未知指令: $1${RESET}"; exit 1 ;;
    esac
    exit 0
else
    while true; do main_menu; done
fi
EOF_MAGIC_END
chmod +x /usr/local/bin/ssr && ssr
