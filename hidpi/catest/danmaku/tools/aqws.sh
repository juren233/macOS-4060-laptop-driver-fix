#!/bin/zsh
# aqws.sh [fish...] : webglsamples aquarium in the isolated test Chrome (user's flags + GPU caches, no cookies), per fish count 10 s warm-up then
# 10 s: Chrome rAF (raf.js) + test Chrome GPU-process CPU + WindowServer on-screen frames (wsframes.sh)
D=${0:A:h:h}; O=$D/dm/aqws.out; : > $O
pkill -f "remote-debugging-port=9333"; sleep 3; PLAY=$D/play zsh $D/tools/synthchrome.sh
B=$(pgrep -of "remote-debugging-port=9333"); G=$(for p in $(pgrep -P $B); do ps -o command= -p $p | grep -q gpu-process && echo $p; done | head -1)
(( $# )) || set -- 1000 5000 10000 20000
for n in "$@"; do
  J=$(curl -s -X PUT "http://127.0.0.1:9333/json/new?https://webglsamples.org/aquarium/aquarium.html?numFish=$n"); ID=$(echo $J | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  curl -s "http://127.0.0.1:9333/json/activate/$ID" >/dev/null; sleep 10
  zsh $D/tools/wsframes.sh 10 > $O.ws & sleep 0.3
  python3 -I $D/tools/cdp.py ws://127.0.0.1:9333/devtools/page/$ID "$(cat $D/tools/raf.js)" > $O.raf & RP=$!
  sleep 2; C=$(top -l 2 -s 6 -stats pid,cpu -pid $G -pid $(pgrep -x WindowServer) | awk '/^PID/{n++} n==2 && $1 ~ /^[0-9]+$/ {printf "%s=%s%% ", ($1=='$G'?"GPUproc":"WS"), $2}')
  wait $RP; wait
  echo "fish $n: $(cat $O.raf) $C" >> $O; cat $O.ws >> $O
  curl -s http://127.0.0.1:9333/json/close/$ID >/dev/null; sleep 2
done
pkill -f "remote-debugging-port=9333"; pkill -f "http.server 8765"; sleep 2; rm -rf $D/chrome-prof $O.ws $O.raf; echo DONE >> $O
