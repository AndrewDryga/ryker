#!/usr/bin/env bash
set -euo pipefail
tools=/opt/coop-tools
# Refresh operator access from this allocation's read-only seed on every boot.
install -d -o coop -g coop -m 0700 /var/lib/coop/.ssh
install -o coop -g coop -m 0600 /opt/coop-seed/operator.pub /var/lib/coop/.ssh/authorized_keys
if ! command -v iptables >/dev/null || ! command -v git-lfs >/dev/null || ! command -v jq >/dev/null || ! command -v nft >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Acquire::Retries=3 update
  apt-get -o Acquire::Retries=3 install -y nftables iptables kmod procps pigz git git-lfs ca-certificates openssl jq
fi
getent group docker >/dev/null || groupadd --system docker
usermod -aG docker coop
install -m 0755 "$tools"/engine/* /usr/local/bin/
install -m 0644 "$tools/docker.service" /etc/systemd/system/docker.service
install -d /usr/local/libexec/docker/cli-plugins
install -m 0755 "$tools/coop" "$tools/docker" /usr/local/bin/
rm -f /usr/local/bin/ryker-model-login
install -m 0755 "$tools/docker-buildx" "$tools/docker-compose" /usr/local/libexec/docker/cli-plugins/
install -m 0755 "$tools/connect.sh" /usr/local/bin/coop-connect
install -m 0644 "$tools/worker.env" /etc/coop-worker.env
install -m 0644 "$tools/coop-worker.service" /etc/systemd/system/
install -d -o coop -g coop -m 0700 /var/lib/coop/{agents,sessions,tmp}
install -m 0644 "$tools"/coop-egress.{service,timer} /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now coop-egress.timer
systemctl enable --now docker
systemctl enable --now --no-block coop-worker
