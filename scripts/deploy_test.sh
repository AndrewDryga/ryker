#!/usr/bin/env bash
# Proves scripts/deploy.sh refuses what it must refuse and, against a fake
# Docker and a fake control plane, does its steps in the right order: the
# database backed up before the container is replaced, the version pinned
# only after the host saw the new release healthy, ready and named in the
# version header, the worktree gone either way, and a failed deploy stopping
# the unverified replacement while retaining the previous pin and log tail.
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
cp "$root/scripts/deploy.sh" "$root/scripts/compose.sh" "$root/scripts/compose-lifecycle.sh" \
  "$root/scripts/elixir-release-version.sh" "$repo/scripts/"
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
  *" exec -T database pg_restore --list "*)
    cat >/dev/null
    [[ -f $fake/dump.unreadable ]] && exit 1
    ;;
  *" exec -T database pg_restore -U ryker -d ryker_restoring "*)
    cat >/dev/null
    [[ -f $fake/restore.fail ]] && { echo "fake: pg_restore failed" >&2; exit 1; }
    ;;
  *" run --rm --no-deps -T --entrypoint tar volume-init "*)
    [[ -f $fake/archive.fail ]] && exit 1
    tar -czf - -T /dev/null
    ;;
  *" run --rm --no-deps -T --entrypoint tar ryker-coop "*)
    tar -czf - -T /dev/null
    [[ -f $fake/worker.changed ]] && { echo "tar: coop/agents: file changed as we read it" >&2; exit 1; }
    [[ -f $fake/worker.unreadable ]] && { echo "tar: coop: Cannot open: Permission denied" >&2; exit 2; }
    ;;
  *" build ryker "*)
    printf 'RYKER_VERSION=%s RYKER_IMAGE=%s\n' "${RYKER_VERSION:-}" "${RYKER_IMAGE:-}" >>"$fake/build.env"
    [[ -f $fake/build.fail ]] && { echo "fake: the image did not build" >&2; exit 1; }
    ;;
  *" up --detach --no-build --wait "*)
    # What the environment says, and what the --env-file compose was given pins.
    env_file=$(sed -n 's/.*--env-file \([^ ]*\).*/\1/p' <<<"$*")
    pinned=$(sed -n 's/^RYKER_VERSION=//p' "$env_file" 2>/dev/null | tail -n 1)
    printf 'RYKER_VERSION=%s RYKER_IMAGE=%s PINNED=%s\n' "${RYKER_VERSION:-}" "${RYKER_IMAGE:-}" "$pinned" >>"$fake/up.env"
    touch "$fake/controller.running"
    # A release that runs its migrations as it boots, before it fails or not.
    [[ -f $fake/up.migrates ]] && printf '20261006000000\n' >"$fake/schema"
    [[ -f $fake/up.fail ]] && { echo "fake: the container did not become healthy" >&2; exit 1; }
    # deploy.sh names the version it starts; compose.sh starts the pinned one.
    [[ -f $fake/up.stale || -z ${RYKER_VERSION:-} ]] || printf '%s\n' "${RYKER_VERSION:-}" >"$fake/version"
    ;;
  *" stop ryker "*) rm -f "$fake/controller.running" ;;
  *" start ryker "*) touch "$fake/controller.running" ;;
  *" logs "*) echo "fake container log line" ;;
  *" ps --status running --services "*) [[ -f $fake/controller.stopped ]] || echo "ryker" ;;
  *" exec -T database psql "*"schema_migrations"*) cat "$fake/schema" 2>/dev/null || echo 20261005000000 ;;
  *" exec -T database psql "*) echo 1 ;;
  *" ps "*) echo "ryker fake running" ;;
  *" image ls "*) cat "$fake/images" 2>/dev/null ;;
  *" image inspect "*) [[ -f $fake/image.missing ]] && exit 1 ;;
  *" volume inspect "*) [[ -f $fake/volume.exists ]] || exit 1 ;;
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
  rm -f "$fake/calls" "$fake/build.env" "$fake/build.fail" "$fake/up.env" "$fake/up.fail" "$fake/up.stale" "$fake/database.down" \
    "$fake/schema" "$fake/up.migrates" "$fake/image.missing" "$fake/volume.exists"
  touch "$fake/controller.running"
  rm -rf "$state/backups" "$state/lifecycle.lock"
  printf '%s\n' "$old_version" >"$fake/version"
  printf '200' >"$fake/readyz.code"
  printf 'ready\n' >"$fake/readyz.body"
  cat >"$state/compose.env" <<ENV
