以下为您整理好的完整 **README.md** 介绍内容。您可以直接将其复制到您的 GitHub 项目首页。

---

# SSR + nftables 综合管理脚本 (my-manager)

本项目是一个集成了 **SSR 节点部署**、**nftables 端口转发**、**Nginx 反向代理**以及**系统运维工具**的全能型 Shell 脚本。旨在为 Linux 服务器提供一站式的网络优化、中转转发与服务管理解决方案。

## 🚀 快速开始

### 1. 综合管理面板 (推荐)

使用以下命令安装并运行综合管理面板。脚本支持自动识别网络环境，提供国内加速镜像。

**GitHub 直连：**

```bash
wget -N https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/my.sh && chmod +x my.sh && ./my.sh

```

**国内加速：**

```bash
wget -N https://ghproxy.net/https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/my.sh && chmod +x my.sh && ./my.sh

```

**一键 Curl 安装：**

```bash
curl -fL https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/my.sh -o my.sh && chmod +x my.sh && ./my.sh

```

> **快捷命令**：安装后，您可以在终端随时输入 `my` 唤起主菜单。

### 2. 单独模块快捷路径

如果您仅需使用特定功能模块，可以使用以下独立命令：

* **SSR 综合管理** (快捷命令: `ssr`)
```bash
curl -Ls https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/ssr.sh -o /usr/local/bin/ssr.sh && chmod +x /usr/local/bin/ssr.sh && /usr/local/bin/ssr.sh

```


* **nftables 端口转发** (快捷命令: `nft`)
```bash
curl -L https://ghproxy.net/https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/nft_mgr.sh -o nft.sh && chmod +x nft.sh && ./nft.sh

```



---

## ✨ 核心特性

### 1. 节点部署与生命周期管控

* **多协议支持**：支持原生部署 SS-Rust、VLESS Reality (Xray) 及 ShadowTLS 保护层。
* **统一管控中心**：提供图形化界面查看连接信息、修改端口/密码，以及针对异常服务的“强制核爆”清理功能。
* **安全热更新**：内置安全检测，仅在有新版本时进行原子替换，不影响当前运行配置。

### 2. nftables 高性能端口转发

* **智能转发**：基于 nftables 实现 TCP/UDP 流量转发，性能优越且规则原子化应用。
* **域名 DDNS 联动**：支持目标地址为域名，并自动启用每分钟 IP 变动检测与同步。
* **系统调优**：内置“稳定优先”与“极致性能”两档内核网络参数优化方案。

### 3. Nginx 反向代理与 SSL

* **自动化环境**：一键安装 Nginx 环境及 Certbot 证书工具链。
* **HTTPS 部署**：自动申请 Let's Encrypt 证书并配置 HTTP 强制跳转 HTTPS。
* **简易管理**：支持按序号查看、添加或删除反代配置，管理直观。

### 4. 系统底层运维工具

* **DD / 重装系统**：集成高效重装脚本，支持 Debian 12/13 及 Ubuntu 24.04 一键重装。
* **DNS 深度管理**：支持延迟测试选优、手动设置 DNS，以及 `/etc/resolv.conf` 的锁定保护。
* **安全加固**：一键修改 SSH 端口、Root 密码、禁用密码登录、同步服务器时间等。
* **自动清理**：每日凌晨 2:00 自动执行系统垃圾清理与日志维护。

---

## 🛠️ 脚本结构

* **主程序**：`/usr/local/bin/my`
* **模块目录**：`/usr/local/lib/my`
* **配置路径**：`/usr/local/etc/`

---

## ⚠️ 卸载说明

脚本内置“一键卸载中心”，支持按模块（SSR/NFT/Nginx）单独卸载，或执行“全量卸载”以彻底清除脚本本身及所有相关配置与定时任务。

---

**您还需要我为您生成其他的 GitHub 项目文档（如 LICENSE 或 CONTRIBUTING）吗？**
