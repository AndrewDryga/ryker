#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/state"
printf 'RYKER_VERSION=test\n' >"$scratch/state/compose.env"
cat >"$scratch/bin/docker" <<'FAKE'
#!/bin/sh
printf '%s\n' "$@" >"$FLYWHEEL_TEST_CALLS"
cat >"$FLYWHEEL_TEST_INPUT"
FAKE
chmod +x "$scratch/bin/docker"
export PATH="$scratch/bin:$PATH" RYKER_INSTALL_STATE="$scratch/state"
export FLYWHEEL_TEST_CALLS="$scratch/calls" FLYWHEEL_TEST_INPUT="$scratch/input"
# Literal shell syntax must survive the transport as data.
# shellcheck disable=SC2016
printf '%s' '{"action":"report","text":"$(touch /tmp/never) `echo never`"}' >"$scratch/request"
"$root/scripts/flywheel.sh" "$scratch/request"
cmp "$scratch/request" "$scratch/input"
grep -Fxq 'Ryker.Release.flywheel()' "$scratch/calls"
"$root/scripts/flywheel.sh" - <"$scratch/request"
cmp "$scratch/request" "$scratch/input"
if RYKER_INSTALL_STATE="$scratch/missing" "$root/scripts/flywheel.sh" - <"$scratch/request" 2>/dev/null; then
  echo 'an uninstalled target must fail' >&2
  exit 1
fi
python3 -B "$root/.agent/skills/flywheel/scripts/tasks_test.py"
python3 -B "$root/.agent/skills/flywheel/scripts/collect_test.py"
echo 'flywheel transport and task reconciliation passed'
