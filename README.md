# IPv6 ADD 管理工具

Linux VPS 上的交互式 IPv6 管理脚本。仓库地址：[lulu123k/addipv6](https://github.com/lulu123k/addipv6)。

本项目保留了原项目的提交历史和 [MIT 许可证](LICENSE)。

## 功能

- 在所选网卡的现有 IPv6 前缀内生成并添加地址，单次最多 1000 个。
- 选择现有 IPv6 作为默认路由的出站源地址；可选创建 systemd 服务，在开机时恢复路由。
- 删除本脚本记录的地址；会保留当前出口地址和网卡上的最后一个全局 IPv6 地址。
- 经明确确认后，删除所选网卡上除当前出口外的其他全部全局 IPv6 地址。这项操作也会删除并非由脚本添加的地址。

## 环境要求

Linux、Bash、Python 3.6+、iproute2、curl，以及 root 权限。路由持久化功能还需要 systemd。

## 安装与运行

以 root 登录 VPS 后，复制这一行即可下载并运行脚本：

```bash
curl -fsSLo addipv6.sh https://raw.githubusercontent.com/lulu123k/addipv6/main/addipv6.sh && bash addipv6.sh
```

脚本会以 root 身份修改网卡地址与默认路由。建议先阅读下载的文件，并准备 VPS 控制台作为备用入口；错误操作可能中断 SSH 连接。

## 状态与开机恢复

新增地址按“网卡名 IPv6/前缀长度”记录在 `/var/lib/addipv6/managed-addresses`。目录仅 root 可访问，状态文件权限为 `0600`。旧版脚本的 `/tmp/added_v6_ipv6.txt` **不会自动导入或执行**；如果需要清理旧版地址，请先核对网卡上的实际地址，再手动处理。

选择“设置默认出口”并确认持久化时，脚本创建 `/etc/systemd/system/addipv6-route.service`。该服务只恢复默认路由；**出口源地址本身必须由 VPS 的网络配置在重启后重新添加**，否则路由恢复会失败。检查服务：

```bash
systemctl status addipv6-route.service
journalctl -u addipv6-route.service --no-pager
```

旧版追加到 `/etc/rc.local` 的命令不会被新脚本删除；升级前请检查该文件，避免同时执行两份路由设置。

## 安全注意事项

- 新增公网 IPv6 后，检查 VPS 的 IPv6 防火墙规则，以及监听 `::` 的服务是否意外对外开放。
- 地址生成使用 Python `secrets`，并校验前缀；状态文件不再放在共享的 `/tmp`。
- “仅保留当前出口”会删除网卡上其他全部全局 IPv6 地址。此操作需要输入 `DELETE` 确认。
- 安装命令从本仓库的 `main` 分支下载脚本；执行前可先检查下载的 `addipv6.sh` 内容。
