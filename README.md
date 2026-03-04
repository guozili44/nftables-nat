🚀 综合网络管理脚本 (SSR + NFt 转发)
这是一个极致精简且功能强大的系统级网络管理工具。它将 SSR 节点部署管控、系统网络内核调优，以及基于 nftables 的端口转发与 DDNS 守护完美整合在一起，提供统一的全局交互管理面板。
✨ 核心特性
 * 🔰 多协议节点原生部署：支持 SS-Rust, VLESS Reality, ShadowTLS，提供完整的生命周期管控（部署、修改、重启、核爆卸载）。
 * 🔄 原子化端口转发：基于 nftables 实现 0 丢包热重载，支持 TCP/UDP 转发，自带自动 DDNS 域名解析变动同步。
 * ⚡ 双档网络极速调优：针对 NAT 小鸡与常规独立服务器，提供「稳定优先」与「极致性能」两种内核级优化 Profile。
 * 🛡️ 安全与自动化：防命令冲突架构，定时任务严格隔离；支持一键自适应更新（自动识别国内/海外网络）与一键无痕完全卸载。
🖥️ 菜单界面预览
安装完成后，输入快捷命令即可进入可视化交互面板。主菜单结构如下，功能分区清晰，告别繁琐的命令行操作：
==========================================
       综合网络管理脚本 (SSR+NFt)         
==========================================
  1. 🚀 进入 SSR 节点与内核优化模块
  2. 🔄 进入 NFt 端口转发模块
------------------------------------------
  3. 🗑️ 综合脚本一键卸载中心 (多级卸载)
  4. 🌍 综合脚本自适应安全更新 (国内/海外)
  0. 退出管理脚本
==========================================

(注：进入子模块后，将展示对应节点配置、系统调优或端口转发规则的详细操作菜单。)
📥 一键安装指南
支持全新的主流 Linux 发行版（Debian / Ubuntu / CentOS / AlmaLinux 等）。请使用 root 用户运行以下命令进行一键安装。若系统未自带 curl，请使用下方的 wget 备用命令。
🌍 海外服务器 (推荐官方直连)
curl -fsSL -o my.sh https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/my.sh && chmod +x my.sh && bash my.sh

> 备用命令 (wget):
> wget -O my.sh https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/my.sh && chmod +x my.sh && bash my.sh
> 
> 
🇨🇳 国内服务器 (GHProxy 代理加速)
curl -fsSL -o my.sh https://ghproxy.net/https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/my.sh && chmod +x my.sh && bash my.sh

> 备用命令 (wget):
> wget -O my.sh https://ghproxy.net/https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/my.sh && chmod +x my.sh && bash my.sh
> 
> 
🛠️ 如何使用
首次运行上述安装命令后，脚本会自动完成系统环境初始化，并将自身配置为全局快捷命令。
以后在任何目录下的终端中，只需输入以下命令即可随时唤出综合管理主菜单：
my

这份介绍文档现在既有详细的安装防错指导（备用命令），又有非常直观的功能展示（菜单预览）。是否还需要我为你补充其他模块（例如 SSR 节点管理子菜单）的具体预览说明？
