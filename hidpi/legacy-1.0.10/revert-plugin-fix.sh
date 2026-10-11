#!/bin/bash
# Run with sudo. Puts NullMoth's original Metal plugin back (backed up by install-plugin-fix.sh). Reboot afterwards.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
BK=$HERE/backup/NVMTLDriver.bundle.orig; B=/Library/GPUBundles/NVMTLDriver.bundle
[ -d "$BK" ] || { echo "STOP: no backup at $BK"; exit 1; }
# Only the executable goes back: the codec dylibs in the bundle may carry separate patches (nvdec-t2d.sh, uu-nvenc-t2d.sh).
E=$B/Contents/MacOS/NVMTLDriver
cp "$BK/Contents/MacOS/NVMTLDriver" "$E.new.$$" && chown root:wheel "$E.new.$$" && chmod 755 "$E.new.$$" && mv -f "$E.new.$$" "$E" && echo "original plugin restored. Reboot now."
