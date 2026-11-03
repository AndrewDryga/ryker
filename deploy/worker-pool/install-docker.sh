#!/bin/sh
# Bootstrap only the owned isolated worker; package installation cannot start
# Docker before the boot-required network policy has been installed.
set -eu
engine=5:28.2.2-1~debian.12~bookworm
containerd=1.7.27-1
if [ "$(dpkg-query -W -f='${Version}' docker-ce 2>/dev/null || true)" = "$engine" ] &&
   [ "$(dpkg-query -W -f='${Version}' docker-ce-cli 2>/dev/null || true)" = "$engine" ] &&
   [ "$(dpkg-query -W -f='${Version}' containerd.io 2>/dev/null || true)" = "$containerd" ] &&
   command -v nft >/dev/null && command -v jq >/dev/null; then
  exit 0
fi
[ "$(dpkg --print-architecture)" = arm64 ]
saved=$(mktemp -d /run/ryker-worker-packages.XXXXXX)
policy=/usr/sbin/policy-rc.d
if [ -e "$policy" ] || [ -L "$policy" ]; then
  cp -a "$policy" "$saved/original"
fi
restore_policy() {
  rm -f "$policy"
  if [ -e "$saved/original" ] || [ -L "$saved/original" ]; then
    mv "$saved/original" "$policy"
  fi
  rm -rf "$saved"
}
trap restore_policy EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
rm -f "$policy"
printf '#!/bin/sh\nexit 101\n' > "$policy"
chmod 0755 "$policy"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL --retry 3 https://download.docker.com/linux/debian/gpg -o "$saved/docker.asc"
printf '%s\n' "1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570  $saved/docker.asc" | sha256sum -c -
install -m 0644 "$saved/docker.asc" /etc/apt/keyrings/docker.asc
printf '%s\n' 'deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable' > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y --no-install-recommends "docker-ce=$engine" "docker-ce-cli=$engine" "containerd.io=$containerd" nftables jq
