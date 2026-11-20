#!/usr/bin/env bash
# The guest and its job containers need public package/model endpoints and one
# private service. Keep infrastructure, storage, metadata and tailnet addresses
# off the guest uplink. Docker-to-Docker traffic stays on its own bridges.
set -euo pipefail
uplink=$(ip -4 route show default | awk 'NR==1 {print $5}')
[[ $uplink =~ ^[[:alnum:]_-]+$ ]]
if ! nft list table inet coop_egress >/dev/null 2>&1; then
  nft -f - <<EOF
table inet coop_egress {
  set fleet { type ipv4_addr; }
  chain uplink {
    ct state established,related accept
    ip daddr 10.0.2.3 meta l4proto { tcp, udp } th dport 53 accept
    udp sport 68 udp dport 67 accept
    ip daddr @fleet tcp dport $RYKER_WORKER_PORT accept
    ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } reject
    meta nfproto ipv6 reject
  }
  chain output {
    type filter hook output priority -10; policy accept;
    oifname "$uplink" jump uplink
  }
  chain forward {
    type filter hook forward priority -10; policy accept;
    oifname "$uplink" jump uplink
  }
}
EOF
fi
# Retain the last working address set through a transient discovery outage.
if ! addresses=$(getent ahostsv4 "$RYKER_WORKER_HOST" | awk '{print $1}' | sort -u) || [[ -z $addresses ]]; then
  echo "Ryker gateway discovery pending; keeping current egress policy" >&2
  exit 0
fi
{
  echo 'flush set inet coop_egress fleet'
  for ip in $addresses; do
    [[ $ip =~ ^[0-9.]+$ ]]
    printf 'add element inet coop_egress fleet { %s }\n' "$ip"
  done
} | nft -f -
