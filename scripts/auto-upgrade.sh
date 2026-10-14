#!/bin/bash
# The install's own half of an upgrade: moves this checkout's install to the
# commit a branch on origin names, whenever that branch moves, so nobody needs
# a shell on its host. RYKER_UPGRADE_REF in compose.env names the branch, for
# example tenant/blitz, and moving it is the upgrade:
#
#   git push origin main:tenant/blitz
#
# On 2026-10-14 each upgrade of the tenant install went through Tailscale SSH:
# a profile switch on this Mac, a check approval only Andrew could give, step
# scripts outside the repository, and an exit status of 0 even when the remote
# command failed. A launch agent runs this every five minutes instead
# (scripts/install-auto-upgrade.sh).
#
# It only moves forward: a branch that does not build on what runs is refused.
# It backs up, upgrades with scripts/compose.sh (which pins the release and
# keeps the worker), and moves the worker when the commit pins another Coop.
# A failed upgrade restores the backup it took and puts the checkout back, and
# that commit is not tried again; the next move of the branch is. Each attempt
# is a line in ~/.local/state/ryker-upgrade/upgrades.log.
set -uo pipefail

repository=$(cd "$(dirname "$0")/.." && pwd)
cd "$repository" || exit 1
state_dir=${RYKER_INSTALL_STATE:-$repository/.ryker}
env_file=$state_dir/compose.env
upgrade_state=${RYKER_UPGRADE_STATE:-$HOME/.local/state/ryker-upgrade}
# shellcheck source=scripts/compose-lifecycle.sh
. "$repository/scripts/compose-lifecycle.sh"
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin"

ref=$(compose_env_value RYKER_UPGRADE_REF "$env_file")
[[ -n $ref ]] || exit 0
mkdir -p "$upgrade_state"

record() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" | tee -a "$upgrade_state/upgrades.log"
}

coop_pin() { sed -n 's/^ARG COOP_REVISION=//p' deploy/compose/coop/Dockerfile 2>/dev/null; }

if ! git fetch --quiet origin "$ref"; then
  record "could not fetch origin's $ref"
  exit 1
fi
target=$(git rev-parse FETCH_HEAD)
current=$(git rev-parse HEAD)

[[ $target != "$current" ]] || exit 0
if [[ $(cat "$upgrade_state/failed" 2>/dev/null) == "$target" ]]; then
  exit 0
fi
if ! git merge-base --is-ancestor "$current" "$target"; then
  record "refused ${target:0:12}: origin's $ref does not build on ${current:0:12}, which runs"
  echo "$target" >"$upgrade_state/failed"
  exit 1
fi
if [[ -n $(git status --porcelain) ]]; then
  record "refused ${target:0:12}: this checkout has uncommitted changes"
  exit 1
fi

record "upgrading ${current:0:12} -> ${target:0:12}"
pin_before=$(coop_pin)
if ! scripts/compose.sh backup </dev/null; then
  record "FAILED ${target:0:12}: the backup before it did not complete; nothing changed"
  echo "$target" >"$upgrade_state/failed"
  exit 1
fi
# shellcheck disable=SC2012 # backups are named by their time, nothing else
backup=$(ls -t "$state_dir"/backups/*.tar.gz | head -n 1)
git merge --ff-only --quiet "$target"

failed=
if ! scripts/compose.sh upgrade </dev/null; then
  failed="the upgrade"
elif [[ $(coop_pin) != "$pin_before" ]] && ! scripts/compose.sh worker-upgrade </dev/null; then
  failed="the worker upgrade"
fi

if [[ -z $failed ]]; then
  rm -f "$upgrade_state/failed"
  record "upgraded ${current:0:12} -> ${target:0:12}"
  exit 0
fi

echo "$target" >"$upgrade_state/failed"
git reset --quiet --hard "$current"
if scripts/compose.sh restore "$backup" </dev/null; then
  record "FAILED ${target:0:12}: $failed failed; restored ${current:0:12} from $(basename "$backup")"
else
  record "FAILED ${target:0:12}: $failed failed, and so did restoring $(basename "$backup"); the install needs a person"
fi
exit 1
