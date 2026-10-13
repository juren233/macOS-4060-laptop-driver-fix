#!/bin/zsh
# synthws.sh N [query] : N launches of the isolated test Chrome on play/dm.html (default 200 danmaku + smart-mask CSS, 4K60 H.264 play/v.mp4);
# per launch 3 x 10 s: Chrome rAF + WindowServer on-screen frames (wsframes.sh)
D=${0:A:h:h}; Q=${2:-rate=25%26mask=1%26w=910}; O=$D/dm/synthws.out; : > $O
for i in $(seq $1); do
  pkill -f "remote-debugging-port=9333"; sleep 3; PLAY=$D/play zsh $D/tools/synthchrome.sh
  J=$(curl -s -X PUT "http://127.0.0.1:9333/json/new?http://127.0.0.1:8765/dm.html?f=v.mp4%26$Q"); ID=$(echo $J | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  curl -s "http://127.0.0.1:9333/json/activate/$ID" >/dev/null; sleep 10; echo "== launch $i $(date +%T) $Q" >> $O
  for r in 1 2 3; do zsh $D/tools/wsframes.sh 10 > $O.ws & sleep 0.3; zsh $D/tools/run.sh ws://127.0.0.1:9333/devtools/page/$ID | grep -E "WindowServer|fps" | sed -E 's/"(p50|p99|vframes|res|paused)": [^,}]*,? ?//g' >> $O; wait; cat $O.ws >> $O; done
done
pkill -f "remote-debugging-port=9333"; pkill -f "http.server 8765"; sleep 2; rm -rf $D/chrome-prof $O.ws; echo DONE >> $O
