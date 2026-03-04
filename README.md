# 综合管理脚本（SSR 管理 / NFt 转发 / 一键卸载 / GitHub 更新）

一个脚本同时管理 **SSR** 与 **NFt（nftables NAT 转发）**，内置：
- ✅ SSR 管理（安装/卸载/状态/守护等）
- ✅ NFt 转发管理（添加/删除/查看/重载等）
- ✅ 一键卸载（全部 / 仅 SSR / 仅 NFt）
- ✅ GitHub 一键更新（自动判断直连/代理）
- ✅ 默认仅保留：系统每日凌晨 2 点自动清理（进入 SSR/NFt 管理后才按需添加对应自动任务）


## GitHub 一键命令（安装 / 覆盖更新并运行）

### 直连 GitHub（海外/可直连）
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/my.sh)
````

### 国内/直连不稳定（自动走代理）

```bash
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/my.sh)
```

运行完成后会自动安装快捷命令：

* `my`（综合管理脚本快捷命令）

---

## 已安装后：一键更新

进入脚本菜单：

```bash
my
```

选择：

* `4) GitHub 一键更新`

---

## 单独使用脚本（可选）

### 1）单独使用 SSR 脚本（快捷命令：`ssr`）

（已做精简：下载到 `/usr/local/bin/ssr` 并直接运行）

```bash
curl -fsSL https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/ssr.sh -o /usr/local/bin/ssr && chmod +x /usr/local/bin/ssr && ssr
```

---

### 2）单独使用 NFt 脚本（快捷命令：`nft`）

（已做精简：下载到 `/usr/local/bin/nft` 并直接运行；默认使用 ghproxy 更适合国内）

```bash
curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/nft_mgr.sh -o /usr/local/bin/nft && chmod +x /usr/local/bin/nft && nft
```

---

## 说明

* 推荐优先使用综合脚本：`my`
* 单独脚本适合只需要 SSR 或只需要 NFt 的场景
* 如遇更新/安装失败，请优先切换为国内代理命令再次执行

```
```
