# tahoe/ — macOS 26 专用脚本

作者本机从 macOS 15.8.1 升级到 **26.7.1**（SMBIOS 仍是 iMacPro1,1，驱动 NullMoth 1.15.0 + 本仓库补丁）时用到的全部东西。
原因和排查过程见 [docs/fixes.md 第 32–34 项](../docs/fixes.md#十一macos-26tahoe)，操作顺序见 [docs/applying.md 第 9 节](../docs/applying.md#9-升级到-macos-26tahoe)。

> 改 ESP 的脚本都用 `ESP_UUID`（OpenCore 所在 ESP 的分区 UUID）**按 UUID 找盘**：两块 NVMe 的识别先后不固定，ESP 的盘号偶尔会变（`disk1s4` / `disk0s4`）。
> 运行方式：`sudo -E ESP_UUID=$(diskutil info disk1s4 | awk -F': *' '/Partition UUID/{print $2}') bash <脚本>`（`disk1s4` 换成你现在的 ESP）。
> 脚本里的 kext / 内核扩展哈希都是**作者的构建**，用在你的机器上要换成你自己的。

| 文件 | 什么时候用 | 作用 |
|---|---|---|
| `prep-efi-26.sh` | 升级前，在 15 上 | 15 和 26 都能用的 EFI 改动：RestrictEvents、`-no_compat_check revpatch=sbvmm`、AirportItlwm 的 Tahoe 条目（`MinKernel 25.0.0`）、NVDSM/BTLEFix 的 26 版。`--check` 只演练；`TAHOE_TEST_ESP=<目录>` 在 ESP 副本上测试。要你自己把 kext 放进 `payload/ESP/` |
| `revert-efi-26.sh` | 撤销上一步 | 从 `prep-efi-26.sh` 的备份 tar 恢复 `config.plist` 和 `Kexts`（**别拿它救已经升级的 26**，见 `RESCUE.md`） |
| `update-26.sh` | 开始升级前一刻 | `prepare`：驱动停放（`-nvoff`）+ 安装器屏幕设置 + LaunchDaemon；第一次进 26 自动 `finish`：换 26 版 NVAccel、重建辅助内核集合、设置改回、重启一次。`cancel` 撤销。日志 `/Library/NullMoth/tahoe/update.log` |
| `install-rescue.sh`、`rescue/`、`RESCUE.md` | 升级前装好，之后每次有意改 `config.plist` 后重跑 | ESP 上的 `EFI/OC/rescue/`：恢复模式终端里 `sh rescue.sh safe` 换成救援配置（驱动停放 + 关掉 4 个新加/自己的 kext），`restore` 改回。生效时 efiguard 和 `finish` 不动 ESP |
| `add-ocrec.sh` | 可选（Limine 引导 OpenCore 的布局） | 复制 `EFI/OC` → `EFI/OCREC`（立即显示 OpenCore 选单），Limine 菜单加 “macOS Recovery”。`undo` 撤销 |
| `audio/install-hda26.sh` | 进 26 之后（每次 macOS 更新后确认） | 把 15.7.9 KDK 的 AppleHDA 放进 `/Library/Apple/System/Library/Extensions` 并重建辅助内核集合（`kmutil -b`）。需要 ESP 上有 BTLEFix 1.0.6。KDK（dortania KdkSupportPkg `24G830`）自己下载解开到 `audio/dl/kdk15/`，或 `HDA_SRC=<AppleHDA.kext>`。`undo` 撤销 |
| `audio/diag-hda-stuck.sh` | 声卡不出现时 | 收集内核消息、带符号的内核栈、编解码器的 ioreg |
| `power/install-acpsr.sh`、`power/acpi/SSDT-ACPSR.*` | 插电却显示电池 / FileVault 转换暂停时 | 自己的 `\_SB.AC._PSR`（返回 `ACFG`）+ ACPI 改名 `_PSR → XPSR`。`undo` 撤销。**`ACFG` 等名字是这台机器 DSDT 里的，先核对你的** |
| `power/show-acpi.sh` | 随时（只读） | 列出 ESP 上 `config.plist` 的 ACPI/Add、ACPI/Patch 和 SSDT 文件 |
| `power/ACProbe/`、`power/install-acprobe.sh` | 诊断 | 只读 kext：在内核里求值 `AC._PSR`、EC 字段并挂到 IORegistry（`ioreg -rn AC -l \| grep probe_`）。用完 `install-acprobe.sh undo` |

改完 EFI 后记得重跑 `efiguard/install.sh`（刷新 ESP 守护的快照）和 `install-rescue.sh`（让救援配置跟上）。**不要测试系统睡眠**：NullMoth 没有 GPU 挂起/恢复，唤醒后黑屏（见 docs/pitfalls.md）。
