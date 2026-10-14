#!/bin/bash
# A worktree of its own for an agent working beside others in this repository:
#
#   scripts/agent-worktree.sh NAME
#
# makes .claude/worktrees/NAME on a new branch NAME from local main (origin/main
# lags this checkout by days, and agents once started there 47 commits behind,
# 2026-09-18), with copies of this checkout's dependencies and Hex install so
# its first test needs no network. Copies, not links: a linked deps directory
# was once committed and wrote itself over the real one (2026-09-11). On APFS
# the copies are clones and take no space. The worktree builds into its own
# _build, so its compiles never touch anyone else's. Land its commit on main
# with scripts/land.sh; remove it with `git worktree remove`.
set -euo pipefail

name=${1:?usage: scripts/agent-worktree.sh NAME}
[[ $name =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "agent-worktree: NAME takes letters, digits, '.', '_' and '-'" >&2
  exit 2
}

repository=$(git rev-parse --show-toplevel)
tree=$repository/.claude/worktrees/$name

git -C "$repository" worktree add --quiet -b "$name" "$tree" main

for directory in deps .elixir; do
  if [[ -d $repository/$directory ]]; then
    # -c clones on APFS; elsewhere it is a plain copy.
    cp -cR "$repository/$directory" "$tree/" 2>/dev/null || cp -R "$repository/$directory" "$tree/"
  fi
done

echo "agent-worktree: $tree on branch $name at $(git -C "$tree" rev-parse --short HEAD)"
