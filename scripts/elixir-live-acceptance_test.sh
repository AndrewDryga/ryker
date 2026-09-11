#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

set +e
output=$(RESPONDER_ELIXIR_RELEASE="$work/missing-release" \
  "$root/scripts/elixir-live-acceptance.sh" C0BLU1GACKC 2>&1)
status=$?
set -e

if [[ $status -ne 1 ]] || [[ $output != *"installed Elixir release is unavailable"* ]]; then
  echo "valid Slack channel IDs must pass wrapper validation" >&2
  echo "$output" >&2
  exit 1
fi

set +e
output=$(RESPONDER_ELIXIR_RELEASE="$work/missing-release" \
  "$root/scripts/elixir-live-acceptance.sh" invalid/channel 2>&1)
status=$?
set -e

if [[ $status -ne 2 ]] || [[ $output != *"live acceptance Slack channel reference is invalid"* ]]; then
  echo "invalid Slack channel IDs must fail wrapper validation" >&2
  echo "$output" >&2
  exit 1
fi
