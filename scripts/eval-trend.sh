#!/usr/bin/env bash
# Print the trend across recorded model evaluations.
#
# The judges have always produced numbers. A quality rubric scores six
# dimensions per case, an evidence verifier re-checks the claims, and a
# calibration pass scores the judge itself. All of it went to stdout and then to
# nowhere: --results was passed by no target, no script, and no CI job, and CI
# reads only the exit code. So every release could say the gate passed and none
# of them could say whether the answers were better than last month's.
#
# This is the reader for what the Makefile now writes. It is deliberately a
# table and not a dashboard — the question is "did the number move", and a
# column of numbers answers it.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: eval-trend.sh [history-directory]

Summarize every recorded model evaluation, grouped by the target that produced
it and ordered by time. Prints pass rate and mean judge score per run, with the
change from the previous run of the same target.

Defaults to $EVAL_HISTORY, then ~/.local/state/responder/eval-history.
EOF
}

case "${1:-}" in
  --help | -h)
    usage
    exit 0
    ;;
esac

history_dir=${1:-${EVAL_HISTORY:-$HOME/.local/state/responder/eval-history}}

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

# One row per run: label, timestamp, passed, total, pass rate, mean quality.
# A summary that will not parse is reported rather than skipped silently — a
# corrupt result is itself a finding, and dropping it would overstate the trend.
rows=$(
  for path in "${results[@]}"; do
    file=$(basename "$path" .json)
    label=${file%-*}
    stamp=${file##*-}
    if ! jq -e . "$path" >/dev/null 2>&1; then
      printf '%s\t%s\tUNREADABLE\n' "$label" "$stamp"
      continue
    fi
    jq -r --arg label "$label" --arg stamp "$stamp" '
      [
        $label,
        $stamp,
        (.passed // 0 | tostring),
        (.total // 0 | tostring),
        (if (.total // 0) > 0 then ((.passed // 0) / .total * 100) else -1 end | tostring),
        ((.quality.mean_score // -1) | tostring)
      ] | @tsv
    ' "$path"
  done
)

printf '%s\n\n' "model evaluation trend — $history_dir"

printf '%s\n' "$rows" | awk -F'\t' '
function pct(v) { return v < 0 ? "  n/a" : sprintf("%5.1f", v) }
function qual(v) { return v < 0 ? " n/a" : sprintf("%4.2f", v) }
function delta(now, was) {
  if (was == "" || now < 0 || was < 0) return ""
  d = now - was
  if (d > -0.05 && d < 0.05) return "     ="
  return sprintf("%+6.1f", d)
}
function qdelta(now, was) {
  if (was == "" || now < 0 || was < 0) return ""
  d = now - was
  if (d > -0.005 && d < 0.005) return "     ="
  return sprintf("%+6.2f", d)
}
{
  label = $1
  if (label != current) {
    if (current != "") printf "\n"
    printf "%s\n", label
    current = label
    lastpct = ""
    lastqual = ""
  }
  if ($3 == "UNREADABLE") {
    printf "  %s  UNREADABLE — this result did not parse\n", $2
    next
  }
  printf "  %s  %4d/%-4d  %s%%  quality %s   %s %s\n",
    $2, $3, $4, pct($5), qual($6), delta($5, lastpct), qdelta($6, lastqual)
  if ($5 >= 0) lastpct = $5
  if ($6 >= 0) lastqual = $6
}
END {
  if (current == "") print "  no readable results"
}
'

printf '\n%d run(s). "quality n/a" means that run had no judge; only --judge and\n' "${#results[@]}"
printf '%s\n' "--calibrate-judge produce a score."
