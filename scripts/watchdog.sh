#!/bin/bash
# Notices that Ryker has stopped doing work, and says so where a person
# will see it.
#
# From 2026-09-13 to 2026-09-18 the only Coop worker was gone — its launchd job
# could not find Docker after a reboot, then its certificate expired — and
# /readyz answered "not ready" for four and a half days. Nobody was told: the
# watchdog of the time still looked for the retired Go deployment's SQLite
# file and found nothing it recognised. On 2026-08-13 the opposite happened:
# Docker stopped, readiness kept saying ready, and every turn died inside
# execution for twenty minutes until the operator noticed Slack had gone quiet.
#
# So this asks the deployment two questions over its loopback control plane:
#
#   /readyz   Is anything stopping work? The host folds every systemic cause
#             into it — no eligible worker or capacity, a due queue that has
#             not drained or a lease held too long for fifteen minutes, a
#             polling lane that stopped cycling, a runtime that is not
#             running, a saved setting it could not apply — and names each in
#             the 503 body.
#   /metrics  Did work stop and wait for a person? A request whose retries
#             are spent is blocked and waits on the Failures page; a crash-
#             looping turn ends there too, which is what readiness alone would
#             miss between its retries.
#
# It does not read the database and it needs nothing from the process it
# watches: an unreachable control plane is itself the alarm. It speaks through
# a macOS notification, a Slack DM sent with the deployment's own bot token
# (the Slack app outlives the process), and a log file.
set -uo pipefail

# Overridable so every alarm can be exercised against a fabricated deployment.
# A watchdog that has never been seen to fire is indistinguishable from one
# that cannot.
agents="${WATCHDOG_AGENTS:-$HOME/Library/LaunchAgents}"
state_dir="${WATCHDOG_STATE:-$HOME/.local/state/ryker-watchdog}"
log="$state_dir/watchdog.log"
# Three consecutive bad checks before saying anything, so a deploy — which
# restarts the release and drops readiness for a minute — passes in silence.
strikes_required="${WATCHDOG_STRIKES:-3}"
# While a deployment stays broken, repeat every half hour rather than every
# minute. An alarm nobody can silence is an alarm everybody learns to ignore.
renotify_minutes="${WATCHDOG_RENOTIFY_MINUTES:-30}"
# The Slack user or channel the DM goes to. Unset keeps the alarm local.
slack_channel="${WATCHDOG_SLACK_CHANNEL:-}"

mkdir -p "$state_dir"

# A heartbeat, because this script is silent when everything is well and also
# silent when it is dead, and those must be tellable apart. Written first, so
# it records that the check started even if the check itself then fails.
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$state_dir/heartbeat"

note() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$log"
}

