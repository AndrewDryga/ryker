#!/bin/bash
# Proves scripts/doctor.sh finds the faults it names and that --fix repairs the safe ones, against
# a fake Docker: test databases a stopped run left, a lock a dead gate left, a dependencies
# directory turned into a link, and a worker behind the Coop the Dockerfile pins.
#
# Each was a recovery an agent had to find in a note and follow by hand; five databases were left
# behind on 2026-10-14 alone.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

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

repo=$work/repo
mkdir -p "$repo/scripts" "$repo/deploy/compose/coop" "$repo/.ryker" "$repo/deps" "$work/bin"
cp "$root/scripts/doctor.sh" "$root/scripts/compose-lifecycle.sh" "$repo/scripts/"
printf 'ARG COOP_REVISION=1234abcd%s\n' "$(printf '0%.0s' $(seq 1 32))" >"$repo/deploy/compose/coop/Dockerfile"
printf 'RYKER_VERSION=1\n' >"$repo/.ryker/compose.env"
git -C "$repo" init -q

# A live PID and one that is gone, for the databases' names.
sleep 30 &
live=$!
sleep 0 &
gone=$!
wait "$gone"

cat >"$work/bin/docker" <<FAKE
#!/bin/bash
printf '%s\n' "\$*" >>"$work/calls"
case "\$*" in
  info) ;;
  *"SHOW max_connections"*) echo 500 ;;
  *"SELECT datname"*) printf 'ryker_test_${gone}_1_p0\nryker_test_${gone}_1_p1\nryker_test_${live}_2\n' ;;
  *"state = 'working'"*) echo 0 ;;
  *pg_stat_activity*) echo 0 ;;
  *"compose --env-file"*"ps --all"*) echo "ryker-coop ryker-coop:old" ;;
esac
FAKE
chmod 0755 "$work/bin/docker"
# The watchdog's launch agent is there.
printf '#!/bin/sh\nexit 0\n' >"$work/bin/launchctl"
chmod 0755 "$work/bin/launchctl"

doctor() {
  (cd "$repo" && PATH="$work/bin:$PATH" RYKER_GATE_LOCK="$work/gate.lock" scripts/doctor.sh "$@" 2>&1
    echo "exit=$?")
}

mkdir "$work/gate.lock" && echo "$gone" >"$work/gate.lock/pid"
mv "$repo/deps" "$work/real-deps" && ln -s "$work/real-deps" "$repo/deps"

out=$(doctor)
check "databases a stopped run left are found" "2 test databases were left by runs that are gone" "$out"
check "a lock a dead gate left is found" "a gate that is gone left its lock" "$out"
check "a dependencies link is found" "deps is a link, not a directory" "$out"
check "a worker behind its recipe is named" "the worker runs ryker-coop:old, its recipe names ryker-coop:1234abcd-" "$out"
check "and the doctor fails" "exit=1" "$out"

: >"$work/calls"
rm "$repo/deps" && mkdir "$repo/deps"
out=$(doctor --fix)
check "the left databases are dropped" "dropped 2 test databases" "$out"
check "the first by name" "DROP DATABASE IF EXISTS \"ryker_test_${gone}_1_p0\" WITH (FORCE)" "$(cat "$work/calls")"
if grep -q "ryker_test_${live}_2\" WITH" "$work/calls"; then
  printf 'FAIL a running test'"'"'s database is never dropped\n'
  failures=$((failures + 1))
else
  printf 'ok   a running test'"'"'s database is never dropped\n'
fi
check "the dead gate's lock is removed" "removed the lock a gate that is gone left" "$out"
check "the lock is gone" "absent" "$([[ -e $work/gate.lock ]] && echo present || echo absent)"
check "the worker is still only named" "scripts/compose.sh worker-upgrade" "$out"

kill "$live" 2>/dev/null
wait "$live" 2>/dev/null
if ((failures > 0)); then
  echo "doctor_test: $failures failure(s)"
  exit 1
fi
echo "doctor_test: all checks passed"
