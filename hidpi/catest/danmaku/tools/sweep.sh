#!/bin/zsh
# sweep.sh <video> <rate>... : one tab at a time, 10 s warm-up, 10 s measurement, close
S=${0:A:h:h}; F=$1; shift
for r in "$@"; do
  J=$(curl -s -X PUT "http://127.0.0.1:9333/json/new?http://127.0.0.1:8765/dm.html?f=$F%26rate=$r")
  ID=$(echo $J | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  curl -s "http://127.0.0.1:9333/json/activate/$ID" >/dev/null
  sleep 10; echo "== $F rate=$r/s"; $S/tools/run.sh ws://127.0.0.1:9333/devtools/page/$ID
  curl -s http://127.0.0.1:9333/json/close/$ID >/dev/null; sleep 2
done
