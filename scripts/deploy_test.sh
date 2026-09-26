#!/usr/bin/env bash
# Proves scripts/deploy.sh refuses what it must refuse and, against a fake
# Docker and a fake control plane, does its steps in the right order: the
# database backed up before the container is replaced, the version pinned
# only after the host saw the new release healthy, ready and named in the
# version header, the worktree gone either way, and a failed deploy leaving
# the previous pin in place with the container's logs on the screen.
#
# The pin-after-verification rule is the one that matters most. A deploy
# that pins first and fails later leaves compose.env claiming a version that
# is not serving, which is exactly the "the fix is live" claim this
# repository's rules forbid making without proof.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/ryker-deploy-test.XXXXXX")
server_pid=
cleanup() {
  if [[ -n $server_pid ]]; then
    kill "$server_pid" 2>/dev/null
    wait "$server_pid" 2>/dev/null
  fi
  rm -rf "$work"
}
trap cleanup EXIT

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

refute() {
  local what="$1" unwanted="$2" actual="$3"
  if [[ $actual == *"$unwanted"* ]]; then
    printf 'FAIL %s\n     unwanted: %s\n     got:      %s\n' "$what" "$unwanted" "$actual"
    failures=$((failures + 1))
  else
    printf 'ok   %s\n' "$what"
  fi
}

# A repository of its own, so nothing here depends on the state of this
# checkout: the script under test is copied in beside the version script it
# calls, and a compose.yml stands in for the project.
repo="$work/repo"
mkdir -p "$repo/scripts"
git init -q --initial-branch=main "$repo"
git -C "$repo" config user.email deploy-test@example.invalid
git -C "$repo" config user.name "deploy test"
cp "$root/scripts/deploy.sh" "$root/scripts/elixir-release-version.sh" "$repo/scripts/"
printf 'name: ryker\n' >"$repo/compose.yml"
git -C "$repo" add -A
git -C "$repo" commit -q -m "first"
sha=$(git -C "$repo" rev-parse HEAD)
version="0.1.0-g$sha"
old_version="0.1.0-g$(printf 'a%.0s' $(seq 1 40))"

# A stand-in control plane: /healthz always answers, /readyz answers from
# files the cases rewrite, and every answer carries the version the fake
# Docker "started".
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
        if self.path == "/healthz":
            self.respond(200, "ok\n")
        elif self.path == "/readyz":
            self.respond(int(read("readyz.code", "200")), read("readyz.body", "ready\n"))
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

# The fake Docker records every call and answers as the Compose project
# would; files under $fake make it fail where a case needs it to.
cat >"$work/bin/docker" <<'SH'
#!/usr/bin/env bash
fake=$DEPLOY_TEST_FAKE
printf '%s\n' "$*" >>"$fake/calls"
case " $* " in
  *" compose version "*) echo "Docker Compose version v-fake" ;;
  *" exec -T database pg_isready "*) [[ -f $fake/database.down ]] && exit 1 ;;
  *" exec -T database pg_dump "*) printf 'PGDMP fake dump\n' ;;
  *" exec -T database pg_restore --list "*) cat >/dev/null ;;
  *" up --detach --build --wait "*)
    printf 'RYKER_VERSION=%s RYKER_IMAGE=%s\n' "${RYKER_VERSION:-}" "${RYKER_IMAGE:-}" >>"$fake/up.env"
    [[ -f $fake/up.fail ]] && { echo "fake: the container did not become healthy" >&2; exit 1; }
    [[ -f $fake/up.stale ]] || printf '%s\n' "${RYKER_VERSION:-}" >"$fake/version"
    ;;
  *" logs "*) echo "fake container log line" ;;
  *" ps "*) echo "ryker fake running" ;;
  *" image ls "*) cat "$fake/images" 2>/dev/null ;;
esac
exit 0
SH
chmod 0755 "$work/bin/docker"
export PATH="$work/bin:$PATH" DEPLOY_TEST_FAKE="$fake"

state="$work/state"
mkdir -p "$state"
export RYKER_INSTALL_STATE="$state" RYKER_DEPLOY_READY_TIMEOUT=3 RYKER_DEPLOY_POLL_SECONDS=1

