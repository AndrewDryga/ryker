#!/usr/bin/env bash
set -euo pipefail

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

# A prod release erased dev BEAM files beneath the running Blitz replay VM,
# breaking assets and stopping admission. Exercise the real Mix clean command
# extracted from our release target against disposable environment trees.
mkdir -p "$fixture/scripts" "$fixture/_build/dev/lib/probe/ebin" \
  "$fixture/_build/test/lib/probe/ebin" "$fixture/_build/prod/lib/probe/ebin"
cp "$repository/Makefile" "$fixture/Makefile"
printf 'defmodule Probe.MixProject do\n use Mix.Project\n def project, do: [app: :probe, version: "0.1.0"]\nend\n' >"$fixture/mix.exs"
printf '#!/bin/sh\nprintf 0.1.0\n' >"$fixture/scripts/elixir-release-version.sh"
chmod +x "$fixture/scripts/elixir-release-version.sh"
for environment in dev test prod; do
  printf 'in-use artifact\n' >"$fixture/_build/$environment/lib/probe/ebin/probe.beam"
done

command=$(cd "$fixture" && make -s -n elixir-release | sed -n 's/.*scripts\/elixir-mix.sh do \(clean[^+]*\) + release.*/\1/p')
[[ -n "$command" ]] || { echo 'release clean command not found' >&2; exit 1; }
mkdir -p "$fixture/external/lib/probe/ebin" "$fixture/external/prod/lib/probe/ebin"
printf 'outside build\n' >"$fixture/external/lib/probe/ebin/probe.beam"
printf 'outside root\n' >"$fixture/external/prod/lib/probe/ebin/probe.beam"
for override in MIX_BUILD_PATH MIX_BUILD_ROOT; do
  mkdir -p "$fixture/_build/prod/lib/probe/ebin"
  printf 'release artifact\n' >"$fixture/_build/prod/lib/probe/ebin/probe.beam"
  (
    cd "$fixture"
    unset MIX_BUILD_PATH MIX_BUILD_ROOT MIX_TARGET
    export "$override=$fixture/external"
    # CI build overrides must never let this test clean outside its fixture.
    unset MIX_BUILD_PATH MIX_BUILD_ROOT
    # Word splitting is intentional: execute only the clean task, never a release.
    # shellcheck disable=SC2086
    MIX_ENV=prod mix $command
  )
  [[ -f "$fixture/external/lib/probe/ebin/probe.beam" && -f "$fixture/external/prod/lib/probe/ebin/probe.beam" ]] || {
    echo 'release isolation test touched an external build tree' >&2
    exit 1
  }
done
for environment in dev test; do
  [[ -f "$fixture/_build/$environment/lib/probe/ebin/probe.beam" ]] || {
    echo "release build deleted the $environment runtime artifacts" >&2
    exit 1
  }
done
[[ ! -e "$fixture/_build/prod/lib/probe/ebin/probe.beam" ]]
echo 'release-build-isolation: dev and test artifacts survived prod cleanup'
