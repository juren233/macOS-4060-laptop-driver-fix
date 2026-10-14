#!/bin/bash
# AppleHDADriver stays "!registered !matched" under AppleHDACodecGeneric on macOS 26 (no AppleHDAEngine, no built-in audio).
# Collect: kernel message buffer lines about alc/hda + a short kernel stack sample (keepsyms=1 is set, so kext frames are named).
# Run: sudo bash diag-hda-stuck.sh      -> audio/backup/diag-hda-stuck/
set -u
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd); O=$HERE/backup/diag-hda-stuck; mkdir -p "$O"
dmesg > "$O/dmesg.txt" 2>&1; grep -i -E 'alc|hda|lilu|audio' "$O/dmesg.txt" > "$O/dmesg-hda.txt"
spindump -noTarget 3 20 -o "$O/spindump.txt" >/dev/null 2>&1
grep -n -i -B2 -A25 'AppleHDA' "$O/spindump.txt" | head -150 > "$O/spindump-hda.txt"
ioreg -c AppleHDACodecGeneric -r -l -w0 > "$O/ioreg-codec.txt" 2>&1
ioreg -r -n HDEF -l -w0 > "$O/ioreg-hdef.txt" 2>&1
chown -R "$SUDO_USER" "$O"
echo "done -> $O  (dmesg lines: $(wc -l < "$O/dmesg-hda.txt"), hda stack lines: $(wc -l < "$O/spindump-hda.txt"))"
