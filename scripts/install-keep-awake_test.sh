#!/bin/bash
# Proves scripts/install-keep-awake.sh leaves a launch agent that keeps the Mac awake from login
# on, through restarts.
#
# 2026-10-14: the Mac hosting a tenant install stayed awake only because someone had started
# `caffeinate -dis` in a terminal 43 days before. On battery it sleeps after a minute, so after any
# restart a short power cut would have put the install to sleep, with nothing to wake it when the
# power came back, and no message answered until someone did.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
check() {
  local what="$1" expected="$2" actual="$3"
  if [[ $actual == "$expected" ]]; then
    printf 'ok   %s\n' "$what"
  else
    printf 'FAIL %s\n     wanted: %s\n     got:    %s\n' "$what" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

# A stand-in launchctl: an agent is registered once it is bootstrapped.
mkdir -p "$work/bin" "$work/home"
cat >"$work/bin/launchctl" <<'FAKE'
#!/bin/bash
state=$KEEP_AWAKE_TEST_STATE
echo "$*" >>"$state/calls"
case $1 in
  print) [[ -e $state/registered ]] || exit 113 ;;
  bootout) rm -f "$state/registered" ;;
  bootstrap) touch "$state/registered" ;;
esac
FAKE
chmod 0755 "$work/bin/launchctl"

install() {
  HOME="$work/home" PATH="$work/bin:$PATH" KEEP_AWAKE_TEST_STATE="$work" \
    "$root/scripts/install-keep-awake.sh" >"$work/out" 2>&1
}

install
check "the install succeeds" 0 "$?"
plist="$work/home/Library/LaunchAgents/ai.emisar.ryker.awake.plist"
value() { /usr/bin/plutil -extract "$1" "$2" -o - "$plist" 2>/dev/null; }
check "the agent holds off idle sleep, and any sleep on power" \
  '["/usr/bin/caffeinate","-i","-s"]' "$(value ProgramArguments json | sed 's#\\/#/#g')"
check "the agent starts at login" true "$(value RunAtLoad raw)"
check "the agent starts again whenever it stops" true "$(value KeepAlive raw)"
check "the agent is registered" "bootstrap gui/$(id -u) $plist" "$(grep bootstrap "$work/calls")"

# Running the install again replaces the agent rather than failing on the one that runs.
install
check "a second install succeeds" 0 "$?"
check "a second install reloads the agent" 2 "$(grep -c bootstrap "$work/calls")"

if ((failures > 0)); then
  echo "install-keep-awake_test: $failures failure(s)"
  sed 's/^/  out: /' "$work/out"
  exit 1
fi
echo "install-keep-awake_test: all checks passed"
