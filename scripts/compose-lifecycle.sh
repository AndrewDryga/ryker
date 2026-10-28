# shellcheck shell=sh
# shellcheck disable=SC2154 # state_dir and env_file belong to the script that sources this
# What scripts/deploy.sh, scripts/compose.sh and scripts/watchdog.sh share about
# the Compose project: how compose.env is read, one lifecycle command at a
# time, how a release is pinned, and where and how the console is asked
# whether it is ready.

# Two deploys, or a backup beside a restore, each stopped and started the one
# ryker project under the other: a backup lost its quiet database and a probe
# passed the wrong release (2026-10-04 review).
#
# The lock is a directory, because mkdir is atomic and macOS has no flock. Its
# owner file names the process and the command; a lock whose process is gone
# is taken over.

# The bundled worker's image is named for the Coop its Dockerfile pins and for what else is built
# into it: that Dockerfile, the worker's entrypoint and the box Dockerfile. Named for the Coop
# alone, a change to one of the others reached no install that had built that Coop's image
# already: worker-upgrade found the name and built nothing (2026-10-17). Callers take it from a
# command substitution, so its variables stay its own.
worker_image() {
  worker_recipe="$1/deploy/compose/coop"
  worker_revision=$(sed -n 's/^ARG COOP_REVISION=//p' "$worker_recipe/Dockerfile" 2>/dev/null)
  case $worker_revision in
    *[!0-9a-f]* | "") return 1 ;;
  esac
  worker_inputs=$(cat "$worker_recipe/Dockerfile" "$worker_recipe/entrypoint.sh" \
    "$worker_recipe/Box.Dockerfile" 2>/dev/null | sha256_hex)
  printf 'ryker-coop:%s-%s\n' "$(printf '%s' "$worker_revision" | cut -c1-8)" \
    "$(printf '%s' "$worker_inputs" | cut -c1-8)"
}

sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1
}

take_lifecycle_lock() {
  lifecycle_lock=$state_dir/lifecycle.lock
  mkdir -p "$state_dir"

  if ! mkdir "$lifecycle_lock" 2>/dev/null; then
    holder=$(cat "$lifecycle_lock/owner" 2>/dev/null || true)
    holder_pid=${holder%% *}

    if [ -n "$holder_pid" ] && kill -0 "$holder_pid" 2>/dev/null; then
      echo "Another Ryker lifecycle command is running (process $holder). Wait for it to finish; if nothing is running, remove $lifecycle_lock." >&2
      exit 75
    fi

    rm -rf -- "$lifecycle_lock"
    mkdir "$lifecycle_lock" 2>/dev/null || {
      echo "Could not take the lifecycle lock at $lifecycle_lock." >&2
      exit 1
    }
  fi

  echo "$$ $1" >"$lifecycle_lock/owner"
  lifecycle_locked=1
}

release_lifecycle_lock() {
  if [ "${lifecycle_locked:-0}" = 1 ]; then
    rm -rf -- "$lifecycle_lock"
    lifecycle_locked=0
  fi
}

# Pins RYKER_VERSION and RYKER_IMAGE in the environment file and keeps every
# other line. The new file is written beside it and moved over it, so nothing
# ever reads half a file.
pin_release() {
  pinned=$(mktemp "$state_dir/.compose.env.XXXXXX")
  awk -v version="$1" -v image="$2" '
    /^RYKER_VERSION=/ { print "RYKER_VERSION=" version; seen_version = 1; next }
    /^RYKER_IMAGE=/ { print "RYKER_IMAGE=" image; seen_image = 1; next }
    { print }
    END {
      if (!seen_version) print "RYKER_VERSION=" version
      if (!seen_image) print "RYKER_IMAGE=" image
    }' "$env_file" >"$pinned"
  chmod 0600 "$pinned"
  mv -f "$pinned" "$env_file"
}

