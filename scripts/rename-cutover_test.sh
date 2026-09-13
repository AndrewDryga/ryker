#!/usr/bin/env bash
# Proves the rename cutover's decision logic against a fake host.
#
# The cutover runs once, on the production Mac, against the live database and
# launchd domain; there is no second run in which to learn that it renamed
# before it stopped, moved before it dumped, or put the password on a command
# line. So every tool it touches is replaced here with a recorder, the old
# layout is rebuilt under a throwaway HOME for each case, and the assertions
# read the recorded calls and the files left behind.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export FAKE_WORK=$work
home=$work/home
old_root=$home/.local/state/responder
new_root=$home/.local/state/ryker
agents=$home/Library/LaunchAgents
coop_bin=$home/.local/lib/responder-coop/releases/87e5d13cf9fb91ea69db8441c0d50cc29bc2cdf5/coop
uid=$(id -u)
domain="gui/$uid"

mkdir -p "$work/bin"
PATH="$work/bin:$PATH"
export PATH

# --- fakes ------------------------------------------------------------------

# The waits in the script are real seconds; here they are free.
cat >"$work/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# launchctl: the loaded set lives in $FAKE_WORK/loaded; print answers from
# $FAKE_WORK/print-<label>.txt when present; labels in $FAKE_WORK/sticky
# survive bootout, which is how a job that will not die is simulated.
cat >"$work/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
work=$FAKE_WORK
printf 'launchctl %s\n' "$*" >>"$work/launchctl.log"
printf 'launchctl %s\n' "$*" >>"$work/events.log"
loaded() { grep -qx -- "$1" "$work/loaded" 2>/dev/null; }
case ${1:-} in
  print)
    label=${2##*/}
    if loaded "$label"; then
      if [[ -f $work/print-$label.txt ]]; then
        cat "$work/print-$label.txt"
      else
        printf 'gui/501/%s = {\n\tstate = running\n}\n' "$label"
      fi
      exit 0
    fi
    echo "Could not find service \"$label\" in domain for uid: 501" >&2
    exit 113
    ;;
  bootout)
    label=${2##*/}
    if grep -qx -- "$label" "$work/sticky" 2>/dev/null; then
      exit 0
    fi
    if loaded "$label"; then
      grep -vx -- "$label" "$work/loaded" >"$work/loaded.next" || true
      mv "$work/loaded.next" "$work/loaded"
      exit 0
    fi
    echo "Boot-out failed: 3: No such process" >&2
    exit 3
    ;;
  bootstrap)
    plist=${3:-}
    [[ -f $plist ]] || { echo "fake launchctl: bootstrap of a missing plist '$plist'" >&2; exit 5; }
    label=${plist##*/}
    echo "${label%.plist}" >>"$work/loaded"
    exit 0
    ;;
  submit)
    shift
    while [[ $# -gt 0 ]]; do
      case $1 in
        -l) echo "$2" >>"$work/loaded"; shift 2 ;;
        --) break ;;
        *) shift ;;
      esac
    done
    exit 0
    ;;
  *)
    echo "fake launchctl: unexpected call: $*" >&2
    exit 64
    ;;
esac
EOF

# psql: records argv (which must never carry a password) and answers from
# $FAKE_WORK/db-state, connections and verify-fail-count. It also holds the
# script to the connection contract: superuser work goes to postgres/postgres
# on the host and port from DATABASE_URL, and the verification uses the
# application's own credentials.
cat >"$work/bin/psql" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
work=$FAKE_WORK
state=$work/db-state
case ${PGPASSWORD:-} in
  secret-pass) credential=app ;;
  postgres) credential=super ;;
  '') credential=none ;;
  *) credential=other ;;
esac
sql=
host=
port=
user=
database=
args=("$@")
while [[ $# -gt 0 ]]; do
  case $1 in
    -c) sql=$2; shift 2 ;;
    -h) host=$2; shift 2 ;;
    -p) port=$2; shift 2 ;;
    -U) user=$2; shift 2 ;;
    -d) database=$2; shift 2 ;;
    -v | -f) shift 2 ;;
    *) shift ;;
  esac
done
if [[ -z $sql ]]; then
  sql=$(cat)
  printf '%s\n' "$sql" >>"$work/psql-stdin.log"
  printf 'psql [credential=%s] stdin: %s\n' "$credential" "${args[*]}" >>"$work/psql.log"
  printf 'psql [credential=%s] stdin: %s\n' "$credential" "${args[*]}" >>"$work/events.log"
