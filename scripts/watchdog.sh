#!/bin/bash
# Notices that Ryker has stopped doing work, and says so where a person
# will see it.
#
# From 2026-09-13 to 2026-09-18 the only Coop worker was gone — its launch
# agent could not find Docker after a reboot, then its certificate expired —
# and /readyz answered "not ready" for four and a half days. Nobody was told:
# the watchdog of the time still looked for the retired Go deployment's
# SQLite file and found nothing it recognised. On 2026-08-13 the opposite
# happened: Docker stopped, readiness kept saying ready, and every turn died
# inside execution for twenty minutes until the operator noticed Slack had
# gone quiet. And a deploy that restarts the service but never pins what it
# started is the case this repository's "say what is running" rule is about.
#
# The deployment is the Docker Compose project in this checkout, pinned by
# .ryker/compose.env. So this asks it three questions every minute:
#
#   /readyz   Is anything stopping work? The host folds every systemic cause
#             into it — no eligible worker or capacity, a due queue that has
#             not drained or a lease held too long for fifteen minutes, a
#             polling lane that stopped cycling, a runtime that is not
#             running, a saved setting it could not apply — and names each in
#             the 503 body. And does the x-ryker-version header name the
#             version compose.env pins? A container serving other code than
#             the pinned release is a deploy that did not finish.
#   docker    Are the project's containers — the release, PostgreSQL, the
#             bundled worker and its Docker daemon — running and healthy?
#             Readiness folds a lost worker in only once its lease lapses; a
#             container that exited or restarts in a loop shows here first,
#             and a Docker that has stopped answering is itself news.
#   /metrics  Did work stop and wait for a person? A request whose retries
#             are spent is blocked and waits on the Failures page; a crash-
#             looping turn ends there too, which is what readiness alone would
#             miss between its retries.
#   helpers   Do the servers on this Mac that compose.env names answer? When
#             the whisper servers stop, Ryker reads voice messages with its own
#             small model, which wrote Andrew's Ukrainian as Russian
#             (2026-09-28); when the embedding server stops, routing finds
#             earlier work by words alone. Nothing else says so.
#
# It does not read the database or integration credentials: an unreachable
# control plane is itself the alarm. It speaks through a macOS notification
# and a log file. Product notifications belong to Ryker's credential-custody
# and delivery paths, not this host-side process check.
set -uo pipefail

repository=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/compose-lifecycle.sh
. "$repository/scripts/compose-lifecycle.sh"

# Overridable so every alarm can be exercised against a fabricated deployment.
# A watchdog that has never been seen to fire is indistinguishable from one
# that cannot.
env_file="${WATCHDOG_ENV_FILE:-${RYKER_INSTALL_STATE:-$repository/.ryker}/compose.env}"
state_dir="${WATCHDOG_STATE:-$HOME/.local/state/ryker-watchdog}"
docker_command="${WATCHDOG_DOCKER:-docker}"
# A Docker that hangs, as a wedged OrbStack does, held this check for good, and
# launchd starts no new one while the last still runs: no alarm came in exactly
# the case that had already happened here (2026-10-04 review). Every Docker
# call gets this many seconds.
docker_timeout="${WATCHDOG_DOCKER_TIMEOUT:-30}"
log="$state_dir/watchdog.log"
# Three consecutive bad checks before saying anything, so a deploy — which
# replaces the container and drops readiness for a minute — passes in silence.
strikes_required="${WATCHDOG_STRIKES:-3}"
# While a deployment stays broken, repeat every half hour rather than every
# minute. An alarm nobody can silence is an alarm everybody learns to ignore.
renotify_minutes="${WATCHDOG_RENOTIFY_MINUTES:-30}"
# launchd starts agents with a PATH that has no Docker on it; the bundled
# worker's own launch agent once lost Docker exactly that way for four days.
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin"
mkdir -p "$state_dir"

# A heartbeat, because this script is silent when everything is well and also
# silent when it is dead, and those must be tellable apart. Written first, so
# it records that the check started even if the check itself then fails.
date -u '+%Y-%m-%dT%H:%M:%SZ' >"$state_dir/heartbeat"

note() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >>"$log"
}