# compose_env_value KEY FILE prints KEY's last assignment in FILE as Compose
# reads it: without an `export` in front or the quotes around it. The three
# scripts each read the file their own way, and a quoted RYKER_CONTROL_PORT,
# which Compose accepts, sent deploy.sh to a port that does not exist
# (2026-10-04 review). The file is never sourced: it holds the database
# password and every root key.
compose_env_value() {
  sed -n "s/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}$1=//p" "$2" 2>/dev/null | tail -n 1 |
    sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

# A launch agent does not inherit the installing shell's Docker context. Pin
# that context so a later desktop switch cannot move backups to another daemon.
launch_agent_docker_environment() {
  if [ -n "${DOCKER_HOST:-}" ] && [ -z "${DOCKER_CONTEXT:-}" ]; then
    echo "Select DOCKER_CONTEXT before installing a Docker launch agent; DOCKER_HOST alone is not a named installation." >&2
    return 1
  fi
  agent_context=$(docker context show) || return 1
  [ -n "$agent_context" ] || return 1
  agent_context=$(printf '%s' "$agent_context" | sed 's/\&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  printf '<key>EnvironmentVariables</key><dict><key>DOCKER_CONTEXT</key><string>%s</string></dict>\n' "$agent_context"
}

# The models Compose runs beside Ryker (compose.yml): voice, search by meaning
# and, while COMPOSE_PROFILES in compose.env turns its profile on, the local
# routing model. Ryker works without them, with less, so one that does not
# build or start is said and stops nothing, and the watchdog keeps saying it.
#
# model_services COMPOSE... prints the models the installation turns on, one
# per line.
model_services() {
  "$@" config --services | grep -Fx -e whisper -e whisper-detect -e embeddings -e routing-model || true
}

# Where the host reaches the console: the address it is published on
# (RYKER_CONTROL_BIND, which Ryker requires to be 127.0.0.1 or ::1) and its
# port. The probes asked 127.0.0.1 whatever the bind, or wrote ::1 into a URL
# without its brackets (2026-10-04 review).
control_origin() {
  case $1 in
    "") printf 'http://127.0.0.1:%s\n' "$2" ;;
    *:*) printf 'http://[%s]:%s\n' "$1" "$2" ;;
    *) printf 'http://%s:%s\n' "$1" "$2" ;;
  esac
}

# probe_console ORIGIN asks the console whether it is healthy and ready and
# which release answers, and sets healthz_code, readyz_code, readyz_body (the
# first line of /readyz) and running_version. Each request gets three seconds,
# and one that is not answered reads as 000.
# shellcheck disable=SC2034 # the script that sources this reads what it sets
probe_console() {
  probe_headers=$(mktemp)
  probe_body=$(mktemp)
  healthz_code=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 3 \
    "$1/healthz" 2>/dev/null) || true
  readyz_code=$(curl --silent --dump-header "$probe_headers" --output "$probe_body" \
    --write-out '%{http_code}' --max-time 3 "$1/readyz" 2>/dev/null) || true
  readyz_body=$(head -n 1 "$probe_body" 2>/dev/null) || true
  running_version=$(awk 'tolower($1) == "x-ryker-version:" { sub(/\r$/, "", $2); print $2; exit }' \
    "$probe_headers" 2>/dev/null) || true
  rm -f "$probe_headers" "$probe_body"
}

# write_backup ARCHIVE DIRECTORY FILE... packs the FILEs in DIRECTORY into
# ARCHIVE, owner-only, under a hidden name until it is whole: a backup written
# under its final name and cut short looked like a good one (2026-10-04 review).
write_backup() {
  backup_archive=$1
  backup_partial=$(dirname "$backup_archive")/.partial-$(basename "$backup_archive")
  shift
  if (umask 077 && tar -czf "$backup_partial" -C "$@"); then
    mv -f "$backup_partial" "$backup_archive"
  else
    rm -f "$backup_partial"
    return 1
  fi
}