else
  printf 'psql [credential=%s] %s\n' "$credential" "${args[*]}" >>"$work/psql.log"
  printf 'psql [credential=%s] %s\n' "$credential" "${args[*]}" >>"$work/events.log"
fi
if [[ $host != 127.0.0.1 || $port != 5432 ]]; then
  echo "fake psql: expected the host and port from DATABASE_URL, got '$host:$port'" >&2
  exit 64
fi
superuser() {
  if [[ $credential != super || $user != postgres || $database != postgres ]]; then
    echo "fake psql: '$sql' must run as postgres/postgres on the postgres database (got $credential $user@$database)" >&2
    exit 64
  fi
}
case $sql in
  *pg_stat_activity*)
    superuser
    cat "$work/connections" 2>/dev/null || echo 0
    ;;
  *"from pg_database where datname = '"*)
    superuser
    name=${sql#*"datname = '"}
    name=${name%%\'*}
    if grep -qx -- "database=$name" "$state"; then echo 1; else echo 0; fi
    ;;
  *"from pg_roles where rolname = '"*)
    superuser
    name=${sql#*"rolname = '"}
    name=${name%%\'*}
    if grep -qx -- "role=$name" "$state"; then echo 1; else echo 0; fi
    ;;
  "ALTER DATABASE \""*"\" RENAME TO \""*)
    superuser
    rest=${sql#ALTER DATABASE \"}
    from=${rest%%\"*}
    to=${rest#*RENAME TO \"}
    to=${to%%\"*}
    grep -qx -- "database=$from" "$state" || { echo "ERROR:  database \"$from\" does not exist" >&2; exit 1; }
    sed "s/^database=$from\$/database=$to/" "$state" >"$state.next" && mv "$state.next" "$state"
    ;;
  "ALTER ROLE \""*"\" RENAME TO \""*)
    superuser
    rest=${sql#ALTER ROLE \"}
    from=${rest%%\"*}
    to=${rest#*RENAME TO \"}
    to=${to%%\"*}
    grep -qx -- "role=$from" "$state" || { echo "ERROR:  role \"$from\" does not exist" >&2; exit 1; }
    sed "s/^role=$from\$/role=$to/" "$state" >"$state.next" && mv "$state.next" "$state"
    ;;
  "ALTER ROLE \""*"\" PASSWORD '"*)
    superuser
    ;;
  "select 1")
    remaining=$(cat "$work/verify-fail-count" 2>/dev/null || echo 0)
    if [[ $remaining -gt 0 ]]; then
      echo $((remaining - 1)) >"$work/verify-fail-count"
      echo 'psql: error: connection to server at "127.0.0.1", port 5432 failed: FATAL:  password authentication failed for user "ryker_emisar"' >&2
      exit 2
    fi
    if [[ $credential != app || $user != ryker_emisar || $database != ryker_emisar ]]; then
      echo "fake psql: the verification must use the application's credentials against ryker_emisar (got $credential $user@$database)" >&2
      exit 64
    fi
    echo 1
    ;;
  *)
    echo "fake psql: unexpected SQL: $sql" >&2
    exit 64
    ;;
esac
EOF

# pg_dump: records its arguments and writes the --file target.
cat >"$work/bin/pg_dump" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
work=$FAKE_WORK
case ${PGPASSWORD:-} in
  postgres) credential=super ;;
  '') credential=none ;;
  *) credential=other ;;
esac
printf 'pg_dump [credential=%s] %s\n' "$credential" "$*" >>"$work/pg_dump.log"
printf 'pg_dump [credential=%s] %s\n' "$credential" "$*" >>"$work/events.log"
target=
for arg in "$@"; do
  case $arg in
    --file=*) target=${arg#--file=} ;;
  esac
done
[[ -n $target ]] || { echo "fake pg_dump: no --file given" >&2; exit 64; }
[[ -d ${target%/*} ]] || { echo "fake pg_dump: the directory of $target does not exist" >&2; exit 64; }
echo "fake dump" >"$target"
EOF

# plutil: records the call; on a Mac the real one still lints the rendering.
cat >"$work/bin/plutil" <<'EOF'
#!/usr/bin/env bash
printf 'plutil %s\n' "$*" >>"$FAKE_WORK/plutil.log"
if [[ -x /usr/bin/plutil ]]; then
  exec /usr/bin/plutil "$@"
fi
exit 0
EOF

chmod +x "$work/bin/"*

# --- fixtures ---------------------------------------------------------------

reset_logs() {
  : >"$work/launchctl.log"
  : >"$work/psql.log"
  : >"$work/psql-stdin.log"
  : >"$work/pg_dump.log"
  : >"$work/plutil.log"
  : >"$work/events.log"
  rm -f "$work/connections" "$work/sticky" "$work/verify-fail-count"
}

write_plist() {
  # write_plist FILE LABEL ARG...: a launchd job in the real worker's shape.
  local file=$1 label=$2 arg
  shift 2
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n'
    printf '  <key>KeepAlive</key>\n  <true/>\n'
    printf '  <key>Label</key>\n  <string>%s</string>\n' "$label"
    printf '  <key>ProgramArguments</key>\n  <array>\n'
    for arg in "$@"; do
      printf '    <string>%s</string>\n' "$arg"
    done
    printf '  </array>\n'
    printf '  <key>RunAtLoad</key>\n  <true/>\n'
    printf '  <key>StandardErrorPath</key>\n  <string>%s/emisar/coop-worker/log/worker.stderr.log</string>\n' "$old_root"
    printf '  <key>StandardOutPath</key>\n  <string>%s/emisar/coop-worker/log/worker.stdout.log</string>\n' "$old_root"
    printf '  <key>ThrottleInterval</key>\n  <integer>5</integer>\n'
    printf '</dict>\n</plist>\n'
  } >"$file"
}

old_layout() {
  # The host as it is today: the old state root, the old jobs, nothing new.
  rm -rf "$home"
  mkdir -p "$old_root/emisar/coop-worker" "$old_root/emisar/backups" \
    "$old_root/emisar/coop-component" "$old_root/blitz" "$old_root/eval-history" "$agents"

  cat >"$old_root/emisar/runtime.env" <<EOF
SLACK_BOT_TOKEN=xoxb-test
DATABASE_URL=ecto://responder_emisar:secret-pass@127.0.0.1:5432/responder_emisar
POOL_SIZE=10
RELEASE_DISTRIBUTION=name
RELEASE_NODE=responder-emisar
RELEASE_COOKIE=cookie-test
RELEASE_TMP=$old_root/emisar/release-tmp
# retired by the durable settings cutover; the release ignores it
# RESPONDER_ELIXIR_CONFIG=$old_root/emisar/responder-elixir.yaml
RESPONDER_STATE_TOOLS_TOKEN=tools-token
RESPONDER_STATE_DIR=$old_root/emisar
RESPONDER_WORKER_PUBLIC_URL=https://127.0.0.1:4322
RESPONDER_WORKER_CA_FILE=$old_root/emisar/worker-ca.pem
RESPONDER_WORKER_CA_KEY_FILE=$old_root/emisar/worker-ca-key.pem
RESPONDER_WORKER_CERT_FILE=$old_root/emisar/worker-gateway.pem
RESPONDER_WORKER_KEY_FILE=$old_root/emisar/worker-gateway-key.pem
RESPONDER_CONTROL_PORT=4321
EOF
  chmod 0600 "$old_root/emisar/runtime.env"

  cat >"$old_root/emisar/coop-worker/worker.json" <<EOF
{
  "version": 1,
  "worker_id": "emisar-local-worker",
  "responder_url": "https://127.0.0.1:4322",
  "ca_file": "$old_root/emisar/worker-ca.pem",
  "identity_file": "$old_root/emisar/coop-worker/identity.pem",
  "enrollment_token_file": "$old_root/emisar/coop-worker/enrollment.token",
  "coop_socket": "$old_root/emisar/coop-component/control.sock",
  "journal_dir": "$old_root/emisar/coop-worker/journal",
  "policy_digests": {
    "responder-learning-v2": "d46224304ab08ceb6f10da8b6f3616d404b915e56c6d294ba6a1945557fc2a27"
  },
  "session_state_dir": "$old_root/emisar/coop-component",
  "session_policy_path": "$old_root/emisar/session-policies.yaml"
}
EOF

  cat >"$old_root/emisar/session-policies.yaml" <<EOF
policies:
  responder-learning-personal-v1:
    repository: $old_root/emisar/learning-scratch
  emisar-standard-v2:
    repositories:
      - name: responder
        repository: /Users/andrewdryga/Projects/os/responder
EOF

  printf '{"policy_file":"%s/emisar/session-policies.yaml","policy_digests":{"emisar-standard-v1":"75b3"}}' \
    "$old_root" >"$old_root/emisar/policy-digests.json"

  write_plist "$agents/ai.emisar.responder.plist" ai.emisar.responder \
    /bin/bash -c "set -a; . \"$old_root/emisar/runtime.env\"; set +a; exec responder start"
  write_plist "$agents/ai.emisar.responder.emisar-coop-worker.plist" \
    ai.emisar.responder.emisar-coop-worker \
    "$coop_bin" sessions connect --config "$old_root/emisar/coop-worker/worker.json"
  write_plist "$agents/ai.emisar.responder.emisar.plist.staged-39581e7" ai.emisar.responder.emisar \
    /bin/true
  write_plist "$agents/ai.emisar.responder.watchdog.plist" ai.emisar.responder.watchdog /bin/true
  write_plist "$agents/ai.emisar.responder.quality-watch.plist" ai.emisar.responder.quality-watch /bin/true
  write_plist "$agents/com.example.other.plist" com.example.other /bin/true

  printf '%s\n' ai.emisar.responder ai.emisar.responder.emisar-coop-worker responder-emisar-coop \
    >"$work/loaded"
  printf 'database=responder_emisar\nrole=responder_emisar\n' >"$work/db-state"

  # The serve sidecar as launchctl print shows it: submitted without a plist.
  {
    printf 'gui/%s/responder-emisar-coop = {\n' "$uid"
    printf '\tactive count = 1\n\tpath = (submitted by launchctl[5905])\n\ttype = Submitted\n\tstate = running\n\n'
    printf '\tprogram = /usr/bin/env\n\targuments = {\n'
    for arg in /usr/bin/env "HOME=$home" \
      "PATH=/opt/homebrew/bin:/usr/local/bin:$home/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      "$coop_bin" sessions serve \
      --state "$old_root/emisar/coop-component" \
      --policies "$old_root/emisar/session-policies.yaml" \
      --socket "$old_root/emisar/coop-component/control.sock"; do
      printf '\t\t%s\n' "$arg"
    done
    printf '\t}\n\n'
    printf '\tstdout path = %s/emisar/coop-component/serve-87e5d13.log\n' "$old_root"
    printf '\tstderr path = %s/emisar/coop-component/serve-87e5d13.err\n' "$old_root"
    printf '\tinherited environment = {\n\t\tSSH_AUTH_SOCK => /private/tmp/com.apple.launchd.x/Listeners\n\t}\n\n'
    printf '\tdomain = gui/%s [100018]\n\tpid = 5906\n}\n' "$uid"
  } >"$work/print-responder-emisar-coop.txt"

  reset_logs
}

run_cutover() {
  # run_cutover SUBCOMMAND: the script against the fake HOME; $status, $output.
  set +e
  output=$(HOME=$home "$root/scripts/rename-cutover.sh" "$1" 2>&1)
  status=$?
  set -e
}

fail() {
  echo "$1" >&2
  echo "--- output" >&2
  printf '%s\n' "$output" >&2
  echo "--- events" >&2
  cat "$work/events.log" >&2
  exit 1
}

event_line() {
  # event_line NEEDLE: the position of the first matching recorded event.
  grep -nF -- "$1" "$work/events.log" | head -n 1 | cut -d: -f1
}

no_calls() {
  [[ ! -s $work/launchctl.log && ! -s $work/psql.log && ! -s $work/pg_dump.log ]]
}

private() {
  # private FILE: mode 0600 exactly, on BSD and GNU find alike.
  [[ -n $(find "$1" -perm 0600) ]]
}

# --- (1) neither layout -----------------------------------------------------

rm -rf "$home"
mkdir -p "$agents"
reset_logs
run_cutover prepare
if [[ $status -ne 0 || $output != *"deploy: cutover: nothing to cut over"* ]]; then
  fail "a host with neither layout must be left alone (exit $status)"
fi
if ! no_calls; then
  fail "a host with neither layout must not touch launchd or PostgreSQL"
fi

# --- (2) new layout only ----------------------------------------------------

rm -rf "$home"
mkdir -p "$agents" "$new_root/emisar/backups"
printf 'DATABASE_URL=ecto://ryker_emisar:secret-pass@127.0.0.1:5432/ryker_emisar\n' >"$new_root/emisar/runtime.env"
date -u +%Y-%m-%dT%H:%M:%SZ >"$new_root/emisar/backups/rename-cutover.done"
reset_logs
run_cutover prepare
if [[ $status -ne 0 || $output != *"deploy: cutover: already complete"* ]]; then
  fail "a completed cutover must be recognised as complete (exit $status)"
fi
if ! no_calls; then
  fail "a completed cutover must not touch launchd or PostgreSQL again"
fi

# --- (3) both layouts -------------------------------------------------------

old_layout
mkdir -p "$new_root/emisar"
touch "$new_root/emisar/runtime.env"
run_cutover prepare
if [[ $status -ne 1 || $output != *"deploy: cutover: both $old_root/emisar and $new_root/emisar exist; finish or remove one by hand"* ]]; then
  fail "two layouts must be refused, never merged (exit $status)"
fi
if ! no_calls; then
  fail "refusing two layouts must not touch launchd or PostgreSQL"
fi
if [[ ! -f $old_root/emisar/runtime.env || ! -f $new_root/emisar/runtime.env ]]; then
  fail "refusing two layouts must leave both in place"
fi
if grep -q RYKER_ "$old_root/emisar/runtime.env"; then
  fail "refusing two layouts must not rewrite the old runtime.env"
fi

# --- (4) the happy path -----------------------------------------------------

old_layout
run_cutover prepare
if [[ $status -ne 0 ]]; then
  fail "the cutover of the old layout must succeed (exit $status)"
fi
if [[ -n ${RENAME_CUTOVER_TEST_SHOW:-} ]]; then
  printf '%s\n' "$output"
  echo "--- events"
  cat "$work/events.log"
fi

# Stop first, rename second: the serve job's arguments are read from launchd
# before it is booted out, and every old job is gone before PostgreSQL is
# asked to rename anything.
captured=$(event_line "launchctl print $domain/responder-emisar-coop")
rename=$(event_line 'ALTER DATABASE "responder_emisar" RENAME TO "ryker_emisar"')
if [[ -z $rename ]]; then
  fail "the database must be renamed with ALTER DATABASE"
fi
for label in ai.emisar.responder ai.emisar.responder.emisar-coop-worker responder-emisar-coop; do
  booted=$(event_line "launchctl bootout $domain/$label")
  if [[ -z $booted ]]; then
    fail "$label must be booted out"
  fi
  if [[ $booted -gt $rename ]]; then
    fail "$label must be booted out before the database is renamed"
  fi
done
if [[ -z $captured || $captured -gt $(event_line "launchctl bootout $domain/responder-emisar-coop") ]]; then
  fail "the serve job's arguments must be captured before it is booted out"
fi

# Check the pool, dump, then rename; the dump lands in the old root, which
# is then moved wholesale.
activity=$(event_line "pg_stat_activity where datname = 'responder_emisar' and pid <> pg_backend_pid()")
dumped=$(event_line "pg_dump [credential=super]")
if [[ -z $activity || -z $dumped || $activity -gt $dumped ]]; then
  fail "the connection check must run before the dump"
fi
if [[ $dumped -gt $rename ]]; then
  fail "the dump must be taken before the rename"
fi
if ! grep -q -- "--format=custom --no-owner --no-privileges -h 127.0.0.1 -p 5432 -U postgres --file=$old_root/emisar/backups/pre-rename-.*\.dump responder_emisar" "$work/pg_dump.log"; then
  fail "the dump must be a custom-format superuser dump of responder_emisar into the old backups directory"
fi
if ! grep -q 'ALTER ROLE "responder_emisar" RENAME TO "ryker_emisar"' "$work/psql.log"; then
  fail "the role must be renamed with ALTER ROLE"
fi
if [[ $(grep -c 'RENAME TO' "$work/psql.log") -ne 2 ]]; then
  fail "exactly one database and one role rename are expected"
fi
if grep -q secret-pass "$work/psql.log" "$work/launchctl.log" "$work/pg_dump.log" "$work/plutil.log"; then
  fail "the application password must never appear on a command line"
fi
if [[ -s $work/psql-stdin.log ]]; then
  fail "no password reset is expected while the credentials still verify"
fi
if ! grep -q "psql \[credential=app\] .*-U ryker_emisar -d ryker_emisar -c select 1" "$work/psql.log"; then
  fail "the application credentials must be verified against the renamed role and database"
fi
if [[ -e $old_root ]]; then
  fail "the old state root must have been moved"
fi
dumps=("$new_root"/emisar/backups/pre-rename-*.dump)
if [[ ${#dumps[@]} -ne 1 || ! -f ${dumps[0]} ]]; then
  fail "the pre-rename dump must travel with the moved root"
fi
if ! private "${dumps[0]}"; then
  fail "the dump must be private to the operator"
fi
copies=("$new_root"/emisar/backups/pre-rename-*.runtime.env)
if [[ ${#copies[@]} -ne 1 ]] || ! grep -q '^RESPONDER_STATE_DIR=' "${copies[0]}"; then
  fail "the pre-rename runtime.env must be kept for a manual rollback"
fi
if [[ ! -f $new_root/emisar/backups/rename-cutover.done ]]; then
  fail "a finished prepare must leave its marker"
fi
if [[ ! -d $new_root/blitz || ! -d $new_root/eval-history ]]; then
  fail "the sibling deployments must move with the root"
fi

# runtime.env: new keys, new names, new paths, and the secret untouched.
env_file=$new_root/emisar/runtime.env
for line in \
  "DATABASE_URL=ecto://ryker_emisar:secret-pass@127.0.0.1:5432/ryker_emisar" \
  "RELEASE_NODE=ryker-emisar" \
  "RELEASE_TMP=$new_root/emisar/release-tmp" \
  "# RYKER_ELIXIR_CONFIG=$new_root/emisar/responder-elixir.yaml" \
  "RYKER_STATE_DIR=$new_root/emisar" \
  "RYKER_WORKER_CA_FILE=$new_root/emisar/worker-ca.pem" \
  "RYKER_WORKER_KEY_FILE=$new_root/emisar/worker-gateway-key.pem" \
  "RYKER_CONTROL_PORT=4321" \
  "SLACK_BOT_TOKEN=xoxb-test"; do
  if ! grep -qxF -- "$line" "$env_file"; then
    fail "runtime.env must carry '$line'"
  fi
done
if grep -q 'RESPONDER_' "$env_file" || grep -qF "$old_root" "$env_file"; then
  fail "runtime.env must carry no old key or old path"
fi
if ! private "$env_file"; then
  fail "runtime.env must keep its private mode through the rewrite"
fi

# worker.json and the policies: paths move; contracts with co:op stay.
worker=$new_root/emisar/coop-worker/worker.json
for line in \
  '"responder_url": "https://127.0.0.1:4322",' \
  "\"ca_file\": \"$new_root/emisar/worker-ca.pem\"," \
  "\"coop_socket\": \"$new_root/emisar/coop-component/control.sock\"," \
  "\"journal_dir\": \"$new_root/emisar/coop-worker/journal\"," \
  "\"session_policy_path\": \"$new_root/emisar/session-policies.yaml\""; do
  if ! grep -qF -- "$line" "$worker"; then
    fail "worker.json must carry '$line'"
  fi
done
if ! grep -q '"responder-learning-v2"' "$worker" || grep -qF "$old_root" "$worker"; then
  fail "worker.json must keep the policy names and lose the old paths"
fi
policies=$new_root/emisar/session-policies.yaml
for line in \
  "  responder-learning-personal-v1:" \
  "    repository: $new_root/emisar/learning-scratch" \
  "      - name: responder" \
  "        repository: /Users/andrewdryga/Projects/os/responder"; do
  if ! grep -qxF -- "$line" "$policies"; then
    fail "session-policies.yaml must carry '$line'"
  fi
done
if grep -qF "$old_root" "$policies"; then
  fail "session-policies.yaml must lose the old paths"
fi
if ! grep -qF "\"policy_file\":\"$new_root/emisar/session-policies.yaml\"" "$new_root/emisar/policy-digests.json"; then
  fail "policy-digests.json must point at the moved policy file"
fi

# The serve sidecar again, under the new label, with every path moved and
# the co:op binary where it was.
submit=$(grep -F "launchctl submit -l ryker-emisar-coop" "$work/launchctl.log" || true)
expected_submit="launchctl submit -l ryker-emisar-coop -o $new_root/emisar/coop-component/serve-87e5d13.log -e $new_root/emisar/coop-component/serve-87e5d13.err -- /usr/bin/env HOME=$home PATH=/opt/homebrew/bin:/usr/local/bin:$home/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin $coop_bin sessions serve --state $new_root/emisar/coop-component --policies $new_root/emisar/session-policies.yaml --socket $new_root/emisar/coop-component/control.sock"
if [[ $submit != "$expected_submit" ]]; then
  fail "the serve sidecar must be re-submitted with its paths moved and its binary unchanged; got: $submit"
fi
if [[ $(grep -c 'launchctl submit' "$work/launchctl.log") -ne 1 ]]; then
  fail "the serve sidecar must be submitted exactly once"
fi
if [[ ! -f $new_root/emisar/backups/responder-emisar-coop.argv ]]; then
  fail "the serve sidecar's arguments must be saved for a rerun"
fi

# The worker sidecar: a new plist rendered from the old one, then loaded.
worker_plist=$agents/ai.emisar.ryker.emisar-coop-worker.plist
if [[ ! -f $worker_plist ]]; then
  fail "the worker plist must be rendered under the new label"
fi
for line in \
  "  <string>ai.emisar.ryker.emisar-coop-worker</string>" \
  "    <string>$coop_bin</string>" \
  "    <string>$new_root/emisar/coop-worker/worker.json</string>" \
  "  <string>$new_root/emisar/coop-worker/log/worker.stderr.log</string>" \
  "  <string>$new_root/emisar/coop-worker/log/worker.stdout.log</string>"; do
  if ! grep -qxF -- "$line" "$worker_plist"; then
    fail "the worker plist must carry '$line'"
  fi
done
if grep -q 'ai.emisar.responder' "$worker_plist" || grep -qF "$old_root" "$worker_plist"; then
  fail "the worker plist must carry no old label or old path"
fi
if ! grep -qF "launchctl bootstrap $domain $worker_plist" "$work/launchctl.log"; then
  fail "the worker plist must be bootstrapped"
fi
if ! grep -qF "plutil -lint " "$work/plutil.log"; then
  fail "the rendered worker plist must be linted"
fi
if [[ ! -f $agents/ai.emisar.responder.emisar-coop-worker.plist || ! -f $agents/ai.emisar.responder.plist ]]; then
  fail "prepare must leave the old plists for finish"
fi

# --- (7) rerunning a finished prepare changes nothing ----------------------

reset_logs
run_cutover prepare
if [[ $status -ne 0 || $output != *"deploy: cutover: already complete"* ]]; then
  fail "a second prepare after success must report completion (exit $status)"
fi
if ! no_calls; then
  fail "a second prepare after success must not touch launchd or PostgreSQL"
fi

# --- (8) finish retires the old plists once the new release serves ---------

write_plist "$agents/ai.emisar.ryker.plist" ai.emisar.ryker /bin/true
printf '%s\n' ai.emisar.ryker ai.emisar.responder.watchdog >>"$work/loaded"
reset_logs
run_cutover finish
if [[ $status -ne 0 ]]; then
  fail "finish on a prepared host must succeed (exit $status)"
fi
if ! grep -qF "launchctl bootout $domain/ai.emisar.responder.watchdog" "$work/launchctl.log"; then
  fail "finish must boot out an old label that is still loaded"
fi
if grep -q 'launchctl bootout gui/[0-9]*/ai.emisar.ryker' "$work/launchctl.log"; then
  fail "finish must not boot out the new jobs"
fi
for file in ai.emisar.responder.plist ai.emisar.responder.emisar-coop-worker.plist \
  ai.emisar.responder.emisar.plist.staged-39581e7 ai.emisar.responder.watchdog.plist \
  ai.emisar.responder.quality-watch.plist; do
  if [[ -e $agents/$file ]]; then
    fail "finish must remove $file"
  fi
  if [[ $output != *"deploy: cutover: removed $agents/$file"* ]]; then
    fail "finish must log the removal of $file"
  fi
done
for file in ai.emisar.ryker.plist ai.emisar.ryker.emisar-coop-worker.plist com.example.other.plist; do
  if [[ ! -f $agents/$file ]]; then
    fail "finish must leave $file alone"
  fi
done
if grep -qx ai.emisar.responder.watchdog "$work/loaded"; then
  fail "finish must leave the old watchdog label unloaded"
fi

reset_logs
run_cutover finish
if [[ $status -ne 0 || $output == *"removed"* ]]; then
  fail "a second finish must be a quiet no-op (exit $status)"
fi

grep -vx ai.emisar.ryker "$work/loaded" >"$work/loaded.next" || true
mv "$work/loaded.next" "$work/loaded"
write_plist "$agents/ai.emisar.responder.plist" ai.emisar.responder /bin/true
run_cutover finish
if [[ $status -ne 1 || $output != *"is not loaded"* ]]; then
  fail "finish must refuse while the new release is not loaded (exit $status)"
fi
if [[ ! -f $agents/ai.emisar.responder.plist ]]; then
  fail "a refused finish must not remove anything"
fi

# --- (4b) a rename that drops the password is repaired through stdin ------

old_layout
echo 1 >"$work/verify-fail-count"
run_cutover prepare
if [[ $status -ne 0 || $output != *"setting the role's password again"* ]]; then
  fail "a password lost in the role rename must be set again (exit $status)"
fi
if [[ $(grep -c 'ALTER ROLE "ryker_emisar" PASSWORD' "$work/psql-stdin.log") -ne 1 ]]; then
  fail "the password must be set exactly once, through psql's stdin"
fi
if ! grep -qF "ALTER ROLE \"ryker_emisar\" PASSWORD 'secret-pass';" "$work/psql-stdin.log"; then
  fail "the password set through stdin must be the application's own"
fi
if grep -q secret-pass "$work/psql.log" "$work/launchctl.log" "$work/pg_dump.log" "$work/plutil.log"; then
  fail "the application password must never appear on a command line, even when it is reset"
fi
if [[ $(grep -c 'credential=app.* -c select 1' "$work/psql.log") -ne 2 ]]; then
  fail "the credentials must be verified again after the reset"
fi

# --- (5) an old job that will not die stops everything ---------------------

old_layout
echo ai.emisar.responder >"$work/sticky"
run_cutover prepare
if [[ $status -ne 1 || $output != *"still loaded in $domain"*"ai.emisar.responder"* ]]; then
  fail "a release still loaded after bootout must be refused (exit $status)"
fi
if grep -q 'RENAME TO' "$work/psql.log" || [[ -s $work/pg_dump.log ]]; then
  fail "nothing may be dumped or renamed while the old release is loaded"
fi
if [[ ! -d $old_root || -e $new_root ]]; then
  fail "nothing may be moved while the old release is loaded"
fi

# --- (6) lingering connections stop everything -----------------------------

old_layout
echo 3 >"$work/connections"
run_cutover prepare
if [[ $status -ne 1 || $output != *"3 connection(s) to responder_emisar remain"* ]]; then
  fail "lingering connections must be refused with their count (exit $status)"
fi
if grep -q 'RENAME TO' "$work/psql.log" || [[ -s $work/pg_dump.log ]]; then
  fail "nothing may be dumped or renamed while connections remain"
fi
if [[ ! -d $old_root || -e $new_root ]]; then
  fail "nothing may be moved while connections remain"
fi

# --- (7b) a rerun after a partial failure finishes the rest ----------------

# The state after a crash between the move and the rewrite: the database and
# role already renamed, the root already moved, the serve job's arguments
# saved, and neither sidecar re-created.
old_layout
mv "$old_root" "$new_root"
printf 'database=ryker_emisar\nrole=ryker_emisar\n' >"$work/db-state"
: >"$work/loaded"
for arg in /usr/bin/env "HOME=$home" \
  "PATH=/opt/homebrew/bin:/usr/local/bin:$home/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$coop_bin" sessions serve \
  --state "$old_root/emisar/coop-component" \
  --policies "$old_root/emisar/session-policies.yaml" \
  --socket "$old_root/emisar/coop-component/control.sock"; do
  printf '%s\n' "$arg"
done >"$new_root/emisar/backups/responder-emisar-coop.argv"
printf '%s/emisar/coop-component/serve-87e5d13.log\n%s/emisar/coop-component/serve-87e5d13.err\n' \
  "$old_root" "$old_root" >"$new_root/emisar/backups/responder-emisar-coop.stdio"
run_cutover prepare
if [[ $status -ne 0 || $output != *"deploy: cutover: resuming"* ]]; then
  fail "a rerun after a partial failure must resume (exit $status)"
fi
if grep -q 'RENAME TO' "$work/psql.log" || [[ -s $work/pg_dump.log ]]; then
  fail "a rerun must not dump or rename a database that is already renamed"
fi
if ! grep -qxF "DATABASE_URL=ecto://ryker_emisar:secret-pass@127.0.0.1:5432/ryker_emisar" "$new_root/emisar/runtime.env"; then
  fail "a rerun must still rewrite runtime.env"
fi
if [[ $(grep -F "launchctl submit -l ryker-emisar-coop" "$work/launchctl.log" || true) != "$expected_submit" ]]; then
  fail "a rerun must re-submit the serve sidecar from its saved arguments"
fi
if [[ ! -f $worker_plist ]] || ! grep -qF "launchctl bootstrap $domain $worker_plist" "$work/launchctl.log"; then
  fail "a rerun must render and bootstrap the worker plist"
fi
if [[ ! -f $new_root/emisar/backups/rename-cutover.done ]]; then
  fail "a completed rerun must leave the marker"
fi

# --- (8a) finish needs the new deployment ----------------------------------

old_layout
run_cutover finish
if [[ $status -ne 1 || $output != *"$new_root/emisar/runtime.env does not exist"* ]]; then
  fail "finish before the new deployment exists must be refused (exit $status)"
fi
if [[ ! -f $agents/ai.emisar.responder.plist ]]; then
  fail "a refused finish must not remove the old plists"
fi

echo "rename-cutover: all checks passed"