seed() {
  # The installation as the previous deploy left it, and a fake project that
  # still serves the previous version until the fake Docker "starts" a new one.
  rm -f "$fake/calls" "$fake/up.env" "$fake/up.fail" "$fake/up.stale" "$fake/database.down"
  printf '%s\n' "$old_version" >"$fake/version"
  printf '200' >"$fake/readyz.code"
  printf 'ready\n' >"$fake/readyz.body"
  cat >"$state/compose.env" <<ENV
# RYKER_GENERATED_ENV - test installation
RYKER_VERSION=$old_version
RYKER_IMAGE=ryker:$old_version
RYKER_DATABASE_PASSWORD=secret-test-password
RYKER_CONTROL_BIND=0.0.0.0
RYKER_CONTROL_PORT=$port
ENV
  chmod 0600 "$state/compose.env"
}

run() {
  local out
  out=$("$repo/scripts/deploy.sh" "$@" 2>&1)
  printf '%s\nexit=%s\n' "$out" "$?"
}

backups() { find "$state/backups" -name 'pre-deploy-*.tar.gz' 2>/dev/null | wc -l | tr -d ' '; }
worktrees() { git -C "$repo" worktree list | wc -l | tr -d ' '; }
mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
}

# ---------------------------------------------------------------------------
# Refusals come before anything is touched.
seed
out=$(run --bogus)
check "an unknown argument prints the usage" "usage: scripts/deploy.sh" "$out"
check "an unknown argument exits 2" "exit=2" "$out"

printf 'scratch\n' >"$repo/untracked"
out=$(run)
check "a dirty tree is refused" "refusing to deploy a dirty tree" "$out"
check "a dirty tree exits 1" "exit=1" "$out"
refute "a dirty tree reaches no Docker command" "compose" "$(cat "$fake/calls" 2>/dev/null)"
rm "$repo/untracked"

out=$(RYKER_INSTALL_STATE="$work/nowhere" run)
check "a checkout with no installation is refused" "not installed here" "$out"
check "no installation exits 1" "exit=1" "$out"

touch "$fake/database.down"
out=$(run)
check "a stopped database refuses before any backup" "database container is not running" "$out"
check "no backup is written when the database is down" "0" "$(backups)"
refute "no container is replaced when the database is down" "up --detach" "$(cat "$fake/calls")"
check "the worktree is removed after a refused deploy" "1" "$(worktrees)"

# ---------------------------------------------------------------------------
# The ordinary deploy from main.
seed
for letter in b c d e; do
  printf 'ryker:0.1.0-g%s\n' "$(printf "$letter%.0s" $(seq 1 40))" >>"$fake/images"
done
{
  printf 'ryker:%s\n' "$version"
  printf 'ryker:%s\n' "$old_version"
  printf 'ryker:1.0.0\nryker:production-audit\n'
} >>"$fake/images"
out=$(run)
check "a deploy from main succeeds" "exit=0" "$out"
check "the deploy names the running version" "ryker $version is running" "$out"
check "the deploy says how long it took" "done in " "$out"
calls=$(cat "$fake/calls")
dump_line=$(grep -n 'pg_dump' <<<"$calls" | head -n 1 | cut -d: -f1)
up_line=$(grep -n 'up --detach --build --wait' <<<"$calls" | head -n 1 | cut -d: -f1)
check "the container is replaced with --no-deps ryker only" "--no-deps ryker" "$calls"
if [[ -n $dump_line && -n $up_line && $dump_line -lt $up_line ]]; then
  printf 'ok   the database is backed up before the container is replaced\n'
else
  printf 'FAIL the database is backed up before the container is replaced\n     calls:\n%s\n' "$calls"
  failures=$((failures + 1))
fi
check "the build and image carry the commit version" \
  "RYKER_VERSION=$version RYKER_IMAGE=ryker:$version" "$(cat "$fake/up.env")"
