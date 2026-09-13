#!/usr/bin/env bash
set -euo pipefail

archive=${1:-}
expected_version=${2:-}
expected_sha256=${3:-}
mode=${4:-}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ -z $archive || -z $expected_version || -z $expected_sha256 || ! -f $archive ]]; then
  echo "usage: scripts/check-elixir-release.sh ARCHIVE VERSION TRUSTED_SHA256 [--archive-only]" >&2
  exit 2
fi

if [[ -n $mode && $mode != --archive-only ]]; then
  echo "unknown release check mode: $mode" >&2
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
migration="$scratch/lib/ryker-$expected_version/priv/repo/migrations/20260830000100_finalize_elixir_product_schema.exs"

[[ -x $binary ]] || { echo "release is missing executable bin/ryker" >&2; exit 1; }
[[ -f $migration ]] || { echo "release is missing the product migration" >&2; exit 1; }
[[ -f $scratch/releases/$expected_version/runtime.exs ]] || {
  echo "release is missing runtime configuration" >&2
  exit 1
}

for asset in \
  README.md \
  deploy/nginx/ryker.conf \
  deploy/systemd/ryker.service \
  deploy/systemd/ryker.env.example \
  docs/elixir-ingress-admission.md \
  docs/operations.md \
  docs/releasing.md; do
  if [[ ! -f $scratch/share/ryker/$asset ]]; then
    echo "release is missing operator asset share/ryker/$asset" >&2
    exit 1
  fi
done

if find "$scratch/lib" -maxdepth 1 -type d \( -name 'credo-*' -o -name 'jsv-*' \) | grep -q .; then
  echo "release contains development or test dependencies" >&2
  exit 1
fi

[[ $($binary version) == "ryker $expected_version" ]] || {
  echo "release version does not match $expected_version" >&2
  exit 1
}

DATABASE_URL=ecto://release-check:release-check@127.0.0.1/ryker_release_check \
  $binary eval \
  'if Code.ensure_loaded?(Ryker.Release), do: System.halt(0), else: System.halt(1)'

if [[ $mode != --archive-only ]]; then
  install_prefix="$scratch/install-root"

  "$script_dir/install-elixir-release.sh" \
    "$verified_archive" "$expected_version" "$expected_sha256" "$install_prefix" \
    --local-build >/dev/null

  [[ -L $install_prefix/current ]] || {
    echo "release installer did not create the current pointer" >&2
    exit 1
  }

  [[ $(readlink "$install_prefix/current") == "releases/$expected_version" ]] || {
    echo "release installer selected the wrong version" >&2
    exit 1
  }

  [[ $("$install_prefix"/current/bin/ryker version) == "ryker $expected_version" ]] || {
    echo "installed release does not execute through current" >&2
    exit 1
  }

  "$script_dir/install-elixir-release.sh" \
    "$verified_archive" "$expected_version" "$expected_sha256" "$install_prefix" \
    --local-build >/dev/null

  if "$script_dir/activate-elixir-release.sh" "$install_prefix" missing-version >/dev/null 2>&1; then
    echo "release activator selected a missing version" >&2
    exit 1
  fi

  [[ $(readlink "$install_prefix/current") == "releases/$expected_version" ]] || {
    echo "failed activation changed the current release" >&2
    exit 1
  }

  "$script_dir/activate-elixir-release.sh" \
    "$install_prefix" "$expected_version" >/dev/null

  if "$script_dir/install-elixir-release.sh" \
    "$verified_archive" "$expected_version" "$expected_sha256" relative/prefix \
    --local-build >/dev/null 2>&1; then
    echo "release installer accepted a relative prefix" >&2
    exit 1
  fi
fi

echo "Elixir release $expected_version is self-contained and migration-capable"
