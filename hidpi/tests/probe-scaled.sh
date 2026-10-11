#!/bin/bash
# sudo probe-scaled.sh <w> <h> [hz]
# Tries one scaled HiDPI mode for a few seconds, then switches back to native 2560x1440@165.
# The verdict comes from the framebuffer driver's own log line ("switchMode ... test/COMMIT ... -> 0/1").
# If NVKMS refused the mode, WindowServer is restarted at once (that logs the user out but restores the picture).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
W=${1:-1920}; H=${2:-1080}; HZ=${3:-0}; KIND=${4:-hidpi}; HOLD=${HOLD:-10}; U=${SUDO_USER:-$(stat -f %Su /dev/console)}; UIDN=$(id -u "$U")
LOG="$HERE/probe-${W}x${H}@${HZ}-${KIND}.log"; exec > >(tee "$LOG") 2>&1
echo "== $(date '+%F %T')  NVRM $(shasum -a 256 /Library/Extensions/NVRM.kext/Contents/MacOS/NVRM | cut -c1-12)  target ${W}x${H} hz ${HZ}"
T0=$(date '+%F %T')
launchctl asuser "$UIDN" sudo -u "$U" "$HERE/modeprobe" "$W" "$H" "$HOLD" "$HZ" "$( [ "$KIND" = lo ] && echo lo || echo hi )" &
P=$!
verdict=""
for i in $(seq 1 40); do
  sleep 0.5
  L=$(/usr/bin/log show --start "$T0" --predicate 'sender == "NVRMFB" AND eventMessage CONTAINS "switchMode"' --style compact 2>/dev/null | grep switchMode | grep -v "0x1:" )
  if printf '%s\n' "$L" | grep -q -E -- "-> 0 |FAILED|REFUSED"; then verdict=FAIL; break; fi
  if printf '%s\n' "$L" | grep -q "COMMIT.* -> 1 "; then verdict=OK; break; fi
done
printf '%s\n' "$L" | sed 's/^.*NVRM-fb: //' | sort -u
echo "== verdict: ${verdict:-UNKNOWN}"
# Only an explicit refusal restarts WindowServer; a late log line (UNKNOWN) just waits for modeprobe to switch back.
if [ "$verdict" = FAIL ]; then
  kill "$P" 2>/dev/null
  echo "restarting WindowServer"; sysctl -w debug.nvaccel_iop=1 >/dev/null; sleep 0.5; killall -9 WindowServer
  exit 2
fi
wait "$P"
/usr/bin/log show --start "$T0" --predicate 'sender == "NVRMFB" AND eventMessage CONTAINS "switchMode"' --style compact 2>/dev/null | grep switchMode | sed 's/^.*NVRM-fb: //' | sort -u
echo "PROBE DONE"
