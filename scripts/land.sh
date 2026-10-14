#!/bin/bash
# Moves main to a commit made in another worktree while the checkout that has
# main checked out may hold other sessions' uncommitted work.
#
#   scripts/land.sh COMMIT
#
# COMMIT must build on main. Every file it changes must be untouched in that
# checkout: an edit there is another session's, and checking the commit's
# version out over it would silently lose it, so the landing refuses and names
# the files. Then main moves by compare-and-swap (git update-ref with the old
# value), which refuses if anyone moved main meanwhile, and only the commit's
# files are checked out in that checkout, renames and deletions included.
#
# Each step of this was once done by hand and went wrong a different way: a
# landing in zsh whose path list never split checked one bogus path and called
# it clean (2026-09-26), a refused update-ref that the next line did not wait
# for (2026-10-12), and a rename whose old path stayed behind (2026-10-03).
set -euo pipefail

repository=$(git rev-parse --show-toplevel)
cd "$repository"

target=$(git rev-parse --verify --quiet "${1:?usage: scripts/land.sh COMMIT}^{commit}") || {
  echo "land: $1 is not a commit" >&2
  exit 2
}
old=$(git rev-parse --verify main)

if [[ $target == "$old" ]]; then
  echo "land: main is already ${target:0:9}"
  exit 0
fi
if ! git merge-base --is-ancestor "$old" "$target"; then
  echo "land: ${target:0:9} does not build on main (${old:0:9}); rebase it onto main first" >&2
  exit 1
fi

# The worktree that has main checked out, whose files follow main.
checkout=$(git worktree list --porcelain | awk '
  /^worktree / { tree = substr($0, 10) }
  $0 == "branch refs/heads/main" { print tree }')

paths=()
while IFS= read -r -d '' path; do
  paths+=("$path")
done < <(git diff --name-only --no-renames -z "$old" "$target")

if [[ -n $checkout ]]; then
  touched=()
  for path in "${paths[@]}"; do
    if ! git -C "$checkout" diff --quiet "$old" -- "$path" ||
      ! git -C "$checkout" diff --cached --quiet "$old" -- "$path"; then
      touched+=("$path")
    elif ! git cat-file -e "$old:$path" 2>/dev/null && [[ -e $checkout/$path || -L $checkout/$path ]]; then
      # A file the commit adds already sits there, untracked.
      touched+=("$path")
    fi
  done
  if ((${#touched[@]} > 0)); then
    echo "land: these files have uncommitted changes in $checkout, so main stays at ${old:0:9}:" >&2
    printf '  %s\n' "${touched[@]}" >&2
    echo "Land once they are committed or set aside, or merge them into your commit." >&2
    exit 1
  fi
fi

git update-ref -m "land ${target:0:9}" refs/heads/main "$target" "$old" || {
  echo "land: main moved while landing; rebase onto the new main and land again" >&2
  exit 1
}

if [[ -n $checkout ]] && ((${#paths[@]} > 0)); then
  present=()
  for path in "${paths[@]}"; do
    if git cat-file -e "$target:$path" 2>/dev/null; then
      present+=("$path")
    else
      git -C "$checkout" rm -q --cached --ignore-unmatch -- "$path"
      rm -f "$checkout/$path"
    fi
  done
  if ((${#present[@]} > 0)); then
    git -C "$checkout" checkout "$target" -- "${present[@]}"
  fi
  if ! git -C "$checkout" diff --quiet HEAD -- "${paths[@]}" ||
    ! git -C "$checkout" diff --cached --quiet HEAD -- "${paths[@]}"; then
    echo "land: main is ${target:0:9}, but $checkout does not match it for:" >&2
    git -C "$checkout" status --short -- "${paths[@]}" >&2
    exit 1
  fi
fi

echo "land: main ${old:0:9} -> ${target:0:9}, ${#paths[@]} files${checkout:+ checked out in $checkout}"
