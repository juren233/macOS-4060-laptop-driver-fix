# 怎么用这些补丁

## 0. 先决条件

- OpenCore 能正常引导 macOS 15.x（或按第 9 节升级到 26）；已按 NullMoth 官方步骤装好其驱动（本仓库**不分发**驱动）。
- Xcode 命令行工具（编译插件）、Rust 工具链（编译翻译器）、`python3`、`git`。
- 一个**能进的备用启动项**（OpenCore 的安全模式 / 第二块 EFI），和一份完整的 EFI 备份。
- 所有改 ESP 的脚本需要两个环境变量（缺失即退出，防止写错盘）：
  ```bash
  export ESP_DEV=disk1s4     # diskutil list
  export ESP_UUID=$(diskutil info $ESP_DEV | awk -F': *' '/Partition UUID/{print $2}')
  ```
  `wifibt/install-airportitlwm.sh`、`oc-bootarg.sh`、`backlight/enable-ec.sh`、`install-builtin-bl.sh`、`kexts/install-kexts-115.sh` 等用 `mtools` 直接写 ESP，需要 `brew install mtools`。
  **盘号每次开机可能不同**（macOS 26 上见过 `disk1s4` / `disk0s4`）：`tahoe/`、`efiguard/`、1.15.0 内核扩展脚本只认 `ESP_UUID`、自己按 UUID 找盘（`sudo -E` 传进去）；其余脚本运行前请重新确认 `ESP_DEV`。

## 1. 取得上游源码并打补丁

```bash
git clone https://github.com/nullmoth/nvidia-macos-driver && cd nvidia-macos-driver
```
**旧基线 1.9.0**（用户态 + 内核扩展，macOS 15）：
```bash
git checkout v1.9.0
P=/path/to/this-repo/patches/nullmoth-1.9.0
git apply $P/0001-plugin.patch $P/0002-translator.patch $P/0003-nvrm-flip-at-once.patch $P/0004-nvrmfb-backlight.patch
# 可选（修复 21，光标只提交光标；内核扩展，装前先读下面的风险）：
git apply $P/0005-nvrmfb-cursor-only.patch
# 可选（修复 26 的内核部分：新显存抽样为零就不再 CPU 清零；内核扩展，在 0005 之后）：
git apply $P/0006-nvrmfb-vram-noclear.patch
```
**推荐：1.15.0**（插件 + 翻译器 + NVRMFB，含修复 26–30；作者现在用的就是这一套）：
```bash
git checkout v1.15.0
P=/path/to/this-repo/patches/nullmoth-1.15.0
git apply $P/0001-plugin.patch $P/0002-translator.patch
git apply $P/0003-nvrmfb-vram-noclear.patch      # 内核扩展（NVRMFB），可选，见第 5 节
# 旧的用户态补丁集：v1.14.2 → patches/nullmoth-1.14.2/0001、0002；v1.13.0 → patches/nullmoth-1.13.0/0001、0002
```
1.9.0 的四个补丁已验证可在原版 v1.9.0 上干净应用，且打补丁后的插件可编译；1.14.2、1.15.0 的补丁同样验证过（应用后的源码与作者在用的构建一致，只有注释里的路径不同）。
1.9.0–1.14.2 的翻译器补丁里带着作者离线构建时被精简的 `translator/translator/Cargo.lock`；1.15.0 的不带，用上游的。
`per-fix/` 里的是各修复的独立 diff，用来阅读，**不要**按顺序叠加。

## 2. 编译插件

