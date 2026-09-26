#!/usr/bin/env bash
# The live lane must run inside the deployed container with exactly the
# channel and timeout it was given, and refuse to run at all without an
# installation or with a channel reference it cannot vouch for.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

state="$work/state"
mkdir -p "$state" "$work/bin"
printf 'RYKER_VERSION=1.2.3\nRYKER_CONTROL_PORT=4321\n' >"$state/compose.env"

# A fake Docker that only answers the one exec the wrapper is allowed to run.
# These literals are its source and expand when it runs.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  "expected=\"compose --env-file $state/compose.env exec -T --env RYKER_LIVE_CHANNEL=C0BLU1GACKC --env RYKER_LIVE_TIMEOUT_SECONDS=600 ryker /opt/ryker/bin/ryker eval Ryker.Acceptance.Live.run_from_env!()\"" \
  '[[ $* == "$expected" ]] || { echo "unexpected docker call: $*" >&2; exit 7; }' \
  'printf "%s\\n" live-acceptance-exec-ok' >"$work/bin/docker"
chmod 0700 "$work/bin/docker"

set +e
output=$(PATH="$work/bin:$PATH" RYKER_INSTALL_STATE="$state" \
  "$root/scripts/elixir-live-acceptance.sh" C0BLU1GACKC 2>&1)
status=$?
set -e

if [[ $status -ne 0 ]] || [[ $output != *"live-acceptance-exec-ok"* ]]; then
  echo "live acceptance must run inside the deployed container with the exact channel and timeout" >&2
  echo "$output" >&2
  exit 1
fi

set +e
output=$(PATH="$work/bin:$PATH" RYKER_INSTALL_STATE="$work/nowhere" \
  "$root/scripts/elixir-live-acceptance.sh" C0BLU1GACKC 2>&1)
status=$?
set -e

if [[ $status -ne 1 ]] || [[ $output != *"not installed here"* ]]; then
  echo "live acceptance must refuse a checkout with no installation" >&2
  echo "$output" >&2
  exit 1
fi

set +e
output=$(PATH="$work/bin:$PATH" RYKER_INSTALL_STATE="$state" \
  "$root/scripts/elixir-live-acceptance.sh" invalid/channel 2>&1)
status=$?
set -e

if [[ $status -ne 2 ]] || [[ $output != *"live acceptance Slack channel reference is invalid"* ]]; then
  echo "invalid Slack channel IDs must fail wrapper validation" >&2
  echo "$output" >&2
  exit 1
fi

echo "live acceptance wrapper check passed"
