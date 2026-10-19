# 来源与许可说明

本仓库是**独立的社区补丁/脚本集**，与 NullMoth Systems、NVIDIA、Apple、Intel 无关联。

| 内容 | 来源 | 许可 |
|------|------|------|
| `patches/nullmoth-1.9.0/0001`、`0003`–`0006`、`patches/nullmoth-1.13.0/0001`、`patches/nullmoth-1.14.2/0001`、`patches/nullmoth-1.15.0/0001`、`0003`、`patches/nullmoth-2.3.7/0001`、`0003` 及 `per-fix/` 中的插件/内核扩展补丁 | 对 <https://github.com/nullmoth/nvidia-macos-driver> v1.9.0 / v1.13.0 / v1.14.2 / v1.15.0 / v2.0.4 / v2.3.7 的修改 | PolyForm Noncommercial 1.0.0（**仅限非商业**）<br>Required Notice: Copyright (c) 2026 NullMoth Systems (https://nullmothsystems.com) |
| 各目录（含 `nullmoth-2.3.7`）的 `0002-translator.patch`，`per-fix/` 中的 `translator-callers-first.patch`、`sampler-array-translator.patch`、`translator-table-merge.patch` | 对 metal2vulkan（Anees Iqbal）衍生的翻译器的修改 | LGPL-3.0-or-later |
| `patches/voodoo/` | 对 acidanthera/VoodooGPIO 的修改 | 沿用上游（GPL-3.0 / BSD 类） |
| `patches/itlwm/` | 对 laobamac/itlwm（OpenIntelWireless itlwm 分支）的修改 | 沿用上游（GPL-2.0） |
| `backlight/NVDSM`、`wifibt/BTLEFix` | 作者原创，依赖 Lilu | GPL-3.0（见 [LICENSE](LICENSE)） |
| `tahoe/power/ACProbe`（诊断 kext）、`tahoe/power/acpi/SSDT-ACPSR`、`tahoe/` 的其余脚本 | 作者原创 | GPL-3.0（见 [LICENSE](LICENSE)） |
| 其余脚本、测试程序、文档 | 作者原创 | GPL-3.0（见 [LICENSE](LICENSE)） |

**本仓库不包含**：NullMoth/NVIDIA 的任何二进制、GSP 固件、你机器的 OpenCore `config.plist` / EFI、ACPI 转储、Apple 系统文件（包括 macOS 26 声卡要用的 AppleHDA / KDK，请自行从 Apple / dortania 获取）、RestrictEvents / AirportItlwm 等第三方 kext。
`codec-vulkan/` 里的脚本只携带“偏移 + 原字节 + 新字节”的断言式补丁，需要你自己机器上已安装的原版文件。

使用者须自行遵守上游驱动与 macOS 的许可条款。

补丁文件（`.patch`）里的代码属于被修改的上游项目，**沿用该上游的许可证**，不因本仓库的 GPL-3.0 而改变；本仓库的 GPL-3.0 只适用于上表中标为“作者原创”的文件。
