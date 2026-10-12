# AirportItlwm 开机初始化失败自愈（修复 18 原生 Wi-Fi 的稳定性补丁）

**现象**：部分开机后 Wi-Fi 一直显示“未连接”，列表里没有网络，要手动关一次 Wi-Fi 再打开（约 30 s 后）才恢复。
运行中并不会掉线：configd 的 `en2 link` 时间线 26 h 内没有一次中途 INACTIVE，坏的都是“这次开机从没连上”。

**根因**（laobamac/itlwm 的 Sequoia WCL 构建，9bc4b4d 与 d695c97 都有）：
1. 开机时驱动还没就绪（`isDriverAvailable=0`），IO80211Family 会把外部的 `SIOCGA80211` ioctl（GET OP_MODE / POWER / SUPPORTED_CHANNELS / SSID）
   在**共享的 work loop gate 里**挂起 4–9 s。AirportItlwm 的 HAL 与 IO80211 用同一个 work loop（`getWorkQueue()`），
   固件 ALIVE 中断和等待线程都要这个 gate，于是首次加载固件被拖到 5–11 s。
2. `iwx_load_firmware` 等 ALIVE 的预算只有 1000 ms（被 gate 拖住后实际约 6.5 s 才超时），`iwx_init` 只重试 1 次。两次都晚就失败。
3. 失败后驱动清掉 `IFF_UP`、上报 `DriverAvailable=0`，但 `power_state` 仍是 1；airportd 只发一次上电，没人再重试。
   另外有些路径留下 `IFF_UP` 却没有 `IFF_RUNNING`，`ItlIwx::enable()` 会因“已在激活中”直接返回。

**补丁**（[`patches/itlwm/0001-AirportItlwm-init-recovery.patch`](../../patches/itlwm/0001-AirportItlwm-init-recovery.patch)，基于 laobamac/itlwm `d695c97`）：
- ALIVE 预算 15 s（成功时立刻返回，正常开机不变慢），每次加载 IOLog `itlwm: firmware alive wait N ms, err E ok K`。
- `iwx_init` 最多 3 次尝试。
- `AirportItlwm::watchdogAction`（原有的 1 Hz 定时器）里加自愈：上电但接口没 RUNNING 时
  - `IFF_UP` 已清：3 s 后经 `_fCommandGate` 重跑 `enable()`，失败则间隔翻倍到 60 s，永不放弃；
  - `IFF_UP` 挂着 30 s 仍没 RUNNING：`disable()` + `enable()`。
  每次 IOLog `itlwm: init recovery #N`，并在 IORegistry 写 `ItlwmInitRecoveries`。
- 性能：自愈检查只是每秒比较几个标志；额外日志每次开机约 3 行。Wi-Fi 6（`itlwm_he=1`）不受影响。

**自愈覆盖范围**：开机/唤醒初始化失败（本补丁）；TX 卡住（驱动自带 `device timeout` → `init_task`）；固件错误中断（驱动自带重启，重启失败再由本补丁接手）；
断开关联（airportd 自动重连）。**不覆盖**：接口 RUNNING 但收包静默死掉且没有发送。

## 编译与安装

```bash
git clone https://github.com/laobamac/itlwm && cd itlwm && git checkout d695c97
git apply /path/to/patches/itlwm/0001-AirportItlwm-init-recovery.patch
git clone https://github.com/acidanthera/MacKernelSDK && git -C MacKernelSDK checkout 3f750085
xcodebuild -project itlwm.xcodeproj -scheme AirportItlwm-Sequoia -configuration Release ARCHS=x86_64 \
  SYMROOT=$PWD/build/out OBJROOT=$PWD/build/obj CODE_SIGNING_ALLOWED=NO GIT_COMMIT=_d695c97+initrec build
```

产物（`build/out/Release/Sequoia/AirportItlwm.kext`）放到 `wifibt/kexts/AirportItlwm.kext`，然后：

```bash
sudo -E ESP_DEV=disk1s4 ESP_UUID=<你的 ESP Partition UUID> bash wifibt/replace-airportitlwm.sh
```

脚本先把 ESP 上原来的 kext 备份到 `wifibt/backup/esp-aitlwm-<时间>`，替换后逐字节读回比对；撤销：`... replace-airportitlwm.sh undo <备份目录>`。
默认检查 Info.plist 里有 AX211 的 `0x51F18086`，别的 iwx 网卡设 `WIFI_PCI_ID`。用了 efiguard 的话替换后要刷新快照。

**检查**：`sudo dmesg | grep -E "alive wait|init recovery"`；`ioreg -r -c AirportItlwm | grep ItlwmInitRecoveries`；`ifconfig en2` 应有 `RUNNING`。
`networksetup -getairportnetwork` 和日志里的 “Apple80211Scan Failed” **不能**当健康指标（已连接时旧 ioctl 照样失败）。

## 怎么查到的

itlwm 的 Release 构建每条固件命令都打日志，128 KB 的内核消息缓冲只够约 50 s，开机后手动 `dmesg` 早已看不到失败现场。
[`tools/wifi-bootlog/`](../../tools/wifi-bootlog/) 把 `kern.msgbuf` 调到 1 MB，并在开机 60/120/180 s 各存一份 dmesg。
随后几轮诊断构建：分片等待证明 ALIVE 早已置位而等待线程拿不到 gate；`IOWorkLoop::setMaximumLockTime(1 s)` 打出持有者回溯在 IO80211Family 里，
IO80211 自己的 `_logTimeIfThresholdExceeded` 显示被挂起的是外部 `SIOCGA80211`；不发 reset 通告也照样挂起，说明只由 `isDriverAvailable=0` 触发。
上游同类问题：[laobamac/itlwm#19](https://github.com/laobamac/itlwm/issues/19)（唤醒后一直不可用，直到开关 Wi-Fi）。
