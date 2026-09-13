#!/bin/bash
# Proves the watchdog fires, stays quiet, and recovers.
#
# A watchdog is the one piece of software whose failure mode is silence, and
# silence is also what it looks like when everything is fine. The only way to
# know it works is to break something on purpose and watch it complain.
#
# The stalled case reproduces 2026-08-13 exactly: runs sitting in pending, due
# now, created twelve minutes ago, against a deployment whose HTTP endpoint
# still answers.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export WATCHDOG_AGENTS="$work/agents"
export WATCHDOG_STATE="$work/state"
export WATCHDOG_NO_NOTIFY=1
export WATCHDOG_STRIKES=2
export WATCHDOG_RENOTIFY_MINUTES=0
mkdir -p "$WATCHDOG_AGENTS" "$work/deploy/.ryker/state"

failures=0
check() {
  local what="$1" expected="$2" actual="$3"
  if [[ $actual == *"$expected"* ]]; then
    printf 'ok   %s\n' "$what"
  else
    printf 'FAIL %s\n     wanted: %s\n     got:    %s\n' "$what" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

# refute is for the assertions that matter most here: a watchdog's worst bug is
# a line it should not have written.
refute() {
  local what="$1" unwanted="$2" actual="$3"
  if [[ $actual == *"$unwanted"* ]]; then
    printf 'FAIL %s\n     unwanted: %s\n     got:      %s\n' "$what" "$unwanted" "$actual"
    failures=$((failures + 1))
  else
    printf 'ok   %s\n' "$what"
  fi
}

count_check() {
  local what="$1" want="$2" needle="$3" actual="$4" got
  got=$(printf '%s\n' "$actual" | grep -Fc -- "$needle") || true
  if [[ $got -eq $want ]]; then
    printf 'ok   %s\n' "$what"
  else
    printf 'FAIL %s\n     wanted %s of: %s\n     got %s\n' "$what" "$want" "$needle" "$got"
    failures=$((failures + 1))
  fi
}

/usr/bin/plutil -create xml1 "$WATCHDOG_AGENTS/ai.emisar.ryker.probe.plist"
/usr/bin/plutil -insert StandardErrorPath -string \
  "$work/deploy/.ryker/state/ryker.stderr.log" \
  "$WATCHDOG_AGENTS/ai.emisar.ryker.probe.plist"
printf 'listen: 127.0.0.1:59999\n' > "$work/deploy/.ryker/ryker.yaml"

db="$work/deploy/.ryker/state/responder.db"
# seed <state> <created-minutes-ago> [failure_count] [next-attempt modifier].
# The columns are the real ones — failure_count, started_at, completed_at —
# because the watchdog now reads all three and a fabricated table that is
# missing one reads as "database unreadable" rather than as the case under
# test.
seed() {
  rm -f "$db"
  /usr/bin/sqlite3 "$db" "
    CREATE TABLE agent_runs (id TEXT, state TEXT, failure_count INTEGER NOT NULL DEFAULT 0,
      created_at TEXT, next_attempt_at TEXT, started_at TEXT, completed_at TEXT,
      last_error TEXT NOT NULL DEFAULT '');
    INSERT INTO agent_runs (id, state, failure_count, created_at, next_attempt_at)
    VALUES
      ('run_stalled', '$1', ${3:-0}, strftime('%Y-%m-%dT%H:%M:%f', 'now', '-$2 minutes'),
       strftime('%Y-%m-%dT%H:%M:%f', 'now', '${4:--1 minutes}'));"
}

# backoff pushes the seeded run into a retry backoff of the given length, which
# is the single move that made the watchdog report recovery during the outage.
backoff() {
  /usr/bin/sqlite3 "$db" "
    UPDATE agent_runs
    SET next_attempt_at = strftime('%Y-%m-%dT%H:%M:%f', 'now', '+$1 seconds'),
        failure_count = failure_count + 1;"
}

# attempted marks the seeded run as one that has already reached running once
# and come back to pending: the shape a deferral leaves behind.
attempted() {
  /usr/bin/sqlite3 "$db" "UPDATE agent_runs SET started_at = created_at;"
}

# rate_limited stamps the seeded run with the provider-throttle error the real
# retry path records, so the classifier has the same evidence production gives it.
rate_limited() {
  /usr/bin/sqlite3 "$db" "UPDATE agent_runs SET last_error = 'provider rate limited the turn';"
}

# due_again brings the run back out of backoff at the age the log recorded, so
# the replay walks the same minute counts the outage did.
due_again() {
  /usr/bin/sqlite3 "$db" "
    UPDATE agent_runs
    SET next_attempt_at = strftime('%Y-%m-%dT%H:%M:%f', 'now', '-1 minutes'),
        created_at = strftime('%Y-%m-%dT%H:%M:%f', 'now', '-$1 minutes');"
}

run() { bash "$root/scripts/watchdog.sh" >/dev/null 2>&1; cat "$WATCHDOG_STATE/watchdog.log" 2>/dev/null; }

# A queue that is moving says nothing, however loudly the endpoint is missing —
# because a drained queue on an unreachable port is still checked, so this also
# proves the two signals are independent.
seed running 30
bash "$root/scripts/watchdog.sh" >/dev/null 2>&1
check "running work does not count as stalled" "not ready" "$(cat "$WATCHDOG_STATE/watchdog.log")"

# Twelve minutes of due, unmoved work: the outage.
rm -rf "$WATCHDOG_STATE"; seed pending 12
first=$(run)
check "first bad check is a strike, not an alarm" "strike 1/2" "$first"
if [[ $first == *ALERT* ]]; then
  printf 'FAIL alarmed on the first bad check\n'; failures=$((failures + 1))
else
  printf 'ok   silent on the first bad check\n'
fi

second=$(run)
check "a persistent stall raises the alarm" "ALERT Ryker probe is not working" "$second"
check "the alarm says what is wrong" "waited 12m and nothing has ever run" "$second"

# Provider weather is named, not disguised as a host stall. On 2026-08-15 the
# alarm said "178m without moving" for three hours of rate limiting — true,
# useless, and indistinguishable from the wedges fixed the same evening.
rm -rf "$WATCHDOG_STATE"; seed pending 12 3
rate_limited
run >/dev/null
weather=$(run)
check "a rate-limited stall names the weather" "waiting on provider rate limits" "$weather"
check "the weather alarm blames the quota, not the host" "the host is healthy, the quota is not" "$weather"
refute "the weather alarm does not read as an unexplained stall" "without moving" "$weather"

# Recovery: the queue drains. The endpoint is still unreachable, so this also
# proves an unreachable deployment is reported rather than passed over.
seed running 30
recovered=$(run)
check "an unreachable endpoint is still reported" "not ready: unreachable" "$recovered"

# With the port answering and the queue drained, it goes quiet and forgets.
rm -rf "$WATCHDOG_STATE"; seed running 30
printf 'listen: 127.0.0.1:0\n' > "$work/deploy/.ryker/ryker.yaml"
/usr/bin/python3 -c "
import http.server, threading, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(b'{\"ready\":true,\"reason\":\"ready\"}')
    def log_message(self, *a): pass
s = http.server.HTTPServer(('127.0.0.1', 0), H)
open('$work/port', 'w').write(str(s.server_address[1]))
threading.Thread(target=s.serve_forever, daemon=True).start()
import time; time.sleep(12)
" &
server=$!
sleep 1
printf 'listen: 127.0.0.1:%s\n' "$(cat "$work/port")" > "$work/deploy/.ryker/ryker.yaml"
healthy=$(run)
kill $server 2>/dev/null; wait $server 2>/dev/null
if [[ -z $healthy ]]; then
  printf 'ok   a healthy deployment is entirely silent\n'
else
  printf 'FAIL a healthy deployment logged: %s\n' "$healthy"; failures=$((failures + 1))
fi

# The alarm also lands as a Slack DM to the deployment's operator, with the
# deployment's own bot token — the toast alone let an 11-hour stall pass
# unseen. Proven by watching the request arrive, not by trusting that it
# would: the API base is pointed at a local server that records what it is
# sent.
rm -rf "$WATCHDOG_STATE"; seed pending 12
printf 'listen: 127.0.0.1:59999\nslack:\n  operators:\n    - UWATCHOP1\n' \
  > "$work/deploy/.ryker/ryker.yaml"
printf 'SLACK_BOT_TOKEN=xoxb-watchdog-test-token\n' > "$work/deploy/.ryker/local.env"
/usr/bin/python3 -c "
import http.server, threading, time
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        with open('$work/slack-posts', 'ab') as f:
            f.write(self.path.encode() + b' ' + self.headers.get('Authorization','').encode() + b' ' + body + b'\n')
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(b'{\"ok\":true}')
    def log_message(self, *a): pass
s = http.server.HTTPServer(('127.0.0.1', 0), H)
open('$work/slack-port', 'w').write(str(s.server_address[1]))
threading.Thread(target=s.serve_forever, daemon=True).start()
time.sleep(12)
" &
slack_server=$!
sleep 1
slack_port=$(cat "$work/slack-port")
export WATCHDOG_SLACK_API="http://127.0.0.1:$slack_port"
run >/dev/null
run >/dev/null
kill $slack_server 2>/dev/null; wait $slack_server 2>/dev/null
unset WATCHDOG_SLACK_API
posts=$(cat "$work/slack-posts" 2>/dev/null)
check "the alarm reaches Slack as a DM to the operator" "\"channel\":\"UWATCHOP1\"" "$posts"
check "the DM says what is wrong" "is not working" "$posts"
check "the DM authenticates with the deployment's token" "Bearer xoxb-watchdog-test-token" "$posts"

# A deployment without Slack credentials keeps the toast and says why, rather
# than failing the check.
rm -rf "$WATCHDOG_STATE"; rm -f "$work/deploy/.ryker/local.env"; seed pending 12
run >/dev/null
nodm=$(run)
check "a deployment without credentials skips the DM and says so" "slack DM skipped" "$nodm"

# ---------------------------------------------------------------------------
# The 2026-08-13 flap: a retry backoff is the stall, not recovery from it.
#
# During the buildkit-corruption outage every failing run was pushed into a
# 30s-128s retry backoff, and the stall query counted only runs due right now.
# So each time the backoff swallowed the queue the watchdog logged "recovered —
# Queue is moving again" and cleared the strike count. The real log shows a
# 71-minute stall alerting at 21:00:34Z, "recovered" at 21:01:43Z, and the SAME
# stall back at strike 1/3 with 73m at 21:03:01Z — cycling for two hours
# (71m → 76m → 105m → 118m) while nothing moved. Both halves cost the operator:
# the log lied about the deployment, and every false recovery re-armed the
# three-strike delay so the alarm had to climb back from nothing.
#
# These run against a deployment whose /readyz answers ready, because that is
# exactly what the outage looked like — Coop's control API kept answering while
# no turn could run — which leaves the queue as the only signal in play.
cat > "$work/ready-server.py" <<'PY'
import http.server, sys
port_file = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{"ready":true,"reason":"ready"}')
    def log_message(self, *a): pass
s = http.server.HTTPServer(('127.0.0.1', 0), H)
with open(port_file, 'w') as f:
    f.write(str(s.server_address[1]))
s.serve_forever()
PY
/usr/bin/python3 "$work/ready-server.py" "$work/ready-port" &
ready_server=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -s $work/ready-port ]] && break
  sleep 0.3
