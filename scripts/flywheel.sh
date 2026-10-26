#!/bin/sh
# The installed release owns the ledger. JSON is data on stdin, never Elixir
# source or shell arguments; user evidence cannot become an eval expression.
set -eu
repository=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
state_dir=${RYKER_INSTALL_STATE:-$repository/.ryker}
case ${1:--} in
  -) ;;
  --help|-h)
    echo 'usage: scripts/flywheel.sh [REQUEST.json|-]'
    echo 'Reads one flywheel JSON request; see .agent/skills/flywheel/references/commands.md.'
    exit 0 ;;
  *) exec <"$1" ;;
esac
[ "$#" -le 1 ] || { echo 'one JSON request expected' >&2; exit 2; }
[ -r "$state_dir/compose.env" ] || { echo 'Ryker is not installed here' >&2; exit 1; }
cd "$repository"
exec docker compose --env-file "$state_dir/compose.env" exec -T ryker \
  /opt/ryker/bin/ryker eval 'Ryker.Release.flywheel()'
