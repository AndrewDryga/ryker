#!/bin/bash
# Schedules a daily backup of the Docker Compose installation in this checkout as a launch agent
# on this Mac, or reinstalls it with another time.
#
#   scripts/install-backup-schedule.sh [HH:MM]
#
# The backup runs at HH:MM in this Mac's time zone, 03:30 unless given. It pauses Ryker while it
# dumps the database, under a minute, so pick an hour nobody uses it. Each run keeps the newest 14
# scheduled backups in .ryker/backups (scripts/scheduled-backup.sh); a backup taken by hand stays
# until it is deleted. Like the watchdog's, the agent is checked to be registered, not merely
# accepted (scripts/launch-agent.sh).
set -euo pipefail

usage() {
  echo "usage: scripts/install-backup-schedule.sh [HH:MM]" >&2
  exit 2
}

[[ $# -le 1 ]] || usage
at=${1:-03:30}
[[ $at =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]] || usage
hour=$((10#${BASH_REMATCH[1]}))
minute=$((10#${BASH_REMATCH[2]}))

label="ai.emisar.ryker.backup"
plist="$HOME/Library/LaunchAgents/$label.plist"
here=$(cd "$(dirname "$0")" && pwd)
script="$here/scheduled-backup.sh"
state="$HOME/.local/state/ryker-backup"

mkdir -p "$(dirname "$plist")" "$state"
cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$script</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>$hour</integer>
    <key>Minute</key><integer>$minute</integer>
  </dict>
  <key>StandardOutPath</key><string>$state/backup.log</string>
  <key>StandardErrorPath</key><string>$state/backup.log</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$plist" >/dev/null
"$here/launch-agent.sh" load "$label" "$plist"
echo "backups: scheduled daily at $at this Mac's time; the newest 14 stay in .ryker/backups; log in $state/backup.log"