```bash
cd plugin
xcrun clang -arch x86_64 -bundle -fobjc-arc -O1 -DNVMTL_RELEASE=1 \
  -Wno-protocol -Wno-incomplete-implementation \
  -I<Vulkan-Headers>/include \
  -o NVMTLDriver NVMTLDevice.m \
  -framework Foundation -framework Metal -framework IOSurface -framework IOKit -framework CoreVideo
codesign -f -s - -i com.nullmoth.NVMTLDriver NVMTLDriver   # 标识符要和安装器期望的一致；不签名 WindowServer 会拒绝加载（见 pitfalls）
```
`Vulkan-Headers` 用 Khronos 的 `Vulkan-Headers`（`include/vulkan`）。在 macOS 26 上编译要加 `-mmacosx-version-min=15.0`，才和作者装的构建一致（同一份源码只差 `LC_UUID`）。**没有 `-DNVMTL_RELEASE=1` 的构建会写 `/tmp/nvmtl-*` 诊断文件，且保留环境变量旋钮**。
上游的 `build/build_plugin.sh` 是官方构建脚本（会校验功能标记是否都在，本补丁只改了其中一行），也可以直接用它。

## 3. 编译翻译器

```bash
cd translator/wrapper && cargo build --release      # 产物 libnvmtl_translate.dylib
```
翻译器 crate 自带的测试在本机不能编（缺校验夹具），不要指望 `cargo test`。验证用 `hidpi/catest/` 里的程序（见下）。

## 4. 替换到系统（不要杀正在运行的进程）

**永远不要用 `cp` 覆盖已被加载的 dylib/可执行文件**（同一 inode 会让内核缓存的代码签名失效，所有随后加载它的进程被 SIGKILL）。用“复制到旁边再 `mv`”：

```bash
sudo zsh hidpi/plugin-swap.sh     /path/to/NVMTLDriver
sudo zsh hidpi/translator-swap.sh /path/to/libnvmtl_translate.dylib   # 会自测，失败自动回滚
```
WindowServer 要重启（通常重启系统）才会加载新文件；新启动的进程立刻使用新文件。旋钮写入 `/Library/GPUBundles/nvmtl/nvrm610.conf`（`tools/nvknob.sh`）。

## 5. 内核扩展（NVRM / NVRMFB）

**1.15.0（推荐，作者现用）**：
```bash
# 1) 取得上游 1.15.0 安装包的 payload，放在 kexts/payload（路径和哈希由 install-kexts-115.sh 校验）
python3 -I kexts/patch-nvrm-115.py kexts/payload/Library/Extensions/NVRM.kext/Contents/MacOS/NVRM   # head-scaler + 启动即翻转
codesign -f -s - kexts/payload/Library/Extensions/NVRM.kext
# 2) 用打过 1.15.0/0003 的源码编译 NVRMFB（需要 NVIDIA open-gpu-kernel-modules，路径见脚本），替换 payload 里的同名二进制
SRC=/path/to/src kexts/build-fb-115.sh kexts/out /path/to/patched-v1.15.0
sudo -E ESP_UUID=… kexts/install-kexts-115.sh --check   # 只构建测试用内核集合，不改系统
sudo -E ESP_UUID=… kexts/install-kexts-115.sh           # 备份 → 替换 → 重建 Aux KC → ESP 上的 NVDSM
sudo -E ESP_UUID=… kexts/rollback-kexts-115.sh <备份目录>
```
`install-kexts-115.sh` 在 macOS 15 上运行，里面的哈希都是作者的构建（含“当前已装的是 1.9.0 + 补丁”的检查），换成你的。macOS 26 的 NVAccel 由第 9 节的 `update-26.sh` 换。
上游 1.15.0 已自带背光和光标修复，所以不需要 1.9.0 的 `0004`、`0005`；NVDSM 要用本仓库的新版（遇到 1.15.0 的 NVRM 会让出背光注册）。

**1.9.0（旧基线）**：

