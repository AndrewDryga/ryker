#!/bin/bash
# Proves scripts/auto-upgrade.sh upgrades an install when the branch it follows moves, and only
# then: forward only, after a backup, moving the worker when the commit pins another Coop. A
# failed upgrade puts the checkout and the pin back, restores the backup only when the release
# before no longer serves, and that commit is not tried again.
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
chmod 0755 "$source/scripts/compose.sh"
printf 'ARG COOP_REVISION=%s\n' aaaa >"$source/deploy/compose/coop/Dockerfile"
s add -A && s commit -q -m first
s remote add origin "$work/origin.git"
s push -q origin main main:tenant/test

install=$work/install
git clone -q "$work/origin.git" "$install" -b main
mkdir -p "$work/state/backups"
pin_old() {
  printf 'RYKER_UPGRADE_REF=tenant/test\nRYKER_VERSION=old\nRYKER_IMAGE=ryker:old\nRYKER_CONTROL_PORT=%s\n' \
    "$(cat "$work/console/port")" >"$work/state/compose.env"
}
pin_old

upgrade() {
  : >"$work/calls"
  (cd "$install" && UPGRADE_TEST_STATE="$work" RYKER_INSTALL_STATE="$work/state" \
    RYKER_UPGRADE_STATE="$work/upgrades" scripts/auto-upgrade.sh >"$work/out" 2>&1)
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
check "after a backup" "compose.sh backup"$'\n'"compose.sh upgrade" "$(cat "$work/calls")"
refute "the worker stays while its pin does" "worker-upgrade" "$(cat "$work/calls")"
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
check "the commit that failed is not tried again" "" "$(cat "$work/calls")"

# A migration that failed: the release before no longer serves, so the backup comes back.
push "does not migrate"
touch "$work/upgrade.fail"
printf '503' >"$work/console/code"
upgrade
check "a failed upgrade that stopped the release restores the backup it took" \
  "compose.sh restore $work/state/backups/pre-upgrade-" "$(cat "$work/calls")"
check "and puts the checkout back too" "$before" "$(head_of)"
rm "$work/upgrade.fail" "$work/console/code"

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

for _ in 1 2 3 4 5 6; do
  push more
  upgrade
done
check "only the newest five upgrade backups stay" "5" "$(find "$work/state/backups" -name 'pre-upgrade-*' | wc -l | tr -d ' ')"

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
