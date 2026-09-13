#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)

# The toolchain is pinned in .tool-versions. A newer Homebrew Elixir ahead of
# the asdf shims on PATH once produced twenty-two false type warnings under
# --warnings-as-errors and invalidated _build for a full rebuild, so the shims
# are preferred when present and any mismatch is refused before mix runs.
if [[ -d "$HOME/.config/asdf/shims" ]]; then
  export PATH="$HOME/.config/asdf/shims:$PATH"
fi

pinned_elixir=$(awk '$1 == "elixir" { print $2 }' "$root/.tool-versions")
running_elixir=$(elixir --short-version 2>/dev/null || true)

if [[ -z $running_elixir || $pinned_elixir != "$running_elixir"* ]]; then
  echo "elixir '$running_elixir' on PATH does not match .tool-versions ($pinned_elixir)" >&2
  exit 1
fi

# Hex 2.5.1's published archive does not load completely on the pinned OTP 28 toolchain.
hex_version=2.4.1

export HEX_HOME=${RYKER_HEX_HOME:-$root/.elixir/hex}
export MIX_HOME=${RYKER_MIX_HOME:-$root/.elixir/mix-$hex_version}

if [[ ! -d "$MIX_HOME/archives/hex-$hex_version" ]]; then
  mix local.hex "$hex_version" --force >/dev/null
fi

mix local.rebar --if-missing --force >/dev/null

cd "$root"

required_dependencies=(bandit ecto_sql finch jason postgrex phoenix phoenix_html phoenix_live_view)
if [[ ${MIX_ENV:-dev} != prod ]]; then
  required_dependencies+=(credo)
fi
if [[ ${MIX_ENV:-dev} == test ]]; then
  required_dependencies+=(jsv lazy_html)
fi

for dependency in "${required_dependencies[@]}"; do
  if [[ ! -d "$root/deps/$dependency" ]]; then
    mix deps.get --only "${MIX_ENV:-dev}" --check-locked >/dev/null
    break
  fi
done

exec mix "$@"
