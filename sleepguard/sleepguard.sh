#!/bin/zsh
# ============================================================================================================
# LOCAL HARDENING - DO NOT EDIT, DELETE OR "CLEAN UP" THIS FILE OR /Library/NullMoth/sleepguard.
# System sleep is only safe while the NullMoth kernel can suspend and resume the GPU (NVRM in the power tree,
# ioreg NVRM "nvrm-pm" = running, i.e. 2.3.7+ kexts without the -nvrmnopm boot-arg). Without that, a sleep
# leaves the screen black until a forced power-off (see nvidia-setup/sleep/README.md).
# Run by LaunchDaemon local.sleepguard at boot and every 10 min. It makes SleepDisabled follow the driver:
#   wanted "on" + GPU suspend/resume available  -> SleepDisabled 0, hibernatemode 0
#   anything else (wanted "off", -nvrmnopm back, older kexts, "lost (resume failed)") -> SleepDisabled 1
# Install / switch: sudo zsh ~/work/system/sleepguard/install.sh on|off   Status: zsh install.sh status
# ============================================================================================================
G=${SLEEPGUARD_DIR:-/Library/NullMoth/sleepguard}
LOG=${SLEEPGUARD_LOG:-/var/log/sleepguard.log}
log() { print -r -- "$(date '+%F %T') $*" >> $LOG; }
nvrmpm() { ioreg -r -c NVRM -d1 -l 2>/dev/null | awk -F'"' '/"nvrm-pm"/{print $4; exit}'; }
disabled() { pmset -g 2>/dev/null | grep -Eq "SleepDisabled[[:space:]]+1"; }

want=$(cat $G/want 2>/dev/null); [[ $want == on ]] || want=off
# at boot NVRM may still be starting: wait for its property, at most 90 s
pm=$(nvrmpm); i=0
while [[ -z $pm && $i -lt 45 ]]; do sleep 2; pm=$(nvrmpm); i=$((i+1)); done
ba=$(sysctl -n kern.bootargs 2>/dev/null)

why=""
[[ $want == on ]] || why="sleep not wanted (install.sh off)"
[[ -z $why && " $ba " == *" -nvrmnopm "* ]] && why="boot-args have -nvrmnopm (NVRM outside the power tree)"
[[ -z $why && $pm != running ]] && why="NVRM nvrm-pm is '${pm:-absent}' - this driver cannot suspend/resume the GPU"

if [[ -n $why ]]; then
  if ! disabled; then pmset -a disablesleep 1 && log "SleepDisabled 1: $why" || log "FAILED to set SleepDisabled 1 ($why)"; fi
  exit 0
fi

# sleep is wanted and safe: S3 only (hibernation is untested with the GPU), then open sleep
for prof in -b -c; do
  h=$(pmset -g custom | awk -v p=$prof 'BEGIN{s=(p=="-b")?"Battery Power:":"AC Power:"} /^[^ \t]/{f=(index($0,s)==1);next} f&&$1=="hibernatemode"{print $2}')
  [[ -n $h && $h != 0 ]] && { pmset $prof hibernatemode 0 && log "hibernatemode $h -> 0 ($prof): hibernation is untested with the NullMoth GPU"; }
done
if disabled; then pmset -a disablesleep 0 && log "SleepDisabled 0: NVRM ${pm}, no -nvrmnopm" || log "FAILED to set SleepDisabled 0"; fi
exit 0
