#!/bin/sh
# Refuse a changed OrbStack uplink instead of exposing the host to jobs.
set -eu
sysctl -q -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
[ "$(ip -4 route show default | awk '{print $3, $5}')" = '192.168.139.1 eth0' ]
[ -z "$(ip -6 route show default)" ]
guest_cidr=$(ip -o -4 addr show dev eth0 | awk '{print $4}')
# Only the observed guest's DNS listener is reachable from worker bridges.
case "$guest_cidr" in
  192.168.139.*/24) ;;
  *) exit 1 ;;
esac
guest_host_octet=${guest_cidr#192.168.139.}
guest_host_octet=${guest_host_octet%/24}
case "$guest_host_octet" in '' | *[!0-9]*) exit 1 ;; esac
[ "$guest_host_octet" -ge 2 ]
[ "$guest_host_octet" -le 254 ]
batch=$(mktemp /run/ryker-worker-network.XXXXXX)
trap 'rm -f "$batch"' EXIT
printf 'define guest_ipv4 = %s\n' "${guest_cidr%/24}" > "$batch"
test -s /etc/ryker-worker-controller-networks
while IFS= read -r network; do
  case "$network" in '' | *[!0-9./]*) exit 1 ;; esac
done < /etc/ryker-worker-controller-networks
printf 'define controller_networks = { %s }\n' "$(paste -sd, /etc/ryker-worker-controller-networks)" >> "$batch"
if nft list table inet ryker_worker >/dev/null 2>&1; then
  printf 'delete table inet ryker_worker\n' >> "$batch"
fi
cat /etc/ryker-worker-network.nft >> "$batch"
nft --check -f "$batch"
nft -f "$batch"
# The Mac uplink does not route to Docker bridges. Keep the certificate's
# existing gateway address and send only that /32 through Docker's bridge.
ip route replace 172.30.42.10/32 via 192.168.139.2 dev eth0
