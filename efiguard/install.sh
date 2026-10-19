#!/bin/zsh
# Install / refresh the ESP guard (efiguard.sh) and its snapshot.
#   sudo -E ESP_UUID=$(diskutil info disk1s4 | awk -F': *' '/Partition UUID/{print $2}') zsh install.sh   (disk1s4 = your ESP today)
# Re-run after every DELIBERATE EFI change (apply-alc.sh, apply-kexts.sh, ...): the snapshot is what gets restored.
# Remove: sudo zsh install.sh remove.   Test without touching the system: EFIGUARD_ROOT=<dir with EFI/OC> EFIGUARD_SNAP=<dir> EFIGUARD_TEST=1 zsh install.sh
HERE=${0:A:h}
G=${EFIGUARD_SNAP:-/Library/NullMoth/efiguard}
PL=/Library/LaunchDaemons/local.efiguard.plist
UUID=${ESP_UUID:?set ESP_UUID to the Partition UUID of your OpenCore ESP (diskutil list; diskutil info <disk>)}
# disk numbers occasionally change (two NVMe drives, probe order varies: disk1s4 / disk0s4): the ESP is found by its partition UUID
DEV=; [[ -n $EFIGUARD_ROOT ]] || for d in $(diskutil list 2>/dev/null | awk '/ EFI /{print $NF}'); do [[ "$(diskutil info $d 2>/dev/null | awk -F': *' '/Partition UUID/{print $2}')" == $UUID ]] && { DEV=$d; break; }; done
PB=/usr/libexec/PlistBuddy
if [[ $1 == remove ]]; then launchctl bootout system $PL 2>/dev/null || true; rm -f $PL; chflags -R noschg $G 2>/dev/null; rm -rf $G; echo "efiguard removed (snapshots of replaced files stay in /Library/NullMoth/efiguard-replaced)"; exit 0; fi
[[ -n $EFIGUARD_TEST || $(id -u) -eq 0 ]] || { echo "STOP: run with sudo"; exit 1; }

MP=; OURS=0
if [[ -n $EFIGUARD_ROOT ]]; then MP=$EFIGUARD_ROOT; else
  [[ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" == $UUID ]] || { echo "STOP: $DEV is not the expected ESP"; exit 1; }
  diskutil unmount $DEV >/dev/null 2>&1 || true
  MP=$(mktemp -d /private/var/tmp/efig.XXXX); OURS=1
  mount -t msdos -o rdonly /dev/$DEV $MP 2>/dev/null || mount -F -t msdos -o rdonly /dev/$DEV $MP || { echo "STOP: cannot mount $DEV"; exit 1; }
  trap 'sync; umount $MP 2>/dev/null || diskutil unmount force $DEV; rmdir $MP 2>/dev/null' EXIT
fi
E=$MP/EFI/OC; C=$E/config.plist
[[ -f $E/OpenCore.efi || -n $EFIGUARD_TEST ]] && [[ -f $C ]] || { echo "STOP: unexpected ESP layout"; exit 1; }
plutil -lint $C >/dev/null || { echo "STOP: live config.plist does not parse"; exit 1; }
# refuse to snapshot a half-broken state: every enabled Kernel/Add kext must exist on the ESP
i=0; while b=$($PB -c "Print :Kernel:Add:$i:BundlePath" $C 2>/dev/null); do
  if [[ $($PB -c "Print :Kernel:Add:$i:Enabled" $C) == true && $b != */* && ! -d $E/Kexts/$b ]]; then echo "STOP: $b is enabled in config.plist but missing from EFI/OC/Kexts"; exit 1; fi
  i=$((i+1)); done

chflags -R noschg $G 2>/dev/null
rm -rf $G; mkdir -p $G/EFI/OC
cp -p $C $G/EFI/OC/config.plist
for d in Kexts ACPI Drivers; do [[ -d $E/$d ]] && cp -Rp $E/$d $G/EFI/OC/; done
find $G -name '.DS_Store' -o -name '._*' | xargs rm -rf 2>/dev/null
# manifest of every file we can restore (config.plist is checked semantically, not by hash)
( cd $G && find EFI/OC/Kexts EFI/OC/ACPI EFI/OC/Drivers -type f 2>/dev/null | sort | while read -r f; do print "$(shasum -a 256 "$f" | cut -d' ' -f1) $f"; done ) > $G/manifest.txt
# the files in the manifest are addressed relative to the ESP root (EFI/OC/...): same layout as under $G
# required Kernel/Add entries = everything enabled right now (top-level kexts first, so Lilu stays ahead of its plugins)
i=0; while b=$($PB -c "Print :Kernel:Add:$i:BundlePath" $C 2>/dev/null); do
  [[ $($PB -c "Print :Kernel:Add:$i:Enabled" $C) == true ]] && print -r -- $b; i=$((i+1)); done > $G/required-kexts.txt
# required boot-args: the ones that carry our fixes (only those present right now); a trailing = means "any value"
cur=$($PB -c "Print :NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args" $C)
# nvfbhidpi=1 / -nvrmnopm / nvrmmapowner=0: NullMoth 2.3.7 kernel (HiDPI modes, NVRM stays out of the power tree, map-owner count-only)
for tok in nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth ipc_control_port_options=0 itlwm_he=1 -btlfxboardid amfi=0x80 amfi_get_out_of_my_way=0x1 alcid= -no_compat_check revpatch= nvfbhidpi=1 -nvrmnopm nvrmmapowner=0; do
  if [[ $tok == *= && $tok != *=?* ]]; then [[ " $cur " == *" $tok"* ]] && print -r -- $tok
  else [[ " $cur " == *" $tok "* ]] && print -r -- $tok; fi
done > $G/required-bootargs.txt
cp $HERE/efiguard.sh $G/efiguard.sh
printf 'DEV=%s\nUUID=%s\n' $DEV $UUID > $G/esp.conf   # the daemon reads the ESP identity from here (DEV is only a hint)
echo "snapshot: $(wc -l < $G/manifest.txt | tr -d ' ') files, $(wc -l < $G/required-kexts.txt | tr -d ' ') required kexts, boot-args: $(tr '\n' ' ' < $G/required-bootargs.txt)"
[[ -n $EFIGUARD_TEST ]] && { echo "(test mode: no daemon)"; exit 0; }
mkdir -p /Library/NullMoth/efiguard-replaced
chown -R root:wheel $G; chmod 755 $G $G/efiguard.sh; chmod 644 $G/*.txt $G/esp.conf
cat > $PL <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>local.efiguard</string>
	<key>ProgramArguments</key><array><string>/bin/zsh</string><string>$G/efiguard.sh</string></array>
	<key>RunAtLoad</key><true/>
	<key>StartInterval</key><integer>21600</integer>
	<key>ThrottleInterval</key><integer>60</integer>
</dict>
</plist>
PLIST
chown root:wheel $PL; chmod 644 $PL
launchctl bootout system $PL 2>/dev/null || true
launchctl bootstrap system $PL
sleep 8
tail -3 /var/log/efiguard.log 2>/dev/null || true
chflags -R schg $G 2>/dev/null && echo "snapshot locked (chflags schg; install.sh unlocks it itself)"
echo "efiguard installed."
