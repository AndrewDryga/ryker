#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# Hex 2.5.1's published archive does not load completely on the pinned OTP 28 toolchain.
hex_version=2.4.1

export HEX_HOME=${RESPONDER_HEX_HOME:-$root/.elixir/hex}
export MIX_HOME=${RESPONDER_MIX_HOME:-$root/.elixir/mix-$hex_version}

if [[ ! -d "$MIX_HOME/archives/hex-$hex_version" ]]; then
  mix local.hex "$hex_version" --force >/dev/null
fi

mix local.rebar --if-missing --force >/dev/null

cd "$root"

required_dependencies=(bandit ecto_sql finch jason postgrex)
if [[ ${MIX_ENV:-dev} != prod ]]; then
  required_dependencies+=(credo)
fi
if [[ ${MIX_ENV:-dev} == test ]]; then
  required_dependencies+=(jsv)
fi

for dependency in "${required_dependencies[@]}"; do
  if [[ ! -d "$root/deps/$dependency" ]]; then
    mix deps.get --only "${MIX_ENV:-dev}" --check-locked >/dev/null
    break
  fi
done

exec mix "$@"
