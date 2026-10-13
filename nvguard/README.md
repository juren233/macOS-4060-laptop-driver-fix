# nvguard — 参考实现

作者本机用的“驱动被重装/更新后自动把补丁放回去”的守护。**它依赖作者自己的构建产物和目录布局**
（`install.sh` 会从作者的工作目录取已构建好的插件/翻译器/补丁 dylib，并核对 sha256），所以不能原样运行；
请把它当作思路和模板：

- `install.sh`：登记“好的构建”的哈希（`GOOD_*`）、可被替换的旧/原版哈希（`OLD_*`、`STOCK_*`），把快照放进 `/Library/NullMoth/guard`（`chflags schg` + MANIFEST），安装 LaunchDaemon `local.nvguard`。
- `nvguard.sh`：开机和被守护目录变化时运行；若线上文件是**已知的可替换构建**，就用快照覆盖（新 inode，不原地写）；未知构建不动；并保证 `nvrm610.conf` 里的必需旋钮**生效**（插件和 NVK 只认同一个键的第一行，所以会删掉该键的旧行再写入，改前留备份）。
- 回滚：`install.sh previous` / `rpark` / `sampler` 把更早的构建登记为“好的构建”，守护随即放回旧文件（安全模式里也能用）；不带参数重跑就回到最新。
- `verify.sh`：无需 sudo 的只读体检（哈希、conf、LaunchDaemon、git 状态、最新 EFI 备份）。

移植要改的：`install.sh` 顶部的各个哈希与源路径、`verify.sh` 里的目录。脚本里的 `~/work/…` 是作者本机路径。

`verify.sh` 还检查 `efiguard`（ESP 守护）与 AppleALC/`alcid`；`efiguard/` 管 OpenCore ESP 上的修复，见 [../efiguard/README.md](../efiguard/README.md)。
