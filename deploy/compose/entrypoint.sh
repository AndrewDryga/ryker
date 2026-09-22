#!/bin/sh
set -eu

if [ "$#" -eq 0 ] || [ "$1" = "start" ]; then
  pki=/var/lib/ryker/pki
  shared=/var/lib/ryker-coop
  compose_worker_ip=${RYKER_COMPOSE_WORKER_IP:-127.0.0.1}
  mkdir -p "$pki" "$shared"
  chmod 0700 "$pki" "$shared"

  if [ ! -s "$pki/ca.pem" ] || [ ! -s "$pki/ca-key.pem" ]; then
    umask 077
    openssl genrsa -out "$pki/ca-key.pem" 4096 >/dev/null 2>&1
    openssl req -x509 -new -key "$pki/ca-key.pem" -sha256 -days 3650 \
      -subj "/CN=Ryker Compose Worker CA" -out "$pki/ca.pem" >/dev/null 2>&1
  fi

  if [ ! -s "$pki/server-key.pem" ]; then
    umask 077
    openssl genrsa -out "$pki/server-key.pem" 2048 >/dev/null 2>&1
  fi

  if [ ! -s "$pki/server.pem" ] ||
     ! openssl x509 -in "$pki/server.pem" -noout -checkhost ryker 2>/dev/null | grep -q 'does match certificate' ||
     ! openssl x509 -in "$pki/server.pem" -noout -checkip "$compose_worker_ip" 2>/dev/null | grep -q 'does match certificate'; then
    umask 077
    openssl req -new -key "$pki/server-key.pem" -subj "/CN=ryker" \
      -out "$pki/server.csr" >/dev/null 2>&1
    printf '%s\n' "subjectAltName=DNS:ryker,IP:127.0.0.1,IP:$compose_worker_ip" \
      'extendedKeyUsage=serverAuth' >"$pki/server.ext"
    openssl x509 -req -in "$pki/server.csr" -CA "$pki/ca.pem" -CAkey "$pki/ca-key.pem" \
      -CAcreateserial -out "$pki/server.pem" -days 825 -sha256 -extfile "$pki/server.ext" \
      >/dev/null 2>&1
    rm -f "$pki/server.csr" "$pki/server.ext" "$pki/ca.srl"
  fi

  cp "$pki/ca.pem" "$shared/worker-ca.pem"
  chmod 0600 "$shared/worker-ca.pem"
  /opt/ryker/bin/ryker eval 'Ryker.Release.migrate()'
  exec /opt/ryker/bin/ryker start
fi

exec /opt/ryker/bin/ryker "$@"
