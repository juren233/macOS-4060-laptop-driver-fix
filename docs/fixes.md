# 修复详解

编号与 [README](../README.md) 的表格一致。除特别说明外，环境为各项修复做出来时的 macOS 15.8.1、NullMoth v1.9.0 内核扩展 + v1.14.2 用户态（插件、翻译器、NVK）、RTX 4060 Laptop（Ada）。
作者本机现在是 **macOS 26.7.1 + NullMoth 1.15.0 内核扩展与用户态 + 本仓库补丁**：1.15.0 补丁集见第九节（再续），macOS 26 见第十一节。
“插件”= `/Library/GPUBundles/NVMTLDriver.bundle`（Metal 驱动），“翻译器”= 其中的 `libnvmtl_translate.dylib`（Apple AIR → SPIR-V），
“NVK”= `libvulkan_nouveau.dylib`。

> 重要：发行版插件会在构造函数里 `unsetenv()` 所有 `NVMTL_/NVK_/NAK_/NVRM_` 环境变量，**旋钮只能写在
> `/Library/GPUBundles/nvmtl/nvrm610.conf`**（`tools/nvknob.sh` 可读写）。

---

## 一、显示：HiDPI 与翻转

### 1. HiDPI（head scaler）
- **死路**：窗口级（precomp）缩放在独显上被 NVKMS 隐藏；强行打开 caps 会出 Xid 56 `INVALID_STATE` 并整卡挂死。
- **做法**：让**显示头（postcomp）**缩放。NVRM 二进制 26 字节补丁：`viewPortSizeIn` 取图层源尺寸，`sizeOut` 取源尺寸（`0x56/0x58 → 0x4e/0x50`）。
  1.9.0 的偏移见 `kexts/patch-nvrm-190.py`（每个字节都先断言再写，可重复运行）。1.15.0 的 NVRM 这段代码与 1.9.0 逐字节相同，只是整体后移 0x1590：`kexts/patch-nvrm-115.py`。
- **165Hz 上限**：2560×1440@165 时 IMP 接受 ≤1.4× 降采样（looks like **1792×1008**，backing 3584×2016），1.425×（1824×1026）起被拒绝。
  更低刷新率能用更大的 looks-like（如 40Hz 的 1920×1080）。
- `hidpi/overrides/DisplayProductID-b40.final` 是 BOE 0B40 的 HiDPI 列表（`scale-resolutions` 为大端 `宽,高,flags` 的 base64），
  安装到 `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-9e5/DisplayProductID-b40`。**你的面板 VendorID/ProductID 不同，需要改文件名和内容**。
  新增的 HiDPI 项**必须完整重启**才出现（只重启 WindowServer 不行）。
- 工具：`hidpi/tools/listmodes.swift`（列出所有 CG 模式）、`setmode.swift`、`modetest.swift`、`hsprobe.c`。

### 2. 启动即零拷贝翻转
- NullMoth 的 `autoGo` 在释放 boot-hold **之后**还 `IOSleep(60000)` 才打开 `debug.nvaccel_iop_flip=1`，于是登录后、窗口已显示时才**热切换**扫描路径，
  已被拷贝路径扫描出去的表面（Dock）停止呈现，直到进程重启。
- `IOSleep(60000)` → `IOSleep(0)`（源码补丁 `0003`，二进制补丁在 `patch-nvrm-190.py` 末尾；1.15.0 在 `patch-nvrm-115.py`，偏移 0x9467）。
- 运行时关闭翻转是安全的（`sysctl debug.nvaccel_iop_flip=0`），**运行时再打开不安全**（Dock 会坏），需要重启。
- 旧方案 `hidpi/legacy-1.0.10/nvflip/`（LaunchDaemon 延迟 60 秒再开）已被取代。

---

## 二、WindowServer / 插件（NVMTLDriver）

当前补丁在 `patches/nullmoth-1.15.0/0001-plugin.patch`（累计；1.9.0、1.13.0、1.14.2 基线的旧版在各自目录），逐项独立 diff 在各目录的 `per-fix/`。

### 3. 黑块 / 残影 / 圆角变方
排查走了很长的路，结论按层记录：
1. `newTiledTextureWithDescriptor` 在 pitch/offset 非 32B 对齐时退化为一次性拷贝，CA 之后写 buffer 纹理却不更新 → 过期内容；
   `newBufferWithBytesNoCopy` 在宿主指针导入被拒时同理（`stale-texture-fix.patch`）。**单独修这两处并不能治好 Finder 侧栏。**
2. 真正根因：WindowServer 把小图层缓存渲染进**线性共享 IOSurface VRAM**，结果出错（具体哪个操作未查明）；另有“纹理创建与 GPU 写入的发布顺序”竞争。
3. 修复：旋钮 `NVMTL_SURF_SHARE_MINPX`（默认 0）——像素数低于阈值的 IOSurface 用**私有 tiled 图像**（当时用 `3686400`）；同一进程里同一私有 IOSurface 的所有纹理共享同一根图像；
   `surfaceOut` 在写 tag 之后才标记已发布。帧缓冲必须保持共享（扫描输出需要）。
4. 后续：窗口尺寸 ≥ 阈值的共享表面若被自己的 pass 采样（defocus），做快照（`surface-guard-diag.patch` / `private-guard.patch`）。
- **现状**：有了后续修复（本节第 4 点的自采样快照等）之后，作者本机自 2026-10-13 起改回 `MINPX=0`（所有窗口大小的 IOSurface 都走共享显存），没有再出现黑块，而且智能防挡弹幕下 WindowServer CPU 80% → 55%（第 26 项）。`nvguard/` 现在保持的就是 `0`。如果你的机器出现黑块，再把它设回 `3686400`。
  注意 conf 里同一个键只有**第一行**生效，追加一行不会覆盖前面的值（`nvguard/` 会删掉旧行再写）。
- 验证：`hidpi/catest/surftex.m`（6 种时序）、`hostcopy.m`、`tiledtex.m`、`lintarget.m`；窗口截图（`app_screenshot` 类工具）能复现该问题，可作判据。
- ⚠ 教训：只看窗口截图正确不代表屏幕正确——曾出现“窗口捕获正常但物理屏幕全黑”。要让人看实际屏幕。

### 4. WindowServer 高 CPU / 掉帧（异步 surface-in）
- `spindump WindowServer 10`：主线程 61% 在 `nvmtlSurfaceIn → nvmtl_vk_image_write`（CPU memmove + 缺页），11% 同步 `vkWaitForFences`。
  原因是第 3 项把所有小表面和每个 NV12 视频帧变成私有图像，每次 seed 变化都整块 CPU 拷贝并等 GPU。（现在 `MINPX=0`，窗口大小的表面走共享显存，私有图像主要剩视频帧这类。）
- 修复 `surfin-async.patch`：上传不等待、按队列顺序提交；用 `vkGetFenceStatus` + 16ms 定时器回收，最多 48 个在途；重复上传可改为让 GPU 直接读 IOSurface 的内存页（`NVMTL_SURFIN_IMPORT_MB`，**默认 0 = 关闭**：GPU 稍后才读这些页，会和 Chrome 改写栅格块竞争，滚动时闪烁；写一个 MB 数可开启）。
  只对私有图像异步；共享 VRAM 上的上传仍同步（VRAM tag 表示数据已就绪）。关闭开关：`NVMTL_SURFIN_ASYNC=0`。
- 测试：`hidpi/catest/surfasync.m`。

### 6. 闪烁（scheduled 回调时机）
- Chromium 在提交 CA 事务前调用 `waitUntilScheduled`；WindowServer 的 NVK 通道与 Chrome 的无序，私有图像表面只在**完成**时发布。
- `addScheduledHandler` 回调改在完成时执行（`NVMTL_SCHED_AT_COMPLETION=0` 恢复），治好了 Electron（大窗口 2432×1600 IOSurface）的交替旧帧。**这一半必须保留**（关掉会满屏闪）。
- 当时还把 `waitUntilScheduled` 改为等到完成（插件默认仍是这样）。后来查明 Chrome 那次闪烁的真因是翻译器（第 9 项），这个等待只是让 Chrome GPU 进程空等，作者的 conf 用 `NVMTL_SCHEDULED_WAIT=0` 关掉了（见第 26 项）。

### 8. IOSurface use count
- Apple 驱动在 GPU 工作引用 surface 期间保持 `IOSurfaceIsInUse` 为真，Chromium 的 buffer queue / CVPixelBufferPool 据此回收。插件从不持有 → 视频预览（HEVC 640×360 经 VideoToolbox）纯绿、窗口对角撕裂（新旧帧混合）。
- 命令缓冲持有的 `nvmtl_resref` 在 0→1 加 use count，→0 减；每纹理 `_useLk/_useHeld`。旋钮 `NVMTL_SURF_USECOUNT=0`。测试 `catest/usecount.m`（原版 FAIL，新版 PASS）。

### 10. 线性 RT 的 tiled 渲染影子（Chrome 滚动）
- 走共享显存的窗口 IOSurface（≥ `MINPX`；作者现在 `MINPX=0`，即全部）是 pitch-linear 的共享 VRAM 别名，一帧约 11 个 Graphite pass、每个约 1 ms，且与 backdrop 模糊链交错。
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
- 修复：无后端时用标准采样图案（`gl-sample-positions.patch`）。1.14.2 补丁集里改用上游同类的兜底，效果相同。测试：`catest/gldiff.m`（CGL 硬件 vs Apple 软件渲染，46 例；MSAA 边缘像素、points_lines、flipped blit 仍有预期差异）。

### 16. UU 远程作控制端闪退
- UU 的信号处理函数把 SIGABRT/SEGV/… 全部转成 `kill(self, SIGKILL)`，崩溃无 `.ips`，launchd 只说“SIGKILL sent by UURemote”。用 get-task-allow 重签名的副本放进 lldb 才抓到：
  libstreamer 的 Metal 视频视图设置的 viewport 深度范围越出 [0,1]，插件原样传给 `vkCmdSetViewport`，NVK 在 `nvk_emit_viewport` 里 `assert(0<=zmin<=1)`。
- 修复：在 `nvmtl_vk_cmd_set_viewport` 夹紧 znear/zfar（`viewport-depth-clamp.patch`）。

### 22. Memoji / SceneKit 角色网格碎裂（compute `stage_in`）
- 现象：Memoji、SceneKit 骨骼蒙皮的角色网格被“炸开”成碎片。
- 根因：SceneKit 的蒙皮 kernel 用 Metal 的 `MTLStageInputOutputDescriptor`（compute 阶段的 `[[stage_in]]`：kernel 按属性描述从顶点缓冲取输入）。
  插件没有实现这一功能，kernel 读到的是未绑定的属性。
- 修复：插件实现 compute stage_in——用一个由 MSL 编译出的 gather kernel（`plugin/si_gather.metal`）在 GPU 上把各属性收集到连续缓冲，再绑定给原 kernel；
  支持 8/16/32 位属性格式、BGRA 排序、常量步长（`per-fix/compute-stage-in.patch`，已包含在 `0001-plugin.patch`）。
