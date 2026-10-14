# macOS 26 出事时的兜底

按情况从轻到重：

## 1. 能进桌面但显卡异常 / WindowServer 反复崩溃
开机按住 **Shift** 进安全模式（不加载 NullMoth 显卡驱动），进去后再排查。

## 2. 开机就崩溃、卡死，安全模式也不行 → 用 EFI 兜底配置
1. 开机，OpenCore 阶段按 **Esc**（或按住 **Option**），出现启动菜单。
2. 选 **Recovery …**（恢复模式）进入。菜单栏 **实用工具 → 终端**。
3. 依次输入三行（ESP 上的 `EFI/OC/rescue/README.txt` 里是已经填好 UUID 的同一段命令，可以照抄）：

```sh
D=$(for d in $(diskutil list | grep -o 'disk[0-9]*s[0-9]*'); do diskutil info $d | grep -q <你的 ESP 分区 UUID> && echo $d; done); echo $D; diskutil mount $D
sh "/Volumes/NO NAME/EFI/OC/rescue/rescue.sh" safe
reboot
```

- 第一行会打印出分区名（比如 `disk1s4`；盘号偶尔会变，所以按分区 UUID 找），并显示 mounted。
- 第二行必须看到 `OK: rescue config active`。
- `/Volumes` 下不叫 `NO NAME` 时，先 `ls /Volumes` 看实际名字。

**效果：**
- 显卡驱动停用，用固件画面显示（分辨率低、不流畅，但能用）。
- 关掉 4 个我们自己的或新加的 kext：26 版 Wi-Fi、BTLEFix、NVDSM、RestrictEvents。没有 Wi-Fi，有线网卡能用。
- 其他保持不变。efiguard 和升级收尾脚本会暂停，不会把这些改回去。

进系统后再排查。

**改回原来的配置：**
- 恢复模式里：`sh "/Volumes/NO NAME/EFI/OC/rescue/rescue.sh" restore`
- 进系统后：先用上面第一行挂载 EFI 分区（盘号会变，别直接写 `disk1s4`），再 `sudo sh "/Volumes/NO NAME/EFI/OC/rescue/rescue.sh" restore`
- 看当前状态：把上面的 `restore` 换成 `status`。

## 3. 恢复模式也进不去
- 启动菜单里的 Linux（Limine）同样可以用。挂载 EFI 分区（4.3 GB 的 FAT32 分区）后，运行同一条 `sh …/EFI/OC/rescue/rescue.sh safe`。
- 再不行，用另一台电脑或 U 盘启动，手动把 `EFI/OC/rescue/config-safe.plist` 复制成 `EFI/OC/config.plist`，原文件先另存一份。

> 别用 `revert-efi-26.sh` 那份升级前的备份。它没有 `-no_compat_check`，26 用它根本开不了机。
