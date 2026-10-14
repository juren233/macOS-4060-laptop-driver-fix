#!/bin/zsh
# 登录后立刻启动微信输入法，让它尽早向 imklaunchagent 登记（否则自启应用会拿到"无输入法"并缓存）。
# 注意：不能加 open -j（隐藏启动），否则候选窗口不显示（2026-10-13 验证）。
/usr/bin/open -g "/Library/Input Methods/WeType.app"
