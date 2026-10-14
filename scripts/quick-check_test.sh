#!/bin/bash
# Proves scripts/quick-check.sh checks the files a change touches: format and Credo on the
# changed Elixir files, and the owning test of each beside the three source audits; that the
# pre-commit hook's form takes only what is staged; and that a failing check fails the run.
#
# 2026-10-14: five gate runs went red minutes in on one file each (a format slip, two Credo
# house rules, PublicFunctionsTest, a short assert_receive). Nothing that fast ran before them.
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

# A repository holding quick-check.sh and stand-ins for Mix and the test runner, which
# record what they were asked to check. QUICK_TEST_FAIL names a Mix task that fails.
repo=$work/repo
mkdir -p "$repo/scripts" "$repo/lib/ryker/settings" "$repo/test/ryker"
cp "$root/scripts/quick-check.sh" "$repo/scripts/quick-check.sh"
cat >"$repo/scripts/elixir-mix.sh" <<'FAKE'
#!/bin/bash
echo "$*" >>"$QUICK_TEST_STATE/mix"
if [[ $1 == "${QUICK_TEST_FAIL:-none}" ]]; then
  echo "lib/ryker/settings/channel.ex is not formatted"
  exit 1
fi
FAKE
cat >"$repo/scripts/elixir-test.sh" <<'FAKE'
#!/bin/bash
echo "$*" >"$QUICK_TEST_STATE/tests"
echo "${GIT_INDEX_FILE:-no index}" >"$QUICK_TEST_STATE/index"
FAKE
chmod 0755 "$repo/scripts/"*.sh

for file in lib/ryker/settings.ex lib/ryker/settings/channel.ex lib/ryker/unowned.ex \
  test/ryker/settings_test.exs test/ryker/other_test.exs README.md; do
  echo original >"$repo/$file"
done
git -C "$repo" init -q
git -C "$repo" config user.email quick@example.com
git -C "$repo" config user.name quick
git -C "$repo" add .
git -C "$repo" commit -q -m initial

quick() {
  (cd "$repo" && QUICK_TEST_STATE="$work" scripts/quick-check.sh >"$work/out" 2>&1)
}

# A nested module, a test file, a new untracked module with no test, and a document.
echo edited >"$repo/lib/ryker/settings/channel.ex"
echo edited >"$repo/test/ryker/other_test.exs"
echo new >"$repo/lib/ryker/fresh.ex"
echo edited >"$repo/README.md"

quick
check "a clean change passes" 0 "$?"
check "the audits and each changed file's owning test run" \
  "--warnings-as-errors test/ryker/other_test.exs test/ryker/public_functions_test.exs test/ryker/redaction_audit_test.exs test/ryker/rename_audit_test.exs test/ryker/settings_test.exs" \
  "$(cat "$work/tests")"
check "format reads the changed Elixir files, new ones included" \
  "format --check-formatted lib/ryker/fresh.ex lib/ryker/settings/channel.ex test/ryker/other_test.exs" \
  "$(grep '^format' "$work/mix")"
check "Credo reads the same files" \
  "credo --strict lib/ryker/fresh.ex lib/ryker/settings/channel.ex test/ryker/other_test.exs" \
  "$(grep '^credo' "$work/mix")"
check "compiling with warnings as errors comes first" "compile --warnings-as-errors" "$(head -1 "$work/mix")"

# The pre-commit hook: only what the commit takes, with Git's index variable kept from the
# tests, which build throwaway repositories of their own.
git -C "$repo" add lib/ryker/settings/channel.ex
: >"$work/mix"
(cd "$repo" && GIT_INDEX_FILE="$repo/.git/index" QUICK_TEST_STATE="$work" \
  scripts/quick-check.sh --staged >"$work/out" 2>&1)
check "a commit's check passes" 0 "$?"
check "a commit's check reads only the staged file" \
  "format --check-formatted lib/ryker/settings/channel.ex" "$(grep '^format' "$work/mix")"
check "and runs its owning test with the audits" \
  "--warnings-as-errors test/ryker/public_functions_test.exs test/ryker/redaction_audit_test.exs test/ryker/rename_audit_test.exs test/ryker/settings_test.exs" \
  "$(cat "$work/tests")"
check "the hook's index variable does not reach the tests" "no index" "$(cat "$work/index")"

QUICK_TEST_FAIL=format quick
check "a check that fails fails the run" 1 "$?"
grep -q "FAIL  format" "$work/out"
check "the run names it" 0 "$?"
grep -q "channel.ex is not formatted" "$work/out"
check "and shows what it said" 0 "$?"
grep -q "ok    tests" "$work/out"
check "the other checks still report" 0 "$?"

if ((failures > 0)); then
  echo "quick-check_test: $failures failure(s)"
  sed 's/^/  out: /' "$work/out"
  exit 1
fi
echo "quick-check_test: all checks passed"