- 测试：`hidpi/catest/sitest.swift` + `sitest.metal`（三组随机顶点布局，逐元素与 CPU 参考比对）。若 Memoji 仍显示旧的坏状态，清掉 `~/Library/Caches/Animoji` 里残留的缓存。

### 23. 往 `framebufferOnly=NO` 的 CAMetalLayer 写入被丢（Photo Booth 预览纯黑）
- 现象：Photo Booth 实时预览纯黑（拍照正常）；任何用 compute / Core Image 往这类 drawable 画图的程序都画不出来。插件日志里有 `ShaderWrite` 相关报错。
- 根因：QuartzCore 对 `framebufferOnly=NO` 的 drawable 传 `MTLTextureUsageUnknown`（0）。Apple 自己的驱动把 0 当作“所有用途”，
  插件却按字面当成“没有任何用途”，Core Image 的 compute 写入因缺少 ShaderWrite 被拒绝。
- 修复：在创建纹理的各入口（普通、IOSurface、heap、buffer 纹理，含 `heapTextureSizeAndAlign`）把 0 读作 ShaderRead | ShaderWrite | RenderTarget。
  旋钮 `NVMTL_UNKNOWN_USAGE=0`（写在 `nvrm610.conf`）恢复旧行为（`per-fix/unknown-usage-all.patch`）。
- 测试：`hidpi/catest/drawable-writes.swift`（渲染 pass / compute / blit / Core Image 四种写法，每行必须是 OK）。
- 附带：macOS 15 的 Photo Booth 在 iPhone 在附近时默认选连续互通相机，要手动切到内置/外接摄像头才有画面，这不是驱动问题。

### 26. B 站 4K 视频 + 大量弹幕掉帧（视频帧上传、提交等待、每帧新表面）
- 现象：B 站 4K 视频开弹幕后掉帧、视频丢帧；开“智能防挡弹幕”更明显。没有弹幕时 Chrome 把视频直接交给 Core Animation，GPU 进程几乎不动；
  有了覆盖层，Chrome 要自己合成视频，每一帧都牵动插件的上传、提交和表面导入路径。逐个找到的开销：
  1. **每帧新建 12 MB 暂存缓冲**：每个解码出的 NV12 帧都被包进新的 MTLTexture，插件的异步上传（第 4 项）每帧新建再释放 8 MB + 4 MB 暂存缓冲。
     改为按尺寸回收复用（`per-fix/surfin-stage-reuse.patch`）：4K 每帧主线程 CPU 约 10 → 2.8 ms（`hidpi/catest/upbench.m`），合成测试 200 条弹幕 86–92 → 165 fps、视频丢帧 15% → 0。
  2. **`waitUntilScheduled` 等到 GPU 完成**：第 6 项的闪烁修复把它改成了等完成，后来查明那次闪烁的真正原因是翻译器（第 9 项），
     所以 `NVMTL_SCHEDULED_WAIT=0` 让它提交后就返回（**scheduled 回调仍在完成时触发**，那部分不能动：`NVMTL_SCHED_AT_COMPLETION=0` 在没有第 7 点时满屏闪；有了第 7 点不闪了，但实测更慢，见第八节（续））。
     真实 B 站 4K：128–160 → 165 fps，Chrome GPU 进程 CPU 约 116% → 34%。
  3. **提交被前一帧的发布挡住**：执行线程只在两次阻塞等待之间做“提前提交”，导致 Chrome 等的那帧要等上一帧 GPU 完成 + IOSurface 发布。
     改为提交时就在独立队列上做（`per-fix/eager-submit.patch`，`NVMTL_GSUB_EAGER=0` 关闭）：`schedlat` 2.5 → 0.01 ms；智能防挡下每 10 秒 >12 ms 的帧 132 → 6。
  4. **自旋等待**：`NVRM_EVENT_WAIT=1`（上游旋钮）让普通进程也用事件等待 GPU，Chrome GPU 进程 CPU 再降约 10%。
  5. **每帧一个新 IOSurface**（智能防挡的遮罩层）：每个新表面第一次被当纹理用时要导入显存（约 2 ms）。
     - 插件：死掉的纹理留下的 tiled 渲染影子按尺寸/格式“停车”复用（`per-fix/rsh-park.patch`，`NVMTL_RSH_PARK=0` 关闭）：`newsurf` 每个表面 CPU 1.48 → 0.93 ms。
     - 内核：NVRMFB 给每块新显存先用 CPU 经 BAR 清零（约 2.5 ms / 7.6 MB）。RM 的 scrub-on-free 已经用拷贝引擎清过（抽查约 2.1 万次分配，非零 0 次），
       所以改为“抽样为零就不再清”（`patches/nullmoth-1.9.0/0006-nvrmfb-vram-noclear.patch`，1.15.0 版是 `patches/nullmoth-1.15.0/0003-nvrmfb-vram-noclear.patch`；`sysctl debug.nvrmfb_clear_mode`：0 原样、2 抽样为零即跳过=默认），弹幕时省约 10% 个核。
  6. `NVMTL_SURF_SHARE_MINPX=0`（所有窗口大小的 IOSurface 走共享显存）：智能防挡下 WindowServer CPU 80% → 55%，最长卡顿 42 → 18 ms；本机没有再出现第 3 项的黑块。
  7. **第 2 点的副作用：跨进程读到上一帧**（1.15.0 补丁集里修复）。`waitUntilScheduled` 提交即返回后，生产者（如 Chrome GPU 进程）在 GPU 还在写的时候就把表面交了出去；
     Apple GPU 上消费者的命令天然排在后面，这里每个进程是独立的 GPU 通道，私有图像的写入要到完成时才发布到表面页面 → 另一个进程读到上一帧（`hidpi/catest/gfx4.m` 10 次里 7 次有 1–55/60 帧错）。
     修复：插件把每个表面“已编码/已发布的写入次数”写进 IOSurface 的值 `NVMTLWr:p<plane>`（任何进程立刻可见），读者在使用前等待别的进程尚未发布的写入
     （双方都在共享显存时在提交前等，否则在 surface-in 处等；最多 200 ms，写者进程消失即停）（`patches/nullmoth-1.15.0/per-fix/xsurf-sync.patch`，`NVMTL_XSURF_SYNC=0` 关闭）。
     `gfx4` 60/60 正确，平均等待约 2.5 ms（一帧生产者 GPU 时间）。
- 当前 conf：`NVMTL_SCHEDULED_WAIT=0`、`NVRM_EVENT_WAIT=1`、`NVMTL_SURF_SHARE_MINPX=0`（`nvguard/` 会保持它们生效）。
- **仍然存在的限制（不是驱动的问题）**：
  - 开智能防挡后，Chrome 把弹幕层做成每帧一个新 IOSurface 的 CALayer，**WindowServer 实际上屏帧数减半**：合成测试 200 条弹幕，不开遮罩上屏 145–155 fps，开遮罩 85–94 fps（Chrome 自己的 rAF 一直是 165）。
    换了三套驱动结果一样。Chrome 启动参数 `--disable-features=CoreAnimationRenderer` 能回到约 140 fps，但不开遮罩和滚动网页时 CPU 更高，是取舍而不是默认。
  - 同屏弹幕到 400–500 条时，瓶颈在 Chrome 自己（渲染进程排版 + 合成），驱动能做的有限；调低弹幕密度最有效。
- 测试：`hidpi/catest/danmaku/`（`dm.html` 合成弹幕页 + 遮罩，`gen.swift` 生成 4K 测试视频，`tools/synthws.sh` / `biliws.sh` 同时记录 Chrome 帧率和 **WindowServer 实际上屏帧数** `wsframes.sh`），
  `upbench.m`、`schedlat.m`、`chainstress.m`、`newsurf.m`、`rparktest.m`、`gfx4.m`（跨进程，第 7 点）。

### 28. Unity 类程序卡死（在 `@synchronized(命令缓冲/队列)` 里提交并等待）
- 现象：Unity 编辑器/游戏等程序偶发整个卡死。它们会在 `@synchronized(commandBuffer)` 或 `@synchronized(queue)` 里调用 `commit` + `waitUntilCompleted`，
  而插件的执行线程完成命令缓冲时也要拿同一个对象的锁 → 互相等待。
- 修复：回移植上游 1.14.5 的做法——插件内部改用自己的类级锁，不再锁用户可见的对象，容量计数原子释放（`per-fix/upstream-sandbox-unity-backport.patch` 的一部分）。
- 测试：`hidpi/catest/unitylock.m`（旧插件会卡住，新插件 PASS）。

### 29. WebGL 大量绘制（每个物体一次 draw，如 WebGL Aquarium）帧率低
- 现象：WebGL Aquarium 5000 条鱼只有 41 fps、20000 条 13 fps；Chrome GPU 进程一个线程 100%，其中 76% 在插件的渲染编码器里，每次 draw 约 4–5 µs CPU。
- 根因与修复：
  1. 发行版里 `nvtrace()` 是普通函数，参数（如 `_vdesc.UTF8String`）每次 draw 都会求值，约占 10%：改成宏，只在开了跟踪时求值（`per-fix/nvtrace-release.patch`）。
  2. 每次 draw 都新分配并写一个描述符集（约 25%）：当两次 draw 之间只变了经地址表读取的绑定（`setVertexBytes`/`setFragmentBytes` 移动字节环），
     就重新绑定上一个描述符集，地址表写到同一页的新位置、以动态偏移传入（`per-fix/descriptor-table-reuse.patch`，`NVMTL_TABLE_REUSE=0` 关闭）。
     同时修正：绑定掩码把 bindless 堆（set 2 binding 0）误算成缓冲槽 0，导致所有采样纹理的着色器都像在用描述符读缓冲 0。
  3. **翻译器**：已经带地址表的模块（采样纹理的片元着色器，表项是 `uvec2`）原样返回，其余缓冲仍走描述符，描述符集无法复用。
     现在把剩余的存储缓冲也降到这张表上（`per-fix/translator-table-merge.patch`，`NVMTL_NO_TABLE_MERGE=1` 关闭）；本机 4639 个缓存模块：2580 个不变、2059 个合并，全部能被 NVK 编译。
- 结果：`hidpi/catest/drawbench.m`（ANGLE 式结构体 uniform）3.13 → 1.56 µs/draw，图像逐字节一致；Aquarium 5000 条 41 → 73 fps、10000 条 24 → 39、20000 条 13 → 21。
- 注意：比较修改前后的 GPU 输出要在**相同的着色器缓存状态**下进行（见 docs/pitfalls.md）。
- ⚠ **回归与修正（1.15.0 补丁集）**：第 2 点的复用最初只看管线的绑定掩码，而掩码里不含存储纹理（storage texture）。VideoToolbox 的两遍缩放（“照片”“预览”的缩略图）第二遍只换了输出纹理，
  于是复用了第一遍的描述符集、把结果写进了中间纹理，**所有两遍缩放出来的图都是空白**（1:1 或单轴缩放正常）。修正：存储纹理变了就不复用；变化位覆盖到 ≥63 号的存储槽位（原先越界写过 `chg[][4]`）；
  拷贝掩码覆盖描述符写入时检查的每个槽位（`patches/nullmoth-1.15.0/per-fix/vt-storage-descriptor-reuse.patch`）。验证用上游的 `tools/bench_vt_transfer.m`：3/3 张坏图 → 0。
  **1.14.2 补丁集里的 `descriptor-table-reuse` 带着这个问题**，请改用 1.15.0 补丁集，或把这处修正一起打上。

