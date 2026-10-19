# BTLEFix v6：bluetoothd 补丁改为进程私有（1.0.8 已安装，压力与睡眠测试通过）

## 当前状态

- `kern_btlefix.cpp` 已改为在 `task_set_main_thread_qos` 后对 bluetoothd/BlueTool 的进程私有页打补丁；不再路由 `cs_validate_page`。
- 1.0.7 已安装并重启验证：核心功能正常，磁盘/UBC 页保持 pristine，无 APFS page-in 错误，蓝牙为 On。
- 1.0.7 的检查有 2 项失败，原因是 `candidateProcess()` 用 `strncmp(name, "bluetoothd", 6)` 误匹配了 `/usr/libexec/bluetoothuserd`；已改为精确 `strcmp()`。
- `build.sh` 已成功构建 `BTLEFix/build/BTLEFix.kext`（1.0.8，sha256 `88bc59d3...`）。
- 1.0.8 已安装到 ESP 并重启，压力测试前的 `check-v6.sh` 为 13 passed, 0 failed。
- 2026-10-19 18:40 压力测试：10/10 次 bluetoothd 重启均为 `6/6`，无 APFS page-in 错误；45 秒定时睡眠测试 PASS（正常唤醒、NVRM running、WindowServer pid 不变、无 panic）。
- 压力测试期间 `audioaccessoryd` 的 "Bluetoothd has crashed / Restarted" 是 `launchctl kickstart -k` 强制重启导致的正常现象；真正的失败标准是出现 `apfs_pagein` 或 `Cannot read data`。
- 压力测试后 `check-v6.sh` 为 12/13：唯一失败是 BlueTool 的历史日志行已被 32 KB 的 `debug.btlefix_log` 环形缓冲覆盖。BlueTool 在压力测试前已由 13/13 检查确认，且进程仍在运行；这不是补丁失败。
- `check-v6.sh` 已改为断言 1.0.8，并把日志检查限定到本次启动，避免上一次启动的旧错误污染结果；`install-v6.sh` 重装时保留原始 v5 回滚备份，不再把它覆盖成上一版 v6。
- `verify_private_patch.py` 已对 `/usr/sbin/bluetoothd` 和 `/usr/sbin/BlueTool` 做过离线只读检查。
- 已准备 `install-v6.sh`、`check-v6.sh`、`stress-v6.sh`、`rollback-v6.sh`，安装脚本会先备份并关闭 BlueToolFixup。
- `efiguard/install.sh` 已把 `-btlfxoff` 加入必需 boot-args，避免后续快照修复漏掉这个开关。
- `stress-v6.sh` 的启动前检查已改为接受 `code 6/6` 或 `path 1/1`；之前只认前者，BlueTool 最后写入状态时会误停。

## 问题

**现象**：蓝牙显示"关闭"并且打不开。`system_profiler` 里 Address 为 NULL、State 为 Off。

**直接原因**：bluetoothd 每约 10 秒崩溃一次，直到 launchd 放弃重启它。每次崩溃前，内核日志里都有：

```
apfs_pagein_with_verification: disk2s4 Cannot read data for compressed inode … size 16384 file size 0: Bad message(94)
apfs_pagein … error 94 (bluetoothd)  →  crashed: bluetoothd
```

**证据**：

- 解压失败的 16 KB 块是 966656、1982464、3391488 和 3653632。它们**恰好就是** BlueToolFixup 打补丁的那几块：厂商检查和两处芯片检查。
- XProtectRemediator 扫描这个文件时，在同样的块上失败。
- 对 `/usr/sbin/bluetoothd` 做 `codesign --verify`，结果是 "invalid signature (code or signature have been modified)"。对照组 sshd、airportd、bluetoothuserd 都通过。可见内存里缓存的文件页已经被改过。
- 出事时内存压力很大：压缩器里约 10 GB，swapouts 120 万次。
- 和睡眠无关：这次开机 16:47 就开始崩，比睡眠测试早。日志里最早一次是 10-19 10:16。

**机制**：

