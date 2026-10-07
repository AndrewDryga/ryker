#!/usr/bin/env bash
# Proves the host model installers keep only the bytes they pin. They fetched
# `resolve/main` and kept whatever came back (2026-10-04 review), so a moved
# branch or a replaced file would have run on this Mac unnoticed.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/ryker-model-download-test.XXXXXX")
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

# A fake curl that serves whatever the case put in $work/served and counts its
# downloads.
mkdir -p "$work/bin"
cat >"$work/bin/curl" <<'SH'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  case $1 in
    -o) output=$2; shift ;;
  esac
  shift
done
echo download >>"$MODEL_TEST_WORK/downloads"
cat "$MODEL_TEST_WORK/served" >"$output"
SH
chmod 0755 "$work/bin/curl"
export PATH="$work/bin:$PATH" MODEL_TEST_WORK="$work"

# shellcheck source=scripts/model-download.sh
. "$root/scripts/model-download.sh"

printf 'the pinned model\n' >"$work/served"
pinned=$(shasum -a 256 "$work/served" | cut -d' ' -f1)
model="$work/models/model.bin"
mkdir -p "$work/models"

out=$(download_model https://example.invalid/model.bin "$pinned" "$model" "a model" 2>&1; echo "exit=$?")
check "the pinned bytes install" "exit=0" "$out"
check "the installed file holds them" "the pinned model" "$(cat "$model" 2>/dev/null)"
check "the download is announced" "Downloading a model to $work/models" "$out"

out=$(download_model https://example.invalid/model.bin "$pinned" "$model" "a model" 2>&1; echo "exit=$?")
check "an installed model with the pinned bytes is kept" "exit=0" "$out"
check "it is not downloaded again" "1" "$(wc -l <"$work/downloads" | tr -d ' ')"

printf 'another file under the same name\n' >"$work/served"
rm "$model"
out=$(download_model https://example.invalid/model.bin "$pinned" "$model" "a model" 2>&1; echo "exit=$?")
check "other bytes are refused" "exit=1" "$out"
check "the refusal names both digests" "wanted $pinned" "$out"
if [[ -e $model || -e $model.partial ]]; then
  printf 'FAIL refused bytes leave nothing behind\n'
  failures=$((failures + 1))
else
  printf 'ok   refused bytes leave nothing behind\n'
fi

printf 'an older model\n' >"$model"
printf 'the pinned model\n' >"$work/served"
out=$(download_model https://example.invalid/model.bin "$pinned" "$model" "a model" 2>&1; echo "exit=$?")
check "an installed model with other bytes is replaced" "the pinned model" "$(cat "$model")"

if [[ $failures -gt 0 ]]; then
  echo "$failures model download check(s) failed"
  exit 1
fi
echo "model download self-test passed"
