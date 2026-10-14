#!/bin/zsh
# 微信输入法卡死时运行（先别杀进程）：抓 WeType / imklaunchagent / TextInputSwitcher 的栈、进程状态和最近日志
out=~/Desktop/wetype-hang-$(date +%H%M%S); mkdir -p $out
ps -axo pid,lstart,etime,state,%cpu,command | grep -E "WeType|imklaunchagent|TextInputSwitcher|TextInputMenuAgent|WindowServer" | grep -v grep > $out/ps.txt
for n in WeType imklaunchagent TextInputSwitcher; do
  p=$(pgrep -x $n | head -1); [ -n "$p" ] && sample $p 3 -file $out/sample-$n.txt >/dev/null 2>&1
done
/usr/bin/log show --last 3m --style compact --predicate 'process == "WeType" OR process == "imklaunchagent" OR process == "TextInputSwitcher" OR process == "WindowServer" OR eventMessage CONTAINS[c] "wetype"' > $out/log.txt 2>&1
echo "已保存到 $out"