- BlueToolFixup 和 BTLEFix 的第 1 项都钩在 `cs_validate_page` 上，**直接改写正在校验的那一页**。那一页就是 bluetoothd 文件在统一缓存（UBC）里的页，所有进程共用。
- 系统卷是密封的，bluetoothd 又是压缩文件。APFS 换入时，一次解压并校验整个 16 KB 块。
- 内存紧张时，一块里的 4 页会只被换出一部分。剩在内存里的页是改过的，再换入同一块时校验就对不上，于是报 `Bad message`，bluetoothd 读不到代码而崩溃。

## 思路

文件页一个字节都不动。补丁只写进 bluetoothd **这一个进程**的私有副本：在 exec 之后、用户代码运行之前，对补丁所在页做写时复制（COW），再写入补丁。

这样：

- UBC 里的文件页保持原样，APFS 校验和 codesign 都能通过，换入随时可以进行。
- 改过的页是进程的匿名页。内存紧张时它进压缩器，不会再从文件换入。
- 每次 bluetoothd 重启都会重新打一遍补丁，因为每次 exec 都会触发。

## 要接手的补丁

在 macOS 26 x86_64 上，按现在的 boot-args（`-btlfxboardid`）实际生效的是下面这些：

| # | 文件 | 补丁 | 来源 | x86_64 片内所在块 |
|---|---|---|---|---|
| 1 | bluetoothd | 厂商检查 kVendorCheck | BlueToolFixup | 966656 |
| 2 | bluetoothd | 芯片检查 kBadChipsetCheck（3 处） | BlueToolFixup | 3391488、3653632 |
| 3 | bluetoothd | 芯片检查 kBadChipsetCheck15_4（Sequoia+） | BlueToolFixup | 1982464 |
| 4 | bluetoothd | board-id 字符串换成本机 Mac-7BA5B2D9E42DDD94（`-btlfxboardid`） | BlueToolFixup | 10960896 |
| 5 | bluetoothd | LE Read Buffer Size v2 → v1 分支（kFind26） | BTLEFix #1 | 1523712 |
| 6 | BlueTool | SkipBluetoothAutomaticFirmwareUpdate 路径，以及 board-id | BlueToolFixup | 212992 等 |

以下不需要：

- 地址检查：要 `-btlfxallowanyaddr` 才启用，我们没加。
- NVRAM 检查：只在 Sonoma 及以前生效。

BTLEFix 的 #2、#4（HCI 命令改写和寻呼延迟）和 #5（AppleHDA）不改动。

## 实现

1. **触发点**：自己路由内核函数 `task_set_main_thread_qos`。这个符号在 26.7.1 内核里存在，Lilu 也用它做延迟的用户态补丁。
   - 它在 exec 换到新任务之后、新进程的第一条用户指令之前调用，此时 `current_map()` 已经是新进程的地址空间。
   - 只处理可执行文件路径正好是 `/usr/sbin/bluetoothd` 或 `/usr/sbin/BlueTool` 的情况，用 `proc_pidpath` 或 vnode 路径判断。其他进程直接返回。
   - 不用 Lilu 的 `onProcLoad`。它会打开 Lilu 整套用户态补丁器，在没有共享缓存 slide 时还会往进程头里注入 `__RESTRICT`（`injectRestrict`），副作用太多。
2. **找补丁位置**：
   - 每个文件只做一次，按 vnode 加文件修改时间缓存。用 `vn_rdwr` 读 x86_64 片：这走普通读路径；而且旧的就地补丁已经去掉，读到的是原始字节。
   - 解析 Mach-O，在 `__TEXT` 段里找表中每个原始模式，记下它相对 `__TEXT` 起点的偏移。
   - 每个模式都必须恰好命中预期的次数，比如芯片检查是 3 次。数目不对就这一项不打，并记日志。不要猜。
