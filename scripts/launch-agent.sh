#!/usr/bin/env bash
# Loads or unloads one of Ryker's launch agents on this Mac: the helper
# servers (voice, search by meaning, the local routing model) and the
# watchdog.
#
# `launchctl bootout` returns while the agent's process is still exiting, and
# bootstrapping a label that is still registered fails with "5: Input/output
# error". Every install script booted out and bootstrapped back to back, so
# re-running one on a running agent failed half way and left it stopped: it
# did exactly that to the local routing model on 2026-09-30. So loading waits
# for the old agent to be gone, and then checks that the new one is
# registered, not merely accepted: a `launchctl load` once accepted the
# watchdog and something dropped it within the hour.
#
# usage: scripts/launch-agent.sh load <label> <plist> | unload <label>
set -euo pipefail

domain="gui/$(id -u)"

usage() {
  echo "usage: scripts/launch-agent.sh load <label> <plist> | unload <label>" >&2
  exit 2
}

registered() {
  launchctl print "$domain/$1" >/dev/null 2>&1
}

unload() {
  local label=$1
  launchctl bootout "$domain/$label" 2>/dev/null || true
  # A model server takes a few seconds to let go of the GPU.
  for _ in $(seq 1 150); do
    registered "$label" || return 0
    sleep 0.2
  done
  echo "$label: still registered 30 s after it was asked to stop" >&2
  return 1
}

load() {
  local label=$1 plist=$2
  unload "$label"
  launchctl bootstrap "$domain" "$plist"
  if ! registered "$label"; then
    echo "$label: launchctl accepted the agent but it is not registered" >&2
    return 1
  fi
}

case ${1:-} in
  load)
    [ $# -eq 3 ] || usage
    load "$2" "$3"
    ;;
  unload)
    [ $# -eq 2 ] || usage
    unload "$2"
    ;;
  *) usage ;;
esac
