#!/bin/bash
# Boot-time capture for the "Wi-Fi never comes up after boot" bug: itlwm's verbose log wraps the 128 KB
# kernel message buffer in under a minute, so grab dmesg early. Run by LaunchDaemon local.wifibootlog.
D=/var/log/wifi-bootlog; IF=${WIFI_IF:-en2}; mkdir -p "$D"; chmod 755 "$D"
B=$(sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+),.*/\1/'); P="$D/$(date -r "$B" +%Y%m%d-%H%M%S)"
{ echo "msgbuf before: $(sysctl -n kern.msgbuf)"; sysctl -w kern.msgbuf=1048576 2>&1; echo "msgbuf after: $(sysctl -n kern.msgbuf)"; } > "$P-info.txt"
# One-shot kernel stack sampling over the firmware-load window (armed by: install.sh spindump).
if [ -f "$D/do-spindump" ]; then
  rm -f "$D/do-spindump"
  spindump kernel_task 12 10 -noProcessingWhileSampling -o "$P-spindump.txt" >/dev/null 2>&1 &
fi
for t in 60 120 180; do
  while [ $(( $(date +%s) - B )) -lt $t ]; do sleep 2; done
  { echo "== uptime ${t}s"; ifconfig "$IF" 2>&1 | grep -E "flags|status|inet "; } >> "$P-info.txt"
  dmesg > "$P-t$t.txt" 2>&1
done
wait
chmod 644 "$D"/*
ls -1t "$D"/*-info.txt | tail -n +11 | while read f; do rm -f "${f%-info.txt}"-*; done   # keep 10 boots
