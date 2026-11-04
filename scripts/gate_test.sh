#!/bin/bash
# Proves scripts/gate.sh gates what the checkout holds, new files included, without touching
# the checkout; stops on a static failure before the tests; tells a test file the host's load
# failed from one that fails alone; and never passes a failure it did not run again.
#
# 2026-10-14: the gate ritual (a worktree, the diff applied by hand, deps and _build copied in)
# ran about fifteen times in one day, `git diff` left the untracked files out unless someone
# remembered them, and five gate runs went red on one file each, a whole rerun every time.
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

# A repository holding gate.sh and a stand-in suite. make records each target and what the
# gate's tree holds; the suite fails the files GATE_TEST_FAIL names or prints the run
# GATE_TEST_LOG holds, and the rerun alone (scripts/elixir-test.sh) fails those
# GATE_TEST_FAIL_ALONE names.
repo=$work/repo
mkdir -p "$repo/scripts" "$work/bin"
cp "$root/scripts/gate.sh" "$repo/scripts/gate.sh"
cat >"$repo/scripts/elixir-test.sh" <<'FAKE'
#!/bin/bash
echo "alone $*" >>"$GATE_TEST_STATE/calls"
for file in "$@"; do
  case " $GATE_TEST_FAIL_ALONE " in
    *" $file "*) printf '  1) test fails alone (T)\n     %s:3\n' "$file" && exit 1 ;;
  esac
done
FAKE
cat >"$work/bin/make" <<'FAKE'
#!/bin/bash
target=${*: -1}
echo "make $target" >>"$GATE_TEST_STATE/calls"
case $target in
  static-check)
    [[ ${GATE_TEST_STATIC:-0} == 0 ]] || { echo "credo: a house rule broken" && exit 2; }
    ;;
  elixir-partitions)
    cat changed.txt staged.txt untracked.txt >>"$GATE_TEST_STATE/tree" 2>/dev/null
    if [[ -n ${GATE_TEST_LOG:-} ]]; then
      cat "$GATE_TEST_LOG"
      exit 2
    fi
    echo "== async files"
    number=0
    for file in ${GATE_TEST_FAIL:-}; do
      number=$((number + 1))
      printf '%3s) test fails under load (T)\n     %s:7\n' "$number" "$file"
    done
    echo "4 tests, $number failures"
    if ((number == 0)); then
      echo "== red partitions: none"
    else
      echo "== red partitions: 0"
      exit 2
    fi
    ;;
esac
FAKE
# This rig alone decides whether a model-world eval is running.
cat >"$work/bin/pgrep" <<'FAKE'
#!/bin/sh
[ "${GATE_TEST_WORLD:-0}" = 1 ]
FAKE
chmod 0755 "$repo/scripts/gate.sh" "$repo/scripts/elixir-test.sh" "$work/bin/make" "$work/bin/pgrep"

git -C "$repo" init -q
git -C "$repo" config user.email gate@example.com
git -C "$repo" config user.name gate
git -C "$repo" config commit.gpgsign false
echo committed >"$repo/changed.txt"
git -C "$repo" add .
git -C "$repo" commit -q -m initial

gate() {
  (cd "$repo" && PATH="$work/bin:$PATH" GATE_TEST_STATE="$work" RYKER_GATE_HOME="$work/home" \
    RYKER_GATE_LOCK="$work/lock" scripts/gate.sh >"$work/out" 2>&1)
}

# A change of every kind: unstaged, staged, and a file Git does not know yet.
echo edited >"$repo/changed.txt"
echo staged >"$repo/staged.txt"
git -C "$repo" add staged.txt
echo untracked >"$repo/untracked.txt"
status_before=$(git -C "$repo" status --porcelain)
index_before=$(git -C "$repo" ls-files --stage)

gate
check "a green suite passes the gate" 0 "$?"
check "the gate tests the edit, the staged file and the untracked one" \
  "edited staged untracked" "$(tr '\n' ' ' <"$work/tree" | sed 's/ $//')"
check "the checkout's status is untouched" "$status_before" "$(git -C "$repo" status --porcelain)"
check "the checkout's index is untouched" "$index_before" "$(git -C "$repo" ls-files --stage)"
check "the gate's worktree is gone" absent "$([[ -e $work/home/tree ]] && echo present || echo absent)"
check "the lock is released" absent "$([[ -e $work/lock ]] && echo present || echo absent)"

calls=$(wc -l <"$work/calls")
gate
check "a tree that passed passes again" 0 "$?"
check "without running anything" "$calls" "$(wc -l <"$work/calls")"

