#!/usr/bin/env bash
# Format and validate only the files and Go packages changed in this checkout.
set -euo pipefail

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
package=${RESPONDER_FOCUS_PACKAGE:-}
test_name=${RESPONDER_FOCUS_TEST:-}

cd "$repository"

if [[ ${1:-} == "--help" ]]; then
  cat <<'EOF'
usage: make focus [FOCUS_PACKAGE=./internal/service] [FOCUS_TEST=TestName]

With no arguments, formats changed Go files and tests their owning packages.
Set FOCUS_PACKAGE and optionally FOCUS_TEST for an exact package or named test.
EOF
  exit 0
fi

if [[ -n $package ]]; then
  args=(go test "$package")
  if [[ -n $test_name ]]; then
    args+=( -run "$test_name" )
  fi
  args+=( -count=1 )
  printf 'focus: %q ' "${args[@]}"
  printf '\n'
  exec "${args[@]}"
fi

changed=$(mktemp)
go_files=$(mktemp)
shell_files=$(mktemp)
package_dirs=$(mktemp)
trap 'rm -f "$changed" "$go_files" "$shell_files" "$package_dirs"' EXIT

{
  git diff --name-only HEAD
  git ls-files --others --exclude-standard
} | awk 'NF && !seen[$0]++' >"$changed"

if [[ ! -s $changed ]]; then
  echo "focus: no changed files; set FOCUS_PACKAGE to run an exact package" >&2
  exit 2
fi

grep -E '\.go$' "$changed" >"$go_files" || true
grep -E '\.sh$' "$changed" >"$shell_files" || true

if [[ -s $go_files ]]; then
  # Mechanical formatting belongs in the fast loop. The candidate gate remains
  # read-only and proves the committed result later.
  while IFS= read -r file; do
    [[ -f $file ]] && gofmt -w "$file"
    dirname "$file"
  done <"$go_files" | sort -u >"$package_dirs"

  while IFS= read -r dir; do
    target="./$dir"
    [[ $dir == "." ]] && target="."
    echo "focus: go test $target -count=1"
    go test "$target" -count=1
  done <"$package_dirs"
fi

if [[ -s $shell_files ]]; then
  existing=()
  while IFS= read -r file; do
    [[ -f $file ]] && existing+=("$file")
  done <"$shell_files"
  if [[ ${#existing[@]} -gt 0 ]]; then
    echo "focus: shellcheck ${existing[*]}"
    shellcheck "${existing[@]}"
  fi
fi

if [[ ! -s $go_files && ! -s $shell_files ]]; then
  echo "focus: no Go or shell owner could be inferred; running the fast repository gate"
  exec make dev-check
fi