# env_value FILE KEY prints KEY's last assignment in a runtime.env, with an
# optional `export` and surrounding quotes removed. The file is never sourced:
# it holds every secret the deployment has.
env_value() {
  local value
  value=$(sed -n "s/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}$2=//p" "$1" 2>/dev/null | tail -1)
  value=${value%\"}; value=${value#\"}; value=${value%\'}; value=${value#\'}
  printf '%s' "$value"
}

# json_string VALUE prints VALUE as a JSON string literal.
json_string() {
  local value=${1//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  printf '"%s"' "$value"
}

# slack_dm sends the alarm as a Slack DM with the deployment's own bot token.
#
# The toast was not enough. On 2026-08-14 a queue sat wedged for eleven hours
# while the alarm fired as a macOS notification — transient, easy to miss, and
# gone if nobody was at this machine. The token is read from the deployment's
# runtime.env at alarm time and never logged; the API base is overridable so
# the test can watch the request arrive instead of trusting that it would.
slack_dm() {
  local title="$1" message="$2" token api
  # The nothing-to-watch alarm belongs to no deployment and stays local.
  [[ -n ${current_env:-} ]] || return 0
  if [[ -z $slack_channel ]]; then
    note "slack DM skipped for $title: WATCHDOG_SLACK_CHANNEL is not set"
    return 0
  fi
  token=$(env_value "$current_env" SLACK_BOT_TOKEN)
  if [[ -z $token ]]; then
    note "slack DM skipped for $title: no SLACK_BOT_TOKEN in $current_env"
    return 0
  fi
  api="${WATCHDOG_SLACK_API:-https://slack.com/api}"
  /usr/bin/curl -fsS --max-time 5 -X POST "$api/chat.postMessage" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json; charset=utf-8" \
    -d "{\"channel\":$(json_string "$slack_channel"),\"text\":$(json_string "$title — $message")}" \
    >/dev/null 2>&1 || note "slack DM failed for $title"
}

alarm() {
  local title="$1" message="$2"
  note "ALERT $title — $message"
  slack_dm "$title" "$message"
  [[ -n ${WATCHDOG_NO_NOTIFY:-} ]] && return
  # Escaped for AppleScript's string literal, which is the one place a reason
  # containing a quote would otherwise become a syntax error.
  local safe_title=${title//\"/\\\"} safe_message=${message//\"/\\\"}
  /usr/bin/osascript -e "display notification \"$safe_message\" with title \"$safe_title\"" \
    >/dev/null 2>&1 || true
}

# readiness BASE prints "ready", "unreachable", or the host's own reasons.
readiness() {
  local response code body
  response=$(/usr/bin/curl -sS --max-time 10 -w $'\n%{http_code}' "$1/readyz" 2>/dev/null) || {
    echo "unreachable"
    return
  }
  code=${response##*$'\n'}
  body=${response%$'\n'*}
  body=${body%%$'\n'*}
  if [[ $code == 200 ]]; then
    echo "ready"
  elif [[ -n $body ]]; then
    echo "$body"
  else
    echo "not ready (HTTP $code)"
  fi
}

# blocked_count BASE prints how many requests wait for an operator — every
# `ryker_*_total{status="blocked"}` gauge summed — or nothing when /metrics
# cannot be read. Retention's own blocked gauge is left out on purpose: a
# workspace kept for review is blocked from cleanup by design.
blocked_count() {
  local metrics
  metrics=$(/usr/bin/curl -fsS --max-time 10 "$1/metrics" 2>/dev/null) || return 0
  printf '%s\n' "$metrics" |
    /usr/bin/awk '/^ryker_[a-z_]+_total\{status="blocked"\} [0-9]+$/ {sum += $2} END {print sum + 0}'
}

checked=0
for plist in "$agents"/ai.emisar.ryker*.plist; do
  [[ -e $plist ]] || continue
  case $plist in
    *.staged-*) continue ;;
  esac

  # A deployment is a state root holding a runtime.env that names the control
  # listener; everything else under the same prefix — the Coop worker, this
  # watchdog — is skipped by that fact rather than by name, so nothing added
  # later has to remember to exclude itself.
  root=$(/usr/bin/plutil -extract WorkingDirectory raw -o - "$plist" 2>/dev/null) || root=""
  if [[ -z $root ]]; then
    stderr_path=$(/usr/bin/plutil -extract StandardErrorPath raw -o - "$plist" 2>/dev/null) || continue
    root=$(dirname "$(dirname "$stderr_path")")
  fi
  env_file="$root/runtime.env"
  [[ -r $env_file ]] || continue
  port=$(env_value "$env_file" RYKER_CONTROL_PORT)
  [[ $port =~ ^[0-9]+$ ]] || continue
  address=$(env_value "$env_file" RYKER_CONTROL_IP)
  case $address in
    "" | 0.0.0.0 | "::") address=127.0.0.1 ;;
  esac
  base="http://$address:$port"
  name=$(basename "$root")
  # Remembered for the alarm path: a deployment's alarm is sent with that
  # deployment's own token.
  current_env="$env_file"
  checked=$((checked + 1))

  strike_file="$state_dir/$name.strikes"
  alerted_file="$state_dir/$name.alerted"
  blocked_file="$state_dir/$name.blocked"

  state=$(readiness "$base")
  strikes=$(cat "$strike_file" 2>/dev/null || echo 0)
  if [[ $state == "ready" ]]; then
    if [[ -f $alerted_file ]]; then
      alarm "Ryker $name recovered" "The deployment reports ready again."
      note "$name recovered after $strikes strikes"
    fi
    rm -f "$strike_file" "$alerted_file"
  else
    [[ $state == "unreachable" ]] && state="control plane unreachable at $base"
    strikes=$((strikes + 1))
    echo "$strikes" > "$strike_file"
    note "$name unhealthy (strike $strikes/$strikes_required): $state"
    if [[ $strikes -ge $strikes_required ]]; then
      now=$(date +%s)
      last=$(cat "$alerted_file" 2>/dev/null || echo 0)
      if [[ $((now - last)) -ge $((renotify_minutes * 60)) ]]; then
        echo "$now" > "$alerted_file"
        alarm "Ryker $name is not working" "$state"
      fi
    fi
  fi

  # Blocked work is a durable state, not a transient one, so it alarms when it
  # appears rather than after strikes, and once per increase rather than every
  # half hour: it waits on a decision, and nagging about a decision is noise.
  blocked=$(blocked_count "$base")
  if [[ $blocked =~ ^[0-9]+$ ]]; then
    previous=$(cat "$blocked_file" 2>/dev/null || echo 0)
    [[ $previous =~ ^[0-9]+$ ]] || previous=0
    if [[ $blocked -gt $previous ]]; then
      noun="requests are"
      [[ $blocked -eq 1 ]] && noun="request is"
      alarm "Ryker $name needs attention" "$blocked $noun blocked and waiting for an operator: $base/failures"
    elif [[ $blocked -lt $previous ]]; then
      note "$name blocked requests fell from $previous to $blocked"
    fi
    echo "$blocked" > "$blocked_file"
  fi
done

if [[ $checked -eq 0 ]]; then
  alarm "Ryker watchdog found nothing to watch" \
    "No launch agent in $agents names a state root with a runtime.env and a control port."
  exit 1
fi
