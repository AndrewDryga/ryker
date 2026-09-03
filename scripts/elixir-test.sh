#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compose=(docker compose --project-name responder-kernel --file "$root/compose.test.yml")

cd "$root"

container=$("${compose[@]}" ps --quiet episode-db)

if [[ -z "$container" ]] ||
  [[ $(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container") != "healthy" ]]; then
  "${compose[@]}" up --detach --wait episode-db >/dev/null
fi

address=$("${compose[@]}" port episode-db 5432)

export PGHOST=127.0.0.1
export PGPASSWORD=postgres
export PGPORT=${address##*:}
export PGUSER=postgres

isolated_database=0

if [[ ${RESPONDER_TEST_ISOLATED:-0} == 1 ]]; then
  export PGDATABASE="responder_test_$$_${RANDOM}"

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
  export PGDATABASE=${PGDATABASE:-responder_test}
fi

if [[ ${1:-} == "--check" ]]; then
  shift
  env MIX_ENV=test scripts/elixir-mix.sh "do" \
    format --check-formatted + \
    compile --warnings-as-errors + \
    credo --strict + \
    ecto.migrate --quiet + \
    test --cover "$@"
else
  env MIX_ENV=test scripts/elixir-mix.sh "do" ecto.migrate --quiet + test "$@"
fi
