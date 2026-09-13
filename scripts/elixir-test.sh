#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compose=(docker compose --project-name ryker-kernel --file "$root/compose.test.yml")

cd "$root"

# `up` is a no-op when the healthy container already matches compose.test.yml
# and recreates it when the file changed, so a capacity change lands on the
# next run instead of after someone remembers to down it.
"${compose[@]}" up --detach --wait episode-db >/dev/null

address=$("${compose[@]}" port episode-db 5432)

export PGHOST=127.0.0.1
export PGPASSWORD=postgres
export PGPORT=${address##*:}
export PGUSER=postgres

isolated_database=0

if [[ ${RYKER_TEST_ISOLATED:-0} == 1 ]]; then
  export PGDATABASE="ryker_test_$$_${RANDOM}"

  cleanup_database() {
    status=$?
    trap - EXIT

    if [[ $isolated_database == 1 ]]; then
      env MIX_ENV=test scripts/elixir-mix.sh ecto.drop --quiet >/dev/null 2>&1 || true
    fi

    exit "$status"
  }

  trap cleanup_database EXIT
  env MIX_ENV=test scripts/elixir-mix.sh ecto.create --quiet
  isolated_database=1
else
  # The compose project name changed with the 2026-09-13 rename, so a fresh
  # container may be serving; create the shared database when it is absent
  # (ecto.create is a no-op when it already exists).
  export PGDATABASE=${PGDATABASE:-ryker_test}
  env MIX_ENV=test scripts/elixir-mix.sh ecto.create --quiet
fi

if [[ ${1:-} == "--check" ]]; then
  shift
  env MIX_ENV=test scripts/elixir-mix.sh "do" \
    format --check-formatted + \
    compile --warnings-as-errors + \
    credo --strict + \
    ecto.migrate --quiet + \
    test "$@"
else
  env MIX_ENV=test scripts/elixir-mix.sh "do" ecto.migrate --quiet + test "$@"
fi
