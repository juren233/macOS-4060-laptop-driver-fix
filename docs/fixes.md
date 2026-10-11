# 修复详解

编号与 [README](../README.md) 的表格一致。除特别说明外，环境为 macOS 15.8.1、NullMoth v1.9.0、RTX 4060 Laptop（Ada）。
“插件”= `/Library/GPUBundles/NVMTLDriver.bundle`（Metal 驱动），“翻译器”= 其中的 `libnvmtl_translate.dylib`（Apple AIR → SPIR-V），
“NVK”= `libvulkan_nouveau.dylib`。

> 重要：发行版插件会在构造函数里 `unsetenv()` 所有 `NVMTL_/NVK_/NAK_/NVRM_` 环境变量，**旋钮只能写在
> `/Library/GPUBundles/nvmtl/nvrm610.conf`**（`tools/nvknob.sh` 可读写）。

---

## 一、显示：HiDPI 与翻转

### 1. HiDPI（head scaler）
- **死路**：窗口级（precomp）缩放在独显上被 NVKMS 隐藏；强行打开 caps 会出 Xid 56 `INVALID_STATE` 并整卡挂死。
- **做法**：让**显示头（postcomp）**缩放。NVRM 二进制 26 字节补丁：`viewPortSizeIn` 取图层源尺寸，`sizeOut` 取源尺寸（`0x56/0x58 → 0x4e/0x50`）。
  1.9.0 的偏移见 `kexts/patch-nvrm-190.py`（每个字节都先断言再写，可重复运行）。
- **165Hz 上限**：2560×1440@165 时 IMP 接受 ≤1.4× 降采样（looks like **1792×1008**，backing 3584×2016），1.425×（1824×1026）起被拒绝。
  更低刷新率能用更大的 looks-like（如 40Hz 的 1920×1080）。
- `hidpi/overrides/DisplayProductID-b40.final` 是 BOE 0B40 的 HiDPI 列表（`scale-resolutions` 为大端 `宽,高,flags` 的 base64），
  安装到 `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-9e5/DisplayProductID-b40`。**你的面板 VendorID/ProductID 不同，需要改文件名和内容**。
  新增的 HiDPI 项**必须完整重启**才出现（只重启 WindowServer 不行）。
- 工具：`hidpi/tools/listmodes.swift`（列出所有 CG 模式）、`setmode.swift`、`modetest.swift`、`hsprobe.c`。

### 2. 启动即零拷贝翻转
- NullMoth 的 `autoGo` 在释放 boot-hold **之后**还 `IOSleep(60000)` 才打开 `debug.nvaccel_iop_flip=1`，于是登录后、窗口已显示时才**热切换**扫描路径，
  已被拷贝路径扫描出去的表面（Dock）停止呈现，直到进程重启。
- `IOSleep(60000)` → `IOSleep(0)`（源码补丁 `0003`，二进制补丁在 `patch-nvrm-190.py` 末尾）。
- 运行时关闭翻转是安全的（`sysctl debug.nvaccel_iop_flip=0`），**运行时再打开不安全**（Dock 会坏），需要重启。
- 旧方案 `hidpi/legacy-1.0.10/nvflip/`（LaunchDaemon 延迟 60 秒再开）已被取代。

---

## 二、WindowServer / 插件（NVMTLDriver）

补丁在 `patches/nullmoth-1.9.0/0001-plugin.patch`（累计），逐项独立 diff 在 `per-fix/`。

### 3. 黑块 / 残影 / 圆角变方
排查走了很长的路，结论按层记录：
1. `newTiledTextureWithDescriptor` 在 pitch/offset 非 32B 对齐时退化为一次性拷贝，CA 之后写 buffer 纹理却不更新 → 过期内容；
   `newBufferWithBytesNoCopy` 在宿主指针导入被拒时同理（`stale-texture-fix.patch`）。**单独修这两处并不能治好 Finder 侧栏。**
