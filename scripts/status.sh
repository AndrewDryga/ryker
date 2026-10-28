#!/bin/bash
# What is running where, in one screen: main and CI on it, this checkout's
# install (the version it serves against main and the one compose.env pins,
# readiness, the bundled worker, the Docker disk, the newest backup and the
# watchdog), and every install RYKER_WATCH_REMOTE names, as far as its public
# readiness says. On 2026-10-14 those answers took a dozen commands across
# two machines after every deploy, and "is blitz on the new release?" was
# answered from memory more than once.
#
#   scripts/status.sh
#
# Read-only: nothing here starts, stops or changes anything.
set -uo pipefail

repository=$(cd "$(dirname "$0")/.." && pwd)
cd "$repository" || exit
state_dir=${RYKER_INSTALL_STATE:-$repository/.ryker}
env_file=$state_dir/compose.env
# shellcheck source=scripts/compose-lifecycle.sh
. "$repository/scripts/compose-lifecycle.sh"
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin"

main=$(git rev-parse main 2>/dev/null)

ago() {
  local seconds=$(($(date +%s) - $1))
  if ((seconds < 120)); then
    echo "${seconds} s ago"
  elif ((seconds < 7200)); then
    echo "$((seconds / 60)) min ago"
  elif ((seconds < 172800)); then
    echo "$((seconds / 3600)) h ago"
  else
    echo "$((seconds / 86400)) days ago"
  fi
}

# against_main VERSION: where the commit a release was built from stands
# against main. Versions end in -g<sha> (deploy.sh) or .g<sha> (a source
# install's upgrade).
against_main() {
  local commit behind
  commit=$(printf '%s' "$1" | sed -n 's/.*[.-]g\([0-9a-f]\{7,40\}\)$/\1/p')
  commit=$(git rev-parse --verify -q "$commit^{commit}" 2>/dev/null) || {
    echo "a commit this checkout does not have"
    return
  }
  if [[ $commit == "$main" ]]; then
    echo "main"
  elif behind=$(git rev-list --count "$commit..$main" 2>/dev/null) && [[ $behind -gt 0 ]] &&
    git merge-base --is-ancestor "$commit" "$main"; then
    echo "$behind commits behind main"
  else
    echo "not on main"
  fi
}

# readiness ORIGIN: "ready" or the first line the host gave for not being,
# then the version its header names.
readiness() {
  local headers body code first version
  headers=$(mktemp)
  body=$(mktemp)
  code=$(curl -sS --max-time 10 -D "$headers" -o "$body" -w '%{http_code}' "$1/readyz" 2>/dev/null) ||
    code=000
  version=$(awk 'tolower($1) == "x-ryker-version:" { sub(/\r$/, "", $2); print $2; exit }' "$headers")
  first=$(head -n 1 "$body" 2>/dev/null)
  rm -f "$headers" "$body"
  case $code in
    200) echo "ready ${version:-unversioned}" ;;
    000) echo "unreachable -" ;;
    *) echo "not-ready ${version:-unversioned} ${first:-HTTP $code}" ;;
  esac
}

# install LABEL ORIGIN: readiness and version of one install, one line.
install_line() {
  local label=$1 origin=$2 state version rest
  read -r state version rest <<<"$(readiness "$origin")"
  case $state in
    ready) printf '%-8s %s  ready, %s (%s)\n' "$label" "$origin" "$version" "$(against_main "$version")" ;;
    unreachable) printf '%-8s %s  UNREACHABLE\n' "$label" "$origin" ;;
    *) printf '%-8s %s  NOT READY, %s (%s): %s\n' "$label" "$origin" "$version" "$(against_main "$version")" "$rest" ;;
  esac
}

pushed="not pushed"
if [[ $(git rev-parse -q --verify origin/main 2>/dev/null) == "$main" ]]; then
  pushed="pushed"
fi
printf '%-8s %s  %s (%s)\n' main "${main:0:9}" "$(git log -1 --format=%s "$main")" "$pushed"

# CI on main: the run for main's commit, else the newest finished one.
if command -v gh >/dev/null 2>&1; then
  runs=$(gh run list --workflow ci.yml --branch main --limit 10 \
    --json headSha,status,conclusion,updatedAt,databaseId 2>/dev/null)
  if [[ -n $runs ]]; then
    printf '%s' "$runs" | python3 -c '