```bash
# 1) 取得上游 1.9.0 安装包的 payload，放在 kexts/payload（路径和哈希由 install-kexts-190.sh 校验）
python3 -I kexts/patch-nvrm-190.py kexts/payload/Library/Extensions/NVRM.kext/Contents/MacOS/NVRM
# 2) 用打过 0004 的源码编译 NVRMFB（参考 backlight/build-fb.sh；它假定 NVIDIA open-gpu-kernel-modules 在
#    ../../src/ogkm、上游仓库在 ../../src/repo，路径需按你的目录改），替换 payload 里的同名二进制
sudo kexts/install-kexts-190.sh --check     # 只构建测试用内核集合，不改系统
sudo kexts/install-kexts-190.sh             # 备份 → 替换 → 重建 Aux KC
sudo kexts/rollback-kexts-190.sh <备份目录>  # 回滚（Recovery 里也可用）
```
`patch-nvrm-190.py` 只接受“原版 1.9.0”或“已打过全部/部分补丁”的二进制，每个字节都先断言再写，哈希不同的构建会直接报错。
`install-kexts-190.sh` 里的哈希是**作者本机构建**的值，你自己的构建需要改成你的哈希。

亮度还需要 **NVDSM**（Lilu 插件，`backlight/NVDSM/build.sh`，需要 Lilu 1.7.2 源码 + MacKernelSDK，用 `LILU=… MKSDK=…` 指定）和 BrightnessKeys，
再由 `backlight/install-builtin-bl.sh` 一并装入；OpenCore 的 `config.plist` 条目由脚本代改（先备份）。

## 6. HiDPI 显示覆盖

`hidpi/overrides/DisplayProductID-b40.final` 是 **BOE 0B40（VendorID 0x9e5，ProductID 0xb40）** 的文件。要用在你的面板上：
1. 用 `ioreg -l -w0 | grep -i -E "DisplayVendorID|DisplayProductID"` 或 `hidpi/tools/listmodes` 找到你的 ID。
2. 复制并改名为 `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<十六进制>/DisplayProductID-<十六进制>`，修改 `DisplayVendorID/DisplayProductID` 键。
3. `scale-resolutions` 里每项是 base64 的 `宽(4B) 高(4B) flags(4B)`；可参考 [fixes.md 第 1 项](fixes.md) 选择你的刷新率下 IMP 接受的最大降采样比（作者的面板：2560×1440@165 → ≤1.4×）。
4. **完整重启**。

## 7. 二进制补丁（编解码 / Vulkan）

这些脚本针对**特定构建**的 NullMoth 二进制（按固定偏移和字节断言），遇到不同构建会拒绝执行：
```bash
sudo zsh codec-vulkan/nvdec/nvdec-t2d.sh install|restore
sudo zsh codec-vulkan/nvenc/uu-nvenc-t2d.sh install|restore
sudo zsh codec-vulkan/vulkan/vk-devnull.sh install|restore
```
`vk-bindfix.sh` / `mk-bindfix*.py` 是用 Python 重新推导补丁的版本（1.0.10 与 1.9.0 偏移不同）；`mk-bindfix-190.py` 对应 1.9.0 的 `libvulkan_nouveau.dylib`。
用 1.14.2 补丁集的插件时，再用 `mk-nomem-190.py` 去掉 `hw.memsize` 改写（修复 27，插件和 NVK 要一起换）。**1.15.0 的原版 NVK 不需要任何补丁。**
H.264 解码提速（修复 14）：`mk-detile8.py`、`mk-sleep.py` 生成补丁版，`sudo zsh codec-vulkan/nvdec/nvdec-sleep.sh` 安装（带 `restore`），`decbench.swift` 测速并逐比特比对。

## 8. 守护（可选）

`efiguard/` 守护 ESP 上的修复（见它的 README）。`nvguard/` 是作者的“**NullMoth 重装/更新后自动把补丁放回去**”的 LaunchDaemon：快照被登记的构建到 `/Library/NullMoth/guard`（`schg`），启动和被守护目录变化时若发现被替换成**已知的原版哈希**就恢复，**未知构建不动**。
它里面的哈希是作者本机的构建；用在自己机器上要把 `install.sh` 里的 `GOOD_*` / `OLD_*` / `STOCK_*` 换成你的。`nvguard/verify.sh` 无需 sudo 即可核对当前状态。

## 测试

`hidpi/catest/*.m` 是针对每个修复写的最小回归程序，直接 `clang -fobjc-arc -framework … x.m -o x`：