2. 真正根因：WindowServer 把小图层缓存渲染进**线性共享 IOSurface VRAM**，结果出错（具体哪个操作未查明）；另有“纹理创建与 GPU 写入的发布顺序”竞争。
3. 修复：旋钮 `NVMTL_SURF_SHARE_MINPX`（默认 0，推荐 `3686400`）——像素数低于阈值的 IOSurface 用**私有 tiled 图像**；同一进程里同一私有 IOSurface 的所有纹理共享同一根图像；
   `surfaceOut` 在写 tag 之后才标记已发布。帧缓冲必须保持共享（扫描输出需要）。
4. 后续：窗口尺寸 ≥ 阈值的共享表面若被自己的 pass 采样（defocus），做快照（`surface-guard-diag.patch` / `private-guard.patch`）。
- 验证：`hidpi/catest/surftex.m`（6 种时序）、`hostcopy.m`、`tiledtex.m`、`lintarget.m`；窗口截图（`app_screenshot` 类工具）能复现该问题，可作判据。
- ⚠ 教训：只看窗口截图正确不代表屏幕正确——曾出现“窗口捕获正常但物理屏幕全黑”。要让人看实际屏幕。

### 4. WindowServer 高 CPU / 掉帧（异步 surface-in）
- `spindump WindowServer 10`：主线程 61% 在 `nvmtlSurfaceIn → nvmtl_vk_image_write`（CPU memmove + 缺页），11% 同步 `vkWaitForFences`。
  原因是第 3 项把所有小表面和每个 NV12 视频帧变成私有图像，每次 seed 变化都整块 CPU 拷贝并等 GPU。
- 修复 `surfin-async.patch`：上传不等待、按队列顺序提交；用 `vkGetFenceStatus` + 16ms 定时器回收，最多 48 个在途；重复上传直接导入 IOSurface 主机指针（预算 `NVMTL_SURFIN_IMPORT_MB`，默认 256）。
  只对私有图像异步；共享 VRAM 上的上传仍同步（VRAM tag 表示数据已就绪）。关闭开关：`NVMTL_SURFIN_ASYNC=0`。
- 测试：`hidpi/catest/surfasync.m`。

### 6. 闪烁（scheduled 回调时机）
- Chromium 在提交 CA 事务前调用 `waitUntilScheduled`；WindowServer 的 NVK 通道与 Chrome 的无序，私有图像表面只在**完成**时发布。
- `waitUntilScheduled` 改为等到完成（`NVMTL_SCHEDULED_WAIT=0` 恢复）；`addScheduledHandler` 回调也改在完成时执行（`NVMTL_SCHED_AT_COMPLETION=0` 恢复）。后者治好了 Electron（大窗口 2432×1600 IOSurface）的交替旧帧。

### 8. IOSurface use count
- Apple 驱动在 GPU 工作引用 surface 期间保持 `IOSurfaceIsInUse` 为真，Chromium 的 buffer queue / CVPixelBufferPool 据此回收。插件从不持有 → 视频预览（HEVC 640×360 经 VideoToolbox）纯绿、窗口对角撕裂（新旧帧混合）。
- 命令缓冲持有的 `nvmtl_resref` 在 0→1 加 use count，→0 减；每纹理 `_useLk/_useHeld`。旋钮 `NVMTL_SURF_USECOUNT=0`。测试 `catest/usecount.m`（原版 FAIL，新版 PASS）。

