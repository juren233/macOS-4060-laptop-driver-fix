# 怎么用这些补丁

## 0. 先决条件

- OpenCore 能正常引导 macOS 15.x；已按 NullMoth 官方步骤装好其驱动（本仓库**不分发**驱动）。
- Xcode 命令行工具（编译插件）、Rust 工具链（编译翻译器）、`python3`、`git`。
- 一个**能进的备用启动项**（OpenCore 的安全模式 / 第二块 EFI），和一份完整的 EFI 备份。
- 所有改 ESP 的脚本需要两个环境变量（缺失即退出，防止写错盘）：
  ```bash
  export ESP_DEV=disk1s4     # diskutil list
  export ESP_UUID=$(diskutil info $ESP_DEV | awk -F': *' '/Partition UUID/{print $2}')
  ```
  `wifibt/install-airportitlwm.sh`、`oc-bootarg.sh`、`backlight/enable-ec.sh`、`install-builtin-bl.sh` 等用 `mtools` 直接写 ESP，需要 `brew install mtools`。

## 1. 取得上游源码并打补丁

```bash
git clone https://github.com/nullmoth/nvidia-macos-driver && cd nvidia-macos-driver
git checkout v1.9.0
P=/path/to/this-repo/patches/nullmoth-1.9.0
git apply $P/0001-plugin.patch $P/0002-translator.patch $P/0003-nvrm-flip-at-once.patch $P/0004-nvrmfb-backlight.patch
# 可选（修复 21，光标只提交光标；内核扩展，装前先读下面的风险）：
git apply $P/0005-nvrmfb-cursor-only.patch
# 可选（修复 26 的内核部分：新显存抽样为零就不再 CPU 清零；内核扩展，在 0005 之后）：
git apply $P/0006-nvrmfb-vram-noclear.patch
# 推荐的用户态（插件 + 翻译器，含修复 26–29）：另开一份源码 git checkout v1.14.2，再
#   git apply patches/nullmoth-1.14.2/0001-plugin.patch patches/nullmoth-1.14.2/0002-translator.patch
# 也可以用 v1.13.0：git checkout v1.13.0，再 git apply patches/nullmoth-1.13.0/0001-plugin.patch patches/nullmoth-1.13.0/0002-translator.patch
```
四个补丁已验证可在原版 v1.9.0 上干净应用，且打补丁后的插件可编译；1.14.2 的两个补丁同样验证过（应用后的源码与作者在用的构建一致）。`translator/translator/Cargo.lock` 没有包含在补丁里（作者离线构建时被精简）。
`per-fix/` 里的是各修复的独立 diff，用来阅读，**不要**按顺序叠加。

## 2. 编译插件

```bash
cd plugin
xcrun clang -arch x86_64 -bundle -fobjc-arc -O1 -DNVMTL_RELEASE=1 \
  -Wno-protocol -Wno-incomplete-implementation \
  -I<Vulkan-Headers>/include \
  -o NVMTLDriver NVMTLDevice.m \
  -framework Foundation -framework Metal -framework IOSurface -framework IOKit -framework CoreVideo
codesign -f -s - -i com.nullmoth.NVMTLDriver NVMTLDriver   # 标识符要和安装器期望的一致
```
`Vulkan-Headers` 用 Khronos 的 `Vulkan-Headers`（`include/vulkan`）。**没有 `-DNVMTL_RELEASE=1` 的构建会写 `/tmp/nvmtl-*` 诊断文件，且保留环境变量旋钮**。
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
用 1.14.2 补丁集的插件时，再用 `mk-nomem-190.py` 去掉 `hw.memsize` 改写（修复 27，插件和 NVK 要一起换）。
H.264 解码提速（修复 14）：`mk-detile8.py`、`mk-sleep.py` 生成补丁版，`sudo zsh codec-vulkan/nvdec/nvdec-sleep.sh` 安装（带 `restore`），`decbench.swift` 测速并逐比特比对。

## 8. 守护（可选）

`nvguard/` 是作者的“**NullMoth 重装/更新后自动把补丁放回去**”的 LaunchDaemon：快照被登记的构建到 `/Library/NullMoth/guard`（`schg`），启动和被守护目录变化时若发现被替换成**已知的原版哈希**就恢复，**未知构建不动**。
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
| `hidpi/tests/*.sh` | 旋钮二分、WindowServer 重启、模式探测等脚本 |

测试未发布的翻译器：在同一目录放插件副本、指向 `air-runtime` 的软链和新的 `libnvmtl_translate.dylib`，再用 `plugshim` 运行。
