#!/usr/bin/env bash
# Proves the runtime release check fails while a newer patch of the pinned
# Erlang/OTP or Elixir line is out, and stays quiet otherwise. Ryker ran a
# runtime with a critical TLS fix available for two weeks (2026-10-08).
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/ryker-runtime-releases-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

failures=0
check() {
  if [[ $3 == *"$2"* ]]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n     wanted: %s\n     got:    %s\n' "$1" "$2" "$3"
    failures=$((failures + 1))
  fi
}

# A fake gh that answers the release tags a case put in $work/otp and
# $work/elixir, newest first, as `gh api --jq '.[].tag_name'` prints them.
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'SH'
#!/bin/sh
case $2 in
  repos/erlang/otp/*) cat "$RUNTIME_TEST_WORK/otp" ;;
  repos/elixir-lang/elixir/*) cat "$RUNTIME_TEST_WORK/elixir" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
SH
chmod 0755 "$work/bin/gh"
export PATH="$work/bin:$PATH" RUNTIME_TEST_WORK="$work"

# shellcheck source=scripts/runtime-releases.sh
. "$root/scripts/runtime-releases.sh"

printf 'erlang 28.4.1\nelixir 1.19.5-otp-28\n' >"$work/tool-versions"
printf 'OTP-29.1.1\nOTP-28.5.0.7\nOTP-29.0-rc1\nOTP-28.4.1\nOTP-28.10\nOTP-27.3.4.18\n' >"$work/otp"
printf 'v1.20.4\nv1.19.6\nv1.19-latest\nv1.19.5\nv1.19.7-rc.0\n' >"$work/elixir"

out=$(check_runtime_releases "$work/tool-versions" 2>&1; echo "exit=$?")
check "a newer patch of the pinned OTP major fails the check" "exit=1" "$out"
check "it names the newest of that major, by version order" "Erlang/OTP 28.10 is out; Ryker pins 28.4.1." "$out"
check "a newer Elixir patch of the pinned minor is named" "Elixir 1.19.6 is out; Ryker pins 1.19.5." "$out"

printf 'erlang 28.10\nelixir 1.19.6-otp-28\n' >"$work/tool-versions"
out=$(check_runtime_releases "$work/tool-versions" 2>&1; echo "exit=$?")
check "the newest of each line passes; a new major or a candidate is not a patch" "exit=0" "$out"
check "a pass says what it checked" "Erlang/OTP 28.10 and Elixir 1.19.6 are the newest of their lines." "$out"

printf 'erlang 28.4.1\n' >"$work/tool-versions"
out=$(check_runtime_releases "$work/tool-versions" 2>&1; echo "exit=$?")
check "a pin file without both runtimes is refused" "exit=2" "$out"

if [[ $failures -gt 0 ]]; then
  echo "$failures runtime release check(s) failed"
  exit 1
fi
echo "runtime release self-test passed"
