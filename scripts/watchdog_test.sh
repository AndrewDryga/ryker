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
# The version case is the deploy that started a container and never pinned
# it, and the container case is the worker gone while readiness still says
# ready because its lease has not lapsed.
set -uo pipefail

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

export WATCHDOG_STATE="$work/state"
export WATCHDOG_NO_NOTIFY=1
export WATCHDOG_STRIKES=2
export WATCHDOG_RENOTIFY_MINUTES=30

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
# rewrite, and every answer carries the version another file names.
fake="$work/fake"
mkdir -p "$fake" "$work/bin"
cat >"$work/server.py" <<'PY'
import http.server, os, sys

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
        version = read("version").strip()
        if version:
            self.send_header("x-ryker-version", version)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/readyz":
            self.respond(int(read("readyz.code", "200")), read("readyz.body", "ready\n"))
        elif self.path == "/metrics":
            self.respond(200, read("metrics"))
        else:
            self.respond(404, "not found\n")

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

ready() { printf '200' >"$fake/readyz.code"; printf 'ready\n' >"$fake/readyz.body"; }
not_ready() { printf '503' >"$fake/readyz.code"; printf 'not ready: %s\n' "$1" >"$fake/readyz.body"; }
metrics() { printf '%s\n' "$@" >"$fake/metrics"; }
serving() { printf '%s\n' "$1" >"$fake/version"; }

# The installation exactly as install.sh and deploy.sh leave it: the pinned
# version and the control listener in compose.env, plus the project's
# containers as a fake Docker lists them.
install="$work/install"
mkdir -p "$install"
cat >"$install/compose.env" <<ENV
# RYKER_GENERATED_ENV - test installation
RYKER_VERSION=1.2.3
RYKER_IMAGE=ryker:1.2.3
RYKER_DATABASE_PASSWORD=secret-test-password
RYKER_CONTROL_BIND=127.0.0.1
RYKER_CONTROL_PORT=$port
ENV
export WATCHDOG_ENV_FILE="$install/compose.env"