3. **写入**：
   - 映像基址取 `get_map_min(map)`：x86_64 上 `__PAGEZERO` 就是靠抬高 map min 实现的，所以 map min 就是主映像的 Mach-O 头。先读头部，核对 magic、cputype 和 `LC_UUID`，三者都要和文件一致。
   - 每处补丁先用 `vm_map_read_user` 读出目标字节，确认等于原始字节。等于补丁字节说明已经打过，跳过；两者都不是就放弃这一处。
   - 写入时对那一页执行 `mach_vm_protect(map, page, PAGE_SIZE, FALSE, VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)`，强制写时复制并临时去掉执行权限。用户代码还没开始跑，所以这是安全的。
   - 然后 `vm_map_write_user` 写入补丁，再 `mach_vm_protect` 恢复原来的保护（通常是 RX）。
   - 代码签名方面：本机关闭了 AMFI，私有的脏代码页不会让进程被杀。仍要照 Lilu 的 `vmProtect` 那样检查 `CS_KILL` 和 `CS_ENFORCEMENT`：只要进程带着这些标志，就不打补丁并记日志，不去改它的标志。原型阶段先确认 bluetoothd 实际带哪些标志，见下面第 2 步。
4. **去掉旧的就地补丁**：
   - BTLEFix 不再改 `cs_validate_page` 交来的页。这个钩子整个删掉。
   - BlueToolFixup 用 boot-arg `-btlfxoff` 关掉。kext 留在 EFI 里，回滚时去掉这个参数即可。
   - BTLEFix 自己读 `-btlfxboardid`，决定是否做 board-id 补丁。
5. **开关和诊断**：
   - `-btlefixoff`（已有）：关掉整个 BTLEFix。
   - 新增 boot-arg `btlefix_cow=0`：只关进程内补丁，其余功能照常。
   - 新增 `sysctl debug.btlefix_cow`，记录每次 exec 的结果。例如：`bluetoothd pid 812: 6/6 patched, 0 skipped, 0 already, uuid ok`。
   - 内核日志前缀用 `BTLEFix: cow:`。

## 验证（每一步都要你同意才做）

1. **离线检查**：用 python 在文件里算出每个补丁的偏移和命中次数，和内核日志里的结果对照。只读，不装任何东西。
2. **原型构建**：签名，并在库校验下测试，参照 [[verify-like-windowserver]]。
3. **安装**：
   - 用 `safe-replace-btlefix.sh` 替换 BTLEFix.kext，它会先备份。
   - 用 `oc-bootarg.sh add -btlfxoff` 加参数，再重新生成 efiguard 快照。
   - 然后重启。重启是必需的，因为要清掉内存里已经被改过的页。
4. **重启后检查**：
   - `codesign --verify /usr/sbin/bluetoothd` 通过。
   - `debug.btlefix_cow` 显示 6/6。
   - 蓝牙为 On，已配对的设备能连上，BLE 扫描正常。BTLEFix #2、#4 不受影响。
5. **压力测试**（有上限，见 [[feedback-no-unbounded-loops]]）：
   - 先 `sudo purge`，再重启 bluetoothd 10 次。
   - 每次都确认 6/6、没有 `Cannot read data`、蓝牙能起来。
   - 另外做一次定时睡眠，用 `sleep/sleep-test.sh`。
6. **观察几天**：内核日志里不再出现 `apfs_pagein … (bluetoothd)`。

## 风险与回滚

- **exec 钩子出错会 panic**：这个钩子每次 exec 都会调用。
  - 除了比较路径，钩子里不做任何其他操作，也不分配内存。读文件只在第一次匹配时做一次。
  - 万一出问题：开机时在 OpenCore 里加 `-btlefixoff`；或者用 Recovery 里现成的 `EFI/OC/rescue` 救援配置；或者用 `safe-replace-btlefix.sh` 换回 v5。
- **补丁漏打或打错**：bluetoothd 会像没有 BlueToolFixup 时那样认不出控制器，蓝牙起不来，但不会损坏任何东西。逐项核对原始字节就是为了防止写错位置。
- **回滚**：
  - 用 `oc-bootarg.sh remove -btlfxoff` 去掉参数。
  - 把 BTLEFix 换回 v5（`kexts/` 里的备份）。
  - 重新生成 efiguard 快照，然后重启。

## 暂不处理

内存压力本身偏高（16 GB 内存，压缩器里约 10 GB）。它是触发条件，不是根因。改完以后，即使内存紧张也不会再触发这个问题。占内存的是哪些进程，以后另外看。
