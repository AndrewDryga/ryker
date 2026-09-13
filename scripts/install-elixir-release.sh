#!/usr/bin/env bash
set -euo pipefail

archive=${1:-}
expected_version=${2:-}
third=${3:-}
fourth=${4:-}
fifth=${5:-}
sixth=${6:-}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  cat >&2 <<'EOF'
usage:
  scripts/install-elixir-release.sh ARCHIVE VERSION CHECKSUMS BUNDLE TAG ABSOLUTE_PREFIX
  scripts/install-elixir-release.sh ARCHIVE VERSION SHA256 ABSOLUTE_PREFIX --local-build
EOF
  exit 2
}

if [[ -z $archive || -z $expected_version || ! -f $archive ]]; then
  usage
fi

if [[ $fifth == --local-build && -z $sixth ]]; then
  expected_archive_sha256=$third
  prefix=$fourth
elif [[ -n $third && -n $fourth && -n $fifth && -n $sixth ]]; then
  checksums=$third
  bundle=$fourth
  tag=$fifth
  prefix=$sixth

  [[ -f $checksums && -f $bundle ]] || usage
  [[ $tag == "v$expected_version" ]] || {
    echo "release tag does not match version $expected_version" >&2
    exit 2
  }
  command -v cosign >/dev/null 2>&1 || {
    echo "cosign is required for a production release install" >&2
    exit 1
  }
  command -v gh >/dev/null 2>&1 || {
    echo "GitHub CLI is required for release provenance verification" >&2
    exit 1
  }

  cosign verify-blob "$checksums" \
    --bundle "$bundle" \
    --certificate-identity \
    "https://github.com/AndrewDryga/responder/.github/workflows/release.yml@refs/tags/$tag" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com >/dev/null

  archive_name=${archive##*/}
  expected_name="ryker_${expected_version}_elixir_linux_amd64.tar.gz"
  [[ $archive_name == "$expected_name" ]] || {
    echo "production Elixir archive must be named $expected_name" >&2
    exit 1
  }

  expected_archive_sha256=$(
    awk -v file="$archive_name" \
      '$2 == file && $1 ~ /^[0-9a-f]{64}$/ { print $1 }' "$checksums"
  )

  [[ $expected_archive_sha256 =~ ^[0-9a-f]{64}$ ]] || {
    echo "signed checksum manifest does not name exactly one trusted Elixir archive" >&2
    exit 1
  }

  gh attestation verify "$archive" \
    --repo AndrewDryga/responder \
    --signer-workflow AndrewDryga/responder/.github/workflows/release.yml \
    --source-ref "refs/tags/$tag" >/dev/null
else
  usage
fi

if [[ ! $expected_archive_sha256 =~ ^[0-9a-f]{64}$ ]]; then
  echo "trusted archive SHA-256 must be 64 lowercase hexadecimal characters" >&2
  exit 2
fi

if [[ ! $expected_version =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  echo "release version is not a safe path component" >&2
  exit 2
fi

if [[ $prefix != /* || $prefix == / ]]; then
  echo "release prefix must be an absolute non-root path" >&2
  exit 2
fi

releases="$prefix/releases"
target="$releases/$expected_version"
staging=

archive_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

cleanup() {
  if [[ -n $staging && -d $staging ]]; then
    rm -rf -- "$staging"
  fi
}

trap cleanup EXIT
mkdir -p "$releases"

verify_installed_release() {
  local candidate=$1
  local binary="$candidate/bin/ryker"
  local digest_file="$candidate/.ryker-archive.sha256"

  [[ -d $candidate && -x $binary && -f $digest_file ]] || return 1
  [[ $($binary version) == "ryker $expected_version" ]] || return 1
  [[ $(tr -d '[:space:]' <"$digest_file") == "$expected_archive_sha256" ]]
}

if [[ -e $target || -L $target ]]; then
  if ! verify_installed_release "$target"; then
    echo "release identity collision or incomplete release at $target" >&2
    exit 1
  fi
else
  staging=$(mktemp -d "$releases/.ryker-$expected_version.XXXXXX")
  verified_archive="$staging/.ryker-source.tar.gz"
  install -m 0600 "$archive" "$verified_archive"

  [[ $(archive_sha256 "$verified_archive") == "$expected_archive_sha256" ]] || {
    echo "archive SHA-256 does not match trusted digest" >&2
    exit 1
  }

  "$script_dir/check-elixir-release.sh" \
    "$verified_archive" "$expected_version" "$expected_archive_sha256" \
    --archive-only >/dev/null

  tar -xzf "$verified_archive" -C "$staging"
  rm -- "$verified_archive"

  printf '%s\n' "$expected_archive_sha256" >"$staging/.ryker-archive.sha256"

  if ! verify_installed_release "$staging"; then
    echo "staged release is incomplete or has the wrong version" >&2
    exit 1
  fi

  mv "$staging" "$target"
  staging=
fi

"$script_dir/activate-elixir-release.sh" "$prefix" "$expected_version" >/dev/null

echo "installed ryker $expected_version in $target"
echo "current ryker release: $prefix/current -> releases/$expected_version"
