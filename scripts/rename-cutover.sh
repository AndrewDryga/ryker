#!/usr/bin/env bash
# One-time macOS cutover from the Responder on-host layout to the Ryker one.
#
# The tree was renamed, but the host still carries the old names: the state
# root ~/.local/state/responder, the responder_emisar database and role, the
# ai.emisar.responder launchd job, and the two co:op sidecars that share its
# state directory. scripts/deploy.sh calls this once, in two halves, around
# the first Ryker restart:
#
#   prepare   after the new archive is proven and installed, before the new
#             job is loaded: stop the old job and both sidecars, dump and
#             rename the database and role, move the whole state root,
#             rewrite the deployment's files for the new names, and re-create
#             the sidecars against the moved paths.
#   finish    after the new job answers /readyz with the new version: retire
#             every ai.emisar.responder* plist, booting out any still loaded.
#
# Every step is idempotent and logged with the prefix "deploy: cutover:". A
# rerun after a partial failure resumes where it stopped, and anything that
# would need a guess refuses instead (exit 1) rather than merge or delete.
# Nothing here discards user data: the state root moves, the database is
# dumped before it is renamed, and the old plists go only once the new
# release is serving.
#
# Manual rollback, should the new release fail to start after `prepare`:
#   1. mv ~/.local/state/ryker ~/.local/state/responder
#   2. restore emisar/runtime.env from emisar/backups/pre-rename-<stamp>.runtime.env
#   3. psql -h 127.0.0.1 -U postgres -d postgres
#        -c 'ALTER DATABASE "ryker_emisar" RENAME TO "responder_emisar"'
#        -c 'ALTER ROLE "ryker_emisar" RENAME TO "responder_emisar"'
#   4. launchctl bootstrap gui/$UID ~/Library/LaunchAgents/ai.emisar.responder.plist
#      and the same for ai.emisar.responder.emisar-coop-worker.plist; re-submit
#      the serve job from emisar/backups/responder-emisar-coop.argv.
#
# Parameters come from the environment; deploy.sh passes the values it
# computed and the rest default to the production host. Every external tool
# (launchctl, psql, pg_dump, plutil, install) is taken from PATH so the test
# can stand in for them.
set -euo pipefail

usage() {
  echo "usage: scripts/rename-cutover.sh prepare|finish" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
case $1 in
  prepare | finish) subcommand=$1 ;;
  *) usage ;;
esac

old_state_root=${OLD_STATE_ROOT:-$HOME/.local/state/responder}
old_deployment=${OLD_DEPLOYMENT:-$old_state_root/emisar}
new_state_root=${NEW_STATE_ROOT:-$HOME/.local/state/ryker}
new_deployment=${NEW_DEPLOYMENT:-$new_state_root/emisar}
old_label=${OLD_LABEL:-ai.emisar.responder}
new_label=${NEW_LABEL:-ai.emisar.ryker}
old_worker_label=${OLD_WORKER_LABEL:-ai.emisar.responder.emisar-coop-worker}
new_worker_label=${NEW_WORKER_LABEL:-ai.emisar.ryker.emisar-coop-worker}
old_coop_label=${OLD_COOP_LABEL:-responder-emisar-coop}
new_coop_label=${NEW_COOP_LABEL:-ryker-emisar-coop}
old_database=${OLD_DATABASE:-responder_emisar}
new_database=${NEW_DATABASE:-ryker_emisar}
old_role=${OLD_ROLE:-responder_emisar}
new_role=${NEW_ROLE:-ryker_emisar}
old_release_node=${OLD_RELEASE_NODE:-responder-emisar}
new_release_node=${NEW_RELEASE_NODE:-ryker-emisar}
old_env_prefix=${OLD_ENV_PREFIX:-RESPONDER_}
new_env_prefix=${NEW_ENV_PREFIX:-RYKER_}
launch_agents=${LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}
pg_superuser=${PGSUPERUSER:-postgres}
pg_superpassword=${PGSUPERPASSWORD:-postgres}

