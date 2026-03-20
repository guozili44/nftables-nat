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

### 2. 单独模块快捷路径（不建议使用，很久未更新，不知道有什么BUG了）

如果您仅需使用特定功能模块，可以使用以下独立命令：

* **SSR 综合管理** (快捷命令: `ssr`)
```bash
curl -Ls https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/ssr.sh -o /usr/local/bin/ssr.sh && chmod +x /usr/local/bin/ssr.sh && /usr/local/bin/ssr.sh

```


* **nftables 端口转发** (快捷命令: `nft`)
```bash
curl -L https://ghproxy.net/https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/nft_mgr.sh -o nft.sh && chmod +x nft.sh && ./nft.sh

