EFI 兜底（macOS 26 进不去时用）
================================

1. 开机，OpenCore 阶段按 Esc（或按住 Option），出现启动菜单。
2. 选 "Recovery ..." 恢复模式进入。菜单栏 实用工具 -> 终端。
3. 在终端里依次输入（第一行找到并挂载 OpenCore 所在的 EFI 分区）：

   D=$(for d in $(diskutil list | grep -o 'disk[0-9]*s[0-9]*'); do diskutil info $d | grep -q ESP_UUID_HERE && echo $d; done); echo $D; diskutil mount $D
   sh "/Volumes/NO NAME/EFI/OC/rescue/rescue.sh" safe
   reboot

   看到 "OK: rescue config active" 才算成功。

效果：显卡驱动停用（固件画面）、自带/新增的 4 个 kext 关掉（26 版 Wi-Fi、BTLEFix、NVDSM、RestrictEvents），
其他照旧。能进系统后有线网卡可用，再排查。

改回原来的配置（在恢复模式或进系统后的终端里）：
   sh "/Volumes/NO NAME/EFI/OC/rescue/rescue.sh" restore        （进系统后前面加 sudo；先用上面第一行挂载 EFI 分区，盘号会变）
看状态：
   sh "/Volumes/NO NAME/EFI/OC/rescue/rescue.sh" status

/Volumes 下的名字不是 "NO NAME" 时，用 ls /Volumes 看实际名字。