echo "a format slip" >>"$repo/untracked.txt"
: >"$work/calls"
GATE_TEST_STATIC=1 gate
check "a static failure fails the gate" 1 "$?"
check "before any test runs" "make static-check" "$(cat "$work/calls")"
grep -q "a house rule broken" "$work/out"
check "and says what failed" 0 "$?"

echo "a load flake" >>"$repo/untracked.txt"
: >"$work/calls"
GATE_TEST_FAIL="test/a_test.exs test/b_test.exs" gate
check "files that fail only under load pass the gate" 0 "$?"
check "after running just those files again" "alone --warnings-as-errors --exclude slow test/a_test.exs test/b_test.exs" \
  "$(grep '^alone' "$work/calls")"
grep -q "failed under load and passed alone" "$work/out"
check "and the gate says so" 0 "$?"

echo "a real failure" >>"$repo/untracked.txt"
GATE_TEST_FAIL="test/a_test.exs test/b_test.exs" GATE_TEST_FAIL_ALONE="test/b_test.exs" gate
check "a file that fails again alone fails the gate" 1 "$?"
grep -q "fails alone (T)" "$work/out"
check "and its failure is shown" 0 "$?"

# A run the suite printed, then the gate's judgement of it: only files it read run again.
run() {
  cat >"$work/run.log"
  echo "another run" >>"$repo/untracked.txt"
  : >"$work/calls"
  GATE_TEST_LOG=$work/run.log gate
}
ran_again() {
  grep '^alone' "$work/calls" | tr ' ' '\n' | grep '_test\.exs$' | tr '\n' ' ' | sed 's/ $//'
}

# 2026-11-03: the gate read only failure lines with two spaces before the number, and ExUnit
# right-aligns it, so every failure numbered 10 or higher was dropped. This run, harvested from
# that gate, had 39 failures in 29 files. It reran the 14 files behind the first 15 and passed;
# the day's other run passed the same way with test/ryker/release_test.exs failing for real.
recorded=$root/testdata/gate/run-with-failures-past-the-ninth.log
behind_failure_11=test/ryker/slack/thread_status_projection_test.exs
echo "the recorded run" >>"$repo/untracked.txt"
: >"$work/calls"
GATE_TEST_LOG=$recorded gate
check "a recorded run that fails only under load passes" 0 "$?"
check "after every one of its 29 failing files ran again" 29 "$(ran_again | wc -w | tr -d ' ')"
case " $(ran_again) " in
  *" $behind_failure_11 "*) found=yes ;;
  *) found=no ;;
esac
check "including a file that failed only past the ninth failure" yes "$found"

echo "the recorded run again" >>"$repo/untracked.txt"
GATE_TEST_LOG=$recorded GATE_TEST_FAIL_ALONE=$behind_failure_11 gate
check "a real failure past the ninth fails the gate" 1 "$?"

for number in $(seq 1 105); do
  file=test/first_test.exs
  ((number <= 99)) || file=test/past_ninety_nine_test.exs
  printf '%3s) test fails under load (T)\n     %s:7\n' "$number" "$file"
done | { echo "== async files" && cat && printf '200 tests, 105 failures\n== red partitions: 0\n'; } | run
check "a run with no space before the number passes once each file passed alone" 0 "$?"
check "and the file past the ninety-ninth failure ran again" \
  "test/first_test.exs test/past_ninety_nine_test.exs" "$(ran_again)"

run <<'LOG'
== async files
  1) test fails under load (T)
     test/async_test.exs:1
2 tests, 1 failure
== serial files, partition 1 of 2
2 tests, 0 failures (1 excluded)
== serial files, partition 2 of 2
  1) test fails under load (T)
     test/serial_test.exs:1
1 test, 1 failure (1 excluded)
== red partitions: 0 2
LOG
check "failures in two partitions pass once both files passed alone" 0 "$?"
check "and both files ran again" "test/async_test.exs test/serial_test.exs" "$(ran_again)"

# What cannot be run again fails the gate, and says why: none of these is a load failure the
# gate has proved, and each used to pass beside one that was.
refused() {
  local what="$1" says="$2"
  check "$what" 1 "$3"
  check "without running anything again" "" "$(ran_again)"
  grep -q "$says" "$work/out"
  check "and names it: $says" 0 "$?"
}

run <<'LOG'
== async files
  1) test fails under load (T)
     test/async_test.exs:1
  2) test its location is no test file (T)
     test/support/shared_case.ex:12
3 tests, 2 failures
== red partitions: 0
LOG
refused "a failure the gate cannot read fails the gate" "ExUnit printed 2 failures, this gate read 1" "$?"

