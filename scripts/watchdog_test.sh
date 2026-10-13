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
server6_pid=""
remote_pid=""
cleanup() {
  local pid
  for pid in $server_pid $server6_pid $remote_pid; do
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  done
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
import http.server, os, socket, sys

base = sys.argv[1]
host = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
port_file = sys.argv[3] if len(sys.argv) > 3 else "port"

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

class Server(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6 if ":" in host else socket.AF_INET

server = Server((host, 0), Handler)
with open(os.path.join(base, port_file), "w") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY
python3 "$work/server.py" "$fake" &
server_pid=$!
# The one other address Ryker lets the console be published on is IPv6
# loopback; a host without one skips the check that needs it.
python3 "$work/server.py" "$fake" ::1 port6 2>/dev/null &
server6_pid=$!
for _ in $(seq 1 50); do [[ -s $fake/port && -s $fake/port6 ]] && break; sleep 0.1; done
port=$(cat "$fake/port")
port6=$(cat "$fake/port6" 2>/dev/null)

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
# The models Compose runs beside Ryker, healthy.
models=(whisper running healthy whisper-detect running healthy embeddings running healthy)
all_healthy() {
  containers ryker running healthy database running healthy \
    ryker-coop running healthy ryker-coop-docker running healthy "${models[@]}"
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

# 2026-10-04 review: the watchdog wrote ::1 into a URL without its brackets, so a console
# published on IPv6 loopback, which Ryker allows, read as unreachable every minute.
if [[ -n $port6 ]]; then
  reset; ready
  sed -e 's/^RYKER_CONTROL_BIND=.*/RYKER_CONTROL_BIND=::1/' \
    -e "s/^RYKER_CONTROL_PORT=.*/RYKER_CONTROL_PORT=$port6/" "$install/compose.env" >"$install/compose.env.ipv6"
  ipv6=""
  for _ in 1 2 3; do ipv6+=$(WATCHDOG_ENV_FILE="$install/compose.env.ipv6" run); done
  refute "a console published on IPv6 loopback is watched there" "ALERT" "$ipv6"
else
  printf 'skip a console published on IPv6 loopback (this host has no ::1)\n'
fi

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
  ryker-coop exited "" ryker-coop-docker running unhealthy "${models[@]}"
run >/dev/null
gone=$(run)
check "an exited container alarms while readiness still says ready" \
  "ALERT Ryker is not working — container ryker-coop is exited; container ryker-coop-docker is unhealthy" "$gone"
reset; ready
containers ryker running healthy database running healthy ryker-coop-docker running healthy "${models[@]}"
run >/dev/null
missing=$(run)
check "a container that is not in the project at all is named" "container ryker-coop is missing" "$missing"
reset; ready
containers ryker running starting database running healthy \
  ryker-coop running healthy ryker-coop-docker running healthy "${models[@]}"
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
  "ALERT Ryker is working with less: a model stopped — whisper at http://127.0.0.1:$((port + 1)) is not answering" \
  "$silent"
refute "the whisper server that answers is not named" "127.0.0.1:$port is not answering" "$silent"

# 2026-10-13: the models run in Compose beside Ryker, where the host cannot
# reach them by name. Their containers say whether they run; one that stopped
# makes Ryker worse, not stopped, and the alarm says what Ryker does without it.
reset; ready
containers ryker running healthy database running healthy ryker-coop running healthy \
  ryker-coop-docker running healthy whisper exited "" whisper-detect running healthy \
  embeddings running unhealthy
run >/dev/null
worse=$(run)
check "a model container that stopped alarms, as worse rather than stopped" \
  "ALERT Ryker is working with less: a model stopped — container whisper is exited, so voice messages are read by Ryker's own small model; container embeddings is unhealthy, so routing finds earlier work by words alone" \
  "$worse"
reset; ready
cp "$install/compose.env" "$install/compose.env.routing"
printf 'COMPOSE_PROFILES=routing-model\n' >>"$install/compose.env.routing"
WATCHDOG_ENV_FILE="$install/compose.env.routing" run >/dev/null
comparing=$(WATCHDOG_ENV_FILE="$install/compose.env.routing" run)
check "the local routing model is watched once its profile is on" \
  "container routing-model is missing, so the local routing model is not compared" "$comparing"
offprofile=$(run)
refute "the local routing model is not watched while its profile is off" "routing-model" "$offprofile"
cp "$install/compose.env" "$install/compose.env.service"
printf 'RYKER_WHISPER_URL=http://whisper:8080\n' >>"$install/compose.env.service"
named=$(WATCHDOG_ENV_FILE="$install/compose.env.service" run)
refute "a whisper address only Compose can resolve is not probed from the host" "strike" "$named"

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
# It alarmed every minute, past the repeat limit every other alarm keeps (2026-10-04 review).
again=$(WATCHDOG_ENV_FILE="$work/nowhere/compose.env" run)
refute "nothing to watch repeats only after the renotify interval" "ALERT" "$again"
check "nothing to watch still fails every run" "exit=1" "$again"

# ---------------------------------------------------------------------------
# An install on another machine, watched from this one through the address it is published at.
# The tenant install runs where a notification reaches nobody, and nothing watched it until
# 2026-10-14. Only its readiness is public there, so that is what is asked.
remote="$work/remote"
mkdir -p "$remote"
python3 "$work/server.py" "$remote" &
remote_pid=$!
for _ in $(seq 1 50); do [[ -s $remote/port ]] && break; sleep 0.1; done
remote_origin="http://127.0.0.1:$(cat "$remote/port")"
printf 'RYKER_WATCH_REMOTE=%s\n' "$remote_origin" >>"$install/compose.env"
reset; ready; metrics 'ryker_work_total{status="settled"} 1'
printf '503' >"$remote/readyz.code"
printf 'not ready: no_eligible_workers\n' >"$remote/readyz.body"
remote_down="$(run)$(run)"
check "a remote install that is not ready alarms with its reasons" \
  "ALERT Ryker at $remote_origin is not working — not ready: no_eligible_workers" "$remote_down"
refute "the local install stays quiet while a remote one is down" "ALERT Ryker is not working" "$remote_down"
quiet=$(run)
refute "a remote outage repeats only after the renotify interval" "ALERT" "$quiet"
printf '200' >"$remote/readyz.code"
printf 'ready\n' >"$remote/readyz.body"
remote_back=$(run)
check "a remote install ready again says so" "ALERT Ryker at $remote_origin recovered" "$remote_back"
kill "$remote_pid" 2>/dev/null
wait "$remote_pid" 2>/dev/null
remote_pid=""
gone="$(run)$(run)"
check "an unreachable remote install alarms" "ALERT Ryker at $remote_origin is not working — unreachable" "$gone"

if [[ $failures -gt 0 ]]; then
  echo "$failures watchdog check(s) failed"
  exit 1
fi
echo "watchdog self-test passed"
