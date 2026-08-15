package migrationddl

// V81 gives an Emisar approval an owner that is not a room.
//
// `incident_id` has been the only thing on this row that said which work the
// approval belonged to, and it is nullable — because a configured operator may
// ask for one exact action in any Slack conversation, and most of them do. The
// column is therefore empty exactly when the question "what work is this?" is
// hardest to answer, and every projection keyed on it (the remediation record,
// the postmortem's approval list, the retention sweep that follows a closed
// incident) simply cannot see a thread-scoped approval at all.
//
// The host has always known the answer. Section 25's phase 5 is the change that
// writes it down: approval ownership moves to the episode id, and incident_id
// stays for what it is actually good at — naming the room that showed the card,
// when there is one.
//
// Both halves of the backfill are needed because `source_input` holds two
// different kinds of identifier depending on which path requested the action.
// A watch turn stores the Slack input id; an incident or engineering-task turn
// stores the agent run id (persistAgentReport is called with run.ID there). One
// UPDATE per shape, in that order, and neither overwrites a row the other
// already resolved.
//
// Measured before it shipped: on the emisar deployment every retained approval
// resolves through the watch shape, and on tenant there are none retained at all
// — emisar_approvals expires on the OPERATIONAL horizon, which is why fixtures
// for this capability have to be harvested within days and cannot be recovered
// afterwards. Rows the backfill cannot resolve keep the empty string, which is
// the honest answer for an approval whose originating run has already been
// pruned, and is what ListForEpisode's empty-id guard exists to refuse.
//
// No foreign key, deliberately. work_episodes expires on the episode-history
// horizon and emisar_approvals on the operational one, so the two clocks
// disagree by design; a cascade would let the longer-lived table dictate
// deletions in the shorter-lived one, and a RESTRICT would let a pruned
// approval block an episode from ever expiring.
const V81 = `
ALTER TABLE emisar_approvals ADD COLUMN episode_id TEXT NOT NULL DEFAULT '';

UPDATE emisar_approvals
SET episode_id = COALESCE((
  SELECT run.episode_id FROM agent_runs AS run
  WHERE run.source_kind = 'watch' AND run.source_id = emisar_approvals.source_input
    AND run.episode_id != ''
  ORDER BY run.created_at DESC, run.id DESC LIMIT 1
), '')
WHERE episode_id = '';

UPDATE emisar_approvals
SET episode_id = COALESCE((
  SELECT run.episode_id FROM agent_runs AS run
  WHERE run.id = emisar_approvals.source_input AND run.episode_id != ''
), '')
WHERE episode_id = '';

CREATE INDEX emisar_approvals_episode_idx
  ON emisar_approvals(episode_id, created_at);
`
