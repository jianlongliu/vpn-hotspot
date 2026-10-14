# vpn-hotspot

把系统 `mihomo` 的代理出口共享成一个 2.4GHz WiFi 热点（`ap0`），手表、手机连上就能走代理。

## 要求

- Arch 系，装了 `hostapd`、`dnsmasq`、`iwd`、`iptables`、`firewalld`
- **`mihomo` 已在跑** —— 热点出口就是它的 TUN 接口
- **用 `pkexec` 提权**（不是 `sudo`）
- 接口名与网段写死在脚本里：STA `wlan0`、AP `ap0`、出口 `mihomo`、网段 `10.42.0.0/24`（网关 `10.42.0.1`）
- SSID 与密码来自 `~/.local/state/vpn-hotspot/hotspot.env`（脚本里没有密码）

## 用法

```bash
# 一次性：写凭据（值带引号，SSID 含空格也不会被拆断）
mkdir -p ~/.local/state/vpn-hotspot
printf 'HOTSPOT_SSID="%s"\nHOTSPOT_PSK="%s"\n' "SSID" "密码" > ~/.local/state/vpn-hotspot/hotspot.env
chmod 600 ~/.local/state/vpn-hotspot/hotspot.env

# 开
pkexec bash iwd-2g.sh 2g      # STA 钉到 2.4GHz（会重启 iwd，短暂断网）
pkexec bash run.sh start      # 开热点
pkexec bash run.sh status     # 看现场：接口 / 进程 / 租约 / NAT / 转发 / 防火墙 / 频段
pkexec bash selftest.sh       # 端到端自检（可选）

# 关
pkexec bash run.sh stop
pkexec bash iwd-2g.sh restore # 把 5GHz 放回来 —— 别忘这一步
```

`run.sh start` 遇到下面这些会当场退出，不半拉起：`mihomo` 没跑、缺凭据（或密码短于 8 位）、`ap0` 已存在、STA 还落在 5GHz（会提示先跑 `iwd-2g.sh 2g`）。

## 为什么非得先降到 2.4GHz

本机网卡是 Intel AX201（`iwlwifi`），两条硬件限制叠在一起，结果只剩 2.4GHz 这一条路：

- **AP 侧用不了 5GHz**：网卡是自管管制域（`iw phy phy0 info` 标 `self-managed`），5GHz 的 149–165 全带 `no IR`，hostapd 直接以 `NO-IR ... not allowed for AP mode` 拒绝。`iw reg set CN` 与 hostapd 的 `country_code=CN` 都改不动自管域。
- **AP 必须与 STA 同信道**：驱动的接口组合是 `#{managed}<=1, #{AP}<=1, #channels<=1`，STA 在 5GHz 时建 2.4GHz AP 会 `-EBUSY`。

所以先把 STA 钉到 2.4GHz，AP 才能在同一条 2.4GHz 信道上起来。

⚠ **「5GHz 用不了」只限 AP 这一侧**：AX201 作为 STA 连 5GHz 完全正常。钉频用的 `BandModifier5GHz=0.0` 副作用比"降权"狠得多 —— 因子为 0 时 iwd 的周期性扫描根本不把 5GHz 放进扫描频点集，表现成「同名双频永远只连 2.4G、`iwctl station wlan0 scan` 里 0 个 5GHz SSID」。因此它只当临时开关用：用完 `restore`，`run.sh status` 末段会检查有没有忘记还原。

## 验证

- **现场**：`run.sh status` 里 hostapd 有进程、`ap0` 有 `10.42.0.1/24`、NAT 段出现 MASQUERADE、`ip_forward=1`、trusted 区含 `ap0`；`journalctl -t hostapd` 里出现 `AP-ENABLED`。
- **端到端**：`selftest.sh` 里假客户端能解析域名、打到 gstatic `204` 与 google `200`，并在 mihomo 面板（`127.0.0.1:9090`）里看到它的连接。
- **真机**：手表/手机连上后 `/var/lib/misc/dnsmasq.leases` 里出现租约。
- **频段**：`iwd-2g.sh` 每次跑完自己会打 iwd 状态、`wlan0` 的 ssid/channel 与 5GHz BSS 计数（钉住时应为 `0 个`）。

## 文件

| 文件 | 作用 |
|---|---|
| `run.sh` | `start` / `stop` / `status`：建 `ap0`、起 hostapd 与 dnsmasq、配 NAT 与转发 |
| `iwd-2g.sh` | `2g` / `restore`：把 iwd 临时钉在 2.4GHz，以及还原 |
| `selftest.sh` | 用 netns + veth 冒充客户端跑端到端自检 |
| `dnsmasq.conf` | DHCP/DNS：`interface=ap0`、`server=198.18.0.2`（mihomo 的 fake-ip，靠 TUN 劫持） |
| `hostapd.conf.example` | `run.sh start` 生成的配置样例（真值含密码，运行时落在 `~/.local/state/vpn-hotspot/`） |

运维向的东西（状态文件、备份、回退、拆除）在 [`NOTES.md`](NOTES.md)。