check "the deploy pins the new version" "RYKER_VERSION=$version" "$(cat "$state/compose.env")"
check "the deploy pins the new image" "RYKER_IMAGE=ryker:$version" "$(cat "$state/compose.env")"
check "pinning keeps the rest of compose.env" "RYKER_DATABASE_PASSWORD=secret-test-password" "$(cat "$state/compose.env")"
check "compose.env stays owner-only" "600" "$(mode "$state/compose.env")"
check "one pre-deploy backup was written" "1" "$(backups)"
backup=$(find "$state/backups" -name 'pre-deploy-*.tar.gz' | head -n 1)
check "the backup is owner-only" "600" "$(mode "$backup")"
check "the backup holds the database dump" "database.dump" "$(tar -tzf "$backup")"
check "the backup holds the environment" "compose.env" "$(tar -tzf "$backup")"
check "the backup's environment pins the version that was running before" \
  "RYKER_VERSION=$old_version" "$(tar -xzOf "$backup" compose.env)"
check "the worktree is removed after a successful deploy" "1" "$(worktrees)"
worktree=$(sed -n 's/.*clean worktree at \(.*\)$/\1/p' <<<"$out" | head -n 1)
if [[ -n $worktree && ! -e $worktree ]]; then
  printf 'ok   the worktree directory is gone\n'
else
  printf 'FAIL the worktree directory is gone\n     path: %s\n' "$worktree"
  failures=$((failures + 1))
fi
check "images older than the kept ones are pruned" "image rm ryker:0.1.0-g$(printf 'd%.0s' $(seq 1 40))" "$calls"
check "the oldest image is pruned" "image rm ryker:0.1.0-g$(printf 'e%.0s' $(seq 1 40))" "$calls"
refute "the pinned image is never pruned" "image rm ryker:$version" "$calls"
refute "the previous image is kept for a rollback" "image rm ryker:$old_version" "$calls"
refute "recent commit images stay" "image rm ryker:0.1.0-g$(printf 'b%.0s' $(seq 1 40))" "$calls"
refute "a tagged release is never pruned" "image rm ryker:1.0.0" "$calls"
refute "a hand-made tag is never pruned" "image rm ryker:production-audit" "$calls"

# ---------------------------------------------------------------------------
# A container that does not come up healthy.
seed
touch "$fake/up.fail"
out=$(run)
check "a container that stays unhealthy fails the deploy" "exit=1" "$out"
check "the failure is named" "FAILED" "$out"
check "the container's logs are printed" "fake container log line" "$out"
check "the previous version stays pinned" "RYKER_VERSION=$old_version" "$(cat "$state/compose.env")"
check "the failure says what is still pinned" "still pins $old_version" "$out"
check "the backup was taken before the failed replacement" "1" "$(backups)"
check "the worktree is removed after a failed deploy" "1" "$(worktrees)"

# ---------------------------------------------------------------------------
# A container that is healthy but serves other code than the commit.
seed
touch "$fake/up.stale"
out=$(run)
check "a version header that is not the commit fails the deploy" "exit=1" "$out"
check "the mismatch names the version that is serving" "version $old_version" "$out"
check "a mismatched version is not pinned" "RYKER_VERSION=$old_version" "$(cat "$state/compose.env")"

# ---------------------------------------------------------------------------
# A container that is healthy and the right version but not ready.
seed
printf '503' >"$fake/readyz.code"
printf 'not ready: no_eligible_workers\n' >"$fake/readyz.body"
out=$(run)
check "a release that never becomes ready fails the deploy" "exit=1" "$out"
check "the failure carries the host's own readiness reason" "no_eligible_workers" "$out"
check "an unready release is not pinned" "RYKER_VERSION=$old_version" "$(cat "$state/compose.env")"

# ---------------------------------------------------------------------------
# A HEAD that is not main's.
seed
git -C "$repo" checkout -q -b feature
printf 'branch work\n' >"$repo/feature.txt"
git -C "$repo" add -A
git -C "$repo" commit -q -m "feature"
out=$(run)
check "a branch HEAD is refused" "is not main's HEAD" "$out"
check "a branch HEAD exits 1" "exit=1" "$out"
refute "a refused branch reaches no Docker command" "compose" "$(cat "$fake/calls" 2>/dev/null)"
out=$(run --allow-not-main)
check "--allow-not-main deploys the branch on purpose" "exit=0" "$out"
check "the branch deploy pins its own commit" "RYKER_VERSION=0.1.0-g$(git -C "$repo" rev-parse HEAD)" "$(cat "$state/compose.env")"
git -C "$repo" checkout -q main

if [[ $failures -gt 0 ]]; then
  echo "$failures deploy check(s) failed"
  exit 1
fi
echo "deploy self-test passed"
