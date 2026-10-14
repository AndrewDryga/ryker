#!/bin/bash
# Proves scripts/agent-guard.sh refuses the commands that cost this repository an outage, a
# sign-in or another session's work, and lets the everyday ones through.
#
# Each refused command is one that happened: a pattern kill that took production down, a stash
# popped into the wrong worktree (2026-09-11), a sign-in deleted by `coop login`, and a replay on
# the tenant install recorded as its operator. Each was in a memory note an agent had to read
# first; the hook does not depend on that.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
failures=0

decide() {
  local status=0
  jq -n --arg command "$1" '{tool_name: "Bash", tool_input: {command: $command}}' |
    "$root/scripts/agent-guard.sh" >/dev/null 2>&1 || status=$?
  if [[ $status == 2 ]]; then echo refused; else echo allowed; fi
}

expect() {
  local verdict="$1" command="$2" actual
  actual=$(decide "$command")
  if [[ $actual == "$verdict" ]]; then
    printf 'ok   %s: %s\n' "$verdict" "$command"
  else
    printf 'FAIL %s, wanted %s: %s\n' "$actual" "$verdict" "$command"
    failures=$((failures + 1))
  fi
}

expect refused 'git stash'
expect refused 'git stash pop'
expect refused 'cd /tmp/x && git -C /repo stash push -- lib/a.ex'
expect refused 'FOO=1 git stash apply'
expect refused 'pkill -f beam.smp'
expect refused 'sleep 1; killall beam.smp'
expect refused 'sudo pkill -9 -f "mix test"'
expect refused 'docker exec -u coop ryker-ryker-coop-1 coop login codex'
expect refused 'coop login'
expect refused 'if true; then git stash; fi'
expect refused 'for pid in 1 2; do pkill -P 7; done'
# shellcheck disable=SC2088 # the command's own text, never expanded here
expect refused "~/.cache/ryker-blitz-ssh/ssh.sh 'cd ~/Projects/ryker-blitz && scripts/compose.sh replay abc'"
expect refused 'ssh mac-server scripts/compose.sh replay abc'

expect allowed 'git stash list'
expect allowed 'git stash show -p stash@{0}'
expect allowed 'git status --short && git log --oneline -3'
expect allowed 'kill 12345 12346'
expect allowed 'pgrep -fl beam.smp'
expect allowed 'grep -n "git stash" docs/testing.md'
expect allowed "python3 - <<'EOF'
text = 'refuses \`git stash\`, \`pkill\` and \`coop login\`'
EOF"
expect allowed 'docker exec -u coop ryker-ryker-coop-1 coop credentials codex'
expect allowed 'scripts/compose.sh replay-show abc'
expect allowed 'scripts/compose.sh replay abc'
expect allowed 'make quick'

if ((failures > 0)); then
  echo "agent-guard_test: $failures failure(s)"
  exit 1
fi
echo "agent-guard_test: all checks passed"
