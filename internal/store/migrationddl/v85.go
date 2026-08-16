package migrationddl

// V85 gives the outcomes already on disk the alert identity they were written
// without.
//
// Grafana's Slack integration posts a message, not a groupKey, so every
// episode_outcomes row projected from a Slack-delivered alert stored an empty
// alert_group_key — and that column is recall's twelve-point signal, worth more
// than every vocabulary match combined. From the projection's first day this
// meant the alerts that actually wake people up were the only ones recall could
// not recognise. On 2026-08-16 va1-nomad-oom-risk fired on tenant for the fifth
// time; the four earlier investigations, one of which had already produced a
// committed fix, were invisible to it.
//
// The live path now derives the identity from the message. The rows already
// written cannot be re-derived in SQL, because the derivation is a Go function
// over the alert text — but it was ALSO already computed for every one of these
// episodes and stored: watchConversationKey writes
// 'operation:' || channel_id || ':' || OperationalCorrelationKey(input) onto
// the run, precisely so a re-firing alert answers in the same place. Stripping
// that prefix recovers the same string the live path now writes, which is why
// this is a backfill and not a guess.
//
// Bounded at 2000 rows, newest first: the deployments hold a few hundred
// outcomes each, so this reaches all of them, and a database that has somehow
// accumulated more gets the recent history that a recall would actually have
// selected rather than an unbounded rewrite inside a startup migration.
//
// Idempotent by its WHERE clause. It touches only rows whose identity is still
// empty, so a row an operator or a re-projection has since filled is left
// exactly as it is, and re-running changes nothing.
const V85 = `
UPDATE episode_outcomes
SET alert_group_key = (
  SELECT substr(
           run.conversation_key,
           length('operation:' || run.channel_id || ':') + 1
         )
  FROM work_episodes AS episode
  JOIN agent_runs AS run ON run.id = episode.agent_run_id
  WHERE episode.id = episode_outcomes.episode_id
    AND run.channel_id != ''
    AND substr(run.conversation_key, 1, length('operation:' || run.channel_id || ':'))
        = 'operation:' || run.channel_id || ':'
)
WHERE alert_group_key = ''
  AND episode_id IN (
    SELECT episode.id
    FROM work_episodes AS episode
    JOIN agent_runs AS run ON run.id = episode.agent_run_id
    WHERE run.channel_id != ''
      AND substr(run.conversation_key, 1, length('operation:' || run.channel_id || ':'))
          = 'operation:' || run.channel_id || ':'
    ORDER BY episode.updated_at DESC
    LIMIT 2000
  );
`
