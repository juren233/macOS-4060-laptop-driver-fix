# 内置声卡（麦克风 + 扬声器）— 修复 24

参考机型：蓝天（Clevo）模具，Realtek **ALC256**，子系统 ID `1558:25E1`，PCH 音频控制器 `8086:51ca`（Alder Lake-P）。
**别的机器的编解码器、引脚配置、layout 都不同，不能直接照抄**：先确认你自己的编解码器（见 docs/fixes.md 第 24 项）。

- `apply-alc.sh [layout]`：备份 `config.plist` 和 `Kexts`，把 AppleALC 加到 `Kernel/Add`（Lilu 之后），在 `boot-args` 里写 `alcid=<layout>`。可重复运行换 layout。
- `revert-alc.sh`：恢复到第一次运行前的备份并移除 AppleALC。
- `SOURCE.txt`：AppleALC 的下载地址和 sha256（本仓库**不含**这个二进制）。

需要 `ESP_DEV` / `ESP_UUID`（见仓库根目录 README 的“快速上手”），脚本以 root 运行。
