#!/bin/bash
# Fast commit gate: format staged files, block the commit if they're dirty.
# Reads the tool call on stdin; only acts on git commit. Fails open.
set -f          # the file lists below are word-split on purpose; don't also glob-expand a name
IFS=$'\n'       # …and split only on newlines, so a staged filename with a space stays one path
input=$(cat)
echo "$input" | grep -q '"command"[^}]*git commit' || exit 0
staged=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null) || exit 0

# Go: block the commit if any staged .go file isn't gofmt-clean.
go_files=$(echo "$staged" | grep '\.go$' || true)
if [ -n "$go_files" ] && command -v gofmt >/dev/null 2>&1; then
  # shellcheck disable=SC2086  # intentional: split the file list into separate gofmt args
  bad=$(gofmt -l $go_files 2>/dev/null || true)
  if [ -n "$bad" ]; then
    echo "pre-commit blocked — these need gofmt:" >&2; echo "  ${bad//$'\n'/$'\n'  }" >&2
    echo "fix: gofmt -w <files>   (skip once: git commit --no-verify)" >&2; exit 2
  fi
fi

exit 0
