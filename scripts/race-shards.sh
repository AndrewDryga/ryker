#!/usr/bin/env bash
# Run the race suite with bounded local parallelism. Responder and Coop share
# this development host with the gate: five unconstrained race processes once
# delayed a live session long enough for its binding and cleanup deadlines to
# expire. Operators can raise these limits explicitly on an isolated runner.
set -euo pipefail

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
shards=${RACE_SHARDS:-2}
gomaxprocs=${RACE_GOMAXPROCS:-2}
niceness=${RACE_NICE:-10}
timeout=${RACE_TIMEOUT:-20m}

case "$shards" in
  ''|*[!0-9]*) echo "race: RACE_SHARDS must be a positive integer" >&2; exit 2 ;;
  0) echo "race: RACE_SHARDS must be a positive integer" >&2; exit 2 ;;
esac
case "$gomaxprocs" in
  ''|*[!0-9]*) echo "race: RACE_GOMAXPROCS must be a positive integer" >&2; exit 2 ;;
  0) echo "race: RACE_GOMAXPROCS must be a positive integer" >&2; exit 2 ;;
esac
case "$niceness" in
  ''|*[!0-9]*) echo "race: RACE_NICE must be a non-negative integer" >&2; exit 2 ;;
esac
if [[ ! $timeout =~ ^[1-9][0-9]*(s|m|h)$ ]]; then
  echo "race: RACE_TIMEOUT must be a positive Go duration in s, m, or h" >&2
  exit 2
fi

if [[ ${1:-} == "--settings" ]]; then
  echo "shards=$shards gomaxprocs=$gomaxprocs nice=$niceness timeout=$timeout"
  exit 0
fi

cd "$repository"

tests=$(mktemp)
plan=$(mktemp)
logs=$(mktemp -d)
trap 'rm -f "$tests" "$plan"; rm -rf "$logs"' EXIT

go test ./internal/service -list '^(Test|Example|Fuzz)' |
  awk '/^(Test|Example|Fuzz)/ { print }' >"$tests"
awk -v shards="$shards" '{ print ((NR - 1) % shards) + 1 "\t" $0 }' "$tests" >"$plan"

if [[ ${1:-} == "--plan" ]]; then
  cat "$plan"
  exit 0
fi
if [[ $# -gt 0 ]]; then
  echo "race: unknown argument $1 (only --plan or --settings is accepted)" >&2
  exit 2
fi

pids=()
names=()
start_job() {
  local name=$1
  shift
  echo "race: starting $name"
  ( nice -n "$niceness" env GOMAXPROCS="$gomaxprocs" "$@" ) >"$logs/$name.log" 2>&1 &
  pids+=("$!")
  names+=("$name")
}

other_packages=()
while IFS= read -r import_path; do
  [[ $import_path == */internal/service ]] || other_packages+=("$import_path")
done < <(go list ./...)
if [[ ${#other_packages[@]} -gt 0 ]]; then
  # The store package opens a fresh migrated SQLite database in most tests.
  # Under race instrumentation its full package can exceed Go's default ten
  # minute package timeout while each individual test is still making normal
  # progress, so give this broad shard the same bounded headroom as CI.
  start_job other-packages go test -race -count=1 -timeout="$timeout" "${other_packages[@]}"
fi

shard=1
while [[ $shard -le $shards ]]; do
  regex=$(awk -F '\t' -v shard="$shard" '$1 == shard { print $2 }' "$plan" | paste -sd '|' -)
  if [[ -n $regex ]]; then
    start_job "service-$shard" go test -race -count=1 -timeout="$timeout" ./internal/service -run "^(${regex})$"
  fi
  shard=$((shard + 1))
done

failed=0
i=0
while [[ $i -lt ${#pids[@]} ]]; do
  if wait "${pids[$i]}"; then
    echo "race: ${names[$i]} passed"
  else
    echo "race: ${names[$i]} failed" >&2
    cat "$logs/${names[$i]}.log" >&2
    failed=1
  fi
  i=$((i + 1))
done
exit "$failed"
