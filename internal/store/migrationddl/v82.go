package migrationddl

// V82 gives a publication an owner that is not a room, for the same reason V81
// gave one to an approval.
//
// publications.incident_id is the table's PRIMARY KEY, which is a stronger
// statement than "this publication happened in that room": it says a
// publication IS an incident's, one each, addressable no other way. That is the
// projection §25 phase 5 re-anchors — engineering work is supposed to follow
// pull request, checks, merge and verification from a normal thread, and today
// it cannot, because there is nowhere to put the row.
//
// This migration is the ownership half and not the addressing half. The primary
// key does not move here and neither does the foreign key: publication_followups
// and publication_lifecycle_events both cascade from publications(incident_id),
// every write in publicationstore re-asserts the incidents row under
// sqlutil.ExpectOne, and changing all of that in the same commit that introduces
// the column is how a migration takes a whole capability down with it. What
// lands is the column, filled by the statement that creates a publication and
// refreshed on every new attempt, plus an index — so the episode page can show
// a publication, the trace can follow one, and the addressing change that comes
// later has something to cut over TO.
//
// The backfill and the persist-time fill agree on one rule: a publication
// belongs to the most recent episode-bearing run of its incident. That is the
// work that produced the diff being published. The publish CLICK owns no
// episode of its own — measured on the emisar deployment, publications
// .attempt_input_id joins to no run's source — so keying on the click would
// have bound every publication to nothing.
//
// No foreign key, for V81's reason: work_episodes expires on the episode-history
// horizon and publications on closed-work, so a cascade would let one table's
// clock decide the other's deletions.
const V82 = `
ALTER TABLE publications ADD COLUMN episode_id TEXT NOT NULL DEFAULT '';

UPDATE publications
SET episode_id = COALESCE((
  SELECT run.episode_id FROM agent_runs AS run
  WHERE run.incident_id = publications.incident_id AND run.episode_id != ''
  ORDER BY run.created_at DESC, run.id DESC LIMIT 1
), '')
WHERE episode_id = '';

CREATE INDEX publications_episode_idx
  ON publications(episode_id, updated_at);
`
