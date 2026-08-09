package store

// schemaV51 removes the waiting events that were written once per second.
//
// DeferAgentRun used to build its idempotency key from the next attempt time,
// so a run polling once a second produced a unique key every second and
// appended a phase_changed event every second. Migration 50 shipped alongside
// the fix to the emitter, and the collapsing the control plane does at read
// time; neither touches what is already on disk. On the deployed databases that
// is 5,483 rows on tenant — 47% of its entire episode event stream, 4,632 of
// them inside one hour — and 328 on emisar, every one of them carrying the
// identical payload "waiting for the previous agent run in this Slack channel".
//
// The read-time fold made those timelines legible; it did not make them cheap.
// Every page view still reads and discards thousands of rows, every backup
// copies them, and anyone reaching for sqlite directly — which is how "why did
// it say that" has actually been answered here — still has to scroll past them.
// So they are deleted where they live.
//
// One row survives per episode and per run, not one per episode. An episode
// runs several attempts when the host sends work back, each attempt is its own
// agent run, and each one waiting is a separate fact about a separate attempt.
// Keeping only the earliest per episode would report three waits as one; on
// tenant the difference is 16 surviving rows rather than 12. The earliest is the
// one kept because it is the row that says when the waiting began, which is the
// only thing the repeats ever added to.
//
// The survivor keeps its historical timestamped key. Rewriting it to the shape
// the fixed emitter now writes would let a still-blocked episode's next defer
// collide with it instead of appending one more row, which is worth exactly one
// row per episode — not worth changing the recorded identity of a durable event
// for, and not worth the UNIQUE(episode_id, idempotency_key) collision handling
// that rewriting keys in bulk would need.
//
// Deleting events leaves gaps in work_episode_events.sequence. That is safe and
// checked: the next sequence comes from work_episodes.event_sequence, the
// aggregate's own high-water mark, never from MAX(sequence) over this table, so
// no future insert can collide with a deleted number. Every reader — the store,
// the control plane, the lifecycle divergence probe — orders by sequence and
// none requires it to be contiguous.
//
// Nothing here rebuilds a table, so migration 51 is not in
// tableRebuildMigrations. work_episode_events is a leaf: it is the child of
// work_episodes and no table references it, so deleting rows cascades nowhere.
// Running it twice deletes nothing the second time, and on a database that
// never wrote a timestamped key it matches no rows at all.
const schemaV51 = `
DELETE FROM work_episode_events
WHERE kind = 'phase_changed'
  AND idempotency_key LIKE 'agent-run:%:deferred:%'
  AND sequence > (
    SELECT MIN(first.sequence)
    FROM work_episode_events AS first
    WHERE first.episode_id = work_episode_events.episode_id
      AND first.kind = 'phase_changed'
      AND first.idempotency_key LIKE 'agent-run:%:deferred:%'
      AND substr(first.idempotency_key, 1, instr(first.idempotency_key, ':deferred:'))
        = substr(
            work_episode_events.idempotency_key,
            1,
            instr(work_episode_events.idempotency_key, ':deferred:')
          )
  );
`
