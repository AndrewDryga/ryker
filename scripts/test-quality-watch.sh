#!/usr/bin/env bash
set -euo pipefail

repository=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/responder-quality-watch-test.XXXXXX")
trap 'rm -rf "$temporary"' EXIT

state_dir="$temporary/state"
fake_codex="$temporary/codex"
capture="$temporary/prompt"
count_file="$temporary/count"
mkdir -p "$state_dir"

cat >"$fake_codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=""
while (($# > 0)); do
  if [[ "$1" == "--output-last-message" ]]; then
    output=$2
    shift 2
    continue
  fi
  shift
done
cat >"$QUALITY_WATCH_TEST_CAPTURE"
count=0
if [[ -f "$QUALITY_WATCH_TEST_COUNT" ]]; then
  count=$(<"$QUALITY_WATCH_TEST_COUNT")
fi
count=$((count + 1))
printf '%s\n' "$count" >"$QUALITY_WATCH_TEST_COUNT"

if [[ ${QUALITY_WATCH_TEST_MODE:-clean} == challenge && $count -eq 1 ]] ||
   [[ ${QUALITY_WATCH_TEST_MODE:-clean} == confirmed && $count -le 2 ]]; then
  needs_fix=true
  confidence=high
  severity=high
  summary="proposed defect"
  code_evidence='["internal/service/watch.go: test evidence"]'
else
  needs_fix=false
  confidence=high
  severity=none
  summary="no defect"
  code_evidence='[]'
fi
jq -n \
  --argjson needs_fix "$needs_fix" \
  --arg confidence "$confidence" \
  --arg severity "$severity" \
  --arg summary "$summary" \
  --argjson code_evidence "$code_evidence" \
  '{
    needs_fix: $needs_fix,
    confidence: $confidence,
    severity: $severity,
    summary: $summary,
    evidence: [],
    code_evidence: $code_evidence,
    expected_behavior: "",
    suspected_components: [],
    regression_test: ""
  }' >"$output"
EOF
chmod 700 "$fake_codex"

sqlite3 "$state_dir/responder.db" <<'SQL'
CREATE TABLE agent_runs (
  id TEXT PRIMARY KEY,
  mode TEXT,
  state TEXT,
  terminal_state TEXT,
  channel_id TEXT,
  thread_ts TEXT,
  source_kind TEXT,
  source_id TEXT,
  repository TEXT,
  last_error TEXT,
  created_at TEXT,
  started_at TEXT,
  completed_at TEXT,
  updated_at TEXT,
  result_json TEXT,
  failure_count INTEGER
);
CREATE TABLE slack_inputs (
  id TEXT PRIMARY KEY,
  kind TEXT,
  channel_id TEXT,
  thread_ts TEXT,
  user_id TEXT,
  message_ts TEXT,
  text TEXT,
  state TEXT,
  failure_count INTEGER,
  last_error TEXT,
  received_at TEXT,
  updated_at TEXT
);
CREATE TABLE evaluation_decisions (
  source_input TEXT,
  mode TEXT,
  action TEXT,
  reason TEXT,
  evidence_count INTEGER,
  coverage_count INTEGER
);
CREATE TABLE slack_deliveries (
  id TEXT PRIMARY KEY,
  state TEXT,
  operation TEXT,
  kind TEXT,
  message_ts TEXT,
  last_error TEXT,
  body_json TEXT
);
SQL

run_watch() {
  QUALITY_WATCH_TEST_CAPTURE="$capture" \
  QUALITY_WATCH_TEST_COUNT="$count_file" \
  QUALITY_WATCH_TEST_MODE="${1:-clean}" \
  RESPONDER_QUALITY_STATE_DIR="$state_dir" \
  RESPONDER_QUALITY_TEST_CHANNEL=C0TENANTX01 \
  RESPONDER_QUALITY_REPOSITORY="$repository" \
  RESPONDER_QUALITY_CODEX="$fake_codex" \
    "$repository/scripts/quality-watch.sh" "${@:2}"
}

mkdir -p "$state_dir/quality-watch/lock"
printf '999999\n' >"$state_dir/quality-watch/lock/pid"
run_watch clean --from-now --once
if [[ -d "$state_dir/quality-watch/lock" ]]; then
  printf 'quality-watch test: stale lock was not reclaimed\n' >&2
  exit 1
fi
sqlite3 "$state_dir/responder.db" <<'SQL'
INSERT INTO slack_inputs (
  id, kind, channel_id, thread_ts, user_id, message_ts, text, state,
  failure_count, last_error, received_at, updated_at
) VALUES (
  'slack_one', 'mention', 'C0TENANTX01', '', 'U123', '2999.001',
  'check production health', 'done', 0, '',
  '2999-01-01T00:00:00.000Z', '2999-01-01T00:00:02.000Z'
);
INSERT INTO agent_runs VALUES (
  'run_one', 'triage', 'completed', 'completed', 'C0TENANTX01', '',
  'watch', 'slack_one', 'emisar', '',
  '2999-01-01T00:00:00.000Z', '2999-01-01T00:00:01.000Z',
  '2999-01-01T00:00:02.000Z', '2999-01-01T00:00:02.000Z', '{"action":"reply"}', 0
);
INSERT INTO slack_deliveries VALUES (
  'watch_reply_slack_one', 'sent', 'post', 'notice', '2999.002', '',
  '{"text":"Production is healthy within the checked scope."}'
);
SQL
run_watch clean --once
grep -Fq 'Production is healthy within the checked scope.' "$capture"
grep -Fq '"reply_delivery_state": "sent"' "$capture"
grep -Fq 'C0TENANTX01' "$capture"
grep -Fq $'2999-01-01T00:00:02.000Z\trun_one' "$state_dir/quality-watch/cursor.tsv"

rm -f "$count_file"
sqlite3 "$state_dir/responder.db" <<'SQL'
INSERT INTO slack_inputs (
  id, kind, channel_id, thread_ts, user_id, message_ts, text, state,
  failure_count, last_error, received_at, updated_at
) VALUES (
  'slack_two', 'mention', 'C0TENANTX01', '', 'U123', '2999.003',
  'check the deployment', 'done', 0, '',
  '2999-01-01T00:00:03.000Z', '2999-01-01T00:00:05.000Z'
);
INSERT INTO agent_runs VALUES (
  'run_two', 'triage', 'completed', 'completed', 'C0TENANTX01', '',
  'watch', 'slack_two', 'emisar', '',
  '2999-01-01T00:00:03.000Z', '2999-01-01T00:00:04.000Z',
  '2999-01-01T00:00:05.000Z', '2999-01-01T00:00:05.000Z', '{"action":"reply"}', 0
);
INSERT INTO slack_deliveries VALUES (
  'out_run_run_two', 'sent', 'post', 'assistant', '2999.004', '',
  '{"text":"The deployment is healthy.","actions":[{"id":"stale_control","label":"Create draft PR"}]}'
);
SQL
run_watch challenge --once
grep -Fq 'Create draft PR' "$capture"
grep -Fq 'adversarial review rejected the proposed defect' \
  "$state_dir/quality-watch/quality-watch.log"
if find "$state_dir/quality-watch/worktrees" -mindepth 1 -print -quit | grep -q .; then
  printf 'quality-watch test: adversarial rejection created a worktree\n' >&2
  exit 1
fi

rm -f "$count_file"
sqlite3 "$state_dir/responder.db" <<'SQL'
INSERT INTO slack_inputs (
  id, kind, channel_id, thread_ts, user_id, message_ts, text, state,
  failure_count, last_error, received_at, updated_at
) VALUES (
  'slack_three', 'mention', 'C0TENANTX01', '2999.006', 'U123', '2999.006',
  '<@U999BOT>', 'failed', 12, 'empty Slack message',
  '2999-01-01T00:00:06.000Z', '2999-01-01T00:00:07.000Z'
);
INSERT INTO slack_deliveries VALUES (
  'out_input_error_slack_three', 'sent', 'post', 'notice', '2999.007', '',
  '{"text":"Responder could not complete that request after retrying.","reason":"empty Slack message"}'
);
SQL
run_watch clean --once
grep -Fq '"mode": "input"' "$capture"
grep -Fq 'empty Slack message' "$capture"
grep -Fq 'Responder could not complete that request after retrying.' "$capture"
grep -Fq $'2999-01-01T00:00:07.000Z\tinput_error_slack_three' \
  "$state_dir/quality-watch/cursor.tsv"

rm -f "$count_file"
sqlite3 "$state_dir/responder.db" <<'SQL'
INSERT INTO slack_inputs (
  id, kind, channel_id, thread_ts, user_id, message_ts, text, state,
  failure_count, last_error, received_at, updated_at
) VALUES (
  'slack_four', 'mention', 'C0TENANTX01', '', 'U123', '2999.008',
  'check every pull zone for unresolved traffic spikes', 'done', 0, '',
  '2999-01-01T00:00:08.000Z', '2999-01-01T00:00:10.000Z'
);
INSERT INTO agent_runs VALUES (
  'run_four', 'triage', 'completed', 'failed', 'C0TENANTX01', '',
  'watch', 'slack_four', 'tenant-platform', 'ACP transcript exceeded its bound',
  '2999-01-01T00:00:08.000Z', '2999-01-01T00:00:09.000Z',
  '2999-01-01T00:00:10.000Z', '2999-01-01T00:00:10.000Z', '', 20
);
INSERT INTO slack_deliveries VALUES (
  'watch_failure_slack_four', 'sent', 'post', 'notice', '2999.009', '',
  '{"text":"Responder could not complete this check.","reason":"ACP transcript exceeded its bound"}'
);
SQL
run_watch clean --once
grep -Fq 'Responder could not complete this check.' "$capture"
grep -Fq '"reply_delivery_state": "sent"' "$capture"
grep -Fq '"failure_count": 20' "$capture"

rm -f "$count_file"
mkdir -p "$state_dir/quality-watch/worktrees/old-failure"
sqlite3 "$state_dir/responder.db" <<'SQL'
INSERT INTO slack_inputs (
  id, kind, channel_id, thread_ts, user_id, message_ts, text, state,
  failure_count, last_error, received_at, updated_at
) VALUES (
  'slack_five', 'mention', 'C0TENANTX01', '', 'U123', '2999.011',
  'check another failure', 'done', 0, '',
  '2999-01-01T00:00:11.000Z', '2999-01-01T00:00:13.000Z'
);
INSERT INTO agent_runs VALUES (
  'run_five', 'triage', 'completed', 'failed', 'C0TENANTX01', '',
  'watch', 'slack_five', 'tenant-platform', 'reproducible failure',
  '2999-01-01T00:00:11.000Z', '2999-01-01T00:00:12.000Z',
  '2999-01-01T00:00:13.000Z', '2999-01-01T00:00:13.000Z', '', 1
);
SQL
run_watch confirmed --once
if [[ $(<"$count_file") != 3 ]]; then
  printf 'quality-watch test: quarantined worktree blocked a later fixer\n' >&2
  exit 1
fi
if [[ ! -f "$state_dir/quality-watch/quarantine/old-failure.meta" ]]; then
  printf 'quality-watch test: orphaned worktree was not quarantined\n' >&2
  exit 1
fi
grep -Fq 'fixer confirmed no code change was justified' \
  "$state_dir/quality-watch/quality-watch.log"

# The bug this file exists to prevent a second time: when the assessor could not
# run at all, the watcher advanced its cursor and logged "no high-confidence
# product defect", so 56 batches were discarded unexamined over a day while the
# loop reported clean. A check that cannot run must not read like one that
# passed. Both rungs are pointed at a binary that always fails.
failing="$temporary/always-fails"
cat >"$failing" <<'EOF'
#!/usr/bin/env bash
printf "You've hit your usage limit.\n" >&2
exit 1
EOF
chmod 700 "$failing"

sqlite3 "$state_dir/responder.db" <<'SQL'
INSERT INTO slack_inputs (
  id, kind, channel_id, thread_ts, user_id, message_ts, text, state,
  failure_count, last_error, received_at, updated_at
) VALUES (
  'slack_six', 'mention', 'C0TENANTX01', '', 'U123', '2999.021',
  'unassessable turn', 'done', 0, '',
  '2999-01-01T00:00:21.000Z', '2999-01-01T00:00:23.000Z'
);
INSERT INTO agent_runs VALUES (
  'run_six', 'triage', 'completed', 'succeeded', 'C0TENANTX01', '',
  'watch', 'slack_six', 'tenant-platform', 'answered',
  '2999-01-01T00:00:21.000Z', '2999-01-01T00:00:22.000Z',
  '2999-01-01T00:00:23.000Z', '2999-01-01T00:00:23.000Z', '', 0
);
SQL

run_failing() {
  QUALITY_WATCH_TEST_CAPTURE="$capture" \
  QUALITY_WATCH_TEST_COUNT="$count_file" \
  QUALITY_WATCH_TEST_MODE=clean \
  RESPONDER_QUALITY_STATE_DIR="$state_dir" \
  RESPONDER_QUALITY_TEST_CHANNEL=C0TENANTX01 \
  RESPONDER_QUALITY_REPOSITORY="$repository" \
  RESPONDER_QUALITY_CODEX="$failing" \
  RESPONDER_QUALITY_CLAUDE="$failing" \
  RESPONDER_QUALITY_ASSESSOR_RETRIES="${1:-5}" \
    "$repository/scripts/quality-watch.sh" --once
}

before_cursor=$(<"$state_dir/quality-watch/cursor.tsv")
run_failing 5
if [[ $(<"$state_dir/quality-watch/cursor.tsv") != "$before_cursor" ]]; then
  printf 'quality-watch test: cursor advanced past a batch nothing assessed\n' >&2
  exit 1
fi
if grep -Fq 'no high-confidence product defect' <(tail -2 "$state_dir/quality-watch/quality-watch.log"); then
  printf 'quality-watch test: a failed assessment was reported as a clean review\n' >&2
  exit 1
fi
grep -Fq 'cursor held' "$state_dir/quality-watch/quality-watch.log" || {
  printf 'quality-watch test: the retry was not announced\n' >&2
  exit 1
}
grep -Fq "hit your usage limit" "$state_dir/quality-watch/quality-watch.log" || {
  printf 'quality-watch test: the provider reason never reached the loop log\n' >&2
  exit 1
}

# A batch that can never be assessed still has to stop blocking the queue, and
# must say plainly that it was skipped rather than reviewed.
run_failing 1
if [[ $(<"$state_dir/quality-watch/cursor.tsv") == "$before_cursor" ]]; then
  printf 'quality-watch test: an unassessable batch blocked the cursor forever\n' >&2
  exit 1
fi
grep -Fq 'SKIPPING these episodes UNASSESSED' "$state_dir/quality-watch/quality-watch.log" || {
  printf 'quality-watch test: the skip was not reported as a skip\n' >&2
  exit 1
}

# A fix is quarantined unless it changed something that proves the defect is
# fixed. The pattern that decides this once read "^eval/" while every corpus
# lives under testdata/eval/, so an evaluation case proved nothing and a real
# fix was discarded. Driving the whole fixer path here would need a live gate
# run, so the predicate itself is exercised against the paths it must classify.
proof_pattern=$(
  sed -n "s/^regression_proof_paths='\(.*\)'$/\1/p" "$repository/scripts/quality-watch.sh"
)
if [[ -z $proof_pattern ]]; then
  printf 'quality-watch test: regression_proof_paths is no longer a single quoted assignment\n' >&2
  exit 1
fi
for proof in \
  internal/service/agent_run_test.go \
  scripts/test-quality-watch.sh \
  testdata/eval/regressions.jsonl \
  testdata/eval/episode-replay/tenant.jsonl; do
  grep -Eq "$proof_pattern" <<<"$proof" || {
    printf 'quality-watch test: %s does not count as a regression test\n' "$proof" >&2
    exit 1
  }
done
for bare in internal/service/agent_run.go docs/testing.md; do
  if grep -Eq "$proof_pattern" <<<"$bare"; then
    printf 'quality-watch test: %s counted as a regression test\n' "$bare" >&2
    exit 1
  fi
done

printf 'quality-watch test: ok\n'
