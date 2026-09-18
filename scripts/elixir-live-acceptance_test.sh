#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

runtime_env="$work/runtime.env"
release="$work/ryker"

printf '%s\n' \
  'DATABASE_URL=ecto://ryker:acceptance@127.0.0.1/ryker' \
  'SLACK_BOT_TOKEN=xoxb-acceptance' >"$runtime_env"
# These literals are the source of the fake release and expand when that release runs.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '[[ ${DATABASE_URL:-} == ecto://ryker:acceptance@127.0.0.1/ryker ]] || exit 7' \
  '[[ ${SLACK_BOT_TOKEN:-} == xoxb-acceptance ]] || exit 7' \
  '[[ ${RYKER_LIVE_CHANNEL:-} == C0BLU1GACKC ]] || exit 7' \
  '[[ ${RYKER_LIVE_TIMEOUT_SECONDS:-} == 600 ]] || exit 7' \
  '[[ $1 == eval ]] || exit 7' \
  'printf "%s\\n" live-acceptance-env-ok' >"$release"
chmod 0700 "$release"

set +e
output=$(DATABASE_URL=wrong SLACK_BOT_TOKEN=wrong \
  RYKER_RUNTIME_ENV="$runtime_env" RYKER_ELIXIR_RELEASE="$release" \
  "$root/scripts/elixir-live-acceptance.sh" C0BLU1GACKC 2>&1)
status=$?
set -e

if [[ $status -ne 0 ]] || [[ $output != *"live-acceptance-env-ok"* ]]; then
  echo "live acceptance must use the deployment runtime environment" >&2
  echo "$output" >&2
  exit 1
fi

set +e
output=$(RYKER_ELIXIR_RELEASE="$work/missing-release" \
  "$root/scripts/elixir-live-acceptance.sh" C0BLU1GACKC 2>&1)
status=$?
set -e

if [[ $status -ne 1 ]] || [[ $output != *"installed Elixir release is unavailable"* ]]; then
  echo "valid Slack channel IDs must pass wrapper validation" >&2
  echo "$output" >&2
  exit 1
fi

set +e
output=$(RYKER_ELIXIR_RELEASE="$work/missing-release" \
  "$root/scripts/elixir-live-acceptance.sh" invalid/channel 2>&1)
status=$?
set -e

if [[ $status -ne 2 ]] || [[ $output != *"live acceptance Slack channel reference is invalid"* ]]; then
  echo "invalid Slack channel IDs must fail wrapper validation" >&2
  echo "$output" >&2
  exit 1
fi
