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
	failure_count INTEGER,
	incident_id TEXT,
	idempotency_key TEXT
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
	coverage_count INTEGER,
	agent_run_id TEXT,
	agent_run_key TEXT
);
CREATE TABLE slack_deliveries (
  id TEXT PRIMARY KEY,
  state TEXT,
  operation TEXT,
  kind TEXT,
  message_ts TEXT,
  last_error TEXT,
	body_json TEXT
	,incident_id TEXT
	,card_version INTEGER
	,agent_run_id TEXT
	,source_input_id TEXT
	,response_root INTEGER
	,agent_run_key TEXT
);
SQL

# quality_findings is created from Responder's own migration text, not retyped.
#
# The other tables here are hand-written stand-ins the watcher only reads, so a
# drift between them and production costs a wrong-looking test. This one the
# watcher writes, and a column list that disagrees with the shipped schema would
# make the insert fail in production while passing here — which is precisely the
# class of "the check ran and reported nothing" failure this whole file exists
# to prevent. Extracting the real DDL means the test inserts into the real
# shape.
# Found by content rather than by migration number, because the number is
# whichever one was free when this landed and renumbering is a rebase away.
findings_schema=$(grep -l 'CREATE TABLE quality_findings' \
  "$repository"/internal/store/schema_v*.go | head -1)
awk '/^const schemaV[0-9]+ = `$/{copy=1; next} copy&&/^`$/{exit} copy' \
  "$findings_schema" >"$temporary/findings.sql" 2>/dev/null
if ! grep -q 'CREATE TABLE quality_findings' "$temporary/findings.sql"; then
  printf 'quality-watch test: no migration creates quality_findings, so the watcher has nowhere to record\n' >&2
  exit 1
fi
sqlite3 "$state_dir/responder.db" <"$temporary/findings.sql"

findings() { sqlite3 "$state_dir/responder.db" "$1"; }

run_watch() {
  QUALITY_WATCH_TEST_CAPTURE="$capture" \
  QUALITY_WATCH_TEST_COUNT="$count_file" \
  QUALITY_WATCH_TEST_MODE="${1:-clean}" \
  RESPONDER_QUALITY_STATE_DIR="$state_dir" \
  RESPONDER_QUALITY_TEST_CHANNEL=C0TENANTX01 \
  RESPONDER_QUALITY_REPOSITORY="$repository" \
  RESPONDER_QUALITY_CODEX="$fake_codex" \
  RESPONDER_QUALITY_FIX="${FIX_MODE:-off}" \
  RESPONDER_QUALITY_RETENTION_DAYS="${RETENTION_DAYS:-30}" \
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
	'2999-01-01T00:00:02.000Z', '2999-01-01T00:00:02.000Z', '{"action":"reply"}', 0, '', 'run:key:one'
);
INSERT INTO slack_deliveries VALUES (
	'watch_reply_slack_one', 'sent', 'post', 'notice', '2999.002', '',
	'{"text":"Production is healthy within the checked scope."}', '', 0,
	'run_one', 'slack_one', 1, 'run:key:one'
);
INSERT INTO evaluation_decisions VALUES (
	'slack_one', 'live', 'reply', 'fresh evidence supports the answer', 2, 3,
	'run_one', 'run:key:one'
);
SQL
run_watch clean --once
grep -Fq 'Production is healthy within the checked scope.' "$capture"
grep -Fq '"reply_delivery_state": "sent"' "$capture"
grep -Fq '"recorded_action": "reply"' "$capture"
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
	'run_two', 'engineering_task', 'completed', 'completed', 'C0TENANTX01', '',
	'watch', 'slack_two', 'emisar', '',
	'2999-01-01T00:00:03.000Z', '2999-01-01T00:00:04.000Z',
	'2999-01-01T00:00:05.000Z', '2999-01-01T00:00:05.000Z', '{"action":"reply"}', 0, 'inc_task', 'run:key:two'
);
INSERT INTO slack_deliveries VALUES (
	'delivery_card_inc_task_1', 'sent', 'update', 'card', '2999.004', '',
	'{"text":"The deployment is healthy.","actions":[{"id":"stale_control","label":"Create draft PR"}]}',
	'inc_task', 1, 'run_two', 'slack_two', 0, 'run:key:two'
);
INSERT INTO slack_deliveries VALUES (
	'delivery_card_inc_task_2', 'sent', 'update', 'card', '2999.0045', '',
	'{"text":"Wrong card from a newer task turn."}',
	'inc_task', 2, 'run_future', 'slack_future', 0, 'run:key:future'
);
SQL
run_watch challenge --once
grep -Fq 'The deployment is healthy.' "$capture"
if grep -Fq 'Wrong card from a newer task turn.' "$capture"; then
  printf 'quality-watch test: older engineering run was paired with the latest incident card\n' >&2
  exit 1