| 程序 | 作用 |
|------|------|
| `plugshim.m` | `DYLD_INSERT_LIBRARIES=plugshim.dylib NVMTL_TEST_PLUGIN=<构建>` 让任意 `MTLCreateSystemDefaultDevice` / `MTLCopyAllDevices` 测试程序使用指定的插件构建 |
| `surftex.m` `hostcopy.m` `tiledtex.m` `usecount.m` `surfasync.m` | IOSurface 一致性 / use count / 异步上传 |
| `rshtest.m` `lintbench.m` `lintarget.m` `partial.m` | tiled 渲染影子的正确性与性能 |
| `selffetch.m` `selfrect.m` | self-bind guard（含负对照） |
| `nsamp.m` `gldiff.m` | 采样数 / Apple GL 对比 |
| `cikl.m` `cidown.m` `lanczos.m` `mipt.m` `fmath.m` | Core Image Lanczos 与相关数学 |
| `upbench.m` `vidup.m` `schedlat.m` `chainstress.m` `newsurf.m` `rparktest.m` | 修复 26：视频帧上传、`waitUntilScheduled` 延迟、提交顺序压力、每帧新表面开销、渲染影子复用 |
| `danmaku/` | 修复 26：合成弹幕页 + 4K 测试视频生成、隔离的测试 Chrome，`tools/wsframes.sh` 数 WindowServer 实际上屏帧数（不需要录屏权限） |
| `ffsandbox.m` `unitylock.m` | 修复 27（Firefox GPU 沙箱，需自备 `ffsandbox-gpu.sb`）、28（Unity 式加锁提交） |
| `drawbench.m` | 修复 29：每次 draw 的 CPU 开销（5 种绑定模式）+ 图像校验和 |
| `vtreg.m` | 修复 14：H.264 硬件解码器是否注册到 VideoToolbox |
| `tiledmips.m` | 修复 30：`newTiledTextureWithBytesNoCopy` + mipmap 描述符时每一级是否有内容 |
| 上游 `tools/bench_vt_transfer.m` | 修复 29 的回归：VideoToolbox 两遍缩放输出是否空白 / 有整列为零 |
| `hidpi/tests/*.sh` | 旋钮二分、WindowServer 重启、模式探测等脚本 |

测试未发布的翻译器：在同一目录放插件副本、指向 `air-runtime` 的软链和新的 `libnvmtl_translate.dylib`，再用 `plugshim` 运行。

## 9. 升级到 macOS 26（Tahoe）

详细原因见 [fixes.md 第 32–34 项](fixes.md)，脚本都在 [`tahoe/`](../tahoe/README.md)。顺序：
1. 在 15 上把驱动换成 1.15.0 + 本仓库补丁（第 1–5 节），确认稳定。准备 30–40 GB 空闲空间、一份 EFI 备份。
2. `sudo -E ESP_UUID=… bash tahoe/prep-efi-26.sh --check`，再去掉 `--check` 运行；重启回 15 检查 Wi-Fi、蓝牙、亮度、声音。（`payload/ESP` 里的 kext 要自己准备，哈希换成你的。）
3. `sudo -E ESP_UUID=… bash tahoe/install-rescue.sh`：把救援配置放到 ESP 上，读一遍 `tahoe/RESCUE.md`。可选 `tahoe/add-ocrec.sh`（Limine 用户的恢复模式入口）。
4. `sudo -E ESP_UUID=… bash tahoe/update-26.sh prepare`，然后到“系统设置 → 软件更新”升级。第一次进 26 会自动收尾并重启一次；日志 `/Library/NullMoth/tahoe/update.log`。
5. 进 26 后：声卡 `sudo bash tahoe/audio/install-hda26.sh`（需要 BTLEFix 1.0.6 在 ESP 上），电源/FileVault 有问题时 `sudo -E ESP_UUID=… bash tahoe/power/install-acpsr.sh`，
   然后重跑 `efiguard/install.sh` 和 `tahoe/install-rescue.sh` 刷新快照与救援配置。**不要测试系统睡眠。**
