#!/bin/zsh
# Snapshot of everything that makes this Hackintosh's GPU stack work, as one tar (no sudo needed for the files below; the EFI partition
# needs sudo - see wifibt/backup/esp-OC-*.tar for the existing EFI backups). COPY THE RESULT TO ANOTHER DISK / CLOUD.
#   zsh ~/work/system/backup-state.sh
out=~/work/backups; mkdir -p $out; f=$out/hackintosh-state-$(date +%Y%m%d-%H%M%S).tar.gz
tar -czf $f -C / --exclude='Library/NullMoth/backup-*' \
  Library/Extensions/NVRM.kext Library/Extensions/NVAccel.kext Library/Extensions/NVRMFB.kext Library/Extensions/NVRMAGDC.kext \
  Library/GPUBundles Library/NullMoth Library/LaunchDaemons/local.nvguard.plist Library/LaunchDaemons/local.nvflip.plist 2>/dev/null
nvram -p > ${f%.tar.gz}.nvram.txt 2>/dev/null
echo "$f ($(du -h $f | cut -f1))"; shasum -a 256 $f
