# 来源与许可说明

本仓库是**独立的社区补丁/脚本集**，与 NullMoth Systems、NVIDIA、Apple、Intel 无关联。

| 内容 | 来源 | 许可 |
|------|------|------|
| `patches/nullmoth-1.9.0/0001`、`0003`、`0004` 及 `per-fix/` 中的插件/内核扩展补丁 | 对 <https://github.com/nullmoth/nvidia-macos-driver> v1.9.0 的修改 | PolyForm Noncommercial 1.0.0（**仅限非商业**）<br>Required Notice: Copyright (c) 2026 NullMoth Systems (https://nullmothsystems.com) |
| `patches/nullmoth-1.9.0/0002-translator.patch`、`per-fix/translator-callers-first.patch` | 对 metal2vulkan（Anees Iqbal）衍生的翻译器的修改 | LGPL-3.0-or-later |
| `patches/voodoo/` | 对 acidanthera/VoodooGPIO 的修改 | 沿用上游（GPL-3.0 / BSD 类） |
| `backlight/NVDSM`、`wifibt/BTLEFix` | 作者原创，依赖 Lilu | GPL-3.0 |
| 其余脚本、测试程序、文档 | 作者原创 | MIT |

**本仓库不包含**：NullMoth/NVIDIA 的任何二进制、GSP 固件、你机器的 OpenCore `config.plist` / EFI、ACPI 转储、Apple 系统文件。
`codec-vulkan/` 里的脚本只携带“偏移 + 原字节 + 新字节”的断言式补丁，需要你自己机器上已安装的原版文件。

使用者须自行遵守上游驱动与 macOS 的许可条款。
