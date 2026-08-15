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

# Ten minutes of queued-and-not-moving. A healthy deployment reads zero: a turn
# that is running is not queued, and work not yet attempted is not late. A run
# waiting out a retry backoff does count — see stalled_minutes.
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

# slack_dm sends the alarm to the deployment's first configured operator as a
# Slack DM, with the deployment's own bot token.
#
# The toast was not enough. On 2026-08-14 the emisar queue sat wedged for
# eleven hours and 654 strikes while the alarm fired as a macOS notification —
# transient, easy to miss, gone if the operator was not at this machine. The
# bot token is the right transport for the same reason the queue is the right
# signal: it works when the Responder process is dead, because the Slack app
# outlives the process that uses it. Credentials come from the deployment's own
# local.env and config, read at alarm time and never logged; a deployment
# without them just keeps the toast. The API base is overridable so the test
# can watch the request arrive instead of trusting that it would.
slack_dm() {
  local title="$1" message="$2"
  # The nothing-to-watch alarm belongs to no deployment and stays a toast.
  [[ -n ${current_env:-} && -n ${current_config:-} ]] || return 0
  if [[ ! -f $current_env ]]; then
    note "slack DM skipped for $title: no local.env beside the deployment config"
    return 0
  fi
  local token operator
  token=$(sed -n 's/^ *\(export \)\{0,1\}SLACK_BOT_TOKEN=//p' "$current_env" | head -1)
  token=${token%\"}; token=${token#\"}; token=${token%\'}; token=${token#\'}
  operator=$(sed -n '/^ *operators:/,/^[^ ]/p' "$current_config" |
    sed -n 's/^[[:space:]]*-[[:space:]]*//p' | head -1)
  if [[ -z $token || -z $operator ]]; then
    note "slack DM skipped for $title: no bot token or operator in the deployment config"
    return 0
  fi
  local api="${WATCHDOG_SLACK_API:-https://slack.com/api}"
  local safe_title=${title//\"/\\\"} safe_message=${message//\"/\\\"}
  /usr/bin/curl -fsS --max-time 5 -X POST "$api/chat.postMessage" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json; charset=utf-8" \
    -d "{\"channel\":\"$operator\",\"text\":\"$safe_title — $safe_message\"}" \
    >/dev/null 2>&1 || note "slack DM failed for $title"
}

alarm() {
  local title="$1" message="$2"
  note "ALERT $title — $message"
  slack_dm "$title" "$message"
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
# A run waiting out its retry backoff counts. On 2026-08-13 it did not: this
# query read `next_attempt_at <= now` as the whole definition of due, so every
# time the failing queue was pushed into its 30s-128s backoff the count fell to
# zero and a 71-minute stall read as a healthy deployment. Work that has
# already been attempted and is waiting to go again is the stall; a first
# attempt genuinely scheduled for the future is not, and stays exempt.
#
# "Already attempted" is two facts, because the store records two kinds of
# retry. A failed attempt increments failure_count. A deferral — the provider
# rate-limiting the turn — pushes the run back to pending with a later
# next_attempt_at and spends no attempt at all, leaving failure_count at zero,
# so a failure count alone would have missed it: tenant had a run sitting 139
# minutes in exactly that shape on 2026-08-15. started_at catches it, being set
# once when a run first reaches running and never cleared, which makes a
# pending run that has one a retry by definition.
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
      AND (next_attempt_at IS NULL OR next_attempt_at = '' OR next_attempt_at <= strftime('%Y-%m-%dT%H:%M:%f', 'now')
           OR failure_count > 0
           OR (started_at IS NOT NULL AND started_at != ''))
  " 2>/dev/null || echo "unreadable"
}

# stall_reason distinguishes provider weather from an unexplained stall.
#
# On 2026-08-15 the alarm said "work has been queued 178m without moving" for
# three hours of provider rate limiting — true, useless, and indistinguishable
# from the wedges fixed the same evening. An operator reading the alarm could
# not tell whether to debug the host or wait out a quota. The classification
# reads what the stalled runs themselves recorded: when every stalled run is
# parked on a rate-limit retry, the weather is named; anything else stays
# unexplained, which is the alarm that means "go look".
stall_reason() {
  local db="$1"
  [[ -f $db ]] || { echo "unexplained"; return; }
  local total limited
  total=$(/usr/bin/sqlite3 -readonly "file:$db?immutable=1" "
    SELECT COUNT(*) FROM agent_runs
    WHERE state IN ('pending', 'preparing')
      AND (next_attempt_at IS NULL OR next_attempt_at = '' OR next_attempt_at <= strftime('%Y-%m-%dT%H:%M:%f', 'now')
           OR failure_count > 0
           OR (started_at IS NOT NULL AND started_at != ''))
  " 2>/dev/null) || { echo "unexplained"; return; }
  limited=$(/usr/bin/sqlite3 -readonly "file:$db?immutable=1" "
    SELECT COUNT(*) FROM agent_runs
    WHERE state IN ('pending', 'preparing')
      AND (next_attempt_at IS NULL OR next_attempt_at = '' OR next_attempt_at <= strftime('%Y-%m-%dT%H:%M:%f', 'now')
           OR failure_count > 0
           OR (started_at IS NOT NULL AND started_at != ''))
      AND (last_error LIKE '%rate limited%' OR last_error LIKE '%rate_limited%')
  " 2>/dev/null) || { echo "unexplained"; return; }
  if [[ -n $total && $total -gt 0 && $total == "$limited" ]]; then
    echo "provider-limited"
  else
    echo "unexplained"
  fi
}

# movement_marker is the latest moment any run started or finished: the only
# evidence this script accepts that the deployment is doing work.
#
# Deliberately not `updated_at`, which a retry bumps every time it reschedules
# a run it could not execute — that is the backoff advancing, not the queue.
# `started_at` is set once, on a run's first transition into running, and
# `completed_at` only on a terminal one, so this marker moves when work moves
# and holds perfectly still through any number of failed attempts. Empty when
# nothing has ever run, or when the database cannot be read: both mean no
# movement was observed, which is what the caller asks.
movement_marker() {
  local db="$1"
  [[ -f $db ]] || { echo ""; return; }
  /usr/bin/sqlite3 -readonly "file:$db?immutable=1" "
    SELECT COALESCE(MAX(moved_at), '') FROM (
      SELECT started_at AS moved_at FROM agent_runs WHERE started_at IS NOT NULL AND started_at != ''
      UNION ALL
      SELECT completed_at FROM agent_runs WHERE completed_at IS NOT NULL AND completed_at != ''
    )
  " 2>/dev/null || echo ""
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
  # Remembered for the alarm path: a per-deployment alarm DMs that
  # deployment's operator with that deployment's token. The nothing-to-watch
  # alarm at the bottom has neither and stays a toast.
  current_config="$config"
  current_env="$responder_dir/local.env"
  db="$responder_dir/state/responder.db"
  listen=$(/usr/bin/awk -F'[[:space:]]+' '/^listen:/ {print $2; exit}' "$config" 2>/dev/null)

  checked=$((checked + 1))
  stalled=$(stalled_minutes "$db")
  movement=$(movement_marker "$db")
  reason=$([[ -n $listen ]] && ready_reason "$listen" || echo "no-listen-configured")

  trouble=""
  queue_stalled=""
  case $stalled in
    no-db) trouble="no database at $db" ;;
    unreadable) trouble="database unreadable" ;;
    *) if [[ $stalled -ge $stall_minutes ]]; then
         if [[ $(stall_reason "$db") == "provider-limited" ]]; then
           trouble="waiting on provider rate limits — oldest run queued ${stalled}m; the host is healthy, the quota is not"
         else
           trouble="work has been queued ${stalled}m without moving"
         fi
         queue_stalled=1
       fi ;;
  esac
  if [[ -z $trouble && $reason != "ready" ]]; then
    trouble="not ready: $reason"
  fi

  strike_file="$state_dir/$name.strikes"
  alerted_file="$state_dir/$name.alerted"
  # When the queue was last seen stalled, and what movement looked like then.
  # Its presence is what makes the next all-clear provisional.
  stalled_at_file="$state_dir/$name.stalled-at"
  strikes=$(cat "$strike_file" 2>/dev/null || echo 0)

  if [[ -z $trouble ]]; then
    # Recovery has to be movement, not a momentarily empty queue. On
    # 2026-08-13 a backoff phase emptied the due count for one check and the
    # watchdog announced "Queue is moving again" on a stall that then ran for
    # another two hours — 71m → 76m → 105m → 118m, re-climbing from strike 1
    # each time, because the false recovery cleared the strikes the alarm had
    # already paid for. So an all-clear that follows a stall must show a run
    # that started or finished since the stall was last seen.
    if [[ -f $stalled_at_file ]]; then
      read -r stalled_at stalled_movement < "$stalled_at_file" || true
      if [[ $movement > ${stalled_movement:-} ]]; then
        : # Something ran. This is a real recovery; fall through and say so.
      elif [[ $(($(date +%s) - ${stalled_at:-0})) -ge $((stall_minutes * 60)) ]]; then
        # Read clear for a whole stall window with nothing left to move: an
        # idle deployment, not a recovery. Forget the stall without claiming
        # credit for it, so the hold cannot outlive what it was watching.
        note "$name has read clear for ${stall_minutes}m with nothing moving; clearing strikes without calling it recovery"
        rm -f "$strike_file" "$alerted_file" "$stalled_at_file"
        continue
      else
        note "$name reads clear but nothing has started or finished since the stall; holding strike $strikes/$strikes_required"
        continue
      fi
    fi
    if [[ $strikes -ge $strikes_required && -f $alerted_file ]]; then
      alarm "Responder $name recovered" "Queue is moving again and the deployment reports ready."
    fi
    rm -f "$strike_file" "$alerted_file" "$stalled_at_file"
    continue
  fi

  strikes=$((strikes + 1))
  echo "$strikes" > "$strike_file"
  # Refreshed on every stalled check, so recovery is measured against the last
  # time the queue was seen stuck rather than the first.
  [[ -n $queue_stalled ]] && printf '%s %s\n' "$(date +%s)" "$movement" > "$stalled_at_file"
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
