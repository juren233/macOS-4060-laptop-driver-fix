# 踩坑记录（请先读）

## 会让你丢掉桌面/崩溃的
- **放进 `/Library/GPUBundles` 的每个 dylib / 插件都必须至少 ad-hoc 签名（`codesign -f -s -`）**。cargo / clang 直接产出的翻译器没有签名：普通用户进程照样能 `dlopen`（你的测试会通过），但 WindowServer（平台进程，带库验证）会拒绝加载 → “AIR->SPIR-V translator is not loaded” → 建不出 Metal 管线 → `MetalShader::CopyPipelineState` 空指针崩溃循环 + 用户态看门狗 panic，开机停在 verbose 画面。内核日志里是 `Library Validation failed: Rejecting …libnvmtl_translate.dylib … completely unsigned`。复现办法：用 `codesign -f -s - -o library` 签名的测试程序跑（`hidpi/tests/lv-test.sh`）。救援：安全模式（`-x`）进系统，把上一版文件放回去（作者的 `nvguard/install.sh previous`），`nvram boot-args` 里被去掉的显卡参数要补回来。**所有“已验证”的结论都要说明测试进程是否带库验证。**
- **别原地覆盖已加载的 dylib / 插件**。同一 inode 的 `cp` 会让内核缓存的代码签名失效，随后所有 dlopen 它的进程（WindowServer、视频编解码 XPC、通知中心……）被 `SIGKILL "Code Signature Invalid"`。只能写新 inode 再 `mv`，或重启。
- **NVRM 对快速的 GPU 客户端创建/销毁很脆弱**。作者在同时开 4–6 个 Chrome 实例并反复 `pkill` 时触发过一次内核 panic（`_kdispNotifyEvent_IMPL` ← `_kheadHandleRgSemIntr` ISR 中 `_serverShareIterNext` 空指针）。做 GPU 测试一次只开一个实例，让它自己退出。
- **Lilu 插件里别 hook 所有 USB I/O，也别在完成回调里读传输缓冲区**（`IOGMD: not wired for the IODMACommand` panic，进了安全模式才恢复）。
- Lilu/OC 注入的 kext 在 Boot KC，**无法链接** System KC 里的框架（如 IOGraphicsFamily）。
- 运行时**打开**零拷贝翻转（`debug.nvaccel_iop_flip=1`）会弄坏 Dock，要在启动早期做（见 fixes.md 第 2 项）；运行时关闭是安全的。
- 一次性测试**别用 `nvram boot-args=…`**：OpenCore 会按 ESP 配置重写，重启就没了；改 ESP 里的 `config.plist`（`wifibt/oc-bootarg.sh`）。
- 插件旋钮只能写 `nvrm610.conf`：发行版插件在启动时 `unsetenv` 所有 `NVMTL_*` 变量。`killall WindowServer` 带着某些旋钮会黑屏，换旋钮集请**重启**。
- 重装 NullMoth 驱动会重写 `nvrm610.conf` 和 dylib，上面的二进制补丁、`NVMTL_SURF_SHARE_MINPX`、`NVMTL_NO_NVENC_HEVC` 都会丢，这就是 `nvguard/` 存在的原因。
- **不要让系统睡眠**（合盖、苹果菜单“睡眠”）：NullMoth 的 NVRM（直到 1.15.0）没有 GPU 的挂起/恢复，唤醒后 GPU 读出 `0xbadf5620`、“GSP core unresponsive”、Xid 119，屏幕不亮，只能强制关机。
  作者设了 `sudo pmset -a SleepDisabled 1`（合盖也不睡）。显示器休眠没问题。
- **ESP 的盘号偶尔会变**：有两块 NVMe 时识别先后不固定（作者 20 次开机里 1 次 `disk1s4` 变成 `disk0s4`，而平时的 `disk0s4` 是 Windows 恢复分区）。写死盘号的脚本会去查错盘或停下；用分区 UUID 找（本仓库所有改 ESP 的脚本都这么做）。
- **救 macOS 26 别用升级前的 EFI 备份**：iMacPro1,1 上没有 `-no_compat_check` 的配置 26 开不了机。用 `tahoe/` 的救援配置（`RESCUE.md`）。

