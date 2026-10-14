#!/bin/bash
# Keeps this Mac awake for Ryker from login on, as a launch agent.
#
#   scripts/install-keep-awake.sh
#
# A Mac that sleeps pauses Ryker, and nothing is answered until someone wakes it. A laptop on
# battery sleeps after a minute or so, so a short power cut could put the host to sleep with
# nothing to wake it when the power came back. The agent runs `caffeinate -i -s`: no idle sleep,
# and no sleep at all on power. It starts at login and again whenever it stops, so it lasts through
# restarts, as a caffeinate started in a terminal does not. The display still sleeps, and a laptop
# still sleeps when its lid is closed without an external display. Stop it with
# `scripts/launch-agent.sh unload ai.emisar.ryker.awake` and delete its plist.
set -euo pipefail

[[ $# -eq 0 ]] || {
  echo "usage: scripts/install-keep-awake.sh" >&2
  exit 2
}

label="ai.emisar.ryker.awake"
plist="$HOME/Library/LaunchAgents/$label.plist"
here=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$(dirname "$plist")"
cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/caffeinate</string>
    <string>-i</string>
    <string>-s</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
PLIST

plutil -lint "$plist" >/dev/null
"$here/launch-agent.sh" load "$label" "$plist"
echo "keep-awake: this Mac stays awake from login on, through restarts ($label)"
