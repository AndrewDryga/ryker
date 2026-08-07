#!/usr/bin/env bash
# Deploy the current commit to the supervised Responder launch agents.
#
# Each agent pins an exact binary by commit — `responder-<sha>` under libexec — so building or
# `make install`ing anywhere else changes nothing they run. That gap is not theoretical: it is how
# a green gate came to sit next to a Slack failure produced by older code. Deploying therefore
# means all three of: build the binary for this commit, repoint every agent at it, restart them.
#
# Coop rides along. Every deployment sets `coop.supervise: true` with the binary at a stable path,
# so restarting Responder restarts Coop; run `make install` in the Coop checkout first when the
# change spans both repositories.
set -euo pipefail

# --stage builds and prepares everything a deploy would use — the immutable
# commit-named binary and a .staged plist beside each live one — without
# repointing or restarting anything. It is the automatic-preparation half of
# self-deployment: a machine may stage endlessly, and rotating onto a staged
# candidate stays a separate, deliberate act. Activation is this same script
# without --stage, which rebuilds nothing (the binary is content-addressed by
# commit) and performs only the pointer move and restart.
stage=0
if [[ ${1:-} == "--stage" ]]; then
  stage=1
  shift
fi
if [[ $# -gt 0 ]]; then
  echo "deploy: unknown argument $1 (only --stage is accepted)" >&2
  exit 2
fi

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
libexec=${RESPONDER_LIBEXEC:-$HOME/.local/libexec/responder}
agents=${RESPONDER_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}
domain="gui/$(id -u)"

cd "$repository"

# A binary is named for a commit, so a name that does not describe what is running is worse than
# no name at all. Refuse rather than deploy something unidentifiable.
if [[ -n $(git status --porcelain) ]]; then
  echo "deploy: refusing to deploy a dirty tree — commit first" >&2
  exit 1
fi

sha=$(git rev-parse --short HEAD)
version=$(git describe --tags --always 2>/dev/null || echo "$sha")
binary="$libexec/responder-$sha"

mkdir -p "$libexec"
go build -trimpath \
  -ldflags "-s -w -X github.com/AndrewDryga/responder/internal/version.Version=$version" \
  -o "$binary" ./cmd/responder
echo "deploy: built $binary ($version)"

if [[ $stage -eq 1 ]]; then
  staged=0
  for plist in "$agents"/ai.emisar.responder.*.plist; do
    [[ -e $plist ]] || continue
    grep -q "libexec/responder/responder-" "$plist" || continue
    /usr/bin/sed -E "s#libexec/responder/responder-[0-9a-f]+#libexec/responder/responder-$sha#g" \
      "$plist" > "$plist.staged-$sha"
    echo "deploy: staged $(basename "$plist").staged-$sha"
    staged=$((staged + 1))
  done
  if [[ $staged -eq 0 ]]; then
    echo "deploy: no launch agent pins a Responder binary — nothing was staged" >&2
    exit 1
  fi
  echo "deploy: staged responder-$sha for $staged agent(s); nothing was rotated or restarted"
  echo "deploy: activate with scripts/deploy.sh at this commit"
  exit 0
fi

deployed=0
for plist in "$agents"/ai.emisar.responder.*.plist; do
  [[ -e $plist ]] || continue
  label=$(basename "$plist" .plist)
  # The quality watcher runs a script rather than the server binary, so it has no pin to move.
  grep -q "libexec/responder/responder-" "$plist" || continue
  /usr/bin/sed -i '' -E "s#libexec/responder/responder-[0-9a-f]+#libexec/responder/responder-$sha#g" "$plist"
  # bootout + bootstrap, not `kickstart -k`: kickstart restarts the definition launchd already
  # has in memory, so editing the plist on disk and kickstarting relaunches the OLD binary and
  # reports success. The job has to be unloaded for the new ProgramArguments to be read.
  #
  # bootout returns before the job is gone, and bootstrapping a label that is still present fails
  # with a bare "Input/output error" — which, mid-loop under set -e, leaves the service down and
  # the remaining agents untouched. Wait for it to actually leave the domain.
  launchctl bootout "$domain/$label" 2>/dev/null || true
  for _ in $(seq 1 40); do
    launchctl print "$domain/$label" >/dev/null 2>&1 || break
    sleep 0.25
  done
  if ! launchctl bootstrap "$domain" "$plist"; then
    echo "deploy: $label is BOOTED OUT and failed to bootstrap — it is down" >&2
    exit 1
  fi
  echo "deploy: reloaded $label on responder-$sha"
  deployed=$((deployed + 1))
done

if [[ $deployed -eq 0 ]]; then
  echo "deploy: no launch agent pins a Responder binary — nothing was deployed" >&2
  exit 1
fi

# Assert what is actually running, not what was asked for. This script exists because those two
# drifted apart once already, and a check that only proves "something restarted" would have
# reported that drift as a success.
sleep 3
# `pgrep -c` is Linux-only; count the matched pids instead so this works on macOS too.
total=$(pgrep -f "libexec/responder/responder-" | wc -l | tr -d ' ')
current=$(pgrep -f "libexec/responder/responder-$sha " | wc -l | tr -d ' ')
if [[ ${total:-0} -eq 0 ]]; then
  echo "deploy: no Responder process is running after reload" >&2
  exit 1
fi
if [[ ${current:-0} -ne ${total:-0} ]]; then
  echo "deploy: only $current of $total Responder processes are on responder-$sha" >&2
  pgrep -lf "libexec/responder/responder-" >&2 || true
  exit 1
fi
echo "deploy: $current process(es) running responder-$sha"
