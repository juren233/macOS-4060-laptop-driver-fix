#!/bin/zsh
# synthchrome.sh : isolated muted Chrome for the synthetic page with the user's chrome://flags (Local State only - no cookies) and GPU caches,
# serving play/ on :8765, DevTools on :9333. Kill it with: pkill -f "user-data-dir=$S/chrome-prof"
S=${0:A:h:h}; C="$HOME/Library/Application Support/Google/Chrome"; U=$S/chrome-prof
rm -rf $U; mkdir -p $U/Default; cp "$C/Local State" $U/
for d in GraphiteDawnCache GPUPersistentCache; do cp -R "$C/$d" "$U/$d" 2>/dev/null; done; for d in GPUCache DawnGraphiteCache DawnWebGPUCache; do cp -R "$C/Default/$d" "$U/Default/$d" 2>/dev/null; done
pgrep -f "http.server 8765" >/dev/null || (cd ${PLAY:-$S/play} && python3 -I -m http.server 8765 --bind 127.0.0.1 > /dev/null 2>&1 &!)
env -u MESA_SHADER_CACHE_DIR ${=EXTRAENV:-} ANGLE_FEATURE_OVERRIDES_DISABLED=disableMetalOnNvidia "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --user-data-dir=$U --no-first-run --no-default-browser-check --mute-audio --autoplay-policy=no-user-gesture-required --remote-debugging-port=9333 --window-size=1600,950 ${=EXTRAARGS:-} --new-window about:blank > $S/dm/synthchrome.log 2>&1 &!
sleep 8
