#!/bin/zsh
# check-wsmark.sh [baseline] : after the reboot that loads plugin 1eae68fa into WindowServer (install-wsmark.sh), check the real
# WindowServer: (1) it sends its marks (debug.nvaccel_surface_gpu_marks grows; only WindowServer's marks are taken) with no
# swap timeouts, (2) a window capture (screencapture -l, SkyLight's capture path) shows the window's colour, not black, and
# (3) the frames it puts on screen while a vsync'd GL window animates are not fewer than the baseline recorded with the old
# plugin ("baseline" records it into hidpi/wsmark-baseline.txt; run that BEFORE the install). No sudo needed, nothing changed.
# Lock screen (no sleep): lock with Ctrl+Cmd+Q and unlock - the lock screen must show the wallpaper/user, not black.
set -u
HERE=${0:A:h}; C=$HERE/catest; P=/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver; BL=$HERE/wsmark-baseline.txt
TD=$(mktemp -d /private/tmp/wsmark-check.XXXXXX); trap 'rm -rf $TD' EXIT
sha() { shasum -a256 "$1" | cut -c1-8; }
k() { sysctl -n debug.nvaccel_surface_gpu_$1 2>/dev/null || echo -1; }
for f in $C/wincap $C/pngmean.py $C/gl236/glvsync $C/danmaku/tools/wsframes.sh; do [[ -f $f ]] || { echo "STOP: missing $f"; exit 1; }; done
echo "installed plugin $(sha $P); kernel: gpu_on $(k on), marks $(k marks), waits $(k waits), timeouts $(k timeouts), longest wait $(k wait_max_us) us"
# on-screen frames: WindowServer's per-update line counted for 5 s while glvsync animates (its own fps printed too), twice
frames() { local i; for i in 1 2; do
    (perl -e 'alarm 12; exec @ARGV' $C/gl236/glvsync 7 > $TD/gl.$i 2>/dev/null &) ; sleep 1.5
    zsh $C/danmaku/tools/wsframes.sh 5 2>/dev/null | sed -n 's/.*WS on screen \([0-9.]*\) fps.*/\1/p'; sleep 1.5; done | sort -n | tail -1; }
if [[ ${1:-} == baseline ]]; then
  F=$(frames); echo "$(date '+%F %T') plugin $(sha $P) onscreen ${F:-0}" >> $BL; echo "baseline recorded: plugin $(sha $P), WindowServer on screen ${F:-?} fps (glvsync)"; exit 0
fi
M0=$(k marks); T0=$(k timeouts)
F=$(frames)
# window capture of a window that keeps redrawing
$C/wincap 6 > $TD/wid 2>/dev/null & WP=$!
for i in {1..30}; do grep -q '^wid' $TD/wid && break; sleep 0.2; done
WID=$(sed -n 's/^wid //p' $TD/wid); sleep 1
CAP=NO; MEAN=""
if [[ -n $WID ]]; then
  for i in 1 2 3; do
    # screencapture fails outright ("could not create image") when this terminal has no Screen Recording permission (TCC);
    # that is not the driver - say so instead of calling the capture black
    if ! screencapture -x -o -l $WID $TD/w$i.png 2>/dev/null || [[ ! -s $TD/w$i.png ]]; then
      CAP="UNTESTED (screencapture refused: give this terminal Screen Recording in System Settings > Privacy & Security, or tccgrant)"; break; fi
    m=$(python3 -I $C/pngmean.py $TD/w$i.png 2>/dev/null); MEAN="$MEAN | $m"
    echo "$m" | python3 -I -c "import sys,re; v=[float(x) for x in re.findall(r'[0-9.]+', sys.stdin.read().split('mean')[-1])][:3]; sys.exit(0 if len(v)==3 and abs(v[0]-0.2)<0.08 and abs(v[1]-0.6)<0.08 and abs(v[2]-0.9)<0.08 else 1)" && CAP=yes || { CAP=NO; break; }
  done
fi
wait $WP 2>/dev/null
M1=$(k marks); T1=$(k timeouts)
MOK=$([[ $M1 -gt $M0 && $M0 -ge 0 ]] && echo yes || echo NO)
TOK=$([[ $T1 -eq $T0 ]] && echo yes || echo NO)
B=$(tail -1 $BL 2>/dev/null | sed -n 's/.*onscreen \([0-9.]*\).*/\1/p')
FOK=$([[ -n $B && -n $F ]] && python3 -c "print('yes' if $F >= 0.95 * $B else 'NO')" || echo "NO (no baseline: run check-wsmark.sh baseline on the old plugin)")
echo "WindowServer marks during the check: +$((M1 - M0)) -> $MOK; swap timeouts +$((T1 - T0)) -> $TOK"
echo "window capture (screencapture -l, expect 0.20 0.60 0.90):${MEAN:- (no capture)} -> $CAP"
echo "WindowServer on screen with a vsync'd GL window: ${F:-?} fps, baseline ${B:-none} (>= 0.95x) -> $FOK"
echo "glvsync: $(grep -h '^display' $TD/gl.* 2>/dev/null | tail -1)"
[[ $MOK == yes && $TOK == yes && $CAP == yes && $FOK == yes ]] && echo "ALL OK" || { echo "NEEDS ATTENTION (rollback: sudo zsh ~/work/system/nvguard/install.sh wsmarkprev, then reboot)"; exit 1; }
