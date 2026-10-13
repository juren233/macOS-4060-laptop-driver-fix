#!/bin/bash
# Records USB port state so a "wired mouse/speakers vanished" event can be traced afterwards. Polls every 2 s (30 ms per poll) and
# writes a line only when something changes: per-port status / connect count / enumeration failures / over-current, the USB device
# list, and the power source. On a port or device change it also saves the USB stack's log from 60 s before to 30 s after the event
# (log show of what the system keeps anyway). No live `log stream`: a debug-level stream makes every process emit its debug messages
# (~1700/s system-wide, log + diagnosticd ~9% CPU idle, ~30% during video) and it caught almost nothing the stored log lacks.
# Run by LaunchDaemon local.usbwatch.
D=/var/log/usb-watch; mkdir -p "$D"; chmod 755 "$D"
L="$D/usb-watch.log"
PRED='sender CONTAINS "USB" OR process == "usbd" OR (process == "kernel" AND eventMessage CONTAINS[c] "usb")'
ports() {
  ioreg -r -c AppleUSBHostPort -l -w0 | awk '
    /\+-o (HS|SS)[0-9]+@/ { n=$0; sub(/.*\+-o /,"",n); sub(/@.*/,"",n); name=n }
    name && /"port-status" =/ { ps=$NF }
    name && /"kPortStatConnectCount"/ {
      c=$0; sub(/.*"kPortStatConnectCount"=/,"",c); sub(/[^0-9].*/,"",c)
      e=$0; sub(/.*"kPortStatEnumerationFailureCount"=/,"",e); sub(/[^0-9].*/,"",e)
      o=$0; sub(/.*"kPortStatOverCurrentCount"=/,"",o); sub(/[^0-9].*/,"",o)
      printf "%s status=%s connects=%s enumfail=%s overcurrent=%s\n", name, ps, c, e, o; name="" }'
}
devices() { ioreg -p IOUSB -w0 | sed -n 's/.*+-o \(.*\)@\([0-9a-f]*\)  <class.*/\1@\2/p' | grep -v "Root Hub" | sort; }
power()   { pmset -g batt | sed -n "1s/Now drawing from //p;2s/^ *-[^	]*	*\([0-9]*%\); *\([a-z ]*\);.*/ \1 \2/p" | tr -d '\n'; echo; }
rotate()  { [ "$(stat -f %z "$L" 2>/dev/null || echo 0)" -gt 4000000 ] && mv -f "$L" "$L.1"; }
say() { echo "$(date '+%F %T') $*" >> "$L"; }
# USB log around an event, in its own file: 60 s before now, then (in the background, polling goes on) the 30 s after
capture() {
  local t f; t=$(date '+%F %T'); f="$D/event-$(date '+%Y%m%d-%H%M%S').log"
  say "  USB log around this event -> $f"
  { echo "== $t: 60 s before"; /usr/bin/log show --last 60s --info --debug --style compact --predicate "$PRED" 2>/dev/null | cut -c1-300; } > "$f"
  ( sleep 30; { echo "== 30 s after $t"; /usr/bin/log show --start "$t" --info --debug --style compact --predicate "$PRED" 2>/dev/null | cut -c1-300; } >> "$f" ) &
  ls -t "$D"/event-*.log 2>/dev/null | tail -n +51 | xargs rm -f 2>/dev/null   # keep the newest 50 events
}
say "== start boot=$(sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+),.*/\1/' | xargs -I{} date -r {} '+%F %T') power=$(power)"
P="$(ports)"; V="$(devices)"; W="$(power)"; echo "$P" | sed "s/^/  /" >> "$L"; echo "$V" | sed "s/^/  dev /" >> "$L"
i=0
while sleep 2; do
  i=$((i+1)); np="$(ports)"; nv="$(devices)"; nw="$(power)"
  if [ "$np" != "$P" ]; then
    say "ports changed:"; diff <(echo "$P") <(echo "$np") | grep '^[<>]' | sed 's/^/    /' >> "$L"
  fi
  if [ "$nv" != "$V" ]; then say "devices changed:"; diff <(echo "$V") <(echo "$nv") | grep '^[<>]' | sed 's/^/    /' >> "$L"; fi
  [ "$nw" != "$W" ] && say "power: $W -> $nw"
  if [ "$np" != "$P" ] || [ "$nv" != "$V" ]; then capture; fi
  P="$np"; V="$nv"; W="$nw"
  [ $((i % 300)) -eq 0 ] && { say "heartbeat power=$W"; echo "$P" | sed 's/^/  /' >> "$L"; echo "$V" | sed 's/^/  dev /' >> "$L"; rotate; }
done
