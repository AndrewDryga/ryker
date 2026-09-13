#!/usr/bin/env bash
set -euo pipefail

prefix=${1:-}
expected_version=${2:-}

if [[ -z $prefix || -z $expected_version ]]; then
  echo "usage: scripts/activate-elixir-release.sh ABSOLUTE_PREFIX VERSION" >&2
  exit 2
fi

if [[ $prefix != /* || $prefix == / ]]; then
  echo "release prefix must be an absolute non-root path" >&2
  exit 2
fi

if [[ ! $expected_version =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  echo "release version is not a safe path component" >&2
  exit 2
fi

target="$prefix/releases/$expected_version"
binary="$target/bin/ryker"

if [[ ! -d $target || ! -x $binary ]]; then
  echo "installed release $target is incomplete" >&2
  exit 1
fi

if [[ $($binary version) != "ryker $expected_version" ]]; then
  echo "installed release $target has the wrong version" >&2
  exit 1
fi

if [[ -e $prefix/current && ! -L $prefix/current ]]; then
  echo "release pointer $prefix/current exists and is not a symbolic link" >&2
  exit 1
fi

link_staging=$(mktemp -d "$prefix/.current.XXXXXX")

cleanup() {
  if [[ -L $link_staging ]]; then
    rm -- "$link_staging"
  elif [[ -d $link_staging ]]; then
    rmdir "$link_staging"
  fi
}

trap cleanup EXIT
rmdir "$link_staging"
ln -s "releases/$expected_version" "$link_staging"

case $(uname -s) in
  Darwin|FreeBSD) mv -fh "$link_staging" "$prefix/current" ;;
  *) mv -Tf "$link_staging" "$prefix/current" ;;
esac

if [[ $("$prefix"/current/bin/ryker version) != "ryker $expected_version" ]]; then
  echo "activated release failed verification" >&2
  exit 1
fi

echo "current ryker release: $prefix/current -> releases/$expected_version"
