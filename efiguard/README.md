# efiguard — OpenCore ESP 守护（参考实现）

`nvguard` 管 `/Library` 下的驱动文件，这里管 **ESP 上的修复**：AppleALC + `alcid`、Wi-Fi/蓝牙/NVDSM/BrightnessKeys/VoodooI2C 的 kext、`SSDT-PS2KEYS`、关键 boot-args。

```bash
# 安装 / 有意改过 EFI 之后刷新快照（root，需要你自己的 ESP）
sudo -E ESP_DEV=disk1s4 ESP_UUID=$(diskutil info disk1s4 | awk -F': *' '/Partition UUID/{print $2}') zsh install.sh
```

- `install.sh`：把 `EFI/OC` 的 `config.plist`、`Kexts`、`ACPI`、`Drivers` 拍快照到 `/Library/NullMoth/efiguard`（`chflags schg`），
  生成 `required-kexts.txt`（当前所有启用的 `Kernel/Add`）和 `required-bootargs.txt`（带我们修复的 boot-args），注册 LaunchDaemon `local.efiguard`（开机 + 每 6 小时）。
  拒绝给“已损坏”的状态拍快照：任何启用的 kext 在 ESP 上不存在就停下。
- `efiguard.sh`：先**只读**挂载 ESP 检查；只有需要修复时才读写挂载。
  - 文件缺失 → 从快照补回；
  - `Kernel/Add` 条目缺失 → 按快照补回，被禁用 → 重新启用；关键 boot-arg 缺失 → 补回；
  - `Lilu` 条目没了或 `config.plist` 不可用 → 整份恢复快照；
  - 文件只是与快照不同 → 不动，日志写 `ATTENTION`（你可能有意升级了，改完请重跑 `install.sh`）。
  - 被替换的文件先复制到 `/Library/NullMoth/efiguard-replaced/<时间戳>/`；日志在 `/var/log/efiguard.log`。
  - 绝不卸载别人挂着的 ESP，绝不碰 `OpenCore.efi`、引导器、启动项。
- 演练（不碰系统）：`EFIGUARD_ROOT=<含 EFI/OC 的目录> EFIGUARD_SNAP=<快照目录> EFIGUARD_REPLACED=<目录> EFIGUARD_LOG=<文件> EFIGUARD_TEST=1 ESP_DEV=x ESP_UUID=y zsh install.sh`，
  然后弄坏那份副本，再用同样的环境变量运行 `efiguard.sh`。
- 脚本只在作者的 ESP 布局（OpenCore 在 `EFI/OC`）上测过。
