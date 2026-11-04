#!/bin/bash
# The install's own half of an upgrade: moves this checkout's install to the
# commit a branch on origin names, whenever that branch moves, so nobody needs
# a shell on its host. RYKER_UPGRADE_REF in compose.env names the branch, main
# on the tenant install, and a push to it is the upgrade.
#
# On 2026-10-14 each upgrade of the tenant install went through Tailscale SSH:
# a profile switch on this Mac, a check approval only Andrew could give, step
# scripts outside the repository, and an exit status of 0 even when the remote
# command failed. A launch agent runs this every five minutes instead
# (scripts/install-auto-upgrade.sh).
#
# It only moves forward: a branch that does not build on what runs is refused.
# It deploys with scripts/deploy.sh, then moves the worker when the commit
# pins another Coop. It takes no automatic backup and never restores data
# automatically. A failed upgrade keeps the previous pin; a stopped release
# needs a fixed release or an explicit manual restore. A
# commit whose upgrade failed before anything changed is tried again half an
# hour later; one that stopped the release is not, and the next move of the
# branch is. A worker that did not move is asked again every half hour until it
# has. Each attempt is a line in ~/.local/state/ryker-upgrade/upgrades.log.
set -uo pipefail

repository=$(cd "$(dirname "$0")/.." && pwd)
cd "$repository" || exit 1
state_dir=${RYKER_INSTALL_STATE:-$repository/.ryker}
env_file=$state_dir/compose.env
upgrade_state=${RYKER_UPGRADE_STATE:-$HOME/.local/state/ryker-upgrade}
# A worker that did not move to the Coop its commit pins, and a commit whose
# upgrade failed before anything changed, are tried again this long after they
# last were, between pushes. The tenant install's download of Coop broke off
# after 397 s on 2026-10-17, and later that day its upgrade stopped when Docker
# Hub's TLS handshake timed out; each kept what it ran until the next push.
retry_seconds=${RYKER_UPGRADE_RETRY_SECONDS:-1800}
# shellcheck source=scripts/compose-lifecycle.sh
. "$repository/scripts/compose-lifecycle.sh"
# launchd starts it with a bare PATH; the tenant host's Docker is Homebrew's.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ref=$(compose_env_value RYKER_UPGRADE_REF "$env_file")
[[ -n $ref ]] || exit 0
mkdir -p "$upgrade_state"

record() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" | tee -a "$upgrade_state/upgrades.log"
}

# The daily backup or a person's restore holds the lifecycle lock; the next
# round, five minutes on, tries again rather than calling the commit failed.
busy() {
  local holder
  holder=$(cat "$state_dir/lifecycle.lock/owner" 2>/dev/null)
  [[ -n $holder ]] && kill -0 "${holder%% *}" 2>/dev/null
}

# worker-behind holds when a worker last failed to move; it goes once one has.
worker_behind=$upgrade_state/worker-behind
upgrade_workers() {
  scripts/compose.sh worker-upgrade </dev/null || return 1
  if [[ -f $state_dir/worker-pool/state.json ]]; then
    python3 -B scripts/worker_pool.py upgrade --state-dir "$state_dir" </dev/null || return 1
  fi
}

retry_worker_upgrade() {
  local last
  last=$(cat "$worker_behind" 2>/dev/null) || return 0
  (($(date +%s) - ${last:-0} >= retry_seconds)) || return 0
  busy && return 0
  if upgrade_workers; then
    rm -f "$worker_behind"
    record "the worker moved to the Coop ${current:0:12} pins"
  else
    date +%s >"$worker_behind"
    record "the worker upgrade failed again; the worker runs the Coop it ran"
    return 1
  fi
}

if ! git fetch --quiet origin "$ref"; then
  record "could not fetch origin's $ref"
  exit 1
fi
target=$(git rev-parse FETCH_HEAD)
current=$(git rev-parse HEAD)

if [[ $target == "$current" ]]; then
  retry_worker_upgrade
  exit
fi
# The failed marker names a commit, and when its upgrade failed with nothing
# changed, the time it did: that one is tried again once retry_seconds have
# passed since.
if read -r failed failed_at <"$upgrade_state/failed" 2>/dev/null && [[ $failed == "$target" ]]; then
  [[ -n $failed_at ]] && (($(date +%s) - failed_at >= retry_seconds)) || exit 0
fi
busy && exit 0
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
previous_version=$(compose_env_value RYKER_VERSION "$env_file")
previous_image=$(compose_env_value RYKER_IMAGE "$env_file")
git merge --ff-only --quiet "$target"

# The configured ref already authorizes this forward-only target, including
# installs checked out on a tenant branch instead of local main.
if ! scripts/deploy.sh --allow-not-main </dev/null; then
  echo "$target" >"$upgrade_state/failed"
  # An upgrade that failed before it replaced Ryker (an image that did not
  # build) left the release before it serving and the database untouched:
  # only the pin goes back; no database restore runs.
  control_port=$(compose_env_value RYKER_CONTROL_PORT "$env_file")
  probe_console "$(control_origin "$(compose_env_value RYKER_CONTROL_BIND "$env_file")" "${control_port:-4321}")"
  pinned_version=$(compose_env_value RYKER_VERSION "$env_file")
  # Deploy keeps a verified release running when its later live acceptance
  # fails. Keep matching source too, and leave worker movement retryable.
  if [[ $readyz_code == 200 && $running_version == "$pinned_version" && $pinned_version != "$previous_version" ]]; then
    date +%s >"$worker_behind"
    record "FAILED ${target:0:12}: $running_version is running, but deployment checks failed; source and pin kept"
    exit 1
  elif [[ $readyz_code == 200 && $running_version == "$previous_version" ]]; then
    pin_release "$previous_version" "$previous_image"
    echo "$target $(date +%s)" >"$upgrade_state/failed"
    record "FAILED ${target:0:12}: the upgrade failed before it replaced $previous_version, which still runs"
  else
    record "FAILED ${target:0:12}: the release is not ready; deploy a fixed release or restore a manual backup"
  fi
  # Moving source back does not undo migrations or replace worker custody.
  git reset --quiet --hard "$current"
  exit 1
fi

# Ryker runs the new release; the worker moves to the Coop it pins, and does
# nothing when it runs that one already. One that did not move keeps the Coop
# it ran and is moved by the next upgrade: asked only when the pin changed, a
# worker busy at that moment stayed behind until the pin changed again
# (2026-10-16).
if ! upgrade_workers; then
  date +%s >"$worker_behind"
  record "upgraded ${current:0:12} -> ${target:0:12}, but the worker upgrade failed; the worker runs the Coop it ran"
  exit 1
fi
rm -f "$upgrade_state/failed" "$worker_behind"
record "upgraded ${current:0:12} -> ${target:0:12}"