fi
grep -Fq 'Create draft PR' "$capture"
grep -Fq 'adversarial review rejected the proposed defect' \
  "$state_dir/quality-watch/quality-watch.log"
if find "$state_dir/quality-watch/worktrees" -mindepth 1 -print -quit | grep -q .; then
  printf 'quality-watch test: adversarial rejection created a worktree\n' >&2
  exit 1
fi
# A rejected finding is still a finding. The challenger overturned 23 of the
# first 83 proposals, and dropping those on the floor hides the only evidence
# that the second reader is doing anything.
if [[ $(findings "SELECT COUNT(*) FROM quality_findings WHERE verdict = 'rejected'") != 1 ]]; then
  printf 'quality-watch test: the challenger overturned a defect and nothing recorded it\n' >&2
  exit 1
fi

# Requeue keeps the durable run ID but rotates its execution key. An answer
# from the failed execution must not make the retried execution look answered.
rm -f "$count_file"
sqlite3 "$state_dir/responder.db" <<'SQL'
INSERT INTO slack_inputs (
  id, kind, channel_id, thread_ts, user_id, message_ts, text, state,
  failure_count, last_error, received_at, updated_at
) VALUES (
  'slack_requeued', 'mention', 'C0TENANTX01', '', 'U123', '2999.0055',
  'retry the failed check', 'done', 0, '',
  '2999-01-01T00:00:05.500Z', '2999-01-01T00:00:05.800Z'
);
INSERT INTO agent_runs VALUES (
  'run_requeued', 'triage', 'failed', 'failed', 'C0TENANTX01', '',
  'watch', 'slack_requeued', 'emisar', 'retry finalization failed',
  '2999-01-01T00:00:05.500Z', '2999-01-01T00:00:05.600Z',
  '2999-01-01T00:00:05.800Z', '2999-01-01T00:00:05.800Z', '', 2, '', 'run:key:new:recovery_2'
);
INSERT INTO slack_deliveries VALUES (
  'watch_reply_slack_requeued', 'sent', 'post', 'notice', '2999.0057', '',
  '{"text":"Answer from the earlier failed execution."}', '', 0,
  '', 'slack_requeued', 1, ''
);
INSERT INTO evaluation_decisions VALUES (
  'slack_requeued', 'live', 'reply', 'decision from the earlier execution', 1, 1,
  '', ''
);
SQL
run_watch clean --once
if grep -Fq 'Answer from the earlier failed execution.' "$capture"; then
  printf 'quality-watch test: retried run inherited its prior execution reply\n' >&2
  exit 1
