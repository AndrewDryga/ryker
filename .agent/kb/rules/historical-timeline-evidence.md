# Historical timeline evidence

A historical card answers what was known at that point, not what the request
knows now. Keep current summaries explicitly separate from historical events.

- Render a briefing from its own frozen submission. Later messages, settings,
  findings, goals and reviews cannot replace or enrich that evidence.
- A new turn consuming several inputs belongs after the latest input it
  actually selected, and lists every consumed input. Late receipts retain their
  original turn ownership; an unrelated new message cannot acquire them.
- Completion reviews belong to their exact parent turn, not an ambient cursor.
- A retry follows a visible saved outcome: worker failure, rejected answer,
  stale evidence or cancellation. Missing reasons stay explicitly unknown.
  Do not imply the model rejected an answer when no judgment was produced.
- Earlier labels must not depend on a future attempt count. New attempts add
  cards; they do not rewrite the earlier heading.
- Every model-call kind needs readable evidence sections and exact prompt-part
  attribution. Unknown fields stay visible as unknown, never silently dropped.
- Truncated snapshots are partial. Do not reconstruct their omitted middle or
  query live records to populate a historical disclosure. Retained tool
  observations reuse tool components without live artifact lookups.
- System inputs need readable intent, verification and timing, not raw actor IDs
  or a claim that an event with structured content has no body.

Regressions: `episode_causality_test.exs`, `model_requests_test.exs`,
`prompt_document_test.exs`, `request_context_html_test.exs`, `source_text_test.exs`
and `work/completion_review_history_test.exs`. Run their focused checks, then the gate.

Recorded 2026-10-26 after a multi-input resume was filed above the human message
it contained, while failed independent reviews showed only timings.