cat >"$work/bin/docker" <<'SH'
#!/bin/bash
fake=$WATCHDOG_TEST_FAKE
[[ -f $fake/docker.down ]] && exit 1
[[ -f $fake/docker.hung ]] && exec sleep 300
cat "$fake/containers"
SH
chmod 0755 "$work/bin/docker"
export WATCHDOG_DOCKER="$work/bin/docker" WATCHDOG_TEST_FAKE="$fake"
containers() {
  # containers [SERVICE STATE HEALTH]...: the fake project's listing.
  printf 'volume-init\texited\t\n' >"$fake/containers"
  while (($# >= 3)); do
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$fake/containers"
    shift 3
  done
}
all_healthy() {
  containers ryker running healthy database running healthy \
    ryker-coop running healthy ryker-coop-docker running healthy
}

# run prints only the log lines this run wrote, then its exit status.
run() {
  local before=0 status
  [[ -f $WATCHDOG_STATE/watchdog.log ]] && before=$(wc -l <"$WATCHDOG_STATE/watchdog.log")
  bash "$root/scripts/watchdog.sh"
  status=$?
  [[ -f $WATCHDOG_STATE/watchdog.log ]] && tail -n +"$((before + 1))" "$WATCHDOG_STATE/watchdog.log"
  echo "exit=$status"
}
reset() { rm -rf "$WATCHDOG_STATE" "$fake/docker.down" "$fake/docker.hung"; all_healthy; serving 1.2.3; }

# ---------------------------------------------------------------------------
# A healthy deployment is silent, and the heartbeat proves the check ran.
reset; ready; metrics 'ryker_queue_claimable{queue="work"} 0' 'ryker_work_total{status="settled"} 9'
out="$(run)$(run)"
refute "a healthy deployment raises nothing" "ALERT" "$out"
check "a healthy deployment exits cleanly" "exit=0" "$out"
check "the heartbeat records that the check ran" "T" "$(cat "$WATCHDOG_STATE/heartbeat" 2>/dev/null)"
refute "volume-init exiting is by design" "volume-init" "$out"

# ---------------------------------------------------------------------------
# 2026-09-13 to 09-18: the fleet was gone and /readyz said so for days.
reset; not_ready "no_eligible_workers; no_session_capacity"
first=$(run)
check "one bad check is a strike" "strike 1/2): not ready: no_eligible_workers; no_session_capacity" "$first"
refute "one bad check is not an alarm" "ALERT" "$first"
second=$(run)
check "consecutive bad checks alarm with the host's own reasons" \
  "ALERT Ryker is not working — not ready: no_eligible_workers; no_session_capacity" "$second"
third=$(run)
refute "a standing outage does not alarm every minute" "ALERT" "$third"
fourth=$(WATCHDOG_RENOTIFY_MINUTES=0 run)
check "a standing outage is repeated once the renotify interval passes" "ALERT Ryker is not working" "$fourth"

ready
recovered=$(run)
check "the first ready check after an alarm says so" "ALERT Ryker recovered" "$recovered"
again=$(run)
refute "recovery is announced once" "ALERT" "$again"

# A deploy replaces the container and drops readiness for about a minute: one
# bad check between good ones is neither an alarm nor a recovery.
reset; ready; run >/dev/null
not_ready "lane not cycling: work"; blip=$(run)
ready; after=$(run)
refute "a single bad check during a deploy stays quiet" "ALERT" "$blip$after"

# ---------------------------------------------------------------------------
# A control plane that does not answer is the alarm itself; the watchdog
# needs nothing from the process it watches.
reset
sed "s/^RYKER_CONTROL_PORT=.*/RYKER_CONTROL_PORT=$((port + 1))/" "$install/compose.env" >"$install/compose.env.down"
WATCHDOG_ENV_FILE="$install/compose.env.down" run >/dev/null
down=$(WATCHDOG_ENV_FILE="$install/compose.env.down" run)
check "an unreachable control plane alarms" \
  "ALERT Ryker is not working — control plane unreachable at http://127.0.0.1:$((port + 1))" "$down"

# ---------------------------------------------------------------------------
# A container serving other code than compose.env pins is a deploy that did
# not finish, and the operator reading compose.env would debug the wrong
# release.
reset; ready; serving 9.9.9
run >/dev/null
crossed=$(run)
check "a running version other than the pinned one alarms" \
  "ALERT Ryker is not working — running 9.9.9, but $install/compose.env pins 1.2.3" "$crossed"
serving 1.2.3
repinned=$(run)
check "the pinned version serving again is a recovery" "ALERT Ryker recovered" "$repinned"

# ---------------------------------------------------------------------------
# Readiness lags a lost worker by its lease; the container listing does not.
reset; ready
containers ryker running healthy database running healthy \
  ryker-coop exited "" ryker-coop-docker running unhealthy
run >/dev/null
gone=$(run)
check "an exited container alarms while readiness still says ready" \
  "ALERT Ryker is not working — container ryker-coop is exited; container ryker-coop-docker is unhealthy" "$gone"
reset; ready
containers ryker running healthy database running healthy ryker-coop-docker running healthy
run >/dev/null
missing=$(run)
check "a container that is not in the project at all is named" "container ryker-coop is missing" "$missing"
reset; ready
containers ryker running starting database running healthy \
  ryker-coop running healthy ryker-coop-docker running healthy
starting=$(run)
refute "a container still starting its health check is not a problem" "strike" "$starting"

# Docker itself not answering is worth knowing even while the release is up:
# the next turn needs a box, and there will be none.
reset; ready; touch "$fake/docker.down"
run >/dev/null
nodocker=$(run)
check "a Docker that cannot list the project alarms" \
  "ALERT Ryker is not working — docker compose cannot list the project's containers" "$nodocker"

# 2026-10-04 review: a Docker that hangs, as a wedged OrbStack does, held the check for
# good, and launchd starts no new one while the last still runs. No alarm came in exactly
# the case that had already happened here. Every Docker call has a deadline.
reset; ready; touch "$fake/docker.hung"
export WATCHDOG_DOCKER_TIMEOUT=1
started=$SECONDS
run >/dev/null
hung=$(run)
unset WATCHDOG_DOCKER_TIMEOUT
check "a Docker that does not answer alarms" "ALERT Ryker is not working — Docker is not answering" "$hung"
check "a Docker that does not answer does not hold the check" "fast" \
  "$( ((SECONDS - started < 20)) && echo fast || echo "took $((SECONDS - started))s")"

# ---------------------------------------------------------------------------
# 2026-09-30: voice moved to whisper on this Mac. When it stops, Ryker falls
# back to its small model, which wrote Andrew's Ukrainian as Russian, and
# nothing but this says so. compose.env names the servers the way Ryker's
# container reaches them, through host.docker.internal.
reset; ready
cp "$install/compose.env" "$install/compose.env.voice"
printf 'RYKER_WHISPER_URL=http://host.docker.internal:%s\nRYKER_WHISPER_DETECT_URL=http://host.docker.internal:%s\n' \
  "$port" "$port" >>"$install/compose.env.voice"
answering=$(WATCHDOG_ENV_FILE="$install/compose.env.voice" run)
refute "whisper servers that answer raise nothing" "strike" "$answering"
printf 'RYKER_WHISPER_DETECT_URL=http://host.docker.internal:%s\n' "$((port + 1))" >>"$install/compose.env.voice"
WATCHDOG_ENV_FILE="$install/compose.env.voice" run >/dev/null
silent=$(WATCHDOG_ENV_FILE="$install/compose.env.voice" run)
check "a whisper server that stopped answering alarms, as worse rather than stopped" \
  "ALERT Ryker is working with less: a server on this Mac stopped — whisper at http://127.0.0.1:$((port + 1)) is not answering" \
  "$silent"
refute "the whisper server that answers is not named" "127.0.0.1:$port is not answering" "$silent"

# 2026-09-30: routing searches earlier work by meaning on an embedding server
# on this Mac, and by words alone when it stops.
reset; ready
cp "$install/compose.env" "$install/compose.env.embeddings"
printf 'RYKER_EMBEDDINGS_URL=http://host.docker.internal:%s\n' "$((port + 1))" >>"$install/compose.env.embeddings"
WATCHDOG_ENV_FILE="$install/compose.env.embeddings" run >/dev/null
words=$(WATCHDOG_ENV_FILE="$install/compose.env.embeddings" run)
check "an embedding server that stopped answering alarms" \
  "the embedding server at http://127.0.0.1:$((port + 1)) is not answering, so routing finds earlier work by words alone" \
  "$words"

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
  "ALERT Ryker needs attention — 1 request is blocked and waiting for an operator: http://127.0.0.1:$port/failures" \
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
# A watchdog with nothing to watch is itself a failure, not a quiet success.
reset; ready
nothing=$(WATCHDOG_ENV_FILE="$work/nowhere/compose.env" run)
check "nothing to watch alarms" "ALERT Ryker watchdog found nothing to watch" "$nothing"
check "nothing to watch fails the run" "exit=1" "$nothing"

if [[ $failures -gt 0 ]]; then
  echo "$failures watchdog check(s) failed"
  exit 1
fi
echo "watchdog self-test passed"
