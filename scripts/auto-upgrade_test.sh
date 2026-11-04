#!/bin/bash
# Proves scripts/auto-upgrade.sh upgrades an install when the branch it follows moves, and only
# then: forward only, through the canonical deploy, with no automatic snapshot or restore. A
# failed upgrade restores the previous source/pin only; stopped releases need explicit recovery. A commit whose upgrade failed before anything changed is tried again
# half an hour later; one that stopped the release is not. A worker that did not move is asked
# again every half hour until it has.
#
# On 2026-10-14 each upgrade of the tenant install needed a Tailscale profile switch, an approval
# only Andrew could give, and step scripts whose SSH exit status was 0 even when they failed.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
server_pid=
cleanup() {
  [[ -z $server_pid ]] || { kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null; }
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

# A stand-in console: /readyz answers with the code and version files name.
mkdir -p "$work/console"
cat >"$work/server.py" <<'PY'
import http.server, os, sys
base = sys.argv[1]
def read(name, default):
    try:
        with open(os.path.join(base, name)) as handle:
            return handle.read().strip()
    except FileNotFoundError:
        return default
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(int(read("code", "200")))
        self.send_header("x-ryker-version", read("version", "old"))
        self.end_headers()
        self.wfile.write(b"ready\n")
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
open(os.path.join(base, "port"), "w").write(str(server.server_address[1]))
server.serve_forever()
PY
python3 "$work/server.py" "$work/console" &
server_pid=$!
for _ in $(seq 1 50); do [[ -s $work/console/port ]] && break; sleep 0.1; done

# An origin, a source checkout that pushes to it, and the install's checkout, whose compose.sh
# records each call, pins a new release on upgrade as the real one does, and fails a command when
# the file its name says exists.
git init -q --bare "$work/origin.git"
source=$work/source
git init -q -b main "$source"
s() { git -C "$source" -c user.email=up@example.com -c user.name=up -c commit.gpgsign=false "$@"; }
mkdir -p "$source/scripts" "$source/deploy/compose/coop"
cp "$root/scripts/auto-upgrade.sh" "$root/scripts/compose-lifecycle.sh" "$source/scripts/"
cat >"$source/scripts/compose.sh" <<'FAKE'
#!/bin/sh
echo "compose.sh $*" >>"$UPGRADE_TEST_STATE/calls"
case $1 in
  backup)
    n=$(($(cat "$UPGRADE_TEST_STATE/backups.count" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$UPGRADE_TEST_STATE/backups.count"
    archive="$RYKER_INSTALL_STATE/backups/ryker-20261015T0000$(printf '%02d' "$n")Z.tar.gz"
    touch "$archive"
    echo "$archive"
    ;;
  upgrade)
    sed 's/^RYKER_VERSION=.*/RYKER_VERSION=new/' "$RYKER_INSTALL_STATE/compose.env" >"$RYKER_INSTALL_STATE/env.new"
    mv "$RYKER_INSTALL_STATE/env.new" "$RYKER_INSTALL_STATE/compose.env"
    ;;
esac
[ -f "$UPGRADE_TEST_STATE/$1.fail" ] && exit 1
exit 0
FAKE
cat >"$source/scripts/deploy.sh" <<'FAKE'
#!/bin/sh
echo "deploy.sh $*" >>"$UPGRADE_TEST_STATE/calls"
# Match the canonical deploy's local-main guard. A configured upgrade ref is
# already authorized by the operator and may be checked out on its own branch.
if [ "$(git rev-parse HEAD)" != "$(git rev-parse refs/heads/main)" ] && [ "${1:-}" != --allow-not-main ]; then
  exit 1
fi
[ -f "$UPGRADE_TEST_STATE/upgrade.fail" ] && exit 1
sed 's/^RYKER_VERSION=.*/RYKER_VERSION=new/' "$RYKER_INSTALL_STATE/compose.env" >"$RYKER_INSTALL_STATE/env.new"
mv "$RYKER_INSTALL_STATE/env.new" "$RYKER_INSTALL_STATE/compose.env"
if [ -f "$UPGRADE_TEST_STATE/acceptance.fail" ]; then
  echo new >"$UPGRADE_TEST_STATE/console/version"
  exit 1
fi
FAKE
chmod 0755 "$source/scripts/deploy.sh"
chmod 0755 "$source/scripts/compose.sh"
cat >"$source/scripts/worker_pool.py" <<'PY'
import os, pathlib, sys
root = pathlib.Path(os.environ["UPGRADE_TEST_STATE"])
with (root / "calls").open("a") as stream:
    stream.write("worker_pool.py " + " ".join(sys.argv[1:]) + "\n")
sys.exit(1 if (root / "pool-upgrade.fail").exists() else 0)
PY
printf 'ARG COOP_REVISION=%s\n' aaaa >"$source/deploy/compose/coop/Dockerfile"
s add -A && s commit -q -m first
s remote add origin "$work/origin.git"
s push -q origin main main:tenant/test

install=$work/install
git clone -q "$work/origin.git" "$install" -b main
git -C "$install" checkout -q -b tenant/test origin/tenant/test
mkdir -p "$work/state/backups"
pin_old() {
  printf 'RYKER_UPGRADE_REF=tenant/test\nRYKER_VERSION=old\nRYKER_IMAGE=ryker:old\nRYKER_CONTROL_PORT=%s\n' \
    "$(cat "$work/console/port")" >"$work/state/compose.env"
}
pin_old

upgrade() {
  : >"$work/calls"
  (cd "$install" && UPGRADE_TEST_STATE="$work" RYKER_INSTALL_STATE="$work/state" \
    RYKER_UPGRADE_STATE="$work/upgrades" RYKER_UPGRADE_RETRY_SECONDS="${retry_seconds:-1800}" \
    scripts/auto-upgrade.sh >"$work/out" 2>&1)
  echo "exit=$?" >>"$work/out"
}
head_of() { git -C "$install" rev-parse HEAD; }
push() {
  s commit -q --allow-empty -m "$1"
  s push -q origin main:tenant/test
}

upgrade
check "a branch that has not moved changes nothing" "" "$(cat "$work/calls")"
check "and succeeds" "exit=0" "$(cat "$work/out")"

push second
second=$(s rev-parse HEAD)
upgrade
check "a moved branch is upgraded to" "$second" "$(head_of)"
check "a configured branch can use the canonical deploy" "deploy.sh --allow-not-main" "$(cat "$work/calls")"
refute "automatic upgrades never create a snapshot" "compose.sh backup" "$(cat "$work/calls")"
check "and the worker is asked to run the Coop it pins" "deploy.sh --allow-not-main"$'\n'"compose.sh worker-upgrade" "$(cat "$work/calls")"
check "and the upgrade is recorded" "-> ${second:0:12}" "$(grep ' upgraded ' "$work/upgrades/upgrades.log")"

printf 'ARG COOP_REVISION=%s\n' bbbb >"$source/deploy/compose/coop/Dockerfile"
s commit -q -am "newer Coop"
s push -q origin main:tenant/test
upgrade
check "a commit that pins another Coop moves the worker too" "compose.sh worker-upgrade" "$(cat "$work/calls")"

# An image that did not build: the release before still serves, so only the pin goes back.
pin_old
push "does not build"
unbuilt=$(s rev-parse HEAD)
before=$(head_of)
touch "$work/upgrade.fail"
upgrade
check "a failed upgrade fails" "exit=1" "$(cat "$work/out")"
check "and puts the checkout back" "$before" "$(head_of)"
check "and the pin" "RYKER_VERSION=old" "$(cat "$work/state/compose.env")"
refute "and restores nothing while the release before serves" "compose.sh restore" "$(cat "$work/calls")"
check "and says so" "FAILED ${unbuilt:0:12}: the upgrade failed before it replaced old, which still runs" "$(cat "$work/out")"
rm "$work/upgrade.fail"
upgrade
check "the commit that failed is not tried again within the half hour" "" "$(cat "$work/calls")"
# The tenant install's upgrade broke off on 2026-10-17 when Docker Hub's TLS handshake timed out,
# with nothing changed, and the install kept the release before until somebody pushed again.
retry_seconds=0 upgrade
check "but after it, since nothing had changed" "$unbuilt" "$(head_of)"
check "and its upgrade is recorded" "upgraded ${before:0:12} -> ${unbuilt:0:12}" "$(cat "$work/out")"
before=$(head_of)

# A stopped release needs explicit recovery; automation must not roll its database back.
pin_old
push "does not migrate"
unmigrated=$(s rev-parse HEAD)
touch "$work/upgrade.fail"
printf '503' >"$work/console/code"
upgrade
refute "a failed migration never restores data automatically" "compose.sh restore" "$(cat "$work/calls")"
check "the stopped release names explicit recovery" "deploy a fixed release or restore a manual backup" "$(cat "$work/out")"
check "and puts the checkout back too" "$before" "$(head_of)"
rm "$work/upgrade.fail" "$work/console/code"
retry_seconds=0 upgrade
check "a commit whose upgrade stopped the release is not tried again, even after the half hour" "" "$(cat "$work/calls")"
check "and the checkout stays where it was" "$before" "$(head_of)"
refute "nor is it ever recorded as upgraded" "${unmigrated:0:12}" "$(grep ' upgraded ' "$work/upgrades/upgrades.log")"

# A worker that does not move leaves Ryker on the new release.
pin_old
printf 'ARG COOP_REVISION=%s\n' cccc >"$source/deploy/compose/coop/Dockerfile"
s commit -q -am "another Coop"
s push -q origin main:tenant/test
coop=$(s rev-parse HEAD)
touch "$work/worker-upgrade.fail"
upgrade
check "a worker upgrade that fails is said" "the worker upgrade failed" "$(cat "$work/out")"
check "and Ryker stays on the new release" "$coop" "$(head_of)"
refute "and nothing is restored" "compose.sh restore" "$(cat "$work/calls")"
rm "$work/worker-upgrade.fail"
upgrade
check "a worker that did not move is left alone for half an hour" "" "$(cat "$work/calls")"
# The tenant install's download of Coop broke off after 397 s on 2026-10-17; without a retry
# its worker kept the Coop it ran until somebody pushed again.
retry_seconds=0 upgrade
check "and asked again after it, with nothing new to upgrade" "compose.sh worker-upgrade" "$(cat "$work/calls")"
check "and its move is recorded" "the worker moved to the Coop ${coop:0:12} pins" "$(cat "$work/out")"
retry_seconds=0 upgrade
check "a worker that moved is not asked again" "" "$(cat "$work/calls")"
touch "$work/worker-upgrade.fail"
push "same Coop"
upgrade
check "a worker that did not move is moved by the next upgrade" "compose.sh worker-upgrade" "$(cat "$work/calls")"
retry_seconds=0 upgrade
check "and asked again while it fails" "the worker upgrade failed again" "$(cat "$work/out")"
rm "$work/worker-upgrade.fail"
retry_seconds=0 upgrade
check "until it moves" "the worker moved to the Coop" "$(cat "$work/out")"

mkdir -p "$work/state/worker-pool"
printf '{}\n' >"$work/state/worker-pool/state.json"
touch "$work/pool-upgrade.fail"
push "pool update"
upgrade
check "an installed separate pool is upgraded after the retained worker" "worker_pool.py upgrade" "$(cat "$work/calls")"
check "a failed pool upgrade keeps the retry marker" "yes" "$([[ -f $work/upgrades/worker-behind ]] && echo yes || echo no)"
rm "$work/pool-upgrade.fail"
retry_seconds=0 upgrade
check "the separate pool is retried without another controller deploy" "worker_pool.py upgrade" "$(cat "$work/calls")"
refute "retrying the pool does not take another controller backup" "compose.sh backup" "$(cat "$work/calls")"
rm "$work/state/worker-pool/state.json"
rmdir "$work/state/worker-pool"

# The daily backup holds the lifecycle lock: this round waits for the next.
sleep 30 &
holder=$!
mkdir -p "$work/state/lifecycle.lock" && echo "$holder backup" >"$work/state/lifecycle.lock/owner"
push "while a backup runs"
waiting=$(s rev-parse HEAD)
upgrade
check "an install that is busy is left for the next round" "" "$(cat "$work/calls")"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
rm -rf "$work/state/lifecycle.lock"
upgrade
check "and upgraded once it is free" "$waiting" "$(head_of)"

printf "manual snapshot\n" >"$work/state/backups/ryker-latest.tar.gz"
for _ in 1 2 3 4 5 6; do
  push more
  upgrade
done
check "repeated automatic upgrades create no backups" "1" "$(find "$work/state/backups" -name '*.tar.gz' | wc -l | tr -d ' ')"
check "automatic upgrades preserve the manual snapshot" "manual snapshot" "$(cat "$work/state/backups/ryker-latest.tar.gz")"

# Canonical deploy may serve and pin the new release, then fail live acceptance.
# Never roll source back or call that ready release stopped.
pin_old
push "ready but acceptance fails"
accepted=$(s rev-parse HEAD)
touch "$work/acceptance.fail"
upgrade
check "failed live acceptance stays a failure" "exit=1" "$(cat "$work/out")"
check "a ready new release keeps its source after acceptance fails" "$accepted" "$(head_of)"
check "and keeps its new pin" "RYKER_VERSION=new" "$(cat "$work/state/compose.env")"
check "and reports the running release and failed checks" "new is running, but deployment checks failed; source and pin kept" "$(cat "$work/out")"
check "its pending worker upgrade remains retryable" "yes" "$([[ -f $work/upgrades/worker-behind ]] && echo yes || echo no)"
refute "no database is restored after acceptance fails" "compose.sh restore" "$(cat "$work/calls")"
rm "$work/acceptance.fail" "$work/console/version"

last=$(head_of)
s reset -q --hard HEAD~1
s commit -q --allow-empty -m elsewhere
s push -q -f origin main:tenant/test
upgrade
check "a branch that does not build on what runs is refused" "does not build on" "$(cat "$work/out")"
check "and nothing is changed" "$last" "$(head_of)"

if ((failures > 0)); then
  echo "auto-upgrade_test: $failures failure(s)"
  sed 's/^/  out: /' "$work/out"
  exit 1
fi
echo "auto-upgrade_test: all checks passed"
