#!/bin/zsh
# Install / switch the sleep guard (sleepguard.sh): system sleep follows the NullMoth GPU's suspend/resume support.
#   sudo zsh ~/work/system/sleepguard/install.sh on       sleep allowed whenever the driver can suspend/resume the GPU
#   sudo zsh ~/work/system/sleepguard/install.sh off      sleep always off (SleepDisabled 1)
#   sudo zsh ~/work/system/sleepguard/install.sh remove   daemon removed, SleepDisabled 1
#   zsh ~/work/system/sleepguard/install.sh status        read-only
HERE=${0:A:h}
G=/Library/NullMoth/sleepguard; PL=/Library/LaunchDaemons/local.sleepguard.plist; LOG=/var/log/sleepguard.log
nvrmpm() { ioreg -r -c NVRM -d1 -l 2>/dev/null | awk -F'"' '/"nvrm-pm"/{print $4; exit}'; }

status() {
  print -r -- "wanted:        $(cat $G/want 2>/dev/null || echo 'not installed')"
  print -r -- "daemon:        $([[ -f $PL ]] && echo installed || echo missing)"
  print -r -- "NVRM nvrm-pm:  $(nvrmpm)"
  print -r -- "-nvrmnopm:     $([[ " $(sysctl -n kern.bootargs) " == *" -nvrmnopm "* ]] && echo present || echo absent)"
  print -r -- "SleepDisabled: $(pmset -g | awk '/SleepDisabled/{print $2}')"
  print -r -- "hibernatemode: $(pmset -g custom | awk '$1=="hibernatemode"{printf "%s ", $2}')(battery, AC)"
  print -r -- "idle sleep:    $(pmset -g custom | awk '$1=="sleep"{printf "%s ", $2}')min (battery, AC; 0 = never)"
  print -r -- "last log:"; tail -3 $LOG 2>/dev/null | sed 's/^/  /'
}

case $1 in
  status) status; exit 0;;
  on|off|remove) ;;
  *) print "usage: install.sh on|off|remove|status"; exit 1;;
esac
[[ $(id -u) -eq 0 ]] || { print "STOP: run with sudo"; exit 1; }

if [[ $1 == remove ]]; then
  launchctl bootout system $PL 2>/dev/null; rm -f $PL
  chflags -R noschg $G 2>/dev/null; rm -rf $G
  pmset -a disablesleep 1; print "sleepguard removed, SleepDisabled 1"; exit 0
fi

if [[ $1 == on ]]; then
  pm=$(nvrmpm)
  [[ $pm == running ]] || { print "STOP: NVRM nvrm-pm is '${pm:-absent}', not running - run nvidia-setup/sleep/enable-sleep.sh and reboot first"; exit 1; }
fi
chflags -R noschg $G 2>/dev/null
mkdir -p $G && cp $HERE/sleepguard.sh $G/sleepguard.sh && print -r -- $1 > $G/want || { print "STOP: cannot write $G"; exit 1; }
chown -R root:wheel $G; chmod 755 $G $G/sleepguard.sh; chmod 644 $G/want
cat > $PL <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>local.sleepguard</string>
	<key>ProgramArguments</key><array><string>/bin/zsh</string><string>$G/sleepguard.sh</string></array>
	<key>RunAtLoad</key><true/>
	<key>StartInterval</key><integer>600</integer>
	<key>ThrottleInterval</key><integer>60</integer>
</dict>
</plist>
PLIST
chown root:wheel $PL; chmod 644 $PL; plutil -lint $PL >/dev/null || { print "STOP: plist invalid"; exit 1; }
launchctl bootout system $PL 2>/dev/null
launchctl bootstrap system $PL || { print "STOP: launchctl bootstrap failed"; exit 1; }
sleep 3
chflags -R schg $G 2>/dev/null
print "sleepguard installed, wanted: $1"
status
