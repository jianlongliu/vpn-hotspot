# 运维与排障

## 状态与凭据文件

都在 `~/.local/state/vpn-hotspot/`：

| 文件 | 说明 |
|---|---|
| `hotspot.env` | `HOTSPOT_SSID` / `HOTSPOT_PSK`，手工建、`chmod 600` |
| `hostapd.conf` | 由 `run.sh start` 按 STA 当前信道生成，含密码，600 |
| `hostapd.pid` / `dnsmasq.pid` | `stop` 据此杀进程；残留的旧 pid 文件无害 |
| `dnsmasq.test.conf` | 只在 `selftest.sh` 运行期间存在（临时给假客户端加一条 `interface=`） |

脚本里没有密码、也没有家目录字面量：状态目录由 `PKEXEC_UID` 反查"发起提权那个用户"的家目录决定。**因此必须用 `pkexec`**；裸 `sudo` 会把它指到 `/root/.local/state/vpn-hotspot`。

## 备份

- `iwd-2g.sh 2g` 先把改动前的 `/etc/iwd/main.conf` 存成 `~/.local/state/backups/etc/iwd/main.conf.bak-<YYYYMMDD>-pre2ghotspot`。
- `restore` 取该目录下**最新**的一份；一份都没有时报错退出，不盲写配置。
- 机器备份根是 `~/.local/state/backups/`（结构镜像 `$HOME`）。

## 验证清单

- **AP 侧**：`run.sh status` 中 hostapd 有进程、`ap0` 有 `10.42.0.1/24`、NAT 段出现 MASQUERADE、`ip_forward=1`、trusted 区含 `ap0`；`journalctl -t hostapd` 里出现 `AP-ENABLED`。
- **端到端**：`selftest.sh` 中假客户端能解析域名、打到 gstatic `204` 与 google `200`，并在 mihomo 面板（`127.0.0.1:9090`）里看到它的连接。
- **真机**：手表/手机连上后 `/var/lib/misc/dnsmasq.leases` 里出现租约。
- **频段**：`iwd-2g.sh` 跑完会打 iwd 状态、`wlan0` 的 ssid/channel、5GHz BSS 计数（钉住时应为 `0 个`）、默认路由与一次出口连通性。

## 故障排查

| 现象 | 处理 |
|---|---|
| `start` 报 `mihomo 没在跑` | 先把系统 mihomo 起起来 —— 热点出口是它的 TUN |
| `start` 报 STA 在 5GHz | 先 `pkexec bash iwd-2g.sh 2g` |
| `start` 报 `ap0 已存在` | `pkexec bash run.sh stop`，或手工 `iw dev ap0 del`，再 start |
| hostapd 起不来 / 起完就退 | 脚本会顺手打 `journalctl -t hostapd -n 20`；常见原因是 5GHz `no-IR` 或信道与 STA 冲突，见 [why-2.4ghz.md](why-2.4ghz.md) |
| dnsmasq 报 `interface ap0 does not currently exist` | `ap0` 没有 IPv4：`ip addr add` 必须排在 hostapd 之后（hostapd 初始化接口时会 down/up 一次），脚本已按这个顺序，手工排查时别颠倒 |
| 客户端连上但没有 IP / 上不了网 | 看 `/var/lib/misc/dnsmasq.leases` 与 `run.sh status` 的 dnsmasq、NAT 两段；`ap0` 不在 firewalld 的 trusted 区时转发会被拦 |
| 5GHz 从列表里消失 | 是 iwd 配置还在钉着 5GHz，见 [why-2.4ghz.md](why-2.4ghz.md) 的症状辨识 |

## 回退

| 想撤销 | 动作 |
|---|---|
| 热点 | `pkexec bash run.sh stop` —— 撤 iptables、杀 hostapd/dnsmasq、删 `ap0`、摘 trusted 区 |
| 2.4GHz 钉住 | `pkexec bash iwd-2g.sh restore`；脚本与备份都没了 → 手工删掉 `/etc/iwd/main.conf` 的 `[Rank]` 段再 `systemctl restart iwd` |
| 整套 | 删 `~/.local/state/vpn-hotspot/` ＋ 上面那条；`ap0`、iptables、firewalld 的改动都是 runtime 的，重启即净 |

## 使用注意

- 手表/手机更新期间**别合盖、别挂起** —— suspend 会掐掉热点。
- 别把 2.4GHz 钉住当常态配置：它会让 iwd 完全不扫 5GHz（见 [why-2.4ghz.md](why-2.4ghz.md)）。