## 调试习惯
- 窗口截图正确 ≠ 物理屏幕正确（出现过“窗口捕获正常、屏幕全黑”）。
- 在 zsh 里 `log` 是内建，要用 `/usr/bin/log`。
- `plutil -p … | grep -q`、`strings … | grep -q` 在 `pipefail` 下会因 SIGPIPE 误判失败；直接 `grep -a -q 模式 文件`。
- itlwm 的 Release 构建日志很多，128 KB 内核消息缓冲只够约 50 s；查开机问题用 `sysctl -w kern.msgbuf=1048576` 并尽早 dmesg（`tools/wifi-bootlog/`）。
- PlistBuddy 一次 `-c` 超过约 13 个会中止。
- PlistBuddy 一次调用里连续多个 `-c` 往数组末尾 `Add dict` 再 `Add` 字段，新元素会变成上一个元素的副本（"Entry Already Exists"）；每条命令单独调用。
- zsh 终端标签页不接受非 ASCII 路径；用 ASCII 符号链接。
- 沙箱里的 WindowServer 只能写 `/private/tmp`、`/private/var/tmp`、`TMPDIR`，诊断日志放这里。
- `dtrace -p WindowServer` 被 SIP 挡，用 `spindump WindowServer 10`；内核符号用 `nm /System/Library/Kernels/kernel`（基址 `0xffffff8000200000`）。
- UU 的信号处理会把崩溃全部变成 SIGKILL；要看真正的崩溃需 get-task-allow 重签名后进 lldb。
- macOS 26 的 `kmutil` 默认不把第三方目录里 Apple 前缀的 kext（如放回去的 AppleHDA）放进辅助内核集合，要 `-b <bundle id>` 点名；放在 `/Library/Extensions` 的 Apple kext 还会被 `kernelmanagerd` 拒绝建资源表（“restricted lookup table”），要放 `/Library/Apple/System/Library/Extensions`。
- 内核里 `evaluateInteger` 绝对 ACPI 路径时每段名字要补足 4 个字符（`\_SB_.AC__`）；不存在的名字和求值出错返回同一个 `0xE00002BC`，要配一个确定存在的哨兵名字来区分。
- 在 Claude Code 里跑需要 sudo 的脚本：命令行版的 `!` 命令没法输入密码，请在 Terminal.app 里跑；桌面版可以在它的终端面板里输入密码。

- **看流畅度要量 WindowServer 实际上屏的帧数，不是网页里的 `requestAnimationFrame`**。智能防挡弹幕时 Chrome 的 rAF 一直是 165 fps，实际上屏只有约 90。
  不需要录屏权限的办法：WindowServer 每次更新屏幕都会打一条 CoreDisplay 调试日志（“using last created GPU Gamma Table”），数它的时间戳即可（`hidpi/catest/danmaku/tools/wsframes.sh`）。
- **比较修改前后的 GPU 输出，要在相同的着色器缓存状态下**：同一个程序冷缓存和热缓存的结果可能差 1 个色阶（旧驱动也一样）。换了翻译器后缓存键会变，“修改后”那次往往是冷的。
  用 `CFFIXED_USER_HOME` 给两边各指一个新目录，冷对冷、热对热地比（`~/Library/Caches/nvmtl` 跟着变）。
- **往 Chrome 里注入测试插件**（`plugshim`）：未签名的 `DYLD_INSERT_LIBRARIES` 库会被静默忽略；GPU 沙箱不允许从 `/tmp` 加载插件，GPU 进程会退回软件渲染（帧率掉到 20–40，这组数据作废）。
  要 ad-hoc 签名，并给测试 Chrome 加 `--disable-gpu-sandbox`，两边条件一致地比。
- **别常开 debug 级的 `log stream`**（哪怕带过滤条件）：它让所有进程都开始产出调试日志（本机每秒约 1700 条），`log` + `diagnosticd` 平时约 9% CPU、播视频时约 30%。
  要抓事件前后的日志，事后 `log show --start …` 就够了（`tools/usb-watch/` 就是这样做的）。

## 机器/版本相关
- 本仓库的二进制补丁都绑定具体构建：NVRM 有 1.9.0（`patch-nvrm-190.py`）和 1.15.0（`patch-nvrm-115.py`）两版；NVK、NVDEC、NVENC 的补丁只针对 **NullMoth 1.9.0 / 1.0.10**（1.15.0 安装包里的编解码库不同，NVK 则不再需要补丁），升级后偏移会变；脚本会断言，报错就是该重新推导而不是硬改。
- macOS 更新可能破坏 kext / 插件；ESP 上的修复由 `efiguard/` 守护（见 docs/fixes.md 第十节），NVRAM 里的 `csr-active-config` 不在任何守护范围（`nvguard/verify.sh` 会提示）。macOS 26 每次更新后确认声卡（`tahoe/audio/install-hda26.sh` 可重复运行）。
- Homebrew 7.x 起不再支持 Intel macOS（官方安装脚本在 x86_64 直接退出，也没有 bottle）：手动 `git clone Homebrew/brew` 到 `/usr/local/Homebrew` 并链接 `/usr/local/bin/brew`，之后一切源码编译。
