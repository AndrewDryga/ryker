# Review Ryker's behavior

Read this before selecting improvements. The unit of review is a request and what Ryker
actually did for it, including later corrections. A completed turn, accepted response or
delivered message is not proof that the request was handled well.

## Inspect the trajectory

Start with explicit corrections, repeated questions, unfinished commitments, unnecessary
approval requests and costly or slow work. Also inspect ordinary delivered answers and
apparently successful requests: error logs cannot reveal a confident but unhelpful answer.
For a small window, review every retained trajectory. Otherwise describe the sample and
include distinct work types and outcomes; do not select only failures or only the latest reply.

For each reviewed case, establish from retained evidence:

- What the person wanted, their constraints and the authority they had already given.
- What Ryker knew at that point: the frozen submission, available tools and recalled memory.
- What it actually did: routing, calls and results, attempts, waits and corrections.
- What reached the person and what outcome it established; distinguish a draft from delivery.
- What the person had to repeat, correct, approve or fetch afterward, and whether that was
  necessary. Later knowledge must not be treated as something Ryker already knew.

Use these questions to look for improvement, not to manufacture scores:

| Dimension | What to examine | Possible change in Ryker |
|---|---|---|
| Understanding | Did it preserve the request and followups, distinguish questions from actions, and honor constraints? | Context selection, routing, instruction wording |
| Evidence and tools | Did it retrieve available facts, use the right tools, verify claims and state uncertainty? | Tool discovery/integration, retrieval, evidence presentation |
| Follow-through | Did it finish authorized work, respect a real human block, and resume after the awaited event? | Host state handling, prompts, scheduling or delivery |
| Communication | Was the answer useful and concise? Did status and next steps reflect reality? | Response instructions, UI or status handling |
| Learning | Did it repeat a corrected mistake, miss relevant memory or use stale advice? | Recall, memory review, provenance or instructions |
| Efficiency | Did repeated calls, oversized context, retries or model choice add cost without improving the result? | Context budgets, tool design, model/settings changes |

Keep raw case notes private and temporary. Save pseudonymized findings and source identities
through the existing ledger. Do not write automated judgments as human feedback or ratings.
Missing frozen inputs or tool traces are unknowns; record a gap rather than attributing blame.

## Trace the cause and choose a change

Separate three cases. A valid result mishandled by the host needs a deterministic code
regression. Poor decisions despite adequate instructions, context and tools need a prompt,
settings or model investigation and an appropriate eval. Missing evidence or capabilities
may need context selection, retrieval, an integration or a concrete operator prerequisite.
Do not add a new control loop merely because a prompt was weak; do not try to prompt around
a host bug. Follow `AGENTS.md` for the actual validation boundary.

Each proposal must connect its existing fields to the behavior:

- `example`: the observed behavior and consequence, with a real source identity.
- `baseline`: affected requests over reviewed eligible requests, or an explicit small-sample
  limitation; distinguish repeated log lines from distinct user outcomes.
- `change`: the specific Ryker code, prompt, tool, setting or workflow to change and why it
  could address the cause. Identify uncertainty as an investigation.
- `verification`: replay or eval the recorded case, then compare eligible subsequent traffic
  for the desired behavior and regressions. Include user effort, useful completion, latency
  or cost as appropriate; do not treat fewer visible errors as better work.

Preserve genuine approval boundaries. Fewer interruptions must not mean bypassing required
human decisions. Better completion must not mean forcing replies or retries while blocked.

Before selecting work, state which dimensions have actual trace evidence and which remain
unreviewed. Fix urgent Ryker outages when needed; record partial behavioral coverage if that
consumes the pass. Do not describe an operations-only pass as a completed behavioral review.

## Coverage after a rubric change

Older inventory receipts do not prove this trajectory review happened. When adopting this
rubric after an inventory-only pass, register a distinct staged source such as
`ryker-behavior-review-v1` at run start and backfill the retained interval. Stage only compact
case identities, versions, reviewed dimensions and evidence-availability facts through the
existing external-source protocol. Keep the original work/feedback evidence linked to each
finding. Explicitly mark sampling or missing trajectories as partial coverage; do not relabel
the old receipts or reset an active pass to evade its limits.

The closing report should explain what Ryker could do better, the proposed changes, and what
is proven versus still unmeasured. List Ryker reliability repairs separately. Recommendations
for systems Ryker monitors belong to the separately requested operational review.
