#!/usr/bin/env bash
set -euo pipefail

archive=${1:-}
expected_version=${2:-}
expected_sha256=${3:-}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compose=(docker compose --project-name responder-kernel --file "$root/compose.test.yml")

if [[ -z $archive || -z $expected_version || -z $expected_sha256 || ! -f $archive ]]; then
  echo "usage: scripts/check-elixir-candidate.sh ARCHIVE VERSION SHA256" >&2
  exit 2
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/responder-elixir-candidate.XXXXXX")
database_name="responder_candidate_${$}_${RANDOM}"
restore_database_name="${database_name}_restore"
candidate_pid=
database_created=0
restore_database_created=0

cleanup() {
  if [[ -n $candidate_pid ]] && kill -0 "$candidate_pid" 2>/dev/null; then
    kill -TERM "$candidate_pid" 2>/dev/null || true
    wait "$candidate_pid" 2>/dev/null || true
  fi

  if [[ $restore_database_created == 1 ]]; then
    PGDATABASE=postgres dropdb --if-exists "$restore_database_name" >/dev/null 2>&1 || true
  fi

  if [[ $database_created == 1 ]]; then
    PGDATABASE=postgres dropdb --if-exists "$database_name" >/dev/null 2>&1 || true
  fi

  rm -rf -- "$scratch"
}

trap cleanup EXIT

container=$("${compose[@]}" ps --quiet episode-db)

if [[ -z $container ]] ||
  [[ $(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container") != healthy ]]; then
  "${compose[@]}" up --detach --wait episode-db >/dev/null
fi

address=$("${compose[@]}" port episode-db 5432)
export PGHOST=127.0.0.1
export PGPASSWORD=postgres
export PGPORT=${address##*:}
export PGUSER=postgres
export PGDATABASE=postgres

createdb "$database_name"
database_created=1

candidate_port=${RESPONDER_CANDIDATE_PORT:-$((44000 + $$ % 10000))}

if curl --silent --fail --max-time 1 "http://127.0.0.1:$candidate_port/healthz" >/dev/null 2>&1; then
  echo "candidate control-plane port $candidate_port is already in use" >&2
  exit 1
fi

install_prefix="$scratch/install"
"$root/scripts/install-elixir-release.sh" \
  "$archive" "$expected_version" "$expected_sha256" "$install_prefix" \
  --local-build >/dev/null

binary="$install_prefix/current/bin/responder"
release_tmp="$scratch/release-tmp"
mkdir -p "$release_tmp"

migration_count=

run_candidate() {
  local boot=$1
  local target_database=$2
  local candidate_database_url="ecto://postgres:postgres@127.0.0.1:$PGPORT/$target_database"
  local current_migration_count
  local log="$scratch/candidate-$boot.log"
  local ready=0
  local runtime_env=(
    "DATABASE_URL=$candidate_database_url"
    "POOL_SIZE=4"
    "RELEASE_DISTRIBUTION=none"
    "RELEASE_TMP=$release_tmp"
    "RESPONDER_CONTROL_PORT=$candidate_port"
    "RESPONDER_STATE_DIR=$scratch/state"
  )

  env "${runtime_env[@]}" "$binary" eval 'Responder.Release.migrate()' >/dev/null

  current_migration_count=$(PGDATABASE="$target_database" psql --no-psqlrc --tuples-only --no-align \
    --command 'SELECT count(*) FROM schema_migrations')

  if [[ -z $migration_count ]]; then
    migration_count=$current_migration_count
  elif [[ $current_migration_count != "$migration_count" ]]; then
    echo "release restart changed the applied migration set: $migration_count -> $current_migration_count" >&2
    exit 1
  fi

  env "${runtime_env[@]}" "$binary" start >"$log" 2>&1 &
  candidate_pid=$!

  for _attempt in $(seq 1 100); do
    if ! kill -0 "$candidate_pid" 2>/dev/null; then
      echo "release candidate $boot boot exited before readiness" >&2
      cat "$log" >&2
      exit 1
    fi

    if curl --silent --fail --max-time 1 "http://127.0.0.1:$candidate_port/healthz" >/dev/null &&
      curl --silent --fail --max-time 1 "http://127.0.0.1:$candidate_port/readyz" >/dev/null; then
      ready=1
      break
    fi

    sleep 0.1
  done

  if [[ $ready != 1 ]]; then
    echo "release candidate $boot boot did not become ready" >&2
    cat "$log" >&2
    exit 1
  fi

  curl --silent --fail --max-time 2 "http://127.0.0.1:$candidate_port/metrics" |
    grep -q '^responder_queue_claimable'

  kill -TERM "$candidate_pid"
  wait "$candidate_pid"
  candidate_pid=
}

run_candidate first "$database_name"
run_candidate restart "$database_name"

backup_marker=durable-state-survives-backup
backup_archive="$scratch/responder.dump"

PGDATABASE="$database_name" psql --no-psqlrc --set ON_ERROR_STOP=1 --quiet \
  --command 'CREATE TABLE responder_candidate_backup_proof (value text PRIMARY KEY)' \
  --command "INSERT INTO responder_candidate_backup_proof (value) VALUES ('$backup_marker')"

pg_dump --format=custom --file="$backup_archive" "$database_name"
pg_restore --list "$backup_archive" >/dev/null

createdb "$restore_database_name"
restore_database_created=1
pg_restore --exit-on-error --no-owner --no-privileges \
  --dbname="$restore_database_name" "$backup_archive"

restored_marker=$(PGDATABASE="$restore_database_name" psql --no-psqlrc --tuples-only --no-align \
  --command 'SELECT value FROM responder_candidate_backup_proof')

if [[ $restored_marker != "$backup_marker" ]]; then
  echo "restored database did not preserve the durable backup marker" >&2
  exit 1
fi

run_candidate restored "$restore_database_name"

echo "Elixir release $expected_version started with no application configuration file, migrated idempotently, restarted from the same database, restored a verified backup, became ready, exported metrics, and stopped cleanly"
