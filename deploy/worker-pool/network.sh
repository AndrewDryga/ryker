#!/bin/sh
# Refuse a changed Colima uplink instead of exposing host loopback to jobs.
set -eu
[ "$(ip -4 route show default | awk '{print $3, $5}')" = '192.168.5.2 eth0' ]
[ -z "$(ip -6 route show default)" ]
guest_cidr=$(ip -o -4 addr show dev eth0 | awk '{print $4}')
# Colima allocates another address when another profile already uses .3.
# Only the observed guest's DNS listener is reachable from worker bridges.
case "$guest_cidr" in
  192.168.5.*/24) ;;
  *) exit 1 ;;
esac
guest_host_octet=${guest_cidr#192.168.5.}
guest_host_octet=${guest_host_octet%/24}
case "$guest_host_octet" in '' | *[!0-9]*) exit 1 ;; esac
[ "$guest_host_octet" -ge 3 ]
[ "$guest_host_octet" -le 254 ]
batch=$(mktemp /run/ryker-worker-network.XXXXXX)
trap 'rm -f "$batch"' EXIT
printf 'define guest_ipv4 = %s\n' "${guest_cidr%/24}" > "$batch"
if nft list table inet ryker_worker >/dev/null 2>&1; then
  printf 'delete table inet ryker_worker\n' >> "$batch"
fi
cat /etc/ryker-worker-network.nft >> "$batch"
nft --check -f "$batch"
nft -f "$batch"
