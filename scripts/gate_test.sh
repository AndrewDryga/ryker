#!/bin/bash
# Proves scripts/gate.sh gates what the checkout holds, new files included, without touching
# the checkout; stops on a static failure before the tests; and tells a test file the host's
# load failed from one that fails alone.
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
# gate's tree holds; the suite fails the files GATE_TEST_FAIL names, and the rerun alone
# (scripts/elixir-test.sh) fails those GATE_TEST_FAIL_ALONE names.
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
    echo "== async files"
    number=0
    for file in ${GATE_TEST_FAIL:-}; do
      number=$((number + 1))
      printf '  %s) test fails under load (T)\n     %s:7\n' "$number" "$file"
    done
    echo "4 tests, $number failures"
    ((number == 0)) || exit 2
    ;;
esac
FAKE
# No model-world eval is running here, whatever the host is doing.
printf '#!/bin/sh\nexit 1\n' >"$work/bin/pgrep"
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

# A gate that died leaves its lock behind; the next one takes it over.
sleep 0 &
dead=$!
wait "$dead"
mkdir "$work/lock" && echo "$dead" >"$work/lock/pid"
echo "after a crash" >>"$repo/untracked.txt"
gate
check "a lock whose holder died is taken over" 0 "$?"

if ((failures > 0)); then
  echo "gate_test: $failures failure(s)"
  sed 's/^/  out: /' "$work/out"
  exit 1
fi
echo "gate_test: all checks passed"