done
printf 'listen: 127.0.0.1:%s\n' "$(cat "$work/ready-port")" > "$work/deploy/.ryker/ryker.yaml"

# Unrelated work is activity, not recovery of the stalled cohort. The live
# false positives came from a daily review and Rivals messages moving while the
# original provider-limited run remained pending.
rm -rf "$WATCHDOG_STATE"; seed pending 12 3; attempted; rate_limited
run >/dev/null; run >/dev/null
/usr/bin/sqlite3 "$db" "
  INSERT INTO agent_runs (id, state, failure_count, created_at, next_attempt_at, started_at, completed_at)
  VALUES ('run_unrelated', 'completed', 0,
    strftime('%Y-%m-%dT%H:%M:%f', 'now', '-2 minutes'), '',
    strftime('%Y-%m-%dT%H:%M:%f', 'now', '-2 minutes'),
    strftime('%Y-%m-%dT%H:%M:%f', 'now'));"
partial=$(run)
check "unrelated activity names the provider-limited work still blocked" \
  "Activity resumed, but 1 provider-limited run remains blocked" "$partial"
refute "unrelated activity is not recovery of the stalled cohort" \
  "ALERT Ryker probe recovered" "$partial"

/usr/bin/sqlite3 "$db" "
  UPDATE agent_runs SET state = 'completed', next_attempt_at = '',
    completed_at = strftime('%Y-%m-%dT%H:%M:%f', 'now')
  WHERE id = 'run_stalled';"
