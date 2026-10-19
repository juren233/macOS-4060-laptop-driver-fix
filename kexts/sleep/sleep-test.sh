#!/bin/bash
# System sleep, step 3: ONE timed sleep. Opens sleep (SleepDisabled 0), schedules a wake N seconds out
# (default 45, 30..300), sleeps now, then closes sleep again (SleepDisabled 1) and writes an evidence report.
#   sudo bash ~/work/nvidia-setup/sleep/sleep-test.sh [seconds]
# If the screen stays black after the wake, the script keeps running and still writes its report; after a forced
# power-off a one-shot boot daemon sets SleepDisabled 1 again, so the lid cannot put the broken path to sleep.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
die() { echo "STOP: $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
SEC=${1:-45}; case "$SEC" in ''|*[!0-9]*) die "seconds must be a number";; esac
[ "$SEC" -ge 30 ] && [ "$SEC" -le 300 ] || die "seconds must be 30..300"
MARK=/Library/NullMoth/sleeptest-active; GPL=/Library/LaunchDaemons/local.sleeptest.guard.plist
nvrmpm() { ioreg -r -c NVRM -d1 -l | awk -F'"' '/"nvrm-pm"/{print $4; exit}'; }

echo "== 1. preconditions"
[ "$(nvrmpm)" = running ] || die "nvrm-pm is '$(nvrmpm)', not running: run enable-sleep.sh + reboot + check-sleep.sh first"
case " $(sysctl -n kern.bootargs) " in *" -nvrmnopm "*) die "-nvrmnopm is still in the boot-args";; esac
pmset -g batt | grep -q "AC Power" || die "plug in the charger (first test on AC)"
[ "$(pmset -g custom | awk '$1=="hibernatemode"{print $2}' | sort -u | tr '\n' ' ')" = "0 " ] || die "hibernatemode is not 0 everywhere"
[ -e "$MARK" ] && die "$MARK exists: an earlier test did not finish - look at its report first, then remove it"
WSPID=$(pgrep -x WindowServer | head -1); [ -n "$WSPID" ] || die "no WindowServer"
echo "   ok: NVRM running, AC power, hibernatemode 0, WindowServer pid $WSPID, wake in $SEC s"
echo
echo "   Save your work first. If the screen stays black after the wake:"
echo "     wait 2 minutes (the report is still being written), press a key once,"
echo "     then hold the power button 10 s. The next boot puts SleepDisabled back to 1 by itself."
printf "   Type yes to sleep now: "; read -r ans; [ "$ans" = yes ] || die "not confirmed - nothing changed"

EV=$HERE/evidence/test-$(date +%Y%m%d-%H%M%S); mkdir -p "$EV" || die "cannot create $EV"
T0=$(date '+%Y-%m-%d %H:%M:%S'); echo "$T0" > "$EV/start.txt"
CTRS="debug.nvrm_pm_waited debug.nvaccel_vm_parked debug.nvaccel_vm_unparked debug.nvaccel_vm_park_released debug.nvaccel_surface_gpu_timeouts"
sysctl $CTRS > "$EV/counters-before.txt" 2>&1

echo "== 2. one-shot boot guard (removed again when this test finishes)"
mkdir -p /Library/NullMoth; : > "$MARK"
cat > "$GPL" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>local.sleeptest.guard</string>
	<key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>if [ -e /Library/NullMoth/sleeptest-active ]; then /usr/bin/pmset -a disablesleep 1; echo "$(date '+%F %T') boot after an unfinished sleep test: SleepDisabled 1 restored" >> /var/log/sleeptest.log; rm -f /Library/NullMoth/sleeptest-active; fi; rm -f /Library/LaunchDaemons/local.sleeptest.guard.plist</string></array>
	<key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
chown root:wheel "$GPL"; chmod 644 "$GPL"; plutil -lint "$GPL" >/dev/null || die "guard plist invalid"
# not bootstrapped now: launchd loads it at the next boot only (RunAtLoad would close sleep right away)
SLEPT=0
closesleep() { pmset -a disablesleep 1; }
onexit() { closesleep; [ "$SLEPT" = 0 ] && rm -f "$MARK" "$GPL"; }
trap onexit EXIT
echo "   ok"

