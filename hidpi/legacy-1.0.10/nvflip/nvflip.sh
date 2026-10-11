#!/bin/sh
# Turns on NullMoth's zero-copy scanout (debug.nvaccel_iop_flip=1) after boot. -nvrmnoflip stays in boot-args, so
# removing this LaunchDaemon is enough to go back to the copying path. Same timing as NVRM's own auto-go: wait until
# the display pipe is armed (debug.nvaccel_iop=1), then 60 s more.
LOG=/var/log/nvflip.log
i=0
while [ "$(/usr/sbin/sysctl -n debug.nvaccel_iop 2>/dev/null)" != 1 ] && [ $i -lt 300 ]; do sleep 1; i=$((i + 1)); done
if [ "$(/usr/sbin/sysctl -n debug.nvaccel_iop 2>/dev/null)" != 1 ]; then echo "$(date '+%F %T') display pipe never armed -- zero-copy left OFF" >> $LOG; exit 0; fi
sleep 60
/usr/sbin/sysctl -w debug.nvaccel_iop_flip=1 >/dev/null 2>&1
echo "$(date '+%F %T') debug.nvaccel_iop_flip=$(/usr/sbin/sysctl -n debug.nvaccel_iop_flip 2>/dev/null) (armed after ${i}s + 60s)" >> $LOG
