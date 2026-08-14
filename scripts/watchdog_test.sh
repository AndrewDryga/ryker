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
mkdir -p "$WATCHDOG_AGENTS" "$work/deploy/.responder/state"

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

/usr/bin/plutil -create xml1 "$WATCHDOG_AGENTS/ai.emisar.responder.probe.plist"
/usr/bin/plutil -insert StandardErrorPath -string \
  "$work/deploy/.responder/state/responder.stderr.log" \
  "$WATCHDOG_AGENTS/ai.emisar.responder.probe.plist"
printf 'listen: 127.0.0.1:59999\n' > "$work/deploy/.responder/responder.yaml"

db="$work/deploy/.responder/state/responder.db"
seed() {
  rm -f "$db"
  /usr/bin/sqlite3 "$db" "
    CREATE TABLE agent_runs (id TEXT, state TEXT, created_at TEXT, next_attempt_at TEXT);
    INSERT INTO agent_runs VALUES
      ('run_stalled', '$1', strftime('%Y-%m-%dT%H:%M:%f', 'now', '-$2 minutes'),
       strftime('%Y-%m-%dT%H:%M:%f', 'now', '-1 minutes'));"
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
check "a persistent stall raises the alarm" "ALERT Responder probe is not working" "$second"
check "the alarm says what is wrong" "queued 12m without moving" "$second"

# Recovery: the queue drains. The endpoint is still unreachable, so this also
# proves an unreachable deployment is reported rather than passed over.
seed running 30
recovered=$(run)
check "an unreachable endpoint is still reported" "not ready: unreachable" "$recovered"

# With the port answering and the queue drained, it goes quiet and forgets.
rm -rf "$WATCHDOG_STATE"; seed running 30
printf 'listen: 127.0.0.1:0\n' > "$work/deploy/.responder/responder.yaml"
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
printf 'listen: 127.0.0.1:%s\n' "$(cat "$work/port")" > "$work/deploy/.responder/responder.yaml"
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
  > "$work/deploy/.responder/responder.yaml"
printf 'SLACK_BOT_TOKEN=xoxb-watchdog-test-token\n' > "$work/deploy/.responder/local.env"
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
rm -rf "$WATCHDOG_STATE"; rm -f "$work/deploy/.responder/local.env"; seed pending 12
run >/dev/null
nodm=$(run)
check "a deployment without credentials skips the DM and says so" "slack DM skipped" "$nodm"

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
