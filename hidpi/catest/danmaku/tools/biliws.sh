#!/bin/zsh
# biliws.sh N [out] : N launches of the isolated test Chrome (copied login, deleted after) on Bilibili BV1NGZtBwELa 4K + smart mask;
# per launch 3 x 10 s: Chrome rAF (meas.js) + WindowServer CPU + WindowServer on-screen frames (wsframes.sh)
D=${0:A:h:h}; O=${2:-$D/dm/biliws.out}; : > $O
for i in $(seq $1); do
  pkill -f "remote-debugging-port=9333"; sleep 3
  ID=$(zsh $D/tools/userchrome.sh "https://www.bilibili.com/video/BV1NGZtBwELa"); W=ws://127.0.0.1:9333/devtools/page/$ID
  echo "== launch $i $(date +%T) $(python3 -I $D/tools/cdp.py $W "$(cat $D/tools/bili-setup.js)" | cut -c1-60) $(python3 -I $D/tools/cdp.py $W "$(cat $D/dm/maskmeas.js)")" >> $O
  for r in 1 2 3; do zsh $D/tools/wsframes.sh 10 > $O.ws & sleep 0.3; zsh $D/tools/cpu.sh $W | grep -E 'fps|WindowServer' | sed -E 's/"(p50|p99|vframes|res|paused)": [^,}]*,? ?//g' >> $O; wait; cat $O.ws >> $O; done
done
pkill -f "remote-debugging-port=9333"; sleep 3; rm -rf $D/userprof $O.ws; echo DONE >> $O
