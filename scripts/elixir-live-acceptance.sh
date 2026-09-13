#!/usr/bin/env bash
set -euo pipefail

channel_ref=${1:-}
release=${RYKER_ELIXIR_RELEASE:-"$HOME/.local/lib/ryker-elixir/current/bin/ryker"}
timeout_seconds=${RYKER_LIVE_TIMEOUT_SECONDS:-600}

if [[ -z $channel_ref ]]; then
  echo "usage: scripts/elixir-live-acceptance.sh SLACK_TEST_CHANNEL" >&2
  echo "the harness reads the deployment's own durable settings" >&2
  exit 2
fi

if (( ${#channel_ref} < 1 || ${#channel_ref} > 256 )) ||
  [[ ! $channel_ref =~ ^[A-Za-z0-9._:-]+$ ]]; then
  echo "live acceptance Slack channel reference is invalid" >&2
  exit 2
fi

if [[ ! $timeout_seconds =~ ^[0-9]+$ ]] || ((timeout_seconds < 1 || timeout_seconds > 1800)); then
  echo "RYKER_LIVE_TIMEOUT_SECONDS must be between 1 and 1800" >&2
  exit 2
fi

if [[ ! -x $release ]]; then
  echo "installed Elixir release is unavailable at $release" >&2
  exit 1
fi

RYKER_LIVE_CHANNEL=$channel_ref \
RYKER_LIVE_TIMEOUT_SECONDS=$timeout_seconds \
  "$release" eval 'Ryker.Acceptance.Live.run_from_env!()'
