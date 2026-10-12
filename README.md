# macOS 上 NVIDIA 笔记本 RTX 4060（Ada）驱动补丁与修复集

[English](README.en.md)

在 **黑苹果（OpenCore）+ macOS 15.8.1 + RTX 4060 笔记本独显直连** 上，把 [NullMoth NVIDIA 驱动](https://github.com/nullmoth/nvidia-macos-driver)
（v1.9.0）用起来的一整套补丁、脚本和排错记录：HiDPI、WindowServer 花屏/黑块/卡顿、Chrome/Steam/Electron 渲染错误、
远程控制与视频编解码、屏幕亮度、Wi-Fi/蓝牙、触控板、内置声卡等。

> **这是什么 / 不是什么**
> - 是：对上游驱动**源码**的补丁（diff）、对已安装二进制的**字节补丁脚本**、内核扩展的小补丁、安装/回滚/守护脚本，以及每个问题的根因分析。
> - 不是：驱动本身。**本仓库不含任何 NullMoth / NVIDIA 二进制、固件或你机器的 EFI/config.plist**，请自行从上游获取驱动。
> - 参考机型：蓝天（Clevo）模具，i7-13620H，RTX 4060 Laptop（独显直连、无核显），BOE 0B40 面板（2560×1440@165Hz），
>   Intel AX211 Wi-Fi/BT，ELAN0420 I²C 触控板。别的机器**不能直接照抄**，见 [docs/applying.md](docs/applying.md)。

## ⚠️ 风险提示

这些东西会改内核扩展、系统 GPU 插件、OpenCore 的 `config.plist` 和 ACPI。作者踩过的坑包括：内核 panic、进不了桌面、
Wine/CrossOver 被系统直接杀掉。**先备份 EFI、保留一个可用的安全启动项，再动手**；所有安装脚本默认都会先备份并带回滚。
按“原样”提供，不作任何保证。详见 [docs/pitfalls.md](docs/pitfalls.md)。

## 版本与适用范围

**已验证的组合**：NullMoth **v1.9.0** 的内核扩展与二进制 + 本仓库的补丁；其中插件和翻译器可选 v1.9.0 版或 v1.13.0 版补丁集（作者本机用的是后者）。

| 层 | 选哪个版本 | 说明 |
|---|---|---|
| 插件 NVMTLDriver、翻译器 | `patches/nullmoth-1.13.0/`（推荐）或 `patches/nullmoth-1.9.0/0001`、`0002` | 两套二选一，不要叠加。1.13.0 版已去掉上游已吸收的部分 |
| 内核扩展 NVRM/NVAccel/NVRMFB | 以 **1.9.0** 为基线（`patches/nullmoth-1.9.0/0003–0005`） | 1.9.0→1.13.0 期间 NVRM 核心源码没有变化，但二进制补丁的偏移量仍需你对着自己的包核对 |
| NVK / NVDEC / NVENC 字节补丁 | 针对 1.9.0 的二进制 | 脚本带断言，字节对不上会拒绝执行，不会乱写 |

**按你的机器挑修复**（编号见下表）：

| 你的情况 | 适用的修复 |
|---|---|
| 任何 NullMoth 支持的 NVIDIA 卡 + macOS 15（用户态，与机型无关） | 3、4、6、7、8、9、10、11、12、13、16、20、22、23 |
| 需要特定 NullMoth 版本的二进制（字节补丁/偏移量绑定版本） | 2、5（NVK 部分）、14、15 |
| 仅 Ada（RTX 40 系）：NVDEC/NVENC 的 t2d 布局 | 14、15 |
| 取决于你的面板和主板 | 1（HiDPI：面板 ID、刷新率）、17（亮度：DSDT 里的 `_DSM`/`_DOD` 路径） |
| 仅限同款硬件 | 18（Intel AX211）、19（ELAN0420 I²C 触控板）、24（ALC256 声卡，layout 因机型而异） |
| 内核扩展，预防性、风险较高 | 21（光标独立提交） |

建议顺序：先装用户态（插件、翻译器）并稳定使用；再按需做字节补丁；最后才碰内核扩展。机型相关的几项（1、17、18、19）要先对照自己的硬件，**不要整套照抄**。

## 修复一览

| # | 现象 | 根因（一句话） | 修复 | 位置 |
|---|------|---------------|------|------|
| 1 | 无法开 HiDPI；开了也进不去 165Hz | NVKMS 在独显上隐藏窗口缩放；head-scaler 的 IMP 在 165Hz 只接受 ≤1.4× 降采样 | NVRM 二进制 26 字节补丁（head scaler）+ 自定义 `DisplayProductID` 覆盖，得到 1792×1008 HiDPI @165Hz，零拷贝翻转 | `kexts/patch-nvrm-190.py`、`hidpi/overrides/` |
| 2 | 开机后 Dock 等窗口停止刷新，需重启进程 | 零拷贝翻转在启动 60 秒后才热切换 | NVRM 把 `IOSleep(60000)` 改 0，翻转在 WindowServer 首次提交前就绪 | `patches/…/0003`、`patch-nvrm-190.py` |
| 3 | 界面出现黑块、残影、窗口圆角变方 | WindowServer 往**线性**共享 IOSurface VRAM 渲染图层缓存结果出错 + 过期上传竞争 | 小于阈值的 IOSurface 用私有 tiled 图像（`NVMTL_SURF_SHARE_MINPX`）；纹理一致性补丁 | `patches/…/0001`（`per-fix/stale-texture-fix`, `surface-guard-diag`） |
| 4 | WindowServer 占 75–90% CPU、掉帧 | 每次 IOSurface 内容变化做同步 CPU 拷贝+等 fence | 异步上传 + 主机指针导入 | `per-fix/surfin-async.patch` |
| 5 | Chrome 变成软件合成 | ANGLE 在 NVIDIA 上禁用 Metal；GPU 沙箱拒绝 `/dev/null` 写入使 NVK 连接失败 | 环境变量 `ANGLE_FEATURE_OVERRIDES_DISABLED=disableMetalOnNvidia` + `libvulkan_nouveau.dylib` 2 字节补丁 + `hw.memsize` 改写 | `codec-vulkan/vulkan/` |
| 6 | Chrome 满屏闪烁 | `waitUntilScheduled` / scheduled 回调在 GPU 完成前就返回，IOSurface 未发布 | 等到完成再回调 | `per-fix/scheduled-wait.patch` |
| 7 | Chrome 窗口偶发整块空白一下 | ANGLE WebGL 着色器翻译失败（`air.get_num_samples` 需要 `raster_sample_count`），GPU 进程被重启 | 翻译器改为 SpecConstant + 插件下发 `VkSpecializationInfo` | `per-fix/raster-samples.patch` |
| 8 | 视频悬浮预览纯绿、窗口对角撕裂 | 插件从不持有 IOSurface use count，Chromium 回收了仍在被 GPU 使用的 buffer | 命令缓冲持有/释放 use count | `per-fix/surface-usecount.patch` |
| 9 | Graphite 渲染缺块 / 页面背景消失 | **翻译器**在新生成的返回结构体上丢掉了全部顶点输出（`rewrite_return`） | 回退到 `type_def_of` 查找 | `patches/…/0002` |
| 10 | Chrome 滚动慢（B 站） | 窗口级线性 RT 的每个 pass ≈1 ms | 线性 RT 的 tiled 渲染影子（每帧 GPU 13.6 → 3.2 ms） | `per-fix/tiled-render-shadow.patch` |
| 11 | Cmd-Tab/拖动时 WindowServer 超 165Hz 帧预算 | self-bind guard 每次采样前复制整个 28 MB 帧缓冲 | 对 `fixed_frag_*` 走“结束 pass→屏障→重启→自采样”，不拷贝（>6 ms 帧 536 → 6） | `per-fix/selfbind-fetch.patch` |
| 12 | Steam / CEF 界面闪烁、错位 | Apple GL-on-Metal 的 MSAA pass 设置了全零采样位置，插件无后端直接拒绝整个 pass | 无采样位置后端时回退到标准采样图案 | `per-fix/gl-sample-positions.patch` |
| 13 | 截图缩略图 / 预览里大图变成一块块纯色 | **翻译器**：CI Lanczos 的 stitched AIR 中，调用方晚于接收指针参数的 helper 被发射，丢了常量偏移 | “调用者优先”的稳定拓扑重排 | `per-fix/translator-callers-first.patch` |
| 14 | 播放视频有 16px 竖条纹（App Store 等） | NVDEC H.264 以 Blackwell 的 detile mode 1 解，Ada 实为 t2d GOB（mode 0） | `libnvdec_h264.dylib` 1 字节补丁 | `codec-vulkan/nvdec/` |
| 15 | UU 远程被控端卡在“传输画面中”/ 花屏 / 慢 | NVENC：NotSync 标志、bw8/bw16 与 t2d 布局不符、清零 29 MB 显存走 BAR、无码率控制 | H.264 二进制补丁（t2d 循环、NotSync、AVX 清零、逐帧 QP 码控） | `codec-vulkan/nvenc/` |
| 16 | UU 作为控制端首帧闪退 | viewport 深度范围越界传给 NVK 触发 `assert(0<=zmin<=1)` | 夹紧 znear/zfar | `per-fix/viewport-depth-clamp.patch` |
| 17 | 亮度滑块 / Fn 亮度键 / 电池都没有 | NullMoth NVRM 把 `nv_acpi_dsm_method` / `_dod_method` 等桩掉，GSP 认不出面板 | `NVDSM`（Lilu 插件）补上 `_DSM`/`_DOD`/NVKMS 背光；`NVRMFB` 把面板标为内置并出 `AppleBacklightDisplay`；重新启用真 EC0 | `backlight/`、`patches/…/0004` |
| 18 | 原生 Wi-Fi / 蓝牙 | 无 Sequoia 版 AirportItlwm；macOS 的 bluetoothd 对 AX211 发 LE 命令出错、`Connect` 要点三次 | AirportItlwm-Sequoia + `itlwm_he=1`；`BTLEFix`（Lilu）补丁 bluetoothd 并注入 Random Address / Inquiry Cancel | `wifibt/` |
| 19 | 触控板整个不动 | ELAN0420 在 I²C 上；VoodooI2C 发行版缺 `51e8` PCI ID，VoodooGPIO 的 TigerLakeLP 类未编译且 `start` 链错 | 三处修改 + `SSDT-PS2KEYS`（Fn+F1 宏、PrtSc） | `trackpad/`、`patches/voodoo/` |
| 20 | CrossOver/Wine 创建容器被 `EXC_GUARD` 杀 | `amfi_get_out_of_my_way` 使所有进程变“平台二进制”，task port 变不可移动 | boot-arg `ipc_control_port_options=0` | [docs/fixes.md](docs/fixes.md) |
| 21 | 光标移动时偶发闪回旧画面（预防性，本机未复现） | NVRMFB 光标提交顺带重提交主画面，与零拷贝翻转竞争 | 光标提交只带光标（移植上游 1.13.0） | `patches/…/0005` |
| 22 | Memoji / SceneKit 角色网格碎裂 | SceneKit 蒙皮 kernel 用 compute `stage_in`，插件没实现，属性读不到 | 插件里用 MSL gather kernel 实现 compute stage_in（8/16/32 位格式、BGRA、常量步长） | `patches/nullmoth-1.13.0/per-fix/compute-stage-in.patch` |
| 23 | Photo Booth 预览纯黑（拍照正常）；compute / Core Image 往 CAMetalLayer 画不上 | `framebufferOnly=NO` 的 drawable 用途是 `Unknown(0)`，Apple 驱动当“全部用途”，插件当“没有”→ ShaderWrite 被拒 | 把 0 读作 ShaderRead、ShaderWrite、RenderTarget（`NVMTL_UNKNOWN_USAGE=0` 关闭） | `patches/nullmoth-1.13.0/per-fix/unknown-usage-all.patch`、`hidpi/catest/drawable-writes.swift` |
| 24 | 内置麦克风 / 扬声器不出现 | 没装 AppleALC；声卡是 ALC256（子系统 `1558:25E1`） | AppleALC + `alcid=11`，脚本改 ESP 的 `config.plist` | `audio/` |

每一项的详细分析、验证方法和注意事项见 **[docs/fixes.md](docs/fixes.md)**。

## 目录

```
patches/nullmoth-1.9.0/   对上游 v1.9.0 的累计补丁（plugin / translator / NVRM / NVRMFB）
patches/nullmoth-1.13.0/  重新整理到上游 v1.13.0 之上的插件 / 翻译器补丁（内核扩展仍以 1.9.0 为基线）
  per-fix/                逐项修复的独立 diff（便于阅读，各自以当时的基线生成，不保证按序可叠加）
patches/voodoo/           VoodooGPIO 补丁
kexts/                    NVRM 二进制补丁脚本（head-scaler + 启动即翻转）、1.9.0 内核扩展安装/回滚
hidpi/                    HiDPI 显示覆盖、插件/翻译器热替换脚本、测试程序源码（catest/）、诊断小工具
  legacy-1.0.10/          基于 NullMoth 1.0.10 的旧安装脚本（已被 1.9.0 路线取代，仅供参考）
codec-vulkan/             NVDEC / NVENC / libvulkan_nouveau 的二进制补丁与测试
backlight/                NVDSM（Lilu 插件）、亮度/EC/ACPI 脚本、救援脚本
wifibt/                   AirportItlwm / BTLEFix / BT 产品名注入 / OpenCore boot-arg 脚本
trackpad/                 VoodooI2C + PS2 按键映射
audio/                    内置声卡（AppleALC + alcid）安装/回滚脚本
nvguard/                  “驱动被重装后自动把补丁放回去”的 LaunchDaemon（参考实现）
efiguard/                 “ESP 上的修复被丢了就自动补回”的 LaunchDaemon（可在 ESP 副本上演练）
tools/                    备份、NVRM 运行时旋钮
docs/                     详细文档
```

## 快速上手

1. 读 [docs/applying.md](docs/applying.md)：怎么拿到上游源码、打补丁、编译插件/翻译器、替换到系统。
2. 凡涉及 OpenCore ESP 的脚本，先导出你自己的分区信息（脚本会拒绝在未设置时运行）：
   ```bash
   export ESP_DEV=disk1s4                                   # 你的 ESP，diskutil list 查看
   export ESP_UUID=$(diskutil info $ESP_DEV | awk -F': *' '/Partition UUID/{print $2}')
   ```
3. 先在 `--check` / 备份模式下运行，确认再安装。

## 许可证

- 对 NullMoth 插件/内核扩展的补丁：随上游 **PolyForm Noncommercial 1.0.0**（仅限非商业用途），见 [LICENSE-PolyForm-Noncommercial-1.0.0.txt](LICENSE-PolyForm-Noncommercial-1.0.0.txt)。
- 对翻译器（metal2vulkan 衍生）的补丁：**LGPL-3.0-or-later**，见 [LICENSE-LGPL-3.0.txt](LICENSE-LGPL-3.0.txt)。
- 对 VoodooGPIO / VoodooI2C 的补丁：沿用其上游许可（GPL-3.0 / BSD 类）。
- Lilu 插件源码（`backlight/NVDSM`、`wifibt/BTLEFix`）：因依赖 Lilu，按 **GPL-3.0** 提供，见 [LICENSE](LICENSE)。
- 本仓库作者原创的其余脚本、测试、文档：**GPL-3.0**，见 [LICENSE](LICENSE)。

详见 [NOTICE.md](NOTICE.md)。本项目与 NullMoth Systems、NVIDIA、Apple 无任何关联。
