#!/bin/bash
# Run with sudo. Installs NullMoth's Metal plugin rebuilt from source (plugin/stale-texture-fix.patch). Core Animation
# hands WindowServer small layer contents as memory it keeps rewriting; when the driver could not map that memory for
# the GPU it kept a one-time copy, so the layer showed old bytes (black bars, stale text in Finder's sidebar, black
# window corners). Those copies are now refreshed whenever the texture is used. This build also logs IOSurface uploads
# ("NullMoth-diag" in the system log) and skips uploading a surface's CPU pages over shared VRAM that this process still
# has GPU writes in flight for (NVMTL_SURFIN_GUARD=0 in nvrm610.conf switches that off). Running WindowServer keeps the old
# plugin until the reboot. Undo with revert-plugin-fix.sh.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
GB=/Library/GPUBundles; B=$GB/NVMTLDriver.bundle; BK=$HERE/backup/NVMTLDriver.bundle.orig; U=${SUDO_USER:-$(stat -f %Su /dev/console)}
[ -d "$BK" ] || { mkdir -p "$HERE/backup" && ditto "$B" "$BK" && echo "original plugin backed up to $BK"; } || { echo "STOP: backup failed"; exit 1; }
# Stage from the LIVE bundle, not the stock backup: it carries the separately patched codec dylibs
# (~/work/system/nvdec-t2d.sh, uu-nvenc-t2d.sh), which a copy of the backup would silently wipe.
TMP=$(mktemp -d /private/var/tmp/nvmtl.XXXXXX); ST=$TMP/NVMTLDriver.bundle; PREV=$TMP/prev.bundle
ditto "$B" "$PREV" && cp -Rp "$PREV" "$ST" && cp "${PLUGIN_SRC:-$HERE/plugin/NVMTLDriver}" "$ST/Contents/MacOS/NVMTLDriver" || { echo "STOP: staging failed"; exit 1; }
# The shader translator rebuilt from source (plugin/raster-samples.patch): a fragment shader's get_num_samples() - ANGLE
# emits it for WebGL - failed to translate, Chrome took that as a lost GPU context and restarted its GPU process (windows
# flashed blank). It is now a specialization constant the plugin fills with the pipeline's sample count.
if [ -f "$HERE/plugin/libnvmtl_translate.dylib" ]; then cp "$HERE/plugin/libnvmtl_translate.dylib" "$ST/Contents/MacOS/libnvmtl_translate.dylib" || { echo "STOP: staging the translator failed"; exit 1; }; fi
# Only the executable is replaced (ad-hoc signed on its own). NullMoth's bundle seal is already incomplete (its air-runtime
# text files are not sealed) and loads fine with the boot-args' AMFI settings, so the bundle is not re-signed.
codesign -dv "$ST/Contents/MacOS/NVMTLDriver" 2>&1 | grep -q "Identifier=com.nullmoth.NVMTLDriver" || { echo "STOP: plugin executable is not signed"; exit 1; }
rm -rf "$B" && ditto "$ST" "$B" && chown -R root:wheel "$B" && chmod -R a+rX "$B" || { echo "STOP: copy failed, restoring"; rm -rf "$B"; ditto "$PREV" "$B"; exit 1; }
echo "patched plugin installed: $(shasum -a 256 "$B/Contents/MacOS/NVMTLDriver" | cut -c1-16), translator $(shasum -a 256 "$B/Contents/MacOS/libnvmtl_translate.dylib" | cut -c1-16)"
# A new process loads the new plugin: check that buffer writes now reach the texture.
T1=$(launchctl asuser "$(id -u "$U")" sudo -u "$U" "$HERE/catest/tiledtex" 2>/dev/null | tail -1)
T2=$(launchctl asuser "$(id -u "$U")" sudo -u "$U" "$HERE/catest/hostcopy" 2>/dev/null | tail -1)
O3=$(launchctl asuser "$(id -u "$U")" sudo -u "$U" "$HERE/catest/surftex" 64 64 2>/dev/null); T3=$(echo "$O3" | tail -1)
O4=""; T4="stale reads: 0"
for i in 1 2 3; do  # timing-dependent: run the framebuffer-sized case three times
  O=$(launchctl asuser "$(id -u "$U")" sudo -u "$U" "$HERE/catest/surftex" 2560 1440 2>/dev/null); O4="$O4$O"$'\n'
  [ "$(echo "$O" | tail -1)" = "stale reads: 0" ] || T4=$(echo "$O" | tail -1); done
O5=$(launchctl asuser "$(id -u "$U")" sudo -u "$U" "$HERE/catest/surfasync" 2>/dev/null); T5=$(echo "$O5" | tail -1)
O6=$(launchctl asuser "$(id -u "$U")" sudo -u "$U" "$HERE/catest/nsamp" 2>/dev/null); T6=$(echo "$O6" | tail -1)
O7=$(launchctl asuser "$(id -u "$U")" sudo -u "$U" "$HERE/catest/usecount" 2>/dev/null); T7=$(echo "$O7" | tail -1)
O8=$(launchctl asuser "$(id -u "$U")" sudo -u "$U" "$HERE/catest/gfx2" 6 2>/dev/null); T8=$(echo "$O8" | tail -1)
O9=$(launchctl asuser "$(id -u "$U")" sudo -u "$U" "$HERE/catest/nv12planes" 2>/dev/null); T9=$(echo "$O9" | tail -1 | cut -c1-4)
echo "self-test: tiled texture copy -> $T1; texture over copied memory -> $T2"
echo "           CPU-written IOSurfaces re-uploaded asynchronously (surfasync) -> $T5"
echo "           second texture on a GPU-written IOSurface: small -> $T3; framebuffer-sized -> $T4"
echo "           fragment get_num_samples() at 1x / 4x MSAA (nsamp) -> $T6"
echo "           IOSurface reported in use while GPU work references it (usecount) -> $T7"
echo "           partial redraws into a small IOSurface target with frames in flight (gfx2) -> $T8"
echo "           NV12 chroma plane sampled after a GPU write to the luma plane (nv12planes) -> $T9"
if [ "$T1" = "stale reads: 0" ] && [ "$T2" = "stale reads: 0" ] && [ "$T3" = "stale reads: 0" ] && [ "$T4" = "stale reads: 0" ] && [ "$T5" = "stale reads: 0" ] && [ "$T6" = "PASS" ] && [ "$T7" = "PASS" ] && [ "$T8" = "PASS" ] && [ "$T9" = "PASS" ]; then echo "self-test OK (memory writes reach the textures)"
else echo "$O3$O4$O5$O6$O7$O8" | grep -E "STALE|OLDER|WRONG|FAILED"; echo "self-test FAILED -- restoring the previous plugin"; rm -rf "$B"; ditto "$PREV" "$B"; chown -R root:wheel "$B"; exit 1; fi
echo; echo "DONE. Reboot now so WindowServer and every app load it."
