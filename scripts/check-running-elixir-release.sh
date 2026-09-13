#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: scripts/check-running-elixir-release.sh <loopback-base-url> <expected-version>" >&2
  exit 2
fi

base_url=${1%/}
expected_version=$2

if [[ ! $base_url =~ ^http://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]{1,5})?$ ]]; then
  echo "running release check requires a loopback HTTP base URL" >&2
  exit 2
fi

if [[ ! $expected_version =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  echo "expected release version is invalid" >&2
  exit 2
fi

command -v curl >/dev/null 2>&1 || {
  echo "curl is required to verify the running release" >&2
  exit 1
}

headers=$(
  curl --silent --show-error --fail --max-time 5 \
    --dump-header - --output /dev/null "$base_url/readyz"
)

versions=$(
  printf '%s\n' "$headers" | awk '
    tolower($1) == "x-ryker-version:" {
      value = $0
      sub(/^[^:]*:[[:space:]]*/, "", value)
      sub(/\r$/, "", value)
      print value
    }
  '
)
version_count=$(printf '%s\n' "$versions" | awk 'NF { count++ } END { print count + 0 }')

if [[ $version_count -ne 1 ]]; then
  echo "ready process did not report exactly one release identity" >&2
  exit 1
fi

running_version=$versions

if [[ $running_version != "$expected_version" ]]; then
  echo "running release reports '$running_version', expected '$expected_version'" >&2
  exit 1
fi

echo "running ryker release: $running_version"