### 30. Dock 图标角标数字只有放大时才看得见（tiled 纹理的 mipmap 链）
- 现象（在 macOS 26 上发现，问题本身与系统版本无关）：Dock 上应用角标的红底在，数字不见；鼠标放大 Dock 时数字才出现。图标尺寸 78 能看到、62 很淡、50 完全没有。
- 根因：角标数字是一个 108×108 的图层，`minificationFilter` 为 trilinear、`minificationFilterBias` −0.5，画进约 21 pt 的角标，必然用到 mip 第 1 级以上。
  Core Animation 用私有接口 `newTiledTextureWithBytesNoCopy:`（落到插件的 `-[NVMTLBuffer newTiledTextureWithDescriptor:offset:bytesPerRow:]`）创建这种内容，描述符带 mipmap，
  缓冲里只有第 0 级，**其余级别要由驱动生成**（Apple 的驱动就是这样）。插件的拷贝兜底只上传了第 0 级，第 1 级起全空 → 一缩小数字就淡没了。
- 修复：上传第 0 级之后、以及每次从缓冲重新上传之后，生成整条 mip 链（`patches/nullmoth-1.15.0/per-fix/tiled-mips.patch`）。
- 测试：`hidpi/catest/tiledmips.m` 直接调用这个私有接口并检查每一级（修复前 FAIL、修复后 PASS，库验证下也 PASS）。`plugshim` 复现不了：CA 在测试进程里看到的是另一个设备，会改走 managed 纹理 + `generateMipmaps`。
- 排查备忘：Dock 进程不能用 lldb（SIP），但 AMFI 关着时可以 `launchctl setenv DYLD_INSERT_LIBRARIES …` + `killall Dock` + 立即 `unsetenv`，把 CALayer 树打出来；
  测试进程里 `instrumentObjcMessageSends(YES)` 能列出 CA 发出的每个 Metal 调用（`/tmp/msgSends-<pid>`）。

---

## 三、翻译器（metal2vulkan 衍生）

当前补丁 `patches/nullmoth-1.14.2/0002-translator.patch`（LGPL-3.0-or-later；1.9.0、1.13.0 基线的旧版在各自目录）。

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
- 1.14.2 补丁集里由上游的 raw-cursor 发射顺序取代（上游修了同一个问题），`cikl`/`lanczos` 测试结果不变。

### 25. WebGL 多纹理单元（`sampler2D u[N]`）：Claude 桌面端终端文字不显示
- 现象：Claude 桌面端右侧 Terminal 面板只有一个空心光标框，没有任何文字；加 `--disable-gpu` 才正常。任何用 WebGL2、且着色器里有 `uniform sampler2D tex[N]` 数组并按整数下标选用的页面都一样（xterm.js 的 WebGL 字形图集：`MAX_TEXTURE_IMAGE_UNITS`=16，`flat in int v_texpage` + if 链）。
- 根因（两处，缺一不可）：ANGLE-Metal 把它发射成两个 `ptr byval([16 x ptr])` 入口参数（纹理在 addrspace 1，采样器在 addrspace 2），再装进局部结构体 `thread T *texture` / `thread sampler *sampler` 指针里。
  1. **翻译器**：没有采样器数组的降级，`declared_descriptor_counts` 直接拒绝（回退，着色器创建失败）；纹理数组也只保住元素 0——`&param[k]` 的 access chain 在被 consumer 引用前就被当作死代码清掉，元素 0 的 store 不留 sidecar 事实，发射器还会折叠末尾全 0 的 GEP 下标。
  2. **插件**：每个 Metal 槽位一个 layout binding（`descriptorCount=1`），`nvmtl_spirv_bmask` 只按 `Binding` 装饰标记第一个槽位，元素 1…N-1 读到的是占位描述符（普通的 `array<texture2d<float>, N>` 动态下标也一样读不到第 1 个及之后的元素）。
- 修复：翻译器新增 `ParamBinding::SamplerArray`（`OpTypeArray<OpTypeSampler,N>` 的 UniformConstant 变量，沿用采样器 binding），`Ctx::sampler_array_vars/array_element_ptrs` 记录元素指针，`texture_array.rs` 同时解析采样调用的纹理（操作数 1）和采样器（操作数 2）句柄，并沿 `CopyObject` 链和结构体字段的 load/store 找回元素；
  插件让 `nvmtl_spirv_bmask` 顺着变量→指针→`OpTypeArray`→长度常量，把 `count` 个连续槽位都标上（`per-fix/sampler-array-translator.patch`、`per-fix/sampler-array-plugin.patch`，已包含在 `0001/0002` 里）。
- 测试：`hidpi/catest/sarray.m`（ANGLE 同款：16 页，每页必须取到自己的纹理**和**采样器，偶数页 nearest、奇数页 linear；旧栈 FAIL，新栈 PASS）；`catest/slib.m` 对系统 `SkyLightShaders.air64.metallib` 的每个着色器建管线，新旧一致；翻译缓存里约 4400 个着色器新旧对比输出逐字节相同，只有 xterm 那个以前翻译失败的现在能翻译。
- ⚠ **这个修复第一次安装时让桌面崩溃循环**：cargo 直接编出来的 `libnvmtl_translate.dylib` **没有代码签名**。普通用户进程照样 `dlopen`（所以上面的测试都通过），但 WindowServer 是平台进程、带库验证，拒绝加载 → “AIR->SPIR-V translator is not loaded” → 管线状态为空 → `MetalShader::CopyPipelineState` 空指针崩溃，随后用户态看门狗 panic，开机停在 verbose 画面。**放进 `/Library/GPUBundles` 的每个 dylib/插件都必须先 `codesign -f -s -`（插件加 `-i com.nullmoth.NVMTLDriver`），并用 `hidpi/tests/lv-test.sh`（`codesign -o library` 的测试程序）复现 WindowServer 的加载条件再安装**；详见 [pitfalls.md](pitfalls.md)。
- 回滚：`sudo zsh nvguard/install.sh previous`（把上一版重新登记为“好的构建”，守护进程随即把旧文件放回去，安全模式里也能用）。

- 后续（2.3.7 补丁集，翻译器 `passes::split_descriptor_arrays`）：纹理/采样器数组的**每个元素各自一个描述符**（binding 基址 + k）。开了 `robustBufferAccess`（NullMoth 2.0.x 起）之后 NVK 会把 `tex[k]` 夹到 `tex[0]`，`hidpi/catest/sarray.m` 在这种情况下只剩 1/16 页正确；`hidpi/catest/sarraydyn.m` 测动态下标。`METAL2VULKAN_NO_DESCRIPTOR_ARRAY_SPLIT=1` 关闭。

### 35. three.js 带阴影的 WebGL 页面打不开（Chrome “WebGL context lost”，GPU 进程重启）
- 现象：three.js 的 3D 页面（例子：带阴影的国际象棋）一打开就 context lost，Chrome GPU 进程反复重启；关掉阴影就正常。
- 根因：three.js 的阴影贴图是**只有一个元素的**采样器数组 `uniform sampler2D directionalShadowMap[1]`，并作为参数传给 `getShadow()`。ANGLE 发射成 `array<sampler, 1>` 入口参数，
  第 25 项的数组降级只处理 2 个及以上元素，长度 1 的被当成普通采样器绑定 → ANGLE 存进 TextureEnv 结构体的参数指针变成 null，
  helper 里的采样找不到采样器，翻译失败（“sampler operand is a pointer whose exact sampler state was not recovered”）。
- 修复（翻译器）：长度 1 的 `array<sampler, 1>` 入口参数也按采样器数组绑定（`patches/nullmoth-1.15.0/per-fix/sampler1-threejs-shadow.patch`，已包含在 `0002` 里）。
- 验证：`hidpi/catest/sarray1.m`（ANGLE 同款结构：单元素纹理/采样器数组经结构体指针传给不内联的 helper；nearest 取到 texel 0、linear 混合 0 和 1 才算 PASS）+ `sarray.m`；
  本机 3008 个缓存着色器新旧对比，只有这一个变化（失败 → 能翻译）。

---

### 38. Core Animation 的 uber shader 特化要 3.3 秒（翻译器）+ 图标字形变黑的陷阱
- 现象：窗口服务/Core Animation 的 `fixed_frag_*` 每个变体冷编译约 3.3 s，超出 CA 的预算，CA 在该进程里退回通用路径（冷/热对比几乎没差别）。
- 根因：`fixed_frag_*` 用静态初始化器里的函数常量构造 `FragmentShaderConfig` 结构体，再经 `select(has_config, @config, buffer)` + `getelementptr` 读取，这些字段读取从来没被折叠 → 每个“特化”变体其实是整个 684 KB 的 uber shader。
- 修复：翻译器把这些聚合字段读取折叠掉（`meta::static_init_foldable_aggregates` + LlModule 的聚合镜像）：684 KB → 19–24 KB，3.3 s → ~0.5 s；通用变体 3.0 → 2.45 s。289 个捕获的翻译里 280 个逐字节相同，其余 9 个（`fc_generic 0` 的 fixed_frag）都通过 `spirv-val`。
  测试：`hidpi/catest/fcbench/`（捕获 + 重放工具）。
- ⚠ 相关陷阱（`[[visible]]` 函数引用）：函数常量关掉之后仍然活着、又没被提供的 `[[visible]]` 引用，翻译器必须报“visible function reference”这个固定措辞——插件把带这个措辞的失败推迟到管线创建时用链接函数解决。
  中间版本换了措辞，RenderBox 的自定义片元全部返回 nil，系统所有图标字形变黑。`hidpi/catest/iconfc.m` 检查：0 个 nil，8/8 条 `custom_fn` 管线链接成功。
- 2.3.7 里还有 `ce133bf`：单字段结构体的 alloca 不再按字段类型重新解释。

