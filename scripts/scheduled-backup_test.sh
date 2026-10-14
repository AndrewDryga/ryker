#!/bin/bash
# Proves scripts/scheduled-backup.sh keeps the newest scheduled backups and nothing a person took,
# and leaves every backup alone when the backup itself fails.
#
# Until 2026-10-14 no install took a backup on its own. One that did, and kept every archive,
# would fill the disk it protects; one that rotated by name could delete the backup a person took
# before an upgrade.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
check() {
  local what="$1" expected="$2" actual="$3"
  if [[ $actual == "$expected" ]]; then
    printf 'ok   %s\n' "$what"
  else
    printf 'FAIL %s\n     wanted: %s\n     got:    %s\n' "$what" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

backups="$work/backups"
mkdir -p "$backups"
# A stand-in for scripts/compose.sh backup: it writes the archive under the name the real one
# uses, one second apart, and prints its path last. With $work/fail, it fails before writing.
cat >"$work/compose.sh" <<FAKE
#!/bin/bash
[[ \$1 == backup ]] || exit 2
[[ -e "$work/fail" ]] && { echo "database dump failed" >&2; exit 1; }
count=\$(cat "$work/count" 2>/dev/null || echo 0)
count=\$((count + 1))
echo "\$count" >"$work/count"
archive="$backups/ryker-20261014T0300\$(printf '%02d' "\$count")Z.tar.gz"
echo archive >"\$archive"
echo "Pausing Ryker to capture the database and encrypted files consistently." >&2
echo "\$archive"
FAKE
chmod +x "$work/compose.sh"

echo kept >"$backups/ryker-20261001T120000Z.tar.gz"
echo kept >"$backups/pre-deploy-20261013T210335Z.tar.gz"

scheduled() {
  find "$backups" -maxdepth 1 -name 'scheduled-*.tar.gz' -exec basename {} \; | sort | tr '\n' ' ' | sed 's/ $//'
}

run() {
  RYKER_COMPOSE_SH="$work/compose.sh" RYKER_KEEP_SCHEDULED_BACKUPS=2 \
    "$root/scripts/scheduled-backup.sh" >>"$work/log" 2>&1
}

for _ in 1 2 3; do
  run
  check "a scheduled backup succeeds" 0 "$?"
done
check "only the newest two scheduled backups stay" \
  "scheduled-20261014T030002Z.tar.gz scheduled-20261014T030003Z.tar.gz" \
  "$(scheduled)"
check "a backup a person took stays" "kept" "$(cat "$backups/ryker-20261001T120000Z.tar.gz")"
check "a pre-deploy backup stays" "kept" "$(cat "$backups/pre-deploy-20261013T210335Z.tar.gz")"

touch "$work/fail"
run
check "a failed backup fails the run" 1 "$?"
check "a failed backup removes no earlier one" \
  "scheduled-20261014T030002Z.tar.gz scheduled-20261014T030003Z.tar.gz" \
  "$(scheduled)"

if ((failures > 0)); then
  echo "scheduled-backup_test: $failures failure(s)"
  sed 's/^/  log: /' "$work/log"
  exit 1
fi
echo "scheduled-backup_test: all checks passed"
