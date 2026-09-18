#!/bin/bash
# Proves the watchdog fires, stays quiet, recovers, and speaks where a person
# will see it.
#
# A watchdog is the one piece of software whose failure mode is silence, and
# silence is also what it looks like when everything is fine. The only way to
# know it works is to break something on purpose and watch it complain.
#
# The not-ready case reproduces 2026-09-13 to 2026-09-18: the deployment's
# control plane answering 503 with its fleet gone, for days, while the previous
# watchdog looked for a database file that no longer existed and said nothing.
set -uo pipefail

# The watchdog is a launchd agent and reads launch agents with plutil; it only
# exists on macOS, so that is the only place its self-test means anything.
if [[ $(uname -s) != Darwin ]]; then
  echo "skip: the watchdog is a launchd agent; its self-test runs on macOS"
  exit 0
fi

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
server_pid=""
cleanup() {
  if [[ -n $server_pid ]]; then
    kill "$server_pid" 2>/dev/null
    wait "$server_pid" 2>/dev/null
  fi
  rm -rf "$work"
}
trap cleanup EXIT

export WATCHDOG_AGENTS="$work/agents"
export WATCHDOG_STATE="$work/state"
export WATCHDOG_NO_NOTIFY=1
export WATCHDOG_STRIKES=2
export WATCHDOG_RENOTIFY_MINUTES=30
unset WATCHDOG_SLACK_CHANNEL WATCHDOG_SLACK_API

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

# A stand-in control plane: /readyz and /metrics answer from files the cases
# rewrite, and every POST — the Slack API — is recorded with its bearer token
# and whether its body parsed as JSON.
fake="$work/fake"
mkdir -p "$fake"
cat > "$work/server.py" <<'PY'
import http.server, json, os, sys

base = sys.argv[1]

def read(name, default=""):
    try:
        with open(os.path.join(base, name)) as handle:
            return handle.read()
    except FileNotFoundError:
        return default

class Handler(http.server.BaseHTTPRequestHandler):
    def respond(self, code, body):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/readyz":
            self.respond(int(read("readyz.code", "200")), read("readyz.body", "ready\n"))
        elif self.path == "/metrics":
            self.respond(200, read("metrics"))
        else:
            self.respond(404, "not found\n")

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()
        try:
            json.loads(body)
            parsed = "json"
        except ValueError:
            parsed = "INVALID-JSON"
        with open(os.path.join(base, "slack-posts"), "a") as handle:
            handle.write(f"{self.path} {self.headers.get('Authorization', '')} {parsed} {body}\n")
        self.respond(200, '{"ok":true}')

    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(base, "port"), "w") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY
python3 "$work/server.py" "$fake" &
server_pid=$!
for _ in $(seq 1 50); do [[ -s $fake/port ]] && break; sleep 0.1; done
port=$(cat "$fake/port")

ready() { printf '200' > "$fake/readyz.code"; printf 'ready\n' > "$fake/readyz.body"; }
not_ready() { printf '503' > "$fake/readyz.code"; printf 'not ready: %s\n' "$1" > "$fake/readyz.body"; }
metrics() { printf '%s\n' "$@" > "$fake/metrics"; }

# The deployment exactly as this host lays it out: the release's launch agent
# names its state root as WorkingDirectory, and the root holds runtime.env.
deploy="$work/deploy/emisar"
mkdir -p "$WATCHDOG_AGENTS" "$deploy/log" "$deploy/coop-worker/log"
cat > "$deploy/runtime.env" <<ENV
RYKER_CONTROL_IP=0.0.0.0
RYKER_CONTROL_PORT=$port
export SLACK_BOT_TOKEN="xoxb-watchdog-test-token"
ENV
agent() {
  local label="$1" key="$2" value="$3"
  /usr/bin/plutil -create xml1 "$WATCHDOG_AGENTS/$label.plist"
  /usr/bin/plutil -insert Label -string "$label" "$WATCHDOG_AGENTS/$label.plist"
  /usr/bin/plutil -insert "$key" -string "$value" "$WATCHDOG_AGENTS/$label.plist"
}
agent ai.emisar.ryker WorkingDirectory "$deploy"
/usr/bin/plutil -insert StandardErrorPath -string "$deploy/log/ryker.stderr.log" \
  "$WATCHDOG_AGENTS/ai.emisar.ryker.plist"