fi
grep -Fq '"reply_delivery_state": null' "$capture"
grep -Fq '"recorded_action": null' "$capture"

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
	'{"text":"Responder could not complete that request after retrying.","reason":"empty Slack message"}', '', 0,
	'', 'slack_three', 1, ''
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
	'2999-01-01T00:00:10.000Z', '2999-01-01T00:00:10.000Z', '', 20, '', 'run:key:four'
);
INSERT INTO slack_deliveries VALUES (
	'watch_failure_slack_four', 'sent', 'post', 'notice', '2999.009', '',
	'{"text":"Responder could not complete this check.","reason":"ACP transcript exceeded its bound"}', '', 0,
	'run_four', 'slack_four', 1, 'run:key:four'
);
SQL
run_watch clean --once
grep -Fq 'Responder could not complete this check.' "$capture"
grep -Fq '"reply_delivery_state": "sent"' "$capture"
grep -Fq '"failure_count": 20' "$capture"

# The default path, and the whole point of the change: a defect that survives
# both readings is recorded and handed to a person, and no fixer runs.
#
# Two models answer the batch — assessor and challenger — and nothing else. The
# third call is the fixer, so the call count is what proves the expensive half
# did not run; an absent worktree alone would also be true if the fixer had run
# and made no change.
rm -f "$count_file"
sqlite3 "$state_dir/responder.db" <<'SQL'
INSERT INTO slack_inputs (
  id, kind, channel_id, thread_ts, user_id, message_ts, text, state,
  failure_count, last_error, received_at, updated_at
) VALUES (
  'slack_recorded', 'mention', 'C0TENANTX01', '', 'U123', '2999.0105',
  'check the unrecorded failure', 'done', 0, '',
  '2999-01-01T00:00:10.400Z', '2999-01-01T00:00:10.500Z'
);
INSERT INTO agent_runs VALUES (
  'run_recorded', 'triage', 'completed', 'failed', 'C0TENANTX01', '',
  'watch', 'slack_recorded', 'tenant-platform', 'reproducible failure',
  '2999-01-01T00:00:10.400Z', '2999-01-01T00:00:10.450Z',
	'2999-01-01T00:00:10.500Z', '2999-01-01T00:00:10.500Z', '', 1, '', 'run:key:recorded'
);
SQL
run_watch confirmed --once
if [[ $(<"$count_file") != 2 ]]; then
  printf 'quality-watch test: the fixer ran with RESPONDER_QUALITY_FIX=off\n' >&2
  exit 1
fi
if find "$state_dir/quality-watch/worktrees" -mindepth 1 -print -quit | grep -q .; then
  printf 'quality-watch test: the default path created a worktree\n' >&2
  exit 1