# RYKER_GENERATED_ENV - test installation
RYKER_VERSION=$old_version
RYKER_IMAGE=ryker:$old_version
RYKER_DATABASE_PASSWORD=secret-test-password
RYKER_CONTROL_BIND=127.0.0.1
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
check_controller_stopped() {
  local what=$1
  if [[ -e $fake/controller.running ]]; then
    printf 'FAIL %s\n' "$what"
    failures=$((failures + 1))
  else
    printf 'ok   %s\n' "$what"
  fi
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
up_line=$(grep -n 'up --detach --no-build --wait' <<<"$calls" | head -n 1 | cut -d: -f1)
check "the container is replaced with --no-deps ryker only" "--no-deps ryker" "$calls"
if [[ -n $dump_line && -n $up_line && $dump_line -lt $up_line ]]; then
  printf 'ok   the database is backed up before the container is replaced\n'
else
  printf 'FAIL the database is backed up before the container is replaced\n     calls:\n%s\n' "$calls"
  failures=$((failures + 1))
fi
check "the build carries the commit version" \
  "RYKER_VERSION=$version RYKER_IMAGE=ryker:$version" "$(cat "$fake/build.env")"
check "the container runs the image just built" \
  "RYKER_VERSION=$version RYKER_IMAGE=ryker:$version" "$(cat "$fake/up.env")"
check "the deploy pins the new version" "RYKER_VERSION=$version" "$(cat "$state/compose.env")"
check "the deploy pins the new image" "RYKER_IMAGE=ryker:$version" "$(cat "$state/compose.env")"
check "pinning keeps the rest of compose.env" "RYKER_DATABASE_PASSWORD=secret-test-password" "$(cat "$state/compose.env")"
check "compose.env stays owner-only" "600" "$(mode "$state/compose.env")"
check "one pre-deploy backup was written" "1" "$(backups)"
backup=$(find "$state/backups" -name 'pre-deploy-*.tar.gz' | head -n 1)
check "the backup is owner-only" "600" "$(mode "$backup")"
check "the backup holds the database dump" "database.dump" "$(tar -tzf "$backup")"
check "the backup holds encrypted file custody" "ryker-state.tar.gz" "$(tar -tzf "$backup")"
stop_line=$(grep -n 'stop ryker' <<<"$calls" | head -n 1 | cut -d: -f1)
if [[ -n $stop_line && $stop_line -lt $dump_line ]]; then
  printf 'ok   database and file custody share a quiescent snapshot\n'
else
  printf 'FAIL snapshot did not stop its writer before pg_dump\n'
  failures=$((failures + 1))
fi
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
# Old backups. Every deploy writes one of about 20 MB and none was ever
# removed: 140 of them held 2.4 GB on 2026-09-28. The newest ten stay.
seed
mkdir -p "$state/backups"
for day in $(seq -w 1 12); do
  : >"$state/backups/pre-deploy-202001${day}T000000Z.tar.gz"
done
: >"$state/backups/ryker-20200101T000000Z.tar.gz"
out=$(run)
check "a deploy with old backups succeeds" "exit=0" "$out"
check "the newest ten pre-deploy backups stay" "10" "$(backups)"
check "the deploy says it removed the older ones" "removed 3 older pre-deploy backup(s)" "$out"
check "the backup this deploy wrote stays" "1" \
  "$(find "$state/backups" -name "pre-deploy-$(date -u +%Y)*.tar.gz" | wc -l | tr -d ' ')"
check "the oldest kept backup is the fourth" "pre-deploy-20200104T000000Z.tar.gz" "$(ls "$state/backups")"
refute "the oldest backups are removed" "pre-deploy-20200103T000000Z.tar.gz" "$(ls "$state/backups")"
check "other archives are never touched" "ryker-20200101T000000Z.tar.gz" "$(ls "$state/backups")"

# ---------------------------------------------------------------------------
# An image that does not build. On 2026-09-26 mix.exs read a file the
# Dockerfile copied too late, the build failed, and the script blamed the
# container's health and printed the old container's log.
seed
touch "$fake/build.fail"
out=$(run)
check "an image that does not build fails the deploy" "exit=1" "$out"
check "the failure says the image did not build" "did not build" "$out"
check "the failure says what is still running" "$old_version is still running" "$out"
refute "no container is replaced after a failed build" "up --detach" "$(cat "$fake/calls")"
check "no backup is taken for a build that failed" "0" "$(backups)"
check "the previous version stays pinned after a failed build" "RYKER_VERSION=$old_version" "$(cat "$state/compose.env")"
check "the worktree is removed after a failed build" "1" "$(worktrees)"

# ---------------------------------------------------------------------------
# A container that does not come up healthy.
seed
touch "$fake/archive.fail"
out=$(run)
check "a failed state archive aborts deployment" "exit=1" "$out"
check "a failed state archive restarts the existing controller" "start ryker" "$(cat "$fake/calls")"
refute "a failed state archive never replaces the container" "up --detach" "$(cat "$fake/calls")"
check "a failed state archive preserves the old pin" "RYKER_VERSION=$old_version" "$(cat "$state/compose.env")"
rm "$fake/archive.fail"

seed
touch "$fake/up.fail"
out=$(run)
check "a container that stays unhealthy fails the deploy" "exit=1" "$out"
check "the failure is named" "FAILED" "$out"
check "the container's logs are printed" "fake container log line" "$out"
check "the previous version stays pinned" "RYKER_VERSION=$old_version" "$(cat "$state/compose.env")"
check "the failure says what is still pinned" "still pins $old_version" "$out"
check "an unmigrated failure says the previous version can start again" "was not migrated" "$out"
check "the backup was taken before the failed replacement" "1" "$(backups)"
check "the worktree is removed after a failed deploy" "1" "$(worktrees)"
check_controller_stopped "an unhealthy replacement is stopped"

# A release that migrated the database before it failed: starting the
# previous version on that schema is refused, so the backup comes first.
seed
touch "$fake/up.fail" "$fake/up.migrates"
out=$(run)
check "a failed release that migrated names the migration" "migrated the database (from 20261005000000 to 20261006000000)" "$out"
check "a failed release that migrated says to restore first" "scripts/compose.sh restore before starting $old_version" "$out"
refute "a failed release that migrated does not offer a plain start" "was not migrated" "$out"

# ---------------------------------------------------------------------------
# A container that is healthy but serves other code than the commit.
seed
touch "$fake/up.stale"
out=$(run)
check "a version header that is not the commit fails the deploy" "exit=1" "$out"
check "the mismatch names the version that is serving" "version $old_version" "$out"
check "a mismatched version is not pinned" "RYKER_VERSION=$old_version" "$(cat "$state/compose.env")"
check_controller_stopped "a mismatched replacement is stopped"

# ---------------------------------------------------------------------------
# A container that is healthy and the right version but not ready.
seed
printf '503' >"$fake/readyz.code"
printf 'not ready: no_eligible_workers\n' >"$fake/readyz.body"
out=$(run)
check "a release that never becomes ready fails the deploy" "exit=1" "$out"
check "the failure carries the host's own readiness reason" "no_eligible_workers" "$out"
check "an unready release is not pinned" "RYKER_VERSION=$old_version" "$(cat "$state/compose.env")"
check_controller_stopped "an unready replacement is stopped"

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

# Lifecycle backup uses the same file custody and restores a paused controller
# on both success and failure, without starting one the operator had stopped.
seed
out=$(cd "$repo" && sh scripts/compose.sh backup 2>&1; echo "exit=$?")
check "lifecycle backup succeeds" "exit=0" "$out"
check "lifecycle backup resumes its writer" "start ryker" "$(cat "$fake/calls")"
# Ryker waited for the worker's whole archive, Coop's 12 GB of source caches included, and
# tenant's console answered 502 for seven minutes (2026-10-04).
calls=$(cat "$fake/calls")
start_line=$(grep -n ' start ryker' <<<"$calls" | head -n 1 | cut -d: -f1)
worker_line=$(grep -n 'entrypoint tar ryker-coop' <<<"$calls" | head -n 1 | cut -d: -f1)
if [[ -n $start_line && -n $worker_line && $start_line -lt $worker_line ]]; then
  printf 'ok   Ryker runs again before the worker is archived\n'
else
  printf 'FAIL Ryker runs again before the worker is archived\n     calls:\n%s\n' "$calls"
  failures=$((failures + 1))
fi
check "the worker archive leaves out Coop's job sources" "--exclude=coop/sessions/job-sources" "$calls"
check "the worker archive leaves out Coop's repository mirrors" "--exclude=coop/sessions/repositories" "$calls"
check "the worker archive leaves out earlier copies of its state" "--exclude=coop/sessions.*" "$calls"
check "the worker archive leaves out its temporary files" "--exclude=coop/tmp" "$calls"
backup=$(find "$state/backups" -name 'ryker-*.tar.gz' | head -n 1)
check "lifecycle backup includes encrypted state" "ryker-state.tar.gz" "$(tar -tzf "$backup")"

# Kept outside the backups directory, which each seed clears.
cp "$backup" "$work/whole-backup.tar.gz"
backup="$work/whole-backup.tar.gz"
legacy="$work/legacy-backup"
mkdir -p "$legacy"
tar -xzf "$backup" -C "$legacy" database.dump compose.env
tar -czf "$work/legacy.tar.gz" -C "$legacy" database.dump compose.env

# 2026-10-04 review: restore stopped Ryker and dropped the live database before it knew
# the archive could replace it, so a backup without its encrypted files, or a dump that
# did not read, left an empty or half-restored database and no copy of the old one. Both
# are refused before anything changes, and the restore goes beside the live database,
# which is swapped out only once the restore is whole.
seed
out=$(cd "$repo" && sh scripts/compose.sh restore "$work/legacy.tar.gz" 2>&1; echo "exit=$?")
check "a backup without its encrypted files is refused" "encrypted files" "$out"
check "a backup without its encrypted files fails" "exit=1" "$out"
refute "a refused backup stops nothing" "stop ryker" "$(cat "$fake/calls")"
refute "a refused backup drops nothing" "dropdb" "$(cat "$fake/calls")"

seed
touch "$fake/dump.unreadable"
out=$(cd "$repo" && sh scripts/compose.sh restore "$backup" 2>&1; echo "exit=$?")
rm "$fake/dump.unreadable"
check "a dump that does not read is refused" "cannot be read" "$out"
check "a dump that does not read fails" "exit=1" "$out"
refute "an unreadable dump stops nothing" "stop ryker" "$(cat "$fake/calls")"
refute "an unreadable dump drops nothing" "dropdb" "$(cat "$fake/calls")"

seed
touch "$fake/restore.fail"
out=$(cd "$repo" && sh scripts/compose.sh restore "$backup" 2>&1; echo "exit=$?")
rm "$fake/restore.fail"
check "a restore that fails keeps the previous database" "previous database is unchanged" "$out"
check "a restore that fails exits 1" "exit=1" "$out"
refute "a failed restore never renames the live database" "ALTER DATABASE ryker RENAME" "$(cat "$fake/calls")"

seed
out=$(cd "$repo" && sh scripts/compose.sh restore "$backup" 2>&1; echo "exit=$?")
check "a whole restore succeeds" "exit=0" "$out"
check "a whole restore keeps the replaced database" "ALTER DATABASE ryker RENAME TO ryker_before_restore" "$(cat "$fake/calls")"
check "a whole restore swaps the restored database in" "ALTER DATABASE ryker_restoring RENAME TO ryker" "$(cat "$fake/calls")"
check "a restore starts the pinned image without building" "up --detach --no-build --wait ryker" "$(cat "$fake/calls")"

# 2026-10-04 review: restore kept the current pin, so restoring the backup taken before a
# deploy started the new release on the old rows, which it migrated forward again. A
# backup from another release pins that release, and one whose image this host lacks is
# refused before anything changes.
seed
pin_line() { sed -n "s/^RYKER_VERSION=//p" "$state/compose.env"; }
sed -i.bak "s/^RYKER_VERSION=.*/RYKER_VERSION=$version/; s/^RYKER_IMAGE=.*/RYKER_IMAGE=ryker:$version/" "$state/compose.env"
touch "$fake/image.missing"
out=$(cd "$repo" && sh scripts/compose.sh restore "$backup" 2>&1; echo "exit=$?")
check "a backup whose release this host lacks is refused" "is not on this host" "$out"
check "a refused restore names the pinned release" "pins $version" "$out"
refute "a restore refused for its release stops nothing" "stop ryker" "$(cat "$fake/calls")"
check "a refused restore keeps the pin" "$version" "$(pin_line)"
rm "$fake/image.missing"
out=$(cd "$repo" && sh scripts/compose.sh restore "$backup" 2>&1; echo "exit=$?")
check "a backup from another release restores" "exit=0" "$out"
check "the backup's release is pinned" "$old_version" "$(pin_line)"
check "the restore says which release it pinned" "Pinned Ryker $old_version" "$out"
check "the backup's release starts" "PINNED=$old_version" "$(tail -n 1 "$fake/up.env")"

# 2026-10-04 review: the project's name is fixed, so an install or restore from a second
# checkout acted on the live project. With no compose.env here, an existing database volume
# refuses both before anything changes.
seed
rm "$state/compose.env"
touch "$fake/volume.exists"
out=$(cd "$repo" && sh scripts/compose.sh install 2>&1; echo "exit=$?")
check "an install beside another checkout's installation is refused" "installed on this host from another checkout" "$out"
check "a refused install fails" "exit=1" "$out"
refute "a refused install writes no keys" "RYKER_GENERATED_ENV" "$(cat "$state/compose.env" 2>/dev/null)"
refute "a refused install starts nothing" "up --detach" "$(cat "$fake/calls" 2>/dev/null)"
out=$(cd "$repo" && sh scripts/compose.sh restore "$backup" 2>&1; echo "exit=$?")
check "a restore beside another checkout's installation is refused" "installed on this host from another checkout" "$out"
refute "a refused restore drops nothing" "dropdb" "$(cat "$fake/calls" 2>/dev/null)"
refute "a refused restore writes no keys" "RYKER_GENERATED_ENV" "$(cat "$state/compose.env" 2>/dev/null)"

# 2026-10-04 review: start, restart and restore built whatever the checkout held when the
# pinned image was missing, and upgrade built a dirty checkout under the pinned version.
seed
out=$(cd "$repo" && sh scripts/compose.sh start 2>&1; echo "exit=$?")
check "start succeeds" "exit=0" "$out"
check "start never builds" "up --detach --no-build --wait" "$(cat "$fake/calls")"
refute "start lets go of the lifecycle lock" "lifecycle.lock" "$(find "$state" -maxdepth 1 -name lifecycle.lock)"
seed
out=$(cd "$repo" && sh scripts/compose.sh restart 2>&1; echo "exit=$?")
check "restart never builds" "up --detach --no-build --wait" "$(cat "$fake/calls")"

seed
touch "$repo/uncommitted-change"
out=$(cd "$repo" && sh scripts/compose.sh install 2>&1; echo "exit=$?")
check "install over an installation refuses a dirty checkout" "Commit or discard them first" "$out"
refute "a refused reinstall builds nothing" " build" "$(cat "$fake/calls" 2>/dev/null)"
seed
out=$(cd "$repo" && sh scripts/compose.sh upgrade 2>&1; echo "exit=$?")
rm "$repo/uncommitted-change"
check "upgrade refuses a dirty checkout" "Commit or discard them first" "$out"
check "upgrade of a dirty checkout fails" "exit=1" "$out"
refute "a refused upgrade builds nothing" " build " "$(cat "$fake/calls")"

seed
touch "$fake/archive.fail"
out=$(cd "$repo" && sh scripts/compose.sh backup 2>&1; echo "exit=$?")
check "lifecycle archive failure is reported" "exit=1" "$out"
check "lifecycle archive failure resumes its writer" "start ryker" "$(cat "$fake/calls")"
rm "$fake/archive.fail"

# A file the running worker changed while it was archived ended every backup
# taken during work (2026-10-04 review); a worker that cannot be read still fails.
seed
touch "$fake/worker.changed"
out=$(cd "$repo" && sh scripts/compose.sh backup 2>&1; echo "exit=$?")
rm "$fake/worker.changed"
check "a backup taken while the worker writes succeeds" "exit=0" "$out"
seed
touch "$fake/worker.unreadable"
out=$(cd "$repo" && sh scripts/compose.sh backup 2>&1; echo "exit=$?")
rm "$fake/worker.unreadable"
check "a worker that cannot be archived fails the backup" "exit=2" "$out"
check "a failed worker archive still resumes Ryker" "start ryker" "$(cat "$fake/calls")"

seed
touch "$fake/controller.stopped"
out=$(cd "$repo" && sh scripts/compose.sh backup 2>&1; echo "exit=$?")
check "an already stopped controller can be backed up" "exit=0" "$out"
refute "backup preserves the operator's stopped controller" "start ryker" "$(cat "$fake/calls")"
rm "$fake/controller.stopped"

# A worker image named in compose.env is a supplied build: on 2026-09-28 the
# bundled worker ran Coop 126f5d07, built from a Coop checkout ahead of the
# Dockerfile's pin, and that Coop had already moved the worker's session
# store to a schema the pinned Coop refuses. Building ryker-coop there tags
# the pin's image with the supplied name, and the restart that follows takes
# the worker down with no way back but a restore.
seed
printf 'RYKER_COOP_IMAGE=ryker-coop:supplied\n' >>"$state/compose.env"
out=$(cd "$repo" && sh scripts/compose.sh upgrade 2>&1; echo "exit=$?")
check "upgrade with a supplied worker image succeeds" "exit=0" "$out"
check "upgrade still builds Ryker" "build --pull ryker" "$(cat "$fake/calls")"
refute "upgrade leaves a supplied worker image alone" "ryker-coop" "$(grep ' build ' "$fake/calls")"

seed
out=$(cd "$repo" && sh scripts/compose.sh upgrade 2>&1; echo "exit=$?")
check "upgrade without a supplied worker image succeeds" "exit=0" "$out"
check "upgrade builds the worker from the pin" "build --pull ryker ryker-coop" "$(cat "$fake/calls")"

# ---------------------------------------------------------------------------
# One lifecycle command at a time (2026-10-04 review): two deploys, or a backup
# beside a restore, each stopped and started the one project under the other.
seed
mkdir -p "$state/lifecycle.lock"
printf '%s backup\n' "$$" >"$state/lifecycle.lock/owner"
out=$(run)
check "a running lifecycle command refuses a deploy" "Another Ryker lifecycle command is running" "$out"
check "a refused deploy exits 1" "exit=1" "$out"
refute "a refused deploy builds nothing" " build " "$(cat "$fake/calls" 2>/dev/null)"
out=$(cd "$repo" && sh scripts/compose.sh start 2>&1; echo "exit=$?")
check "a running lifecycle command refuses start" "Another Ryker lifecycle command is running" "$out"
check "a refused command leaves the holder's lock" "backup" "$(cat "$state/lifecycle.lock/owner")"

# A lock whose process is gone is taken over, and a finished deploy lets go.
sleep 0 &
dead=$!
wait "$dead"
printf '%s deploy\n' "$dead" >"$state/lifecycle.lock/owner"
out=$(run)
check "a lock left by a process that is gone is taken over" "exit=0" "$out"
if [[ -e $state/lifecycle.lock ]]; then
  printf 'FAIL a finished deploy releases the lock\n'
  failures=$((failures + 1))
else
  printf 'ok   a finished deploy releases the lock\n'
fi

if [[ $failures -gt 0 ]]; then
  echo "$failures deploy check(s) failed"
  exit 1
fi
echo "deploy self-test passed"
