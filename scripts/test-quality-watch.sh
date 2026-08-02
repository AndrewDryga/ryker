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

if [[ ${QUALITY_WATCH_TEST_MODE:-clean} == challenge && $count -eq 1 ]]; then
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
  result_json TEXT
);
CREATE TABLE slack_inputs (
  id TEXT PRIMARY KEY,
  kind TEXT,
  user_id TEXT,
  message_ts TEXT,
  text TEXT
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

run_watch clean --from-now --once
sqlite3 "$state_dir/responder.db" <<'SQL'
INSERT INTO slack_inputs VALUES (
  'slack_one', 'mention', 'U123', '2999.001', 'check production health'
);
INSERT INTO agent_runs VALUES (
  'run_one', 'triage', 'completed', 'completed', 'C0TENANTX01', '',
  'watch', 'slack_one', 'emisar', '',
  '2999-01-01T00:00:00.000Z', '2999-01-01T00:00:01.000Z',
  '2999-01-01T00:00:02.000Z', '2999-01-01T00:00:02.000Z', '{"action":"reply"}'
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
INSERT INTO slack_inputs VALUES (
  'slack_two', 'mention', 'U123', '2999.003', 'check the deployment'
);
INSERT INTO agent_runs VALUES (
  'run_two', 'triage', 'completed', 'completed', 'C0TENANTX01', '',
  'watch', 'slack_two', 'emisar', '',
  '2999-01-01T00:00:03.000Z', '2999-01-01T00:00:04.000Z',
  '2999-01-01T00:00:05.000Z', '2999-01-01T00:00:05.000Z', '{"action":"reply"}'
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

printf 'quality-watch test: ok\n'