### 39. Apple OpenGL 程序（NSOpenGLContext）：挂起、掉帧、整数纹理读错（插件）
- 2.3.6 把 Apple GL-on-Metal 的绘制路径带进了 NullMoth：深度偏移、provoking vertex、逐实例步进、primitive restart、texel-buffer 视图等。我们在其上有三处自己的修复：
  1. **IOSurface use count 从 commit 持有到完成，而不是从 encode**：不然每个带窗口的 `NSOpenGLContext` 程序在第一次 `flushBuffer` 就挂住。
  2. **GL 的垂直同步等待要等到窗口服务器“取走上一帧”，不只是到 vblank**：WindowServer 取走帧比 vblank 晚 0.4–2.7 ms，不等的话 165 Hz 的窗口 GL 跑到约 200 fps，其中每隔一帧被无声丢掉；现在约 152 fps、0 帧被替换。
  3. **整数纹理**：反射把每个纹理都当 Float，Apple 的 GL 于是把 `R8Snorm/R8Unorm` 视图绑到 `isampler/usampler` 上读出浮点位。现在 `textureDataType` 按翻译器的 `texture_shape` 回答 Int/UInt，`textureType` 按其字段，texel-buffer 视图里等于格式自带填充的 swizzle 当作恒等（不是 nil）。
- 测试：`hidpi/catest/gl236/`（`glfeat` 6/6、`itex` 7/7、`glvsync`：fps ≤ 显示器 Hz、`glbench`）；`glvsync-ab.sh` 是交错 A/B（新旧插件各取最好一次，桌面负载高时有 BUSY 重试）。

### 40. WindowServer GPU 标记：截图黑、Dock 缩略图空白、锁屏黑（插件 + 2.3.7 内核）
- 现象：在 WindowServer 的合成还在 GPU 上跑的时候，截图 / 锁屏 / 缩略图去锁 IOSurface，读到上一帧甚至没画完的帧。
- 修复：内核侧（NVAccel，2.3.7 自带，`debug.nvaccel_surface_gpu_marks`）接受标记；插件侧（NullMoth `79f47d0` / `e75be1e` / `40daaa6` 的插件部分）：在 WindowServer 里，命令缓冲渲染的每个表面在 commit 时标成 pending，最后一个写它的部分结束后标 ready（`NVRM_SS_PLANE_GPU_MARK`，重新标记用 TRYLOCK），
  共享显存在 commit 时标成最新，于是抓屏的锁会等 GPU；`commitAndWaitUntilSubmitted` 不再等完成（交换由 NVAccel 等）。
- 测试：NVAccel 只接受进程名为 `WindowServer` 的标记——把测试程序复制成名叫 `WindowServer` 的文件（只 `setprogname` 不够）：`hidpi/catest/wsmark.m`（capture 24/24 正确，旧版 0/24；合成循环 305 → ~390 fps），`hidpi/tests/check-wsmark.sh` 开机后核对（屏幕上 164.7 fps）。
  `plugshim` 现在也读 `SHIM_PLUGIN`（发行版插件会清掉 `NVMTL_*` 环境变量，子进程拿不到 `NVMTL_TEST_PLUGIN`）。
- 已知：非 WindowServer 的普通程序在 commit 后立刻 `IOSurfaceLock` 仍可能读到上一帧（上游相同）。开机后 5 分钟内看到过个位数次 GPU 等待超时（约 100 ms 上限），之后持续平稳，原因未查清。

## 四、Chrome / Electron 的 GPU 合成

### 5. 让 Chrome 走 GPU（ANGLE-Metal + NVK 沙箱）
Chrome 与 Chromium 系应用默认 `--use-gl=disabled`，软件合成，导致 WindowServer 大面积同步上传。两个拦路点：
1. ANGLE 的 `disableMetalOnNvidia`（为老 Kepler 驱动设计）。环境变量 `ANGLE_FEATURE_OVERRIDES_DISABLED=disableMetalOnNvidia`，用 LaunchAgent 里 `launchctl setenv` 设置；或 `--disable-angle-features=disableMetalOnNvidia`。
2. GPU 沙箱拒绝 `file-write-data /dev/null`，而 NVK 的 `nvrm_xnu_open` 为占位 fd 调 `open("/dev/null", O_RDWR)`，沙箱起来后所有 NVRM 连接失败。另外沙箱拒绝 `hw.pagesize`，Mesa 的 `os_get_total_physical_memory` 得到 -1。
   - 修复：`libvulkan_nouveau.dylib` 2 字节补丁（open 标志 `0x1000002 → 0x1000000`，即 `O_RDWR|O_CLOEXEC` → `O_RDONLY|O_CLOEXEC`，偏移 1.0.10 为 0x12bfc8 / 0x12c0db），并把 `os_get_total_physical_memory` 重写成 `sysctlbyname("hw.memsize")`。
   - 脚本：`codec-vulkan/vulkan/vk-devnull.sh`、`vk-bindfix.sh`、`mk-bindfix.py`；1.9.0 版本的偏移用 `mk-bindfix-190.py` 重新推导。
   - 用 1.14.2 补丁集（含第 27 项的插件兜底）时，`hw.memsize` 改写不再需要，用 `mk-nomem-190.py` 去掉它；`/dev/null` 的只读补丁保留。
   - **1.15.0 的原版 NVK 不再需要任何补丁**：上游已改为只读打开 `/dev/null`（e4d8ca8），解绑后再回收描述符池（我们的 bindfix）上游也修了（bee05d1），内存大小由插件兜底。
- 调试备忘：往 Chrome 里 `DYLD_INSERT_LIBRARIES`，库必须 ad-hoc 签名，未签名的会被静默忽略（本机 AMFI 已关；默认的 hardened runtime 下根本注入不了）；GPU 进程从 `/tmp` 加载插件还会被沙箱挡（见 pitfalls）。
- **Chrome 的 flags**：本机上 Graphite 与 GPU 栅格在早期构建下都渲染错误（半个四边形全黑 / 曲线路径缺失）。翻译器修复（第 9、13 项）和插件修复之后，作者现在 GPU 栅格和 Graphite 都开着（`#enable-gpu-rasterization`、`#skia-graphite` 均为 Enabled）。排错时的稳定组合仍是 `chrome://flags` → `#skia-graphite` Disabled，必要时 `#enable-gpu-rasterization` Disabled。
- Electron 应用也会吃到这个环境变量；有问题时 `launchctl unsetenv ANGLE_FEATURE_OVERRIDES_DISABLED`。

### 27. Firefox 没有硬件加速（GPU 沙箱连读 `/dev/null` 都不允许）
- 现象：Firefox 的 WebGL、合成全是软件渲染，`about:support` 里没有 Metal 设备。
- 根因：Firefox 的 GPU 进程沙箱（`SandboxPolicyGPU.h`）比 Chrome 更严，连 `file-read` `/dev/null` 都拒绝，第 5 项把 NVK 的占位 fd 改成只读打开仍然失败；
  同时 `sysconf(_SC_PHYS_PAGES)` 需要的 `hw.pagesize` 也被拒绝。
- 修复：回移植上游 1.14.5 / 1.14.6 的插件兜底——连 `/dev/null` 都打不开时用一根管道的读端当占位 fd；物理内存大小改由插件用 `host_info` 回答（重绑 `sysconf`）。
  因此 NVK 不再需要我们的 `hw.memsize` 改写：`codec-vulkan/vulkan/mk-nomem-190.py` 把那段恢复成原样。**两者必须一起换**：旧插件配新 NVK，在 Chrome 沙箱里会拿不到设备（“Failed to query total system memory”）。
- 1.15.0 起上游已包含这两处（原版插件 + 原版 NVK 即可，本仓库的 1.15.0 补丁集也保留着它们）。
- 测试：`hidpi/catest/ffsandbox.m` 用 Firefox 的沙箱规则启动 Metal blit + CGL 清屏并回读（需要自己从 Firefox 源码导出 `SandboxPolicyGPU.h` 的规则存为 `ffsandbox-gpu.sb`，MPL 代码不随本仓库分发）。旧组合 0/2，新组合 2/2。

---

### 36. WebGL 3D 页面 GPU 慢：打开 ZCULL（层次 Z 剔除）
- 现象：three.js 象棋页（3200×1594 画布、4x MSAA、阴影、8 盏灯、312 次绘制）只有 45–55 fps，GPU 每帧约 11.6 ms。
- 根因：ANGLE 在非 Apple GPU 上的 MSAA WebGL 里，**每个片元着色器都写 `sample_mask`**。NVK 上写 sample mask（或 discard）的着色器没有提前深度测试，被挡住的片元也会被完整着色，
  只能靠 ZCULL（层次 Z）在着色前剔除。Mesa 26 的 NVK 本来就有上游 zcull，但 NullMoth 的 NVRM 后端把 `has_zcull_info` 写死为 false，ZCULL 从来没开过。
- 修复（NVK 二进制补丁，作用于所有 Metal 程序）：`codec-vulkan/vulkan/mk-zcull-115.py` 把那处赋值换成一段代码：用 `NV2080_CTRL_CMD_GR_GET_ZCULL_INFO` 向 RM 取信息并填好（RM 的参数恰好是 nouveau 那个结构的前 10 个字段）。
  上下文的 zcull 缓冲后端本来就绑定了。在 `nvrm610.conf` 写 `ZCULL_RGN=0` 可关闭。
  `sudo zsh codec-vulkan/vulkan/vk-zcull.sh install` 从你装着的原版 1.15.0 NVK（`403d4d40`）生成并安装（不分发二进制；以原文件名 ad-hoc 签名后与作者的构建 `c866c85d` 逐字节相同），`restore` 恢复。
- 结果：`hidpi/catest/earlyz.m`（写 sample mask、被挡住的重着色器 pass）2.98 → 0.06 ms；象棋主 pass 4.4 → 2.4 ms，整帧 GPU 11.6 → 7.2 ms，页面约 65–74 fps。
  `hidpi/catest/rtcheck.m`（MSAA 颜色/深度、resolve、跨 pass 读回、阴影比较采样、深度拷贝、模板）和全部回归测试新旧一致。
- 限制：插件的深度图像带 `TRANSFER_DST`，NVK 不给它们单独的 zcull 平面，所以只在深度 `loadOp` 为 CLEAR 的 pass 里生效（这正是插件不读回深度时的默认）。
- 还能做什么（未做，已存档）：MSAA 颜色/深度压缩。插件从不用 dedicated 分配，NVK 只压缩 dedicated 分配；小测试里 4x + D32S8 11.9 → 3.1 ms。
  象棋这一帧在 Chrome GPU 进程里是串行的（等 GPU 约 9.5 ms + 编码约 3 ms），GPU 每省 1 ms 帧时间就少约 1 ms，估计 74 → 80–95 fps。但要走这个移植上没验证过的压缩内存路径，暂未做。

---

## 五、视频编解码（二进制补丁，NullMoth 只发布二进制）

共同根因：NullMoth 的编解码器是在 **Blackwell** 上做的，Ada（RTX 40）的 NVENC/NVDEC 用的是 **t2d GOB 布局**，而代码按 bw8（亮度）/bw16（色度）块布局读写。

这些字节补丁都针对 **1.9.0 的二进制**。作者在 1.15.0 下仍在用这几个基于 1.9.0 的补丁版编解码库（`nvguard/` 会放回去）；1.15.0 安装包自带的 `libnvdec_h264*.dylib`、`libnvenc_h264.dylib` 与 1.9.0 不同，未评估，脚本也不认它们。

