package migrationddl

// V80 keeps the export-safe copy of what a turn was actually given.
//
// The prompt text was already being written for every path. Migration 57 added
// context_manifests.submitted_prompt and ensureAttemptContextManifest has filled
// it for every attempt since, so the fuel line did not break at the write. It
// broke at retention. Prune empties submitted_prompt on the OPERATIONAL horizon
// — twenty-four hours — alongside the agent run context it rides with, and the
// survivorship on the tenant database says exactly that: 428 of 1221 manifests
// still hold a prompt, and every one of them was written in the preceding two
// days. Everything older is an empty string beside a digest.
//
// So record-episode and promote-fixtures were never limited to "the engineering
// path". They were limited to yesterday. A correction reviewed on Monday for a
// turn that ran on Friday has no prompt left to harvest, and a fixture_candidate
// pins its episode for precisely the reason that it wants the evidence — while
// the one piece of evidence it needs has already been emptied out from under it.
//
// A sibling table rather than a second column, for three reasons that each
// decided it alone:
//
//   - submitted_prompt is live operational state, not an archive. turn_delta
//     reads it as the standing briefing that decides whether the next turn can
//     be a delta, and the compiled_prompt reference records sha256 of those
//     exact bytes. Sanitizing in place would leave the digest on the trace page
//     no longer matching the text beside it, and would hand the delta decision
//     redacted text to compare against.
//   - The two have different lifetimes on purpose. The transport copy is spent
//     when the turn is; the archive copy is the account of it and lives with the
//     episode. Two clocks on one column is how the current bug happened.
//   - context_manifests is read by the episode page, the usage page and the
//     settings page, none of which want the text. Measured at a p50 of 139 KB
//     and a p90 of 175 KB, it belongs behind a join those readers never make.
//
// Nothing is backfilled. The rows that still hold a prompt hold the RAW one,
// and this table's whole contract is that its contents have been through the
// sanitizer. Copying unredacted text into it would poison that contract on day
// one to buy back two days of history.
//
// ON DELETE CASCADE from context_manifests is the entire retention policy. A
// manifest cascades from work_episodes, which expires on the episode-history
// horizon — the long one, thirty days by default — and refuses to expire while
// anything still pins the episode. That is the horizon the fuel line asked for,
// and inheriting it means there is no second sweep to keep in step with a first.
//
// What it costs, measured on both live deployments before this shipped rather
// than after: tenant freezes ~142 manifests a day at ~132 KB of prompt each, so
// ~19 MB a day, ~131 MB a week, and ~560 MB once the thirty-day horizon fills;
// emisar ~26 a day, ~2 MB a day, ~14 MB a week, ~60 MB filled. That is far more
// than the "MBs/week" the spec projected, and the reason is that the spec's
// premise was a 60 KiB prompt bound which does not apply here: agentprompt caps
// ITS prompts at 60 KiB, but the Coop transport this path uses caps at
// coop.MaxPromptBytes, 256 KiB, and the measured prompts sit just under it. The
// number is the number; it is written down here so the next person reads it
// before the disk does.
const V80 = `
CREATE TABLE context_manifest_texts (
  manifest_id TEXT PRIMARY KEY,
  prompt TEXT NOT NULL,
  created_at TEXT NOT NULL,
  FOREIGN KEY(manifest_id) REFERENCES context_manifests(id) ON DELETE CASCADE
);
`
