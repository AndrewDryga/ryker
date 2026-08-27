#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compose=(docker compose --project-name responder-kernel --file "$root/compose.test.yml")

container=$("${compose[@]}" ps --quiet episode-db)

if [[ -z "$container" ]] ||
  [[ $(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container") != "healthy" ]]; then
  "${compose[@]}" up --detach --wait episode-db >/dev/null
fi

address=$("${compose[@]}" port episode-db 5432)

export PGDATABASE=responder_test
export PGHOST=127.0.0.1
export PGPASSWORD=postgres
export PGPORT=${address##*:}
export PGUSER=postgres

cd "$root"

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