### 14. NVDEC H.264 竖条纹
- `libnvdec_h264.dylib` 的 `emit_picture` 以 mode 1 调 `nvd264_detile`（`mov $1,%edx`，0x163d）；Ada 写出的是 mode 0。**0x163e 处 `01 → 00`** + ad-hoc 重签名。
- 亮度 PSNR：补丁前 17.5 dB，补丁后 480p/720p/1080p/2160p 逐比特一致。HEVC NVDEC 本来就是 t2d，无需改。
- `codec-vulkan/nvdec/nvdec-t2d.sh install|restore`；测试程序 `dectest.swift <dylib> [W H]`（进程内寄存器、与 Apple 软解对比）。
- **1.13 起的插件在非 Blackwell 卡上加载的是 `libnvdec_h264_t2d.dylib`**（上游给 mode 0 解码器起的名字），而它从来没被安装 → H.264 硬解**根本没注册**（`hidpi/catest/vtreg.m` 检查）。
  把我们的 t2d 构建以这个名字放进去（`nvguard/` 会补上缺失的文件）。
- **速度**：
  - `nvd264_detile` 每次循环只拷 1 字节：`mk-detile8.py` 改成 8 字节，4K 每帧 26.8 → 12.6 ms，1080p 6.3 → 2.8 ms，逐比特一致。
  - `decode_pending` 在 `clock_gettime` 上自旋整个解码过程：`mk-sleep.py` 改成像 HEVC 解码器那样每 50 µs `mach_wait_until` 一次，
    每帧 CPU 4K 8.0 → 3.7 ms、1080p 2.45 → 0.86 ms，耗时不变、输出逐比特一致（`decbench.swift`）。安装/回滚：`codec-vulkan/nvdec/nvdec-sleep.sh`。

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
- **1.15.0 内核扩展**：上游 NVRMFB 自带同样设计的背光（`NVRMBacklight` 处理器，NVRM 里由 `nvkms_xnu_backlight` 注册），所以不再需要 `0004`。
  NVDSM 检测到 NVRM 导出 `_nvkms_xnu_backlight` 时就**不再接管** `nvkms_(un)register_backlight`（否则上游 NVRMFB 拿不到背光），`_DSM`/`_DOD` 仍由 NVDSM 提供（上游要 `nvrmacpibl=1` 才开自己的）。配 1.9.0 的 NVRM 时行为不变。
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
- **bluetoothd 崩溃循环（BTLEFix 1.0.8 修好）**：蓝牙突然“关闭、打不开”，`system_profiler` 里 Address 为 NULL，内核日志里每约 10 秒一次 `apfs_pagein_with_verification: Cannot read data for compressed inode … Bad message(94)` 然后 `crashed: bluetoothd`，直到 launchd 放弃。
  根因：BlueToolFixup 和 BTLEFix 都钩 `_cs_validate_page`，**直接改写 `/usr/sbin/bluetoothd` 在统一缓存（UBC）里的页**。内存压力大（压缩器 ~10 GB、120 万次 swapout）时被改过的页被换出，APFS 密封卷重新读入压缩数据时校验失败（失败的 16 KB 块正好是补丁所在的块）；
  `codesign --verify /usr/sbin/bluetoothd` 也会报“invalid signature”，其它系统二进制都正常。
  修复（`wifibt/BTLEFix/`，设计见 `PLAN-private-patch.md`）：BTLEFix 1.0.8 在 `task_set_main_thread_qos` 之后对 bluetoothd / BlueTool 进程做**私有写时复制补丁**，文件页保持原样；BlueToolFixup 的补丁也搬进来，BlueToolFixup 用 boot-arg `-btlfxoff` 关掉（`efiguard` 把它列为必需 boot-arg）。
  验证：`debug.btlefix_cow` 显示 `code 6/6 patched … 0 failed`；`codesign --verify` 通过；`stress-v6.sh` 连续 10 次重启 bluetoothd 都是 6/6、无 `apfs_pagein` 错误；一次定时睡眠后蓝牙正常。
  安装 `sudo bash wifibt/BTLEFix/install-v6.sh`（先备份、改 ESP 的 boot-args 并重启），检查 `check-v6.sh`，回滚 `rollback-v6.sh`。pattern 随 macOS 版本变，`verify_private_patch.py` 可离线核对。BTLEFix 的 `candidateProcess()` 要精确匹配进程名，前缀匹配会误伤 `bluetoothuserd`。
- **macOS 26**：Wi-Fi 用 AirportItlwm 的 Tahoe 构建（同一份 laobamac `d695c97` + 下面的初始化自愈补丁，按 Tahoe 方案编译），作为 `config.plist` 里的第二个条目（`MinKernel 25.0.0`；Sequoia 条目 `MaxKernel 24.99.99`），
  OpenCore 按内核版本注入对应的那个（`tahoe/prep-efi-26.sh`）。蓝牙：26 的 bluetoothd 是同一段代码，只是第一个位移从 0x49 变成 0x69，BTLEFix 1.0.6 两种都打。
  BTLEFix / NVDSM 的 Lilu 最高内核版本要放到 Tahoe，否则 Lilu 在 26 上直接跳过它们。BTLEFix 1.0.6 还兼做 macOS 26 声卡的资源请求应答（第 33 项）。

- **开机偶发一直“未连接”（在上面原生 Wi-Fi 基础上的稳定性修复）**：
  - 不是运行中掉线，而是有的开机 `en2` 从没起来（`ifconfig en2` 有 `UP` 没 `RUNNING`），手动开关 Wi-Fi 才好。
  - 根因：驱动未就绪（`isDriverAvailable=0`）时 IO80211Family 把外部 `SIOCGA80211` ioctl 挂在**共享的 work loop gate 里** 4–9 s，固件 ALIVE 中断要同一个 gate，冷加载被拖到 5–11 s；而 ALIVE 预算只有 1000 ms、只重试 1 次。失败后 `IFF_UP` 被清、`DriverAvailable=0`，但 `power_state` 仍为 1，airportd 不会再上电，于是一直卡着。
  - 修复（`patches/itlwm/0001-AirportItlwm-init-recovery.patch`，基于 laobamac/itlwm `d695c97`）：ALIVE 预算 15 s（成功即返回）、3 次初始化尝试、在原有 1 Hz watchdog 里“上电但没 RUNNING 就经 command gate 重新 `enable()`”（3 s 起、退避到 60 s，永不放弃；`IFF_UP` 挂 30 s 没 RUNNING 则先 `disable()`）。保留 Wi-Fi 6（`itlwm_he=1`）。
  - 安装：自己编译 kext → `wifibt/replace-airportitlwm.sh`（备份 + 读回校验 + `undo`）。细节、编译命令、排查过程见 [wifibt/initrec/README.md](../wifibt/initrec/README.md)；开机日志抓取工具 `tools/wifi-bootlog/`。上游同类问题 laobamac/itlwm#19。

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

### 24. 内置麦克风与扬声器（Realtek ALC256 + AppleALC）
- 现象：系统里没有内置输入/输出设备，只认 USB 音箱。Lilu 已加载但没有 AppleALC，音频控制器（`8086:51ca`）上没有任何驱动绑定。
- 确认编解码器：别猜。这台机器的 Windows 分区里 `Windows\INF\setupapi.dev.log` 有 `INTELAUDIO\FUNC_01&VEN_10EC&DEV_0256&SUBSYS_155825E1`，即 **ALC256**，
  子系统 ID `1558:25E1`（Clevo）。控制器类码 `0x040380`（DSP 模式）也能被 `AppleHDAController` 绑定，不需要改类码。
- 修复：AppleALC 1.9.8（Lilu 插件，二进制不随本仓库提供，见 `audio/SOURCE.txt`）+ boot-arg `alcid=11`。11 是 Dell 7559 的 ALC256 layout（双喇叭 + 耳机口），在这台机器上可用；
  ALC256 一共有 30 多个 layout，别的机器要逐个试。`audio/apply-alc.sh [layout]` 修改 ESP 的 `config.plist`（`Kernel/Add` + `boot-args`），先备份，可重复运行换 layout，`revert-alc.sh` 回滚。
- 验证：重启后 `system_profiler SPAudioDataType` 出现 Built-in Microphone / Built-in Output。默认输出设备会保持上次使用的（USB 音箱），需要在系统设置里手动切一次。
- 踩坑：PlistBuddy 在**一次调用里连续多个 `-c`** 往数组末尾 `Add dict` 再 `Add` 字段时，新元素会变成上一个元素的副本（报 "Entry Already Exists"）；每条命令单独调用一次就正常。
- **macOS 26** 删掉了 AppleHDA，AppleALC 无从下手，见第 33 项。

---

### 37. 系统睡眠（S3）：NullMoth 2.3.7 内核能挂起/恢复 GPU
- 背景：1.15.0 及以前的 NVRM 没有 GPU 挂起/恢复，唤醒后 GPU 读出 `0xbadf5620`、“GSP core unresponsive”、Xid 119，屏幕不亮（见 docs/pitfalls.md 旧条目）。作者因此一直 `pmset SleepDisabled 1`。
- 上游自 2.0.3（PR #182）加了 S3：RM standby（`PreserveVideoMemoryAllocations=1`，显存放进可换页的内核内存）、唤醒后恢复 PCI / ReBAR / 根端口窗口、NVRMFB 做 IOGraphics 的 DidWake 工作、NVAccel 的粘性显存。
  2.3.7 内核里全有，**但 boot-arg `-nvrmnopm` 会把它关掉**（`ioreg -rn NVRM | grep nvrm-pm` 显示 `off (-nvrmnopm)`）。
- 这台机器的做法（`kexts/sleep/`）：`enable-sleep.sh` 从 ESP 的 `config.plist` 去掉 `-nvrmnopm`（并刷新 efiguard 快照；hibernatemode / powernap / proximitywake 设 0），重启后 `check-sleep.sh` 核对（`nvrm-pm = running`），
  `sleep-test.sh` 做**一次带定时唤醒的睡眠**（带启动守护和证据报告）。第一次测试通过：RM standby 6.1 s、恢复 4.5 s、2500 MB 显存保留、WindowServer 进程不变、无 panic。`rollback-sleep.sh` 全部撤销（放回 `-nvrmnopm`）。
- 常驻开关：`sleepguard/`（LaunchDaemon，开机 + 每 10 分钟）。只有“你想要睡眠 **且** 没有 `-nvrmnopm` **且** `nvrm-pm = running`”时才让 `SleepDisabled 0`，其余一律 1（包括回滚到旧内核扩展、恢复失败）；并强制 `hibernatemode 0`。
  `nvguard/verify.sh` 多了“system sleep”一节：允许睡眠而 GPU 不能恢复时报 DANGER。
