#!/bin/bash
# A Claude Code PreToolUse hook on Bash (.claude/settings.json): refuses the
# commands that have already cost this repository a production outage, a lost
# sign-in or another session's work, before they run. Each refusal says why and
# what to do instead; exit status 2 is how a hook refuses.
#
#   git stash         The stash is shared by every worktree of the repository:
#                     an agent popped another session's stash into its own tree
#                     (2026-09-11). Set work aside with a wip commit.
#   pkill, killall    A pattern kill took production down. Kill exact PIDs.
#   coop login        It deletes the worker's sign-in before it starts, and a
#                     live worker then has none (scripts/compose.sh model-login
#                     is the operator's path).
#   compose.sh replay over SSH
#                     On the tenant install it records the action as the
#                     configured operator, a real person.
#
# It reads only the command: words at the start of each simple command, after
# ;, &&, ||, |, an opening ( or $(, then, do or else, so a word in quotes or in
# Markdown's backticks passes. A heredoc line that starts with one of these
# commands is refused too; write such text with an editor.
set -uo pipefail

command=$(jq -r '.tool_input.command // empty' 2>/dev/null)
[[ -n $command ]] || exit 0

refuse() {
  echo "agent-guard: $1" >&2
  exit 2
}

# One simple command per line, without leading space or variable assignments.
segments=$(printf '%s\n' "$command" |
  sed -E 's/(\|\||&&|;|\||\$\(|\()/\n/g' |
  sed -E -e 's/^[[:space:]]+//' \
    -e 's/^((then|do|else|elif|!|\{)[[:space:]]+)+//' \
    -e 's/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+//' \
    -e 's/^((sudo|exec|nohup|time|command)[[:space:]]+)+//')

while IFS= read -r segment; do
  if [[ $segment =~ ^git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+stash([[:space:]]|$) ]] &&
    ! [[ $segment =~ stash[[:space:]]+(list|show)([[:space:]]|$) ]]; then
    refuse "git stash is shared by every worktree of this repository, so a pop can take another session's work. Set yours aside with a wip commit instead."
  fi
  if [[ $segment =~ ^(pkill|killall)([[:space:]]|$) ]]; then
    refuse "no kill by name or pattern: one took production down. Find the exact PIDs (pgrep -fl, lsof) and kill those."
  fi
  if [[ $segment =~ ^(coop|docker|ssh)[[:space:]] && $segment =~ (^|[[:space:]])coop[[:space:]]+login([[:space:]]|$) ]]; then
    refuse "coop login deletes the worker's sign-in before it starts. Signing a worker in is the operator's step: scripts/compose.sh model-login."
  fi
done <<<"$segments"

if [[ $command =~ compose\.sh[\"\']?[[:space:]]+replay ]] &&
  [[ $command =~ (^|[^[:alnum:]_-])(ssh|run-step|mac-server)([^[:alnum:]_-]|$) ]]; then
  refuse "compose.sh replay on a remote install records the action as its configured operator, a real person. Leave it to them."
fi

exit 0
