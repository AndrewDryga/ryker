#!/bin/bash
# Proves scripts/land.sh moves main to a commit made in another worktree, checks out exactly its
# files in the checkout that has main, keeps everyone else's uncommitted work there, and refuses
# rather than overwrite a file someone is editing or race a main that moved.
#
# By hand this went wrong three ways: a zsh path list that never split (2026-09-26), a refused
# update-ref the next line ran past (2026-10-12), and a rename whose old path stayed (2026-10-03).
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

main=$work/main
mkdir -p "$main/scripts"
cp "$root/scripts/land.sh" "$main/scripts/land.sh"
g() { git -C "$main" -c user.email=land@example.com -c user.name=land -c commit.gpgsign=false "$@"; }
g init -q -b main
printf 'one\n' >"$main/a.txt"
printf 'two\n' >"$main/old-name.txt"
printf 'three\n' >"$main/gone.txt"
printf 'four\n' >"$main/other.txt"
g add . && g commit -q -m base

# Another session's uncommitted edit in a file the landing does not touch.
printf 'four, edited\n' >"$main/other.txt"

agent=$work/agent
g worktree add -q -b agent "$agent" main
a() { git -C "$agent" -c user.email=land@example.com -c user.name=land -c commit.gpgsign=false "$@"; }
printf 'one, changed\n' >"$agent/a.txt"
a mv old-name.txt new-name.txt
a rm -q gone.txt
printf 'five\n' >"$agent/added.txt"
a add -A && a commit -q -m change
change=$(a rev-parse HEAD)

land() { (cd "$main" && scripts/land.sh "$@" >"$work/out" 2>&1); }

land "$change"
check "a commit that builds on main lands" 0 "$?"
check "main is the commit" "$change" "$(g rev-parse main)"
check "its changed file is checked out" "one, changed" "$(cat "$main/a.txt")"
check "its renamed file is there under the new name" "two" "$(cat "$main/new-name.txt")"
check "the old name is gone" "absent" "$([[ -e $main/old-name.txt ]] && echo present || echo absent)"
check "its deleted file is gone" "absent" "$([[ -e $main/gone.txt ]] && echo present || echo absent)"
check "its new file is there" "five" "$(cat "$main/added.txt")"
check "another session's edit is kept" "four, edited" "$(cat "$main/other.txt")"
check "and is the only change left in the checkout" " M other.txt" "$(g status --short)"

# Someone edits a file the next commit changes: landing would lose that edit.
printf 'one, again\n' >"$agent/a.txt"
a commit -q -am again
again=$(a rev-parse HEAD)
printf 'one, edited by someone else\n' >"$main/a.txt"
land "$again"
check "a file edited in the checkout is not overwritten" 1 "$?"
check "main stays" "$change" "$(g rev-parse main)"
check "the edit stays" "one, edited by someone else" "$(cat "$main/a.txt")"
grep -q '^  a.txt$' "$work/out"
check "and the refusal names the file" 0 "$?"
g checkout -q -- a.txt

# A commit that does not build on main.
a reset -q --hard "$change~1"
printf 'elsewhere\n' >"$agent/elsewhere.txt"
a add elsewhere.txt && a commit -q -m elsewhere
land "$(a rev-parse HEAD)"
check "a commit that does not build on main is refused" 1 "$?"
check "main stays" "$change" "$(g rev-parse main)"

land "$change"
check "landing main itself changes nothing" 0 "$?"

if ((failures > 0)); then
  echo "land_test: $failures failure(s)"
  sed 's/^/  out: /' "$work/out"
  exit 1
fi
echo "land_test: all checks passed"