- 没测过：合盖、电池、长时间睡眠、休眠（hibernate）。笔记本面板/背光在唤醒后的表现上游也没测过；作者选择只用合盖/苹果菜单睡眠，不开空闲睡眠。**每台机器自己小心试，先备份。**
- 适用：内核必须是 2.3.7（或带 PR #182 的版本）。

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
- 验证：作者本机编译安装后重启，HiDPI@165Hz、零拷贝计数、亮度、显示器休眠唤醒均正常（系统睡眠见第 37 项，需要 2.3.7 内核）。内核扩展安装有重启和黑屏风险，先备份并准备恢复模式回滚。
- 1.15.0 的 NVRMFB 本身就是这个做法，不需要 `0005`。
- 后续（作者的 1.15.0/2.3.7 NVRMFB）：翻转等待改成睡在“翻转已发生”事件上（原来 `IOSleep(1)` 轮询），光标放到 thread call 里应用、移动只发位置（移植上游 `dcc8a69` 的 fb 部分、2.3.6 的光标改动），`flip_latch` 计数器恢复工作；
  165 Hz 屏上光标 81 → 165 fps，拖窗口 87 → 101 fps（拖窗口的上限在 WindowServer 的合成等待，不在翻转路径）。旋钮 `debug.nvrmfb_flip_wake`、`debug.nvrmfb_cursor_async`（0 = 旧行为，同一次开机内可 A/B）。2.3.7 内核里已包含。

### 31. 微信输入法开机后在自启应用里打不了字
- 与驱动无关，但每次开机都会碰到。随登录自启的应用（Claude 桌面端、Steam 等）在 WeType 向 `imklaunchagent` 登记之前就来要它的端点，拿到 `NO Endpoint` 后**一直缓存**，
  只有这些应用打不了字；WeType 进程本身是健康的。只杀 `imklaunchagent` 反而更糟，必须连 WeType 一起重启。
- 修复：LaunchAgent 在登录时 `open -g` 先把 WeType 启动起来。**不能用 `open -j`**（隐藏启动）：那样候选词窗口不显示。详见 [tools/wetype/README.md](../tools/wetype/README.md)。

---

## 八、已排除：不是驱动的问题

- **窗口从 Dock 恢复（取消最小化）闪一下**：Chrome 只有 web 内容区变白 0.23 s；Finder 等是一帧“非活动”外观。A/B 排除了 GPU 进程崩溃、遮挡后台化、异步 surface-in、零拷贝翻转、`--disable-mac-overlays`、GPU 栅格。
  结论：macOS 13+ 已知的取消最小化问题（Apple 开发者论坛 801112，Chrome 在列）+ 浏览器在 WS 使后备失效后的重绘。只能用“最小化到应用图标”/“缩放”效果绕开。
- **Photo Booth 预览上下颠倒（但 FaceTime / QuickTime 正常）**：不是驱动问题。Photo Booth 用 `render:toMTLTexture:`（内部固定 `isFlipped=NO`）直接写 CAMetalLayer drawable；
  `CIRenderDestination.h` 规定 `isFlipped=NO` 时图像**最下面**一行放在内存第 0 行（Metal 纹理的第 0 行在顶部），Apple 自带的软件渲染器写位图时结果完全一致，
  而同族的 `toCVPixelBuffer` / `toBitmap` / `toIOSurface` 内部用 `YES`。逐层验证过：摄像头原始帧（各像素格式）、VideoToolbox 转换、Core Image 的 GPU 程序（翻转由主机侧传入的矩阵决定，纯 Apple 代码）、
  窗口合成（图层 `scale(1,-1)` / 旋转 / `isGeometryFlipped` 都正常）都是对的。**不要在插件里“翻转”Core Image 的输出**，那会让所有已正确处理朝向的程序一起倒过来。
- **B 站“骨架屏”等待**：站点数据加载，不是 GPU。
- **开机后的短暂卡顿（“等一会才流畅”）**：冷着色器缓存（以翻译器哈希为键），首次启动后自行恢复；曾因未持久化 `VkPipelineCache` 每次开机重编所有 NVK 着色器，已在 v47 修复（`pcache`）。

## 八（续）、试过但没有收益（未采用）

对象是“页面渲染了 N 帧，屏幕上只出现更少的帧”。**测量要看 WindowServer 实际上屏的帧数**（`hidpi/catest/danmaku/tools/wsframes.sh`，按 CoreDisplay 每次刷新的日志计数），不能只看 Chrome 的 rAF。
- **WindowServer 的 CPU 不是瓶颈**：`sample` 主线程，空闲 77% / 46% / 28%（无页面 / 轻页面 / 象棋），整个进程 0.2–0.4 个核；每帧 CA 合成 1.8–3 ms CPU，等 GPU 完成 1.4–3.9 ms，导入新表面约 0.3 ms，都在 165 Hz 的 6 ms 预算内。
- **WindowServer 翻转门控**（让 WS 的合成在提交后就返回，由内核在翻转前等写入完成）：做成了，但上屏帧数没有变化——瓶颈是多个进程在 GPU 上轮流使用时间片，而不是 WS 等待本身。
  ⚠ 第一版在开门控后第一次翻转就 kernel panic：`IOSurface::copyValue` 无条件往最后一个参数写 seed，传了空指针。回滚。
- **GPU 优先级**（RM 的 TSG interleave level / timeslice / GFXP 抢占）：合成测试里 WS 类负载延迟 4–7 → 1.2–1.8 ms，看起来很好；
  真实 Chrome A/B 里 WS 上屏只多 4–9%（在 ±20% 噪声内），页面自身慢 9–20%。不值得。（RM 610 这些控制是 NON_PRIVILEGED，GSP 接受。）
- **scheduled 回调改回“提交即触发”**（`NVMTL_SCHED_AT_COMPLETION=0`，有了第 26 项第 7 点之后重测）：轻页面上屏 126–150 → 96–143（噪声），象棋上屏 58–71 → **40–45**：
  Chrome 不等了，变成 WindowServer 在跨进程同步里等 Chrome 的 GPU。保持“完成时触发”。偶发的“提交成对、WS 丢一帧”（轻页面 115–150 波动）就是这个等待在某些相位下造成的。
- **GPU 频率**：不是问题。`hidpi/catest/rmclk.c`（只读 RM 客户端：当前 P-state + PMU 的频率采样）显示负载下 GPC 2580 MHz、显存 16 Gbps；`gpuclock.m` 实测 FP32 约 10 TFLOPS、显存拷贝 220 GB/s。
  另外发现 GPU 空闲时也一直在 P0（2100 MHz），不会降频——影响的是空闲功耗/发热，不是流畅度，尚未处理。
- 排查备忘：别在后台跑 `find /`——它会钻进 FSKit 挂载的 NTFS 分区，`UVFSService` 一跑就是一个核好几个小时，看起来像系统问题。

---

## 参考：内部版本演进（作者本机）

插件版本链：v46 → v47（持久化 pipeline cache）→ v48（合入上游 1.9.0：采样器负 LOD、`shaderDrawParameters`、GL zero-net、翻译器的 base_vertex/base_instance；260/260 缓存着色器逐字节一致）→ tiled 渲染影子 → selffetch → gl-sample-positions → 合入 1.13.0（compute stage_in、Unknown 用途、采样器数组）→ 合入 1.14.2（`d8aa6e31`）→ 暂存缓冲复用（`ac789120`）→ 提前提交（`3108990a`）→ 渲染影子复用（`4eb05cf4`）→ 沙箱兜底 + Unity 锁（`dbbc77ec`）→ 单次绘制开销（`93c3be14`）→ 合入 1.15.0（`133fa823`）→ VideoToolbox 回归修正（`e8328b6a`）→ tiled 纹理 mip 链（`b4041b08`）→ 跨进程 IOSurface 写入同步（`9952f874`）；翻译器：`761a54b4`（顶点输出）→ `eb4fb6a3`（Lanczos）→ `50471f26`（1.13.0）→ `aa11ce8d`（采样器数组）→ `f62a16e5`（1.14.2）→ `2a3e7ea7`（地址表合并）→ `70c04748`（1.15.0）→ `183ddb7c`（单元素采样器数组）。NVK：`d94ea1a3`（bindfix）→ `19bbfc23`（去掉 `hw.memsize` 改写）→ `403d4d40`（1.15.0 原版，无补丁）→ `c866c85d`（ZCULL）。
内核扩展：1.0.10 → 1.9.0 + 本仓库补丁 → 1.15.0 + 本仓库补丁（NVRM `9794974b`、NVRMFB `79d60d24`）→ 2.3.7 + 本仓库补丁（NVRM `61bc897f`、NVRMFB `5dec327c`）。
用户态：…→ 1.15.0 → 2.0.4 合并（插件 `ac5df567`→`302fa176`）→ 2.3.6 跟进 → 2.3.7 边界修复 → WindowServer 标记（插件 `1eae68fa`，翻译器 `ce980d35`）。
`nvguard/` 里记录的哈希就是这些构建的 sha256（你自己的构建哈希不会相同）。

## 九、1.13.0 用户态补丁集

`patches/nullmoth-1.13.0/` 是把插件和翻译器的本地修改重新整理到**上游 v1.13.0** 之上的差异（已验证可在原版 v1.13.0 上干净应用，应用后的插件和翻译器可编译，并通过 `hidpi/catest/` 里的回归程序）。和 1.9.0 版相比：
- 上游 1.13 已吸收的内容（视口深度夹紧等）不再出现在补丁里。
- 额外一处本地改动：1.13 只在 Blackwell 上注册 NVENC，Ada 上我们的 NVENC 补丁（修复 15）会被绕开，所以插件默认在所有 GPU 上注册，在 `nvrm610.conf` 里写 `NVMTL_NVENC_BLACKWELL_ONLY=1` 才恢复上游行为（1.14.2 版同样如此）。
- **没有**升级内核扩展。1.9.0→1.13.0 期间 NVRM 核心源码没有变化，变化的只有 NVAccel（无头 GPU、Intel 内置屏，仅用于面板不在独显上的笔记本）、NVRMFB（光标，已移植为修复 21；另有“多列出分辨率”，未移植）、新增的 NMIntelFB 与 NMHDA。对独显直连的机器升级没有收益，所以内核扩展仍以 1.9.0 为基线；若要升级，NVRM 与 NVK 的字节补丁偏移量需针对 1.13.0 的二进制重新核对。

## 九（续）、1.14.2 用户态补丁集

`patches/nullmoth-1.14.2/` 是插件和翻译器的全部本地修改整理到**上游 v1.14.2** 之上的差异（`0001-plugin.patch` 含 `build/build_plugin.sh`，`0002-translator.patch`）。
已验证：在原版 v1.14.2 上干净应用，应用后的源码与作者实际在用的构建一致（只有注释里的路径不同），插件可编译。
- 合并时的取舍：翻译器的 helper 发射顺序用上游的 raw-cursor 方案（取代第 13 项的“调用者优先”）；`begin_pass` 用上游的采样位置兜底（取代第 12 项）；
  blit 用上游的覆盖同步（#98）并保留我们的渲染影子；NVENC 仍在所有 GPU 上注册。
