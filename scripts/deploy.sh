#!/usr/bin/env bash
# Build, prove, install, and restart the one-writer Ryker service.
#
# Durable admission, Work, delivery, schedule, and fleet custody resume from
# PostgreSQL after the restart; there is no canary/promote state. Before the
# running service is touched this proves that:
#
#   1. the tree is clean, so the release identity is an exact commit;
#   2. the exact archive is self-contained, boots, migrates, restarts, and
#      restores against a disposable PostgreSQL (make elixir-candidate-check);
#   3. when the archive carries migrations the live database has not applied,
#      a backup is taken and those migrations run against a restored copy —
#      a migration that fails on real rows fails here, with the old release
#      still serving. Deploys without new migrations skip this entirely.
#
# Then it installs the archive immutably, moves `current`, restarts the job
# under the host's service manager (systemd on Linux, launchd on macOS), and
# waits for /healthz, /readyz, and the exact running version header.
set -euo pipefail

if [[ $# -ne 0 ]]; then
  echo "usage: scripts/deploy.sh" >&2
  exit 2
fi

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repository"

health_url=${RYKER_HEALTH_URL:-http://127.0.0.1:4321}
keep_releases=${RYKER_KEEP_RELEASES:-5}

case $(uname -s) in
  Darwin)
    manager=launchd
    prefix=${RYKER_DEPLOY_PREFIX:-$HOME/.local/lib/ryker-elixir}
    state_root=${RYKER_STATE_ROOT:-$HOME/.local/state/ryker/emisar}
    runtime_env=${RYKER_RUNTIME_ENV:-$state_root/runtime.env}
    label=${RYKER_LAUNCHD_LABEL:-ai.emisar.ryker}
    erl_flags=${RYKER_ERL_FLAGS:-+S 4:4}
    launch_agents="$HOME/Library/LaunchAgents"
    plist="$launch_agents/$label.plist"
    service="$label"
    ;;
  *)
    manager=systemd
    prefix=${RYKER_DEPLOY_PREFIX:-/usr/local/lib/ryker}
    state_root=${RYKER_STATE_ROOT:-/var/lib/ryker}
    runtime_env=${RYKER_RUNTIME_ENV:-/etc/ryker/ryker.env}
    unit=${RYKER_SYSTEMD_UNIT:-ryker.service}
    service="$unit"
    ;;
esac

if [[ $health_url =~ :([0-9]+)/?$ ]]; then
  control_port=${BASH_REMATCH[1]}
else
  control_port=80
fi

if [[ -n $(git status --porcelain) ]]; then
  echo "deploy: refusing to deploy a dirty tree — commit first" >&2
  exit 1
fi

command -v curl >/dev/null 2>&1 || {
  echo "deploy: curl is required for post-restart health verification" >&2
  exit 1
}

case $manager in
  systemd)
    command -v systemctl >/dev/null 2>&1 || {
      echo "deploy: systemctl is required by the systemd deployment" >&2
      exit 1
    }
    ;;
  launchd)
    command -v launchctl >/dev/null 2>&1 || {
      echo "deploy: launchctl is required by the macOS deployment" >&2
      exit 1
    }
    [[ -r $runtime_env ]] || {
      echo "deploy: $runtime_env is missing; the launchd job sources it before every start" >&2
      exit 1
    }
    ;;
esac

run_privileged() {
  if [[ $manager != systemd || $(id -u) -eq 0 ]]; then
    "$@"
  else
    command -v sudo >/dev/null 2>&1 || {
      echo "deploy: sudo is required to install or restart the production service" >&2
      return 1
    }
    sudo "$@"
  fi
}

archive_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

scratch=$(mktemp -d "${TMPDIR:-/tmp}/ryker-deploy.XXXXXX")
preflight_database=
preflight_port=

cleanup() {
  if [[ -n $preflight_database ]]; then
    PGPASSWORD=postgres dropdb --if-exists -h 127.0.0.1 -p "$preflight_port" -U postgres \
      "$preflight_database" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$scratch"
}

trap cleanup EXIT