### 10. 线性 RT 的 tiled 渲染影子（Chrome 滚动）
- 窗口 IOSurface ≥ `MINPX` 时是 pitch-linear 的共享 VRAM 别名，一帧约 11 个 Graphite pass、每个约 1 ms，且与 backdrop 模糊链交错。
- 渲染编码器的颜色附件若是整张单采样 vramOn 表面，改画到私有 tiled 影子；`endEncoding` 时影子标为 *pending* 而不是立即拷回；之后的采样/blit 源读影子，其它用途（blit 目标、compute、signalEvent、commit…）先拷回。
- 旋钮 `NVMTL_TILED_RT`：0 关；1 仅应用（默认，WindowServer 不动）；2 所有进程。
- 结果（B 站滚动，每帧 GPU）：13.6 ms → 8.8 → 8.2 → **3.2 ms**。WindowServer 实测（中位 GPU 22 µs）上加影子**不划算**，故默认不启用。
- 测试：`catest/rshtest.m`（13 个用例对照私有纹理）、`lintbench.m`、`plugshim.m`（见 [applying.md](applying.md#测试)）。

### 11. self-bind guard 去拷贝（selffetch）
- WindowServer 的 CA uber shader（`fixed_vert_lpf_spc` / `fixed_frag_lpf_cpf`）用 `attachment_0` 做帧缓冲 fetch 模拟（逐像素读目标）。守卫在每次采样前把**整个 28 MB 帧缓冲**快照一遍，重帧里 86% 的时间花在这。
  脏矩形快照无效（WS 每次 draw 的 scissor 近乎全屏）。
- 改为：片元名以 `fixed_frag_` 开头且 slot ≤ 2 且无渲染影子时，结束 pass → 全屏障 → 重启 → 直接采样自身（零拷贝）。
- 结果：>6 ms 的命令缓冲 536 → 6，>10 ms 322 → 0，p99 GPU 跨度 10.7 → 2.1 ms。测试 `catest/selffetch.m`（CPU 回放；去掉重启的对照会失败 = 旧的过期读 bug）。

### 12. Steam / CEF（Apple GL-on-Metal）
- Steam 的 CEF 走 `angle=opengl`（Apple 的 GL-on-Metal 叠在插件上），Chrome 走 ANGLE-Metal，是两条路径。
- AppleMetalOpenGLRenderer 对每个 MSAA pass 设置全零“采样位置”；插件没有 sample-locations 后端，`nvmtl_vk_cmd_begin_pass` 返回 -1，整个 pass 被丢 → “cannot begin requested render pass”。
- 修复：无后端时用标准采样图案（`gl-sample-positions.patch`）。测试：`catest/gldiff.m`（CGL 硬件 vs Apple 软件渲染，46 例；MSAA 边缘像素、points_lines、flipped blit 仍有预期差异）。

### 16. UU 远程作控制端闪退
- UU 的信号处理函数把 SIGABRT/SEGV/… 全部转成 `kill(self, SIGKILL)`，崩溃无 `.ips`，launchd 只说“SIGKILL sent by UURemote”。用 get-task-allow 重签名的副本放进 lldb 才抓到：
  libstreamer 的 Metal 视频视图设置的 viewport 深度范围越出 [0,1]，插件原样传给 `vkCmdSetViewport`，NVK 在 `nvk_emit_viewport` 里 `assert(0<=zmin<=1)`。
- 修复：在 `nvmtl_vk_cmd_set_viewport` 夹紧 znear/zfar（`viewport-depth-clamp.patch`）。

---

## 三、翻译器（metal2vulkan 衍生）

补丁 `patches/nullmoth-1.9.0/0002-translator.patch`（LGPL-3.0-or-later）。

### 7. WebGL 着色器翻译失败（`get_num_samples`）
- Metal 库在任何管线存在之前就被翻译，`lower_raster_sample_count` 拿不到采样数 → ANGLE 的 WebGL 着色器创建失败 → “Context lost → Restarting GPU process”（窗口整块空白一下，无 crash dump）。
- 翻译器：未知采样数变成 `OpSpecConstant`（默认 1，SpecId `0x4E560001`）；插件：给片元阶段挂 `VkSpecializationInfo`。**两半缺一不可。** 测试 `catest/nsamp.m`（1x=1、4x=4，PASS）。

### 9. Graphite 顶点输出丢失
- `passes/stage_output/mod.rs::rewrite_return` 只在 stage_input 阶段的 `defs` 快照里查入口返回类型；之前某个 pass 新建了结构体类型（如 Dawn 纯色不透明管线的 `<{<4 x float>,<4 x float>}>`）时查不到，**所有顶点输出（Position+varyings）被静默跳过**，几何永不光栅化。
- 修复：`defs.get(&ret_ty).cloned().or_else(|| type_def_of(ctx, ret_ty))`。
- 最小复现：静态页面 + 一个 `transform: rotate(0.3deg)` 的 canvas，开 Graphite → 页面背景透明。
- 离线调试法：从插件导出管线的 SPIR-V + AIR，`metal2vulkan x.air.ll out.spv --stage vertex`（需要一个假的 `spirv-val` 放在 PATH，`METAL2VULKAN_PHASE_DUMP` 看哪个阶段丢输出）。

### 13. Core Image Lanczos 整块纯色
- `CILanczosScaleTransform` 在非 0.5 的缩放比例下运行 `_lanczosDownH/_lanczosDownV`（stitched AIR）。采样器变换指针（`buffer0+80`）传给一个带分支、不会被内联的 helper。
- `emitter/body/calls.rs` 在**发射 CALL 时**记录 helper 形参的常量字节偏移；但 `emit_inner` 按 IR 顺序发射，helper 在调用者之前 → 偏移回落到 buffer 根（0）→ 坐标取自 destcoord → 每行相同 → 每个 tile 纯色。**这是上游自 1.0.0 就有的 bug，1.9.0 仍在。**
- 修复：`callers_before_pointer_helpers()` 稳定拓扑重排（仅当有指针形参的 helper 排在其调用者之前时才重排）。
- 验证：6787 个可翻译缓存着色器新旧对比，仅 5 个变化（全是 CI Lanczos），另 25 个只是 ID 重编号。

---

## 四、Chrome / Electron 的 GPU 合成

### 5. 让 Chrome 走 GPU（ANGLE-Metal + NVK 沙箱）
Chrome 与 Chromium 系应用默认 `--use-gl=disabled`，软件合成，导致 WindowServer 大面积同步上传。两个拦路点：
1. ANGLE 的 `disableMetalOnNvidia`（为老 Kepler 驱动设计）。环境变量 `ANGLE_FEATURE_OVERRIDES_DISABLED=disableMetalOnNvidia`，用 LaunchAgent 里 `launchctl setenv` 设置；或 `--disable-angle-features=disableMetalOnNvidia`。
2. GPU 沙箱拒绝 `file-write-data /dev/null`，而 NVK 的 `nvrm_xnu_open` 为占位 fd 调 `open("/dev/null", O_RDWR)`，沙箱起来后所有 NVRM 连接失败。另外沙箱拒绝 `hw.pagesize`，Mesa 的 `os_get_total_physical_memory` 得到 -1。
   - 修复：`libvulkan_nouveau.dylib` 2 字节补丁（open 标志 `0x1000002 → 0x1000000`，即 `O_RDWR|O_CLOEXEC` → `O_RDONLY|O_CLOEXEC`，偏移 1.0.10 为 0x12bfc8 / 0x12c0db），并把 `os_get_total_physical_memory` 重写成 `sysctlbyname("hw.memsize")`。
   - 脚本：`codec-vulkan/vulkan/vk-devnull.sh`、`vk-bindfix.sh`、`mk-bindfix.py`；1.9.0 版本的偏移用 `mk-bindfix-190.py` 重新推导。
- 调试备忘：`DYLD_INSERT_LIBRARIES` 进不了 Chrome 的 GPU 助手（hardened runtime）；lldb 也附不上去。
- **Chrome 的 flags**：本机上 Graphite 与 GPU 栅格在早期构建下都渲染错误（半个四边形全黑 / 曲线路径缺失）。翻译器修复（第 9、13 项）和插件修复之后，作者重新打开了 GPU 栅格并保持 Graphite 关闭。排错时的稳定组合是 `chrome://flags` → `#skia-graphite` Disabled，必要时 `#enable-gpu-rasterization` Disabled。
- Electron 应用也会吃到这个环境变量；有问题时 `launchctl unsetenv ANGLE_FEATURE_OVERRIDES_DISABLED`。

---

## 五、视频编解码（二进制补丁，NullMoth 只发布二进制）

共同根因：NullMoth 的编解码器是在 **Blackwell** 上做的，Ada（RTX 40）的 NVENC/NVDEC 用的是 **t2d GOB 布局**，而代码按 bw8（亮度）/bw16（色度）块布局读写。

### 14. NVDEC H.264 竖条纹
- `libnvdec_h264.dylib` 的 `emit_picture` 以 mode 1 调 `nvd264_detile`（`mov $1,%edx`，0x163d）；Ada 写出的是 mode 0。**0x163e 处 `01 → 00`** + ad-hoc 重签名。
- 亮度 PSNR：补丁前 17.5 dB，补丁后 480p/720p/1080p/2160p 逐比特一致。HEVC NVDEC 本来就是 t2d，无需改。
- `codec-vulkan/nvdec/nvdec-t2d.sh install|restore`；测试程序 `dectest.swift <dylib> [W H]`（进程内寄存器、与 Apple 软解对比）。

### 15. NVENC（UU 远程被控端）
1. **NotSync**：关键帧被设置 `kCMSampleAttachmentKey_NotSync=false`，UU（WebRTC 的 libstreamer）只检查 key 是否**存在** → 永远看不到关键帧，卡在“传输画面中”。10 字节补丁（H.264 0x1665 / HEVC 0x175c）。
2. **花屏**：`nve264_encode` 亮度按 bw8、色度按 bw16 拷贝，Ada NVENC（class 0xc9b7）两个平面都按 t2d 读。把输入预先置换后走生产路径，t2d 可得 50.4 dB 亮度 / 47.2 dB 色度，其它布局只有 9–12 dB。补丁在 0x626a / 0x6399 加 t2d 循环。HEVC 的拷贝循环**尚未补**，所以仍需 `NVMTL_NO_NVENC_HEVC=1`。
3. **创建会话 2.6 s**：`buf_alloc` 用 CPU 经 BAR 映射把约 29 MB 显存 `bzero` 到约 10 MB/s → AVX 清零循环（代码洞 0x1d00），降到 0.1 s。
4. **无码率控制**（恒定 QP 23，忽略 AverageBitRate）：加逐帧 QP 控制（`rc.c` 编译进代码洞 0x1d40）；IDR 的 QP 原为 `(4qp+2)/5`（关键帧很大）改为 `qp`；默认 GOP 60 → 3600。
- 简易退路：`uu-nvenc-toggle.sh off`（写入 `NVMTL_NO_NVENC` 到 conf，让应用改用 Apple 软件编码）。
- 脚本 `codec-vulkan/nvenc/uu-nvenc-t2d.sh install|restore`，补丁源码片段在 `*.s`、`rc.c`，测试 `rctest.swift`、`timing.swift`。
- ⚠ **绝不要原地覆盖已被加载的 dylib**（`cp` 到同一 inode）：内核缓存的代码签名失效，所有后续 dlopen 它的进程被 SIGKILL（"Code Signature Invalid"）。所有脚本都用“写临时文件再 `mv`”（新 inode）。
- 重启 UU：不要只 kickstart agent（会使 App 与 agent 失联，显示“网络连接异常”，远程时会把自己锁在外面），用 `uu-restart.sh`（不需要 sudo）。

---

## 六、内核扩展与硬件

### 17. 内置面板亮度（滑块 + Fn 键）与电池
根因链：
1. NullMoth NVRM 把 `nv_acpi_dsm_method` 桩掉，RM 拿不到 NBCI/NVHG `_DSM` 的 GETBACKLIGHT(0x14) → GSP 拒绝 `0x730291/2`，NVKMS `hasBacklightBrightness=false`。
2. 再往下：`nv_acpi_dod_method` 也被桩掉，`_DOD` 为空，GSP 无法把 ACPI id `0x8000a450` 对应到面板 → NOT_SUPPORTED。
3. 面板背光是 **GPU 驱动的 PWM**（NBCI `_DSM 0x14` 返回 BLPK 并触发 SMI），`_BCM`（仅保存变量）和 DPCD 0x722 写入**都不会**改变实际亮度。
- **NVDSM**（Lilu 插件，`backlight/NVDSM`）：路由 `_nv_acpi_dsm_method`（NBCI/NVHG 子函数 0、0x14 → `PEG1.PEGP._DSM`，其余走原桩）、`_nv_acpi_dod_method`，并截获 `_nvkms_register_backlight` 的 `(displayId, pDispEvo)`，解析 `_nvKmsGet/SetBacklight`，以资源 `NVDSMBacklight` 和 sysctl `debug.nvdsm_kms_bl` 暴露。
  注意：OC 注入的 kext 在 Boot KC，**无法链接** System KC 里的 IOGraphicsFamily，所以 NVDSM 不能依赖它；真正的 `IODisplayParameterHandler` 必须放进 NVRMFB（Aux KC）。
  boot-arg `nvdsm=0` 关闭，`nvdsm=2` 记录 BIOS 对每个能力查询的回答。
- **NVRMFB 补丁**（`patches/nullmoth-1.9.0/0004`）：把内部 eDP 标成 `kIOConnectionBuiltIn`，`getAppleSense` 返回 kGenericLCD，在 `IOResources` 下创建 "backlight" 服务（`gIOFBHaveBacklight` → `AppleBacklightDisplay`），`NVRMBacklightHandler` 提供 `brightness`、`linear-brightness`（WindowServer 实际驱动的是 `linear-brightness`）及 `*-probe`。
- **Fn 亮度键 / 电池**：OC 的 `SSDT-EC.aml` 用 `_OSI("Darwin")` 把真实 EC0 对 macOS 隐藏（`_STA` 返回 0）→ 无 AppleACPIEC、无 `_Qxx`、`BatteryInstalled=No`。`backlight/enable-ec.sh` 把那个字符串改名成 `"EC0_ON"`（并修校验和），EC0 绑定后 `_Q11/_Q12 → Notify(LCD0, 0x86/0x87)`，再由 **BrightnessKeys** 转为按键。`backlight/rescue/` 里有 Linux/Windows 下恢复原 SSDT-EC.aml 的救援脚本（原始 AML 内嵌）。
- 安装 `backlight/install-builtin-bl.sh`，撤销 `revert-builtin-bl.sh`（也可以从安全启动项用）。
- 其它工具：`nvbl.c`（用户态读写 NVKMS 背光，免 root）、`nvaux.c`（通过 RM 访问 eDP AUX/DPCD）、`dump-acpi.py`（拆分 NVDSM 导出的 DSDT/SSDT）。

### 18. Wi-Fi 与蓝牙（Intel AX211）
- **Wi-Fi**：`laobamac/itlwm` 的 AirportItlwm-Sequoia（无需根卷补丁；OC `MinKernel 24.2.0`）。换用后要把旧的 itlwm “以太网 2”服务换成 `networksetup -createnetworkservice Wi-Fi en2`。Wi-Fi 6：boot-arg `itlwm_he=1`（`wifibt/oc-bootarg.sh add|remove`）。AWDL/AirDrop 做不到（Intel 固件），WPA3 SAE 未实现。
- **蓝牙**（USB 8087:0033，iMacPro1,1 机型）逐层根因：
  1. macOS 14+ 需要 `-btlfxboardid`（BlueToolFixup）。
  2. 外置 dongle 模式要 NVRAM `bluetoothHostControllerSwitchBehavior=always`；`bluetoothExternalDongleFailed` 一旦被写成 `01` 就不再重扫，需加入 NVRAM Delete。
  3. bluetoothd 在 LE 特性字节 3 ≥ 0x10 时发 LE Read Buffer Size v2，却不检查 supported-commands 八位组 41 bit5；AX211 固件那里是 `0xC8` → 失败。**BTLEFix** 把 `/usr/sbin/bluetoothd` 里的 `73 1E → 90 90`（路由 `_cs_validate_page`，与 BlueToolFixup 同法）。
  4. 随后 LE 扫描 STATUS 718 循环：BTLEFix 在第一次 `0x200B` 前注入 `LE Set Random Address`（IntelBTPatcher 的同类 hook 对此路径无效，应禁用）。
  5. “Connect 要点三次”：bluetoothd 在 Inquiry（0x0401）运行期间发 Create Connection（0x0405），之后才取消，Intel 固件立即页扫失败（STATUS 712）。BTLEFix v4 在 0x0405 前若可能有 inquiry 在跑就先注入 Inquiry Cancel（按 0x0401 长度 ×1.28 s 估算）。
  6. `wifibt/IntelBTProductName/`（无代码 kext，经 AppleUSBHostMergeProperties 把 USB 产品名合并为 `Intel Wireless Bluetooth`）：让 bluetoothd 把 Intel 控制器当作**外置 dongle** 而非内置（内置模式会跑 Broadcom 的 VSC 初始化而失败，STATUS 712）。
- ⚠ BTLEFix v2 曾因为在 `IOUSBHostPipe::io` 的**完成回调**里读传输缓冲区导致 `IOGMD: not wired for the IODMACommand` panic。教训：永远不要在完成回调里碰 USB 传输的描述符，也不要 hook 所有 USB I/O；v3 起只 hook `idVendor 0x8087` 的 `deviceRequest`。
- `-btlefixoff` boot-arg 可停用 BTLEFix。

### 19. 触控板（ELAN0420 / I²C）
- ELAN 的 PS/2 侧（ETD0467）能应答 identify 所以 VoodooPS2Trackpad 会挂上，但永远没有数据包；真设备是 `\_SB.PC00.I2C0.TPD0`（I²C HID）。
- VoodooI2C 2.9.1 发行版三处问题：
  1. `VoodooI2CPCILakeController` 的 `IOPCIMatch` 缺 ADL-P 的 `0x51e88086&0xFFFCFFFF`（Info.plist 编辑，见 `trackpad/install-voodooi2c.sh`）。
  2. VoodooGPIO 的 `VoodooGPIOTigerLakeLP` 类没加进 Xcode 工程 → "Couldn't alloc class"。
  3. `TigerLakeLP::start` 调了 `VoodooGPIO::start` 而不是 `VoodooGPIOIntel::start`（没有 init/registerService）。
  - 2、3 的补丁：`patches/voodoo/0001-VoodooGPIO-TigerLakeLP.patch`（基线 VoodooGPIO `733dc80`，与 v2.9.1 同一子模块提交）。
- 同时停用 VoodooPS2 的 VoodooInput/Trackpad/Mouse 插件（两个 VoodooInput 冲突）；PS/2 键盘保留。
- **Fn+F1**（触控板键）是键盘固件宏 `e05b 3c bc e0db`（≈17 ms 内，即 Win+F2），不是 EC 事件。`trackpad/SSDT-PS2KEYS.dsl` 通过 `PS2K.RMCF` 的 Macro Inversion 把它改成 `e06e`，再映射 `e06e=e037`、`e037=64`；PrtSc → F13，并把 `symbolichotkeys 184`（截图工具栏）绑到 F13。VoodooPS2 的 PrtSc 开关 → `kPS2M_setDisableTouchpad` → VoodooI2CHID 已验证。
- 若更新 kext 后触控板失效：先看 `ioreg` 里 TPD0 → `VoodooI2CHIDDevice`，再重新跑 `install-voodooi2c.sh`。

---

## 七、系统层杂项

### 20. CrossOver / Wine 创建容器被杀
- 崩溃报告：`EXC_GUARD GUARD_TYPE_MACH_PORT ILLEGAL_MOVE`，在 wine 的 `ntdll.so mach_msg_send`（把 `mach_task_self()` 发给 wineserver）。
- 根因：boot-arg `amfi_get_out_of_my_way=0x1` 使**每个**进程都带 `CS_PLATFORM_BINARY`；xnu 把 platform|hardened 当作 1P，macOS 默认 `ipc_control_port_options = IMMOVABLE_1P_HARD|PINNED_1P_HARD`，所以移动 task port 就被 SIGKILL。与 GPU 驱动无关。
- 修复：boot-arg `ipc_control_port_options=0`（对所有进程关闭 immovable/pinned 控制端口，有安全代价）。`wifibt/oc-bootarg.sh add ipc_control_port_options=0` 后重启。
  **NVRAM 里的 boot-args 会被 OpenCore 按 ESP 配置重写，所以必须改 ESP 的配置，不能 `nvram boot-args=…`。**

### 21. 光标移动时偶发闪回旧画面（预防性）
- 现象（上游报告，本机未复现）：零拷贝翻转开启后，移动鼠标时偶尔有旧画面闪一下；`-nvrmnoflip` 后消失。
- 根因：NVRMFB 的 `cursorApply()` 提交光标时顺带把主画面（`fFrontSurf`）也提交一遍，于是每次光标移动都是一次主画面翻转，并按垂直同步节拍；如果零拷贝翻转恰在读取 `fFrontSurf` 与提交之间锁存了更新的帧，旧帧会被放回屏幕，直到下一次翻转。
- 修复：移植上游 1.13.0 的做法——光标提交只带光标，`submitConfig(…, cursorOnly=true)` 跳过主层。补丁 `patches/nullmoth-1.9.0/0005-nvrmfb-cursor-only.patch`（叠加在 0004 之后）。
- 验证：作者本机编译安装后重启，HiDPI@165Hz、零拷贝计数、亮度、睡眠唤醒均正常。内核扩展安装有重启和黑屏风险，先备份并准备恢复模式回滚。

---

---

## 八、已排除：不是驱动的问题

- **窗口从 Dock 恢复（取消最小化）闪一下**：Chrome 只有 web 内容区变白 0.23 s；Finder 等是一帧“非活动”外观。A/B 排除了 GPU 进程崩溃、遮挡后台化、异步 surface-in、零拷贝翻转、`--disable-mac-overlays`、GPU 栅格。
  结论：macOS 13+ 已知的取消最小化问题（Apple 开发者论坛 801112，Chrome 在列）+ 浏览器在 WS 使后备失效后的重绘。只能用“最小化到应用图标”/“缩放”效果绕开。
- **B 站“骨架屏”等待**：站点数据加载，不是 GPU。
- **开机后的短暂卡顿（“等一会才流畅”）**：冷着色器缓存（以翻译器哈希为键），首次启动后自行恢复；曾因未持久化 `VkPipelineCache` 每次开机重编所有 NVK 着色器，已在 v47 修复（`pcache`）。

---

## 参考：内部版本演进（作者本机）

插件版本链：v46 → v47（持久化 pipeline cache）→ v48（合入上游 1.9.0：采样器负 LOD、`shaderDrawParameters`、GL zero-net、翻译器的 base_vertex/base_instance；260/260 缓存着色器逐字节一致）→ tiled 渲染影子 → selffetch → gl-sample-positions；翻译器：`761a54b4`（顶点输出）→ `eb4fb6a3`（Lanczos）。
`nvguard/` 里记录的哈希就是这些构建的 sha256（你自己的构建哈希不会相同）。

## 九、1.13.0 用户态补丁集

`patches/nullmoth-1.13.0/` 是把插件和翻译器的本地修改重新整理到**上游 v1.13.0** 之上的差异（已验证可在原版 v1.13.0 上干净应用，应用后的插件和翻译器可编译，并通过 `hidpi/catest/` 里的回归程序）。和 1.9.0 版相比：
- 上游 1.13 已吸收的内容（视口深度夹紧等）不再出现在补丁里。
- 额外一处本地改动：1.13 只在 Blackwell 上注册 NVENC，Ada 上我们的 NVENC 补丁（修复 15）会被绕开，所以插件默认在所有 GPU 上注册，设置环境变量 `NVMTL_NVENC_BLACKWELL_ONLY` 才恢复上游行为。
- **没有**升级内核扩展。1.9.0→1.13.0 期间 NVRM 核心源码没有变化，变化的只有 NVAccel（无头 GPU、Intel 内置屏，仅用于面板不在独显上的笔记本）、NVRMFB（光标，已移植为修复 21；另有“多列出分辨率”，未移植）、新增的 NMIntelFB 与 NMHDA。对独显直连的机器升级没有收益，所以内核扩展仍以 1.9.0 为基线；若要升级，NVRM 与 NVK 的字节补丁偏移量需针对 1.13.0 的二进制重新核对。

