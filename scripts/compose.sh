#!/bin/sh
# The one lifecycle helper for the Docker Compose deployment. Every command
# runs against the same project (compose.yml) and the same owner-only
# environment file, so install, upgrade, backup and restore cannot drift
# apart in how they name the project or find its roots.
set -eu

repository=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
state_dir=${RYKER_INSTALL_STATE:-$repository/.ryker}
env_file=$state_dir/compose.env

usage() {
  echo "usage: scripts/compose.sh install|status|logs|stop|start|restart|upgrade|model-login [PROVIDER]|worker-token WORKER_ID WORKSPACE_REF OPERATOR_REF|doctor|backup|restore FILE|uninstall|destroy" >&2
  exit 2
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Ryker needs $1. Install it, then run ./install.sh again." >&2
    exit 1
  }
}

require_install() {
  [ -r "$env_file" ] || {
    echo "Ryker is not installed here. Run ./install.sh first, or restore a Ryker backup." >&2
    exit 1
  }
}

compose() {
  docker compose --env-file "$env_file" "$@"
}

# Signs a model account in on the worker volume. Coop refuses a sign-in whose
# project directory holds its own network records, and the container's working
# directory "/" holds everything, so it runs from /tmp. It also refuses to record
# a process whose id is 1, and `run --entrypoint coop` makes coop process 1, so a
# shell stays process 1 and runs it as a child (the `exit` keeps sh from
# replacing itself with coop).
model_login() {
  # shellcheck disable=SC2016 # $0 is expanded by the container's shell
  compose run --rm --no-deps -w /tmp --entrypoint /bin/sh ryker-coop \
    -c 'coop login "$0"; exit $?' "$1"
}

value() {
  sed -n "s/^$1=//p" "$2" | tail -n 1
}

# A worker image named in the environment file is a supplied build, made for
# example from a Coop checkout ahead of the Dockerfile's pin. Building the
# worker would tag the pin's image with that name, and a newer Coop may have
# moved the worker's state to a schema the pinned one refuses.
supplied_worker_image() {
  [ -n "$(value RYKER_COOP_IMAGE "$env_file")" ]
}

wait_ready() {
  control_port=$(value RYKER_CONTROL_PORT "$env_file")
  control_port=${control_port:-4321}
  origin="http://127.0.0.1:$control_port"
  expected=$(value RYKER_VERSION "$env_file")
  attempt=0

  while [ "$attempt" -lt 60 ]; do
    if curl --fail --silent --output /dev/null "$origin/healthz" 2>/dev/null &&
       curl --fail --silent --output /dev/null "$origin/readyz" 2>/dev/null &&
       headers=$(curl --fail --silent --dump-header - --output /dev/null "$origin/readyz" 2>/dev/null); then
      running=$(printf '%s\n' "$headers" | awk 'BEGIN{IGNORECASE=1} /^x-ryker-version:/ {gsub("\r", "", $2); print $2; exit}')
      if [ "$running" = "$expected" ]; then
        echo "Ryker is ready: $origin/setup"
        return 0
      fi
    fi
    attempt=$((attempt + 1))
    sleep 1
  done

  echo "Ryker did not become ready as version $expected." >&2
  return 1
}

same_root() {
  name=$1
  [ "$(value "$name" "$env_file")" = "$(value "$name" "$2")" ]
}

random_urlsafe() {
  openssl rand -base64 "$1" | tr '+/' '-_' | tr -d '=\n'
}

random_base64() {
  openssl rand -base64 "$1" | tr -d '\n'
}

