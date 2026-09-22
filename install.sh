#!/bin/sh
set -eu

repository=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
state_dir=${RYKER_INSTALL_STATE:-$repository/.ryker}
env_file=$state_dir/compose.env

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Ryker needs $1. Install it, then run ./install.sh again." >&2
    exit 1
  }
}

need docker
need openssl
need curl
docker compose version >/dev/null 2>&1 || {
  echo "Ryker needs Docker Compose v2 (the 'docker compose' command)." >&2
  exit 1
}

mkdir -p "$state_dir"
chmod 0700 "$state_dir"

random_urlsafe() {
  openssl rand -base64 "$1" | tr '+/' '-_' | tr -d '=\n'
}

random_base64() {
  openssl rand -base64 "$1" | tr -d '\n'
}

if [ ! -f "$env_file" ]; then
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

  umask 077
  db_password=$(random_urlsafe 32)
  checkpoint_key=$(random_base64 32)
  credential_key=$(random_base64 32)
  state_tools_token=$(random_urlsafe 32)

  apply_patch_marker=RYKER_GENERATED_ENV
  {
    echo "# $apply_patch_marker - generated once by install.sh; keep this file with backups."
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
  chmod 0600 "$env_file"
fi

cd "$repository"
docker compose --env-file "$env_file" up --detach --build --wait database ryker ryker-coop-docker
docker compose --env-file "$env_file" exec -T ryker \
  /opt/ryker/bin/ryker eval 'Ryker.Release.prepare_bundled_coop(log: false)'
docker compose --env-file "$env_file" run --rm --no-deps --entrypoint coop ryker-coop build

if ! docker compose --env-file "$env_file" run --rm --no-deps -T \
  --entrypoint sh ryker-coop -c \
  'find /var/lib/coop/agents/codex/profiles -type f -name auth.json -size +0c 2>/dev/null | grep -q .'; then
  codex_auth_root=${CODEX_HOME:-$HOME/.codex}
  codex_auth=$codex_auth_root/auth.json

  if [ -s "$codex_auth" ]; then
    docker compose --env-file "$env_file" run --rm --no-deps -T \
      --entrypoint sh ryker-coop -c \
      'umask 077; mkdir -p /var/lib/coop/agents/codex/profiles/default; cat > /var/lib/coop/agents/codex/profiles/default/auth.json' \
      <"$codex_auth"
    echo "Imported the existing Codex sign-in into Ryker's private worker volume."
  else
    echo "Connect the model account Ryker will use for work. This is stored only in the private worker volume."
    docker compose --env-file "$env_file" run --rm --no-deps --entrypoint coop \
      ryker-coop login codex
  fi
fi

docker compose --env-file "$env_file" up --detach --build --wait ryker-coop

worker_attempt=0
while [ "$worker_attempt" -lt 120 ]; do
  if docker compose --env-file "$env_file" exec -T ryker \
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

control_port=$(sed -n 's/^RYKER_CONTROL_PORT=//p' "$env_file" | tail -n 1)
control_port=${control_port:-4321}
origin="http://127.0.0.1:$control_port"
setup_url="$origin/settings"

attempt=0
while [ "$attempt" -lt 60 ]; do
  if curl --fail --silent --output /dev/null "$origin/healthz" 2>/dev/null &&
     curl --fail --silent --output /dev/null "$origin/readyz" 2>/dev/null &&
     headers=$(curl --fail --silent --show-error --dump-header - --output /dev/null "$origin/readyz" 2>/dev/null); then
    running=$(printf '%s\n' "$headers" | awk 'BEGIN{IGNORECASE=1} /^x-ryker-version:/ {gsub("\r", "", $2); print $2; exit}')
    expected=$(sed -n 's/^RYKER_VERSION=//p' "$env_file" | tail -n 1)
    if [ "$running" = "$expected" ]; then
      echo "Ryker is ready: $setup_url"
      exit 0
    fi
  fi
  attempt=$((attempt + 1))
  sleep 1
done

echo "Ryker started, but the exact version did not become ready. Run: ./scripts/compose.sh status" >&2
exit 1