- **陷阱**：上游 wrapper 的 `apply_rsc` 默认把 `raster_sample_count` 设为 `Some(1)`，会绕过第 7 项的特化常量；补丁里改为只在插件给出采样数时才写死。
- `per-fix/` 是 1.14.2 之后各项的单独提交（`surfin-stage-reuse`、`eager-submit`、`rsh-park`、`upstream-sandbox-unity-backport`、`nvtrace-release`、`descriptor-table-reuse`、`translator-table-merge`），
  便于阅读；其中 `eager-submit`、`translator-table-merge`、`upstream-sandbox-unity-backport` 能单独打在原版 v1.14.2 上，其余依赖前面的本地修改，请直接用 `0001`/`0002`。
- 编译插件时要链接 `-framework IOKit -framework CoreVideo`（构建脚本已更新）。内核扩展仍以 1.9.0 为基线（`0003–0006`）。
- 上游 1.14.3–1.14.7 的其余改动（AM5 平台、复制路径闪烁、核显面板、ANGLE 自动开启等）对独显直连 + 零拷贝翻转的机器没有收益，未合入。
- ⚠ 这一套里的 `descriptor-table-reuse` 会让 VideoToolbox 的两遍缩放输出空白（第 29 项的回归），1.15.0 补丁集已修。

## 九（再续）、1.15.0 补丁集（当前推荐：用户态 + 内核扩展）

`patches/nullmoth-1.15.0/` 是全部本地修改整理到**上游 v1.15.0** 之上的差异：`0001-plugin.patch`（含 `build/build_plugin.sh`）、`0002-translator.patch`、`0003-nvrmfb-vram-noclear.patch`（内核扩展）。
已验证：在原版 v1.15.0 上干净应用，应用后的 `plugin/`、`build/`、`translator/`、`kexts/` 与作者在用的构建一致（只有注释里的路径不同），插件可编译（`-mmacosx-version-min=15.0`）。
`translator/translator/Cargo.lock` 不在这一套补丁里，用上游的即可。
- 从上游 1.15.0 合入/取舍：插件拿了 IOSurface 页面的流式读取（1baebac：写合并页面上的窗口拷贝最多快 35 倍；也用在我们自己的异步上传路径上）和 `sysconf` 重绑的边界检查（b25058b）；
  **没拿** bee05d1 的插件部分（每表面监视器、写映射、IOSurface 纹理缓存：v47 起同一表面已共享一个私有图像，而它会在每次 draw 的路径上多一把全局锁）。
  翻译器拿了“绑定采样器的 kernel 保留 threadgroup 内存长度”（2009ced：VideoToolbox 缩放输出整列为零 = “照片”里的绿线）和“缓冲类型重映射后保留阶段输出”（4b0a8c7，与第 9 项的 `type_def_of` 兜底合并）。
- NVK：1.15.0 原版 `libvulkan_nouveau.dylib` 不再需要第 5、27 项的补丁；唯一的改动是可选的 ZCULL（第 36 项，`codec-vulkan/vulkan/vk-zcull.sh`）。
- 内核扩展：NVRM = 1.15.0 + `kexts/patch-nvrm-115.py`（head-scaler + 启动即翻转，改动与 1.9.0 相同，代码后移 0x1590）；NVRMFB = 1.15.0 源码 + `0003`（`kexts/build-fb-115.sh`）；NVAccel、NVRMAGDC 用原版。
  上游 1.15.0 自带背光（第 17 项）和“光标只提交光标”（第 21 项），1.9.0 的 `0004`、`0005` 不再需要；另外上游修了 512 个 `nvSVPend` 槽位的泄漏（79e1c2f）。
  安装：`kexts/install-kexts-115.sh`（在 macOS 15 上；`--check` 只建测试内核集合，带备份，`rollback-kexts-115.sh` 回滚；脚本里的哈希是作者的构建，换成你的）。
  装后核对：165 Hz、1792×1008 HiDPI、亮度键与滑块、零拷贝翻转（`flip=1`）都在，`debug.nvrmfb_clear_skipped` 在增长。
- 1.15.0 是上游“最后一个支持 macOS 15 的版本”，安装包里同时带了 macOS 26 用的 NVAccel（`/Library/NullMoth/kexts/26`），升级到 26 见第十一节。
- 1.15.0 之后的本地修复：第 29 项的 VideoToolbox 回归修正、第 30 项、第 26 项第 7 点（跨进程写入同步，`per-fix/xsurf-sync.patch`）、第 35 项（`per-fix/sampler1-threejs-shadow.patch`）。`per-fix/` 是各自的单独提交，依赖前面的本地修改，请直接用 `0001`/`0002`。

## 九（又续）、2.3.7 补丁集（作者现在用的：用户态 + 内核）

**基线**：用户态补丁不是整个搬到 v2.3.7 上，而是 **v2.0.4 加上选择性合入的 2.0.x→2.3.7 改动**（作者按需挑，没有全吃）。所以 `patches/nullmoth-2.3.7/0001`、`0002` 打在**上游 v2.0.4**；`0003` 打在 **v2.3.7**。
已验证：`0001`（含 `build/`）、`0002` 在原版 v2.0.4 上、`0003` 在原版 v2.3.7 上 `git apply --check` 干净；没有重新编译验证（我们的构建是用同一棵树）。`Cargo.lock` 不在补丁里。
- `0001-plugin.patch`：插件。新增/变化（相对 1.15.0 一套）：2.0.x 的锁与资源集改动、完成的命令缓冲不排空池就释放、host-copy 纹理在每次提交时同步、MSAA 采样位置、`robustBufferAccess` + `imageCubeArray`、可选异步 `replaceRegion`（默认关）；
  **每个表面每进程只一次 VRAM 导入**，且表面写入守卫只跳过飞行中写入落到的那块存储（`catest/gfx4` 1/20–1/50 读到零就是这个）；2.3.6 的解码器注册（`VTDecoderXPCService`）、无附件的 pass / 分层 3D 目标、`[[color(n)]]` 经输入附件读取、A8 目标放红色通道；
  2.3.6 的 OpenGL 路径 + 我们的修复（第 39 项）；2.3.7 的边界检查（着色器位码 4 B–64 MB 之外不进进程内读取、位码读取器出错就拒绝该模块、argument encoder 的 `setBuffer` 偏移越界被拒、不能放进 32 位的纹理 region 被拒、区域检查改成减法）；WindowServer GPU 标记（第 40 项）。
  **没合**：`e57a132`（保留我们的 xsurf-sync）、`236f664`（Chrome 继续走 GPU）、RTX 50 专用的 `e12eaf3`/`a76b3c4`、`#263`、`#274` 的 CPU mip 填充（保留我们的 tiled-mips）。
- `0002-translator.patch`：翻译器。规划缓存、cube 数组 / 图像 select / `fcmp ord-uno`、循环出口 + 支配关系、向量 `fast_ldexp`、`bvec icmp`；**纹理/采样器数组每个元素一个描述符**（第 25 项）；`[[visible]]` 函数引用在函数常量关掉之后被收口（Spotlight、iconservicesagent、mediaanalysisd、DockHelper 用到的 122 个 MPS kernel 里 110 个）；
  A8 目标变体、原子图像格式 / `CopyLogical`、Blender、`resource_phi_fold`、`gep_provenance`、`stage_output`；Core Animation 函数常量折叠（第 38 项）；`ce133bf`（单字段结构体 alloca）。保留我们的表合并、sampler[1]、Graphite 输出、Lanczos 偏移、`get_num_samples`。
- `0003-nvrmfb-vram-noclear.patch`（内核）：2.3.7 的 NVRMFB 上，新显存抽样为零就不再 CPU 清零（RM 的拷贝引擎释放时已洗过显存；约一个核的 10%，弹幕时明显）；`debug.nvrmfb_clear_mode 0` = 总是清零（上游行为）。
- **NVK**：2.0.5（2.3.6 里带的 `a3a6451e`：发行版构建无 assert、Ada 的异步拷贝引擎做上传队列、NAK 模板导出）+ ZCULL。ZCULL 的脚本按版本分：`codec-vulkan/vulkan/mk-zcull-115.py`（1.15.0）、`mk-zcull-204.py`（2.0.4）、`mk-zcull-236.py`（2.0.5/2.3.6）。
- **内核**：NVRM = 官方 2.3.7 + `kexts/patch-nvrm-237.py`（head-scaler，按特征串匹配；启动即翻转已经是上游行为，不再补）；NVRMFB = v2.3.7 源码 + `0003`（`kexts/build-fb-237.sh`）；NVAccel 用官方 macOS 26 版，NVRMAGDC 用官方。
  安装 `kexts/install-kexts-237.sh [--check]`（只建测试内核集合；带备份；在 macOS 26 上；需要 `ESP_UUID`），回滚 `kexts/rollback-kexts-237.sh`（只拷文件，恢复模式里也能用）。脚本里的哈希是作者的构建，换成你的。
  boot-args：`nvfbhidpi=1`（缩放的 HiDPI 模式**必须**）、`nvrmmapowner=0`（map-owner 检查只计数；几天没有 `MAP-OWNER-MISMATCH` 就可以去掉）、`-nvrmnopm`（想要睡眠就别加，第 37 项）。`kexts/build-nvrm-from-source.sh`：NVRM 也能从源码编（与官方 2.3.7 只差 RM 编译器的代码生成），用来交叉核对 head-scaler。
- 测试：`hidpi/catest/` 新增 `secreg`（2.3.7 边界回归 7/7）、`sarraydyn`、`a8target`、`fetchpart`、`tiledmipsown`、`iconfc`、`gl236/`、`fcbench/`、`wsmark`、`wincap`。`gfx4` 现在只在生产者仍需要信用时发信用、忽略 SIGPIPE、失败时打印第一个不同的像素。
- 守护：`nvguard/install.sh` 记录这一套的哈希和逐步回滚别名（`previous`、`wsmarkprev`、`sec237prev`、`fcfastprev`、`itexprev`、`gl236`、`m236gl`、`m236xlate`、`m204prev`、`zcullprev`），`NVMTL_RES2_WS=1`（2.3.6 默认：Metal 报告整块显存为工作集）；
  `efiguard` 守护 `nvfbhidpi=1 -nvrmnopm nvrmmapowner=0`（只记录安装时已存在的）。

## 十、ESP 守护（efiguard）

nvguard 只守护 `/Library` 下的驱动文件；**OpenCore ESP 上的修复**（AppleALC 与 `alcid`、Wi-Fi/蓝牙/NVDSM/BrightnessKeys/VoodooI2C 的 kext、`SSDT-PS2KEYS`、关键 boot-args）另有一个 `efiguard/`：
- `install.sh` 把 `EFI/OC` 的 `config.plist`、`Kexts`、`ACPI`、`Drivers` 拍快照放进 `/Library/NullMoth/efiguard`（`chflags schg`），并注册 LaunchDaemon（开机 + 每 6 小时）。
- 只修**缺失**或**丢了我们的修复**的东西：文件不见了就补回；`Kernel/Add` 条目被删/被禁用就按快照补回/重新启用；`alcid=`、`nvfb=1`、`nvaccel=1` 等关键 boot-arg 丢了就补回。
  只有 `Lilu` 条目没了或 `config.plist` 不可用时才整份恢复。**仅仅与快照不同的文件**（可能是你有意升级）只记录 `ATTENTION`，不回退。被替换的文件先复制到 `/Library/NullMoth/efiguard-replaced`。
