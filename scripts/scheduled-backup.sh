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
# The backup prints the archive it wrote as its last line.
taken=$("$compose" backup | tail -n 1)
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
