package migrationddl

// V77 adds the remediation trust ladder's one durable record.
//
// Remediation was read-only everything plus exactly one exact,
// operator-requested action through Emisar's approval workflow — the right
// floor and also the ceiling. This table is what lets the ceiling move by
// increments a person confirms: one row says that for THIS alert group, in THIS
// channel, THIS exact Emisar action may be offered at THIS rung until THIS
// date. Nothing about it is inferred at read time.
//
// The identity is six columns and the unique index over all of them, because
// every one of them is part of what was granted. action_id alone would let a
// grant earned restarting one job on one runner cover the same action pointed
// at another fleet; pack_ref pins the version and digest the behaviour came
// from, so an upgraded pack is a new action that has earned nothing yet. The
// alert group key and channel are the other half: authority earned on one alert
// says nothing about the next one in the same room. Repository is nullable-ish
// (empty is real) and narrows further when the trigger belongs to one.
//
// expires_at is NOT NULL with no default on purpose. Every other durable record
// here can reasonably be permanent; authority cannot, and the one way to
// guarantee that is to make a row without an expiry impossible to write rather
// than merely discouraged. Renewal is one click.
//
// success_count is the host's own recomputed count at the moment of
// confirmation, stored so the card and the audit trail can say what the
// promotion rested on. It is never the number a model reported, and it is never
// read back as authority — the matcher reads rung and expires_at and nothing
// else. demoted_reason and demoted_at record the automatic side of the ladder,
// which needs no one's permission and must leave a trail anyway.
//
// Rows are kept after they lapse. A grant that quietly disappeared would make
// "why did Responder stop offering this" unanswerable, and the volume is one
// row per alert-and-action pair a person deliberately confirmed.
const V77 = `
CREATE TABLE remediation_grants (
  id TEXT PRIMARY KEY,
  alert_group_key TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  repository TEXT NOT NULL DEFAULT '',
  action_id TEXT NOT NULL,
  pack_ref TEXT NOT NULL,
  runner_ref TEXT NOT NULL,
  rung TEXT NOT NULL CHECK (rung IN ('observe', 'propose', 'one_click', 'auto')),
  granted_by TEXT NOT NULL,
  granted_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  success_count INTEGER NOT NULL DEFAULT 0,
  last_verified_at TEXT,
  demoted_reason TEXT NOT NULL DEFAULT '',
  demoted_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(alert_group_key, channel_id, repository, action_id, pack_ref, runner_ref)
);

CREATE INDEX remediation_grants_match_idx
  ON remediation_grants(channel_id, alert_group_key, expires_at);
`
