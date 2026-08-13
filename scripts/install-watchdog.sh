#!/bin/bash
# Installs the watchdog as a launch agent, or reinstalls it after it has been
# lost.
#
# It was installed by hand once and was silently gone within the hour: a plain
# `launchctl load` had accepted it and something later dropped it, and the only
# way that showed up was a deliberate check. A watchdog nobody verified is
# running is worse than none, because it is also a claim that someone is
# watching. So this bootstraps rather than loads, and then asserts the agent is
# actually registered before it reports success.
set -euo pipefail

label="ai.emisar.responder.watchdog"
plist="$HOME/Library/LaunchAgents/$label.plist"
script="$(cd "$(dirname "$0")" && pwd)/watchdog.sh"
state="$HOME/.local/state/responder-watchdog"

mkdir -p "$(dirname "$plist")" "$state"
cat > "$plist" <<PLIST
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
echo "watchdog: installed and registered; checks every 60s, logs to $state/watchdog.log"
