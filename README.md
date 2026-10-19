# macOS 上 NVIDIA 笔记本 RTX 4060（Ada）驱动补丁与修复集

[English](README.en.md)

在 **黑苹果（OpenCore）+ RTX 4060 笔记本独显直连** 上（macOS 15.8.1，现已升级到 **macOS 26.7.1**），把 [NullMoth NVIDIA 驱动](https://github.com/nullmoth/nvidia-macos-driver)
（作者现用 **v2.3.7** 的内核扩展 + **v2.0.4 加选择性合入 2.3.x** 的用户态）用起来的一整套补丁、脚本和排错记录：HiDPI、WindowServer 花屏/黑块/卡顿、Chrome/Steam/Electron 渲染错误、
远程控制与视频编解码、屏幕亮度、Wi-Fi/蓝牙、触控板、内置声卡，以及升级到 macOS 26 的全过程。

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

**作者本机现在的组合**：macOS **26.7.1**（从 15.8.1 升级，SMBIOS 仍是 iMacPro1,1）+ NullMoth **v2.3.7** 的内核扩展 + 以 **v2.0.4 为基线并选择性合入 2.3.x 改动** 的用户态 + 本仓库的 2.3.7 补丁集。
1.15.0 一套（`patches/nullmoth-1.15.0/`）仍可用，是 macOS 15 上最后支持的版本。旧组合（NullMoth v1.9.0 内核扩展 + v1.9.0 / v1.13.0 / v1.14.2 用户态补丁，macOS 15）的补丁仍保留在各自目录。

| 层 | 选哪个版本 | 说明 |
|---|---|---|
| 插件 NVMTLDriver、翻译器 | `patches/nullmoth-2.3.7/0001`、`0002`（**打在上游 v2.0.4 上**，当前）；`patches/nullmoth-1.15.0/0001`、`0002`（打在 v1.15.0 上，macOS 15）；旧的 `nullmoth-1.14.2/`、`nullmoth-1.13.0/`、`nullmoth-1.9.0/0001`、`0002` | 选一套，不要叠加。新版已去掉上游已吸收的部分；修复 26–29 在 1.14.2 及以后，29 的 VideoToolbox 回归修正、30、35 和 26 的跨进程同步在 1.15.0 版里；38–40 只在 2.3.7 版里 |
| 内核扩展 NVRM/NVAccel/NVRMFB | **2.3.7**（macOS 26）：NVRM 用 `kexts/patch-nvrm-237.py`，NVRMFB 用 `patches/nullmoth-2.3.7/0003`，NVAccel（26 版）/NVRMAGDC 原版，安装 `kexts/install-kexts-237.sh`；能睡眠（修复 37）。**1.15.0**：NVRM 用 `kexts/patch-nvrm-115.py`，NVRMFB 用 `patches/nullmoth-1.15.0/0003`，NVAccel/NVRMAGDC 原版；旧基线 1.9.0：`patches/nullmoth-1.9.0/0003–0006` | 1.15.0 自带背光和“光标只提交光标”（17 的 NVRMFB 部分、21）；二进制补丁逐字节断言，对不上会拒绝执行 |
| NVK（`libvulkan_nouveau`） | 1.15.0 原版即可；可选 `codec-vulkan/vulkan/vk-zcull.sh`（ZCULL，修复 36；2.0.4 / 2.0.5 用 `mk-zcull-204.py` / `mk-zcull-236.py`）；1.9.0 用 `codec-vulkan/vulkan/` | 5、27 的 NVK 部分上游已吸收 |
| NVDEC / NVENC 字节补丁 | 针对 1.9.0 的二进制（作者在 1.15.0 下仍用这些补丁版） | 脚本带断言，字节对不上会拒绝执行，不会乱写 |
| macOS 26 | `tahoe/` | 升级、救援、声卡、电源，见修复 32–34 |

**按你的机器挑修复**（编号见下表）：

| 你的情况 | 适用的修复 |
|---|---|
| 任何 NullMoth 支持的 NVIDIA 卡 + macOS 15 / 26（用户态，与机型无关） | 3、4、6、7、8、9、10、11、12、13、16、22、23、25、26（插件部分）、27、28、29、30、35、38、39、40 |
| 与驱动无关的 macOS 问题 | 20（CrossOver/Wine）、31（微信输入法） |
| 需要特定 NullMoth 版本的二进制（字节补丁/偏移量绑定版本） | 2、5（NVK 部分）、14、15、27（NVK 部分）、36（1.15.0 NVK） |
| 仅 Ada（RTX 40 系）：NVDEC/NVENC 的 t2d 布局 | 14、15 |
| 取决于你的面板和主板 | 1（HiDPI：面板 ID、刷新率）、17（亮度：DSDT 里的 `_DSM`/`_DOD` 路径） |
| 仅限同款硬件 | 18（Intel AX211）、19（ELAN0420 I²C 触控板）、24（ALC256 声卡，layout 因机型而异） |
| 升级到 macOS 26 | 32（iMacPro1,1 这类被淘汰的机型 + 打过补丁的驱动）、33（需要 AppleHDA 的声卡）、34（DSDT 的 `_PSR` 依赖 Windows 方法时） |
| 需要 2.3.7 内核 | 37（系统睡眠）、40（内核侧的标记） |
| 内核扩展，风险较高 | 21（光标独立提交，预防性；1.15.0 已自带）、26 的 NVRMFB 部分（新显存不再 CPU 清零） |

建议顺序：先装用户态（插件、翻译器）并稳定使用；再按需做字节补丁；最后才碰内核扩展；升级 macOS 26 之前先读第 32 项。机型相关的几项（1、17、18、19、33、34）要先对照自己的硬件，**不要整套照抄**。

## 修复一览

| # | 现象 | 根因（一句话） | 修复 | 位置 |
|---|------|---------------|------|------|
| 1 | 无法开 HiDPI；开了也进不去 165Hz | NVKMS 在独显上隐藏窗口缩放；head-scaler 的 IMP 在 165Hz 只接受 ≤1.4× 降采样 | NVRM 二进制 26 字节补丁（head scaler）+ 自定义 `DisplayProductID` 覆盖，得到 1792×1008 HiDPI @165Hz，零拷贝翻转 | `kexts/patch-nvrm-{190,115}.py`、`hidpi/overrides/` |
| 2 | 开机后 Dock 等窗口停止刷新，需重启进程 | 零拷贝翻转在启动 60 秒后才热切换 | NVRM 把 `IOSleep(60000)` 改 0，翻转在 WindowServer 首次提交前就绪 | `patches/…/0003`、`patch-nvrm-{190,115}.py` |
| 3 | 界面出现黑块、残影、窗口圆角变方 | WindowServer 往**线性**共享 IOSurface VRAM 渲染图层缓存结果出错 + 过期上传竞争 | 小于阈值的 IOSurface 用私有 tiled 图像（`NVMTL_SURF_SHARE_MINPX`）+ 纹理一致性补丁；后续修复之后作者已改回 `MINPX=0`（全部走共享显存），未再出现黑块 | `patches/…/0001`（`per-fix/stale-texture-fix`, `surface-guard-diag`） |
| 4 | WindowServer 占 75–90% CPU、掉帧 | 每次 IOSurface 内容变化做同步 CPU 拷贝+等 fence | 异步上传（GPU 直接读表面页面的导入默认关闭，会和 Chrome 竞争） | `per-fix/surfin-async.patch` |
| 5 | Chrome 变成软件合成 | ANGLE 在 NVIDIA 上禁用 Metal；GPU 沙箱拒绝 `/dev/null` 写入使 NVK 连接失败 | 环境变量 `ANGLE_FEATURE_OVERRIDES_DISABLED=disableMetalOnNvidia` + `libvulkan_nouveau.dylib` 2 字节补丁（`hw.memsize` 改写在 1.14.2 补丁集下由插件兜底取代，见 27；1.15.0 原版 NVK 已不需要补丁） | `codec-vulkan/vulkan/` |
| 6 | Chrome 满屏闪烁 | `waitUntilScheduled` / scheduled 回调在 GPU 完成前就返回，IOSurface 未发布 | scheduled 回调在完成时执行（`waitUntilScheduled` 的等待后来证明不需要，作者已关闭，见 26） | `per-fix/scheduled-wait.patch` |
| 7 | Chrome 窗口偶发整块空白一下 | ANGLE WebGL 着色器翻译失败（`air.get_num_samples` 需要 `raster_sample_count`），GPU 进程被重启 | 翻译器改为 SpecConstant + 插件下发 `VkSpecializationInfo` | `per-fix/raster-samples.patch` |
| 8 | 视频悬浮预览纯绿、窗口对角撕裂 | 插件从不持有 IOSurface use count，Chromium 回收了仍在被 GPU 使用的 buffer | 命令缓冲持有/释放 use count | `per-fix/surface-usecount.patch` |
| 9 | Graphite 渲染缺块 / 页面背景消失 | **翻译器**在新生成的返回结构体上丢掉了全部顶点输出（`rewrite_return`） | 回退到 `type_def_of` 查找 | `patches/…/0002` |
| 10 | Chrome 滚动慢（B 站） | 窗口级线性 RT 的每个 pass ≈1 ms | 线性 RT 的 tiled 渲染影子（每帧 GPU 13.6 → 3.2 ms） | `per-fix/tiled-render-shadow.patch` |
| 11 | Cmd-Tab/拖动时 WindowServer 超 165Hz 帧预算 | self-bind guard 每次采样前复制整个 28 MB 帧缓冲 | 对 `fixed_frag_*` 走“结束 pass→屏障→重启→自采样”，不拷贝（>6 ms 帧 536 → 6） | `per-fix/selfbind-fetch.patch` |
| 12 | Steam / CEF 界面闪烁、错位 | Apple GL-on-Metal 的 MSAA pass 设置了全零采样位置，插件无后端直接拒绝整个 pass | 无采样位置后端时回退到标准采样图案（1.14.2 版改用上游同类兜底） | `per-fix/gl-sample-positions.patch` |
| 13 | 截图缩略图 / 预览里大图变成一块块纯色 | **翻译器**：CI Lanczos 的 stitched AIR 中，调用方晚于接收指针参数的 helper 被发射，丢了常量偏移 | “调用者优先”的稳定拓扑重排（1.14.2 版由上游的同类修复取代） | `per-fix/translator-callers-first.patch` |
| 14 | 播放视频有 16px 竖条纹（App Store 等）；H.264 硬解慢、占 CPU | NVDEC H.264 以 Blackwell 的 detile mode 1 解，Ada 实为 t2d GOB（mode 0）；1.13 起插件找 `libnvdec_h264_t2d.dylib` 却从未安装；detile 每次拷 1 字节、等待时自旋 | 1 字节补丁；以 t2d 名安装；8 字节 detile（4K 26.8 → 12.6 ms/帧）+ 休眠等待（CPU 4K 8.0 → 3.7 ms/帧） | `codec-vulkan/nvdec/` |
| 15 | UU 远程被控端卡在“传输画面中”/ 花屏 / 慢 | NVENC：NotSync 标志、bw8/bw16 与 t2d 布局不符、清零 29 MB 显存走 BAR、无码率控制 | H.264 二进制补丁（t2d 循环、NotSync、AVX 清零、逐帧 QP 码控） | `codec-vulkan/nvenc/` |
| 16 | UU 作为控制端首帧闪退 | viewport 深度范围越界传给 NVK 触发 `assert(0<=zmin<=1)` | 夹紧 znear/zfar | `per-fix/viewport-depth-clamp.patch` |
| 17 | 亮度滑块 / Fn 亮度键 / 电池都没有 | NullMoth NVRM 把 `nv_acpi_dsm_method` / `_dod_method` 等桩掉，GSP 认不出面板 | `NVDSM`（Lilu 插件）补上 `_DSM`/`_DOD`/NVKMS 背光；`NVRMFB` 把面板标为内置并出 `AppleBacklightDisplay`（1.15.0 上游自带，NVDSM 自动让出背光注册）；重新启用真 EC0 | `backlight/`、`patches/nullmoth-1.9.0/0004` |
| 18 | 原生 Wi-Fi / 蓝牙 | 无 Sequoia 版 AirportItlwm；macOS 的 bluetoothd 对 AX211 发 LE 命令出错、`Connect` 要点三次 | AirportItlwm-Sequoia + `itlwm_he=1`，并打补丁修开机偶发不联网（固件 ALIVE 预算 15 s、3 次尝试、watchdog 自动重新初始化）；`BTLEFix`（Lilu）补丁 bluetoothd 并注入 Random Address / Inquiry Cancel；macOS 26 用 AirportItlwm 的 Tahoe 构建，BTLEFix 1.0.6 认 26 的 bluetoothd | `wifibt/`、`patches/itlwm/`、`tahoe/` |
| 19 | 触控板整个不动 | ELAN0420 在 I²C 上；VoodooI2C 发行版缺 `51e8` PCI ID，VoodooGPIO 的 TigerLakeLP 类未编译且 `start` 链错 | 三处修改 + `SSDT-PS2KEYS`（Fn+F1 宏、PrtSc） | `trackpad/`、`patches/voodoo/` |
| 20 | CrossOver/Wine 创建容器被 `EXC_GUARD` 杀 | `amfi_get_out_of_my_way` 使所有进程变“平台二进制”，task port 变不可移动 | boot-arg `ipc_control_port_options=0` | [docs/fixes.md](docs/fixes.md) |
| 21 | 光标移动时偶发闪回旧画面（预防性，本机未复现） | NVRMFB 光标提交顺带重提交主画面，与零拷贝翻转竞争 | 光标提交只带光标（移植上游 1.13.0；1.15.0 的 NVRMFB 已自带） | `patches/nullmoth-1.9.0/0005` |
| 22 | Memoji / SceneKit 角色网格碎裂 | SceneKit 蒙皮 kernel 用 compute `stage_in`，插件没实现，属性读不到 | 插件里用 MSL gather kernel 实现 compute stage_in（8/16/32 位格式、BGRA、常量步长） | `patches/nullmoth-1.13.0/per-fix/compute-stage-in.patch` |
| 23 | Photo Booth 预览纯黑（拍照正常）；compute / Core Image 往 CAMetalLayer 画不上 | `framebufferOnly=NO` 的 drawable 用途是 `Unknown(0)`，Apple 驱动当“全部用途”，插件当“没有”→ ShaderWrite 被拒 | 把 0 读作 ShaderRead、ShaderWrite、RenderTarget（`NVMTL_UNKNOWN_USAGE=0` 关闭） | `patches/nullmoth-1.13.0/per-fix/unknown-usage-all.patch`、`hidpi/catest/drawable-writes.swift` |
| 24 | 内置麦克风 / 扬声器不出现 | 没装 AppleALC；声卡是 ALC256（子系统 `1558:25E1`） | AppleALC + `alcid=11`，脚本改 ESP 的 `config.plist`（macOS 26 还要第 33 项） | `audio/` |
| 25 | Claude 桌面端终端面板没有文字（xterm.js WebGL）；`sampler2D u[N]` 数组的 WebGL 页面画不出 | **翻译器**不支持采样器数组、纹理数组只保住元素 0；**插件**描述符槽位掩码只标数组的第一个槽位 | 翻译器把数组降级为描述符数组并解析元素指针；插件按数组长度标全部槽位。⚠ 放进 GPUBundles 的 dylib 必须 ad-hoc 签名，否则 WindowServer 库验证拒绝 → 崩溃循环 | `patches/nullmoth-1.13.0/per-fix/sampler-array-{plugin,translator}.patch`、`hidpi/catest/sarray.m`、`hidpi/tests/lv-test.sh` |
| 26 | B 站 4K 视频开弹幕掉帧、视频丢帧（智能防挡更明显） | 每帧新建 12 MB 暂存缓冲；`waitUntilScheduled` 等到 GPU 完成；提交被上一帧的发布挡住；每帧新 IOSurface 的导入 + CPU 清零显存 | 暂存缓冲复用、提交即返回、提前提交、渲染影子复用、NVRMFB 抽样为零即不清（200 条弹幕 86–92 → 165 fps，丢帧 15% → 0）；“提交即返回”带来的跨进程读到上一帧由写入计数同步修复（1.15.0）。智能防挡让 WindowServer 上屏减半是 Chrome 的做法，见文档 | `patches/nullmoth-1.14.2/per-fix/`、`patches/nullmoth-{1.9.0/0006,1.15.0/0003}`、`hidpi/catest/danmaku/` |
| 27 | Firefox 没有硬件加速 | Firefox 的 GPU 沙箱连读 `/dev/null` 都拒绝，`hw.pagesize` 也被拒 | 回移植上游 1.14.5/1.14.6：管道当占位 fd、`host_info` 取内存大小；NVK 去掉 `hw.memsize` 改写（两者一起换） | `per-fix/upstream-sandbox-unity-backport.patch`、`codec-vulkan/vulkan/mk-nomem-190.py`、`hidpi/catest/ffsandbox.m` |
| 28 | Unity 类程序偶发卡死 | 程序在 `@synchronized(命令缓冲/队列)` 里提交并等待，插件完成时要拿同一把锁 | 回移植上游 1.14.5：插件改用自己的类级锁 | 同上、`hidpi/catest/unitylock.m` |
| 29 | WebGL 大量绘制（Aquarium）帧率低 | 每次 draw 新建描述符集；发行版仍在求值跟踪参数；采样纹理的片元着色器缓冲走描述符 | 只变字节环时复用描述符集（动态偏移地址表）；跟踪参数按需求值；**翻译器**把剩余缓冲并到地址表（3.13 → 1.56 µs/draw，5000 条鱼 41 → 73 fps）。复用曾让 VideoToolbox 两遍缩放输出空白（照片/预览缩略图），1.15.0 版已修 | `per-fix/{nvtrace-release,descriptor-table-reuse,translator-table-merge}.patch`、`nullmoth-1.15.0/per-fix/vt-storage-descriptor-reuse.patch`、`hidpi/catest/drawbench.m` |
| 30 | Dock 角标数字只有放大 Dock 时才看得见 | Core Animation 用 `newTiledTextureWithBytesNoCopy` 建带 mipmap 的纹理，缓冲里只有第 0 级、其余要驱动生成，插件没生成 → 缩小后数字淡没 | 上传及每次重新上传后生成整条 mip 链 | `patches/nullmoth-1.15.0/per-fix/tiled-mips.patch`、`hidpi/catest/tiledmips.m` |
| 31 | 微信输入法开机后在自启应用（Claude、Steam…）里打不了字 | 这些应用在 WeType 登记前向 `imklaunchagent` 要端点，拿到“无端点”后一直缓存 | 登录时用 LaunchAgent `open -g` 先启动 WeType（不能 `-j`，否则候选窗口不显示） | `tools/wetype/` |
| 32 | 升级到 macOS 26：iMacPro1,1 被淘汰、打过补丁的驱动、升级失败怎么救 | 26 拒绝 iMacPro1,1；安装器阶段驱动不能在；NullMoth 要换 26 版 NVAccel；ESP 盘号偶尔会变 | 保留 iMacPro1,1 + RestrictEvents + `-no_compat_check revpatch=sbvmm`；升级前停放驱动、首次进 26 自动换 NVAccel 并重建内核集合；ESP 上的救援配置 + Limine 里的恢复模式入口；脚本按分区 UUID 找 ESP | `tahoe/` |
| 33 | macOS 26 没有内置扬声器/麦克风 | 26 删了 AppleHDA；放回后 `kernelmanagerd` 又不应答它的资源请求，驱动永远等着 | 15.7.9 KDK 的 AppleHDA 放进 `/Library/Apple/System/Library/Extensions` + `kmutil -b`；BTLEFix 1.0.6 代答 `OSKextRequestResource` | `tahoe/audio/`、`wifibt/BTLEFix/` |
| 34 | macOS 26 插着电源却显示电池供电，FileVault 转换一直“已暂停” | DSDT 的 `AC._PSR` 依赖 Windows 方法，在 macOS 下求值失败；APFS 在电池供电时暂停加密转换 | `SSDT-ACPSR` 提供自己的 `_PSR`（返回 `ACFG`）+ ACPI 改名 `_PSR → XPSR` | `tahoe/power/` |
| 35 | three.js 带阴影的 WebGL 页面打不开（context lost，GPU 进程反复重启） | 阴影贴图是单元素采样器数组 `sampler2D shadowMap[1]`，翻译器只把 2 个及以上的当数组，长度 1 的采样器指针丢失 | 翻译器把 `array<sampler, 1>` 也按采样器数组绑定 | `patches/nullmoth-1.15.0/per-fix/sampler1-threejs-shadow.patch`、`hidpi/catest/sarray1.m` |
| 36 | WebGL 3D 页面（three.js 象棋）GPU 慢 | ANGLE 的 MSAA 着色器都写 `sample_mask` → 没有提前深度测试；NullMoth 的 NVRM 后端把 NVK 的 ZCULL 关死了 | NVK 二进制补丁：从 RM 取 ZCULL 信息并打开（象棋整帧 GPU 11.6 → 7.2 ms） | `codec-vulkan/vulkan/{mk-zcull-115.py,vk-zcull.sh}`、`hidpi/catest/{earlyz,rtcheck}.m` |
| 37 | 合盖/苹果菜单睡眠后屏幕不亮（旧内核） | 1.15.0 及以前的 NVRM 没有 GPU 挂起/恢复；2.3.7 有，但 `-nvrmnopm` 把它关了 | 去掉 `-nvrmnopm`，`sleepguard` 只在 GPU 能恢复时允许睡眠；带定时唤醒的单次测试脚本（RM standby 6.1 s、恢复 4.5 s、显存保留） | `kexts/sleep/`、`sleepguard/` |
| 38 | 系统窗口/图标渲染慢；CA 退回通用路径；图标字形全黑（中间版本） | Core Animation 的 uber shader 函数常量结构体读取从不折叠，每个“特化”变体都是整个 684 KB（~3.3 s）；`[[visible]]` 引用的报错措辞不对导致 RenderBox 全 nil | **翻译器**折叠这些聚合字段读取（3.3 → ~0.5 s）；固定的 “visible function reference” 措辞 | `patches/nullmoth-2.3.7/0002`、`hidpi/catest/fcbench/`、`iconfc.m` |
| 39 | Apple OpenGL 程序挂住 / 窗口 GL 丢帧 / 整数纹理读成浮点 | use count 只从 encode 持有；垂直同步只等到 vblank，不等 WindowServer 取走上一帧；反射把所有纹理当 Float | use count 持有到完成；等到窗口服务器取走；按 `texture_shape` 反射 Int/UInt | `patches/nullmoth-2.3.7/0001`、`hidpi/catest/gl236/` |
| 40 | 截图黑、Dock 缩略图空白、锁屏黑 | WindowServer 的合成还在 GPU 上跑，抓屏去锁表面读到旧帧 | 插件在 commit 标 pending、写完标 ready，共享显存标最新（配 2.3.7 内核 NVAccel） | `patches/nullmoth-2.3.7/0001`、`hidpi/catest/wsmark.m` |

每一项的详细分析、验证方法和注意事项见 **[docs/fixes.md](docs/fixes.md)**。

## 目录

```
patches/nullmoth-1.9.0/   对上游 v1.9.0 的累计补丁（plugin / translator / NVRM / NVRMFB）
patches/nullmoth-1.13.0/  重新整理到上游 v1.13.0 之上的插件 / 翻译器补丁（内核扩展仍以 1.9.0 为基线）
patches/nullmoth-1.14.2/  重新整理到上游 v1.14.2 之上的插件 / 翻译器补丁（含修复 26–29）
patches/nullmoth-1.15.0/  重新整理到上游 v1.15.0 之上的插件 / 翻译器 / NVRMFB 补丁（含修复 26–30、35）
  per-fix/                逐项修复的独立 diff（便于阅读，各自以当时的基线生成，不保证按序可叠加）
patches/nullmoth-2.3.7/   打在上游 v2.0.4（0001 插件、0002 翻译器）/ v2.3.7（0003 NVRMFB）上的补丁（当前，含修复 38–40）
patches/voodoo/           VoodooGPIO 补丁
patches/itlwm/            laobamac/itlwm（AirportItlwm）开机初始化自愈补丁
kexts/                    NVRM 二进制补丁脚本（head-scaler）、1.9.0 / 1.15.0 / 2.3.7 内核扩展的编译、安装、回滚；sleep/：2.3.7 的系统睡眠（修复 37）
hidpi/                    HiDPI 显示覆盖、插件/翻译器热替换脚本、测试程序源码（catest/）、诊断小工具
  legacy-1.0.10/          基于 NullMoth 1.0.10 的旧安装脚本（已被 1.9.0 路线取代，仅供参考）
codec-vulkan/             NVDEC / NVENC / libvulkan_nouveau 的二进制补丁与测试（1.15.0 NVK 的 ZCULL：vulkan/vk-zcull.sh）
backlight/                NVDSM（Lilu 插件）、亮度/EC/ACPI 脚本、救援脚本
wifibt/                   AirportItlwm / BTLEFix / BT 产品名注入 / OpenCore boot-arg 脚本
trackpad/                 VoodooI2C + PS2 按键映射
audio/                    内置声卡（AppleALC + alcid）安装/回滚脚本
tahoe/                    macOS 26：升级（prepare/finish）、ESP 救援配置、恢复模式入口、AppleHDA（audio/）、AC 电源 SSDT（power/）
nvguard/                  “驱动被重装后自动把补丁放回去”的 LaunchDaemon（参考实现）
sleepguard/               “系统睡眠只在 GPU 能恢复时才允许”的 LaunchDaemon
efiguard/                 “ESP 上的修复被丢了就自动补回”的 LaunchDaemon（可在 ESP 副本上演练）
tools/                    备份、NVRM 运行时旋钮、开机 Wi-Fi 日志抓取（wifi-bootlog）、USB 掉线记录（usb-watch）、微信输入法开机预启动（wetype）
docs/                     详细文档
```

## 快速上手

1. 读 [docs/applying.md](docs/applying.md)：怎么拿到上游源码、打补丁、编译插件/翻译器、替换到系统。
2. 凡涉及 OpenCore ESP 的脚本，先导出你那块 ESP 的**分区 UUID**（脚本会拒绝在未设置时运行）：
   ```bash
   export ESP_UUID=$(diskutil info disk1s4 | awk -F': *' '/Partition UUID/{print $2}')   # disk1s4 换成你现在的 ESP（diskutil list）
   ```
   脚本每次运行时按这个 UUID 自己找盘，不用盘号：机器上有两块 NVMe 时，谁先被识别出来不固定，ESP 的盘号偶尔会变（作者 20 次开机里有 1 次从 `disk1s4` 变成 `disk0s4`）。用 `sudo -E` 把变量带进去。
3. 先在 `--check` / 备份模式下运行，确认再安装。

## 许可证

- 对 NullMoth 插件/内核扩展的补丁：随上游 **PolyForm Noncommercial 1.0.0**（仅限非商业用途），见 [LICENSE-PolyForm-Noncommercial-1.0.0.txt](LICENSE-PolyForm-Noncommercial-1.0.0.txt)。
- 对翻译器（metal2vulkan 衍生）的补丁：**LGPL-3.0-or-later**，见 [LICENSE-LGPL-3.0.txt](LICENSE-LGPL-3.0.txt)。
- 对 VoodooGPIO / VoodooI2C 的补丁：沿用其上游许可（GPL-3.0 / BSD 类）。
- Lilu 插件源码（`backlight/NVDSM`、`wifibt/BTLEFix`）：因依赖 Lilu，按 **GPL-3.0** 提供，见 [LICENSE](LICENSE)。
- 本仓库作者原创的其余脚本、测试、文档：**GPL-3.0**，见 [LICENSE](LICENSE)。

详见 [NOTICE.md](NOTICE.md)。本项目与 NullMoth Systems、NVIDIA、Apple 无任何关联。
