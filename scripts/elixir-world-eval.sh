#!/usr/bin/env bash
# Run the model-world evaluation as concurrent shards and merge one report.
#
# The full matrix is 31 scenarios × 3 repeats × 2 lanes, 186 observations at
# about 93 seconds each. One VM ran them one after another — the Repo is a
# singleton and the worker gateway binds one port — so the matrix took 4.8
# hours, and nothing is allowed to take longer than 30 minutes. Each shard is
# its own `mix ryker.eval world --shard I/N` VM on its own campaign
# database and its own listener ports; every shard deals itself the same
# slice of the same ordered plan, writes results without a verdict, and
# `world-merge` joins them into the one report the thresholds and the trend
# tooling read. The observations, the judge and the scenarios are unchanged.
#
# RYKER_WORLD_EVAL_SHARDS (default 4) is how many shards may run. The plan
# preview decides how many actually start: `--repeat 1 --case X` is one pair,
# so it runs one shard, never an empty VM.
set -euo pipefail

if [[ $# -lt 1 || -z "$1" ]]; then
  echo "usage: scripts/elixir-world-eval.sh /absolute/results.json [world options]" >&2
  echo "the dedicated evaluation policies come from RYKER_EVAL_* in the environment" >&2
  echo "RYKER_WORLD_EVAL_SHARDS (default 4) runs that many observation shards at once" >&2
  exit 2
fi

eval_results=$1
shift 1

if [[ $eval_results != /* ]]; then
  echo "the results path must be absolute: $eval_results" >&2
  exit 2
fi

shards=${RYKER_WORLD_EVAL_SHARDS:-4}
if [[ ! $shards =~ ^[0-9]+$ ]] || ((shards < 1 || shards > 64)); then
  echo "RYKER_WORLD_EVAL_SHARDS must be between 1 and 64" >&2
  exit 2
fi

# The plan flags say what runs and go to every shard; the threshold flags
# qualify the merged report and go to the merge. --paired-baseline is both.
world_args=("$@")
plan_args=()
merge_args=()
while (($# > 0)); do
  case $1 in
    --case | --tag | --repeat)
      [[ $# -ge 2 ]] || { echo "$1 needs a value" >&2; exit 2; }
      plan_args+=("$1" "$2")
      shift 2
      ;;
    --case=* | --tag=* | --repeat=*)
      plan_args+=("$1")
      shift
      ;;
    --paired-baseline | --no-paired-baseline)
      plan_args+=("$1")
      merge_args+=("$1")
      shift
      ;;
    --min-overall-pass-rate | --min-case-pass-rate | --max-paired-regression)
      [[ $# -ge 2 ]] || { echo "$1 needs a value" >&2; exit 2; }
      merge_args+=("$1" "$2")
      shift 2
      ;;
    --min-overall-pass-rate=* | --min-case-pass-rate=* | --max-paired-regression=*)
      merge_args+=("$1")
      shift
      ;;
    *)
      echo "unknown world option: $1" >&2
      exit 2
      ;;
  esac
done

# Each shard binds a worker gateway and a state-tools listener. The two
# configured ports are commonly adjacent, so a shard advances both by two:
# shard I listens on base + 2(I - 1), and one shard of one is exactly the
# environment. The layout is checked for the configured count before any
# database exists, because a shard that cannot bind is a shard that ran
# nothing.
worker_base=${RYKER_WORKER_PORT:-4322}
state_base=${RYKER_STATE_TOOLS_PORT:-4318}
if [[ ! $worker_base =~ ^[0-9]+$ || ! $state_base =~ ^[0-9]+$ ]]; then
  echo "RYKER_WORKER_PORT and RYKER_STATE_TOOLS_PORT must be port numbers" >&2
  exit 2
fi

ports=()
for ((index = 1; index <= shards; index++)); do
  ports+=("$((worker_base + 2 * (index - 1)))" "$((state_base + 2 * (index - 1)))")
done
if ((ports[${#ports[@]} - 1] > 65535 || ports[${#ports[@]} - 2] > 65535)); then
  echo "shard ports exceed 65535; lower RYKER_WORLD_EVAL_SHARDS or the base ports" >&2
  exit 2
fi
if [[ -n $(printf '%s\n' "${ports[@]}" | sort -n | uniq -d) ]]; then
  echo "shard ports overlap: with $shards shards the worker ports from $worker_base and the" \
    "state-tools ports from $state_base collide; set RYKER_STATE_TOOLS_PORT an odd" \
    "distance from RYKER_WORKER_PORT (adjacent works) or at least $((2 * shards)) away" >&2
  exit 2
fi

# The public URL is the worker gateway's own origin; only its port changes.
public_url=${RYKER_WORKER_PUBLIC_URL:-}
if [[ -z $public_url ]]; then
  echo "RYKER_WORKER_PUBLIC_URL must name the worker gateway origin" >&2
  exit 2
fi
public_url=${public_url%/}
if [[ $public_url =~ ^(https://.+):[0-9]+$ ]]; then
  public_origin=${BASH_REMATCH[1]}
else
  public_origin=$public_url
fi

# A campaign database is the migrated template each observation database is
# copied from; it holds no custody of its own. Custody belongs to the
# per-observation databases, which `mix ryker.eval world` preserves and
# names when their observation did not pass, so every campaign database is
# always dropped, on any exit, after the merge that may still name them.
campaign="ryker_world_eval_$(date +%s)_$$_${RANDOM}"
databases=()
pids=()

cleanup() {
  status=$?
  trap - EXIT

  for pid in ${pids[@]+"${pids[@]}"}; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done

  for database in ${databases[@]+"${databases[@]}"}; do
    PGDATABASE="$database" MIX_ENV=test mix ecto.drop >/dev/null 2>&1 || true
  done

  exit "$status"
}

trap cleanup EXIT

export RYKER_WORLD_EVAL=1

# One line per shard the plan fills, so a plan smaller than the shard count
# starts only as many VMs as have something to observe.
preview=$(env MIX_ENV=test mix ryker.eval world-shards --shards "$shards" \
  ${plan_args[@]+"${plan_args[@]}"})
launched=$(printf '%s\n' "$preview" | grep -c '"shard"') || true
if ((launched < 1)); then
  echo "the world plan filled no shard" >&2
  printf '%s\n' "$preview" >&2
  exit 1
fi

shards_dir=${eval_results%.json}.shards
mkdir -p "$shards_dir"

for ((index = 1; index <= launched; index++)); do
  database="${campaign}_s${index}"
  PGDATABASE="$database" MIX_ENV=test mix ecto.create
  databases+=("$database")
  PGDATABASE="$database" MIX_ENV=test mix ecto.migrate
done

partials=()
for ((index = 1; index <= launched; index++)); do
  offset=$((2 * (index - 1)))
  worker_port=$((worker_base + offset))
  state_port=$((state_base + offset))
  partial="$shards_dir/shard-$index.json"
  log="$shards_dir/shard-$index.log"
  partials+=("$partial")

  echo "shard $index/$launched: database ${databases[index - 1]}, worker port $worker_port," \
    "log $log"

  PGDATABASE="${databases[index - 1]}" \
    MIX_ENV=test \
    RYKER_WORKER_PORT="$worker_port" \
    RYKER_STATE_TOOLS_PORT="$state_port" \
    RYKER_WORKER_PUBLIC_URL="$public_origin:$worker_port" \
    mix ryker.eval world --results "$partial" --shard "$index/$launched" \
    ${world_args[@]+"${world_args[@]}"} >"$log" 2>&1 &
  pids+=("$!")
done

echo "follow progress with: tail -f $shards_dir/shard-*.log"

failed=0
for ((index = 1; index <= launched; index++)); do
  status=0
  wait "${pids[index - 1]}" || status=$?
  if ((status == 0)); then
    echo "shard $index/$launched finished"
  else
    echo "shard $index/$launched failed with status $status; see $shards_dir/shard-$index.log" >&2
    failed=1
  fi
done
pids=()

if ((failed)); then
  echo "world eval shards failed; partial results and logs are under $shards_dir" >&2
  exit 1
fi

env MIX_ENV=test mix ryker.eval world-merge --results "$eval_results" \
  ${merge_args[@]+"${merge_args[@]}"} "${partials[@]}"