# Build the exact committed archive and prove it against migrations, a
# same-database restart, a pg_dump/restore boot, readiness, metrics, and clean
# shutdown before touching anything installed.
make elixir-candidate-check

version=$(scripts/elixir-release-version.sh)
archive="_build/prod/ryker-$version.tar.gz"
digest=$(archive_sha256 "$archive")
candidate="_build/prod/rel/ryker/bin/ryker"

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

candidate_eval() {
  # candidate_eval DATABASE_URL EXPRESSION: evaluate inside the built release
  # against one database, with nothing else from the deployment's environment.
  env DATABASE_URL="$1" POOL_SIZE=2 RELEASE_DISTRIBUTION=none \
    RELEASE_TMP="$scratch/release-tmp" RYKER_STATE_DIR="$scratch/state" \
    "$candidate" eval "$2"
}

pending_migrations() {
  candidate_eval "$1" \
    'Ryker.Release.migrations() |> Enum.count(&match?({:down, _, _}, &1)) |> IO.puts()' |
    tail -n 1
}

# A migration proven on an empty candidate database can still fail on real
# rows. When this archive carries migrations the live database has not applied,
# back the live database up and run them on a restored copy in the disposable
# test PostgreSQL first. Most deploys carry none and skip this after one check.
if [[ -r $runtime_env ]]; then
  database_url=$(env_value "$runtime_env" DATABASE_URL)
  [[ -n $database_url ]] || {
    echo "deploy: $runtime_env does not define DATABASE_URL" >&2
    exit 1
  }

  pending=$(pending_migrations "$database_url")
  [[ $pending =~ ^[0-9]+$ ]] || {
    echo "deploy: could not read the live migration state: $pending" >&2
    exit 1
  }

  if [[ $pending -gt 0 ]]; then
    echo "deploy: $pending pending migration(s); backing up the live database and rehearsing them on a restored copy"
    backup_dir="$state_root/backups"
    mkdir -p "$backup_dir"
    chmod 0700 "$backup_dir"
    backup="$backup_dir/pre-$version-$(date -u +%Y%m%dT%H%M%SZ).dump"
    pg_dump --format=custom --no-owner --no-privileges --file="$backup" \
      "${database_url/#ecto:/postgresql:}"
    chmod 0600 "$backup"
    echo "deploy: backup written to $backup"

    compose=(docker compose --project-name ryker-kernel --file "$repository/compose.test.yml")
    "${compose[@]}" up --detach --wait episode-db >/dev/null
    address=$("${compose[@]}" port episode-db 5432)
    preflight_port=${address##*:}
    preflight_database="ryker_preflight_${$}_${RANDOM}"
    PGPASSWORD=postgres createdb -h 127.0.0.1 -p "$preflight_port" -U postgres "$preflight_database"
    PGPASSWORD=postgres pg_restore --exit-on-error --no-owner --no-privileges \
      -h 127.0.0.1 -p "$preflight_port" -U postgres --dbname="$preflight_database" "$backup"

    preflight_url="ecto://postgres:postgres@127.0.0.1:$preflight_port/$preflight_database"
    if ! candidate_eval "$preflight_url" 'Ryker.Release.migrate()' >"$scratch/preflight-migrate.log" 2>&1; then
      echo "deploy: pending migrations failed against a restored copy of the live database; nothing was changed" >&2
      cat "$scratch/preflight-migrate.log" >&2
      exit 1
    fi

    remaining=$(pending_migrations "$preflight_url")
    [[ $remaining == 0 ]] || {
      echo "deploy: the rehearsal left $remaining migration(s) unapplied" >&2
      exit 1
    }
    echo "deploy: migrations rehearsed on the restored copy"
  else
    echo "deploy: no pending migrations"
  fi
else
  echo "deploy: $runtime_env is not readable; skipping the migration rehearsal"
fi

# The installer writes an immutable version directory and atomically moves only
# the `current` symlink. The old release remains available for an explicit,
# database-compatible rollback.
run_privileged scripts/install-elixir-release.sh \
  "$archive" "$version" "$digest" "$prefix" --local-build

stop_unmanaged_listener() {
  # A release started by hand (`bin/ryker daemon`) is not a launchd job.
  # It is stopped only when it is verifiably a Ryker release under the
  # install prefix; anything else holding the port aborts the deploy.
  local pids pid command
  pids=$(lsof -nP -t -iTCP:"$control_port" -sTCP:LISTEN 2>/dev/null || true)
  [[ -n $pids ]] || return 0

  for pid in $pids; do
    command=$(ps -o comm= -p "$pid" || true)
    if [[ $command != "$prefix/releases/"*/erts-*/bin/beam.smp ]]; then
      echo "deploy: port $control_port is held by pid $pid ($command), not a Ryker release under $prefix" >&2
      exit 1
    fi
    echo "deploy: stopping the Ryker release running outside launchd (pid $pid)"
    kill -TERM "$pid"
  done

  for _attempt in $(seq 1 60); do
    if [[ -z $(lsof -nP -t -iTCP:"$control_port" -sTCP:LISTEN 2>/dev/null || true) ]]; then
      return 0
    fi
    sleep 1
  done

  echo "deploy: the previous release did not release port $control_port within 60s" >&2
  exit 1
}

case $manager in
  systemd)
    run_privileged systemctl restart "$unit"
    ;;
  launchd)
    mkdir -p "$state_root/log" "$HOME/Library/LaunchAgents"
    sed -e "s|__LABEL__|$label|g" \
      -e "s|__PREFIX__|$prefix|g" \
      -e "s|__RUNTIME_ENV__|$runtime_env|g" \
      -e "s|__STATE_ROOT__|$state_root|g" \
      -e "s|__ERL_FLAGS__|$erl_flags|g" \
      deploy/launchd/ryker.plist.template >"$scratch/$label.plist"
    plutil -lint "$scratch/$label.plist" >/dev/null
    install -m 0644 "$scratch/$label.plist" "$plist"

    domain="gui/$(id -u)"
    launchctl bootout "$domain/$label" 2>/dev/null || true
    # bootout returns before launchd has finished tearing the job down, and a
    # bootstrap that races it fails with "Input/output error" -- which on
    # 2026-09-12 left the old release already stopped and nothing serving. Wait
    # for the label to actually leave the domain before loading it again.
    for _attempt in $(seq 1 60); do
      launchctl print "$domain/$label" >/dev/null 2>&1 || break
      sleep 1
    done
    if launchctl print "$domain/$label" >/dev/null 2>&1; then
      echo "deploy: $label is still loaded in $domain 60s after bootout" >&2
      exit 1
    fi
    stop_unmanaged_listener
    launchctl bootstrap "$domain" "$plist"
    ;;
