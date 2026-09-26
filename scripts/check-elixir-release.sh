#!/usr/bin/env bash
# Structural check of one Elixir release archive. The bytes must match the
# trusted digest before anything is listed or extracted; every path must be
# safe; the release must carry its executable, its runtime configuration,
# every migration in this tree and every operator asset in release-assets.txt,
# no development dependency, the expected version, and it must boot its
# migration entry point.
set -euo pipefail

archive=${1:-}
expected_version=${2:-}
expected_sha256=${3:-}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
manifest="$root/release-assets.txt"

if [[ $# -ne 3 || -z $archive || -z $expected_version || -z $expected_sha256 || ! -f $archive ]]; then
  echo "usage: scripts/check-elixir-release.sh ARCHIVE VERSION TRUSTED_SHA256" >&2
  exit 2
fi

if [[ ! $expected_version =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  echo "release version is not a safe path component" >&2
  exit 2
fi

if [[ ! $expected_sha256 =~ ^[0-9a-f]{64}$ ]]; then
  echo "trusted archive SHA-256 must be 64 lowercase hexadecimal characters" >&2
  exit 2
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/ryker-elixir-release.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

verified_archive="$scratch/archive.tar.gz"
install -m 0600 "$archive" "$verified_archive"

archive_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

if [[ $(archive_sha256 "$verified_archive") != "$expected_sha256" ]]; then
  echo "archive SHA-256 does not match trusted digest" >&2
  exit 1
fi

if ! tar -tzf "$verified_archive" | awk '
  BEGIN { count = 0 }
  {
    count++
    if ($0 == "" || $0 ~ /^\// || $0 ~ /(^|\/)\.\.(\/|$)/) unsafe = 1
  }
  END { exit unsafe || count == 0 }
'; then
  echo "release archive contains an unsafe path" >&2
  exit 1
fi

if ! tar -tvzf "$verified_archive" | awk '
  {
    kind = substr($1, 1, 1)
    if (kind != "-" && kind != "d") unsafe = 1
  }
  END { exit unsafe }
'; then
  echo "release archive contains a link or special file" >&2
  exit 1
fi

tar -xzf "$verified_archive" -C "$scratch"

binary="$scratch/bin/ryker"
[[ -x $binary ]] || { echo "release is missing executable bin/ryker" >&2; exit 1; }
[[ -f $scratch/releases/$expected_version/runtime.exs ]] || {
  echo "release is missing runtime configuration" >&2
  exit 1
}

# Every migration this tree carries must be in the release, or the container
# boots an older schema than the code expects.
for migration in "$root"/priv/repo/migrations/*.exs; do
  name=${migration##*/}
  if [[ ! -f $scratch/lib/ryker-$expected_version/priv/repo/migrations/$name ]]; then
    echo "release is missing migration $name" >&2
    exit 1
  fi
done

while IFS= read -r asset; do
  [[ -z $asset || $asset == \#* ]] && continue
  if [[ ! -f $scratch/share/ryker/$asset ]]; then
    echo "release is missing operator asset share/ryker/$asset" >&2
    exit 1
  fi
done <"$manifest"

if find "$scratch/lib" -maxdepth 1 -type d \( -name 'credo-*' -o -name 'jsv-*' \) | grep -q .; then
  echo "release contains development or test dependencies" >&2
  exit 1
fi

[[ $($binary version) == "ryker $expected_version" ]] || {
  echo "release version does not match $expected_version" >&2
  exit 1
}

DATABASE_URL=ecto://release-check:release-check@127.0.0.1/ryker_release_check \
  RYKER_CREDENTIAL_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= \
  $binary eval \
  'if Code.ensure_loaded?(Ryker.Release), do: System.halt(0), else: System.halt(1)'

echo "Elixir release $expected_version is self-contained and migration-capable"