# The environment file is generated once: the database password and the
# cryptographic roots in it are what a backup needs to be readable, so a
# later install reuses the file rather than replacing it.
generate_env() {
  version=${RYKER_VERSION:-}
  if [ -z "$version" ] && command -v git >/dev/null 2>&1; then
    revision=$(git -C "$repository" rev-parse --short=12 HEAD 2>/dev/null || true)
    if [ -n "$revision" ]; then
      dirty=
      git -C "$repository" diff-index --quiet HEAD -- 2>/dev/null || dirty=.dirty
      version="0.1.0-source.g$revision$dirty"
    fi
  fi
  version=${version:-0.1.0}
  version=${version#v}

  (
    umask 077
    db_password=$(random_urlsafe 32)
    checkpoint_key=$(random_base64 32)
    credential_key=$(random_base64 32)
    state_tools_token=$(random_urlsafe 32)
    {
      echo "# RYKER_GENERATED_ENV - generated once by install.sh; keep this file with backups."
      echo "RYKER_VERSION=$version"
      echo "RYKER_IMAGE=${RYKER_IMAGE:-ryker:$version}"
      echo "RYKER_DATABASE_PASSWORD=$db_password"
      echo "RYKER_CHECKPOINT_KEY=$checkpoint_key"
      echo "RYKER_CREDENTIAL_KEY=$credential_key"
      echo "RYKER_STATE_TOOLS_TOKEN=$state_tools_token"
      echo "RYKER_CONTROL_BIND=${RYKER_CONTROL_BIND:-127.0.0.1}"
      echo "RYKER_CONTROL_PORT=${RYKER_CONTROL_PORT:-4321}"
      echo "RYKER_GITHUB_BIND=${RYKER_GITHUB_BIND:-127.0.0.1}"
      echo "RYKER_GITHUB_PORT=${RYKER_GITHUB_PORT:-4319}"
      echo "RYKER_WEBHOOK_BIND=${RYKER_WEBHOOK_BIND:-127.0.0.1}"
      echo "RYKER_WEBHOOK_PORT=${RYKER_WEBHOOK_PORT:-4320}"
    } >"$env_file"
  )
  chmod 0600 "$env_file"
}

install_ryker() {
  need docker
  need openssl
  need curl
  docker compose version >/dev/null 2>&1 || {
    echo "Ryker needs Docker Compose v2 (the 'docker compose' command)." >&2
    exit 1
  }

  mkdir -p "$state_dir"
  chmod 0700 "$state_dir"
  [ -f "$env_file" ] || generate_env

  compose up --detach --build --wait database ryker ryker-coop-docker
  compose exec -T ryker \
    /opt/ryker/bin/ryker eval 'Ryker.Release.prepare_bundled_coop(log: false)'
  # Those settings were saved by a one-off process, and the running Ryker applies
  # settings saved elsewhere only when it starts: without this its worker gateway
  # never opened and the worker could not connect.
  compose restart ryker
  compose up --detach --wait ryker
  # Coop refuses to build from a directory that holds its own network records, as
  # the container's "/" does, and a fresh volume has no temporary directory until
  # the worker's entrypoint makes one.
  # shellcheck disable=SC2016 # $TMPDIR is expanded by the container's shell
  compose run --rm --no-deps -w /tmp --entrypoint /bin/sh ryker-coop \
    -c 'umask 077; mkdir -p "$TMPDIR"; coop build; exit $?'

  if ! compose run --rm --no-deps -T \
    --entrypoint sh ryker-coop -c \
    'find /var/lib/coop/agents/codex/profiles -type f -name auth.json -size +0c 2>/dev/null | grep -q .'; then
    codex_auth_root=${CODEX_HOME:-$HOME/.codex}
    codex_auth=$codex_auth_root/auth.json

    if [ -s "$codex_auth" ]; then
      compose run --rm --no-deps -T \
        --entrypoint sh ryker-coop -c \
        'umask 077; mkdir -p /var/lib/coop/agents/codex/profiles/default; cat > /var/lib/coop/agents/codex/profiles/default/auth.json' \
        <"$codex_auth"
      echo "Imported the existing Codex sign-in into Ryker's private worker volume."
    else
      echo "Connect the model account Ryker will use for work. This is stored only in the private worker volume."
      model_login codex
    fi
  fi

  if supplied_worker_image; then
    compose up --detach --wait ryker-coop
  else
    compose up --detach --build --wait ryker-coop
  fi

  worker_attempt=0
  while [ "$worker_attempt" -lt 120 ]; do
    if compose exec -T ryker \
      /opt/ryker/bin/ryker eval \
      'if Ryker.Release.bundled_coop_ready?(log: false), do: :ok, else: System.halt(1)' \
      >/dev/null 2>&1; then
      break
    fi
    worker_attempt=$((worker_attempt + 1))
    sleep 1
  done

  [ "$worker_attempt" -lt 120 ] || {
    echo "Ryker started, but its bundled work runtime did not become ready. Run: ./scripts/compose.sh logs ryker-coop" >&2
    exit 1
  }

  wait_ready || {
    echo "Ryker started, but the exact version did not become ready. Run: ./scripts/compose.sh status" >&2
    exit 1
  }
}

cd "$repository"
command=${1:-}

case "$command" in
  install)
    [ "$#" -eq 1 ] || usage
    install_ryker
    ;;
  restore)
    [ "$#" -eq 2 ] || usage
    backup=$2
    [ -r "$backup" ] || { echo "Cannot read backup: $backup" >&2; exit 1; }
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/ryker-restore.XXXXXX")
    trap 'rm -rf -- "$scratch"' EXIT HUP INT TERM
    tar -xzf "$backup" -C "$scratch"
    if [ ! -r "$scratch/database.dump" ] || [ ! -r "$scratch/compose.env" ]; then
      echo "The backup does not contain Ryker database and key custody." >&2
      exit 1
    fi

    if [ -r "$env_file" ]; then
      for root in RYKER_CHECKPOINT_KEY RYKER_CREDENTIAL_KEY RYKER_STATE_TOOLS_TOKEN; do
        same_root "$root" "$scratch/compose.env" || {
          echo "The backup belongs to an installation with different cryptographic roots." >&2
          exit 1
        }
      done
    else
      mkdir -p "$state_dir"
      chmod 0700 "$state_dir"
      cp "$scratch/compose.env" "$env_file"
      chmod 0600 "$env_file"
    fi

    compose up --detach --wait database
    compose stop ryker ryker-coop ryker-coop-docker 2>/dev/null || true
    compose exec -T database dropdb -U ryker --if-exists ryker
    compose exec -T database createdb -U ryker ryker
    compose exec -T database pg_restore -U ryker -d ryker --exit-on-error --no-owner --no-privileges <"$scratch/database.dump"
    if [ -r "$scratch/ryker-state.tar.gz" ]; then
      compose run --rm --no-deps -T --entrypoint tar volume-init \
        -xzf - -C /var/lib/ryker <"$scratch/ryker-state.tar.gz"
    else
      file_checkpoints=$(compose exec -T database psql -XAt -U ryker -d ryker -v ON_ERROR_STOP=1 \
        -c "SELECT count(*) FROM coop_worker_workspace_checkpoints AS checkpoint WHERE to_jsonb(checkpoint)->>'body_command_id' IS NOT NULL")
      [ "$file_checkpoints" = 0 ] || {
        echo "This database needs encrypted checkpoint files, but the backup has no Ryker state archive. Ryker remains stopped." >&2
        exit 1
      }
    fi
    if [ -r "$scratch/worker-state.tar.gz" ]; then
      compose up --detach --wait volume-init
      compose run --rm --no-deps -T --entrypoint tar ryker-coop \
        -xzf - -C /var/lib coop ryker-coop <"$scratch/worker-state.tar.gz"
    fi
    compose up --detach --wait ryker
    compose exec -T ryker /opt/ryker/bin/ryker eval 'Ryker.Release.prepare_bundled_coop(log: false)'
    compose up --detach --wait ryker-coop
    wait_ready
    ;;
  status)
    require_install
    compose ps
    ;;
  logs)
    require_install
    shift
    compose logs --tail 200 --follow "$@"
    ;;
  stop)
    require_install
    compose stop
    ;;
  start)
    require_install
    compose up --detach --wait
    wait_ready
    ;;
  restart)
    require_install
    compose restart
    compose up --detach --wait
    wait_ready
    ;;
  upgrade)
    require_install
    compose pull --ignore-buildable
    if supplied_worker_image; then
      compose build --pull ryker
    else
      compose build --pull ryker ryker-coop
    fi
    compose up --detach --wait
    wait_ready
    ;;
  model-login)
    require_install
    provider=${2:-codex}
    [ "$#" -le 2 ] || usage
    model_login "$provider"
    compose restart ryker-coop
    ;;
  worker-token)
    # A one-time enrolment token for a worker this installation does not run
    # itself, printed once. Each value is a plain reference, never Elixir.
    require_install
    [ "$#" -eq 4 ] || usage
    for value in "$2" "$3" "$4"; do
      case $value in
        '' | *[!A-Za-z0-9._:-]*)
          echo "Worker, workspace and operator references use letters, digits, '.', '_', ':' and '-'." >&2
          exit 1
          ;;
      esac
    done
    compose exec -T ryker /opt/ryker/bin/ryker eval \
      "Ryker.Release.issue_worker_token(\"$2\", \"$3\", \"$4\")"
    ;;
  doctor)
    require_install
    [ "$#" -eq 1 ] || usage
    compose exec -T ryker /opt/ryker/bin/ryker eval 'Ryker.Release.doctor()'
    ;;
  backup)
    require_install
    backup_dir=$state_dir/backups
    mkdir -p "$backup_dir"
    chmod 0700 "$backup_dir"
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/ryker-backup.XXXXXX")
    restart_controller=0
    finish_backup() {
      backup_status=$?
      if [ "$restart_controller" = 1 ]; then
        compose start ryker >/dev/null || backup_status=1
      fi
      rm -rf -- "$scratch"
      exit "$backup_status"
    }
    trap finish_backup EXIT
    trap 'exit 1' HUP INT TERM
    running_services=$(compose ps --status running --services)
    if printf '%s\n' "$running_services" | grep -qx ryker; then
      echo "Pausing Ryker to capture the database and encrypted files consistently." >&2
      restart_controller=1
      compose stop ryker
    fi
    compose exec -T database pg_dump -U ryker -d ryker --format=custom --no-owner --no-privileges >"$scratch/database.dump"
    compose run --rm --no-deps -T --entrypoint tar volume-init \
      -czf - -C /var/lib/ryker . >"$scratch/ryker-state.tar.gz"
    # Ryker's own state is captured, so it runs again while the worker's is archived. The worker
    # keeps running throughout; holding Ryker for its archive kept tenant's console answering 502
    # for seven minutes (2026-10-04). Coop downloads its source caches (job-sources,
    # repositories) again when a job needs them, the lock and control socket belong to the
    # running daemon, and sessions.* are earlier copies of the worker's state: 12 of tenant's 13 GB.
    # A start that fails here is tried again on the way out, and fails the backup there.
    if [ "$restart_controller" = 1 ] && compose start ryker >/dev/null; then
      restart_controller=0
    fi
    compose run --rm --no-deps -T --entrypoint tar ryker-coop \
      -czf - -C /var/lib --exclude=coop/sessions/job-sources --exclude=coop/sessions/repositories \
      --exclude=coop/sessions/control.sock --exclude=coop/sessions/lock --exclude='coop/sessions.*' \
      coop ryker-coop >"$scratch/worker-state.tar.gz"
    cp "$env_file" "$scratch/compose.env"
    chmod 0600 "$scratch/database.dump" "$scratch/ryker-state.tar.gz" "$scratch/worker-state.tar.gz" "$scratch/compose.env"
    backup=$backup_dir/ryker-$(date -u +%Y%m%dT%H%M%SZ).tar.gz
    tar -czf "$backup" -C "$scratch" database.dump ryker-state.tar.gz worker-state.tar.gz compose.env
    chmod 0600 "$backup"
    echo "$backup"
    ;;
  uninstall)
    require_install
    compose down
    echo "Ryker stopped. Data and keys remain in Docker volumes and $env_file."
    ;;
  destroy)
    require_install
    [ "${RYKER_DESTROY_CONFIRM:-}" = "delete-ryker-data" ] || {
      echo "This deletes Ryker's database, stored work, and encryption keys." >&2
      echo "Run again with RYKER_DESTROY_CONFIRM=delete-ryker-data only if that is intended." >&2
      exit 1
    }
    compose down --volumes
    rm -f -- "$env_file"
    echo "Ryker containers, volumes, and generated keys were deleted. This cannot be recovered without a backup."
    ;;
  *)
    usage
    ;;
esac
