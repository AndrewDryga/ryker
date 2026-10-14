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
# Off a Mac, as in CI, there is no plutil to lint the plist; plistlib reads it below either way.
if ! command -v plutil >/dev/null 2>&1; then
  printf '#!/bin/sh\nexit 0\n' >"$work/bin/plutil"
  chmod 0755 "$work/bin/plutil"
fi

install() {
  HOME="$work/home" PATH="$work/bin:$PATH" KEEP_AWAKE_TEST_STATE="$work" \
    "$root/scripts/install-keep-awake.sh" >"$work/out" 2>&1
}

install
check "the install succeeds" 0 "$?"
plist="$work/home/Library/LaunchAgents/ai.emisar.ryker.awake.plist"
# A key of the plist as launchd reads it, as JSON.
value() {
  python3 -c 'import json, plistlib, sys
with open(sys.argv[1], "rb") as handle:
    print(json.dumps(plistlib.load(handle)[sys.argv[2]]))' "$plist" "$1" 2>/dev/null
}
check "the agent holds off idle sleep, and any sleep on power" \
  '["/usr/bin/caffeinate", "-i", "-s"]' "$(value ProgramArguments)"
check "the agent starts at login" true "$(value RunAtLoad)"
check "the agent starts again whenever it stops" true "$(value KeepAlive)"
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
