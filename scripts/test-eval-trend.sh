#!/usr/bin/env bash
# Exercise the evaluation trend reader against a known history.
#
# The reader is the half of the fix that makes writing results worth anything:
# --results was already implemented and already ignored, and a reporter that
# silently prints nothing would leave the numbers exactly as discarded as they
# were. So the cases that matter here are the quiet ones — a run with no judge,
# a result that will not parse, an empty directory — because each of them could
# plausibly render as a blank line and read like "no regression".
set -euo pipefail

repository=${RYKER_QUALITY_REPOSITORY:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
trend="$repository/scripts/eval-trend.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/ryker-eval-trend-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

fail() {
  printf 'eval-trend test: %s\n' "$1" >&2
  exit 1
}

"$trend" --help >/dev/null || fail 'the help text does not render'

# A directory that does not exist and one that is empty are different states and
# neither is a pass. Both must be loud.
if "$trend" "$work/absent" >/dev/null 2>&1; then
  fail 'a missing history directory reported success'
fi
mkdir -p "$work/history"
if "$trend" "$work/history" >/dev/null 2>&1; then
  fail 'an empty history directory reported success'
fi

summary() {
  printf '{"mode":"live","total":%s,"passed":%s,"failed":%s,"quality":%s,"results":[]}\n' \
    "$1" "$2" "$3" "$4"
}

summary 30 27 3 '{"evaluated":30,"passed":25,"mean_score":4.10}' \
  >"$work/history/quality-20260801T090000Z.json"
summary 30 30 0 '{"evaluated":30,"passed":29,"mean_score":4.40}' \
  >"$work/history/quality-20260807T090000Z.json"
summary 22 22 0 '{}' >"$work/history/episode-replay-blitz-20260803T090000Z.json"
printf 'not json at all' >"$work/history/broken-20260808T010000Z.json"

report=$("$trend" "$work/history")

grep -Fq 'quality 4.10' <<<"$report" || fail 'the first judged score is missing'
grep -Fq 'quality 4.40' <<<"$report" || fail 'the second judged score is missing'
# The whole point is the delta: 90.0% to 100.0% and 4.10 to 4.40.
grep -Eq '\+10\.0 +\+0\.30' <<<"$report" || fail 'the change between two runs is not reported'
# A run with no judge must say so rather than print a silent zero that would
# read as a collapse in quality.
grep -Fq 'quality  n/a' <<<"$report" || fail 'an unjudged run did not report n/a'
grep -Fq 'UNREADABLE' <<<"$report" || fail 'a corrupt result was skipped silently'
# Per-deployment labels carry a suffix; grouping must not fold them together.
grep -Fq 'episode-replay-blitz' <<<"$report" || fail 'the deployment label was lost'
grep -Eq '^quality$' <<<"$report" || fail 'runs are not grouped by target'

printf 'eval-trend test: ok\n'
