#!/bin/zsh
# System sleep, step 2: after the reboot that follows enable-sleep.sh, check that NVRM joined the power tree and the
# desktop is unchanged. Changes nothing; no sudo needed.   zsh ~/work/nvidia-setup/sleep/check-sleep.sh
HERE=${0:A:h}
bad=0
ok()   { print -r -- "   ok   $*"; }
fail() { print -r -- "   FAIL $*"; bad=$((bad+1)); }
note() { print -r -- "   note $*"; }

print "== boot"
BA=$(sysctl -n kern.bootargs)
[[ " $BA " == *" -nvrmnopm "* ]] && fail "boot-args still have -nvrmnopm (enable-sleep.sh not run, or efiguard put it back: tail /var/log/efiguard.log)" || ok "no -nvrmnopm in boot-args"
for a in nvfbhidpi=1 nvrmmapowner=0; do [[ " $BA " == *" $a "* ]] && ok "$a" || fail "boot-arg $a missing"; done
for k in NVRM NVRMFB NVAccel NVRMAGDC; do
  kextstat 2>/dev/null | grep -q "com.nullmoth.$k (2.3.7)" && ok "$k 2.3.7 loaded" || fail "$k 2.3.7 not loaded"
done
BT=$(sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+),.*/\1/')
NP=0; for f in /Library/Logs/DiagnosticReports/*.panic(N); do (( $(stat -f %m $f) >= BT )) && { NP=$((NP+1)); note "panic report since boot: ${f:t}"; }; done
(( NP == 0 )) && ok "no panic report since boot" || fail "$NP panic report(s) since boot"

print "== NVRM power management"
PM=$(ioreg -r -c NVRM -d1 -l | awk -F'"' '/"nvrm-pm"/{print $4; exit}')
[[ $PM == running ]] && ok "nvrm-pm = running" || fail "nvrm-pm = '${PM:-?}' (want running)"
B=$(date -r $BT '+%Y-%m-%d %H:%M:%S')
L=$(/usr/bin/log show --start "$B" --predicate 'process == "kernel" AND (eventMessage CONTAINS "power management" OR eventMessage CONTAINS "PreserveVideoMemoryAllocations")' --style compact 2>/dev/null | cut -c1-220)
[[ $L == *"joined the power tree"* ]] && ok "kernel log: NVRM joined the power tree" || fail "kernel log has no 'joined the power tree' line"
[[ $L == *"PreserveVideoMemoryAllocations=1"* ]] && ok "kernel log: PreserveVideoMemoryAllocations=1 (all VRAM kept across sleep)" || fail "kernel log has no PreserveVideoMemoryAllocations=1 line"
print -r -- "   debug.nvrm_pm_waited $(sysctl -n debug.nvrm_pm_waited 2>/dev/null)   debug.nvaccel_vm_sticky $(sysctl -n debug.nvaccel_vm_sticky 2>/dev/null)"
[[ $(sysctl -n debug.nvaccel_vm_sticky 2>/dev/null) == 1 ]] && ok "NVAccel sticky VRAM on" || fail "debug.nvaccel_vm_sticky is not 1"

print "== power settings"
pmset -g | grep -Eq "SleepDisabled[[:space:]]+1" && ok "SleepDisabled 1 (sleep still off until sleep-test.sh)" || note "SleepDisabled is not 1"
H=$(pmset -g custom | awk '$1=="hibernatemode"{print $2}' | sort -u | tr '\n' ' ')
[[ $H == "0 " ]] && ok "hibernatemode 0 on AC and battery" || fail "hibernatemode is '$H' (want 0: hibernation is untested)"
[[ -f /Library/NullMoth/sleeptest-active ]] && note "an unfinished sleep test left /Library/NullMoth/sleeptest-active"

print "== desktop"
D=$(system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Resolution|UI Looks like" | sed 's/^ *//' | tr '\n' ' ')
note "display: $D"
print -r -- "   (optional, for the GPU path: zsh ${HERE:h}/hidpi/check-wsmark.sh)"

print
(( bad == 0 )) && print "ALL OK - next: sudo bash $HERE/sleep-test.sh  (read README.md first)" || print "$bad problem(s) - do not run sleep-test.sh; undo with: sudo bash $HERE/rollback-sleep.sh"
