#!/bin/sh
# Loads the session policies Ryker wrote for the bundled worker.
#
#   load-policies.sh NEW LOADED PROBLEM
#
# Coop refuses a whole policy file over one entry, such as a fallback model on
# an account the worker has not signed in. Connecting with such a file would
# stop all work, so the worker keeps the policies it last loaded (LOADED)
# instead, and leaves Coop's reason in PROBLEM, where Ryker shows it on
# Settings > Models. PROBLEM holds account names, never secrets.
#
# Prints the JSON of `coop sessions policies --json` for the file the worker
# should connect with and exits 0, or exits 1 when neither file loads.
set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: load-policies.sh NEW LOADED PROBLEM" >&2
  exit 2
fi

new=$1
loaded=$2
problem=$3
umask 077
reason=$(mktemp "${TMPDIR:-/tmp}/ryker-policy-problem.XXXXXX")
trap 'rm -f "$reason"' EXIT

if json=$(coop sessions policies --policies "$new" --json 2>"$reason"); then
  cp "$new" "$loaded.tmp"
  chmod 0600 "$loaded.tmp"
  mv "$loaded.tmp" "$loaded"
  rm -f "$problem"
  printf '%s\n' "$json"
  exit 0
fi

# Coop's reason, capped: one line names the refused entry, and nothing an
# operator needs sits past the first few kilobytes.
dd if="$reason" of="$problem.tmp" bs=4096 count=1 2>/dev/null
chmod 0644 "$problem.tmp"
mv "$problem.tmp" "$problem"

if [ -f "$loaded" ] && json=$(coop sessions policies --policies "$loaded" --json 2>/dev/null); then
  echo "Ryker's worker could not load the newest models, so it keeps running the ones it loaded before." >&2
  printf '%s\n' "$json"
  exit 0
fi

exit 1
