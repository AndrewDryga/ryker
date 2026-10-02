#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)

cd "$root"

isolated_database=0
private_postgres=

cleanup() {
  status=$?
  trap - EXIT

  if [[ $isolated_database == 1 ]]; then
    env MIX_ENV=test scripts/elixir-mix.sh ecto.drop --quiet >/dev/null 2>&1 || true
  fi

  if [[ -n $private_postgres ]]; then
    pg_ctl stop --pgdata="$private_postgres/data" --mode=immediate >/dev/null 2>&1 || true
    rm -rf "$private_postgres"
  fi

  exit "$status"
}

trap cleanup EXIT

# A Coop fleet job or review gets neither Docker nor sidecar services, so the run
# brings its own server, with compose.test.yml's settings, and removes it at exit.
start_private_postgres() {
  private_postgres=$(mktemp -d "${TMPDIR:-/tmp}/ryker-test-postgres.XXXXXX")
  initdb --pgdata="$private_postgres/data" --username=postgres --auth=trust \
    --encoding=UTF8 --locale=en_US.UTF-8 >/dev/null

  # A random port, retried, so concurrent runs in one box each get their own.
  for _ in 1 2 3 4 5; do
    PGPORT=$((20000 + RANDOM % 40000))
    if pg_ctl start --wait --pgdata="$private_postgres/data" --log="$private_postgres/log" \
      --options="-c listen_addresses=127.0.0.1 -c port=$PGPORT \
        -c unix_socket_directories=$private_postgres -c max_connections=500 \
        -c shared_buffers=256MB -c fsync=off -c synchronous_commit=off \
        -c full_page_writes=off -c dynamic_shared_memory_type=mmap" >/dev/null; then
      export PGHOST=127.0.0.1 PGPORT
      return
    fi
  done

  cat "$private_postgres/log" >&2
  exit 1
}

if command -v docker >/dev/null 2>&1; then
  compose=(docker compose --project-name ryker-kernel --file "$root/compose.test.yml")

  # `up` is a no-op when the healthy container already matches compose.test.yml
  # and recreates it when the file changed, so a capacity change lands on the
  # next run instead of after someone remembers to down it.
  "${compose[@]}" up --detach --wait episode-db >/dev/null

  address=$("${compose[@]}" port episode-db 5432)

  export PGHOST=127.0.0.1
  export PGPORT=${address##*:}
elif [[ -n ${PGHOST:-} ]]; then
  # A Coop box has no Docker: Coop starts compose.test.yml as the box's sidecar
  # and names it in PGHOST (.agent/project.yaml).
  :
elif command -v pg_ctl >/dev/null 2>&1; then
  start_private_postgres
else
  echo "no docker, no PGHOST and no pg_ctl: nothing can serve a test PostgreSQL" >&2
  exit 1
fi

export PGPASSWORD=postgres
export PGUSER=postgres

if [[ ${RYKER_TEST_ISOLATED:-0} == 1 ]]; then
  export PGDATABASE="ryker_test_$$_${RANDOM}"
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
