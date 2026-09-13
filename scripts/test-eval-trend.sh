#!/usr/bin/env bash
# Exercise the evaluation trend reader against a known history.
#
# The reader is the half that makes writing results worth anything: a reporter
# that silently prints nothing leaves the numbers exactly as discarded as they
# were. So the cases that matter here are the quiet ones — a run with no judge,
# a result that will not parse, a file that is not a world report, an empty
# directory — because each of them could plausibly render as a blank line or a
# zero and read like "no regression".
#
# The fixtures are the exact shape `mix ryker.eval world` writes
# (Ryker.Evals.WorldReport: results with a lane and a judge decision, summary
# with candidate, paired). For six weeks the reader expected the retired Go
# runner's flat `passed`/`total`/`quality.mean_score` and this test fabricated
# that shape, so the reader passed its own gate while printing `0/0 n/a` for
# every real report on disk.
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

# One candidate result per observation; the judge's decision is null when the
# observation was not judged. Baseline results carry their own lane and must
# not be counted as candidate observations.
result() { # lane status judged(true|false|null)
  local judged=null
  case $3 in
    true | false) judged="{\"decision\":{\"overall_pass\":$3},\"status\":\"$2\"}" ;;
  esac
  printf '{"lane":"%s","scenario_id":"s","status":"%s","failures":[],"quality":%s}' \
    "$1" "$2" "$judged"
}

# world passed total judged_passed judged_total paired_regressions|none
world() {
  local passed=$1 total=$2 judged_passed=$3 judged_total=$4 regressions=$5
  local results=() i judged
  for ((i = 0; i < total; i++)); do
    if ((i < judged_total)); then
      if ((i < judged_passed)); then judged=true; else judged=false; fi
    else
      judged=null
    fi
    if ((i < passed)); then
      results+=("$(result candidate passed "$judged")")
    else
      results+=("$(result candidate failed "$judged")")
    fi
  done
  results+=("$(result baseline failed true)")
  local paired=null
  if [[ $regressions != none ]]; then
    paired="{\"baseline_passed\":$passed,\"regressions\":$regressions,\"total\":$total}"
  fi
  local joined
  joined=$(IFS=,; printf '%s' "${results[*]}")
  printf '{"generated_at":"2026-08-01T09:00:00Z","kind":"ryker_model_world","version":2,"results":[%s],"summary":{"candidate":{"failed":%s,"passed":%s,"total":%s},"paired":%s,"passed?":true}}\n' \
    "$joined" "$((total - passed))" "$passed" "$total" "$paired"
}

world 27 30 25 30 none >"$work/history/world-20260801T090000Z.json"
world 30 30 29 30 0 >"$work/history/world-20260807T090000Z.json"
world 9 9 0 0 none >"$work/history/world-smoke-20260803T090000Z.json"
printf 'not json at all' >"$work/history/broken-20260808T010000Z.json"
# A report the retired Go runner wrote: valid JSON, not a world report.
printf '{"mode":"live","total":30,"passed":30,"failed":0,"quality":{"mean_score":4.4},"results":[]}\n' \
  >"$work/history/prompts-20260802T000000Z.json"

report=$("$trend" "$work/history")

grep -Eq '27/30 +90\.0% +judge +83\.3%' <<<"$report" || fail 'the first run is not summarized from summary.candidate and the judge decisions'
grep -Eq '30/30 +100\.0% +judge +96\.7% +regressions 0' <<<"$report" || fail 'the paired run does not report its regressions'
# The whole point is the delta: 90.0% to 100.0% and 83.3% to 96.7%.
grep -Eq '\+10\.0 +\+13\.3' <<<"$report" || fail 'the change between two runs is not reported'
# A run with no judge must say so rather than print a silent zero that would
# read as a collapse in quality.
grep -Eq '9/9 +100\.0% +judge +n/a' <<<"$report" || fail 'an unjudged run did not report n/a'
grep -Fq 'UNREADABLE' <<<"$report" || fail 'a corrupt result was skipped silently'
# Labels carry suffixes; grouping must not fold world-smoke into world.
grep -Eq '^world$' <<<"$report" || fail 'runs are not grouped by label'
grep -Eq '^world-smoke$' <<<"$report" || fail 'the smoke label was folded into world'
# A file that is not a world report is named, once, and never counted as a run.
grep -Fq 'not world reports: prompts-20260802T000000Z' <<<"$report" || fail 'a non-world report was not named'
if grep -Eq '^prompts$' <<<"$report"; then
  fail 'a non-world report was listed as a run'
fi
if grep -Fq '0/0' <<<"$report"; then
  fail 'a run rendered as 0/0'
fi

printf 'eval-trend test: ok\n'