cohort_recovered=$(run)
check "the watchdog recovers when the stalled cohort moves" \
  "ALERT Ryker probe recovered" "$cohort_recovered"

# Failing work waiting out its backoff is the stall, not an exemption from it.
rm -rf "$WATCHDOG_STATE"; seed pending 12 3 '+45 seconds'
run >/dev/null
backing_off=$(run)
check "a failing run waiting out its backoff is stalled, not healthy" \
  "waited 12m and nothing has ever run" "$backing_off"

# The provider rate-limiting a turn defers it back to pending with a later
# next_attempt_at and spends no attempt, so failure_count stays 0 — a stall
# query that asked only about failures would still have called this healthy.
# Harvested from blitz on 2026-08-15, where a run had sat 139 minutes in
# exactly this shape while the queue behind it went nowhere.
rm -rf "$WATCHDOG_STATE"; seed pending 12 0 '+45 seconds'; attempted
run >/dev/null
deferred=$(run)
check "a deferred run that spent no attempt is stalled too" \
  "no run has started or finished in 12m" "$deferred"

# A queue that is visibly working is not stalled, however old its slowest
# member. At 2026-08-15T03:19Z the alarm said "queued 208m without moving"
# eight minutes after a three-hour-starved run completed and three minutes
# after a fresh run started: the 208m was the oldest run's age, and movement
# was only ever consulted for recovery, never for firing.
rm -rf "$WATCHDOG_STATE"; seed pending 20 4
/usr/bin/sqlite3 "$db" "
  INSERT INTO agent_runs (id, state, failure_count, created_at, next_attempt_at, started_at, completed_at)
  VALUES ('run_flowing', 'completed', 0,
    strftime('%Y-%m-%dT%H:%M:%f', 'now', '-9 minutes'), '',
    strftime('%Y-%m-%dT%H:%M:%f', 'now', '-8 minutes'),
    strftime('%Y-%m-%dT%H:%M:%f', 'now', '-2 minutes'));"
