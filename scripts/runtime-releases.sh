#!/usr/bin/env bash
# Fails while a newer Erlang/OTP release of the pinned major, or a newer Elixir
# patch of the pinned minor, is out (Emisar's "a CVE review covers the
# runtime"). Debian and Hex package scanners never see the runtime itself:
# Ryker ran OTP 28.4.1 for two weeks after 28.5.0.7 fixed CVE-2026-89422, a
# TLS 1.3 client that finished a handshake without checking the server's
# certificate, and nothing said so (2026-10-08). CI runs this every day
# (.github/workflows/runtime-releases.yml); `gh` reads the releases.
#
# A bump moves `.tool-versions`, the Dockerfile's builder image and
# `deploy/compose/coop/Box.Dockerfile` together; the compose distribution test
# holds them to one version.
set -euo pipefail

# The newest version among the lines on stdin.
newest() { sort -V | tail -n 1; }

# Prints each runtime with a newer release than `.tool-versions` pins and
# fails when there is one.
check_runtime_releases() {
  local versions=$1 erlang elixir line latest stale=0
  erlang=$(awk '$1 == "erlang" { print $2 }' "$versions")
  elixir=$(awk '$1 == "elixir" { print $2 }' "$versions")
  elixir=${elixir%%-otp-*}

  if [[ -z $erlang || -z $elixir ]]; then
    echo "$versions pins no erlang or no elixir." >&2
    return 2
  fi

  latest=$(gh api "repos/erlang/otp/releases?per_page=100" --jq '.[].tag_name' |
    sed -n "s/^OTP-\(${erlang%%.*}\.[0-9.]*\)$/\1/p" | newest)

  line=$(printf '%s\n%s\n' "$erlang" "$latest" | newest)
  if [[ $line != "$erlang" ]]; then
    echo "Erlang/OTP $line is out; Ryker pins $erlang."
    stale=1
  fi

  latest=$(gh api "repos/elixir-lang/elixir/releases?per_page=100" --jq '.[].tag_name' |
    sed -n "s/^v\($(cut -d. -f1,2 <<<"$elixir" | sed 's/\./\\./g')\.[0-9]*\)$/\1/p" | newest)

  line=$(printf '%s\n%s\n' "$elixir" "$latest" | newest)
  if [[ $line != "$elixir" ]]; then
    echo "Elixir $line is out; Ryker pins $elixir."
    stale=1
  fi

  if [[ $stale -eq 0 ]]; then
    echo "Erlang/OTP $erlang and Elixir $elixir are the newest of their lines."
  fi

  return "$stale"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  check_runtime_releases "$(cd "$(dirname "$0")/.." && pwd)/.tool-versions"
fi
