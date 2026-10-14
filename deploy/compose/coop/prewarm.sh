# shellcheck shell=sh
# Prepares a new worker image's box while the running worker keeps working:
# scripts/compose.sh worker-upgrade runs this inside a one-off container of the
# new image, on the live worker's volumes and Docker daemon. It builds the box
# base for the new Coop binary and the trusted box on top of it, as the
# entrypoint would at the new worker's first start, so the swap that follows
# finds both built and the worker is back in seconds. Without it a swapped
# worker was unhealthy for minutes, its jobs waiting, while it built them.
#
# The box is tagged ryker-coop-box:prewarm, not ryker-coop-box: the running
# worker starts its sessions from that tag, and this build is for the binary
# that replaces it. The new worker's entrypoint finds the same inputs at its
# first start, so its own build of ryker-coop-box comes from cache.
set -eu
umask 077

root=/var/lib/coop/tmp/prewarm
rm -rf "$root"
mkdir -p "$root/home" "$root/agents"

base_digest=$(sha256sum "$(command -v coop)")
base_image=ryker-coop-base:${base_digest%% *}
echo "prewarm: box base $base_image"
if ! docker image inspect "$base_image" >/dev/null 2>&1; then
  HOME="$root/home" COOP_CONFIG_DIR="$root/agents" COOP_BASE_IMAGE="$base_image" coop build --egress open
fi

# The running worker writes the box context, Ryker's CA included, at its start.
context=/var/lib/coop/tmp/ryker-box
if [ ! -r "$context/ryker-ca.pem" ]; then
  echo "prewarm: no box context at $context; is the worker running?" >&2
  exit 4
fi
base_id=$(docker image inspect "$base_image" --format '{{.Id}}')
inputs=$(sha256sum "$context/ryker-ca.pem" /usr/local/share/ryker/Box.Dockerfile | sha256sum | awk '{print $1}')
fingerprint=$(printf '%s\n%s\n' "$base_id" "$inputs" | sha256sum | awk '{print $1}')
echo "prewarm: trusted box $fingerprint"
docker build --build-arg "COOP_BASE_IMAGE=$base_image" --label "dev.ryker.box-inputs=$fingerprint" \
  --tag ryker-coop-box:prewarm --file /usr/local/share/ryker/Box.Dockerfile "$context"

# Filtered jobs need the daemon qualified; a failure leaves only them refused,
# and the new worker's entrypoint tries again.
echo "prewarm: network setup"
HOME="$root/home" COOP_CONFIG_DIR="$root/agents" COOP_BASE_IMAGE=ryker-coop-box:prewarm coop net setup ||
  echo "prewarm: network setup failed; the new worker tries again at its start" >&2
rm -rf "$root"
echo "prewarm: done"
