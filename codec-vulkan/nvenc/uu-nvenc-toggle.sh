#!/bin/zsh
# Toggle NullMoth's NVENC (nvmtl hardware H.264/HEVC encoder) off/on via the driver knob file.
# Same marked block the NullMoth app writes for the "nvenc-blackwell-only" rule on Turing/Ampere/Ada.
#   sudo zsh uu-nvenc-toggle.sh off   # disable NVENC (apps fall back to Apple's software encoder)
#   sudo zsh uu-nvenc-toggle.sh on    # remove the block again
set -e
CONF=/Library/GPUBundles/nvmtl/nvrm610.conf
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
[[ -f $CONF ]] || { echo "missing $CONF"; exit 1; }
cp -p "$CONF" "$CONF.bak-$(date +%Y%m%d-%H%M%S)"
sed -i '' '/^# --- 1401 per-system rules ---$/,/^# --- end 1401 per-system rules ---$/d' "$CONF"
case "$1" in
  off)
    { echo "# --- 1401 per-system rules ---"
      echo "NVMTL_NO_NVENC=1"
      echo "NVMTL_NO_NVENC_HEVC=1"
      echo "# --- end 1401 per-system rules ---"; } >> "$CONF"
    echo "NVENC disabled" ;;
  on) echo "NVENC enabled (rules block removed)" ;;
  *) echo "usage: $0 off|on"; exit 1 ;;
esac
echo "---- $CONF"; cat "$CONF"
