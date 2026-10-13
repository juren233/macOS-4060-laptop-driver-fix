#!/bin/zsh
# userchrome.sh <url> : temp copy of the user's Chrome login/settings/GPU caches -> isolated muted Chrome with the user's env; prints page id.
# Delete $S/userprof afterwards (it holds a copy of the cookies).
S=${0:A:h:h}; C="$HOME/Library/Application Support/Google/Chrome"; U=$S/userprof
rm -rf $U; mkdir -p $U/Default/IndexedDB; chmod 700 $U
cp "$C/Local State" $U/; for f in Preferences "Secure Preferences"; do cp "$C/Default/$f" "$U/Default/" 2>/dev/null; done
sqlite3 "file:$C/Default/Cookies?mode=ro" ".backup '$U/Default/Cookies'"; cp -R "$C/Default/Local Storage" "$U/Default/"; cp -R "$C/Default/IndexedDB/"*bilibili* "$U/Default/IndexedDB/" 2>/dev/null
for d in GraphiteDawnCache GPUPersistentCache; do cp -R "$C/$d" "$U/$d" 2>/dev/null; done; for d in GPUCache DawnGraphiteCache DawnWebGPUCache; do cp -R "$C/Default/$d" "$U/Default/$d" 2>/dev/null; done
env -u MESA_SHADER_CACHE_DIR ${=EXTRAENV:-} ANGLE_FEATURE_OVERRIDES_DISABLED=disableMetalOnNvidia "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --user-data-dir=$U --no-first-run --no-default-browser-check --mute-audio --autoplay-policy=no-user-gesture-required --remote-debugging-port=9333 --window-size=1600,950 ${=EXTRAARGS:-} --new-window "$1" > $S/dm/userchrome.log 2>&1 &!
sleep 18; curl -s http://127.0.0.1:9333/json | python3 -I -c 'import json,sys; [print(t["id"]) for t in json.load(sys.stdin) if t["type"]=="page" and "bilibili" in t["url"]]' | head -1
