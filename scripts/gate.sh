#!/bin/bash
# The commit gate (make dev-check: static-check, then elixir-partitions) on a
# snapshot of this checkout: HEAD plus
# every change in the working tree, new files included. The snapshot is
# written through a temporary index, so neither this checkout's index nor
# anyone's stash is touched, and checked out in a worktree with a build
# directory of its own: editing on, another session's tests and a running eval
# cannot change the tree under the gate, and the gate's compile cannot change
# theirs. On 2026-10-14 that ritual (a worktree, the diff applied by hand,
# deps and _build copied in) ran about fifteen times, and `git diff` left the
# untracked files out of it unless someone remembered them.
#
#   scripts/gate.sh          gate the snapshot
#   scripts/gate.sh --keep   leave its worktree in place afterwards
#
# One gate runs on this host at a time, and none while a model-world eval
# runs; a second one waits. The static checks run first and stop the gate on
# their own failure, about half a minute in. A test file that fails is run
# again alone: if it passes then, the host's load failed it, and the gate says
# so and passes. A tree that passed once passes again without rerunning.
set -euo pipefail

source_root=$(git rev-parse --show-toplevel)
cd "$source_root"

keep=0
while (($# > 0)); do
  case $1 in
    --keep) keep=1 ;;
    *)
      echo "usage: scripts/gate.sh [--keep]" >&2
      exit 2
      ;;
  esac
  shift
done

home=${RYKER_GATE_HOME:-$HOME/.cache/ryker-gate}
lock=${RYKER_GATE_LOCK:-/tmp/ryker-gate.lock}
tree=$home/tree
log=$home/last.log
# More failed files than this is a broken host or database, not load.
rerun_limit=30
mkdir -p "$home/passed"
find "$home/passed" -type f -mtime +7 -delete
started=$(date +%s)

elapsed() {
  local seconds=$(($(date +%s) - ${1:-$started}))
  if ((seconds >= 60)); then
    echo "$((seconds / 60)) min $((seconds % 60)) s"
  else
    echo "$seconds s"
  fi
}

# The snapshot: HEAD's tree with every change and untracked file laid over it,
# built in an index of its own.
index=$(mktemp "${TMPDIR:-/tmp}/ryker-gate-index.XXXXXX")
GIT_INDEX_FILE=$index git read-tree HEAD
GIT_INDEX_FILE=$index git add --all
snapshot_tree=$(GIT_INDEX_FILE=$index git write-tree)
rm -f "$index"
changes=$(git diff --name-only HEAD "$snapshot_tree" | wc -l | tr -d ' ')

if [[ -f $home/passed/$snapshot_tree ]]; then
  echo "gate passed: tree ${snapshot_tree:0:12} already passed $(cat "$home/passed/$snapshot_tree")"
  exit 0
fi

snapshot=$(git commit-tree --no-gpg-sign "$snapshot_tree" -p HEAD \
  -m "gate snapshot of $(git rev-parse --short HEAD) with $changes changed files")

holding=0
groups=()

