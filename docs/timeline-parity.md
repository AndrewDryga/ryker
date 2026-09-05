# Episode timeline parity

Source comparison: 2026-09-05. Legacy reference: `internal/webui/trace.go` and
`internal/webui/templates/episode.html`. Current reference:
`lib/responder/control_plane/{episode_trace,episode_page,model_requests,request_page,request_context_html}.ex`.
This compares the human-facing episode timeline, not whole-product backend parity.

## Fixed in the current increment

- One aligned timeline rail across input, event and request rows. Legacy
  `.case-message` margins no longer move message rows off the rail.
- Source-labelled instruction and context sections, using the saved prompt's
  `instructions`, `work` or `context` fields. Work input is not taken from the
  neighboring submission-context copy. Instructions are never reconstructed
  from today's code. The schema remains a separately supplied artifact.
- Host instructions, conversation inputs, recalled history, operator guidance,
  tool catalogs and runtime controls have distinct labels, source paths and
  explanatory text. Empty fields and unfamiliar fields remain visible; scope
  and provenance are not inferred from source-message text.
- Section disclosure state survives live refresh. Redaction, truncation,
  artifact hashes and unavailable/expired states remain explicit.

These are labelled decoded views of retained fields, not a byte-for-byte
segmentation of the complete provider system prompt. The sanitized raw prompt
remains accessible. Coop/provider-owned wrappers are not retained by this view.

## Remaining gaps

| Priority | Feature | What Go showed | Current limitation / needed work |
| --- | --- | --- | --- |
| P1 | Prompt composition and budget | Source-colored final text, per-source approximate tokens, budget usage/headroom and trimming reasons | Source labels are restored, but no composition bar or per-source size/token inventory; a context truncated by the inline display bound falls back to raw text. Preserve layer boundaries when truncating and distinguish model-budget omissions from UI truncation. |
| P1 | Context selection and recall | Separate memory, related conversations, past episodes, open tasks and recent changes; selected/not-sent/trimmed status and selection explanations | Current fields have source explanations, not a per-item retrieval/selection ledger. Some old context layers are absent from the Elixir prompt builder, not merely hidden by UI. Don't recreate old data or claim an absent layer was searched. |
| P1 | Human-readable outcomes and changes | Typed operation/evidence tables, expandable rows, before/after side effects, specific delivery and audit presentations | Current event rendering is mainly summary plus label/value details. Candidate, validation, contract and delivery bodies largely remain raw documents. Add dedicated renderers with links to evidence, goals, approvals and actual receipts. |
| P1 | Timing and inactivity | Relative time per step, step durations, visible quiet stretches and usage breakdown | Current chapters show relative ranges and request results show queue/execution/host time. Per-event `duration_ms` is projected but not displayed by the native page; no quiet-gap markers or queue-to-first-visible-output explanation. |
| P1 | Cost | Provider-reported and configured token-priced estimates, measurement coverage and episode summaries | Current page shows reported own cost only, often unknown. Restore explicitly labelled estimates with versioned rates, then per-attempt/child-work attribution. Never show missing cost as zero. |
| P1 | Public model/tool detail | Rich retained turn/tool context and typed results where captured | Current tool starts/completions are paired, but most bodies, plan changes and public streamed output lack rich inline presentation or capture. A completion event is not a result body. Private reasoning is deliberately excluded, not a parity target. |
| P2 | Waits, triggers and recovery explanation | Scheduled/resolved waits with matchers, deadlines and matching observations; reason, attempted remedies and explicit next step | Current lifecycle and records are present, but wait payloads and causal links often remain generic details; native stopped panels need more precise per-state unblock instructions. |
| P2 | Deduplication and trace density | Suppressed redundant model/manifest/lifecycle/answer records and folded simple attempts | Current continuous feed still repeats some source, kernel, request, result and delivery facts. Fold duplicates without erasing separate acceptance and delivery receipts. |
| P2 | End-state review and related records | Visible reviewer/note, stale review state and inline confirmation; meaningful cross-links | Current top actions expose review/recovery routes, but the native footer mostly shows identity and review time. Surface the ending being reviewed, reviewer/note, stale state, and typed relationships inline. |
| P2 | Complete historical navigation | Retained/archive distinctions and replay provenance throughout the trace | Current inline history is bounded (20 work turns, 20 inputs, 20 admission attempts); older requests require the separate paged inspector. Add explicit load-older navigation and stronger within-timeline request/source anchors without losing bounded reads. |

Already present: one continuous chronological feed, explained chapters, exact
retained request inspection, validation attempts, goal/progress/evidence records,
tool lifecycle pairing, delivery status, recovery links and LiveView updates.
Their presence should not be confused with full typed-rendering parity.
