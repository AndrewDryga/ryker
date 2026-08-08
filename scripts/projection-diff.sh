#!/usr/bin/env bash
# Compare what two builds SAY about the same production data.
#
# The gate proves a build does what its tests say. migration-check proves it
# does not destroy rows. Neither notices a build that keeps every row, passes
# every test, and quietly changes what a word counts — the shape of the
# `refused` vocabulary change of 2026-08-07, which would have started reporting
# every refused episode as overdue work needing attention.
#
# So ask both builds the same questions about the same database and diff the
# answers. The previous binary reads an untouched copy; the candidate reads a
# copy it has migrated itself. A difference is not automatically a fault — a
# change whose PURPOSE is to count differently will show up here, and should —
# but it is never something to discover in production.
#
# Read-only throughout, and never against the live state directory: both sides
# run against copies, through a config whose state_dir points at the copy.
set -euo pipefail

usage() { echo "usage: projection-diff.sh <deployment-dir> <previous-binary> <candidate-binary>" >&2; exit 2; }
[[ $# -eq 3 ]] || usage
deployment=$1; previous=$2; candidate=$3
[[ -d $deployment && -x $previous && -x $candidate ]] || usage

config="$deployment/.responder/responder.yaml"
[[ -f $config ]] || { echo "projection-diff: no config at $config" >&2; exit 2; }
state=$(sed -n 's/^state_dir: *//p' "$config" | head -1)
[[ -d $state ]] || { echo "projection-diff: no state dir at $state" >&2; exit 2; }

work=$(mktemp -d -t responder-projection-diff)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/before/state" "$work/after"

# A config per side, identical to the deployment's except for where it reads.
side_config() { # dir statedir
  sed "s#^state_dir: .*#state_dir: $2#" "$config" > "$1/responder.yaml"
  echo "$1/responder.yaml"
}

cp "$state/responder.db" "$work/before/state/responder.db"
before_config=$(side_config "$work/before" "$work/before/state")

# migration-check leaves the migrated copy behind, so the candidate reads
# exactly the database it would create on deployment.
"$candidate" migration-check --config "$config" --keep "$work/after/state" >/dev/null
after_config=$(side_config "$work/after" "$work/after/state")

# Volatile by nature: wall-clock, durations, and the ids of rows a report
# happens to order differently. Normalised so the diff is about MEANING.
normalize() {
  sed -E \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.+-]+/<time>/g' \
    -e 's/[0-9]+(\.[0-9]+)?(ms|s|m|h)\b/<duration>/g' \
    -e 's/[[:space:]]+/ /g' |
    sort
}

status=0
# A report that FAILS on both sides produces no output on both sides, and
# "nothing equals nothing" would read as agreement. Exit codes are checked so
# a check that could not run says so instead of quietly passing — the same
# false-pass this pipeline has already had to fix twice tonight.
run_report() { # binary config out
  local binary=$1 conf=$2 out=$3 rc
  # shellcheck disable=SC2086  # report intentionally carries its own flags
  ( cd "$deployment" && "$binary" $report --config "$conf" ) > "$out.raw" 2>"$out.err"
  rc=$?
  normalize < "$out.raw" > "$out"
  return $rc
}

for report in "status" "failures" "correction-rate --days 30" "lifecycle-divergence"; do
  name=${report%% *}
  before_rc=0; after_rc=0
  run_report "$previous" "$before_config" "$work/before.$name" || before_rc=$?
  run_report "$candidate" "$after_config" "$work/after.$name" || after_rc=$?
  if [[ $before_rc -ne 0 || $after_rc -ne 0 ]]; then
    echo "projection-diff: $name could not be compared (previous rc=$before_rc, candidate rc=$after_rc)"
    sed -n '1,3p' "$work/before.$name.err" "$work/after.$name.err" 2>/dev/null | sed 's/^/    /'
    status=1
    continue
  fi
  if diff -q "$work/before.$name" "$work/after.$name" >/dev/null 2>&1; then
    echo "projection-diff: $name unchanged"
  else
    echo "projection-diff: $name DIFFERS between builds:"
    diff -u "$work/before.$name" "$work/after.$name" | sed -n '3,23p' | sed 's/^/    /'
    status=1
  fi
done

if [[ $status -ne 0 ]]; then
  echo "projection-diff: this build reports differently about the same data." >&2
  echo "projection-diff: intended for a change that redefines a count; otherwise it is drift." >&2
fi
exit $status
