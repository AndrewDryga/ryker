#!/bin/bash
# Checks this checkout and host for the faults that have each cost an
# afternoon here, and with --fix repairs the ones that are safe to repair:
#
#   scripts/doctor.sh          say what is wrong
#   scripts/doctor.sh --fix    and repair what can be repaired without a person
#
# Each check is a recovery that used to live in a note an agent had to find
# and follow by hand. It never restarts Docker, the install or a worker, and
# never touches the live database; those it only names. Exit status 1 means
# something is still wrong.
set -uo pipefail

repository=$(cd "$(dirname "$0")/.." && pwd)
cd "$repository" || exit 1
state_dir=${RYKER_INSTALL_STATE:-$repository/.ryker}
env_file=$state_dir/compose.env
docker_command=${DOCTOR_DOCKER:-docker}
gate_lock=${RYKER_GATE_LOCK:-/tmp/ryker-gate.lock}
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin"
# shellcheck source=scripts/compose-lifecycle.sh
. "$repository/scripts/compose-lifecycle.sh"

fix=0
case ${1:-} in
  --fix) fix=1 ;;
  "") ;;
  *)
    echo "usage: scripts/doctor.sh [--fix]" >&2
    exit 2
    ;;
esac

problems=0
ok() { printf '  ok     %s\n' "$1"; }
fixed() { printf '  FIXED  %s\n' "$1"; }
problem() {
  printf '  WRONG  %s\n' "$1"
  problems=$((problems + 1))
}

