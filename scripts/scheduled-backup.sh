#!/bin/bash
# Takes an explicitly scheduled controller snapshot. All producers atomically replace
# the same .ryker/backups/ryker-latest.tar.gz; a failed snapshot preserves its predecessor.
set -euo pipefail

# launchd starts agents with a PATH that has no Docker on it.
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin"

here=$(cd "$(dirname "$0")" && pwd)
compose=${RYKER_COMPOSE_SH:-$here/compose.sh}
echo "backup: started $(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Only lifecycle contention is temporary. A failed dump must stay a failure,
# and an upgrade must not make the day's only scheduled attempt disappear.
for attempt in 1 2 3 4 5; do
  if taken=$("$compose" backup --controller-only | tail -n 1); then
    break
  else
    status=$?
    if [[ $status -ne 75 || $attempt -eq 5 ]]; then
      echo "backup: failed (exit $status)" >&2
      exit "$status"
    fi
    echo "backup: deployment busy; retrying in 60 seconds ($attempt/5)" >&2
    sleep 60
  fi
done
if [[ ! -f $taken || $(basename "$taken") != ryker-*.tar.gz ]]; then
  echo "backup: the backup reported no archive: '$taken'" >&2
  exit 1
fi
echo "backup: wrote $taken; one rolling archive retained"