echo "== 3. sleep (wake scheduled in $SEC s)"
pmset -a disablesleep 0 || die "pmset disablesleep 0 failed"
pmset relative wake "$SEC" || die "pmset relative wake failed"
sync; sleep 2
SLEPT=1; pmset sleepnow
# wait for the full wake: a "Wake" line after T0 in the pmset log (a timer wake can stop at DarkWake with the
# display off until a key is pressed). At most SEC + 300 s, 2 s steps.
W=""; i=0; MAXI=$(( (SEC + 300) / 2 ))
while [ $i -lt $MAXI ]; do
  W=$(pmset -g log | awk -v t="$T0" '$1" "$2 >= t && $4 == "Wake" && $5 != "Requests"' | tail -1)   # not "Wake Requests"
  [ -n "$W" ] && break; sleep 2; i=$((i+1))
done
closesleep; echo "   SleepDisabled 1 again"
[ -n "$W" ] && echo "   $W" || echo "   no full Wake line in the pmset log after $(( MAXI * 2 )) s"
echo "   settling 20 s"; sleep 20

echo "== 4. report ($EV)"
pmset -g log | awk -v t="$T0" '$1" "$2 >= t' | grep -E "\+[0-9]{4} +(Sleep|Wake|DarkWake|Failure) " | head -40 > "$EV/pmset-log.txt"
/usr/bin/log show --start "$T0" --predicate 'process == "kernel" AND (eventMessage CONTAINS "NVRM-xnu: sleep" OR eventMessage CONTAINS "NVRM-xnu: wake" OR eventMessage CONTAINS "NVRM-xnu: power" OR eventMessage CONTAINS "VRAM save" OR eventMessage CONTAINS "NVRM-fb: system wake" OR eventMessage CONTAINS "Xid" OR eventMessage CONTAINS "GSP" OR eventMessage CONTAINS "NVKMS" OR eventMessage CONTAINS "gpu lost")' --style compact 2>/dev/null | cut -c1-300 | head -400 > "$EV/kernel-nv.txt"
/usr/bin/log show --start "$T0" --predicate 'process == "kernel" AND (eventMessage CONTAINS[c] "wake reason" OR eventMessage CONTAINS "Wake reason")' --style compact 2>/dev/null | cut -c1-300 | head -40 > "$EV/wake-reason.txt"
sysctl $CTRS > "$EV/counters-after.txt" 2>&1
PM=$(nvrmpm); WS2=$(pgrep -x WindowServer | head -1)
BT=$(sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+),.*/\1/')
NP=0; for f in /Library/Logs/DiagnosticReports/*.panic; do [ -e "$f" ] && [ "$(stat -f %m "$f")" -ge "$BT" ] && NP=$((NP+1)); done
{
  echo "start $T0, wake scheduled after $SEC s"
  echo "pmset wake line: ${W:-none}"
  echo "nvrm-pm after: $PM"
  echo "WindowServer pid before $WSPID, after ${WS2:-none}"
  echo "panic reports since boot: $NP"
} > "$EV/summary.txt"

v=PASS; why=""
[ -n "$W" ] || { v=FAIL; why="$why no-wake-line"; }
[ "$PM" = running ] || { v=FAIL; why="$why nvrm-pm=$PM"; }
grep -q "NVRM-xnu: sleep #" "$EV/kernel-nv.txt" || { v=FAIL; why="$why no-sleep-line"; }
grep -q "GPU running, telling the framebuffers" "$EV/kernel-nv.txt" || { v=FAIL; why="$why no-gpu-resume-line"; }
grep -q "NVRM-fb: system wake: clients told DidWake" "$EV/kernel-nv.txt" || { v=FAIL; why="$why no-fb-wake-line"; }
[ "$WS2" = "$WSPID" ] || { v=FAIL; why="$why windowserver-restarted"; }
grep -q "Failure" "$EV/pmset-log.txt" && { v=FAIL; why="$why pmset-failure"; }
[ "$NP" -eq 0 ] || { v=FAIL; why="$why panic"; }
echo "verdict: $v${why:+ ($why )}" | tee -a "$EV/summary.txt"
sed 's/^/   /' "$EV/summary.txt"
grep -E "sleep #|wake #|VRAM save|system wake" "$EV/kernel-nv.txt" | sed 's/^/   /' | head -12

rm -f "$MARK" "$GPL"
echo
echo "Now check by eye: picture, brightness keys, Wi-Fi, Bluetooth, touchpad, sound. Sleep is OFF again (SleepDisabled 1)."