# within SECONDS COMMAND...: macOS has no timeout(1); perl is always there.
within() { /usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$@"; }

alive() { [[ -n $1 ]] && kill -0 "$1" 2>/dev/null; }

test_db() {
  within 15 "$docker_command" exec ryker-kernel-episode-db-1 psql -X -U postgres -d postgres -At "$@" 2>/dev/null
}

echo "doctor: $repository"

# A worktree's linked deps or .elixir was once committed, and merging it wrote
# links over the real directories, each pointing at itself (2026-09-11).
for directory in deps .elixir; do
  if [[ -L $directory ]]; then
    if ((fix == 1)); then
      rm "$directory" && mkdir -p "$directory"
      if env MIX_ENV=test scripts/elixir-mix.sh deps.get >/dev/null 2>&1; then
        fixed "$directory was a link; it is a directory again, dependencies fetched"
      else
        problem "$directory was a link; it is a directory again, but fetching the dependencies failed"
      fi
    else
      problem "$directory is a link, not a directory (--fix makes it one and fetches the dependencies)"
    fi
  fi
done

# A wedged OrbStack held every docker and psql call forever (2026-10-09).
if within 10 "$docker_command" info >/dev/null 2>&1; then
  ok "Docker answers"
else
  problem "Docker does not answer in 10 s: if OrbStack is wedged, quit it by its exact PID and open it again"
  echo "doctor: $problems problems"
  exit 1
fi

# The test server's capacity lives in compose.test.yml, and `up` recreates the
# container when that changes; 100 connections once failed 52 tests (2026-09-11).
connections=$(test_db -c 'SHOW max_connections')
if [[ $connections == 500 ]]; then
  ok "the test PostgreSQL allows 500 connections"
elif ((fix == 1)) && "$docker_command" compose --project-name ryker-kernel --file compose.test.yml \
  up --detach --wait episode-db >/dev/null 2>&1; then
  fixed "the test PostgreSQL runs as compose.test.yml says"
else
  problem "the test PostgreSQL ${connections:+allows $connections connections }is not as compose.test.yml says (--fix starts it so)"
fi

# Isolated test databases are named for the run's PID; a run that was stopped
# part-way left five behind (2026-10-14).
leftover=()
while IFS= read -r database; do
  pid=$(sed -E 's/^ryker_test_([0-9]+)_.*/\1/' <<<"$database")
  alive "$pid" || leftover+=("$database")
done < <(test_db -c "SELECT datname FROM pg_database WHERE datname ~ '^ryker_test_[0-9]+_[0-9]+(_p[0-9]+)?$'")
if ((${#leftover[@]} == 0)); then
  ok "no test databases left by runs that are gone"
elif ((fix == 1)); then
  for database in "${leftover[@]}"; do
    test_db -c "DROP DATABASE IF EXISTS \"$database\" WITH (FORCE)" >/dev/null
  done
  fixed "dropped ${#leftover[@]} test databases left by runs that are gone"
else
  problem "${#leftover[@]} test databases were left by runs that are gone (--fix drops them)"
fi

# A stopped run's sessions commit outside the sandbox, and every later test
# that claims work claimed them instead: 599 false failures (2026-10-07).
working=$(test_db -d ryker_test -c "SELECT count(*) FROM episode_kernel_episodes WHERE state = 'working'" 2>/dev/null)
clients=$(test_db -c "SELECT count(*) FROM pg_stat_activity WHERE datname = 'ryker_test'")
if [[ -z $working || $working == 0 ]]; then
  ok "the shared test database holds no work a stopped run left"
elif [[ $clients != 0 ]]; then
  problem "the shared test database holds $working working episodes, and $clients connections use it now; run doctor again when they are done"
elif ((fix == 1)); then
  test_db -c "DROP DATABASE IF EXISTS ryker_test" >/dev/null
  fixed "dropped the shared test database, which held $working working episodes; the next test run makes it again"
else
  problem "the shared test database holds $working working episodes a stopped run left (--fix drops it; the next run makes it again)"
fi

# Worktrees deleted from disk stay registered until pruned.
if [[ -z $(git worktree prune --dry-run 2>/dev/null) ]]; then
  ok "every registered worktree exists"
elif ((fix == 1)); then
  git worktree prune && fixed "pruned the worktrees that no longer exist"
else
  problem "worktrees that no longer exist are still registered (--fix prunes them)"
fi

# A gate that died leaves its lock; the next gate takes it over, a person may not know.
holder=$(cat "$gate_lock/pid" 2>/dev/null)
if [[ ! -d $gate_lock ]]; then
  ok "no gate lock is held"
elif alive "$holder"; then
  ok "a gate runs now (PID $holder)"
elif ((fix == 1)); then
  rm -rf "$gate_lock" && fixed "removed the lock a gate that is gone left"
else
  problem "a gate that is gone left its lock at $gate_lock (--fix removes it)"
fi

# Evals stopped and gates failed at 90% of the disk (2026-09 and 10-12).
free_gb=$(df -g / 2>/dev/null | awk 'NR == 2 { print $4 }')
if [[ -z $free_gb ]] || ((free_gb >= 50)); then
  ok "the disk has ${free_gb:-enough} GB free"
else
  problem "the disk has $free_gb GB free; gates and evals need about 50 (docker builder prune, then old images)"
fi

if [[ -f $env_file ]]; then
  # The watchdog was lost after the move to Compose for days (2026-09-26).
  if command -v launchctl >/dev/null 2>&1 && ! launchctl list ai.emisar.ryker.watchdog >/dev/null 2>&1; then
    if ((fix == 1)) && scripts/install-watchdog.sh >/dev/null 2>&1; then
      fixed "installed the watchdog"
    else
      problem "the watchdog is not installed (--fix installs it: scripts/install-watchdog.sh)"
    fi
  else
    ok "the watchdog is installed"
  fi

  # The worker moves to the image its recipe names only when someone runs worker-upgrade.
  pinned=$(worker_image "$repository")
  worker=$(within 10 "$docker_command" compose --env-file "$env_file" ps --all \
    --format '{{.Service}} {{.Image}}' 2>/dev/null | awk '$1 == "ryker-coop" { print $2 }')
  if [[ -z $worker || $worker == "$pinned" ]]; then
    ok "the worker runs the image its recipe names${worker:+ ($worker)}"
  else
    problem "the worker runs $worker, its recipe names $pinned (scripts/compose.sh worker-upgrade)"
  fi
fi

echo "doctor: $problems problems"
((problems == 0))
