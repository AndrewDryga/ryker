#!/bin/sh
set -eu
umask 077

state=/var/lib/coop
shared=/var/lib/ryker-coop
identity=$state/sessions/identity.json
token=$shared/enrollment-token
marker=$shared/enrolled
ca=$shared/worker-ca.pem
controller=https://172.30.42.10:4322
worker_id=${RYKER_BUNDLED_COOP_WORKER_ID:-ryker-compose}
workspace_ref=${RYKER_BUNDLED_COOP_WORKSPACE:-ryker-compose}
trusted_box=ryker-coop-box
trusted_box_dockerfile=/usr/local/share/ryker/Box.Dockerfile
connector=

mkdir -p "$state/sessions" "$state/agents" "$state/tmp"
chmod 0700 "$state" "$state/sessions" "$state/agents" "$state/tmp"

stop_connector() {
  if [ -n "$connector" ]; then
    kill "$connector" 2>/dev/null || true
    wait "$connector" || true
    connector=
  fi
}
trap stop_connector EXIT
trap 'exit 0' HUP INT TERM

# An invalid identity is not an expired identity: never erase it as recovery.
# Read one bounded snapshot so a concurrent atomic renewal cannot mix keys. The
# keys checked must be there; a newer Coop may write more (2026-10-04 review).
identity_state() {
  [ ! -L "$identity" ] || return 1
  if [ ! -e "$identity" ]; then
    echo absent
    return
  fi
  [ "$(find "$identity" -prune -type f -perm 0600 -size -65537c -print)" = "$identity" ] || return 1
  document=$(head -c 65537 "$identity") || return 1
  certificate=$(printf '%s' "$document" | jq -er \
    --arg controller "$controller" --arg worker "$worker_id" --arg workspace "$workspace_ref" '
    select(type == "object" and
      (["ca_certificate_pem", "certificate_pem", "controller_url",
        "private_key_pem", "worker_id", "workspace_ref"] - keys) == []) |
    select(.controller_url == $controller and .worker_id == $worker and
      .workspace_ref == $workspace) | .certificate_pem | select(type == "string")
  ') || return 1
  printf '%s\n' "$certificate" | openssl verify -no_check_time -purpose sslclient \
    -CAfile "$ca" -no-CApath >/dev/null 2>&1 || return 1
  subject=$(printf '%s\n' "$certificate" | openssl x509 -noout -subject -nameopt RFC2253) || return 1
  case "$subject" in
    "subject=CN=$worker_id"|"subject=CN=$worker_id,"*) ;;
    *) return 1 ;;
  esac
  cert_key=$(printf '%s\n' "$certificate" | openssl x509 -noout -pubkey) || return 1
  identity_key=$(printf '%s' "$document" | jq -er '.private_key_pem | select(type == "string")' |
    openssl pkey -pubout -passin pass: 2>/dev/null) || return 1
  [ "$cert_key" = "$identity_key" ] || return 1
  if printf '%s\n' "$certificate" | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
    printf '%s\n' "$certificate" | openssl verify -purpose sslclient \
      -CAfile "$ca" -no-CApath >/dev/null 2>&1 || return 1
    echo valid
  else
    echo expired
  fi
}

# Call only after the connector exits, then re-read: it may have renewed while stopping.
recover_identity() {
  identity_status=$(identity_state) || {
    echo "Ryker's worker identity is invalid; leaving it untouched." >&2
    return 1
  }
  case "$identity_status" in
    expired)
      echo "Ryker's worker identity expired; requesting a replacement." >&2
      rm -f "$identity" "$marker"
      ;;
    absent) rm -f "$marker" ;;
    valid) : >"$marker" ;;
  esac
}

until [ -r "$ca" ]; do sleep 1; done
recover_identity

prepare_ryker_box() {
  # A base from another worker version must not satisfy this binary's build.
  base_binary=$(command -v coop)
  base_digest=$(sha256sum "$base_binary")
  base_image=ryker-coop-base:${base_digest%% *}
  if ! docker image inspect "$base_image" >/dev/null 2>&1; then
    COOP_BASE_IMAGE="$base_image" coop build --egress open
  fi

  context=$state/tmp/ryker-box
  mkdir -p "$context"
  cp "$ca" "$context/ryker-ca.pem"

  base_id=$(docker image inspect "$base_image" --format '{{.Id}}')
  inputs=$(sha256sum "$context/ryker-ca.pem" "$trusted_box_dockerfile" | sha256sum | awk '{print $1}')
  fingerprint=$(printf '%s\n%s\n' "$base_id" "$inputs" | sha256sum | awk '{print $1}')
  current=$(docker image inspect "$trusted_box" --format '{{index .Config.Labels "dev.ryker.box-inputs"}}' 2>/dev/null || true)

  if [ "$current" != "$fingerprint" ]; then
    docker build \
      --build-arg "COOP_BASE_IMAGE=$base_image" \
      --label "dev.ryker.box-inputs=$fingerprint" \
      --tag "$trusted_box" \
      --file "$trusted_box_dockerfile" \
      "$context"
  fi

  export COOP_BASE_IMAGE=ryker-coop-box
}

prepare_ryker_box

while :; do
  recover_identity
  until [ -r "$identity" ] || [ -r "$token" ]; do sleep 1; done
  coop sessions connect --controller "$controller" --token-file "$token" \
    --ca-file "$ca" --state "$state/sessions" &
  connector=$!

  # The connector is checked every two seconds; the identity, a 24-hour
  # certificate the connector renews itself, once a minute. Reading it runs
  # find, jq and openssl about ten times, and every two seconds that kept an
  # idle worker at 11 to 17% CPU (2026-10-04).
  checks=0
  while kill -0 "$connector" 2>/dev/null; do
    if [ $((checks % 30)) -eq 0 ]; then
      identity_status=$(identity_state) || {
        echo "Ryker's worker identity is invalid; leaving it untouched." >&2
        exit 1
      }
      case "$identity_status" in
        valid) : >"$marker" ;;
        expired) break ;;
      esac
    fi
    checks=$((checks + 1))
    sleep 2
  done

  stop_connector
  recover_identity
  sleep 1
done