esac

ready=0
for _attempt in $(seq 1 180); do
  if curl --silent --fail --max-time 1 "$health_url/healthz" >/dev/null 2>&1 &&
    curl --silent --fail --max-time 1 "$health_url/readyz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done

if [[ $ready != 1 ]]; then
  echo "deploy: $service did not become healthy and ready at $health_url" >&2
  case $manager in
    systemd) run_privileged systemctl status --no-pager "$unit" >&2 || true ;;
    launchd) tail -n 40 "$state_root/log/ryker.stderr.log" >&2 || true ;;
  esac
  exit 1
fi

installed_version=$("$prefix/current/bin/ryker" version)
if [[ $installed_version != "ryker $version" ]]; then
  echo "deploy: installed pointer reports '$installed_version', expected ryker $version" >&2
  exit 1
fi

scripts/check-running-elixir-release.sh "$health_url" "$version"

# Keep a few immutable installs for rollback; each is tens of megabytes and a
# hundred of them once filled the disk. Release directories are named by the
# installer's validated version strings, so ls is safe here.
current_target=$(readlink "$prefix/current")
# shellcheck disable=SC2012
ls -1t "$prefix/releases" | tail -n +"$((keep_releases + 1))" | while read -r old; do
  [[ $old == .* || "releases/$old" == "$current_target" ]] && continue
  run_privileged rm -rf -- "$prefix/releases/$old"
  echo "deploy: pruned old release $old"
done

echo "deploy: $service is active and ready on ryker $version"
echo "deploy: PostgreSQL custody will resume pending work after the normal restart"