run >/dev/null
flowing=$(run)
refute "an old run behind a moving queue is not an outage" "ALERT Ryker probe is not working" "$flowing"
check "the waiting work is still logged, gated on movement" "but runs are moving" "$flowing"

# A first attempt genuinely scheduled for the future is not a stall. Without
# this the fix above would alarm on every debounced turn ever queued.
rm -rf "$WATCHDOG_STATE"; seed pending 12 0 '+45 seconds'
run >/dev/null
not_yet_due=$(run)
if [[ -z $not_yet_due ]]; then
  printf 'ok   a first attempt scheduled for the future is not a stall\n'
else
  printf 'FAIL a first attempt scheduled for the future was reported: %s\n' "$not_yet_due"
  failures=$((failures + 1))
fi

# Recovery means something moved, not that the queue momentarily read empty.
# The rows vanish here without any run starting or finishing, which is the one
# shape the stall query alone cannot tell apart from a queue that drained.
rm -rf "$WATCHDOG_STATE"; seed pending 12 1
run >/dev/null
alarmed=$(run)
check "a due stall still alarms" "ALERT Ryker probe is not working" "$alarmed"
/usr/bin/sqlite3 "$db" "DELETE FROM agent_runs;"
dipped=$(run)
refute "a due count that dips to zero without movement is not recovery" \
  "ALERT Ryker probe recovered" "$dipped"
held=$(cat "$WATCHDOG_STATE/probe.strikes" 2>/dev/null || echo 0)
if [[ $held -ge 2 ]]; then
  printf 'ok   an unmoved queue keeps its strikes instead of re-climbing\n'
else
  printf 'FAIL strikes were reset to %s without movement\n' "$held"
  failures=$((failures + 1))
fi

