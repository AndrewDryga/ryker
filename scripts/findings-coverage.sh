#!/bin/bash
# Reports which confirmed quality findings have a regression test, and which do
# not.
#
# The assessor already writes the test. Every confirmed finding carries a
# regression_test field naming and describing the test that would have caught
# it — and for months nothing read that column, so each defect was fixed by
# hand and the same class returned a week later. This closes the last inch:
# it names the tests that were asked for and never written.
#
# It reads the deployment databases directly, so it runs where they are rather
# than in CI. Findings are a production artifact; the tests they ask for are a
# repository one, and this is the only place both are visible at once.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
found=0
missing=0
covered=0

for db in "$@"; do
  [[ -f $db ]] || { echo "findings-coverage: no database at $db" >&2; continue; }
  # Read-only and immutable: a live deployment is writing to this file.
  while IFS= read -r spec; do
    [[ -n $spec ]] || continue
    found=$((found + 1))
    # The spec names the test it wants, usually as TestSomething. Where it does
    # not, there is nothing mechanical to check and it is reported as such
    # rather than counted as covered — silence about a gap is how this column
    # went unread in the first place.
    name=$(printf '%s' "$spec" | grep -oE '\bTest[A-Za-z0-9_]{6,}' | head -1)
    if [[ -z $name ]]; then
      printf 'UNNAMED  %s\n' "$(printf '%s' "$spec" | cut -c1-96)"
      missing=$((missing + 1))
      continue
    fi
    # Matched anywhere in a test file, not only as a function name. The
    # assessor proposes a name; a better one often exists by the time the test
    # is written, so a test claims the spec it satisfies by naming it in its
    # own comment — "Covers: TestSuggestedName". Requiring the exact function
    # name instead would push people to keep the worse name or to leave real
    # coverage reported as missing, and both are worse than a one-line comment.
    if grep -rqF "$name" "$root"/internal --include='*_test.go' 2>/dev/null; then
      covered=$((covered + 1))
    else
      printf 'MISSING  %s\n' "$name"
      missing=$((missing + 1))
    fi
  done < <(/usr/bin/sqlite3 -readonly "file:$db?immutable=1" "
    SELECT DISTINCT replace(replace(regression_test, char(10), ' '), char(13), ' ')
    FROM quality_findings
    WHERE verdict = 'confirmed' AND TRIM(regression_test) <> ''
  " 2>/dev/null)
done

printf '\nfindings-coverage: %d confirmed findings ask for a test — %d have one, %d do not\n' \
  "$found" "$covered" "$missing"