# How long to wait for launchd to finish tearing a job down, and for the old
# release's connection pool to drain once it is gone.
bootout_timeout=60
drain_timeout=30

log() {
  echo "deploy: cutover: $*"
}

refuse() {
  echo "deploy: cutover: $*" >&2
  exit 1
}

# The names are spliced into SQL identifiers and regular expressions, so they
# must be plain identifiers; anything else is a configuration mistake.
for name in "$old_database" "$new_database" "$old_role" "$new_role" \
  "$old_release_node" "$new_release_node" "$old_env_prefix" "$new_env_prefix"; do
  [[ $name =~ ^[A-Za-z0-9_-]+$ ]] || refuse "'$name' is not a plain identifier"
done

# The whole state root moves, so the deployment must sit inside it under the
# same relative name on both sides.
[[ $old_deployment == "$old_state_root/"?* ]] ||
  refuse "OLD_DEPLOYMENT $old_deployment is not inside OLD_STATE_ROOT $old_state_root"
[[ $new_deployment == "$new_state_root/"?* ]] ||
  refuse "NEW_DEPLOYMENT $new_deployment is not inside NEW_STATE_ROOT $new_state_root"
[[ ${old_deployment#"$old_state_root/"} == "${new_deployment#"$new_state_root/"}" ]] ||
  refuse "the deployment must keep its name inside the moved root:" \
    "${old_deployment#"$old_state_root/"} became ${new_deployment#"$new_state_root/"}"

domain="gui/$(id -u)"
marker="$new_deployment/backups/rename-cutover.done"

scratch=$(mktemp -d "${TMPDIR:-/tmp}/ryker-cutover.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

is_loaded() {
  launchctl print "$domain/$1" >/dev/null 2>&1
}

bootout_labels() {
  # bootout_labels LABEL...: boot every label out of the gui domain and wait
  # for launchd to finish tearing them down. bootout returns before the job
  # has left the domain, so the wait is what proves the old release is gone.
  local label remaining
  for label in "$@"; do
    if is_loaded "$label"; then
      log "booting out $domain/$label"
    fi
    launchctl bootout "$domain/$label" 2>/dev/null || true
  done

  for _attempt in $(seq 1 "$bootout_timeout"); do
    remaining=
    for label in "$@"; do
      if is_loaded "$label"; then
        remaining="$remaining $label"
      fi
    done
    [[ -n $remaining ]] || return 0
    sleep 1
  done
  refuse "still loaded in $domain ${bootout_timeout}s after bootout:$remaining"
}

env_value() {
  # env_value FILE KEY: the value of KEY=value, without surrounding quotes.
  awk -v key="$2" '
    index($0, key "=") == 1 {
      value = substr($0, length(key) + 2)
      gsub(/^["'\'']|["'\'']$/, "", value)
      print value
      exit
    }' "$1"
}

url_decode() {
  # url_decode STRING: percent-escapes decoded; a literal backslash survives.
  local escaped=${1//\\/\\\\}
  printf '%b' "${escaped//%/\\x}"
}

read_database_url() {
  # read_database_url FILE: sets db_host, db_port and db_password from the
  # deployment's DATABASE_URL. The password is never echoed or put on a
  # command line; it only ever travels through PGPASSWORD and psql's stdin.
  local url pattern
  url=$(env_value "$1" DATABASE_URL)
  [[ -n $url ]] || refuse "$1 does not define DATABASE_URL"
  pattern='^ecto://([^:/@]+):([^@]*)@([^:/@]+)(:([0-9]+))?/([^?]+)(\?.*)?$'
  [[ $url =~ $pattern ]] ||
    refuse "DATABASE_URL in $1 is not ecto://ROLE:PASSWORD@HOST[:PORT]/DATABASE"
  db_host=${BASH_REMATCH[3]}
  db_port=${BASH_REMATCH[5]:-5432}
  db_password=$(url_decode "${BASH_REMATCH[2]}")
}

pg_super() {
  # pg_super PSQL-ARGS...: one superuser connection to the maintenance database.
  PGPASSWORD=$pg_superpassword psql -X -A -t -q -w -v ON_ERROR_STOP=1 \
    -h "$db_host" -p "$db_port" -U "$pg_superuser" -d postgres "$@"
}

pg_count() {
  # pg_count SQL: one non-negative integer from the superuser connection.
  local value
  value=$(pg_super -c "$1")
  [[ $value =~ ^[0-9]+$ ]] || refuse "unexpected answer to '$1': $value"
  printf '%s\n' "$value"
}

pg_verify_application() {
  # The application's own credentials against the renamed role and database.
  PGPASSWORD=$db_password psql -X -A -t -q -w -v ON_ERROR_STOP=1 \
    -h "$db_host" -p "$db_port" -U "$new_role" -d "$new_database" \
    -c 'select 1' >/dev/null
}

pg_reset_application_password() {
  # An MD5 password is salted with the role name, so renaming the role
  # silently invalidates it; SCRAM survives. Either way the fix is the same
  # password again, fed through stdin so it never appears in an argument list.
  local literal=${db_password//\'/\'\'}
  printf '%s\n' "ALTER ROLE \"$new_role\" PASSWORD '$literal';" | pg_super >/dev/null ||
    refuse "could not set the password of $new_role"
}

drain_old_database() {
  # ALTER DATABASE ... RENAME fails while anyone else is connected. The old
  # release is gone by now, but its pool and any watchers get a moment to
  # notice before this refuses.
  local connections
  for _attempt in $(seq 1 "$drain_timeout"); do
    connections=$(pg_count "select count(*) from pg_stat_activity where datname = '$old_database' and pid <> pg_backend_pid()")
    [[ $connections != 0 ]] || return 0
    sleep 1
  done
  refuse "$connections connection(s) to $old_database remain after ${drain_timeout}s; nothing was renamed"
}

replace_literal() {
  # replace_literal FILE OLD NEW: every occurrence of OLD, as plain text, in
  # place, keeping the file's mode. awk's index() never reads OLD as a pattern.
  local file=$1 tmp
  tmp=$(mktemp "$file.XXXXXX")
  cp -p "$file" "$tmp"
  OLD=$2 NEW=$3 awk '
    BEGIN { old = ENVIRON["OLD"]; new = ENVIRON["NEW"] }
    {
      line = $0
      out = ""
      while (old != "" && (i = index(line, old)) > 0) {
        out = out substr(line, 1, i - 1) new
        line = substr(line, i + length(old))
      }
      print out line
    }' "$file" >"$tmp"
  mv "$tmp" "$file"
}

rewrite_paths() {
  # rewrite_paths FILE: the old state root becomes the new one and nothing
  # else changes. Keys such as responder_url and the responder-* policy names
  # are contracts with co:op and the checkout, and they stay.
  local file=$1
  if [[ ! -f $file ]]; then
    log "$file is not present; nothing to rewrite"
  elif grep -qF -- "$old_state_root" "$file"; then
    replace_literal "$file" "$old_state_root" "$new_state_root"
    log "rewrote $old_state_root as $new_state_root in $file"
  else
    log "$file already points at $new_state_root"
  fi
}

rewrite_runtime_env() {
  # rewrite_runtime_env FILE: RESPONDER_* keys become RYKER_* (also the one
  # commented-out key), DATABASE_URL names the new role and database with the
  # password untouched, RELEASE_NODE takes the new node name, and every old
  # state-root path moves. Line by line, so nothing else is reinterpreted.
  local file=$1 tmp line key_re url_re node_re
  key_re="^(#[[:space:]]*)?$old_env_prefix([A-Za-z0-9_]*=.*)$"
  url_re="^DATABASE_URL=([\"']?ecto://)$old_role(:[^@]*@[^/]*/)$old_database([?\"'].*)?$"
  node_re="^(RELEASE_NODE=[\"']?)$old_release_node([\"']?)$"
  tmp=$(mktemp "$file.XXXXXX")
  cp -p "$file" "$tmp"
  : >"$tmp"
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ $key_re ]]; then
      line="${BASH_REMATCH[1]:-}$new_env_prefix${BASH_REMATCH[2]}"
    fi
    if [[ $line =~ $url_re ]]; then
      line="DATABASE_URL=${BASH_REMATCH[1]}$new_role${BASH_REMATCH[2]}$new_database${BASH_REMATCH[3]:-}"
    fi
    if [[ $line =~ $node_re ]]; then
      line="${BASH_REMATCH[1]}$new_release_node${BASH_REMATCH[2]:-}"
    fi
    printf '%s\n' "$line" >>"$tmp"
  done <"$file"
  mv "$tmp" "$file"
  replace_literal "$file" "$old_state_root" "$new_state_root"
  log "rewrote $file for $new_env_prefix keys, $new_role@$new_database, $new_release_node and $new_state_root"
}

capture_serve_job() {
  # capture_serve_job BACKUPS: the serve sidecar was `launchctl submit`ted
  # without a plist, so its argument list exists only inside launchd. Save it
  # before the bootout, one argument per line, so a rerun after a partial
  # failure can still re-submit it.
  local backups=$1 printed="$scratch/$old_coop_label.print"
  is_loaded "$old_coop_label" || return 0
  launchctl print "$domain/$old_coop_label" >"$printed"
  awk '
    /^[[:space:]]*arguments = \{/ { inside = 1; next }
    inside && /^[[:space:]]*\}/ { inside = 0; next }
    inside { sub(/^[[:space:]]+/, ""); print }
  ' "$printed" >"$backups/$old_coop_label.argv"
  awk '
    /^[[:space:]]*stdout path = / { sub(/^[[:space:]]*stdout path = /, ""); print }
    /^[[:space:]]*stderr path = / { sub(/^[[:space:]]*stderr path = /, ""); print }
  ' "$printed" >"$backups/$old_coop_label.stdio"
  [[ -s $backups/$old_coop_label.argv ]] ||
    refuse "$old_coop_label is loaded but its arguments could not be read from launchctl print"
  log "saved the $old_coop_label job's arguments to $backups/$old_coop_label.argv"
}

resubmit_serve_job() {
  # resubmit_serve_job BACKUPS: the serve sidecar again, under the new label,
  # with every old state-root path moved. The co:op binary lives under
  # ~/.local/lib/responder-coop and is installed outside this repository, so
  # its path stays.
  local backups=$1 line stdout_path stderr_path
  local -a args=() stdio=()
  if is_loaded "$new_coop_label"; then
    log "$new_coop_label is already loaded"
    return 0
  fi
  if [[ ! -s $backups/$old_coop_label.argv ]]; then
    log "the $old_coop_label serve sidecar was not running; nothing to re-submit"
    return 0
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    args+=("${line//"$old_state_root"/$new_state_root}")
  done <"$backups/$old_coop_label.argv"
  stdout_path=$(sed -n 1p "$backups/$old_coop_label.stdio" 2>/dev/null || true)
  stderr_path=$(sed -n 2p "$backups/$old_coop_label.stdio" 2>/dev/null || true)
  if [[ -n $stdout_path ]]; then
    stdio+=(-o "${stdout_path//"$old_state_root"/$new_state_root}")
  fi
  if [[ -n $stderr_path ]]; then
    stdio+=(-e "${stderr_path//"$old_state_root"/$new_state_root}")
  fi
  log "submitting $new_coop_label with ${#args[@]} argument(s)"
  # ${stdio[@]+...}: bash 3.2 treats an empty array as unbound under set -u.
  launchctl submit -l "$new_coop_label" ${stdio[@]+"${stdio[@]}"} -- "${args[@]}" ||
    refuse "launchctl submit of $new_coop_label failed"
  log "submitted $domain/$new_coop_label"
}

move_worker_job() {
  # The worker sidecar has a plist: render the new one from it with the label
  # and the state-root paths replaced, lint it, install it, and load it.
  local old_plist="$launch_agents/$old_worker_label.plist"
  local new_plist="$launch_agents/$new_worker_label.plist"
  local rendered="$scratch/$new_worker_label.plist"
  if [[ ! -f $new_plist ]]; then
    if [[ ! -f $old_plist ]]; then
      log "no $old_worker_label job is installed; nothing to move"
      return 0
    fi
    cp "$old_plist" "$rendered"
    replace_literal "$rendered" "$old_worker_label" "$new_worker_label"
    replace_literal "$rendered" "$old_state_root" "$new_state_root"
    plutil -lint "$rendered" >/dev/null ||
      refuse "the $new_worker_label plist rendered from $old_plist does not lint"
    mkdir -p "$launch_agents"
    install -m 0644 "$rendered" "$new_plist"
    log "rendered $new_plist from $old_plist"
  else
    log "$new_plist is already in place"
  fi
  if is_loaded "$new_worker_label"; then
    log "$new_worker_label is already loaded"
  else
    launchctl bootstrap "$domain" "$new_plist" ||
      refuse "launchctl bootstrap of $new_plist failed"
    log "bootstrapped $domain/$new_worker_label"
  fi
}

prepare() {
  local resume backups env_file stamp have_old have_new dump

  # The decision. Both layouts present is the one state that cannot be
  # resolved without a guess, so it is never merged or deleted here.
  if [[ -e $old_deployment && -e $new_deployment ]]; then
    refuse "both $old_deployment and $new_deployment exist; finish or remove one by hand"
  elif [[ ! -e $old_deployment && ! -e $new_deployment/runtime.env ]]; then
    log "nothing to cut over"
    return 0
  elif [[ ! -e $old_deployment && -e $marker ]]; then
    log "already complete"
    return 0
  elif [[ ! -e $old_deployment ]]; then
    log "resuming: $old_deployment already moved to $new_deployment"
    resume=1
    backups="$new_deployment/backups"
    env_file="$new_deployment/runtime.env"
  else
    [[ -r $old_deployment/runtime.env ]] ||
      refuse "$old_deployment/runtime.env is missing or unreadable"
    [[ ! -e $new_state_root ]] ||
      refuse "both $old_state_root and $new_state_root exist; the cutover moves the whole root, so move $new_state_root aside by hand and rerun"
    log "cutting $old_deployment over to $new_deployment"
    resume=0
    backups="$old_deployment/backups"
    env_file="$old_deployment/runtime.env"
  fi
  [[ -r $env_file ]] || refuse "$env_file is missing or unreadable"

  mkdir -p "$backups"
  chmod 0700 "$backups"
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  if [[ $resume == 0 ]]; then
    cp -p "$env_file" "$backups/pre-rename-$stamp.runtime.env"
    chmod 0600 "$backups/pre-rename-$stamp.runtime.env"
  fi

  # (a) Stop the old release and both sidecars. The serve job's arguments are
  # captured first because bootout is the last time launchd will know them.
  capture_serve_job "$backups"
  bootout_labels "$old_label" "$old_worker_label" "$old_coop_label"

  # (b) With nothing connected, dump the database and rename it and its role.
  read_database_url "$env_file"
  drain_old_database
  have_old=$(pg_count "select count(*) from pg_database where datname = '$old_database'")
  have_new=$(pg_count "select count(*) from pg_database where datname = '$new_database'")
  if [[ $have_old == 1 && $have_new == 0 ]]; then
    dump="$backups/pre-rename-$stamp.dump"
    PGPASSWORD=$pg_superpassword pg_dump --format=custom --no-owner --no-privileges \
      -h "$db_host" -p "$db_port" -U "$pg_superuser" --file="$dump" "$old_database" ||
      refuse "pg_dump of $old_database failed; nothing was renamed"
    chmod 0600 "$dump"
    log "backup of $old_database written to $dump"
    pg_super -c "ALTER DATABASE \"$old_database\" RENAME TO \"$new_database\"" >/dev/null ||
      refuse "could not rename database $old_database to $new_database"
    log "renamed database $old_database to $new_database"
  elif [[ $have_old == 0 && $have_new == 1 ]]; then
    log "database $new_database is already in place; skipping the dump and rename"
  else
    refuse "expected exactly one of the databases $old_database and $new_database to exist (found $have_old and $have_new)"
  fi

  have_old=$(pg_count "select count(*) from pg_roles where rolname = '$old_role'")
  have_new=$(pg_count "select count(*) from pg_roles where rolname = '$new_role'")
  if [[ $have_old == 1 && $have_new == 0 ]]; then
    pg_super -c "ALTER ROLE \"$old_role\" RENAME TO \"$new_role\"" >/dev/null ||
      refuse "could not rename role $old_role to $new_role"
    log "renamed role $old_role to $new_role"
  elif [[ $have_old == 0 && $have_new == 1 ]]; then
    log "role $new_role is already in place; skipping the rename"
  else
    refuse "expected exactly one of the roles $old_role and $new_role to exist (found $have_old and $have_new)"
  fi

  if pg_verify_application; then
    log "application credentials verified against $new_role@$new_database"
  else
    log "application credentials failed against $new_role@$new_database; setting the role's password again"
    pg_reset_application_password
    pg_verify_application ||
      refuse "application credentials still fail against $new_role@$new_database after resetting the password"
    log "application credentials verified against $new_role@$new_database after the reset"
  fi

  # (c) Move the whole state root; every deployment under it moves together.
  if [[ -e $old_state_root ]]; then
    [[ ! -e $new_state_root ]] ||
      refuse "both $old_state_root and $new_state_root exist; move $new_state_root aside by hand and rerun"
    mv "$old_state_root" "$new_state_root" ||
      refuse "could not move $old_state_root to $new_state_root"
    log "moved $old_state_root to $new_state_root"
  else
    log "$old_state_root already moved to $new_state_root"
  fi
  [[ -r $new_deployment/runtime.env ]] ||
    refuse "$new_deployment/runtime.env is missing after the move"
  backups="$new_deployment/backups"

  # (d) Rewrite the deployment for its new names, then bring the sidecars
  # back against the moved paths: serve first, since the worker connects to
  # its socket.
  rewrite_runtime_env "$new_deployment/runtime.env"
  rewrite_paths "$new_deployment/coop-worker/worker.json"
  rewrite_paths "$new_deployment/session-policies.yaml"
  rewrite_paths "$new_deployment/policy-digests.json"
  resubmit_serve_job "$backups"
  move_worker_job

  date -u +%Y-%m-%dT%H:%M:%SZ >"$marker"
  log "prepared; $new_deployment is ready for $new_label"
}

finish() {
  local file name label
  local -a files=()
  [[ -e $new_deployment/runtime.env ]] ||
    refuse "$new_deployment/runtime.env does not exist; nothing to finish"
  is_loaded "$new_label" ||
    refuse "$domain/$new_label is not loaded; the old jobs stay until the new release serves"

  shopt -s nullglob
  files=("$launch_agents/$old_label"*.plist "$launch_agents/$old_label"*.plist.staged-*)
  shopt -u nullglob
  if [[ ${#files[@]} -eq 0 ]]; then
    log "no $old_label plists left in $launch_agents"
    return 0
  fi

  for file in "${files[@]}"; do
    name=${file##*/}
    label=${name%%.plist*}
    if is_loaded "$label"; then
      bootout_labels "$label"
    fi
    rm -f -- "$file"
    log "removed $file"
  done
  log "finished; $old_label is retired"
}

"$subcommand"
