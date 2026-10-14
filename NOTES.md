# 运维笔记

README 面向"用它的人"，这里是只有维护者才需要的：状态文件在哪、备份在哪、怎么回退与拆掉。

## 状态与凭据文件

都在 `~/.local/state/vpn-hotspot/`：

| 文件 | 说明 |
|---|---|
| `hotspot.env` | `HOTSPOT_SSID` / `HOTSPOT_PSK`，手工建、`chmod 600`、**不进仓库** |
| `hostapd.conf` | 由 `run.sh start` 按 STA 当前信道现生成，含密码，600 |
| `hostapd.pid` / `dnsmasq.pid` | `stop` 据此杀进程；残留的旧 pid 文件无害 |
| `dnsmasq.test.conf` | 只在 `selftest.sh` 运行期间存在（给假客户端加一条 `interface=`） |

状态目录由 `PKEXEC_UID` 反查"发起提权那个用户"的家目录决定，所以必须用 `pkexec`；裸 `sudo` 会把它指到 `/root/.local/state/vpn-hotspot`。

## 备份

- `iwd-2g.sh 2g` 会把改动前的 `/etc/iwd/main.conf` 存成 `~/.local/state/backups/etc/iwd/main.conf.bak-<YYYYMMDD>-pre2ghotspot`；`restore` 取该目录下**最新**的一份，一份都没有就报错退出、不盲写。
- 机器备份根是 `~/.local/state/backups/`（结构镜像 `$HOME`）。

## 回退

| 想撤销 | 动作 |
|---|---|
| 热点 | `pkexec bash run.sh stop` —— 撤 iptables、杀 hostapd/dnsmasq、删 `ap0`、摘 trusted 区 |
| 5GHz 被钉住 | `pkexec bash iwd-2g.sh restore`；脚本与备份都没了 → 手工删掉 `/etc/iwd/main.conf` 的 `[Rank]` 段再 `systemctl restart iwd` |
| 整套拆掉 | 删 `~/.local/state/vpn-hotspot/` ＋ 上面那条；`ap0`、iptables、firewalld 的改动都是 runtime 的，重启即净，仓库删掉即可 |

症状辨识：root 的 `iw dev wlan0 scan` 看得见自家 5GHz BSS，而 `iwctl`/NM 列表里一个都没有 ⇒ 是 iwd 配置还在钉着 5GHz，不是驱动或射频的问题。

## 使用时注意

手表/手机更新期间**别合盖、别挂起** —— suspend 会掐掉热点。
