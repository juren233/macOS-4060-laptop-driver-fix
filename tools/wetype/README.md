# 微信输入法（WeType）开机后在部分应用里打不了字

**现象**：每次开机后，随登录自启的应用（Claude 桌面端、Steam 等）里微信输入法完全没反应，要杀掉 WeType 让它重启才好；之后新打开的应用（如文本编辑）正常。

**原因**：WeType 不是登录时启动的，而是第一次按键时才被拉起（登录后约 25–45 s）。自启的应用在 WeType 还没向 `imklaunchagent` 登记之前就来要它的连接端点，
拿到 `NO Endpoint` 后**一直缓存着**，所以只有这些应用失效。WeType 进程本身是空闲、健康的（63 个线程全部空闲），与显卡驱动无关。
只杀 `imklaunchagent` 反而更糟（WeType 保留旧登记），必须连 WeType 一起重启。

**修复**：登录时就把 WeType 启动起来，让它抢在其他应用之前登记。

```bash
cp local.wetype.prelaunch.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.wetype.prelaunch.plist
# 撤销：launchctl bootout gui/$(id -u)/local.wetype.prelaunch; rm ~/Library/LaunchAgents/local.wetype.prelaunch.plist
```

- ⚠ 只能用 `open -g`（后台打开），**不能加 `-j`**（隐藏启动）：隐藏启动的 WeType 候选词窗口不显示（窗口建了，但内容看不见）。
- `wetype-prelaunch.sh` 是同一条命令的脚本版。
- 卡住时先别杀进程，运行 `wetype-hang-capture.sh`：保存 WeType / imklaunchagent / TextInputSwitcher 的栈、进程状态和最近 3 分钟日志到桌面。
  日志里的特征是 `getIMKXPCEndpointForBundle: NO Endpoint`；正常时能看到 `Received setIMKXPCEndpoint`。
