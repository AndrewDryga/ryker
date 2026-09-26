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
# watching. So this bootstraps rather than loads, and then asserts the agent is
# actually registered before it reports success.
set -euo pipefail

if [[ $# -ne 0 ]]; then
  echo "usage: scripts/install-watchdog.sh" >&2
  exit 2
fi

label="ai.emisar.ryker.watchdog"
plist="$HOME/Library/LaunchAgents/$label.plist"
script="$(cd "$(dirname "$0")" && pwd)/watchdog.sh"
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
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"

# Registered, not merely accepted. The distinction is the whole reason this
# script exists.
if ! launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
  echo "watchdog: launchctl accepted the agent but it is not registered" >&2
  exit 1
fi
echo "watchdog: installed and registered; checks the Compose installation every 60s, alarms reach this Mac's notifications, logs to $state/watchdog.log"
