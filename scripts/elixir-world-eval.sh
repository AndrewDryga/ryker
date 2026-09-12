#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || -z "$1" ]]; then
  echo "usage: scripts/elixir-world-eval.sh /absolute/results.json [world options]" >&2
  echo "the dedicated evaluation policies come from RESPONDER_EVAL_* in the environment" >&2
  exit 2
fi

eval_results=$1
shift 1
# The campaign database is the migrated template every observation database is
# copied from; it holds no custody of its own. Custody belongs to the
# per-observation databases, which `mix responder.eval world` preserves and
# names when their observation did not pass, so this one is always dropped.
eval_database="responder_world_eval_$(date +%s)_$$_${RANDOM}"
created=0

cleanup() {
  status=$?
  trap - EXIT

  if [[ $created -eq 1 ]]; then
    PGDATABASE="$eval_database" MIX_ENV=test mix ecto.drop >/dev/null 2>&1 || true
  fi

  exit "$status"
}

trap cleanup EXIT

export RESPONDER_WORLD_EVAL=1

PGDATABASE="$eval_database" MIX_ENV=test mix ecto.create
created=1
PGDATABASE="$eval_database" MIX_ENV=test mix ecto.migrate
PGDATABASE="$eval_database" MIX_ENV=test mix responder.eval world \
  --results "$eval_results" "$@"
