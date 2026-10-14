#!/bin/bash
# Proves scripts/memory-lint.sh fails on a memory index and notes that disagree or lack their
# frontmatter, warns about a repository file a note names that is gone, and passes clean notes.
#
# 2026-10-14: 113 notes, one of them missing from the index that loads them, and five naming
# scripts deleted since.
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

note() { # FILE NAME TYPE BODY
  printf -- '---\nname: %s\ndescription: a note\nmetadata:\n  type: %s\n---\n\n%s\n' "$2" "$3" "$4" >"$work/$1"
}

lint() { (cd "$root" && scripts/memory-lint.sh "$work" 2>&1; echo "exit=$?"); }

printf -- '- [Good](good.md) — hook\n' >"$work/MEMORY.md"
note good.md good feedback 'Run scripts/gate.sh before committing.'
clean=$(lint)
check "clean notes pass" "exit=0" "$clean"
check "and are counted" "1 notes, 0 errors, 0 stale paths" "$clean"

note unlisted.md unlisted project 'Something.'
note renamed.md other project 'Something.'
note untyped.md untyped wrong 'See scripts/removed-long-ago.sh.'
printf -- '- [Gone](gone.md) — hook\n- [Renamed](renamed.md) — h\n- [Untyped](untyped.md) — h\n' >>"$work/MEMORY.md"
broken=$(lint)
check "a note the index does not list fails" "unlisted.md is not listed in MEMORY.md" "$broken"
check "an index entry with no note fails" "MEMORY.md lists gone.md, which does not exist" "$broken"
check "a name other than the file's fails" "renamed.md: its name is 'other'" "$broken"
check "an unknown type fails" "untyped.md: type is 'wrong'" "$broken"
check "a file the tree no longer has is reported" "stale untyped.md: scripts/removed-long-ago.sh" "$broken"
check "the run fails" "exit=1" "$broken"

if ((failures > 0)); then
  echo "memory-lint_test: $failures failure(s)"
  exit 1
fi
echo "memory-lint_test: all checks passed"
