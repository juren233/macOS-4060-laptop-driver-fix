#!/bin/zsh
# Restart UU远程 cleanly: quit the app, then restart the agent; the agent relaunches the app itself
# (UURemote -startup-by-server). Restarting only the agent leaves the old app holding a dead connection
# to it, and UU then shows "网络连接异常". The root daemon does not need restarting. No sudo needed.
#   zsh uu-restart.sh        (also works under sudo; it acts on the invoking user's session)
U=${SUDO_UID:-$(id -u)}
NAME=$(id -un $U)
APP=/Applications/UURemote.app
as_user() { if [[ $EUID -eq 0 ]]; then launchctl asuser $U sudo -u $NAME "$@"; else "$@"; fi }
as_user osascript -e 'tell application id "com.netease.uuremote" to quit' >/dev/null 2>&1
for i in {1..10}; do pgrep -u $U -f "$APP/Contents/MacOS/UURemote( |\$)" >/dev/null || break; sleep 0.5; done
pkill -u $U -f "$APP/Contents/MacOS/UURemote( |\$)" 2>/dev/null
launchctl kickstart -k gui/$U/com.netease.uuremote.agent
for i in {1..16}; do pgrep -u $U -f "$APP/Contents/MacOS/UURemote( |\$)" >/dev/null && break; sleep 0.5; done
pgrep -u $U -f "$APP/Contents/MacOS/UURemote( |\$)" >/dev/null || as_user open -a "$APP"
sleep 2
ps -axo pid,lstart,command | grep -E "$APP/Contents/(MacOS|Helpers)/" | grep -v grep
echo "UU restarted"
