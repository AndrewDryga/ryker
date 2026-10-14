#!/bin/bash
# Proves scripts/auto-upgrade.sh upgrades an install when the branch it follows moves, and only
# then: forward only, after a backup, moving the worker when the commit pins another Coop, and
# putting everything back when the upgrade fails, without trying that commit again.
#
# On 2026-10-14 each upgrade of the tenant install needed a Tailscale profile switch, an approval
# only Andrew could give, and step scripts whose SSH exit status was 0 even when they failed.
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
refute() {
  local what="$1" unwanted="$2" actual="$3"
  if [[ $actual == *"$unwanted"* ]]; then
    printf 'FAIL %s\n     unwanted: %s\n     got:      %s\n' "$what" "$unwanted" "$actual"
    failures=$((failures + 1))
  else
    printf 'ok   %s\n' "$what"
  fi
}

# An origin, a source checkout that pushes to it, and the install's checkout, whose compose.sh
# records each call and fails one when the file its name says exists.
git init -q --bare "$work/origin.git"
source=$work/source
git init -q -b main "$source"
s() { git -C "$source" -c user.email=up@example.com -c user.name=up -c commit.gpgsign=false "$@"; }
mkdir -p "$source/scripts" "$source/deploy/compose/coop"
cp "$root/scripts/auto-upgrade.sh" "$root/scripts/compose-lifecycle.sh" "$source/scripts/"
cat >"$source/scripts/compose.sh" <<'FAKE'
#!/bin/sh
echo "compose.sh $*" >>"$UPGRADE_TEST_STATE/calls"
[ "$1" = backup ] && touch "$RYKER_INSTALL_STATE/backups/backup-$(date +%s%N).tar.gz"
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
printf 'RYKER_UPGRADE_REF=tenant/test\n' >"$work/state/compose.env"

upgrade() {
  : >"$work/calls"
  (cd "$install" && UPGRADE_TEST_STATE="$work" RYKER_INSTALL_STATE="$work/state" \
    RYKER_UPGRADE_STATE="$work/upgrades" scripts/auto-upgrade.sh >"$work/out" 2>&1)
  echo "exit=$?" >>"$work/out"
}
head_of() { git -C "$install" rev-parse HEAD; }

upgrade
check "a branch that has not moved changes nothing" "" "$(cat "$work/calls")"
check "and succeeds" "exit=0" "$(cat "$work/out")"

s commit -q --allow-empty -m second
s push -q origin main:tenant/test
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

s commit -q --allow-empty -m broken
s push -q origin main:tenant/test
broken=$(s rev-parse HEAD)
before=$(head_of)
touch "$work/upgrade.fail"
upgrade
check "a failed upgrade fails" "exit=1" "$(cat "$work/out")"
check "and restores the backup it took" "compose.sh restore $work/state/backups/backup-" "$(cat "$work/calls")"
check "and puts the checkout back" "$before" "$(head_of)"
check "and says so" "FAILED ${broken:0:12}: the upgrade failed; restored" "$(cat "$work/out")"
rm "$work/upgrade.fail"
upgrade
check "the commit that failed is not tried again" "" "$(cat "$work/calls")"

s commit -q --allow-empty -m fixed
s push -q origin main:tenant/test
fixed=$(s rev-parse HEAD)
upgrade
check "the next move of the branch is" "$fixed" "$(head_of)"

s reset -q --hard HEAD~1
s commit -q --allow-empty -m elsewhere
s push -q -f origin main:tenant/test
upgrade
check "a branch that does not build on what runs is refused" "does not build on" "$(cat "$work/out")"
check "and nothing is changed" "$fixed" "$(head_of)"

if ((failures > 0)); then
  echo "auto-upgrade_test: $failures failure(s)"
  sed 's/^/  out: /' "$work/out"
  exit 1
fi
echo "auto-upgrade_test: all checks passed"
