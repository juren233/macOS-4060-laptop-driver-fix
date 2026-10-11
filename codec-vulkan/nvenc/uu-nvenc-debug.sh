#!/bin/zsh
# Temporary debug harness: capture UU's encoder log (NVENC_VT_VERBOSE: SetProperty values such as ExpectedFrameRate /
# AverageBitRate, and per-session frame/byte/time stats at teardown). Does not change which encoders are enabled.
#   sudo zsh uu-nvenc-debug.sh start   # UU agent stderr -> /tmp/uu-nvenc.log, reload UU
#   sudo zsh uu-nvenc-debug.sh stop    # restore the agent plist, reload UU
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
HERE=${0:A:h}
PL=/Library/LaunchAgents/com.netease.uuremote.agent.plist
BAK=$PL.nvenc-debug-backup
U=${SUDO_UID:-501}
LOG=/tmp/uu-nvenc.log
restart_agent() {   # the plist changed, so the agent must be reloaded (bootout/bootstrap), not just kickstarted.
  # launchctl on the gui/ domain has to run as the user: run as root, bootout failed silently and left UU dead.
  NAME=$(id -un $U)
  as_user() { launchctl asuser $U sudo -u $NAME "$@"; }
  as_user osascript -e 'tell application id "com.netease.uuremote" to quit' >/dev/null 2>&1
  sleep 2
  as_user launchctl bootout gui/$U/com.netease.uuremote.agent 2>/dev/null
  sleep 2
  if as_user launchctl print gui/$U/com.netease.uuremote.agent >/dev/null 2>&1; then
    as_user launchctl kickstart -k gui/$U/com.netease.uuremote.agent
  else
    as_user launchctl bootstrap gui/$U "$PL"
  fi
  sleep 5
  pgrep -u $U -f "/Applications/UURemote.app/Contents/MacOS/UURemote( |\$)" >/dev/null || as_user open -a /Applications/UURemote.app
  ps -axo pid,lstart,command | grep -E "/Applications/UURemote.app/Contents/(MacOS|Helpers)/" | grep -v grep
}
case "$1" in
  start)
    [[ -f $BAK ]] || cp -p "$PL" "$BAK"
    /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables" "$PL" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" -c "Add :EnvironmentVariables:NVENC_VT_VERBOSE string 1" "$PL"
    /usr/libexec/PlistBuddy -c "Delete :StandardErrorPath" "$PL" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $LOG" "$PL"
    : > $LOG; chown $U $LOG; chmod 644 $LOG
    restart_agent
    echo "debug ON: UU stderr -> $LOG" ;;
  stop)
    [[ -f $BAK ]] && mv "$BAK" "$PL"
    restart_agent
    echo "debug OFF: agent plist restored (NVENC on/off unchanged; use uu-nvenc-toggle.sh)" ;;
  *) echo "usage: $0 start|stop"; exit 1 ;;
esac
