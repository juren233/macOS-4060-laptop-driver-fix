# 踩坑记录（请先读）

## 会让你丢掉桌面/崩溃的
- **别原地覆盖已加载的 dylib / 插件**。同一 inode 的 `cp` 会让内核缓存的代码签名失效，随后所有 dlopen 它的进程（WindowServer、视频编解码 XPC、通知中心……）被 `SIGKILL "Code Signature Invalid"`。只能写新 inode 再 `mv`，或重启。
- **NVRM 对快速的 GPU 客户端创建/销毁很脆弱**。作者在同时开 4–6 个 Chrome 实例并反复 `pkill` 时触发过一次内核 panic（`_kdispNotifyEvent_IMPL` ← `_kheadHandleRgSemIntr` ISR 中 `_serverShareIterNext` 空指针）。做 GPU 测试一次只开一个实例，让它自己退出。
- **Lilu 插件里别 hook 所有 USB I/O，也别在完成回调里读传输缓冲区**（`IOGMD: not wired for the IODMACommand` panic，进了安全模式才恢复）。
- Lilu/OC 注入的 kext 在 Boot KC，**无法链接** System KC 里的框架（如 IOGraphicsFamily）。
- 运行时**打开**零拷贝翻转（`debug.nvaccel_iop_flip=1`）会弄坏 Dock，要在启动早期做（见 fixes.md 第 2 项）；运行时关闭是安全的。
- 一次性测试**别用 `nvram boot-args=…`**：OpenCore 会按 ESP 配置重写，重启就没了；改 ESP 里的 `config.plist`（`wifibt/oc-bootarg.sh`）。
- 插件旋钮只能写 `nvrm610.conf`：发行版插件在启动时 `unsetenv` 所有 `NVMTL_*` 变量。`killall WindowServer` 带着某些旋钮会黑屏，换旋钮集请**重启**。
- 重装 NullMoth 驱动会重写 `nvrm610.conf` 和 dylib，上面的二进制补丁、`NVMTL_SURF_SHARE_MINPX`、`NVMTL_NO_NVENC_HEVC` 都会丢，这就是 `nvguard/` 存在的原因。

## 调试习惯
- 窗口截图正确 ≠ 物理屏幕正确（出现过“窗口捕获正常、屏幕全黑”）。
- 在 zsh 里 `log` 是内建，要用 `/usr/bin/log`。
- `plutil -p … | grep -q` 在 `pipefail` 下会因 SIGPIPE 误判失败。
- PlistBuddy 一次 `-c` 超过约 13 个会中止。
- PlistBuddy 一次调用里连续多个 `-c` 往数组末尾 `Add dict` 再 `Add` 字段，新元素会变成上一个元素的副本（"Entry Already Exists"）；每条命令单独调用。
- zsh 终端标签页不接受非 ASCII 路径；用 ASCII 符号链接。
- 沙箱里的 WindowServer 只能写 `/private/tmp`、`/private/var/tmp`、`TMPDIR`，诊断日志放这里。
- `dtrace -p WindowServer` 被 SIP 挡，用 `spindump WindowServer 10`；内核符号用 `nm /System/Library/Kernels/kernel`（基址 `0xffffff8000200000`）。
- UU 的信号处理会把崩溃全部变成 SIGKILL；要看真正的崩溃需 get-task-allow 重签名后进 lldb。
- 在 Claude Code 的 `!` 命令里没法输入 sudo 密码；需要 root 的脚本请在 Terminal.app 里跑。

## 机器/版本相关
- 本仓库所有二进制补丁都绑定 **NullMoth 1.9.0 / 1.0.10** 的具体构建，升级后偏移会变；脚本会断言，报错就是该重新推导而不是硬改。
- macOS 更新可能破坏 kext / 插件；ESP 上的修复由 `efiguard/` 守护（见 docs/fixes.md 第十节），NVRAM 里的 `csr-active-config` 不在任何守护范围（`nvguard/verify.sh` 会提示）。
- Homebrew 7.x 起不再支持 Intel macOS（官方安装脚本在 x86_64 直接退出，也没有 bottle）：手动 `git clone Homebrew/brew` 到 `/usr/local/Homebrew` 并链接 `/usr/local/bin/brew`，之后一切源码编译。
