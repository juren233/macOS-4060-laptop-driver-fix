# 系统睡眠：打开与测试步骤

## 背景

NullMoth 从 2.0.3 起支持 S3 睡眠，对应上游提交 5583ee9（PR #182）。具体机制：

- 睡眠时 RM 进入 standby，整块显存先拷进可换页的内核内存保存。
- 唤醒时恢复 PCI 配置、Resizable BAR 大小和根端口窗口，再把 GSP 重新拉起来。
- NVRMFB 替 IOGraphics 完成唤醒时的通知工作，NVAccel 保证每个 surface 唤醒后拿回原来那块显存。

原理详见 `src/wt-k237/docs/SLEEP-WAKE.md`。

我们装的 2.3.7 内核里已经带着这些代码，只是被两样东西关着：

- 开机参数 `-nvrmnopm`：NVRM 不加入电源树。
- `SleepDisabled 1`：合盖和苹果菜单的"睡眠"都不会让系统睡下去。

这台机器的条件和上游处理的情况一致：

- DSDT 里有 S3（SS3=One）。
- NVRM 开机时把 BAR1 移到了 8 GB @0x7c00000000，并改了根端口窗口。上游唤醒时恢复的正是这两样。

以下几项上游没测过：

- 笔记本 eDP 屏和背光的唤醒。
- 合盖唤醒。
- AD107 这颗芯片。
- 休眠（hibernate），所以我们固定 hibernatemode 0。

## 第 1 步：让 NVRM 进入电源树（睡眠仍然关着）

```bash
sudo bash ~/work/nvidia-setup/sleep/enable-sleep.sh
```

脚本会依次做这几件事：

1. 备份当前的 boot-args 和 pmset 设置。
2. 用 `wifibt/oc-bootarg.sh` 从 ESP 的 config.plist 里删掉 `-nvrmnopm`。这一步会先备份，写入后再读回比对。
3. 重新生成 efiguard 快照。不做这一步的话，efiguard 会把 `-nvrmnopm` 加回来。
4. 设置 `hibernatemode 0`、`powernap 0`、`proximitywake 0`，减少测试期间的暗唤醒，也确保不会写休眠镜像。

`SleepDisabled` 保持为 1。这一步做完后正常重启。

**风险**：开机时 NVRM 会加入电源树，RM 的调用会经过一道电源门控。这是上游的默认配置，所有没加 `-nvrmnopm` 的用户都这样跑。

## 第 2 步：重启后检查（只读，不需要 sudo）

```bash
zsh ~/work/nvidia-setup/sleep/check-sleep.sh
```

检查以下几项：

- boot-args 里已经没有 `-nvrmnopm`。
- 四个 2.3.7 kext 都已加载，开机以来没有 panic。
- `nvrm-pm = running`。
- 内核日志里有 "joined the power tree" 和 "PreserveVideoMemoryAllocations=1" 两行。
- sticky VRAM 是打开的。
- SleepDisabled 仍为 1，hibernatemode 为 0。

想顺便确认桌面 GPU 路径没受影响，可以再跑一次 `hidpi/check-wsmark.sh`。

结果不是 ALL OK 就停在这里，执行第 5 步回滚。

## 第 3 步：一次定时睡眠（要你在机器前）

先保存好手上的工作，接上电源，然后：

```bash
sudo bash ~/work/nvidia-setup/sleep/sleep-test.sh 45
```

脚本会先检查前提条件，然后要你输入 `yes` 才开始。开始后依次是：

1. 装一个只在下次开机时运行一次的守护。它的作用见下面的"屏幕不亮时"。
2. 临时打开睡眠，预约 45 秒后唤醒，立即睡眠。
3. 等 pmset 日志里出现完整唤醒（Wake），最多等 45+300 秒。之后马上把 SleepDisabled 设回 1。
4. 把报告写到 `sleep/evidence/test-<时间>/`，内容包括 pmset 日志、NVRM/NVRMFB 内核日志、唤醒原因、计数器和结论。

结论为 PASS 需要同时满足：

- 有完整唤醒。
- 唤醒后 `nvrm-pm` 仍是 running。
- 日志里有 `sleep #`、"GPU running"、"NVRM-fb: system wake: clients told DidWake" 这几行。
- WindowServer 没有重启。
- 没有 Sleep Wake Failure，也没有 panic。

**唤醒时的情况和处理**：

- **定时器唤醒后屏幕没亮**：定时器唤醒有时只到暗唤醒（DarkWake），屏幕要按一下键才会亮。按一下键。
- **按键后过了约 2 分钟屏幕还是黑的**：
  - 再等一会儿：系统其实可能还活着，脚本还在写报告。
  - 然后长按电源键 10 秒强制关机。
  - 下次开机时，第 1 项装的守护会把 SleepDisabled 设回 1，合盖不会再走这条坏掉的路。
  - 报告和上一次开机的内核日志都还在，我可以接着查。

**PASS 之后请你目测这些**：

- 画面和 HiDPI 分辨率。
- 亮度键。
- Wi-Fi 和蓝牙。
- 触摸板。
- 声音。

## 第 4 步：正式启用（sleepguard）

```bash
sudo zsh ~/work/system/sleepguard/install.sh on
```

装上一个开机运行、之后每 10 分钟再跑一次的守护 `local.sleepguard`，让 SleepDisabled 跟着驱动的状态走：

- 只有同时满足以下三条，才允许睡眠（SleepDisabled 0），并保持 hibernatemode 0：
  - 你要了睡眠（`install.sh on`）；
  - boot-args 里没有 `-nvrmnopm`；
  - NVRM 显示 `nvrm-pm = running`。
- 其他任何情况都立即关掉睡眠（SleepDisabled 1），例如：
  - 回滚到不支持睡眠的旧 kext；
  - `-nvrmnopm` 被加了回来；
  - 某次唤醒后 GPU 变成 `lost (resume failed)`。

  这样合盖时就不会走进黑屏的那条路。
- 日志在 `/var/log/sleepguard.log`。查看状态：`zsh ~/work/system/sleepguard/install.sh status`。

`nvguard/verify.sh` 里多了"system sleep"一节：

- 允许睡眠但 GPU 不支持时，报 DANGER。
- 想要睡眠、GPU 也支持，却仍是 SleepDisabled 1 时，报 CHANGED。

闲置多久自动睡眠，在"系统设置 → 电池 / 锁定屏幕"里调。守护不会改这个设置。

关掉睡眠用 `install.sh off`；完全卸掉用 `install.sh remove`，卸掉后 SleepDisabled 为 1。

## 第 5 步：回滚（任何时候都可以）

```bash
sudo bash ~/work/nvidia-setup/sleep/rollback-sleep.sh
```

回滚会做这些事：

- 把 sleepguard 切到 off（如果已装），再把 SleepDisabled 设回 1。
- 把 `-nvrmnopm` 加回 boot-args。
- 让 efiguard 重新要求 `-nvrmnopm`。
- 按第 1 步的备份恢复 pmset 设置。

做完重启即可。
