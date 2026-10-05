#!/bin/sh
set -eu

if [ "$#" -eq 0 ] || [ "$1" = "start" ]; then
  pki=/var/lib/ryker/pki
  shared=/var/lib/ryker-coop
  mkdir -p "$shared"
  chmod 0700 "$shared"

  /usr/local/bin/ryker-gateway-pki "$pki" "${RYKER_COMPOSE_WORKER_IP:-127.0.0.1}"

  cp "$pki/ca.pem" "$shared/worker-ca.pem"
  chmod 0600 "$shared/worker-ca.pem"
  /opt/ryker/bin/ryker eval 'Ryker.Release.migrate()'
  exec /opt/ryker/bin/ryker start
fi

exec /opt/ryker/bin/ryker "$@"
