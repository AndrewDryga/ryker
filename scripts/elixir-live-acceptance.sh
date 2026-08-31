#!/usr/bin/env bash
set -euo pipefail

configuration=${1:-}
channel_ref=${2:-}
release=${RESPONDER_ELIXIR_RELEASE:-"$HOME/.local/libexec/responder/current/bin/responder"}
timeout_seconds=${RESPONDER_LIVE_TIMEOUT_SECONDS:-600}

if [[ -z $configuration || -z $channel_ref || ! -f $configuration ]]; then
  echo "usage: scripts/elixir-live-acceptance.sh /absolute/responder.yaml SLACK_TEST_CHANNEL" >&2
  exit 2
fi

if [[ $configuration != /* ]]; then
  echo "live acceptance configuration must be an absolute path" >&2
  exit 2
fi

if [[ ! $channel_ref =~ ^[A-Za-z0-9._:-]{1,256}$ ]]; then
  echo "live acceptance Slack channel reference is invalid" >&2
  exit 2
fi

if [[ ! $timeout_seconds =~ ^[0-9]+$ ]] || ((timeout_seconds < 1 || timeout_seconds > 1800)); then
  echo "RESPONDER_LIVE_TIMEOUT_SECONDS must be between 1 and 1800" >&2
  exit 2
fi

if [[ ! -x $release ]]; then
  echo "installed Elixir release is unavailable at $release" >&2
  exit 1
fi

RESPONDER_LIVE_CONFIG=$configuration \
RESPONDER_LIVE_CHANNEL=$channel_ref \
RESPONDER_LIVE_TIMEOUT_SECONDS=$timeout_seconds \
  "$release" eval 'Responder.Acceptance.Live.run_from_env!()'