# Stops what the gate started, removes its worktree and gives up the lock.
# shellcheck disable=SC2317,SC2329 # the EXIT trap runs it
finish() {
  local status=$?
  trap - EXIT INT TERM
  for group in ${groups[@]+"${groups[@]}"}; do
    kill -TERM -- "-$group" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  if ((keep == 0)) && [[ -d $tree ]]; then
    git worktree remove --force "$tree" 2>/dev/null || rm -rf "$tree"
  fi
  if ((holding == 1)); then
    rm -rf "$lock"
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT TERM

# The host-wide lock is a directory naming its holder. A holder that died
# leaves it behind, and the next gate takes it over.
stale_lock() {
  local holder
  holder=$(cat "$lock/pid" 2>/dev/null || true)
  if [[ -n $holder ]]; then
    if kill -0 "$holder" 2>/dev/null; then
      return 1
    fi
  else
    [[ -n $(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null) ]]
  fi
}

announced=0
until mkdir "$lock" 2>/dev/null; do
  if stale_lock; then
    rm -rf "$lock"
    continue
  fi
  if ((announced == 0)); then
    echo "gate: waiting for the gate already running: $(cat "$lock/what" 2>/dev/null || echo starting)"
    announced=1
  fi
  sleep 5
done
holding=1
echo $$ >"$lock/pid"
echo "PID $$ from $source_root, since $(date '+%H:%M')" >"$lock/what"

# The world eval shares the test PostgreSQL and the eval suites' databases;
# a gate beside it fails on contention, not code (2026-09-12: 88 failures).
announced=0
while pgrep -f 'scripts/elixir-world-eval[.]sh' >/dev/null; do
  if ((announced == 0)); then
    echo "gate: waiting for the model-world eval to finish"
    announced=1
  fi
  sleep 15
done

rm -rf "$tree"
git worktree prune
git worktree add --quiet --detach --force "$tree" "$snapshot"

# Dependencies and the Hex install are this checkout's own; the build is the
# gate's, kept between runs so a gate compiles only what changed since the
# last one. Mix rebuilds everything when the project moves, so the worktree's
# path never changes.
export MIX_BUILD_ROOT=$home/_build
export MIX_DEPS_PATH=$source_root/deps
export RYKER_ELIXIR_HOME=$source_root/.elixir

: >"$log"
echo "gate: snapshot ${snapshot:0:12} of $(git rev-parse --short HEAD) with $changes changed files; log $log"

# in_group COMMAND...: in the background and in a process group of its own,
# so stopping the gate stops every test VM it started.
in_group() {
  set -m
  "$@" &
  groups+=($!)
  set +m
}

# shellcheck disable=SC2317,SC2329 # run through in_group
tree_make() {
  cd "$tree" && exec make --no-print-directory "$@" >>"$log" 2>&1
}

run_make() {
  in_group tree_make "$@"
  local status=0
  wait "${groups[${#groups[@]} - 1]}" || status=$?
  return "$status"
}

# Each partition's result as it lands: the async files first, about a minute in.
# shellcheck disable=SC2317,SC2329 # run through in_group
show_progress() {
  tail -n 0 -F "$log" 2>/dev/null |
    awk '/^== (async|serial)|^Finished in|^[0-9]+ tests?, / { print "  " $0; fflush() }'
}

phase=$(date +%s)
if ! run_make static-check; then
  cat "$log"
  echo "gate failed in $(elapsed): static checks"
  exit 1
fi
echo "gate: static checks passed in $(elapsed "$phase")"

phase=$(date +%s)
in_group show_progress
progress=${groups[${#groups[@]} - 1]}
tests_status=0
run_make elixir-partitions || tests_status=$?
sleep 1
kill -TERM -- "-$progress" 2>/dev/null || true

if ((tests_status == 0)); then
  date '+on %Y-%m-%d at %H:%M' >"$home/passed/$snapshot_tree"
  echo "gate passed in $(elapsed): tree ${snapshot_tree:0:12}"
  exit 0
fi

# A failure is a numbered line, then the file and line it happened at.
failed_files=$(awk '
  /^  +[0-9]+\) / { failure = 1; next }
  failure && match($0, /test\/[^ :]+_test\.exs/) { print substr($0, RSTART, RLENGTH) }
  { failure = 0 }
' "$log" | LC_ALL=C sort -u)
count=$(printf '%s' "$failed_files" | grep -c . || true)

if ((count == 0 || count > rerun_limit)) || grep -q "escaped every test's log capture" "$log"; then
  sed -n '/^== async files/,$p' "$log"
  echo "gate failed in $(elapsed): $count failed test files, so none was run again"
  exit 1
fi

echo "gate: $count test files failed after $(elapsed "$phase"); running them again alone"
printf '%s\n' "$failed_files" | sed 's/^/  /'
echo "== the failed files again, alone" >>"$log"
# shellcheck disable=SC2086 # one test file per line, none with spaces
if (cd "$tree" && RYKER_TEST_ISOLATED=1 scripts/elixir-test.sh --warnings-as-errors --exclude slow \
  $failed_files >>"$log" 2>&1); then
  date '+on %Y-%m-%d at %H:%M, with files that failed only under load' >"$home/passed/$snapshot_tree"
  echo "gate passed in $(elapsed): tree ${snapshot_tree:0:12}; the files above failed under load and passed alone"
  exit 0
fi

sed -n '/^== the failed files again, alone/,$p' "$log"
echo "gate failed in $(elapsed): the files above failed again alone"
exit 1