- ESP 已被别人挂载时不会卸载它（只读检查，推迟修复）；不碰 `OpenCore.efi`、引导器和启动项。
- 有意改过 EFI（`apply-*.sh`）之后要重跑 `install.sh` 刷新快照。日志 `/var/log/efiguard.log`，`nvguard/verify.sh` 里有对应的检查项。
- 测试方式：设 `EFIGUARD_ROOT`（一个含 `EFI/OC` 的目录）和 `EFIGUARD_SNAP`、`EFIGUARD_TEST=1` 就能在 ESP 的副本上演练，不碰系统。
- **按分区 UUID 找 ESP**（`ESP_UUID`）：盘号偶尔会变（两块 NVMe 的识别先后不固定，见第 32 项），写死的盘号会让守护去查错盘或直接停下。
- macOS 26：也守护 `-no_compat_check`、`revpatch=`（没有它们 26 开不了机 / 收不到更新）；救援配置生效时（`EFI/OC/rescue/ACTIVE`，第 32 项）完全不碰 ESP。

## 十一、macOS 26（Tahoe）

macOS 26 专用的脚本都在 [`tahoe/`](../tahoe/README.md)。作者本机：macOS 15.8.1 → **26.7.1**，SMBIOS 仍是 iMacPro1,1，驱动是 NullMoth 1.15.0 + 本仓库补丁。

### 32. 升级到 macOS 26（保留 iMacPro1,1、驱动停放、首次启动收尾、救援）
- **机型**：26 不再支持 iMacPro1,1。上游的安装器给新装的机器用 MacPro7,1（15 和 26 都能装），但**不要**在已经装好的 15.8.1 上直接改成 MacPro7,1（有报告称会启动循环）。保留 iMacPro1,1，
  加 RestrictEvents 1.1.6 + boot-arg `-no_compat_check`（让 26 在不支持的机型上启动）+ `revpatch=sbvmm`（让“软件更新”给这台机器推送 26）。这两个 boot-arg 之后**一直需要**。
- **第一步，在 15 上**（`tahoe/prep-efi-26.sh`，只做 15 和 26 都能用的 EFI 改动）：RestrictEvents、两个 boot-arg、AirportItlwm 的 Tahoe 条目（第 18 项）、
  NVDSM / BTLEFix 的 Lilu 最高内核版本放到 Tahoe。改完先重启回 15，检查 Wi-Fi、蓝牙、亮度、声音。撤销：`revert-efi-26.sh <备份>`。
- **第二步，开始升级之前**（`tahoe/update-26.sh prepare`；思路与上游 1.15.0 的 `nullmoth-setup.sh --update prepare|finish` 相同，但针对打过补丁的驱动和我们的 EFI）：
  驱动“停放”（`-nvoff`，画面走固件帧缓冲），换成安装器需要的屏幕设置（`ResizeGpuBars -1`、`ResizeAppleGpuBars 0`、关掉对 IONDRVSupport 的屏蔽），并装一个 LaunchDaemon。
  升级后第一次进 26，它自动执行 `finish`：NVAccel 换成 1.15.0 安装包里的 macOS 26 版（`/Library/NullMoth/kexts/26`），重建辅助内核集合（四个 NullMoth kext 必须都在），
  EFI 设置改回原样，重启一次。任何一步失败都保持停放状态并写日志（`/Library/NullMoth/tahoe/update.log`）。不升级了：`update-26.sh cancel`。
- 升级需要约 30–40 GB 空闲空间。
- **救援**（`tahoe/install-rescue.sh`，用法见 [`tahoe/RESCUE.md`](../tahoe/RESCUE.md)）：在 ESP 上放 `EFI/OC/rescue/`。`rescue.sh safe|restore|status` 只用 `sh`/`cp`/`cmp`，
  在 macOS 恢复模式的终端里就能跑；`config-safe.plist` = 当前配置 + 驱动停放 + 安装器屏幕设置 + 关掉我们自己/新加的 4 个 kext（AirportItlwm-Tahoe、BTLEFix、NVDSM、RestrictEvents）。
  生效期间 efiguard 和 `finish` 都不碰 ESP。有意改过 `config.plist` 后重跑 `install-rescue.sh`，让 `config-safe.plist` 跟上。
  **别用升级前的 EFI 备份救 26**：它没有 `-no_compat_check`，26 开不了机。
- **恢复模式入口**（`tahoe/add-ocrec.sh`，适用于用 Limine 引导 OpenCore 的布局）：把 `EFI/OC` 复制成 `EFI/OCREC`（同样的 kext / ACPI / boot-args，26 仍能启动），
  把副本的 `config.plist` 设成立即显示 OpenCore 选单（`ShowPicker`、`Timeout 0`、`HideAuxiliary false`），并在 Limine 菜单里加一项 “macOS Recovery”。`EFI/OC` 本身不变；`add-ocrec.sh undo` 撤销。
- **ESP 的盘号偶尔会变**：这台机器有两块 NVMe，macOS 按识别先后编号，先后不固定。系统日志里 20 次开机，19 次 ESP 是 `disk1s4`（装 macOS 的盘先出来，Windows 盘约 20 秒后出现，成为 disk0），
  1 次是 `disk0s4`（两块几乎同时出现，装 macOS 的盘拿到了 disk0）。平时的 `disk0s4` 恰好是 Windows 盘上的“Windows 恢复”分区，写死盘号很危险。
  仓库里所有改 ESP 的脚本都按分区 UUID（`ESP_UUID`）找 ESP，不再用盘号。查自己的机器：`log show --predicate 'process == "diskarbitrationd" AND eventMessage BEGINSWITH "created disk"'`。
- 升级后检查：Wi-Fi、蓝牙、亮度、声音（第 33 项）、电源（第 34 项）、HiDPI@165Hz。系统睡眠只有 2.3.7 内核才有，见第 37 项（1.15.0 上不要睡）。

### 33. macOS 26 没有内置声卡（AppleHDA 被移除）
- 现象：升级到 26 后内置扬声器 / 麦克风消失。AppleALC 照常加载，但它是给 AppleHDA 打补丁的，而 **26 把 AppleHDA.kext 从系统里删了**。
- 修复（`tahoe/audio/install-hda26.sh`）：把 **macOS 15.7.9 KDK**（dortania KdkSupportPkg `24G830`）里的 AppleHDA 放进 `/Library/Apple/System/Library/Extensions`，
  重建辅助内核集合。**不碰密封的系统卷**，macOS 更新后 kext 还在（只是重新链接）。逐个踩过的坑：
  1. Tahoe beta 1 KDK 里的 AppleHDA：编解码器挂上了，`AppleHDADriver` 却永远不启动。换成 15.7.9 的（AppleALC 1.9.8 也是按它验证的）。
  2. `kmutil` 默认不把第三方目录里 Apple 前缀的 kext 放进辅助集合，要用 `-b` 逐个点名（AppleHDA、AppleHDAController、AppleHDAHardwareConfigDriver、DspFuncLib、IOHDAFamily）。
  3. 放在 `/Library/Extensions` 时，`kernelmanagerd` 拒绝为它建资源查找表（`Cannot insert Kext com.apple.driver.AppleHDA … into a restricted lookup table`），
     所以放进 Apple 的仓库目录 `/Library/Apple/System/Library/Extensions`。
  4. `AppleHDADriver::startAction` 用 `OSKextRequestResource` 要 `layoutN.xml.zlib` / `Platforms.xml.zlib`，然后在信号量上**永远等不到回调**（`kernelmanagerd` 不应答）。
     BTLEFix 1.0.6 路由 `OSKext::requestResource`：对 AppleHDA 的这两类文件，直接从 kext 包里读出来调用回调（AppleALC 再把它换成自己的 layout / 平台数据）；文件名有白名单和路径检查。
- 验证：`kextstat | grep -i hda`；`system_profiler SPAudioDataType` 出现内置输入 / 输出；`sysctl debug.btlefix_log` 里有 `AppleHDA resource layoutN.xml.zlib: served from the bundle`。
- 已知问题：设备名显示成原始键（如 `DevShortNameOut…`）——CoreAudio 按裸名 `AppleHDA.kext` 找本地化资源，找不到。要把 AppleHDA 放进密封系统卷才能解决，风险大，未做。
- macOS 更新后确认一次（脚本可重复运行，`undo` 撤销）。诊断：`tahoe/audio/diag-hda-stuck.sh`（内核消息 + 内核栈 + ioreg）。KDK 需要自己下载解开，路径见脚本开头。

### 34. macOS 26 插着电源却显示“电池供电”，FileVault 转换一直“已暂停”
- 现象：26 上 `pmset -g ps` 显示 `Battery Power`、`ExternalConnected = No`，而充电器插着（EC 的 ADP 位为 1）；FileVault 加密 / 解密一直 `0% (Paused)`，
  `fdesetup` / `diskutil apfs decryptVolume` 报 -69573（恢复模式里也一样）——**APFS 在电池供电时暂停加密转换**。
- 根因：SMCBatteryManager 对 ACPI0003 的 `AC` 设备求值 `_PSR` 失败。这台机器 DSDT 里的 `\_SB.AC._PSR` 是给 Windows 写的（调用 WMI / DCHU 的方法），在 macOS 下求值出错（`kIOReturnError`）。
  用一个只读诊断 kext（`tahoe/power/ACProbe`，把求值结果挂到 IORegistry：`ioreg -rn AC -l | grep probe_`）在内核里逐个确认。
- 修复（`tahoe/power/install-acpsr.sh`）：`SSDT-ACPSR.aml` 提供自己的 `_PSR`（返回由 EC 查询 `_Q16` 维护的 `ACFG`），再加一条 ACPI 补丁把原方法改名为 `XPSR`
  （`_PSR\0 → XPSR\0`，整张 DSDT、Count 1；用 `\_SB.AC` 限定 Base 匹配不上）。重启后 `AC Power`、`ExternalConnected = Yes`，FileVault 转换继续。撤销：`install-acpsr.sh undo`。
- `_PSR` 依赖 Windows 专用方法的 DSDT 在蓝天模具上常见，但 EC 字段和 `ACFG` 的名字因机型而异，先用 `tahoe/power/show-acpi.sh`、`ACProbe` 核对你的机器。诊断 kext 用完就撤（`install-acprobe.sh undo`）。
- 绝对 ACPI 路径在内核里求值时，每段名字要补足 4 个字符（`\_SB_.AC__`）；求值不存在的名字返回的也是 `0xE00002BC`，和“方法出错”分不开，要配合一个确定存在的哨兵名字判断。
