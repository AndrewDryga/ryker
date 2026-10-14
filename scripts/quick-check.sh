#!/bin/bash
# The quick check: what the gate most often fails on, run on the files a change
# touches, in seconds. On 2026-10-14 five gate runs went red minutes in on one
# file each (a format slip, two Credo house rules, PublicFunctionsTest, a short
# assert_receive); this catches four of those five before the gate starts.
#
#   scripts/quick-check.sh            files changed since HEAD, untracked included
#   scripts/quick-check.sh --staged   the files the next commit takes (.githooks/pre-commit)
#   scripts/quick-check.sh --base REV files changed since REV
#
# One compile with warnings as errors, then side by side: format and Credo on
# the changed Elixir files, the compile-time cycle check, ShellCheck and the
# self-test of each changed script, the browser tests when a script they cover
# changed, and one ExUnit run of the three source audits plus each changed
# file's owning test. The gate (scripts/gate.sh) still runs everything.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

mode=worktree
base=HEAD

while (($# > 0)); do
  case $1 in
    --staged) mode=staged ;;
    --base)
      base=${2:?--base needs a revision}
      shift
      ;;
    *)
      echo "usage: scripts/quick-check.sh [--staged | --base REV]" >&2
      exit 2
      ;;
  esac
  shift
done

# These read the whole tree, so any change can break them: a public function
# nothing calls, the old product name, a real Slack identifier.
audits=(
  test/ryker/public_functions_test.exs
  test/ryker/redaction_audit_test.exs
  test/ryker/rename_audit_test.exs
)

changed_files() {
  if [[ $mode == staged ]]; then
    git diff --cached --name-only --diff-filter=d
  else
    git diff --name-only --diff-filter=d "$base"
    git ls-files --others --exclude-standard
  fi
}

# The test that owns a source file: test/<path>_test.exs, else the nearest
# enclosing module's (lib/ryker/settings/channel.ex → test/ryker/settings_test.exs).
owning_test() {
  local path=$1 relative
  case $path in
    test/*_test.exs) echo "$path" && return ;;
    credo/checks/*) ls test/ryker/credo_checks/*_test.exs && return ;;
    lib/*.ex | lib/*.heex | evals/*.ex) relative=${path#*/} ;;
    *) return 0 ;;
  esac
  relative=${relative%.ex}
  relative=${relative%.heex}
  relative=${relative%.html}

  while :; do
    if [[ -f test/${relative}_test.exs ]]; then
      echo "test/${relative}_test.exs"
      return
    fi
    [[ $relative == */* ]] || return 0
    relative=${relative%/*}
  done
}

changed=0
elixir=()
credo=()
shell=()
self_tests=()
tests=("${audits[@]}")
javascript=0

while IFS= read -r file; do
  [[ -f $file ]] || continue
  changed=$((changed + 1))
  case $file in
    *.ex | *.exs) elixir+=("$file") ;;
    *.sh) shell+=("$file") ;;
    priv/static/*.js | test/js/*) javascript=1 ;;
  esac
  # A script's self-test, scripts/<name>_test.sh, owns it.
  case $file in
    scripts/*_test.sh) self_test=$file ;;
    scripts/*.sh) self_test=${file%.sh}_test.sh ;;
    *) self_test= ;;
  esac
  if [[ -x $self_test && " ${self_tests[*]-} " != *" $self_test "* ]]; then
    self_tests+=("$self_test")
  fi
  case $file in
    credo/*.ex | evals/*.ex | lib/*.ex | test/*.ex | test/*.exs) credo+=("$file") ;;
  esac
  while IFS= read -r test; do
    tests+=("$test")
  done < <(owning_test "$file")
done < <(changed_files | LC_ALL=C sort -u)

tests_list=$(printf '%s\n' "${tests[@]}" | LC_ALL=C sort -u)

# A hook runs with Git's variables exported for its own repository. Tests that
# build throwaway repositories would otherwise write into this one's index.
while IFS= read -r variable; do
  unset "$variable"
done < <(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p')

logs=$(mktemp -d "${TMPDIR:-/tmp}/ryker-quick-check.XXXXXX")
pids=()
names=()
started=$(date +%s)

cleanup() {
  status=$?
  trap - EXIT INT TERM
  for pid in ${pids[@]+"${pids[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "$logs"
  exit "$status"
}
trap cleanup EXIT INT TERM

# check NAME COMMAND...: runs COMMAND in the background into $logs/NAME.
check() {
  local name=$1
  shift
  names+=("$name")
  (
    begun=$(date +%s)
    status=0
    "$@" >"$logs/$name" 2>&1 || status=$?
    echo "$status $(($(date +%s) - begun))" >"$logs/$name.status"
  ) &
  pids+=($!)
}

echo "quick check: $changed changed files, $(($(printf '%s\n' "$tests_list" | wc -l) - ${#audits[@]})) owning test files besides the audits"

# Mix locks the build directory, so checks that compile would queue behind one
# another; one compile first lets them all start from a finished build.
if ! env MIX_ENV=test scripts/elixir-mix.sh compile --warnings-as-errors >"$logs/compile" 2>&1; then
  cat "$logs/compile"
  echo "quick check failed: compile ($(($(date +%s) - started)) s)"
  exit 1
fi

if ((${#elixir[@]} > 0)); then
  check format env MIX_ENV=test scripts/elixir-mix.sh format --check-formatted "${elixir[@]}"
fi
if ((${#credo[@]} > 0)); then
  check credo env MIX_ENV=test scripts/elixir-mix.sh credo --strict "${credo[@]}"
fi
check cycles env MIX_ENV=test scripts/elixir-mix.sh xref graph --format cycles --label compile --fail-above 0
if ((${#shell[@]} > 0)); then
  # -x follows a sourced script through its `# shellcheck source=` directive.
  check shellcheck shellcheck -x "${shell[@]}"
fi
if ((${#self_tests[@]} > 0)); then
  # shellcheck disable=SC2016 # expanded by the inner shell
  check scripts sh -c 'for test in "$@"; do "$test" || exit; done' self-tests "${self_tests[@]}"
fi
if ((javascript == 1)); then
  check javascript sh -c 'node --test test/js/*_test.mjs'
fi
# shellcheck disable=SC2086 # one test file per line, none with spaces
check tests scripts/elixir-test.sh --warnings-as-errors $tests_list

failed=()
for index in "${!pids[@]}"; do
  wait "${pids[index]}" || true
  name=${names[index]}
  read -r status seconds <"$logs/$name.status"
  if [[ $status == 0 ]]; then
    printf '  ok    %-10s %3s s\n' "$name" "$seconds"
  else
    printf '  FAIL  %-10s %3s s\n' "$name" "$seconds"
    failed+=("$name")
  fi
done
pids=()

for name in ${failed[@]+"${failed[@]}"}; do
  echo
  echo "== $name"
  cat "$logs/$name"
done

elapsed=$(($(date +%s) - started))
if ((${#failed[@]} > 0)); then
  echo "quick check failed: ${failed[*]} ($elapsed s)"
  exit 1
fi
echo "quick check passed ($elapsed s)"
