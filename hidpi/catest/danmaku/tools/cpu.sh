#!/bin/zsh
# cpu.sh <ws> : 10 s meas.js + CPU of the test Chrome (remote-debugging-port 9333): GPU process, renderers, WindowServer
D=${0:A:h:h}
B=$(pgrep -f "remote-debugging-port=9333" | while read p; do ps -o ppid= -p $p | grep -qw 1 && echo $p; done | head -1)
[[ -z $B ]] && B=$(pgrep -of "remote-debugging-port=9333")
A=(); for p in $(pgrep -P $B); do A+=(-pid $p); done
python3 -I $D/tools/cdp.py $1 "$(cat $D/tools/meas.js)" > $D/dm/meas.out & MP=$!
sleep 2; top -l 2 -s 6 -stats pid,cpu,command $A -pid $(pgrep -x WindowServer) 2>/dev/null | awk '/^PID/{n++} n==2 && $1 ~ /^[0-9]+$/ && $2+0 > 1 {print "  cpu", $1, $3, $2"%"}'
wait $MP; cat $D/dm/meas.out
