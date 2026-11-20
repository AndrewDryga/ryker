#!/usr/bin/env bash
set -euo pipefail
state=/var/lib/coop/sessions
ca=/var/lib/coop/worker-ca.pem
token=/var/lib/coop/enroll-token
until [[ -s "$ca" ]]; do sleep 3; done

# Cache the qualified job image across restarts; the key covers all build inputs.
base=ryker-coop-base:$(sha256sum /usr/local/bin/coop | cut -d' ' -f1)
if ! docker image inspect "$base" >/dev/null 2>&1; then
  COOP_BASE_IMAGE="$base" coop build --egress open
fi
box=/opt/coop-tools/Box.Dockerfile
fingerprint=$( { docker image inspect -f '{{.Id}}' "$base"; sha256sum "$ca" "$box"; } | sha256sum | cut -d' ' -f1)
if [[ $(docker image inspect -f '{{index .Config.Labels "dev.ryker.box-inputs"}}' "$COOP_BASE_IMAGE" 2>/dev/null || true) != "$fingerprint" ]]; then
  dir=$(mktemp -d)
  trap 'rm -rf -- "$dir"' EXIT
  cp "$ca" "$dir/ryker-ca.pem"
  docker build --build-arg "COOP_BASE_IMAGE=$base" --label "dev.ryker.box-inputs=$fingerprint" \
    -f "$box" -t "$COOP_BASE_IMAGE" "$dir"
  rm -rf -- "$dir"
  trap - EXIT
fi
coop net setup
echo "Coop box and filtered network are ready for enrollment"
until [[ -s "$state/identity.json" || -s "$token" ]]; do sleep 3; done
options=(--controller "$RYKER_WORKER_CONTROLLER" --ca-file "$ca" --state "$state")
if [[ ! -s "$state/identity.json" ]]; then options+=(--token-file "$token"); fi
exec coop sessions connect "${options[@]}"
