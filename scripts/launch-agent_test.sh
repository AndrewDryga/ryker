#!/bin/bash
# Proves scripts/launch-agent.sh reloads a running agent, and refuses to call
# an agent installed when launchd dropped it.
#
# The reload case reproduces 2026-09-30: re-running the local routing model's
# install booted the running agent out and bootstrapped it at once, while its
# server was still letting go of the GPU; launchd answered "5: Input/output
# error", the install stopped half way, and the model it had just restarted
# stayed stopped. Every install script had the same two lines.
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

# A stand-in launchctl. An agent is registered while $state/registered exists.
# Booting it out removes that file, but the agent stays registered for as many
# more `print`s as $state/exiting says, the way a server that is still exiting
# does; bootstrapping a registered label fails as launchd's does. With
# $state/drops, launchd accepts a bootstrap and registers nothing.
state="$work/state"
mkdir -p "$state" "$work/bin"
cat >"$work/bin/launchctl" <<'FAKE'
#!/bin/bash
state=$LAUNCHCTL_STATE
echo "$*" >>"$state/calls"
still_exiting() {
  local left
  left=$(cat "$state/exiting" 2>/dev/null || echo 0)
  if ((left > 0)); then
    echo $((left - 1)) >"$state/exiting"
    return 0
  fi
  return 1
}
case $1 in
  print)
    [[ -e $state/registered ]] && exit 0
    still_exiting && exit 0
    echo "Could not find service" >&2
    exit 113
    ;;
  bootout)
    [[ -e $state/registered ]] || exit 3
    rm -f "$state/registered"
    echo "${EXIT_PRINTS:-0}" >"$state/exiting"
    ;;
  bootstrap)
    if [[ -e $state/registered ]] || still_exiting; then
      echo "Bootstrap failed: 5: Input/output error" >&2
      exit 5
    fi
    [[ -e $state/drops ]] || touch "$state/registered"
    ;;
esac
FAKE
chmod +x "$work/bin/launchctl"
export PATH="$work/bin:$PATH" LAUNCHCTL_STATE="$state"

agent="$root/scripts/launch-agent.sh"
plist="$work/ai.emisar.ryker.test.plist"
: >"$plist"

reset() {
  rm -f "$state"/*
}

reset
touch "$state/registered"
output=$(EXIT_PRINTS=3 "$agent" load ai.emisar.ryker.test "$plist" 2>&1)
status=$?
check "reloading a running agent waits for it to stop, then starts it" "0" "$status"
check "the reloaded agent is registered" "yes" "$([[ -e $state/registered ]] && echo yes || echo no)"

reset
output=$("$agent" load ai.emisar.ryker.test "$plist" 2>&1)
status=$?
check "loading an agent that was not running starts it" "0" "$status"
check "the new agent is registered" "yes" "$([[ -e $state/registered ]] && echo yes || echo no)"

reset
touch "$state/drops"
output=$("$agent" load ai.emisar.ryker.test "$plist" 2>&1)
status=$?
check "an agent launchd accepted and dropped fails the install" "1" "$status"
check "and says so" "launchctl accepted the agent but it is not registered" "$output"

reset
touch "$state/registered"
output=$(EXIT_PRINTS=2 "$agent" unload ai.emisar.ryker.test 2>&1)
status=$?
check "unloading a running agent returns once it is gone" "0" "$status"
check "the unloaded agent is gone when unload returns" "0" "$(cat "$state/exiting")"

reset
output=$("$agent" unload ai.emisar.ryker.test 2>&1)
status=$?
check "unloading an agent that is not loaded succeeds" "0" "$status"

if ((failures > 0)); then
  echo "$failures launch-agent check(s) failed"
  exit 1
fi
echo "launch-agent: all checks passed"
