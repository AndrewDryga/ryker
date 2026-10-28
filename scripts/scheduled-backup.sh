#!/bin/bash
# Takes the daily backup scripts/install-backup-schedule.sh schedules, and keeps the newest few.
#
#   scripts/scheduled-backup.sh
#
# A backup taken by hand stays until someone deletes it (scripts/compose.sh backup). A scheduled
# one is named scheduled-<time>.tar.gz, and only the newest RYKER_KEEP_SCHEDULED_BACKUPS of those
# stay, 14 unless set. Until 2026-10-14 no install took a backup on its own: the tenant install's
# newest was whatever its last upgrade had taken.
set -euo pipefail

# launchd starts agents with a PATH that has no Docker on it.
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin"

here=$(cd "$(dirname "$0")" && pwd)
compose=${RYKER_COMPOSE_SH:-$here/compose.sh}
keep=${RYKER_KEEP_SCHEDULED_BACKUPS:-14}
if [[ ! $keep =~ ^[1-9][0-9]*$ ]]; then
  echo "RYKER_KEEP_SCHEDULED_BACKUPS must be a positive whole number, not '$keep'" >&2
  exit 2
fi

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
backup_dir=$(dirname "$taken")
scheduled="$backup_dir/scheduled-$(basename "$taken" | sed 's/^ryker-//')"
mv -- "$taken" "$scheduled"
echo "backup: wrote $scheduled"

listed=0
removed=0
while IFS= read -r old; do
  listed=$((listed + 1))
  if ((listed > keep)); then
    rm -f -- "$old"
    removed=$((removed + 1))
  fi
done < <(find "$backup_dir" -maxdepth 1 -name 'scheduled-*.tar.gz' | sort -r)
echo "backup: kept the newest $((listed - removed)) scheduled backups, removed $removed"
