#!/usr/bin/env bash
# Print the trend across recorded model-world evaluations.
#
# `make eval-world` and `make eval-world-smoke` each leave one report under
# $(EVAL_HISTORY), written by Ryker.Evals.WorldReport: every observation with
# its lane and the judge's decision, and a summary with the candidate counts
# and, for a paired run, the regressions against the baseline. CI reads only
# the exit code, so without this reader every release could say the gate
# passed and none could say whether the answers were better than last month's.
#
# It is deliberately a table and not a dashboard — the question is "did the
# number move", and a column of numbers answers it.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: eval-trend.sh [history-directory]

Summarize every recorded model-world evaluation, grouped by the label that
produced it and ordered by time. Prints the candidate pass rate, the share of
judged candidate observations the judge passed, and the paired regression
count per run, with the change from the previous run of the same label.

Defaults to $EVAL_HISTORY, then ~/.local/state/ryker/eval-history.
EOF
}

case "${1:-}" in
  --help | -h)
    usage
    exit 0
    ;;
esac

history_dir=${1:-${EVAL_HISTORY:-$HOME/.local/state/ryker/eval-history}}

if ! command -v jq >/dev/null 2>&1; then
  printf 'eval-trend: jq is required\n' >&2
  exit 2
fi
if [[ ! -d $history_dir ]]; then
  printf 'eval-trend: %s does not exist; no model evaluation has recorded a result yet\n' \
    "$history_dir" >&2
  exit 1
fi

# Sorted by filename, which is <label>-<UTC timestamp>.json, so a plain sort is
# chronological within a label without parsing the timestamp back out.
results=()
while IFS= read -r line; do
  results+=("$line")
done < <(find "$history_dir" -maxdepth 1 -type f -name '*.json' | sort)

if ((${#results[@]} == 0)); then
  printf 'eval-trend: %s holds no results yet; run a model evaluation first\n' \
    "$history_dir" >&2
  exit 1
fi

# One row per run: label, timestamp, passed, total, pass rate, judge pass share,
# paired regressions. A summary that will not parse is reported rather than
# skipped silently — a corrupt result is itself a finding, and dropping it would
# overstate the trend. A readable file that is not a world report is named once
# at the end and never counted as a run.
rows=$(
  for path in "${results[@]}"; do
    file=$(basename "$path" .json)
    label=${file%-*}
    stamp=${file##*-}
    if ! jq -e . "$path" >/dev/null 2>&1; then
      printf '%s\t%s\tUNREADABLE\n' "$label" "$stamp"
      continue
    fi
    jq -r --arg label "$label" --arg stamp "$stamp" --arg file "$file" '
      def count: (. // 0);
      if (.summary.candidate | type) != "object" then
        ["NOT_WORLD", $file] | @tsv
      else
        (.summary.candidate.passed | count) as $passed
        | (.summary.candidate.total | count) as $total
        | ([.results[]? | select(.lane == "candidate")
            | .quality.decision.overall_pass | select(. != null)]) as $judged
        | [
            $label,
            $stamp,
            ($passed | tostring),
            ($total | tostring),
            (if $total > 0 then ($passed / $total * 100) else -1 end | tostring),
            (if ($judged | length) > 0
             then (([$judged[] | select(. == true)] | length) / ($judged | length) * 100)
             else -1 end | tostring),
            (if (.summary.paired | type) == "object"
             then (.summary.paired.regressions | count | tostring)
             else "-" end)
          ] | @tsv
      end
    ' "$path"
  done
)

printf '%s\n\n' "model-world evaluation trend — $history_dir"

printf '%s\n' "$rows" | awk -F'\t' '
function pct(v) { return v < 0 ? "  n/a" : sprintf("%5.1f%%", v) }
function delta(now, was) {
  if (was == "" || now < 0 || was < 0) return ""
  d = now - was
  if (d > -0.05 && d < 0.05) return "     ="
  return sprintf("%+6.1f", d)
}
$1 == "NOT_WORLD" {
  skipped = skipped == "" ? $2 : skipped ", " $2
  skipped_count++
  next
}
{
  label = $1
  if (label != current) {
    if (current != "") printf "\n"
    printf "%s\n", label
    current = label
    lastpct = ""
    lastjudge = ""
  }
  runs++
  if ($3 == "UNREADABLE") {
    printf "  %s  UNREADABLE — this result did not parse\n", $2
    next
  }
  regressions = $7 == "-" ? "" : sprintf("  regressions %s", $7)
  printf "  %s  %4d/%-4d  %s  judge %s%s   %s %s\n",
    $2, $3, $4, pct($5), pct($6), regressions, delta($5, lastpct), delta($6, lastjudge)
  if ($5 >= 0) lastpct = $5
  if ($6 >= 0) lastjudge = $6
}
END {
  if (current == "") print "  no readable world reports"
  printf "\n%d run(s). \"judge n/a\" means no candidate observation of that run was judged;\n", runs
  print "regressions are counted only for a paired run."
  if (skipped_count > 0)
    printf "%d file(s) are not world reports: %s\n", skipped_count, skipped
}
'
