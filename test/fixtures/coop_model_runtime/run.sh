#!/usr/bin/env bash
# All three images must already exist locally. The guard tag must match the Coop binary.
set -euo pipefail
[[ $# == 4 ]] || { echo 'usage: run.sh /absolute/linux-coop worker-image clients-image guard-image' >&2; exit 2; }
[[ $1 == /* && -x $1 ]] || { echo 'Supply an absolute path to the Linux Coop executable.' >&2; exit 2; }
umask 077
fixture_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$fixture_dir/../../.." && pwd)
dind=docker:29.10.0-dind-alpine3.24@sha256:4bbc7223f81db790097c6dea42fb93e05b8fead4f0431fbe6ccaba6e8473201c
postgres=postgres:19.0-alpine@sha256:8b0ff4cdf221f0c53d7fcda681d3b461be725c492cd881c5ec9c0ad25023f188
for image in "$2" "$3" "$4" "$dind" "$postgres"; do docker image inspect "$image" >/dev/null; done
(( $(docker info --format '{{.NCPU}}') >= 7 )) || { echo 'The two workers require seven Docker CPUs.' >&2; exit 1; }

scratch=$(mktemp -d)
owner=coop-fleet-proof-$(openssl rand -hex 8)
export RYKER_FLEET_WORKER_IMAGE=$2 RYKER_FLEET_COOP_BINARY=$1
export RYKER_FLEET_FIXTURE_IMAGE=$owner:clients
engines=() volumes=()
database=""
cleanup() {
  local id
  if [[ -n $database ]]; then docker rm -f "$database" >/dev/null || true; fi
  for id in "${engines[@]:-}"; do [[ -z $id ]] || docker rm -f "$id" >/dev/null || true; done
  for id in "${volumes[@]:-}"; do [[ -z $id ]] || docker volume rm "$id" >/dev/null || true; done
  docker image rm "$RYKER_FLEET_FIXTURE_IMAGE" >/dev/null 2>&1 || true
  rm -rf "$scratch"
}
trap cleanup EXIT
cp "$fixture_dir"/{Dockerfile,*.mjs} "$scratch/"
arch=$(docker image inspect "$3" --format '{{.Architecture}}')
GOOS=linux GOARCH=$arch CGO_ENABLED=0 go build -o "$scratch/native-socket" "$fixture_dir/native_socket.go"
docker build --network none --pull=false --build-arg "BASE_IMAGE=$3" -t "$RYKER_FLEET_FIXTURE_IMAGE" "$scratch" >/dev/null

start_engine() {
  local role=$1 cpus=$2 bridge=$3 state socket data engine volume
  state=$owner-$role-state socket=$owner-$role-socket data=$owner-$role-data
  for volume in "$state" "$socket" "$data"; do
    docker volume create "$volume" >/dev/null
    volumes+=("$volume")
  done
  engine=$(docker run -d --privileged --pull never --cpuset-cpus "$cpus" -e DOCKER_TLS_CERTDIR= \
    --mount "type=volume,src=$state,dst=/var/lib/coop" --mount "type=volume,src=$socket,dst=/run/fleet-engine" \
    --mount "type=volume,src=$data,dst=/var/lib/docker" "$dind" dockerd --host=unix:///var/run/docker.sock \
    --host=unix:///run/fleet-engine/docker.sock --group=1000 --storage-driver=overlay2 --bip="$bridge")
  engines+=("$engine")
  for _ in {1..60}; do docker exec "$engine" docker info >/dev/null 2>&1 && break; sleep 1; done
  docker exec "$engine" docker info >/dev/null
  docker exec "$engine" sh -ec 'mkdir -p /var/lib/coop/tmp; chown -R 1000:1000 /var/lib/coop; chmod 700 /var/lib/coop /var/lib/coop/tmp'
  docker save "$RYKER_FLEET_FIXTURE_IMAGE" "$guard" | docker exec -i "$engine" docker load >/dev/null
  if [[ $role == large ]]; then
    export RYKER_FLEET_ENGINE=$engine RYKER_FLEET_STATE_VOLUME=$state RYKER_FLEET_SOCKET_VOLUME=$socket
  else
    export RYKER_FLEET_SECOND_ENGINE=$engine RYKER_FLEET_SECOND_STATE_VOLUME=$state RYKER_FLEET_SECOND_SOCKET_VOLUME=$socket
  fi
}
guard=$4
start_engine large 1-6 172.28.251.1/24
start_engine small 0 172.28.252.1/24

openssl rand -hex 32 >"$scratch/db-password"
database=$(docker run -d --pull never --publish 127.0.0.1::5432 \
  --mount "type=bind,src=$scratch/db-password,dst=/run/secrets/db,readonly" -e POSTGRES_PASSWORD_FILE=/run/secrets/db "$postgres")
for _ in {1..60}; do docker exec "$database" pg_isready -U postgres >/dev/null && break; sleep 1; done
export PGHOST=127.0.0.1 PGUSER=postgres PGDATABASE=ryker_test_fleet MIX_ENV=test RYKER_FLEET_RUNTIME=1
PGPORT=$(docker port "$database" 5432/tcp | cut -d: -f2)
PGPASSWORD=$(cat "$scratch/db-password")
export PGPORT PGPASSWORD
cd "$root"
scripts/elixir-mix.sh "do" ecto.create --quiet + ecto.migrate --quiet + test test/ryker/coop_fleet/model_runtime_test.exs --trace
