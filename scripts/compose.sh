#!/bin/sh
set -eu

repository=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
state_dir=${RYKER_INSTALL_STATE:-$repository/.ryker}
env_file=$state_dir/compose.env

usage() {
  echo "usage: scripts/compose.sh status|logs|stop|start|restart|upgrade|model-login [PROVIDER]|backup|restore FILE|uninstall|destroy" >&2
  exit 2
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

value() {
  sed -n "s/^$1=//p" "$2" | tail -n 1
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
        echo "Ryker is ready: $origin/settings"
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

cd "$repository"
command=${1:-}

case "$command" in
  restore)
    [ "$#" -eq 2 ] || usage
    backup=$2
    [ -r "$backup" ] || { echo "Cannot read backup: $backup" >&2; exit 1; }
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/ryker-restore.XXXXXX")
    trap 'rm -rf -- "$scratch"' EXIT HUP INT TERM
    tar -xzf "$backup" -C "$scratch"
    [ -r "$scratch/database.dump" ] && [ -r "$scratch/compose.env" ] || {
      echo "The backup does not contain Ryker database and key custody." >&2
      exit 1
    }

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
    if [ -r "$scratch/worker-state.tar.gz" ]; then
      compose up --detach --wait volume-init
      compose run --rm --no-deps -T --entrypoint tar ryker-coop \
        -xzf - -C /var/lib <"$scratch/worker-state.tar.gz"
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
    compose build --pull ryker ryker-coop
    compose up --detach --wait
    wait_ready
    ;;
  model-login)
    require_install
    provider=${2:-codex}
    [ "$#" -le 2 ] || usage
    compose run --rm --no-deps --entrypoint coop ryker-coop login "$provider"
    compose restart ryker-coop
    ;;
  backup)
    require_install
    backup_dir=$state_dir/backups
    mkdir -p "$backup_dir"
    chmod 0700 "$backup_dir"
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/ryker-backup.XXXXXX")
    trap 'rm -rf -- "$scratch"' EXIT HUP INT TERM
    compose exec -T database pg_dump -U ryker -d ryker --format=custom --no-owner --no-privileges >"$scratch/database.dump"
    compose run --rm --no-deps -T --entrypoint tar ryker-coop \
      -czf - -C /var/lib coop ryker-coop ryker-workspaces >"$scratch/worker-state.tar.gz"
    cp "$env_file" "$scratch/compose.env"
    chmod 0600 "$scratch/database.dump" "$scratch/worker-state.tar.gz" "$scratch/compose.env"
    backup=$backup_dir/ryker-$(date -u +%Y%m%dT%H%M%SZ).tar.gz
    tar -czf "$backup" -C "$scratch" database.dump worker-state.tar.gz compose.env
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
