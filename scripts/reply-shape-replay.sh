#!/usr/bin/env bash
# reply-shape-replay.sh measures the reply-shape validator against replies
# Responder actually posted, instead of waiting for it to reject something live.
#
# Every posted reply is still on disk in work_episode_events. The text is at
# $.completion.message on a completion_submitted row; the message it answered is
# the episode objective, which is the triggering Slack text normalised and cut
# to 180 bytes. Those two are what internal/decision needs, so the whole corpus
# can be scored offline for free.
#
# The objective is a prefix, not the message, so a trigger longer than 180 bytes
# under-counts its own words and would be scored against too tight a bound. The
# full text is recovered where it survives in a run context's recent_messages,
# and where it does not, the row is scored at both ends of the ladder and
# reported as undecided when the two disagree.
#
# The live file is only ever read, and only by cp. Responder runs its state in
# WAL mode, so the write-ahead log is copied beside it — without it the replay
# silently scores a corpus that stops at the last checkpoint, and the copy is
# what gets opened so no reader ever attaches to the running database.
#
# Usage: scripts/reply-shape-replay.sh <state.db> [<state.db>...]
set -euo pipefail

if [ "$#" -eq 0 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
  sed -n '2,20p' "$0"
  exit 0
fi

for tool in sqlite3 jq python3 go; do
  command -v "$tool" >/dev/null || {
    echo "reply-shape-replay: $tool is required" >&2
    exit 1
  }
done

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

index=0
for database in "$@"; do
  [ -r "$database" ] || {
    echo "reply-shape-replay: cannot read $database" >&2
    exit 1
  }
  index=$((index + 1))
  host="$(basename "$(dirname "$(dirname "$(dirname "$database")")")")"
  copy="$scratch/$index.db"
  cp "$database" "$copy"
  for sidecar in -wal -shm; do
    [ -r "$database$sidecar" ] && cp "$database$sidecar" "$copy$sidecar"
  done

  # Every posted reply, with the trigger prefix and the lane the run recorded.
  # A run context is cleared when the run finalises, so the lane is often "" and
  # the replay says so rather than guessing.
  sqlite3 -json "$copy" "
    select
      '$host' as host,
      ev.created_at as at,
      ev.episode_id as episode,
      e.effort as effort,
      case when json_valid(cast(a.context_json as text))
           then coalesce(json_extract(cast(a.context_json as text), '\$.lane'), '')
           else '' end as lane,
      e.objective as trigger,
      json_extract(ev.payload_json, '\$.completion.message') as reply
    from work_episode_events ev
    join work_episodes e on e.id = ev.episode_id
    left join agent_runs a on a.id = e.agent_run_id
    where ev.kind = 'completion_submitted'
      and coalesce(trim(json_extract(ev.payload_json, '\$.completion.message')), '') <> ''
    order by ev.created_at
  " >"$scratch/replies-$index.json"

  # Every full message text still reachable in a surviving run context, used to
  # undo the 180-byte cut on the trigger.
  sqlite3 -json "$copy" "
    select distinct json_extract(message.value, '\$.text') as text
    from agent_runs,
         json_each(case when json_valid(cast(agent_runs.context_json as text))
                        then json_extract(cast(agent_runs.context_json as text),
                                          '\$.recent_messages')
                        else '[]' end) as message
    where coalesce(json_extract(message.value, '\$.text'), '') <> ''
    union
    select distinct text from slack_inputs where trim(text) <> ''
  " >"$scratch/pool-$index.json"
done

jq -s 'add' "$scratch"/replies-*.json >"$scratch/replies.json"
jq -s 'add | map(.text)' "$scratch"/pool-*.json >"$scratch/pool.json"

python3 - "$scratch/replies.json" "$scratch/pool.json" "$scratch/corpus.json" <<'PYTHON'
import json
import sys

replies_path, pool_path, corpus_path = sys.argv[1:4]
replies = json.load(open(replies_path))
pool = sorted({" ".join(text.split()) for text in json.load(open(pool_path)) if text})

corpus = []
for reply in replies:
    trigger = reply["trigger"] or ""
    state = "exact"
    if trigger.endswith("..."):
        # The objective was cut. Any pooled message starting with the surviving
        # prefix is a candidate; the word count is settled when they agree on
        # it, which recurring alerts that differ only in a run identifier do.
        candidates = [text for text in pool if text.startswith(trigger[:-3])]
        counts = {len(text.split()) for text in candidates}
        if len(counts) == 1:
            trigger = max(candidates, key=lambda text: len(text.split()))
            state = "recovered"
        else:
            state = "missing"
    reply["trigger"] = trigger
    reply["trigger_state"] = state
    corpus.append(reply)

json.dump(corpus, open(corpus_path, "w"))
print(f"corpus: {len(corpus)} posted replies", file=sys.stderr)
PYTHON

cd "$root"
RESPONDER_REPLY_SHAPE_CORPUS="$scratch/corpus.json" \
  go test ./internal/decision -run '^TestReplyShapeReplay$' -count=1 -v