# Neighbours under the same prefix that are not deployments: the Coop worker,
# the watchdog itself, and a staged copy left by an interrupted install.
agent ai.emisar.ryker.emisar-coop-worker StandardErrorPath "$deploy/coop-worker/log/worker.stderr.log"
agent ai.emisar.ryker.watchdog StandardErrorPath "$WATCHDOG_STATE/stderr.log"
cp "$WATCHDOG_AGENTS/ai.emisar.ryker.plist" "$WATCHDOG_AGENTS/ai.emisar.ryker.plist.staged-abc123"

# run prints only the log lines this run wrote, then its exit status.
run() {
  local before=0 status
  [[ -f $WATCHDOG_STATE/watchdog.log ]] && before=$(wc -l < "$WATCHDOG_STATE/watchdog.log")
  bash "$root/scripts/watchdog.sh"
  status=$?
  [[ -f $WATCHDOG_STATE/watchdog.log ]] && tail -n +"$((before + 1))" "$WATCHDOG_STATE/watchdog.log"
  echo "exit=$status"
}
reset() { rm -rf "$WATCHDOG_STATE" "$fake/slack-posts"; }

# ---------------------------------------------------------------------------
# A healthy deployment is silent, and the heartbeat proves the check ran.
reset; ready; metrics 'ryker_queue_claimable{queue="work"} 0' 'ryker_work_total{status="settled"} 9'
out="$(run)$(run)"
refute "a healthy deployment raises nothing" "ALERT" "$out"
check "a healthy deployment exits cleanly" "exit=0" "$out"
check "the heartbeat records that the check ran" "T" "$(cat "$WATCHDOG_STATE/heartbeat" 2>/dev/null)"
refute "the Coop worker, the watchdog and a staged copy are not deployments" "coop-worker" "$out"

# ---------------------------------------------------------------------------
# 2026-09-13 to 09-18: the fleet was gone and /readyz said so for days.
reset; not_ready "no_eligible_workers; no_session_capacity"
first=$(run)
check "one bad check is a strike" "strike 1/2): not ready: no_eligible_workers; no_session_capacity" "$first"
refute "one bad check is not an alarm" "ALERT" "$first"
second=$(run)
check "consecutive bad checks alarm with the host's own reasons" \
  "ALERT Ryker emisar is not working — not ready: no_eligible_workers; no_session_capacity" "$second"
third=$(run)
refute "a standing outage does not alarm every minute" "ALERT" "$third"
fourth=$(WATCHDOG_RENOTIFY_MINUTES=0 run)
check "a standing outage is repeated once the renotify interval passes" "ALERT Ryker emisar is not working" "$fourth"

ready
recovered=$(run)
check "the first ready check after an alarm says so" "ALERT Ryker emisar recovered" "$recovered"
again=$(run)
refute "recovery is announced once" "ALERT" "$again"

# A deploy restarts the release and drops readiness for about a minute: one
# bad check between good ones is neither an alarm nor a recovery.
reset; ready; run >/dev/null
not_ready "lane not cycling: work"; blip=$(run)
ready; after=$(run)
refute "a single bad check during a deploy stays quiet" "ALERT" "$blip$after"

# ---------------------------------------------------------------------------
# A control plane that does not answer is the alarm itself; the watchdog
# needs nothing from the process it watches.
reset
printf 'RYKER_CONTROL_IP=127.0.0.1\nRYKER_CONTROL_PORT=%s\n' "$((port + 1))" > "$deploy/runtime.env.down"
cp "$deploy/runtime.env" "$deploy/runtime.env.up"
cp "$deploy/runtime.env.down" "$deploy/runtime.env"
run >/dev/null
down=$(run)
check "an unreachable control plane alarms" \
  "ALERT Ryker emisar is not working — control plane unreachable at http://127.0.0.1:$((port + 1))" "$down"