alarm() {
  local title="$1" message="$2"
  note "ALERT $title — $message"
  [[ -n ${WATCHDOG_NO_NOTIFY:-} ]] && return
  # Escaped for AppleScript's string literal, which is the one place a reason
  # containing a quote would otherwise become a syntax error.
  local safe_title=${title//\"/\\\"} safe_message=${message//\"/\\\"}
  /usr/bin/osascript -e "display notification \"$safe_message\" with title \"$safe_title\"" \
    >/dev/null 2>&1 || true
}

# readiness BASE sets readiness_state to "ready", "unreachable" or the host's
# own reasons, and running_version to the x-ryker-version the answer carried.
readiness_state=
running_version=
readiness() {
  local headers="$state_dir/readyz.headers" body="$state_dir/readyz.body" code first
  running_version=""
  code=$(/usr/bin/curl -sS --max-time 10 -D "$headers" -o "$body" -w '%{http_code}' "$1/readyz" 2>/dev/null) || {
    readiness_state="unreachable"
    return
  }
  running_version=$(/usr/bin/awk 'tolower($1) == "x-ryker-version:" { sub(/\r$/, "", $2); print $2; exit }' "$headers" 2>/dev/null)
  if [[ $code == 200 ]]; then
    readiness_state="ready"
  else
    first=$(head -n 1 "$body" 2>/dev/null)
    readiness_state=${first:-"not ready (HTTP $code)"}
  fi
}

# within_deadline SECONDS COMMAND... runs COMMAND, killed with SIGALRM (status
# 142) once SECONDS pass. macOS has no timeout(1); perl is always there.
within_deadline() {
  /usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$@"
}

# containers prints what is wrong with the project's containers, one reason
# per line, or nothing. `volume-init` exits by design and is not listed.
containers() {
  local listing service line state health status
  listing=$(within_deadline "$docker_timeout" "$docker_command" compose --env-file "$env_file" \
    --file "$repository/compose.yml" \
    ps --all --format $'{{.Service}}\t{{.State}}\t{{.Health}}' 2>/dev/null)
  status=$?
  if ((status == 142)); then
    echo "Docker is not answering"
    return
  elif ((status != 0)); then
    echo "docker compose cannot list the project's containers"
    return
  fi
  for service in ryker database ryker-coop ryker-coop-docker; do
    line=$(printf '%s\n' "$listing" | /usr/bin/awk -F '\t' -v service="$service" '$1 == service { print; exit }')
    if [[ -z $line ]]; then
      echo "container $service is missing"
      continue
    fi
    state=$(printf '%s\n' "$line" | cut -f 2)
    health=$(printf '%s\n' "$line" | cut -f 3)
    if [[ $state != running ]]; then
      echo "container $service is ${state:-not running}"
    elif [[ -n $health && $health != healthy && $health != starting ]]; then
      echo "container $service is $health"
    fi
  done
}

# helpers prints what is wrong with the servers on this Mac that compose.env
# names, one reason per line, or nothing. Ryker's container reaches them
# through host.docker.internal, which is this host.
helpers() {
  local name url
  for name in RYKER_WHISPER_URL RYKER_WHISPER_DETECT_URL RYKER_EMBEDDINGS_URL; do
    url=$(compose_env_value "$name" "$env_file")
    [[ -z $url ]] && continue
    url=${url/host.docker.internal/127.0.0.1}
    /usr/bin/curl -s -o /dev/null --max-time 5 "$url/" 2>/dev/null && continue
    case $name in
      RYKER_EMBEDDINGS_URL)
        echo "the embedding server at $url is not answering, so routing finds earlier work by words alone (scripts/embedding-service.sh status)"
        ;;
      *)
        echo "whisper at $url is not answering, so voice messages are read by Ryker's own small model (scripts/voice-service.sh status)"
        ;;
    esac
  done
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

strike_file="$state_dir/ryker.strikes"
alerted_file="$state_dir/ryker.alerted"
blocked_file="$state_dir/ryker.blocked"

# repeat_alarm TITLE MESSAGE alarms, unless it last did less than the renotify
# interval ago: a standing failure is repeated every half hour, not every minute.
repeat_alarm() {
  local now last
  now=$(date +%s)
  last=$(cat "$alerted_file" 2>/dev/null || echo 0)
  if [[ $((now - last)) -ge $((renotify_minutes * 60)) ]]; then
    echo "$now" >"$alerted_file"
    alarm "$1" "$2"
  fi
}

# A watchdog with nothing to watch is itself a failure, not a quiet success. It
# alarmed every minute, past the limit the other alarms keep (2026-10-04 review).
if [[ ! -r $env_file ]]; then
  note "nothing to watch: no Compose installation at $env_file"
  repeat_alarm "Ryker watchdog found nothing to watch" \
    "No Compose installation at $env_file: nothing is pinned there, so nothing is being watched."
  exit 1
fi

port=$(compose_env_value RYKER_CONTROL_PORT "$env_file")
[[ $port =~ ^[0-9]+$ ]] || port=4321
# Ryker does not start with the console published beyond loopback.
base=$(control_origin "$(compose_env_value RYKER_CONTROL_BIND "$env_file")" "$port")
pinned=$(compose_env_value RYKER_VERSION "$env_file")

readiness "$base"
state=$readiness_state
if [[ $state == "ready" && -n $pinned && $running_version != "$pinned" ]]; then
  state="running ${running_version:-an unversioned release}, but $env_file pins $pinned"
elif [[ $state == "unreachable" ]]; then
  state="control plane unreachable at $base"
fi
problems=$(containers | paste -sd ';' - | sed 's/;/; /g')
if [[ -n $problems ]]; then
  if [[ $state == "ready" ]]; then
    state=$problems
  else
    state="$state; $problems"
  fi
fi
# A helper that stopped makes Ryker worse, not stopped, and says so.
title="Ryker is not working"
helper_problems=$(helpers | paste -sd ';' - | sed 's/;/; /g')
if [[ -n $helper_problems ]]; then
  if [[ $state == "ready" ]]; then
    state=$helper_problems
    title="Ryker is working with less: a server on this Mac stopped"
  else
    state="$state; $helper_problems"
  fi
fi

strikes=$(cat "$strike_file" 2>/dev/null || echo 0)
if [[ $state == "ready" ]]; then
  if [[ -f $alerted_file ]]; then
    alarm "Ryker recovered" "The deployment reports ready again, as the pinned $pinned."
    note "recovered after $strikes strikes"
  fi
  rm -f "$strike_file" "$alerted_file"
else
  strikes=$((strikes + 1))
  echo "$strikes" >"$strike_file"
  note "unhealthy (strike $strikes/$strikes_required): $state"
  if [[ $strikes -ge $strikes_required ]]; then
    repeat_alarm "$title" "$state"
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
    alarm "Ryker needs attention" "$blocked $noun blocked and waiting for an operator: $base/failures"
  elif [[ $blocked -lt $previous ]]; then
    note "blocked requests fell from $previous to $blocked"
  fi
  echo "$blocked" >"$blocked_file"
fi