# And when a run really does finish, recovery is announced.
/usr/bin/sqlite3 "$db" "
  INSERT INTO agent_runs (id, state, failure_count, created_at, next_attempt_at, started_at, completed_at)
  VALUES ('run_stalled', 'completed', 1, strftime('%Y-%m-%dT%H:%M:%f', 'now', '-12 minutes'), '',
          strftime('%Y-%m-%dT%H:%M:%f', 'now', '-2 minutes'), strftime('%Y-%m-%dT%H:%M:%f', 'now'));"
moved=$(run)
check "recovery is logged once a run has actually moved" \
  "ALERT Ryker probe recovered" "$moved"

# A hold must not outlive the thing it watched. When the queue has read clear
# for a whole stall window with nothing left to move — rows pruned, work
# cancelled out from under it — the watchdog forgets the stall instead of
# holding a strike and logging a line every minute forever, and it does not
# dress that up as recovery either. The clock is fabricated because the
# alternative is a ten-minute test.
rm -rf "$WATCHDOG_STATE"; seed pending 12 1
run >/dev/null; run >/dev/null
/usr/bin/sqlite3 "$db" "DELETE FROM agent_runs;"
printf '%s %s\n' "$(($(date +%s) - 700))" "" > "$WATCHDOG_STATE/probe.stalled-at"
expired=$(run)
check "a hold that outlasts the stall window is dropped" \
  "clearing strikes without calling it recovery" "$expired"
refute "and dropping a hold is never announced as recovery" \
  "ALERT Ryker probe recovered" "$expired"
if [[ ! -f $WATCHDOG_STATE/probe.strikes ]]; then
  printf 'ok   a dropped hold releases its strikes\n'
else
  printf 'FAIL a dropped hold kept its strikes\n'
  failures=$((failures + 1))
fi

# The outage timeline itself, walked backoff phase by backoff phase at the ages
# the log recorded: one alarm, and not one word of recovery until work moves.
rm -rf "$WATCHDOG_STATE"
export WATCHDOG_RENOTIFY_MINUTES=30
seed pending 71 4                              # 21:00:34Z — 71m of failing work, due now
run >/dev/null; run >/dev/null                 # the alarm
backoff 30;    run >/dev/null                  # 21:01:43Z — "recovered" in the real log
due_again 73;  run >/dev/null; run >/dev/null  # 21:03:01Z — strike 1/3 again, then alarm again
backoff 64;    run >/dev/null
due_again 76;  run >/dev/null; run >/dev/null
backoff 128;   run >/dev/null
due_again 105; run >/dev/null; run >/dev/null
backoff 128
replay=$(run)
count_check "two hours of backoff flapping raises exactly one alarm" 1 \
  "ALERT Ryker probe is not working" "$replay"
count_check "and never once claims recovery while nothing moves" 0 \
  "ALERT Ryker probe recovered" "$replay"
/usr/bin/sqlite3 "$db" "
  UPDATE agent_runs SET state = 'completed', next_attempt_at = '',
    completed_at = strftime('%Y-%m-%dT%H:%M:%f', 'now');"
resumed=$(run)
count_check "recovery is announced when the queue moves again, once" 1 \
  "ALERT Ryker probe recovered" "$resumed"
export WATCHDOG_RENOTIFY_MINUTES=0
kill $ready_server 2>/dev/null; wait $ready_server 2>/dev/null

# Nothing to watch is itself a failure: a watchdog pointed at an empty
# directory reports success forever, which is the most dangerous state it has.
rm -rf "$WATCHDOG_STATE" "$WATCHDOG_AGENTS"; mkdir -p "$WATCHDOG_AGENTS"
bash "$root/scripts/watchdog.sh" >/dev/null 2>&1
status=$?
check "watching nothing is reported" "found nothing to watch" "$(cat "$WATCHDOG_STATE/watchdog.log" 2>/dev/null)"
if [[ $status -ne 0 ]]; then
  printf 'ok   watching nothing exits non-zero\n'
else
  printf 'FAIL watching nothing exited 0\n'; failures=$((failures + 1))
fi

printf '\n%s\n' "$([[ $failures -eq 0 ]] && echo 'watchdog: all checks passed' || echo "watchdog: $failures check(s) failed")"
exit $((failures > 0))