cp "$deploy/runtime.env.up" "$deploy/runtime.env"

# ---------------------------------------------------------------------------
# Work whose retries are spent waits for a person on the Failures page. That
# is a durable state, so it alarms when it appears and when it grows, not on
# strikes and not every half hour; retention's own blocked gauge is a
# workspace kept for review on purpose and never counts.
reset; ready
metrics 'ryker_work_total{status="blocked"} 1' 'ryker_retention_blocked 4' \
  'ryker_retention_sessions{status="blocked"} 4'
blocked=$(run)
check "newly blocked work alarms at once" \
  "ALERT Ryker emisar needs attention — 1 request is blocked and waiting for an operator: http://127.0.0.1:$port/failures" \
  "$blocked"
same=$(run)
refute "the same blocked work is not repeated" "ALERT" "$same"
metrics 'ryker_work_total{status="blocked"} 1' 'ryker_ingress_total{status="blocked"} 2' 'ryker_retention_blocked 4'
grew=$(run)
check "more blocked work alarms again with the new total" "3 requests are blocked" "$grew"
metrics 'ryker_work_total{status="settled"} 3' 'ryker_retention_blocked 4'
cleared=$(run)
refute "resolved blocked work raises nothing" "ALERT" "$cleared"
check "resolved blocked work is noted" "blocked requests fell from 3 to 0" "$cleared"
metrics 'ryker_retention_blocked 4' 'ryker_retention_sessions{status="blocked"} 4'
reset; retained=$(run)
refute "a workspace kept for review is not blocked work" "needs attention" "$retained"

# ---------------------------------------------------------------------------
# The alarm reaches Slack as a DM sent with the deployment's own token, and a
# reason carrying a quote still makes valid JSON.
reset; metrics 'ryker_work_total{status="settled"} 1'
not_ready 'settings not applied: "quoted"'
export WATCHDOG_SLACK_CHANNEL=UWATCHOP1 WATCHDOG_SLACK_API="http://127.0.0.1:$port"
run >/dev/null; run >/dev/null
posts=$(cat "$fake/slack-posts" 2>/dev/null)
check "the alarm is posted to chat.postMessage" "/chat.postMessage" "$posts"
check "the DM goes to the configured operator" '"channel":"UWATCHOP1"' "$posts"
check "the DM authenticates with the deployment's token" "Bearer xoxb-watchdog-test-token" "$posts"
check "the DM says what is wrong" "is not working" "$posts"
refute "a quote in the reason still makes valid JSON" "INVALID-JSON" "$posts"

# Without a token or a channel the alarm stays local and the log says why.
reset
grep -v SLACK_BOT_TOKEN "$deploy/runtime.env.up" > "$deploy/runtime.env"
run >/dev/null; notoken=$(run)
check "a deployment without a bot token skips the DM and says so" "no SLACK_BOT_TOKEN" "$notoken"
cp "$deploy/runtime.env.up" "$deploy/runtime.env"
unset WATCHDOG_SLACK_CHANNEL
reset; run >/dev/null; nochannel=$(run)
check "no configured channel skips the DM and says so" "WATCHDOG_SLACK_CHANNEL is not set" "$nochannel"
unset WATCHDOG_SLACK_API

# ---------------------------------------------------------------------------
# A watchdog with nothing to watch is itself a failure, not a quiet success.
reset; ready
empty="$work/empty-agents"; mkdir -p "$empty"
nothing=$(WATCHDOG_AGENTS="$empty" run)
check "nothing to watch alarms" "ALERT Ryker watchdog found nothing to watch" "$nothing"
check "nothing to watch fails the run" "exit=1" "$nothing"

if [[ $failures -gt 0 ]]; then
  echo "$failures watchdog check(s) failed"
  exit 1
fi
echo "watchdog self-test passed"
