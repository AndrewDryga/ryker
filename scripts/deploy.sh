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

deployed=0
for plist in "$agents"/ai.emisar.responder.*.plist; do
  [[ -e $plist ]] || continue
  label=$(basename "$plist" .plist)
  # The quality watcher runs a script rather than the server binary, so it has no pin to move.
  grep -q "libexec/responder/responder-" "$plist" || continue
  /usr/bin/sed -i '' -E "s#libexec/responder/responder-[0-9a-f]+#libexec/responder/responder-$sha#g" "$plist"
  launchctl kickstart -k "$domain/$label"
  echo "deploy: restarted $label on responder-$sha"
  deployed=$((deployed + 1))
done

if [[ $deployed -eq 0 ]]; then
  echo "deploy: no launch agent pins a Responder binary — nothing was deployed" >&2
  exit 1
fi

# Report what is actually running, not what was asked for: this script exists because those two
# drifted apart once already.
sleep 2
echo "deploy: running processes"
pgrep -af "libexec/responder/responder-" | sed 's/^/  /' || {
  echo "deploy: no Responder process is running after restart" >&2
  exit 1
}
