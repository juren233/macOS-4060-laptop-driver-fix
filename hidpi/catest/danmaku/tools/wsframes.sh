#!/bin/zsh
# wsframes.sh SECONDS : frames WindowServer actually put on screen, counted from its per-update CoreDisplay debug line
# ("using last created GPU Gamma Table", one per display update, 6.06 ms multiples at 165 Hz). Needs no screen-recording permission.
# Chrome's rAF rate is NOT what reaches the screen: smart-mask danmaku = Chrome 165 fps, on screen ~90.
perl -e "alarm $1; exec @ARGV" /usr/bin/log stream --style ndjson --level debug --predicate 'process == "WindowServer" AND eventMessage CONTAINS "GPU Gamma"' 2>/dev/null | python3 -I -c '
import sys,json,datetime
t=[]
for l in sys.stdin:
  try: t.append(datetime.datetime.strptime(json.loads(l)["timestamp"][:26], "%Y-%m-%d %H:%M:%S.%f").timestamp())
  except Exception: pass
d=sorted((b-a)*1000 for a,b in zip(t,t[1:])); n=len(d); span=t[-1]-t[0]
print("  WS on screen %.1f fps, p50 %.1f p95 %.1f max %.1f ms, >12 ms %d, >20 ms %d" % (n/span, d[n//2], d[int(n*.95)], d[-1], sum(x>12 for x in d), sum(x>20 for x in d)))'
