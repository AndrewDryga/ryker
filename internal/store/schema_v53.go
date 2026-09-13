package store

// schemaV53 gives a standing rule a durable record of what its fires produced.
//
// trigger_count counts fires and says nothing about outcomes, and the only
// place an outcome was ever written — standing_rule_runs — expired on the
// operational horizon, which is twenty-four hours in both deployments. The
// result is that no standing rule could be judged. blitz's alert-triage rule
// reports 41 fires with zero surviving rows; emisar's Terraform rule reports 64
// fires with two, both of them 'ignore'. An operator asking "is this earning its
// keep, and should I keep it" had a number that goes up whether the rule works
// or fires constantly and does nothing, and no way to tell those apart.
//
// Two counters rather than one because "how many fires produced nothing" is the
// half of the answer that condemns a rule, and it has to be a count rather than
// an inference: acted_count + quiet_count is the number of fires whose outcome
// was actually recorded, which is not the same as trigger_count and must never
// be presented as if it were. Every fire from before this migration is a fire
// whose outcome nobody kept, and a surface that showed "0 acted of 41" would be
// inventing 41 observations it does not have.
//
// Quiet is 'ignore' and 'shadowed'. Ignore is the rule matching a message and
// deciding it was not worth answering; shadowed is a channel being watched
// before Ryker is allowed to speak in it, so the fire is silent by design.
// Everything else — reply, react, incident, engineering_task — put something in
// front of a person, which is the only thing a standing rule exists to do.
//
// The backfill can see only the rows that survived the twenty-four-hour sweep,
// which is the whole problem restated: it is two rows on emisar and none on
// blitz. It runs anyway because those rows are the only evidence that exists,
// and starting the counters at the evidence is more honest than starting them
// at zero and pretending the fortnight before was never observed.
//
// ADD COLUMN with a constant default, for the reason migrations 48, 49 and 52
// spell out: SQLite fills existing rows in place, so no table is rebuilt and no
// row is copied. Nothing here belongs in tableRebuildMigrations. No column here
// ends in _at, deliberately: migration 46 rewrites every stored timestamp to a
// fixed width and cannot rewrite a column that will not exist for another seven
// versions, so a durable "when did it last act" would have to be either exempt
// from that rule or padded by a second mechanism. Recency is read from
// standing_rule_runs instead, which now survives long enough to answer it — and
// "it has not acted inside the retained window" is a better sentence than a
// timestamp from last spring.
const schemaV53 = `
ALTER TABLE standing_rules ADD COLUMN acted_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE standing_rules ADD COLUMN quiet_count INTEGER NOT NULL DEFAULT 0;

UPDATE standing_rules SET
  acted_count = (
    SELECT count(*) FROM standing_rule_runs
    WHERE rule_id = standing_rules.id AND outcome NOT IN ('ignore', 'shadowed')
  ),
  quiet_count = (
    SELECT count(*) FROM standing_rule_runs
    WHERE rule_id = standing_rules.id AND outcome IN ('ignore', 'shadowed')
  );
`
