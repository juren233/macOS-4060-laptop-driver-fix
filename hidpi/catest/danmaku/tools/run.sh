#!/bin/zsh
# run.sh <ws> : 10 s rAF/video measurement + CPU% of Chrome GPU/renderer + WindowServer during it
S=${0:A:h:h}; P=${PROF:-$S/chrome-prof}
GPU=$(ps -Ao pid,args | grep "user-data-dir=$P" | grep type=gpu-process | awk '{print $1}' | head -1)
python3 -I $S/tools/cdp.py $1 "$(cat $S/tools/meas.js)" > $S/dm/meas.out &
MP=$!
sleep 2; top -l 2 -s 6 -stats pid,cpu,command -pid $GPU -pid $(pgrep -x WindowServer) $(for p in $(ps -Ao pid,args | grep "user-data-dir=$P" | grep type=renderer | awk '{print $1}'); do echo -pid $p; done) 2>/dev/null | awk '/^PID/{n++} n==2 && $1 ~ /^[0-9]+$/ && $2+0 > 1 {print "  cpu", $1, $3, $4, $2"%"}'
wait $MP; cat $S/dm/meas.out
