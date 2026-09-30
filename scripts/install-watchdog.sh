#!/bin/bash
# Installs the watchdog as a launch agent on this Mac, or reinstalls it after
# it has been lost.
#
#   scripts/install-watchdog.sh
#
# The watchdog watches the Docker Compose installation in this checkout
# (.ryker/compose.env), so it has to run outside the containers it watches;
# launchd is the supervisor for that. Alarms are a notification on this Mac
# and a line in the log.
#
# It was installed by hand once and was silently gone within the hour: a plain
# `launchctl load` had accepted it and something later dropped it, and the only
# way that showed up was a deliberate check. A watchdog nobody verified is
# running is worse than none, because it is also a claim that someone is
# watching. So this bootstraps rather than loads, and asserts the agent is
# actually registered before it reports success (scripts/launch-agent.sh).
set -euo pipefail

if [[ $# -ne 0 ]]; then
  echo "usage: scripts/install-watchdog.sh" >&2
  exit 2
fi

label="ai.emisar.ryker.watchdog"
plist="$HOME/Library/LaunchAgents/$label.plist"
here=$(cd "$(dirname "$0")" && pwd)
script="$here/watchdog.sh"
state="$HOME/.local/state/ryker-watchdog"

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
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>$state/stderr.log</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$plist" >/dev/null
# Registered, not merely accepted. The distinction is the whole reason this
# script exists.
"$here/launch-agent.sh" load "$label" "$plist"
echo "watchdog: installed and registered; checks the Compose installation every 60s, alarms reach this Mac's notifications, logs to $state/watchdog.log"
