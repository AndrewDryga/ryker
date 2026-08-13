#!/bin/bash
# Notices that Responder has stopped doing work, and says so where a person
# will see it.
#
# On 2026-08-13 the Docker daemon stopped. Coop's control API kept answering,
# so /readyz reported ready and every health signal Responder had said it was
# fine — while every turn died inside execution on a box image that could not
# be built. Alerts arrived and went unanswered for twenty minutes, and the way
# the operator found out was by watching Slack stay quiet.
#
# So the primary signal here is not a health endpoint. It is whether work that
# is due has moved. A queue that is not draining is the one symptom every
# outage shares, whatever the cause: Docker, Coop, the provider, Slack, a
# wedged worker. /readyz is checked too, because it catches things a drained
# queue cannot — a disconnected socket on an idle afternoon.
#
# This must not depend on Responder to raise the alarm, since Responder is what
# it is watching. It uses a macOS notification and a log file.
set -uo pipefail

# Overridable so the alarm paths can be exercised against a fabricated
# deployment. A watchdog that has never been seen to fire is indistinguishable
# from one that cannot.
agents="${WATCHDOG_AGENTS:-$HOME/Library/LaunchAgents}"
state_dir="${WATCHDOG_STATE:-$HOME/.local/state/responder-watchdog}"
log="$state_dir/watchdog.log"

# Ten minutes of due-and-not-moving. A healthy deployment reads zero: a turn
# that is running is not queued, and a run waiting out its backoff is not due.
# During the outage this measured eight to twelve.
stall_minutes="${WATCHDOG_STALL_MINUTES:-10}"
# Three consecutive bad checks before saying anything, so a deploy — which
# restarts both services and drops readiness for a few seconds — passes in
# silence.
strikes_required="${WATCHDOG_STRIKES:-3}"
# While a deployment stays broken, repeat every half hour rather than every
# minute. An alarm nobody can silence is an alarm everybody learns to ignore.
renotify_minutes="${WATCHDOG_RENOTIFY_MINUTES:-30}"

mkdir -p "$state_dir"

# A heartbeat, because this script is silent when everything is well and also
# silent when it is dead, and those must be tellable apart. Written first, so
# it records that the check started even if the check itself then fails.
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$state_dir/heartbeat"

note() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$log"
}

alarm() {
  local title="$1" message="$2"
  note "ALERT $title — $message"
  # Escaped for AppleScript's string literal, which is the one place a
  # deployment name containing a quote would otherwise become a syntax error.
  local safe_title=${title//\"/\\\"} safe_message=${message//\"/\\\"}
  if [[ -n ${WATCHDOG_NO_NOTIFY:-} ]]; then
    return
  fi
  /usr/bin/osascript -e "display notification \"$safe_message\" with title \"$safe_title\"" \
    >/dev/null 2>&1 || true
}

# stalled_minutes reports how long work has been due without moving.
#
# Read-only and with an immutable snapshot, because the deployment is writing
# to this database as we read it and a watchdog that trips on its own lock is
# worse than none. A database that cannot be read at all is reported as such
# rather than as zero.
stalled_minutes() {
  local db="$1"
  [[ -f $db ]] || { echo "no-db"; return; }
  /usr/bin/sqlite3 -readonly "file:$db?immutable=1" "
    SELECT COALESCE(MAX(CAST((julianday('now') - julianday(created_at)) * 1440 AS INT)), 0)
    FROM agent_runs
    WHERE state IN ('pending', 'preparing')
      AND (next_attempt_at IS NULL OR next_attempt_at = '' OR next_attempt_at <= strftime('%Y-%m-%dT%H:%M:%f', 'now'))
  " 2>/dev/null || echo "unreadable"
}

# ready_reason returns the deployment's own account of itself, or the reason it
# could not be asked.
ready_reason() {
  local listen="$1" body
  body=$(/usr/bin/curl -fsS --max-time 5 "http://$listen/readyz" 2>/dev/null) || {
    echo "unreachable"
    return
  }
  if [[ $body == *'"ready":true'* ]]; then
    echo "ready"
    return
  fi
  local reason=${body##*\"reason\":\"}
  echo "${reason%%\"*}"
}

checked=0
for plist in "$agents"/ai.emisar.responder.*.plist; do
  [[ -e $plist ]] || continue
  case $plist in
    *.staged-*) continue ;;
  esac
  name=$(basename "$plist" .plist)
  name=${name#ai.emisar.responder.}

  # Both derived from the plist rather than configured here, so a deployment
  # added tomorrow is watched without editing this file.
  stderr_path=$(/usr/bin/plutil -extract StandardErrorPath raw -o - "$plist" 2>/dev/null) || continue
  responder_dir=$(dirname "$(dirname "$stderr_path")")
  # A deployment is a thing with a responder.yaml. Everything else sharing the
  # ai.emisar.responder.* prefix — the quality watcher, this watchdog itself —
  # is skipped by that fact rather than by name, so nothing added later has to
  # remember to exclude itself. A blocklist got this wrong on its first run:
  # the watchdog found its own launch agent and reported it as a deployment
  # with no database.
  config="$responder_dir/responder.yaml"
  [[ -f $config ]] || continue
  db="$responder_dir/state/responder.db"
  listen=$(/usr/bin/awk -F'[[:space:]]+' '/^listen:/ {print $2; exit}' "$config" 2>/dev/null)

  checked=$((checked + 1))
  stalled=$(stalled_minutes "$db")
  reason=$([[ -n $listen ]] && ready_reason "$listen" || echo "no-listen-configured")

  trouble=""
  case $stalled in
    no-db) trouble="no database at $db" ;;
    unreadable) trouble="database unreadable" ;;
    *) [[ $stalled -ge $stall_minutes ]] && trouble="work has been queued ${stalled}m without moving" ;;
  esac
  if [[ -z $trouble && $reason != "ready" ]]; then
    trouble="not ready: $reason"
  fi

  strike_file="$state_dir/$name.strikes"
  alerted_file="$state_dir/$name.alerted"
  strikes=$(cat "$strike_file" 2>/dev/null || echo 0)

  if [[ -z $trouble ]]; then
    if [[ $strikes -ge $strikes_required && -f $alerted_file ]]; then
      alarm "Responder $name recovered" "Queue is moving again and the deployment reports ready."
    fi
    rm -f "$strike_file" "$alerted_file"
    continue
  fi

  strikes=$((strikes + 1))
  echo "$strikes" > "$strike_file"
  note "$name unhealthy (strike $strikes/$strikes_required): $trouble"
  [[ $strikes -ge $strikes_required ]] || continue

  now=$(date +%s)
  last=$(cat "$alerted_file" 2>/dev/null || echo 0)
  if [[ $((now - last)) -ge $((renotify_minutes * 60)) ]]; then
    echo "$now" > "$alerted_file"
    alarm "Responder $name is not working" "$trouble"
  fi
done

if [[ $checked -eq 0 ]]; then
  alarm "Responder watchdog found nothing to watch" \
    "No deployment launch agent matched in $agents."
  exit 1
fi
