# 为什么必须先降 2.4GHz

## 两条硬件限制

本机网卡是 **Intel Wi-Fi 6 AX201**（`lspci` = `8086:a0f0` rev 20，驱动 `iwlwifi`）。它同时受两条限制，合起来只剩 2.4GHz 一条路：

1. **AP 侧用不了 5GHz**。网卡工作在**自管管制域**（`iw phy phy0 info` 里标 `self-managed`，国家恒为 `00`）：5GHz 的 149–165 信道全部带 `no IR`（no initiating radiation），hostapd 直接以 `NO-IR ... not allowed for AP mode` 拒绝启动。`iw reg set CN` 与 hostapd 的 `country_code=CN` 都改不动自管域——这类网卡的管制域由固件/驱动自己算（LAR），不认内核的 regulatory hint。
2. **AP 必须与 STA 同信道**。驱动的接口组合是 `#{managed}<=1, #{AP}<=1, #channels<=1`：同一块网卡上 AP 与 STA 只能占同一个信道。STA 在 5GHz 时创建 2.4GHz AP 会拿到 `-EBUSY`。

所以链路是：先把 STA 钉到 2.4GHz（`iwd-2g.sh 2g`），AP 才能在同一个 2.4GHz 信道上起来。

## 边界：这只针对 AP

AX201 作为 **STA 连 5GHz 完全正常**（本机日常就落在 5300 MHz / ch60 一带）。开热点期间的 2.4GHz 是临时代价，关掉热点后还原即可。

## BandModifier5GHz 的坑

`iwd-2g.sh 2g` 的实现是往 `/etc/iwd/main.conf` 写：

```ini
[Rank]
BandModifier5GHz=0.0
```

这个因子的作用是给频段打分排序，**但 0 有特殊后果**：iwd 的周期性扫描按因子拼 band mask，因子为 0 时 5GHz 根本不会进入扫描频点集（iwd 3.12 `scan_periodic_get_freqs()`）。表现不是"5GHz 信号差"，而是：

- 同名双频 SSID 永远只连 2.4GHz
- `iwctl station wlan0 scan` 的列表里**一个 5GHz SSID 都不出现**
- `iw phy phy0 info`、root 的 `iw dev wlan0 scan` 里 5GHz 一切正常

也就是说它会把 5GHz 从 iwd 的世界里抹掉，而不是降权。因此：

- 只当临时开关用，关掉热点后必须 `iwd-2g.sh restore`
- `run.sh status` 末段会检查 `main.conf` 里这个因子还在不在，忘记还原时会打警告

## 症状辨识

**root 的 `iw dev wlan0 scan` 看得见自家 5GHz BSS，而 `iwctl`/NetworkManager 的列表里一个都没有 ⇒ 先查 `/etc/iwd/main.conf`，不是驱动或射频问题。**

还原方式：`pkexec bash iwd-2g.sh restore`（取 `~/.local/state/backups/etc/iwd/main.conf.bak-*-pre2ghotspot` 里最新的一份）；脚本与备份都没了，就手工删掉 `[Rank]` 段再 `systemctl restart iwd`。

验证还原成功：`iwd-2g.sh` 每次跑完会打 iwd 状态、`wlan0` 的 ssid/channel 与 5GHz BSS 计数——钉住时应为 `0 个`，还原后应恢复为非 0。
