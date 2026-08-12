#!/usr/bin/env bash
# Prove one exact commit and its exact binary once, then safely reuse that proof.
set -euo pipefail

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
proofs=${RESPONDER_CANDIDATE_PROOFS:-$HOME/.local/state/responder/candidate-proofs}
libexec=${RESPONDER_LIBEXEC:-$HOME/.local/libexec/responder}
max_age=${RESPONDER_CANDIDATE_MAX_AGE:-86400}
schema=1
case "$max_age" in
  ''|*[!0-9]*) echo "candidate: RESPONDER_CANDIDATE_MAX_AGE must be a non-negative integer" >&2; exit 2 ;;
esac
mode=check
[[ ${1:-} == "--verify-only" ]] && { mode=verify; shift; }
if [[ $# -gt 0 ]]; then
  echo "candidate: unknown argument $1 (only --verify-only is accepted)" >&2
  exit 2
fi

cd "$repository"
[[ -z $(git status --porcelain) ]] || { echo "candidate: refusing a dirty tree" >&2; exit 1; }

full_sha=$(git rev-parse HEAD)
short_sha=$(git rev-parse --short HEAD)
proof="$proofs/$full_sha.json"
binary="$libexec/responder-$short_sha"
lock="$proof.lock"
toolchain=$(go version)
platform="$(go env GOOS)/$(go env GOARCH)/cgo=$(go env CGO_ENABLED)"

artifact_hash() { shasum -a 256 "$binary" | awk '{ print $1 }'; }
proof_valid() {
  [[ -f $proof && -x $binary ]] || return 1
  local now created expected actual
  now=$(date +%s)
  created=$(jq -er '.created_unix' "$proof") || return 1
  (( created <= now && now - created <= max_age )) || return 1
  jq -e \
    --argjson schema "$schema" \
    --arg commit "$full_sha" \
    --arg binary "$binary" \
    --arg toolchain "$toolchain" \
    --arg platform "$platform" \
    '.schema == $schema and .commit == $commit and .binary == $binary and
     .toolchain == $toolchain and .platform == $platform' "$proof" >/dev/null || return 1
  expected=$(jq -er '.sha256' "$proof") || return 1
  actual=$(artifact_hash)
  [[ $expected == "$actual" ]]
}

if proof_valid; then
  echo "candidate: reusing exact-commit proof for $short_sha"
  exit 0
fi
[[ $mode == verify ]] && exit 1

mkdir -p "$proofs"
waiting=0
while ! mkdir "$lock" 2>/dev/null; do
  if [[ -f $lock/pid ]]; then
    owner=$(cat "$lock/pid" 2>/dev/null || true)
    if [[ $owner =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
      rm -rf "$lock"
      continue
    fi
  fi
  if [[ $waiting -eq 0 ]]; then
    echo "candidate: another process is proving $short_sha; waiting for its reusable result"
    waiting=1
  fi
  sleep 1
done
printf '%s\n' "$$" >"$lock/pid"
trap 'rm -rf "$lock"' EXIT

# Another process may have completed while this one waited for the lock.
if proof_valid; then
  echo "candidate: reusing exact-commit proof for $short_sha"
  exit 0
fi

echo "candidate: proving exact commit $short_sha"
make check
scripts/deploy.sh --stage

hash=$(artifact_hash)
now=$(date +%s)
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp="$proof.tmp.$$"
jq -n \
  --argjson schema "$schema" \
  --arg commit "$full_sha" \
  --arg binary "$binary" \
  --arg sha256 "$hash" \
  --arg toolchain "$toolchain" \
  --arg platform "$platform" \
  --arg created_at "$created" \
  --argjson created_unix "$now" \
  '{schema:$schema, commit:$commit, binary:$binary, sha256:$sha256,
    toolchain:$toolchain, platform:$platform, created_at:$created_at,
    created_unix:$created_unix}' >"$tmp"
chmod 600 "$tmp"
mv "$tmp" "$proof"
echo "candidate: recorded $proof"
