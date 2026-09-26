#!/usr/bin/env bash
# Runs the live acceptance lane inside the deployed ryker container, against
# the installation's own durable settings and database: the container already
# carries DATABASE_URL and the encryption roots, so nothing is copied out of
# .ryker/compose.env and nothing runs a second Ryker.
set -euo pipefail

channel_ref=${1:-}
timeout_seconds=${RYKER_LIVE_TIMEOUT_SECONDS:-600}
repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
state_dir=${RYKER_INSTALL_STATE:-$repository/.ryker}
env_file=$state_dir/compose.env

if [[ $# -ne 1 || -z $channel_ref ]]; then
  echo "usage: scripts/elixir-live-acceptance.sh SLACK_TEST_CHANNEL" >&2
  echo "the lane runs in the deployed ryker container and reads its own durable settings" >&2
  exit 2
fi

if ((${#channel_ref} < 1 || ${#channel_ref} > 256)) ||
  [[ ! $channel_ref =~ ^[A-Za-z0-9._:-]+$ ]]; then
  echo "live acceptance Slack channel reference is invalid" >&2
  exit 2
fi

if [[ ! $timeout_seconds =~ ^[0-9]+$ ]] || ((timeout_seconds < 1 || timeout_seconds > 1800)); then
  echo "RYKER_LIVE_TIMEOUT_SECONDS must be between 1 and 1800" >&2
  exit 2
fi

if [[ ! -r $env_file ]]; then
  echo "Ryker is not installed here: $env_file is missing. Run ./install.sh first." >&2
  exit 1
fi

exec docker compose --env-file "$env_file" exec -T \
  --env "RYKER_LIVE_CHANNEL=$channel_ref" \
  --env "RYKER_LIVE_TIMEOUT_SECONDS=$timeout_seconds" \
  ryker /opt/ryker/bin/ryker eval 'Ryker.Acceptance.Live.run_from_env!()'
