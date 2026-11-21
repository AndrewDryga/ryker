#!/bin/bash
# Proves scripts/elixir-test.sh keeps tests that commit for real out of the shared
# ryker_test: a run that names such a file, a directory holding one, or no file at all
# gets a database of its own, dropped at exit, while a run of files that commit nothing
# keeps the shared, already migrated database.
#
# 2026-11-20: one episode a custody concurrency test left in ryker_test the day before
# failed 219 of 404 tests there, the pre-commit hook's included, because every claim
# test claimed it instead of its own work.
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

# A repository holding the runner and stand-ins for Mix and Docker, which record the
# database each Mix call was given.
repo=$work/repo
mkdir -p "$repo/scripts" "$repo/test/ryker/work" "$repo/test/ryker/retention" "$work/bin"
cp "$root/scripts/elixir-test.sh" "$root/scripts/test-database.sh" "$repo/scripts/"
cat >"$repo/scripts/elixir-mix.sh" <<'FAKE'
#!/bin/bash
echo "$PGDATABASE $*" >>"$RUNNER_TEST_STATE/mix"
FAKE
cat >"$work/bin/docker" <<'FAKE'
#!/bin/bash
[[ " $* " == *" port "* ]] && echo "127.0.0.1:55432"
exit 0
FAKE
chmod 0755 "$repo/scripts/"*.sh "$work/bin/docker"

printf 'defmodule PlainTest do\n  use Ryker.DataCase, async: true\nend\n' \
  >"$repo/test/ryker/plain_test.exs"
printf 'defmodule CommitsTest do\n  use Ryker.ConcurrencyCase, async: false\nend\n' \
  >"$repo/test/ryker/work/commits_test.exs"
printf 'defmodule UnboxedTest do\n  test "x" do\n    Sandbox.unboxed_run(Repo, fn -> :ok end)\n  end\nend\n' \
  >"$repo/test/ryker/retention/unboxed_test.exs"

# The database the run tested in, and the databases it dropped at exit.
run() {
  rm -f "$work/mix"
  (cd "$repo" && PATH="$work/bin:$PATH" RUNNER_TEST_STATE="$work" \
    RYKER_TEST_ISOLATED=0 PGDATABASE='' scripts/elixir-test.sh "$@" >/dev/null 2>&1)
  tested=$(awk '$3 == "ecto.create" { print $1 }' "$work/mix")
  dropped=$(awk '$2 == "ecto.drop" { print $1 }' "$work/mix")
}

own_database() {
  [[ $tested =~ ^ryker_test_[0-9]+_[0-9]+$ && $dropped == "$tested" ]] && echo own || echo "$tested, dropped '$dropped'"
}

run test/ryker/plain_test.exs:3
check "a file that commits nothing keeps the shared database" "ryker_test" "$tested"
check "and the shared database is not dropped" "" "$dropped"

run --seed 0 test/ryker/plain_test.exs test/ryker/work/commits_test.exs:2
check "a named ConcurrencyCase file, with a line number, gets a database of its own" own "$(own_database)"

run test/ryker/retention
check "a directory holding an unboxed run gets a database of its own" own "$(own_database)"

run --stale
check "a run naming no file, which may reach any test, gets a database of its own" own "$(own_database)"

if ((failures > 0)); then
  echo "elixir-test: $failures check(s) failed"
  exit 1
fi
echo "elixir-test: all checks passed"