fi
grep -Fq 'no fix attempted (RESPONDER_QUALITY_FIX=off)' \
  "$state_dir/quality-watch/quality-watch.log" || {
  printf 'quality-watch test: the loop did not say the fixer was off\n' >&2
  exit 1
}
recorded=$(findings "SELECT verdict || '|' || disposition || '|' || run_id ||
  '|' || channel_id || '|' || severity || '|' || summary || '|' ||
  json_array_length(code_evidence)
  FROM quality_findings WHERE run_id = 'run_recorded'")
if [[ "$recorded" != 'confirmed|recorded|run_recorded|C0TENANTX01|high|proposed defect|1' ]]; then
  printf 'quality-watch test: the confirmed finding did not reach the table intact: %s\n' \
    "$recorded" >&2
  exit 1
fi
# The row has to point back at the episode it came from, or the page shows a
# defect nobody can trace to a turn.
if [[ $(findings "SELECT json_extract(episode_ids, '\$[0]')
  FROM quality_findings WHERE run_id = 'run_recorded'") != run_recorded ]]; then
  printf 'quality-watch test: the finding lost the episode it came from\n' >&2
  exit 1
fi

# Opt in, and the fixer path still works exactly as it did.
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
	'2999-01-01T00:00:13.000Z', '2999-01-01T00:00:13.000Z', '', 1, '', 'run:key:five'
);
SQL
FIX_MODE=on run_watch confirmed --once
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
# What the fixer did with the finding is written back onto it, or the page shows
# a defect as merely "recorded" while a worktree for it sits in quarantine.
if [[ $(findings "SELECT disposition FROM quality_findings
  WHERE run_id = 'run_five'") != declined ]]; then
  printf 'quality-watch test: the fix attempt did not report back to its finding\n' >&2
  exit 1
fi

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
	'2999-01-01T00:00:23.000Z', '2999-01-01T00:00:23.000Z', '', 0, '', 'run:key:six'
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

# Retention runs on every pass and names what it destroyed.
#
# It used to run only before the watch loop, and the watch loop never exits, so
# on a KeepAlive launch agent the horizon applied eight times in eight days —
# which is to say it did not apply. 366 MB of quarantined worktrees, 71 MB of
# reviews and a 5.6 GB build cache accumulated under a policy that read as if it
# were working. Everything here is aged past a one-day horizon and must come
# back named, because a deletion nobody is told about is indistinguishable from
# a loss.
old=$(date -u -v-3d '+%Y%m%d%H%M' 2>/dev/null || date -u -d '3 days ago' '+%Y%m%d%H%M')
touch -t "$old" "$state_dir/quality-watch/reviews/"*.episodes.json
mkdir -p "$state_dir/quality-watch/worktrees/expired-fix"
printf '%s\n%s\n%s\n' \
  "$state_dir/quality-watch/worktrees/expired-fix" 'quality-watch/expired' \
  'full gate failed for expired-fix' \
  >"$state_dir/quality-watch/quarantine/expired-fix.meta"
touch -t "$old" "$state_dir/quality-watch/quarantine/expired-fix.meta"
mkdir -p "$state_dir/quality-watch/go-cache/aa"
touch -t "$old" "$state_dir/quality-watch/go-cache/aa/cached"
sqlite3 "$state_dir/responder.db" \
  "UPDATE quality_findings SET created_at = '2000-01-01T00:00:00.000000000Z';"

RETENTION_DAYS=1 run_watch clean --once
watch_log="$state_dir/quality-watch/quality-watch.log"
for expected in \
  'review artifact(s) older than 1 days' \
  'expired quarantined quality-fix worktree' \
  'held because: full gate failed for expired-fix' \
  "dropped the fixer's Go build cache" \
  'recorded finding(s) older than 1 days'; do
  grep -Fq "$expected" "$watch_log" || {
    printf 'quality-watch test: retention did not report %s\n' "$expected" >&2
    exit 1
  }
done
if [[ -f "$state_dir/quality-watch/quarantine/expired-fix.meta" ]]; then
  printf 'quality-watch test: an expired quarantine marker survived its horizon\n' >&2
  exit 1
fi
if [[ -d "$state_dir/quality-watch/go-cache" ]]; then
  printf 'quality-watch test: the stale build cache survived its horizon\n' >&2
  exit 1
fi
# Expiring it has to actually remove the tree. A directory that outlives its
# marker is re-adopted as an orphan on the next start and given a fresh
# horizon — an expiry that renews what it was supposed to end.
if [[ -d "$state_dir/quality-watch/worktrees/expired-fix" ]]; then
  printf 'quality-watch test: an expired worktree was unmarked but left on disk\n' >&2
  exit 1
fi
if [[ $(findings 'SELECT COUNT(*) FROM quality_findings') != 0 ]]; then
  printf 'quality-watch test: expired findings were kept\n' >&2
  exit 1
fi
# And a finding inside the window is not touched by the same sweep.
sqlite3 "$state_dir/responder.db" "
INSERT INTO quality_findings (id, verdict, created_at)
VALUES ('fresh', 'confirmed', strftime('%Y-%m-%dT%H:%M:%f','now') || '000000Z');"
RETENTION_DAYS=1 run_watch clean --once
if [[ $(findings 'SELECT COUNT(*) FROM quality_findings') != 1 ]]; then
  printf 'quality-watch test: retention took a finding that was still inside its horizon\n' >&2
  exit 1
fi

printf 'quality-watch test: ok\n'