run <<'LOG'
== async files
  1) test fails under load (T)
     test/async_test.exs:1
  1) AModuleTest: failure on setup_all callback, all tests have been invalidated
     ** (DBConnection.ConnectionError) connection not available
5 tests, 1 failure, 2 invalid
== red partitions: 0
LOG
refused "tests a setup_all failure kept from running fail the gate" "2 tests never ran after a failed setup_all" "$?"

run <<'LOG'
== async files
  1) test fails under load (T)
     test/async_test.exs:1
2 tests, 1 failure
== serial files, partition 1 of 1
3 tests, 0 failures
ERROR! Test suite aborted after successful execution due to warnings
== red partitions: 0 1
LOG
refused "a partition red with no failure fails the gate" "partition 1 went red without a failure to run again" "$?"

run <<'LOG'
== async files
  1) test fails under load (T)
     test/async_test.exs:1
2 tests, 1 failure
== serial files, partition 1 of 1
Segmentation fault
== red partitions: 0 1
LOG
refused "a partition that never finished fails the gate" "serial partition 1: no ExUnit totals" "$?"

run <<'LOG'
== async files
  1) test fails under load (T)
     test/async_test.exs:1
2 tests, 1 failure
LOG
refused "a run that ended early fails the gate" "ended before every partition reported" "$?"

# A gate that died leaves its lock behind; the next one takes it over.
sleep 0 &
dead=$!
wait "$dead"
mkdir "$work/lock" && echo "$dead" >"$work/lock/pid"
echo "after a crash" >>"$repo/untracked.txt"
gate
check "a lock whose holder died is taken over" 0 "$?"

# A cancelled contender used to delete the holder's shared worktree despite
# never acquiring its lock. The FIFO observes the waiting event, with no race
# against a sleep or against a real gate running on this host.
git -C "$repo" worktree add --quiet --detach "$work/home/tree" HEAD
echo active-holder >"$work/home/tree/owner-marker"
mkdir "$work/lock"
echo $$ >"$work/lock/pid"
echo "isolated holder" >"$work/lock/what"
echo "queued cancellation" >>"$repo/untracked.txt"
mkfifo "$work/queued-output"
(
  cd "$repo" || exit
  exec env PATH="$work/bin:$PATH" GATE_TEST_STATE="$work" \
    RYKER_GATE_HOME="$work/home" RYKER_GATE_LOCK="$work/lock" \
    scripts/gate.sh >"$work/queued-output" 2>&1
) &
contender=$!
IFS= read -r queued_line <"$work/queued-output"
check "the contender waits for the holder" \
  "gate: waiting for the gate already running: isolated holder" "$queued_line"
kill -TERM "$contender"
wait "$contender"
check "a cancelled contender exits without running tests" 130 "$?"
check "the contender leaves the holder's worktree" present \
  "$([[ -f $work/home/tree/owner-marker ]] && echo present || echo absent)"
check "the contender leaves the holder's lock" "$$" "$(cat "$work/lock/pid" 2>/dev/null)"
rm -rf "$work/lock"
git -C "$repo" worktree remove --force "$work/home/tree" 2>/dev/null || true

# Taking the lock does not grant ownership of a previous --keep worktree.
# A run waiting for an eval has not yet created its own snapshot tree.
git -C "$repo" worktree add --quiet --detach "$work/home/tree" HEAD
echo kept-snapshot >"$work/home/tree/owner-marker"
echo "eval-wait cancellation" >>"$repo/untracked.txt"
mkfifo "$work/eval-output"
(
  cd "$repo" || exit
  exec env PATH="$work/bin:$PATH" GATE_TEST_STATE="$work" GATE_TEST_WORLD=1 \
    RYKER_GATE_HOME="$work/home" RYKER_GATE_LOCK="$work/lock" \
    scripts/gate.sh >"$work/eval-output" 2>&1
) &
contender=$!
IFS= read -r eval_line <"$work/eval-output"
check "the lock owner waits for the eval before creating its snapshot" \
  "gate: waiting for the model-world eval to finish" "$eval_line"
check "the waiting run owns the lock" "$contender" "$(cat "$work/lock/pid" 2>/dev/null)"
kill -TERM "$contender"
wait "$contender"
check "a cancelled eval waiter exits cleanly" 130 "$?"
check "the waiter preserves the earlier kept snapshot" present \
  "$([[ -f $work/home/tree/owner-marker ]] && echo present || echo absent)"
check "the waiter releases only its own lock" absent \
  "$([[ -e $work/lock ]] && echo present || echo absent)"

if ((failures > 0)); then
  echo "gate_test: $failures failure(s)"
  sed 's/^/  out: /' "$work/out"
  exit 1
fi
echo "gate_test: all checks passed"
