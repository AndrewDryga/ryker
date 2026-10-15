#!/bin/bash
# Installs scripts/auto-upgrade.sh as a launch agent on this Mac, run every five minutes, or
# reinstalls it. It upgrades only once compose.env names the branch to follow:
#
#   RYKER_UPGRADE_REF=main
#
# after which every push to that branch, from anywhere, upgrades this install. Like the
# watchdog's, the agent is checked to be registered, not merely accepted (scripts/launch-agent.sh).
set -euo pipefail

label="ai.emisar.ryker.upgrade"
plist="$HOME/Library/LaunchAgents/$label.plist"
here=$(cd "$(dirname "$0")" && pwd)
state="$HOME/.local/state/ryker-upgrade"

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
    <string>$here/auto-upgrade.sh</string>
  </array>
  <key>StartInterval</key><integer>300</integer>
  <key>StandardOutPath</key><string>$state/agent.log</string>
  <key>StandardErrorPath</key><string>$state/agent.log</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$plist" >/dev/null
"$here/launch-agent.sh" load "$label" "$plist"
echo "upgrades: checked every five minutes; set RYKER_UPGRADE_REF in .ryker/compose.env to follow a branch; log in $state/upgrades.log"
