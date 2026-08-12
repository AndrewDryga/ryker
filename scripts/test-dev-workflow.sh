#!/usr/bin/env bash
set -euo pipefail

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$repository/scripts/focus-check.sh" --help >/dev/null

plan="$tmp/race-plan"
"$repository/scripts/race-shards.sh" --plan >"$plan"
expected=$(cd "$repository" && go test ./internal/service -list '^(Test|Example|Fuzz)' |
  awk '/^(Test|Example|Fuzz)/ { count++ } END { print count + 0 }')
actual=$(wc -l <"$plan" | tr -d ' ')
[[ $actual == "$expected" ]] || {
  echo "dev-workflow-test: race plan assigned $actual of $expected service tests" >&2
  exit 1
}
awk -F '\t' '
  { count[$2]++; shards[$1]++ }
  END {
    for (test in count) if (count[test] != 1) exit 1
    min = 1000000
    for (shard in shards) {
      if (shards[shard] < min) min = shards[shard]
      if (shards[shard] > max) max = shards[shard]
    }
    if (max - min > 1) exit 1
  }
' "$plan" || {
  echo "dev-workflow-test: service race tests are duplicated or imbalanced" >&2
  exit 1
}

# Exercise proof validation in an isolated tiny repository. The production
# helper deliberately refuses a dirty checkout, so testing against this working
# tree would either weaken that invariant or make the test order-dependent.
fixture="$tmp/repository"
mkdir -p "$fixture/scripts" "$tmp/proofs" "$tmp/libexec"
cp "$repository/scripts/candidate-check.sh" "$fixture/scripts/"
cp "$repository/.tool-versions" "$fixture/"
(
  cd "$fixture"
  git init -q
  git config user.email test@example.invalid
  git config user.name Test
  git add .tool-versions scripts/candidate-check.sh
  git commit -qm fixture
)

full_sha=$(git -C "$fixture" rev-parse HEAD)
short_sha=$(git -C "$fixture" rev-parse --short HEAD)
binary="$tmp/libexec/responder-$short_sha"
printf 'candidate artifact\n' >"$binary"
chmod +x "$binary"
hash=$(shasum -a 256 "$binary" | awk '{ print $1 }')
toolchain=$(go version)
platform="$(go env GOOS)/$(go env GOARCH)/cgo=$(go env CGO_ENABLED)"
now=$(date +%s)
proof="$tmp/proofs/$full_sha.json"
jq -n --arg commit "$full_sha" --arg binary "$binary" --arg sha256 "$hash" \
  --arg toolchain "$toolchain" --arg platform "$platform" --argjson created_unix "$now" \
  '{schema:1, commit:$commit, binary:$binary, sha256:$sha256, toolchain:$toolchain,
    platform:$platform, created_at:"test", created_unix:$created_unix}' >"$proof"

candidate=(env "RESPONDER_CANDIDATE_PROOFS=$tmp/proofs" "RESPONDER_LIBEXEC=$tmp/libexec"
  "$fixture/scripts/candidate-check.sh" --verify-only)
(cd "$fixture" && "${candidate[@]}") >/dev/null

printf 'tampered\n' >>"$binary"
if (cd "$fixture" && "${candidate[@]}") >/dev/null 2>&1; then
  echo "dev-workflow-test: candidate proof accepted a tampered artifact" >&2
  exit 1
fi

printf 'candidate artifact\n' >"$binary"
hash=$(shasum -a 256 "$binary" | awk '{ print $1 }')
jq --arg sha256 "$hash" '.sha256 = $sha256 | .created_unix = 1' "$proof" >"$proof.tmp"
mv "$proof.tmp" "$proof"
if (cd "$fixture" && "${candidate[@]}") >/dev/null 2>&1; then
  echo "dev-workflow-test: candidate proof accepted a stale result" >&2
  exit 1
fi

echo "dev-workflow-test: focused checks, race sharding, and exact-artifact proof passed"
