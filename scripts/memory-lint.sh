#!/bin/bash
# Checks the agents' memory notes for this checkout (Claude Code keeps them in
# ~/.claude/projects/<checkout path>/memory) against themselves and the tree:
#
#   scripts/memory-lint.sh [MEMORY_DIRECTORY]
#
# Errors, which fail it: a note MEMORY.md does not list, an entry in MEMORY.md
# with no note, and a note whose frontmatter lacks its name (the file's own),
# description or type (user, feedback, project or reference). Warnings: a
# repository file a note names that no longer exists, the usual sign of a note
# describing a workaround that has since been fixed or renamed away. On
# 2026-10-14 there were 113 notes, and 37 of them described a manual step.
set -uo pipefail

repository=$(git rev-parse --show-toplevel)
directory=${1:-$HOME/.claude/projects/$(printf '%s' "$repository" | sed 's/[^A-Za-z0-9]/-/g')/memory}
index=$directory/MEMORY.md

if [[ ! -f $index ]]; then
  echo "memory-lint: no MEMORY.md in $directory" >&2
  exit 2
fi

errors=0
warnings=0
notes=0

error() {
  echo "  ERROR $1"
  errors=$((errors + 1))
}

listed=$(grep -oE '\]\([^)]+\.md\)' "$index" | sed -E 's/^\]\(//; s/\)$//' | LC_ALL=C sort -u)

while IFS= read -r note; do
  [[ -f $directory/$note ]] || error "MEMORY.md lists $note, which does not exist"
done <<<"$listed"

for file in "$directory"/*.md; do
  note=$(basename "$file")
  [[ $note != MEMORY.md ]] || continue
  notes=$((notes + 1))
  grep -qxF "$note" <<<"$listed" || error "$note is not listed in MEMORY.md"

  frontmatter=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$file")
  name=$(sed -n 's/^name:[[:space:]]*//p' <<<"$frontmatter" | head -n 1)
  type=$(sed -nE 's/^[[:space:]]*type:[[:space:]]*//p' <<<"$frontmatter" | head -n 1)
  [[ $name == "${note%.md}" ]] || error "$note: its name is '$name', not '${note%.md}'"
  grep -q '^description:' <<<"$frontmatter" || error "$note: no description"
  [[ $type =~ ^(user|feedback|project|reference)$ ]] || error "$note: type is '$type'"

  while IFS= read -r path; do
    if [[ ! -e $repository/$path ]]; then
      echo "  stale $note: $path no longer exists"
      warnings=$((warnings + 1))
    fi
  done < <(grep -oE '(^|[^A-Za-z0-9_./-])(scripts|lib|test|docs|deploy|config|evals|priv)/[A-Za-z0-9_./-]+\.(sh|ex|exs|md|yml|yaml|json|cjs|mjs)' "$file" |
    sed -E 's/^[^a-z]//' | LC_ALL=C sort -u)
done

echo "memory-lint: $notes notes, $errors errors, $warnings stale paths"
((errors == 0))
