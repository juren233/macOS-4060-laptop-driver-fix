#!/bin/zsh
# Less CPU for H.264 video (RTX 40): install the t2d8 decoder with a sleeping NVDEC wait as libnvdec_h264_t2d.dylib. decode_pending
# spun on the completion semaphore + clock_gettime for the whole hardware decode (no sleep at all; the HEVC decoder sleeps 50 us per
# poll). nvdec-patched/mk-sleep.py makes it poll every 50 us (mach_wait_until): CPU per frame 4K 8.0 -> 3.7 ms, 1080p 2.45 -> 0.86 ms,
# 720p 1.64 -> 0.48 ms, same wall time, every decoded picture identical (nvdec-patched/decbench).
#   sudo zsh nvdec-sleep.sh install    gates: hashes, signature, dectest bit-exact (1080p + 4K), decbench (same pictures, less CPU),
#                                      VideoToolbox registration under library validation; then the guard pins it
#   sudo zsh nvdec-sleep.sh restore    back to the spinning 8-byte build 703c1f2c (and the guard pins it)
set -u
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
HERE=${0:A:h}; M=/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS; T=$M/libnvdec_h264_t2d.dylib
U=${SUDO_USER:-$(stat -f %Su /dev/console)}
NEW=$HERE/nvdec-patched/h264.t2d8s.dylib; OLD=$HERE/nvdec-patched/h264.t2d8.dylib
NEW_SHA=e641afb31e8cab30b13352f9d9e5cacd460d4ba3fcdbe6a2430093dbedece453; OLD_SHA=703c1f2c1666684b30fc3e17d97e09abb9dfecf03f586ee08488baa8dc39a6d8
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
# New inode (copy beside, then rename): overwriting a loaded dylib in place -> "Code Signature Invalid" SIGKILLs.
put() { cp "$1" "$2.new.$$" && chown root:wheel "$2.new.$$" && chmod 755 "$2.new.$$" && mv -f "$2.new.$$" "$2"; }
asuser() { launchctl asuser "$(id -u "$U")" sudo -u "$U" "$@"; }
restore() { put $OLD $T && NVGUARD_T2D=t2d8 zsh $HERE/nvguard/install.sh >/dev/null && killall VTDecoderXPCService 2>/dev/null; echo "spinning decoder ${OLD_SHA[1,8]} restored and pinned"; }
case ${1:-} in
  restore) [[ $(sha $OLD) == $OLD_SHA ]] || { echo "STOP: $OLD is not the expected build"; exit 1; }; restore; exit ;;
  install) ;;
  *) echo "usage: sudo zsh $0 install|restore"; exit 1 ;;
esac
[[ $(sha $NEW) == $NEW_SHA && $(sha $OLD) == $OLD_SHA ]] || { echo "STOP: staged decoders are not the tested builds"; exit 1; }
codesign --verify --strict $NEW 2>/dev/null && codesign -dv $NEW 2>&1 | grep -q "Signature=adhoc" || { echo "STOP: $NEW is not validly (ad-hoc) signed"; exit 1; }
for sz in "1920 1080" "3840 2160"; do
  R=$(cd /private/tmp && asuser $HERE/nvdec-patched/dectest $NEW ${=sz} 2>/dev/null | grep RESULT)
  echo "dectest $sz: $R"
  [[ $R == *"luma 99.0 dB, worst chroma 99.0 dB"* ]] || { echo "STOP: not bit-exact - nothing installed"; exit 1; }
done
B1=$(cd /private/tmp && asuser $HERE/nvdec-patched/decbench $OLD h264 1920 1080 60 4 2>/dev/null | tail -1)
B2=$(cd /private/tmp && asuser $HERE/nvdec-patched/decbench $NEW h264 1920 1080 60 4 2>/dev/null | tail -1)
echo "decbench old: $B1"; echo "decbench new: $B2"
[[ -n $B1 && ${B1##*checksum } == ${B2##*checksum } && $B2 == *"errors 0"* ]] || { echo "STOP: decoded pictures differ - nothing installed"; exit 1; }
c1=${${B1#*CPU }%% ms*}; c2=${${B2#*CPU }%% ms*}
(( c2 < c1 * 0.7 )) || { echo "STOP: no CPU saving ($c1 -> $c2 ms/frame) - nothing installed"; exit 1; }
echo "installed now: $(sha $T | cut -c1-8)  ->  installing ${NEW_SHA[1,8]}"
put $NEW $T || { echo "STOP: copy failed"; exit 1; }
# vtreg in a library-validation process (Chrome's GPU process and VTDecoderXPCService load this file the same way)
LVD=$(mktemp -d /private/tmp/t2d8s-lv.XXXXXX); cp ${HERE:h}/nvidia-setup/hidpi/catest/vtreg $LVD/vtreg-lv && codesign -f -s - -o library $LVD/vtreg-lv 2>/dev/null; chmod -R a+rX $LVD
LVT=$(date '+%Y-%m-%d %H:%M:%S')
V=$(cd /private/tmp && asuser $LVD/vtreg-lv 2>/dev/null | tail -1); rm -rf $LVD; sleep 2
LVF=$(/usr/bin/log show --start "$LVT" --style compact --predicate 'eventMessage CONTAINS "Library Validation failed" AND eventMessage CONTAINS "nvdec"' 2>/dev/null | grep -c Rejecting)
echo "H.264 decoder registered under library validation (vtreg) -> $V; rejections: $LVF"
[[ $V == PASS && $LVF == 0 ]] || { echo "FAILED"; restore; exit 1; }
zsh $HERE/nvguard/install.sh >/dev/null || { echo "STOP: guard re-pin failed"; restore; exit 1; }
echo "guard pins ${NEW_SHA[1,8]}: $(sha $T | cut -c1-8) installed"
# VTDecoderXPCService instances keep the old copy mapped; the next video starts a fresh one.
killall VTDecoderXPCService 2>/dev/null || true
echo "done - reopen Chrome (or any app that was playing video) to load it; no reboot needed (WindowServer does not load the decoder)."
echo "rollback: sudo zsh ~/work/system/nvdec-sleep.sh restore"
