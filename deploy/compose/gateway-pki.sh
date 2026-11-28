#!/bin/sh
# The worker gateway's TLS, issued and renewed before Ryker starts: a CA the
# bundled worker trusts, and a server certificate for the names it dials.
#
#   gateway-pki.sh PKI_DIR WORKER_IP
set -eu

[ "$#" -eq 2 ] || {
  echo "usage: gateway-pki.sh PKI_DIR WORKER_IP" >&2
  exit 2
}

pki=$1
worker_ip=$2
# The optional address is both the published interface and the TLS identity.
# Accept only canonical private LAN or shared-address-space VPN IPv4 literals.
address=${RYKER_FLEET_ADDRESS:-}
extra_san=
if [ -n "$address" ]; then
  if ! printf '%s\n' "$address" | awk -F '.' '
    NF != 4 {exit 1}
    {for (i=1; i<=4; i++) if ($i !~ /^(0|[1-9][0-9]?[0-9]?)$/ || $i+0>255) exit 1
     if (!($1==10 || ($1==172 && $2>=16 && $2<=31) || ($1==192 && $2==168) ||
           ($1==100 && $2>=64 && $2<=127))) exit 1}
    END {if (NR != 1) exit 1}'; then
    echo "RYKER_FLEET_ADDRESS requires a private LAN or VPN IPv4 address on this controller." >&2
    exit 1
  fi
  extra_san=",IP:$address"
fi

mkdir -p "$pki"
chmod 0700 "$pki"

ca_files=0
if [ -s "$pki/ca.pem" ]; then ca_files=$((ca_files + 1)); fi
if [ -s "$pki/ca-key.pem" ]; then ca_files=$((ca_files + 1)); fi

# Half a CA was replaced with a new one, which signs nothing the enrolled
# workers trust, and the worker crash-looped on its invalid identity
# (2026-10-04 review). The missing half has to come back from a backup.
if [ "$ca_files" -eq 1 ]; then
  echo "The worker gateway's CA in $pki is missing ca.pem or ca-key.pem. Restore both from a backup; a new CA would sign nothing the enrolled workers trust." >&2
  exit 1
fi

if [ "$ca_files" -eq 0 ]; then
  umask 077
  openssl genrsa -out "$pki/ca-key.pem" 4096 >/dev/null 2>&1
  openssl req -x509 -new -key "$pki/ca-key.pem" -sha256 -days 3650 \
    -subj "/CN=Ryker Compose Worker CA" -out "$pki/ca.pem" >/dev/null 2>&1
fi

if [ ! -s "$pki/server-key.pem" ]; then
  umask 077
  openssl genrsa -out "$pki/server-key.pem" 2048 >/dev/null 2>&1
fi

# Reissued when it is missing, names another host or address, was signed by
# another CA, or ends within 30 days: nothing renewed it, so TLS to the
# bundled worker would have broken about 825 days after install (2026-10-04
# review).
if [ ! -s "$pki/server.pem" ] ||
   ! openssl x509 -in "$pki/server.pem" -noout -checkhost ryker 2>/dev/null | grep -q 'does match certificate' ||
   ! openssl x509 -in "$pki/server.pem" -noout -checkip "$worker_ip" 2>/dev/null | grep -q 'does match certificate' ||
   { [ -n "$address" ] && ! openssl x509 -in "$pki/server.pem" -noout -checkip "$address" 2>/dev/null | grep -q 'does match certificate'; } ||
   ! openssl verify -CAfile "$pki/ca.pem" "$pki/server.pem" >/dev/null 2>&1 ||
   ! openssl x509 -in "$pki/server.pem" -noout -checkend 2592000 >/dev/null 2>&1; then
  umask 077
  openssl req -new -key "$pki/server-key.pem" -subj "/CN=ryker" \
    -out "$pki/server.csr" >/dev/null 2>&1
  printf '%s\n' "subjectAltName=DNS:ryker,IP:127.0.0.1,IP:$worker_ip$extra_san" \
    'extendedKeyUsage=serverAuth' >"$pki/server.ext"
  openssl x509 -req -in "$pki/server.csr" -CA "$pki/ca.pem" -CAkey "$pki/ca-key.pem" \
    -CAcreateserial -out "$pki/server.pem" -days 825 -sha256 -extfile "$pki/server.ext" \
    >/dev/null 2>&1
  rm -f "$pki/server.csr" "$pki/server.ext" "$pki/ca.srl"
fi
