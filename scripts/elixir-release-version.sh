#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if ! git -C "$root" diff --quiet --ignore-submodules -- ||
  ! git -C "$root" diff --cached --quiet --ignore-submodules -- ||
  [[ -n $(git -C "$root" ls-files --others --exclude-standard) ]]; then
  echo "Elixir release identity requires a clean committed tree" >&2
  exit 1
fi

commit=$(git -C "$root" rev-parse HEAD)

if [[ ! $commit =~ ^[0-9a-f]{40,64}$ ]]; then
  echo "could not derive an immutable Git commit for the Elixir release" >&2
  exit 1
fi

tag=$(git -C "$root" describe --exact-match --tags --match 'v[0-9]*' HEAD 2>/dev/null || true)

if [[ $tag =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]] &&
  [[ $(git -C "$root" cat-file -t "$tag") == tag ]]; then
  printf '%s\n' "${tag#v}"
  exit 0
fi

printf '0.1.0-g%s\n' "$commit"
