#!/bin/bash
# Installs the watchdog as a launch agent, or reinstalls it after it has been
# lost.
#
#   scripts/install-watchdog.sh [--slack-channel USER_OR_CHANNEL_ID]
#
# With --slack-channel, alarms are also sent there as a Slack message using the
# watched deployment's own bot token; without it they stay a notification on
# this Mac and a line in the log.
#
# It was installed by hand once and was silently gone within the hour: a plain
# `launchctl load` had accepted it and something later dropped it, and the only
# way that showed up was a deliberate check. A watchdog nobody verified is
# running is worse than none, because it is also a claim that someone is
# watching. So this bootstraps rather than loads, and then asserts the agent is
# actually registered before it reports success.
set -euo pipefail

usage() {
  echo "usage: scripts/install-watchdog.sh [--slack-channel USER_OR_CHANNEL_ID]" >&2
  exit 2
}

channel=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --slack-channel)
      [[ $# -ge 2 && $2 =~ ^[A-Z0-9]{9,}$ ]] || usage
      channel=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

label="ai.emisar.ryker.watchdog"
plist="$HOME/Library/LaunchAgents/$label.plist"
script="$(cd "$(dirname "$0")" && pwd)/watchdog.sh"
state="$HOME/.local/state/ryker-watchdog"

environment=""
if [[ -n $channel ]]; then
  environment="  <key>EnvironmentVariables</key>
  <dict>
    <key>WATCHDOG_SLACK_CHANNEL</key><string>$channel</string>
  </dict>"
fi

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
$environment
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
target="this Mac's notifications"
[[ -n $channel ]] && target="this Mac's notifications and Slack $channel"
echo "watchdog: installed and registered; checks every 60s, alarms reach $target, logs to $state/watchdog.log"
