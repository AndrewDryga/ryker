package migrationddl

// V61 repairs work episodes split by an idempotent wake-up replay and makes
// the run/attempt episode identity structural.
//
// A replay used to create episode_<run> around the already-stored run, then
// update agent_runs.episode_id without moving its existing episode_attempts
// row. Repeated wake-ups could form chains of these shells. The recursive map
// below collapses every shell into the original episode, carries its history
// and references with it, and re-numbers only the per-episode ordinals whose
// uniqueness necessarily changes during that merge.
const V61 = `
CREATE TEMP TABLE episode_identity_divergence (
  child TEXT PRIMARY KEY,
  parent TEXT NOT NULL
);

INSERT INTO episode_identity_divergence(child, parent)
SELECT episode.id, attempt.episode_id
FROM work_episodes AS episode
JOIN episode_attempts AS attempt
  ON attempt.agent_run_id = episode.agent_run_id
WHERE episode.id != attempt.episode_id;

-- Fail closed unless every divergence has the exact shape emitted by the
-- wake-up replay bug. A random cross-wire is corruption to diagnose, not an
-- episode shell this migration is authorized to merge.
CREATE TEMP TABLE episode_merge_guard (
  valid INTEGER NOT NULL CHECK(valid = 1)
);

INSERT INTO episode_merge_guard(valid)
SELECT CASE WHEN NOT EXISTS (
  SELECT 1
  FROM episode_identity_divergence AS divergence
  WHERE NOT EXISTS (
    SELECT 1
    FROM work_episodes AS child
    JOIN agent_runs AS child_run ON child_run.id = child.agent_run_id
    JOIN episode_attempts AS attempt ON attempt.agent_run_id = child_run.id
    JOIN work_episodes AS parent ON parent.id = divergence.parent
    JOIN agent_runs AS parent_run ON parent_run.id = parent.agent_run_id
    WHERE child.id = divergence.child
      AND child.id = 'episode_' || child_run.id
      AND (
        child.latest_attempt_id = attempt.id
        OR EXISTS (
          SELECT 1 FROM episode_attempts AS latest
          WHERE latest.id = child.latest_attempt_id
            AND latest.episode_id = child.id
        )
      )
      AND child_run.source_kind = 'watch'
      AND substr(child_run.source_id, 1, 15) = 'episode_wakeup_'
      AND EXISTS (
        SELECT 1
        FROM episode_wakeups AS wakeup
        WHERE child_run.source_id = 'episode_wakeup_' || wakeup.id
          AND wakeup.episode_id = divergence.parent
      )
      AND child_run.conversation_key = parent_run.conversation_key
      AND child_run.channel_id = parent_run.channel_id
      AND child_run.thread_ts = parent_run.thread_ts
  )
) THEN 1 ELSE 0 END;

CREATE TEMP TABLE episode_merge_links (
  child TEXT PRIMARY KEY,
  parent TEXT NOT NULL
);

INSERT INTO episode_merge_links(child, parent)
SELECT child, parent FROM episode_identity_divergence;

-- A cycle has no original episode. Detect one before selecting roots, while a
-- failed guard still rolls the whole schema step back to version 60.
WITH RECURSIVE walk(child, ancestor, path, cycle) AS (
  SELECT child, parent,
         '|' || hex(child) || '|' || hex(parent) || '|',
         child = parent
  FROM episode_merge_links
  UNION ALL
  SELECT walk.child, links.parent,
         walk.path || hex(links.parent) || '|',
         instr(walk.path, '|' || hex(links.parent) || '|') > 0
  FROM walk
  JOIN episode_merge_links AS links ON links.child = walk.ancestor
  WHERE walk.cycle = 0
)
INSERT INTO episode_merge_guard(valid)
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM walk WHERE cycle = 1)
            THEN 1 ELSE 0 END;

CREATE TEMP TABLE episode_merge_map (
  child TEXT PRIMARY KEY,
  root TEXT NOT NULL
);

WITH RECURSIVE
walk(child, ancestor, depth, path) AS (
  SELECT child, parent, 1, child || '>' || parent
  FROM episode_merge_links
  UNION ALL
  SELECT walk.child, links.parent, walk.depth + 1, walk.path || '>' || links.parent
  FROM walk
  JOIN episode_merge_links AS links ON links.child = walk.ancestor
  WHERE instr(walk.path, links.parent) = 0
),
ranked(child, root, position) AS (
  SELECT child, ancestor,
         row_number() OVER (PARTITION BY child ORDER BY depth DESC)
  FROM walk
)
INSERT INTO episode_merge_map(child, root)
SELECT child, root FROM ranked WHERE position = 1;

-- Child lifecycle events describe the accidental shell projection, which can
-- conflict with the canonical stream (including a second episode_created or a
-- transition after a terminal state). Preserve their exact payload and key as
-- non-projecting recovery facts before moving them to the root.
UPDATE work_episode_events
SET kind = 'migration_recovered',
    idempotency_key = 'migration:61:recovered:' || id,
    payload_json = json_object(
      'merged_from_episode', episode_id,
      'original_kind', kind,
      'original_idempotency_key', idempotency_key,
      'original_payload_json', payload_json
    )
WHERE episode_id IN (SELECT child FROM episode_merge_map);

-- Preserve repeated events while retaining one original idempotency key. The
-- suffixed copies remain queryable evidence but cannot block a future append.
WITH ranked AS (
  SELECT event.id,
         row_number() OVER (
           PARTITION BY COALESCE(map.root, event.episode_id), event.idempotency_key
           ORDER BY event.created_at, event.id
         ) AS position
  FROM work_episode_events AS event
  LEFT JOIN episode_merge_map AS map ON map.child = event.episode_id
)
UPDATE work_episode_events
SET idempotency_key = idempotency_key || ':merged:' || id
WHERE id IN (SELECT id FROM ranked WHERE position > 1);

-- Claims and fixture candidates are current-state projections, not append-only
-- history. Keep the newest projection when two shells wrote the same key.
WITH ranked AS (
  SELECT claim.id,
         row_number() OVER (
           PARTITION BY COALESCE(map.root, claim.episode_id), claim.claim_id
           ORDER BY claim.updated_at DESC, claim.id DESC
         ) AS position
  FROM claim_assessments AS claim
  LEFT JOIN episode_merge_map AS map ON map.child = claim.episode_id
)
DELETE FROM claim_assessments
WHERE id IN (SELECT id FROM ranked WHERE position > 1);

WITH ranked AS (
  SELECT candidate.id,
         row_number() OVER (
           PARTITION BY COALESCE(map.root, candidate.episode_id),
                        candidate.correction_class
           ORDER BY candidate.updated_at DESC, candidate.id DESC
         ) AS position
  FROM fixture_candidates AS candidate
  LEFT JOIN episode_merge_map AS map ON map.child = candidate.episode_id
)
DELETE FROM fixture_candidates
WHERE id IN (SELECT id FROM ranked WHERE position > 1);

-- A commitment is one promise per episode. Prefer the original episode's
-- title, or the earliest child title if the root somehow lacks one.
INSERT OR IGNORE INTO commitments(episode_id, title)
SELECT map.root, commitment.title
FROM commitments AS commitment
JOIN episode_merge_map AS map ON map.child = commitment.episode_id
JOIN work_episodes AS episode ON episode.id = commitment.episode_id
ORDER BY episode.created_at, episode.id;

DELETE FROM commitments
WHERE episode_id IN (SELECT child FROM episode_merge_map);

-- Move every durable reference. Tables with per-episode ordinals are staged at
-- globally unique negative values before their episode IDs converge.
UPDATE episode_attempts
SET attempt_number = -rowid
WHERE episode_id IN (
  SELECT child FROM episode_merge_map
  UNION SELECT root FROM episode_merge_map
);

UPDATE work_episode_events
SET sequence = -rowid
WHERE episode_id IN (
  SELECT child FROM episode_merge_map
  UNION SELECT root FROM episode_merge_map
);

UPDATE work_episode_progress
SET sequence = -rowid
WHERE episode_id IN (
  SELECT child FROM episode_merge_map
  UNION SELECT root FROM episode_merge_map
);

UPDATE context_manifests
SET version = -rowid
WHERE episode_id IN (
  SELECT child FROM episode_merge_map
  UNION SELECT root FROM episode_merge_map
);

UPDATE agent_runs
SET episode_id = (
  SELECT map.root FROM episode_merge_map AS map
  WHERE map.child = agent_runs.episode_id
)
WHERE episode_id IN (SELECT child FROM episode_merge_map);

UPDATE episode_attempts
SET episode_id = (
  SELECT map.root FROM episode_merge_map AS map
  WHERE map.child = episode_attempts.episode_id
)
WHERE episode_id IN (SELECT child FROM episode_merge_map);

UPDATE claim_assessments
SET episode_id = (
  SELECT map.root FROM episode_merge_map AS map
  WHERE map.child = claim_assessments.episode_id
)
WHERE episode_id IN (SELECT child FROM episode_merge_map);

UPDATE context_manifests
SET episode_id = (
  SELECT map.root FROM episode_merge_map AS map
  WHERE map.child = context_manifests.episode_id
)
WHERE episode_id IN (SELECT child FROM episode_merge_map);

UPDATE episode_goals
SET episode_id = (
  SELECT map.root FROM episode_merge_map AS map
  WHERE map.child = episode_goals.episode_id
)
WHERE episode_id IN (SELECT child FROM episode_merge_map);

UPDATE episode_wakeups
SET episode_id = (
  SELECT map.root FROM episode_merge_map AS map
  WHERE map.child = episode_wakeups.episode_id
)
WHERE episode_id IN (SELECT child FROM episode_merge_map);

UPDATE work_episode_events
SET episode_id = (
  SELECT map.root FROM episode_merge_map AS map
  WHERE map.child = work_episode_events.episode_id
)
WHERE episode_id IN (SELECT child FROM episode_merge_map);

UPDATE work_episode_progress
SET episode_id = (
  SELECT map.root FROM episode_merge_map AS map
  WHERE map.child = work_episode_progress.episode_id
)
WHERE episode_id IN (SELECT child FROM episode_merge_map);

UPDATE conversation_memory_changes
SET episode_id = (
  SELECT map.root FROM episode_merge_map AS map
  WHERE map.child = conversation_memory_changes.episode_id
)
WHERE episode_id IN (SELECT child FROM episode_merge_map);

UPDATE feedback_items
SET episode_id = (
  SELECT map.root FROM episode_merge_map AS map
  WHERE map.child = feedback_items.episode_id
)
WHERE episode_id IN (SELECT child FROM episode_merge_map);

UPDATE fixture_candidates
SET episode_id = (
  SELECT map.root FROM episode_merge_map AS map
  WHERE map.child = fixture_candidates.episode_id
)
WHERE episode_id IN (SELECT child FROM episode_merge_map);

UPDATE scheduled_task_runs
SET episode_id = (
  SELECT map.root FROM episode_merge_map AS map
  WHERE map.child = scheduled_task_runs.episode_id
)
WHERE episode_id IN (SELECT child FROM episode_merge_map);

UPDATE slack_deliveries
SET episode_id = (
  SELECT map.root FROM episode_merge_map AS map
  WHERE map.child = slack_deliveries.episode_id
)
WHERE episode_id IN (SELECT child FROM episode_merge_map);

UPDATE standing_assignment_actions
SET episode_id = (
  SELECT map.root FROM episode_merge_map AS map
  WHERE map.child = standing_assignment_actions.episode_id
)
WHERE episode_id IN (SELECT child FROM episode_merge_map);

UPDATE audit_events
SET object_id = (
  SELECT map.root FROM episode_merge_map AS map
  WHERE map.child = audit_events.object_id
)
WHERE object_id IN (SELECT child FROM episode_merge_map);

UPDATE work_episodes
SET parent_episode_id = (
  SELECT map.root FROM episode_merge_map AS map
  WHERE map.child = work_episodes.parent_episode_id
)
WHERE parent_episode_id IN (SELECT child FROM episode_merge_map);

-- quality_findings stores an array rather than a relational reference. Replace
-- child IDs and collapse duplicates without disturbing first-seen order.
INSERT INTO episode_merge_guard(valid)
SELECT CASE WHEN NOT EXISTS (
  SELECT 1 FROM quality_findings AS finding
  WHERE NOT json_valid(finding.episode_ids)
     OR json_type(finding.episode_ids) != 'array'
     OR EXISTS (
       SELECT 1 FROM json_each(finding.episode_ids) AS item
       WHERE item.type != 'text'
     )
) THEN 1 ELSE 0 END;

UPDATE quality_findings AS finding
SET episode_ids = (
  SELECT json_group_array(mapped.value)
  FROM (
    SELECT COALESCE(map.root, item.value) AS value, MIN(CAST(item.key AS INTEGER)) AS ordinal
    FROM json_each(finding.episode_ids) AS item
    LEFT JOIN episode_merge_map AS map ON map.child = item.value
    GROUP BY COALESCE(map.root, item.value)
    ORDER BY ordinal
  ) AS mapped
)
WHERE EXISTS (
    SELECT 1 FROM json_each(finding.episode_ids) AS item
    JOIN episode_merge_map AS map ON map.child = item.value
  );

-- Re-number the merged histories chronologically. IDs remain unchanged, so all
-- external and cross-table references still identify the original records.
WITH numbered AS (
  SELECT id,
         row_number() OVER (
           PARTITION BY episode_id ORDER BY created_at, id
         ) AS number
  FROM episode_attempts
  WHERE episode_id IN (SELECT root FROM episode_merge_map)
)
UPDATE episode_attempts
SET attempt_number = (SELECT number FROM numbered WHERE numbered.id = episode_attempts.id)
WHERE id IN (SELECT id FROM numbered);

WITH numbered AS (
  SELECT id,
         row_number() OVER (
           PARTITION BY episode_id ORDER BY created_at, id
         ) AS number
  FROM work_episode_events
  WHERE episode_id IN (SELECT root FROM episode_merge_map)
)
UPDATE work_episode_events
SET sequence = (SELECT number FROM numbered WHERE numbered.id = work_episode_events.id)
WHERE id IN (SELECT id FROM numbered);

WITH numbered AS (
  SELECT id,
         row_number() OVER (
           PARTITION BY episode_id ORDER BY created_at, id
         ) AS number
  FROM work_episode_progress
  WHERE episode_id IN (SELECT root FROM episode_merge_map)
)
UPDATE work_episode_progress
SET sequence = (SELECT number FROM numbered WHERE numbered.id = work_episode_progress.id)
WHERE id IN (SELECT id FROM numbered);

CREATE TEMP TABLE context_manifest_order AS
SELECT id, episode_id,
       row_number() OVER (
         PARTITION BY episode_id ORDER BY created_at, id
       ) AS version,
       lag(id) OVER (
         PARTITION BY episode_id ORDER BY created_at, id
       ) AS parent_id
FROM context_manifests
WHERE episode_id IN (SELECT root FROM episode_merge_map);

-- A shell's first manifest began a separate lineage. Linearizing the merged
-- episode therefore requires explicit omissions for parent references that
-- were not carried into that context; copying the content would invent what
-- the model saw, while an omission records the truth and satisfies lineage.
WITH missing AS (
  SELECT current.id AS manifest_id, parent_ref.kind, parent_ref.source_ref,
         parent_ref.content_digest, parent_ref.source_revision,
         parent_ref.visibility,
         row_number() OVER (
           PARTITION BY current.id ORDER BY parent_ref.ordinal, parent_ref.id
         ) AS missing_ordinal
  FROM context_manifest_order AS current
  JOIN context_manifest_refs AS parent_ref
    ON parent_ref.manifest_id = current.parent_id
   AND parent_ref.omitted_reason = ''
  WHERE NOT EXISTS (
    SELECT 1
    FROM context_manifest_refs AS existing
    WHERE existing.manifest_id = current.id
      AND existing.source_ref = parent_ref.source_ref
      AND (
        existing.content_digest = parent_ref.content_digest
        OR existing.omitted_reason != ''
      )
  )
)
INSERT INTO context_manifest_refs (
  id, manifest_id, kind, source_ref, content_digest, source_revision,
  visibility, ordinal, omitted_reason, metadata_json
)
SELECT
  'context_ref_merge_v61_' || missing.manifest_id || '_' ||
    printf('%04d', missing.missing_ordinal),
  missing.manifest_id, missing.kind, missing.source_ref,
  missing.content_digest, missing.source_revision, missing.visibility,
  COALESCE((
    SELECT MAX(existing.ordinal) FROM context_manifest_refs AS existing
    WHERE existing.manifest_id = missing.manifest_id
  ), 0) + missing.missing_ordinal,
  'not included in recovered split-episode context', '{}'
FROM missing;

UPDATE context_manifests
SET version = (
      SELECT ordered.version FROM context_manifest_order AS ordered
      WHERE ordered.id = context_manifests.id
    ),
    parent_manifest_id = COALESCE((
      SELECT ordered.parent_id FROM context_manifest_order AS ordered
      WHERE ordered.id = context_manifests.id
    ), '')
WHERE id IN (SELECT id FROM context_manifest_order);

UPDATE agent_runs
SET attempt_id = (
      SELECT attempt.id FROM episode_attempts AS attempt
      WHERE attempt.agent_run_id = agent_runs.id
    ),
    attempt_number = (
      SELECT attempt.attempt_number FROM episode_attempts AS attempt
      WHERE attempt.agent_run_id = agent_runs.id
    )
WHERE id IN (
  SELECT attempt.agent_run_id
  FROM episode_attempts AS attempt
  WHERE attempt.episode_id IN (SELECT root FROM episode_merge_map)
);

-- Preserve the root's original identity but advance its aggregate high-water
-- marks and timestamps across the merged history.
UPDATE work_episodes AS root
SET latest_attempt_id = (
      SELECT attempt.id FROM episode_attempts AS attempt
      WHERE attempt.episode_id = root.id
      ORDER BY attempt.attempt_number DESC LIMIT 1
    ),
    event_sequence = COALESCE((
      SELECT MAX(event.sequence) FROM work_episode_events AS event
      WHERE event.episode_id = root.id
    ), 0),
    progress_sequence = COALESCE((
      SELECT MAX(progress.sequence) FROM work_episode_progress AS progress
      WHERE progress.episode_id = root.id
    ), 0),
    updated_at = COALESCE((
      SELECT MAX(episode.updated_at)
      FROM work_episodes AS episode
      LEFT JOIN episode_merge_map AS map ON map.child = episode.id
      WHERE episode.id = root.id OR map.root = root.id
    ), root.updated_at)
WHERE root.id IN (SELECT root FROM episode_merge_map);

-- The split projected the latest attempt's lifecycle onto its child shell.
-- Restore that exact projection for nonterminal roots. A successful transport
-- attempt may legitimately leave work waiting or blocked, so the shell state,
-- phase, action, deadline, and completion time are authoritative here. Record
-- the repair as a real phase event and progress row so replay agrees with the
-- stored projection; an existing terminal root always wins.
CREATE TEMP TABLE episode_projection_repairs AS
WITH candidates AS (
  SELECT root.id,
         owner.lifecycle_state,
         owner.phase,
         owner.status,
         owner.next_action,
         owner.progress_due_at,
         owner.completed_at,
         COALESCE(owner.completed_at, owner.updated_at) AS event_at,
         row_number() OVER (
           PARTITION BY root.id ORDER BY owner.updated_at DESC, owner.id DESC
         ) AS position
  FROM work_episodes AS root
  JOIN episode_attempts AS attempt ON attempt.id = root.latest_attempt_id
  JOIN work_episodes AS owner ON owner.latest_attempt_id = attempt.id
  JOIN episode_merge_map AS map
    ON map.child = owner.id AND map.root = root.id
  WHERE root.id IN (SELECT root FROM episode_merge_map)
    AND root.lifecycle_state NOT IN (
      'completed', 'failed', 'refused', 'cancelled', 'superseded'
    )
)
SELECT
  id, lifecycle_state, phase, status, next_action, progress_due_at,
  completed_at, event_at
FROM candidates
WHERE position = 1;

INSERT INTO work_episode_events (
  id, episode_id, sequence, kind, actor, idempotency_key, payload_json, created_at
)
SELECT
  'episode_event_repair_v61_' || repair.id,
  repair.id,
  root.event_sequence + 1,
  'phase_changed',
  'host',
  'migration:61:projection:' || repair.id,
  json_object(
    'state', repair.lifecycle_state,
    'phase', repair.phase,
    'status', repair.status,
    'next_action', repair.next_action,
    'progress_due_at', repair.progress_due_at
  ),
  repair.event_at
FROM episode_projection_repairs AS repair
JOIN work_episodes AS root ON root.id = repair.id;

INSERT INTO work_episode_progress (
  id, episode_id, sequence, phase, summary, created_at
)
SELECT
  'episode_progress_repair_v61_' || repair.id,
  repair.id,
  root.progress_sequence + 1,
  repair.phase,
  repair.status,
  repair.event_at
FROM episode_projection_repairs AS repair
JOIN work_episodes AS root ON root.id = repair.id;

UPDATE work_episodes AS root
SET lifecycle_state = (
      SELECT repair.lifecycle_state FROM episode_projection_repairs AS repair
      WHERE repair.id = root.id
    ),
    phase = (
      SELECT repair.phase FROM episode_projection_repairs AS repair
      WHERE repair.id = root.id
    ),
    status = (
      SELECT repair.status FROM episode_projection_repairs AS repair
      WHERE repair.id = root.id
    ),
    next_action = (
      SELECT repair.next_action FROM episode_projection_repairs AS repair
      WHERE repair.id = root.id
    ),
    progress_due_at = (
      SELECT repair.progress_due_at FROM episode_projection_repairs AS repair
      WHERE repair.id = root.id
    ),
    event_sequence = event_sequence + 1,
    progress_sequence = progress_sequence + 1,
    last_progress_at = (
      SELECT repair.event_at FROM episode_projection_repairs AS repair
      WHERE repair.id = root.id
    ),
    updated_at = (
      SELECT repair.event_at FROM episode_projection_repairs AS repair
      WHERE repair.id = root.id
    ),
    completed_at = (
      SELECT repair.completed_at FROM episode_projection_repairs AS repair
      WHERE repair.id = root.id
    )
WHERE root.id IN (SELECT id FROM episode_projection_repairs);

DELETE FROM work_episodes
WHERE id IN (SELECT child FROM episode_merge_map);

-- SQLite requires a unique parent key for a composite foreign key. Rebuild the
-- attempts table under that key so neither side can ever drift independently.
CREATE UNIQUE INDEX IF NOT EXISTS agent_runs_episode_identity_idx
  ON agent_runs(id, episode_id);

DROP TRIGGER IF EXISTS work_episode_latest_attempt_insert_guard;
DROP TRIGGER IF EXISTS work_episode_latest_attempt_update_guard;

CREATE TABLE episode_attempts_rebuilt (
  id TEXT PRIMARY KEY,
  episode_id TEXT NOT NULL,
  agent_run_id TEXT NOT NULL UNIQUE,
  attempt_number INTEGER NOT NULL,
  state TEXT NOT NULL CHECK (state IN (
    'pending', 'leased', 'running', 'succeeded', 'failed', 'cancelled'
  )),
  failure_class TEXT NOT NULL DEFAULT '',
  failure_generation INTEGER NOT NULL DEFAULT 0,
  lease_owner TEXT NOT NULL DEFAULT '',
  fencing_token INTEGER NOT NULL DEFAULT 0,
  lease_expires_at TEXT,
  context_manifest_id TEXT NOT NULL DEFAULT '',
  started_at TEXT,
  completed_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(episode_id, attempt_number),
  FOREIGN KEY(episode_id) REFERENCES work_episodes(id) ON DELETE CASCADE,
  FOREIGN KEY(agent_run_id, episode_id)
    REFERENCES agent_runs(id, episode_id) ON DELETE CASCADE
);

INSERT INTO episode_attempts_rebuilt (
  id, episode_id, agent_run_id, attempt_number, state, failure_class,
  failure_generation, lease_owner, fencing_token, lease_expires_at,
  context_manifest_id, started_at, completed_at, created_at, updated_at
)
SELECT
  id, episode_id, agent_run_id, attempt_number, state, failure_class,
  failure_generation, lease_owner, fencing_token, lease_expires_at,
  context_manifest_id, started_at, completed_at, created_at, updated_at
FROM episode_attempts;

DROP TABLE episode_attempts;
ALTER TABLE episode_attempts_rebuilt RENAME TO episode_attempts;

CREATE INDEX episode_attempts_episode_idx
  ON episode_attempts(episode_id, attempt_number);
CREATE INDEX episode_attempts_lease_idx
  ON episode_attempts(state, lease_expires_at, updated_at);

-- latest_attempt_id cannot be a foreign key because work_episodes and attempts
-- are mutually created, so guard the same-episode half explicitly.
CREATE TRIGGER IF NOT EXISTS work_episode_latest_attempt_insert_guard
BEFORE INSERT ON work_episodes
WHEN NEW.latest_attempt_id != '' AND EXISTS (
  SELECT 1 FROM episode_attempts AS attempt
  WHERE attempt.id = NEW.latest_attempt_id AND attempt.episode_id != NEW.id
)
BEGIN
  SELECT RAISE(ABORT, 'work episode latest attempt belongs to another episode');
END;

CREATE TRIGGER IF NOT EXISTS work_episode_latest_attempt_update_guard
BEFORE UPDATE OF latest_attempt_id ON work_episodes
WHEN NEW.latest_attempt_id != '' AND EXISTS (
  SELECT 1 FROM episode_attempts AS attempt
  WHERE attempt.id = NEW.latest_attempt_id AND attempt.episode_id != NEW.id
)
BEGIN
  SELECT RAISE(ABORT, 'work episode latest attempt belongs to another episode');
END;

INSERT INTO episode_merge_guard(valid)
SELECT CASE WHEN NOT EXISTS (
  SELECT 1
  FROM episode_attempts AS attempt
  JOIN agent_runs AS run ON run.id = attempt.agent_run_id
  WHERE attempt.episode_id != run.episode_id
) AND NOT EXISTS (
  SELECT 1
  FROM work_episodes AS episode
  JOIN episode_attempts AS attempt ON attempt.id = episode.latest_attempt_id
  WHERE episode.latest_attempt_id != '' AND episode.id != attempt.episode_id
) AND NOT EXISTS (
  SELECT 1
  FROM work_episodes AS episode
  WHERE episode.latest_attempt_id != '' AND NOT EXISTS (
    SELECT 1 FROM episode_attempts AS attempt
    WHERE attempt.id = episode.latest_attempt_id
  )
) THEN 1 ELSE 0 END;

DROP TABLE episode_projection_repairs;
DROP TABLE context_manifest_order;
DROP TABLE episode_merge_map;
DROP TABLE episode_merge_links;
DROP TABLE episode_identity_divergence;
DROP TABLE episode_merge_guard;
`
