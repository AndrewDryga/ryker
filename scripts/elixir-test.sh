#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)

cd "$root"

databases=()
private_postgres=

cleanup() {
  status=$?
  trap - EXIT

  # A private server goes whole, so only a shared one needs its databases dropped.
  if [[ -z $private_postgres ]]; then
    for database in ${databases[@]+"${databases[@]}"}; do
      PGDATABASE=$database env MIX_ENV=test scripts/elixir-mix.sh ecto.drop --quiet >/dev/null 2>&1 &
    done
    wait
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
  # C.UTF-8 is built into glibc and needs no locales package, which a box may
  # lack (2026-10-04 review); the alpine server in compose.test.yml, on musl, sorts like C.
  initdb --pgdata="$private_postgres/data" --username=postgres --auth=trust \
    --encoding=UTF8 --locale=C.UTF-8 >/dev/null

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

# shellcheck source=scripts/test-database.sh
. "$root/scripts/test-database.sh"

if ! use_test_database_server; then
  if command -v pg_ctl >/dev/null 2>&1; then
    start_private_postgres
    export PGPASSWORD=postgres
    export PGUSER=postgres
  else
    echo "no docker, no PGHOST and no pg_ctl: nothing can serve a test PostgreSQL" >&2
    exit 1
  fi
fi

if [[ ${RYKER_TEST_ISOLATED:-0} == 1 ]]; then
  export PGDATABASE="ryker_test_$$_${RANDOM}"
  isolate=1
else
  # The compose project name changed with the 2026-09-13 rename, so a fresh
  # container may be serving; ecto.create makes the shared database when it is
  # absent and is a no-op when it already exists.
  export PGDATABASE=${PGDATABASE:-ryker_test}
  isolate=0
fi

# The full suite spends most of its time in `async: false` modules, which one VM
# runs one at a time: 283 of 336 seconds on 2026-10-02. So the async files run
# together in one VM, as before, and the serial files are dealt across more VMs
# that run beside it, each with a database of its own. Mix's own --partitions
# put async files in every VM: four of them ran ~96 async tests at once and
# turned a loaded host's local test servers into timeouts. About one serial VM
# per three cores, so a small CI runner keeps one.
test_partitions() {
  local count=${RYKER_TEST_PARTITIONS:-$(($(getconf _NPROCESSORS_ONLN) / 3))}
  local logs partition file dealt=0 status=0 red="" noisy=""
  # Emisar's rule: test output stays boring. Logs are captured per test, and a
  # failing test prints what it captured, so a passing VM that printed a log
  # line let one escape every test: a defect, or a process still running
  # after its test ended.
  local noise='^[[:space:]]*[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{3} [[](warning|error)[]]'
  local pids=()
  ((count >= 1)) || count=1
  logs=$(mktemp -d "${TMPDIR:-/tmp}/ryker-test-partitions.XXXXXX")

  while IFS= read -r file; do
    if grep -q -E '^[[:space:]]*use [A-Za-z.]+,.*async: true' "$file"; then
      echo "$file" >>"$logs/0.files"
    else
      echo "$file" >>"$logs/$((dealt % count + 1)).files"
      dealt=$((dealt + 1))
    fi
  done < <(find test -name '*_test.exs' | LC_ALL=C sort)

  for ((partition = 0; partition <= count; partition++)); do
    [[ -s $logs/$partition.files ]] || continue

    if [[ $isolate == 1 ]]; then
      databases+=("${PGDATABASE}_p$partition")
    fi

    PGDATABASE="${PGDATABASE}_p$partition" \
      test_files "$logs/$partition.files" "$@" >"$logs/$partition.log" 2>&1 &
    pids[partition]=$!
  done

  for ((partition = 0; partition <= count; partition++)); do
    [[ -s $logs/$partition.files ]] || continue

    if wait "${pids[partition]}"; then
      if grep -E -q "$noise" "$logs/$partition.log"; then
        ((status != 0)) || status=1
        red="$red $partition"
        noisy="$noisy $partition"
      fi
    else
      status=$?
      red="$red $partition"
    fi

    if ((partition == 0)); then
      echo "== async files"
    else
      echo "== serial files, partition $partition of $count"
    fi

    cat "$logs/$partition.log"

    if [[ " $noisy " == *" $partition "* ]]; then
      echo "== partition $partition passed, but these lines escaped every test's log capture:"
      grep -E "$noise" "$logs/$partition.log"
    fi
  done

  echo "== red partitions:${red:- none}"
  rm -rf "$logs"
  return "$status"
}

# Creates and migrates PGDATABASE, then tests the files listed in $1.
test_files() {
  local list=$1 file
  local files=()
  shift

  while IFS= read -r file; do
    files+=("$file")
  done <"$list"

  env MIX_ENV=test scripts/elixir-mix.sh "do" ecto.create --quiet + ecto.migrate --quiet + \
    test "$@" "${files[@]}"
}

if [[ ${1:-} == "--check" ]]; then
  shift
  env MIX_ENV=test scripts/elixir-mix.sh "do" \
    format --check-formatted + \
    compile --warnings-as-errors + \
    credo --strict
  # A test file that compiles with a warning fails the gate, as lib does above.
  test_partitions --warnings-as-errors "$@"
else
  if [[ $isolate == 1 ]]; then
    databases+=("$PGDATABASE")
  fi

  env MIX_ENV=test scripts/elixir-mix.sh "do" ecto.create --quiet + ecto.migrate --quiet + test "$@"
fi
