#!/usr/bin/env bash
# Build, prove, install, and restart the canonical Elixir/PostgreSQL service.
#
# This is intentionally a one-writer replacement. Durable admission, Work,
# delivery, schedule, and fleet custody recover from PostgreSQL after systemd
# restarts the process; there is no canary/promote deployment state.
set -euo pipefail

if [[ $# -ne 0 ]]; then
  echo "usage: scripts/deploy.sh" >&2
  exit 2
fi

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
prefix=${RESPONDER_DEPLOY_PREFIX:-/usr/local/lib/responder}
unit=${RESPONDER_SYSTEMD_UNIT:-responder.service}
health_url=${RESPONDER_HEALTH_URL:-http://127.0.0.1:4321}

cd "$repository"

if [[ -n $(git status --porcelain) ]]; then
  echo "deploy: refusing to deploy a dirty tree — commit first" >&2
  exit 1
fi

command -v systemctl >/dev/null 2>&1 || {
  echo "deploy: systemctl is required by the canonical production deployment" >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  echo "deploy: curl is required for post-restart health verification" >&2
  exit 1
}

# Prove the exact committed archive against migrations, a same-database restart,
# a pg_dump/restore boot, readiness, metrics, and clean shutdown before touching
# the installed pointer.
make elixir-candidate-check

version=$(scripts/elixir-release-version.sh)
archive="_build/prod/responder-$version.tar.gz"
digest=$(if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$archive" | awk '{print $1}'
else
  shasum -a 256 "$archive" | awk '{print $1}'
fi)

run_privileged() {
  if [[ $(id -u) -eq 0 ]]; then
    "$@"
  else
    command -v sudo >/dev/null 2>&1 || {
      echo "deploy: sudo is required to install or restart the production service" >&2
      return 1
    }
    sudo "$@"
  fi
}

# The installer writes an immutable version directory and atomically moves only
# the `current` symlink. The old release remains available for an explicit,
# database-compatible rollback.
run_privileged scripts/install-elixir-release.sh \
  "$archive" "$version" "$digest" "$prefix" --local-build

run_privileged systemctl restart "$unit"

ready=0
for _attempt in $(seq 1 180); do
  if curl --silent --fail --max-time 1 "$health_url/healthz" >/dev/null 2>&1 &&
    curl --silent --fail --max-time 1 "$health_url/readyz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done

if [[ $ready != 1 ]]; then
  echo "deploy: $unit did not become healthy and ready at $health_url" >&2
  run_privileged systemctl status --no-pager "$unit" >&2 || true
  exit 1
fi

run_privileged systemctl is-active --quiet "$unit"

installed_version=$("$prefix/current/bin/responder" version)
if [[ $installed_version != "responder $version" ]]; then
  echo "deploy: installed pointer reports '$installed_version', expected responder $version" >&2
  exit 1
fi

scripts/check-running-elixir-release.sh "$health_url" "$version"

echo "deploy: $unit is active and ready on responder $version"
echo "deploy: PostgreSQL custody will resume pending work after the normal restart"