import json, sys
main = sys.argv[1]
runs = json.load(sys.stdin)
mine = [r for r in runs if r["headSha"] == main]
done = [r for r in runs if r["status"] == "completed" and r["conclusion"] != "cancelled"]
if mine and mine[0]["status"] != "completed":
    line = "running on " + main[:9]
    if done:
        line += ", the last finished run (" + done[0]["headSha"][:9] + "): " + done[0]["conclusion"]
elif mine:
    line = mine[0]["conclusion"] + " on " + main[:9]
elif done:
    line = "no run on " + main[:9] + "; the last finished (" + done[0]["headSha"][:9] + "): " + done[0]["conclusion"]
else:
    line = "no finished run"
print("%-8s %s" % ("CI", line))
' "$main"
  else
    printf '%-8s %s\n' CI "unknown: gh run list gave nothing"
  fi
fi

if [[ -f $env_file ]]; then
  control_port=$(compose_env_value RYKER_CONTROL_PORT "$env_file")
  origin=$(control_origin "$(compose_env_value RYKER_CONTROL_BIND "$env_file")" "${control_port:-4321}")
  install_line local "$origin"
  pinned=$(compose_env_value RYKER_VERSION "$env_file")
  printf '%-8s pinned %s (%s)\n' "" "$pinned" "$(against_main "$pinned")"

  worker=$(docker compose --env-file "$env_file" --file "$repository/compose.yml" ps --all \
    --format '{{.Service}} {{.Image}} {{.State}} {{.Health}}' 2>/dev/null | awk '$1 == "ryker-coop" { print $2, $3, $4 }')
  disk=$(docker compose --env-file "$env_file" --file "$repository/compose.yml" exec -T ryker-coop \
    df -h /var/lib/coop 2>/dev/null | awk 'NR == 2 { print $5 " of " $2 " used" }')
  printf '%-8s worker %s, Docker disk %s\n' "" "${worker:-not found}" "${disk:-unknown}"

  # shellcheck disable=SC2012 # backups are named by their time, nothing else
  newest=$(ls -t "$state_dir"/backups/*.tar.gz 2>/dev/null | head -n 1)
  if [[ -n $newest ]]; then
    backup="newest backup $(basename "$newest") ($(ago "$(stat -c %Y "$newest" 2>/dev/null || stat -f %m "$newest")"))"
  else
    backup="NO BACKUP in $state_dir/backups"
  fi
  if command -v launchctl >/dev/null 2>&1 && ! launchctl list ai.emisar.ryker.backup >/dev/null 2>&1; then
    backup="$backup; no daily backup scheduled (scripts/install-backup-schedule.sh)"
  fi
  printf '%-8s %s\n' "" "$backup"

  # Deployment archives are frequent; their freshness hid a week of failures
  # in the independent daily schedule. Report that cadence on its own.
  daily=$(find "$state_dir/backups" -maxdepth 1 -type f -name 'scheduled-*.tar.gz' 2>/dev/null | sort -r | head -n 1)
  if [[ -z $daily ]]; then
    printf '%-8s %s\n' "" "NO DAILY BACKUP in $state_dir/backups"
  else
    daily_at=$(stat -c %Y "$daily" 2>/dev/null || stat -f %m "$daily")
    daily_state="daily backup"
    (($(date +%s) - daily_at > 129600)) && daily_state="DAILY BACKUP OVERDUE"
    printf '%-8s %s %s (%s)\n' "" "$daily_state" "$(basename "$daily")" "$(ago "$daily_at")"
  fi

  heartbeat=$HOME/.local/state/ryker-watchdog/heartbeat
  if [[ -f $heartbeat ]]; then
    beat=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(cat "$heartbeat")" +%s 2>/dev/null ||
      date -u -d "$(cat "$heartbeat")" +%s 2>/dev/null)
    watchdog="watchdog checked $(ago "${beat:-0}")"
    if [[ -n $beat ]] && (($(date +%s) - beat > 300)); then
      watchdog="WATCHDOG SILENT: last check $(ago "$beat") (scripts/install-watchdog.sh)"
    fi
  else
    watchdog="NO WATCHDOG has run here (scripts/install-watchdog.sh)"
  fi
  printf '%-8s %s\n' "" "$watchdog"
else
  printf '%-8s %s\n' local "no install in $state_dir"
fi

for remote in $(compose_env_value RYKER_WATCH_REMOTE "$env_file"); do
  install_line remote "$remote"
done
