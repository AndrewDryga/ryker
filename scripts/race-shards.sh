#!/usr/bin/env bash
# Run the race suite in parallel. internal/service owns most tests, so package
# parallelism alone leaves one CPU-heavy process as the critical path.
set -euo pipefail

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
shards=${RACE_SHARDS:-4}

case "$shards" in
  ''|*[!0-9]*) echo "race: RACE_SHARDS must be a positive integer" >&2; exit 2 ;;
  0) echo "race: RACE_SHARDS must be a positive integer" >&2; exit 2 ;;
esac

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
  echo "race: unknown argument $1 (only --plan is accepted)" >&2
  exit 2
fi

pids=()
names=()
start_job() {
  local name=$1
  shift
  echo "race: starting $name"
  ( "$@" ) >"$logs/$name.log" 2>&1 &
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
  start_job other-packages go test -race -count=1 -timeout=20m "${other_packages[@]}"
fi

shard=1
while [[ $shard -le $shards ]]; do
  regex=$(awk -F '\t' -v shard="$shard" '$1 == shard { print $2 }' "$plan" | paste -sd '|' -)
  if [[ -n $regex ]]; then
    start_job "service-$shard" go test -race -count=1 ./internal/service -run "^(${regex})$"
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
