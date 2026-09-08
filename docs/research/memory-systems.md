# Memory systems: research and pragmatic Responder design

Research date: **2026-09-08**. Responder source inspected: **f664a3e10c8eec85cbbfea9feba5bc94ad0bcd62**.

Status: research baseline and design rationale. The approved build, subsequent Fable reviews,
implementation progress and qualification boundaries are tracked in the
[implementation specification](../memory-implementation-spec.md); this research document itself
is not a deployment or qualification claim.
Use this document before changing learning, recall, summaries, context packing, or memory retention.
Read the decision summary first, then the relevant evidence and acceptance cases. Recheck code
and dated external claims before implementation. This document does not override host policy,
the checked runtime contracts, or [AGENTS.md](../../AGENTS.md).

## 1. Decision summary

Build an attentive engineering teammate, not a transcript summarizer and not an autonomous
memory research platform. It should notice decisions without replying, connect related work,
remember why a service is intentionally disabled, investigate using current code and telemetry,
and distinguish a proposed change from one actually deployed. Remembering is not authorization.

The smallest credible direction is:

1. Keep PostgreSQL, the existing learning/topic/history owners, and Coop execution.
2. Separate **learning**, **responding**, and **acting**. Silence must not prevent learning;
   learning must not create permission to speak or act.
3. Maintain a small current understanding per subject, with source-linked changes and original
   context available on demand. Do not turn every message into a durable memory.
4. Stop disclosing unrelated topics just to fill the context budget. Every disclosed source can
   influence an update: moving receipts into rows cannot cure indiscriminate inheritance.
5. Make the existing background learning lane the **only topic writer**. Admission keeps source
   observations and response/action decisions; remove its topic proposal/write in the same cut.
6. Make silent skips and implicit topic resets explicit failures; then repair source membership,
   lexical recall, category diversity, and pagination using existing PostgreSQL owners.
7. Evaluate longitudinal behavior, freshness, privacy, cost, and action outcomes. More records,
   a successful model call, and a memory-QA benchmark score are not product success.

**Do not adopt now:** a vector database, graph database, universal entity ontology, automatic
system-prompt rewriting, learned operational permissions, or a separate reflection model call
on every incoming message. None is necessary to fix the established defects.

**Reconsider later:** model-visible omission hints after a demonstrated discoverability miss;
embeddings inside existing PostgreSQL if measured paraphrase misses survive lexical/identity
improvements; finer dependency granularity if coarse invalidation causes unacceptable availability;
procedural automation after manually reviewed examples improve held-out work. Cross-transport
knowledge sharing requires a separate explicit authorization design. These are not prerequisites
for repairing passive learning and recall.

Sections 3–4 are the research catalogue, not a list of features to implement. The bounded next
build is in section 8.2. Fable's review materially reduced that build and exposed additional
source-code defects; the disposition is recorded in section 9.

### Navigation

- [Evidence and limits](#2-evidence-and-limits)
- [Systems worth learning from](#3-systems-worth-learning-from)
- [Failures and things to avoid](#4-failures-and-things-to-avoid)
- [Current Responder baseline](#5-current-responder-baseline)
- [Proposed product behavior](#6-proposed-product-behavior)
- [Storage and authorization](#7-storage-and-authorization)
- [Evaluation and implementation order](#8-evaluation-and-implementation-order)
- [Fable review](#9-fable-review)
- [Source register](#10-source-register)

## 2. Evidence and limits

Labels in this document:

- **Implemented/documented:** inspected source or official product documentation establishes a
  mechanism. It does not establish reliability in our workload.
- **Experiment:** paper authors report a result in a specified setup. Not independently reproduced
  here; not a universal ranking or proof of unattended production safety.
- **Issue report:** a first-hand public report with a version/reproduction. Not independently
  reproduced here, and not a claim that every version or hosted product has that defect.
- **Local evidence:** inspected Responder code or the retained September 7 replay audit. The audit
  is historical evidence, not a fresh production database measurement.
- **Proposal/inference:** our engineering judgment, requiring the tests below.

The supplied Letta handoff was a starting point, not treated as current implementation truth.
Its pinned checkout still exists and matches `2f0fb7c12c6973be7d52d9c7d3bf0bf4d9120cb8`.
Recall and reflection prompts were reread. Current public documentation was fetched separately;
its MemFS layout differs from the pinned reflection prompt. Do not mix those versions into an
imaginary single implementation. The old `letta-ai/letta` repository currently directs users to
Letta Code and labels its V1 server archive unsupported. [L1–L4](#10-source-register)

Research covered Letta, Claude Code, local Codex memory, GitHub Copilot Memory, Devin,
LangGraph/LangMem concepts, Mem0, Zep/Graphiti, Hindsight, Cleric, incident.io, and relevant
evaluation/security papers.
It is a targeted architecture comparison, not an exhaustive vendor audit. No competitor was
installed into Responder, and no cross-vendor benchmark was run.

Public OpenAI documentation establishes background extraction/consolidation for **local Codex**,
and explicitly distinguishes that store from ChatGPT web memory. It does **not** establish a
complete public specification of ChatGPT's internal dreaming implementation. Here, “dreaming”
means bounded asynchronous consolidation/reflection, not a claim to reproduce those internals
or to update model weights. [O1](https://learn.chatgpt.com/docs/customization/memories)

## 3. Systems worth learning from

### Letta: progressive disclosure and selective reflection

**Documented:** current MemFS keeps selected files in context and exposes a file tree for deeper
on-demand reads. Default memory-file lookup does not require a vector index. Conversation search
is a separate facility. The pinned recall prompt recommends finding a message, then expanding
before/after it with dates and cursors. [L2](https://docs.letta.com/concepts/memfs),
[L3](https://github.com/letta-ai/letta-code/blob/2f0fb7c12c6973be7d52d9c7d3bf0bf4d9120cb8/src/agent/prompts/recall_subagent.md)

The pinned reflection prompt prioritizes corrections, skips ephemeral/duplicate material, prefers
updating existing memory, and allows no change. Reusable procedures are exceptional, not the
default output. Current dreaming docs offer background review; their optional second agent
review is **not human approval**. [L4](https://github.com/letta-ai/letta-code/blob/2f0fb7c12c6973be7d52d9c7d3bf0bf4d9120cb8/src/agent/subagents/builtin/reflection-v2.md),
[L5](https://docs.letta.com/configuration/memory)

**Adopt:** progressive disclosure; find-then-expand; corrections as learning triggers;
update-before-create; no-op as success. **Do not copy:** Git as runtime memory custody, worktree
orchestration, automatic executable skill edits, or a globally exposed memory tree. Those do not
fit Responder's transactional ownership and Slack/GitHub disclosure boundaries.

The 2025 sleep-time article explicitly identifies latency and multitasking problems when one agent
handles conversation and memory housekeeping together. Its reported experiments and old two-agent
architecture are historical, not evidence that today's implementation or our SRE workload is
qualified. Moving computation out of the response path can improve latency without reducing total
compute. [L6](https://www.letta.com/blog/sleep-time-compute/)

### Claude Code: remember the non-obvious, not another copy of the repository

**Documented:** auto memory separates user, feedback, project, and reference notes; it avoids
material readily derived from code or already in project instructions. A bounded `MEMORY.md`
index loads at startup; topic files load on demand. The documentation acknowledges index limits,
conflicting instructions, and lack of hard enforcement by remembered prose.
[A1](https://code.claude.com/docs/en/memory)

**Adopt:** remember rationale, corrections, intended operating state, and where to find evidence.
A note that says “check this deployment configuration before treating zero replicas as failure”
can be more useful than another stale inventory dump. **Avoid:** copying single-developer
filesystem trust into multi-person channels. For Responder, source deletion and audience access
must propagate to derived material; a Markdown file's existence is not an authorization check.

Anthropic's context-engineering guidance supports concise, sufficient context and non-overlapping
tools. “Small” must not mean deleting the information needed to do the job. Our inference is to
provide a compact situation brief plus working retrieval tools, not a growing book of prompt
exceptions. [A2](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)

### Local Codex: idle-time extraction and consolidation with controls

**Documented:** eligible prior chats can become local memory in the background; active/short-lived
sessions are skipped, idle time matters, and quota can gate generation. Generation and use have
separate controls, with extraction and consolidation settings. Required team rules belong in
checked-in guidance rather than only generated memory. [O1](https://learn.chatgpt.com/docs/customization/memories)

**Adopt:** debouncing, separate read/write controls, resource-aware scheduling, and distinguishing
generated recall from required policy. **Avoid:** assuming “background” means immediate visibility
or free computation. Responder needs observable learning progress and recent-source fallback
while consolidation is behind; a new model-visible watermark is not required initially.

### GitHub Copilot Memory: validate remembered code facts against today's code

**Documented:** repository facts have code citations that are checked against the current branch
before use. Repository knowledge and user preferences have different scopes. The documented
unused-entry policy is 28 days, potentially renewed by validated use; the feature remains labelled
public preview. [G1](https://docs.github.com/en/copilot/concepts/agents/copilot-memory)

**Adopt:** current-branch validation, source links, and distinct personal/team scopes. **Do not
copy:** the retention duration or read-renews-lifetime rule. A rarely used disaster-recovery
decision can be extremely valuable; a repeatedly retrieved error can be extremely harmful.
Historical rationale and current code facts also need different freshness semantics.

### Devin: small, triggered knowledge and reviewed corrections

**Documented:** knowledge items have retrieval triggers, can be scoped/pinned, and are intended
to stay focused. Chat feedback can produce suggestions to create or update an item; users can
edit or dismiss them. [D1](https://docs.devin.ai/product-guides/knowledge)

**Adopt:** “when this matters” as part of guidance; reviewable changes to existing procedures;
explicit controls for disabling bad guidance. **Avoid:** loading every team instruction into
every task, or making an operator approve every ordinary topic update. Review belongs at the
promotion-to-guidance/procedure boundary, not in the passive listening path.

### LangGraph/LangMem: the useful distinction is ownership, not terminology

**Documented:** thread state and cross-thread memory have different owners/namespaces. A single
growing profile can become error-prone to rewrite; a collection improves granularity but creates
insertion/update and retrieval problems. Background writes avoid response-path work but create
freshness and trigger-design problems. [LG1](https://docs.langchain.com/oss/python/concepts/memory)

**Adopt:** compact per-subject records between one giant profile and one note per message;
explicit tradeoff between prompt freshness and background cost. **Avoid:** another framework or
state store. Responder already owns resumable work and durable memory. A namespace is useful
organization, but is not by itself a complete authorization model.

### Mem0: compare candidates before choosing add, update, or no-op

**Experiment:** the paper's pipeline extracts candidate facts and compares them with retrieved
existing memories before selecting an operation. Its LoCoMo evaluation reports efficiency gains
and a relatively small overall gain from the graph extension, with additional overhead. These
are the authors' results under their models, baselines, and judge—not a current vendor ranking.
[M1](https://arxiv.org/html/2504.19413v1)

**Adopt:** explicit update/no-op decisions and a measured plain-storage baseline before graphs.
**Avoid:** automatically treating contradiction as permission to delete history, or assuming a
top-k search proves that no matching fact exists. An exact identity lookup must not depend on
whether a vector candidate happened to rank highly.

The TypeScript SDK issue #7123 reports duplicate accumulation with whole-turn embeddings,
hard-coded top-10 comparison, and unrelated candidates. The reporter's larger-window workaround
reduced but did not eliminate duplicates. It concerns the reported SDK/version, not all Mem0
deployments. [M2](https://github.com/mem0ai/mem0/issues/7123)

### Zep/Graphiti: temporal meaning is worth borrowing; the graph is optional

**Experiment/design:** Zep distinguishes event time from ingestion time, preserves source links,
and represents periods during which facts hold. Its paper combines several retrieval strategies,
entity resolution, and community summaries. It also notes that incrementally maintained
communities drift and require refresh. [Z1](https://arxiv.org/html/2501.13956v1)

**Adopt:** explicit source/event time, validity/correction chronology, and exact entity anchors.
**Avoid:** a graph database, global entity extraction, community refreshes, or LLM-generated
relations unless simpler retrieval demonstrably fails. Later ingestion alone must not override
an earlier explicit decision: an old event can arrive late.

Graphiti issue #1734 reports exact-name duplicates because embedding-only candidate retrieval
excluded the matching entity before deterministic matching ran. This is a useful failure pattern,
not a reproduced finding against today's hosted Zep. Exact scoped identifiers should have their
own indexed path; even identical names do not justify merging different real entities.
[Z2](https://github.com/getzep/graphiti/issues/1734)

### Hindsight: distinguish evidence, derived understanding, and reflection

**Experiment:** Hindsight separates world facts, agent experiences, derived summaries, and beliefs;
its authors report strong long-horizon QA results. That separation is useful even without copying
its four-network architecture. [H1](https://arxiv.org/abs/2512.12818v1)

**Documented:** `recall` is retrieval; `reflect` adds an agentic synthesis loop. They have different
costs and budget semantics. Retention keeps original text alongside extracted knowledge, and
consolidation reconciles observations. These are vendor-described mechanisms, not our latency
measurements. [H2](https://hindsight.vectorize.io/blog/2026/07/24/recall-vs-reflect),
[H3](https://hindsight.vectorize.io/blog/2026/07/13/inside-retain-agent-memory)

**Adopt:** cheap evidence retrieval first; occasional synthesis; original-source expansion;
derived understanding clearly labelled. **Avoid:** a second answering agent inside every memory
read, or treating an extracted “fact” as ground truth merely because its source was retained.

### AI SRE products: remember investigations, not just incident summaries

**Documented:** Cleric describes investigation memory as prior hypotheses, evidence, useful and
failed paths, outcomes, and engineer corrections—not just major-incident postmortems. Its own
warning is that a weak prior diagnosis, changed environment, or misleading similarity can make
reuse dangerous. This is a vendor-described product model, not an independent quality evaluation.
[C1](https://cleric.ai/glossary/what-is-investigation-memory)

**Adopt:** retain what was checked, what it ruled out, and what a human corrected. A prior failed
check can save time only when its conditions still apply. **Avoid:** “same alert, same cause” and
creating a second incident database. Responder's episode/outcome evidence should remain the owner.

**Documented:** incident.io provides compact investigation/postmortem retrieval and a deeper export
of checks, findings, conversation, and evidence, alongside current telemetry access.
[I1](https://docs.incident.io/ai/remote-mcp)

**Adopt:** make remembered conclusions expandable into the actual investigation, and combine
history with current diagnostics. **Avoid:** confusing incident status metadata with the evidence
needed to explain a cause. This does not justify installing another runtime or importing all
investigations into every prompt.

### Research ideas to test, not architectures to import

- **SimpleMem:** structured compression, merging related context, and query-sensitive retrieval
  are promising. “Semantic lossless compression” is the authors' framing, not a guarantee that
  arbitrary future SRE questions retain their answers. Preserve original sources and test omissions.
  [P1](https://arxiv.org/abs/2601.02553v3)
- **ACE:** identifies brevity bias and progressive loss during whole-context rewriting, and uses
  structured incremental updates. Borrow change-oriented maintenance and test preserved facts;
  do not import its whole generation/reflection/curation stack or let learned playbooks rewrite
  operational authority. [P2](https://arxiv.org/abs/2510.04618v3)
- **LongMemEval:** tests extraction, cross-session reasoning, time, updates, and abstention.
  Its reported failures show why a large context window alone is not a memory acceptance test.
  [P3](https://arxiv.org/abs/2410.10813v2)
- **LongMemEval-V2:** adds workflow knowledge, changing environment state, gotchas, and premise
  awareness. Its file-searching agent improves accuracy with substantial latency cost; even its
  reported best average is far from perfect. It is a work-in-progress benchmark, not proof of
  SRE autonomy. [P4](https://arxiv.org/abs/2605.12493v1)
- **WhenLoss:** separates evidence lost during writing from evidence stored but not retrieved.
  Its fixed-budget experiments often found the write side more limiting. Use that diagnostic
  split before buying a better retriever. [P5](https://arxiv.org/abs/2605.24579v1)
- **MINJA:** demonstrates memory poisoning through interaction without direct database access.
  Historical text can become a persistent attack carrier. Source attribution is necessary but
  does not establish truth or authority. [P6](https://arxiv.org/abs/2503.03704v5)

### Counterevidence that changes the design

LongMemEval's experiments found that replacing retained interaction units with extracted summaries
or facts generally hurt QA through information loss, although fact decomposition helped its
multi-session questions. Its error analysis also found substantial failures after correct retrieval.
Therefore, “better summaries” and “better search” are not interchangeable, and neither can replace
testing the reader. Use compact knowledge to navigate, while preserving expansion into original
interactions. [P3, sections 5.2 and E.5](https://arxiv.org/html/2410.10813v2)

WhenLoss explicitly warns that its oracle-to-stored-memory gap is not pure proof of deletion: lost
contextual cues or mismatched presentation can also impair the reader. Use the diagnostic to locate
a failure, then inspect the exact missing evidence/format before assigning a root cause. Its reported
examples include lost dates and negation—precisely the details that distinguish “do not deploy”
from “deploy.” [P5, section 3.2 and appendix A.6](https://arxiv.org/html/2605.24579v1)

There is also a useful caution in Hindsight's own illustrative extraction: enthusiasm about an
opportunity is interpreted as the reason for a decision. Our assessment is that this causal step
needs evidence or an inference label. A quote, schema, or supporting-record count cannot by itself
prove a motive or root cause. Never let repeated derived records turn that inference into an
apparently corroborated operational fact. [H3](https://hindsight.vectorize.io/blog/2026/07/13/inside-retain-agent-memory)

## 4. Failures and things to avoid

The remedies below are Responder proposals inferred from the evidence above and local failures.

| Temptation or failure | Why it fails | Smallest useful response |
|---|---|---|
| Summarize every message into a memory | Repeats the log, preserves noise, makes retrieval and updates harder | Retain sources; write only a meaningful change to a subject; no-op is normal |
| One giant team summary | Rewrites erase exceptions, mix unrelated topics and permissions | Small subject records plus source history |
| Bigger context window fixes memory | Availability of text does not ensure retrieval or correct use | Measure evidence selection and answer behavior separately |
| Top-k similarity is entity identity | The actual duplicate may never reach comparison | Exact scoped IDs first; lexical aliases and bounded semantic judgment second |
| Full slots mean better context | Unrelated topics distract and enlarge inherited dependencies | Leave unused budget empty |
| Only learn after replying | Quiet decisions and shadow-mode traffic never become knowledge | Independent learning eligibility and durable progress |
| Reflect on everything repeatedly | Cost, lag, self-reinforcement, and endless rewritten summaries | Dirty subjects, coalescing, bounded retries, explicit no-op |
| Latest text always wins | Late delivery, speculation, and alert state are not the same as an authoritative correction | Preserve who said what, when, and with which evidence |
| A successful tool call proves recovery | A command can succeed while the service is still broken | Verify the requested outcome and current operational evidence |
| Delete a contradictory memory | Erases why a decision changed and can hide extraction mistakes | Append an attributable correction; retain eligible history |
| Frequently recalled means useful | Retrieval can amplify a wrong belief | Separate exposure counts from outcome-quality feedback |
| Rename expired material to keep it | Launders revoked sources through summaries or new IDs | Preserve dependency validity and earliest applicable lifetime |
| Raise 128 to a bigger constant | Delays the next cliff; does not fix cross-topic inflation | Remove irrelevant disclosure and fix source representation |
| Store full source closure per revision | A one-source-per-update sequence grows quadratically | Incremental membership with immutable version semantics |
| Build a knowledge graph first | Adds extraction, entity resolution, synchronization, traversal, and repair burdens | Ordinary relational IDs/links until measured multi-hop failures justify more |
| “Approved by another agent” means safe | The reviewer can share the same false premise | Host authority checks, testable evidence, human review for policy/procedure promotion |
| Silence on all uncertainty | Avoids useful autonomous work, not just risk | Investigate with permitted reads; act within explicit standing authority; escalate a precise missing prerequisite |

Public issue reports are test ideas, not proof that installing another vendor would fail.
Likewise, a vendor benchmark win does not establish source revocation, tenant isolation,
duplicate-free updates, crash recovery, or safe Slack/infra behavior. None of the cited papers
qualifies Responder to act unattended.

## 5. Current Responder baseline

Verified in the source revision above; local links identify owners, not future APIs:

| Area | What exists / what needs changing |
|---|---|
| Listening | [Admission](../../lib/responder/admission.ex) can apply observations and knowledge with its decision; do not repeat the outdated claim that ignore always prevents learning |
| Separate learning | [Learning](../../lib/responder/state/learning.ex) persists frozen learning-only judgments; its retry bound currently covers only one error class per exact batch; [Application](../../lib/responder/application.ex) does not wire a learning runtime |
| Search | [FixedTools](../../lib/responder/state_tools/fixed_tools.ex) already exposes `search_memory`; fact → guidance → continuity category order spends the limit; dispatch returns a nil cursor |
| Selection | [Knowledge](../../lib/responder/state/knowledge.ex) has ranked full-text related selection, but fills remaining slots from recent unrelated heads; explicit search is substring matching, not that full-text path |
| Prompt fit | [SubmissionBuilder](../../lib/responder/work/submission_builder.ex) drops optional observations/knowledge to fit the budget without equivalent retrieval hints |
| Topic history | [KnowledgeRevision](../../lib/responder/state/knowledge_revision.ex) and [ConversationMemory](../../lib/responder/control_plane/conversation_memory.ex) already exist; do not rebuild history |
| Source accounting | [LearningSources](../../lib/responder/state/learning_sources.ex) merges flattened receipts under 128-source/65,536-byte caps; [KnowledgeSnapshot](../../lib/responder/state/knowledge_snapshot.ex) tracks session disclosures and reauthorization |
| Summary capacity | `KnowledgeSnapshot.session_sources` reads at most 129 exposures then merges; [Continuity](../../lib/responder/state/continuity.ex) can skip a summary when it lacks a valid merged source set |
| Expansion | [Slack capability tools](../../lib/responder/slack/capability_tools.ex) already provide search and source/thread reads; bridge to these rather than add another Slack history service |
| Confirmed knowledge | [Memories](../../lib/responder/state/memories.ex) and [Behaviors](../../lib/responder/state/behaviors.ex) own confirmation and scope; learning must not bypass them |
| Execution | [Work contract](../elixir-work-runtime.md): episodes can contain multiple inputs/turns; shared knowledge does not require sharing an execution session or guarantee provider cache reuse |
| Cross-transport knowledge | `Knowledge.visible_query` requires equal `workspace_ref`; [Continuity](../../lib/responder/state/continuity.ex) assigns different Slack/GitHub workspace namespaces. This topic-recall path does not currently bridge the two transports |
| Exact topic anchors | [KnowledgeUpdate](../../lib/responder/state/knowledge_update.ex) has a topic key and prose but no indexed external-identity field; source URLs in text are not an existing exact-match topic index |

### Local failures this design must actually fix

The retained September 7 audit inspected 17 real revisions/prompts/results and 44 associated raw
inputs at the stopped 370-batch replay boundary. It found useful maintained human decisions **and**
two concrete failures:

- **One incident split:** an existing topic with 127 inherited receipts plus three new receipts
  did not fit. Its acknowledgment was written to another head. Resolution then updated a head
  that had not seen the acknowledgment. Same incident identity, inconsistent current knowledge.
- **Useful history lost:** a WAL topic needed only 20 roots with its new input, but six unrelated
  offered heads inflated its dependencies to 126. The next input overflowed; capacity rebasing
  replaced current understanding with the latest interval. Old revisions survived, but current
  useful context did not.
- **Positive control:** a human proposal followed by an explicit keep decision remained one
  evolving topic without inventing completed engineering work.
- **Not yet tested:** the HAProxy firing/resolution pair was retained but beyond the applied
  prefix. Its absence was not deleted raw data and was not a successful consolidation test.

Private evidence: `knowledge-370-sources-ERzPNI/REVIEW.md` and `offline-checks.json` under
`/private/tmp/responder-adversarial-Vylg4X`. Do not publish raw customer transcripts or IDs in
this research document. Preserve the private evidence before those temporary artifacts vanish.
The descriptions above preserve the failure mechanisms without making the document depend on
temporary files for its architectural conclusions.

### Additional code findings checked after Fable's review

These are source-path findings, not newly reproduced production incidents:

| Finding | Mechanism and consequence | Owning source |
|---|---|---|
| Disclosure amplification | Learning inherits every offered topic's roots into every proposed update. Unrelated fallback makes topic dependencies converge toward unrelated channel history. Per-item validation locks and checks those roots; relational storage alone does not bound that work | [Learning](../../lib/responder/state/learning.ex), [Knowledge](../../lib/responder/state/knowledge.ex), [LearningSources](../../lib/responder/state/learning_sources.ex) |
| Silent capacity loss | `save_update` returns success when the merged receipts do not fit; capacity omissions can authorize a new generation without prior understanding. Summary persistence also returns success on an unsourced result | [Knowledge](../../lib/responder/state/knowledge.ex), [Continuity](../../lib/responder/state/continuity.ex) |
| Observation loss/amplification | Admission observation notes inherit its whole disclosed context, including older notes. If required context still cannot fit after optional items are removed, dependencies become nil and `write_source` drops the proposed note while retaining the source row. A source row is not proof that observation prose survived | [LearningSources.freeze/fit](../../lib/responder/state/learning_sources.ex), [Observations.write_source](../../lib/responder/state/observations.ex) |
| Compaction starvation risk | An over-capacity group returns `:skipped` without removing its summaries. Such groups can repeatedly occupy the oldest-100 window and prevent later eligible work; this needs a deterministic regression, not a claim that every skip starves all work | [Continuity.compact_locked/complete_compaction](../../lib/responder/state/continuity.ex) |
| Late-event loss | An update whose source `occurred_at` precedes the head's `latest_source_at` returns success without writing. Transport edit-time semantics still need a harvested test | [Knowledge.apply_update](../../lib/responder/state/knowledge.ex) |
| Retry-budget holes | Only `output_contract_failed` contributes to the failure count; host-rejected duplicate topic keys use another code. Changing one input changes the exact batch key and starts a different counter | [Learning.new_attempt/parse_updates/mark_failed](../../lib/responder/state/learning.ex) |

No implementation or execution test was performed for these findings in this research task.

## 6. Proposed product behavior

Everything in this section is a proposed contract, not current shipped behavior.

### 6.1 Three decisions, not one

```text
Authorized Slack/GitHub event → retain source revision
                              ├─ learning eligible → mark subject/conversation dirty
                              │                      → bounded consolidation → knowledge
                              └─ response/action admission → existing episode/Work policy

New request → recent authorized context + relevant knowledge
            → search / expand / verify current code and telemetry → answer or governed action
```

Every authorized source is accounted for even when no long-term memory is produced. Human
decisions must not require a bot mention. Attachment-only alerts must not look like empty input.
Ignore unsupported/duplicate transport events deterministically, but do not discard a novel
human decision because a heuristic classified its channel as low value.

Shadow mode uses the same read/learning path but cannot post, react, type, upload, publish a PR,
or mutate infrastructure. Learning should not create an artificial Work episode solely to make
it visible. Its own receipt should show processed, no useful change, changed topics, deferred,
or failed. Shadow findings are private proposals, not delivered alerts.

### 6.2 What to remember

Keep existing owners; these are product categories, not six new databases:

| Information | Example | Treatment |
|---|---|---|
| Original source | Message, attachment, PR event, code revision, tool result | Retained evidence with exact source identity, access, and time |
| Active work | Accepted request, pending approval, promised check | Existing episode/wait/schedule state, not a vague memory note |
| Subject understanding | Why a service is disabled; migration decision and unresolved concern | Small evolving topic with attributable revisions |
| Confirmed fact/guidance | Team-approved operating convention | Existing confirmation and scope mechanisms |
| Reusable procedure | A diagnostic sequence with conditions and verified outcomes | Reviewed runbook/skill/test change; never self-granted authority |
| Transient chatter | Thanks, duplicated alert payload, already-known fact | Source remains eligible history; no durable topic update required |

Subject prose should answer: **what is understood now, why, what changed, what remains uncertain,
and where to verify it**. Preserve decisions, reasons, exceptions, and unsuccessful approaches.
Do not force every update into a large ontology or create open questions for every conceivable
unknown. An open loop needs a real unresolved decision/commitment relevant to future work.

### 6.3 Subject identity, conversations, and incident lifecycles

Source payloads often contain exact issue/PR/resource identifiers, but the current topic schema
does not index them. Start with relevant lexical selection and existing topic keys. Where the
harvested split case needs an external identity, add one bounded `anchors` field/index, not a
global entity service. Host-normalize transport identities and require proposed anchors to be
supported by an eligible input; invented model aliases must not become canonical identities.

An exact authorized anchor match should survive ranked-search truncation. It is a candidate,
not proof that two things are identical: a monitor identifies a recurring condition, not one
incident occurrence. Scope resource identity to repository/environment/transport as appropriate.
Literal appearance in a message proves neither ownership nor permission to disclose another
resource. Ambiguous matches remain separate until evidence supports merging.

Keep **subject**, **incident occurrence**, **conversation**, and **execution episode** distinct.
Learning that two conversations concern one service does not attach them to one Coop session.
Do not infer the same incident from a shared service or similar alert text.

**Current limit:** Slack and GitHub topic recall have different workspace namespaces. An explicit
PR link is not enough to bypass that boundary. First repair learning within existing scopes.
Cross-transport shared knowledge remains a required product follow-up, with host-approved
repository/workspace mappings, destination disclosure checks, and its own privacy tests. Until
then, use only independently authorized source-reading capabilities; do not claim unified memory.

There is a narrower existing bridge: episode-routed GitHub review feedback is retained as a
private source under its destination conversation, which may be Slack, without an Inbox entry
([Observations.record_publication_feedback_in_transaction](../../lib/responder/state/observations.ex)).
That grants access to the routed conversation, not general Slack/workspace recall. Do not broaden
it during deduplication. The initial Inbox-driven learner does not consume these separate lifecycle
events; including them needs an explicit adapter with the same source/privacy contract.

### 6.4 Cheap recall, then source expansion

Extend `search_memory`, do not create a competing recall path. Use PostgreSQL lexical ranking and
exact identifiers first. Reserve room for relevant results from different kinds rather than always
letting facts exhaust the budget before knowledge. Do not claim raw scores from unrelated indexes
are directly comparable; deterministic rank fusion or per-kind quotas are simple candidates to test.

Return a compact title/claim, kind, relevant source time, scope, correction/currentness status,
and a host-issued reference that can reach the original retained context. Reuse Slack readers;
resolve GitHub references through existing authorized capabilities where available. Otherwise
return an explicit unavailable expansion, not a fabricated original or an unrestricted URL fetch.

Search dates must name their meaning: source event time, knowledge change time, and confirmation
time are different. “What did we decide Tuesday?” is about the event/decision, not retrieval time.
Resolve relative dates against source time/timezone where known, not the replay clock.

Implement bounded keyset pagination tied to query, filters, and effective scope. No transaction
held across model calls. Use stable ordering fields unaffected by recall accounting. Define a
snapshot watermark or reject invalidated cursors; reauthorize every page. Page size must bound
database effort and encoded output, not just the number of visible rows.

**Deferred experiment:** a small model-visible index of relevant omitted topics may improve
discoverability. Existing host omission receipts are not automatically safe model context. First
test whether working search/source readers suffice. Add hints only for a demonstrated miss, with
an explicit byte budget, source-exposure accounting, and full/continuation tests. They must not
leak titles, existence, counts, or queued future instructions. Operator inspection of a frozen
briefing remains useful independently of whether the model gets such an index.

### 6.5 Dreaming as ordinary bounded maintenance

Use one durable work lane owned by Responder, backed by existing learning runs/custody patterns.
Do not assume a module named Learning proves that automatic scheduling exists.

**One topic writer:** remove admission's topic proposal from its prompt/schema and its topic write
when this lane is introduced. Admission still writes source observations and owns response/action
decisions. The background lane consumes **Inbox entry revisions with their single raw-source
receipt**, plus deliberately selected current topics. It does not disclose admission observation
documents. Current `Learning.input_document`, `LearningSources.for_entry`, and `Knowledge.raw_sources`
already implement that distinction: raw text is not the derived note that shares its source row.
Any offered topic still contributes all its inherited roots. Update callers, contracts, and tests
together: no inline fallback and no second writer kept “temporarily.” Authorized observations and
current inputs remain immediate context for admission/Work, under their full disclosure accounting.

Initial trigger:

- Newly retained eligible conversation revisions, including silent input and explicit corrections.
  Completed-work/procedure reflection is a later trigger, not another initial loop.

Coalesce nearby inputs; claim a bounded batch after quiet time, with a maximum delay so a busy
channel cannot starve forever. Scope scheduling by conversation/repository; select and write
only the relevant subjects. Use an ingestion/revision high-watermark, not an event-time cutoff,
so retries do not reread the entire workspace. Edits/deletions need their own revision identity;
an old message edit is new work even when its original event timestamp is earlier.

A pass proposes small attributable topic changes or no-op. Supply the relevant existing topic
and sources, not every recent topic. Preserve
untouched decisions and reasons; reject stale expected versions and retry from a fresh bounded
snapshot. No model call or remote work while holding a database transaction open.

Workers need durable deduplication, leases/recovery, backoff, workspace cost/concurrency limits,
and visible backlog age. Count schema and host-semantic rejections, not just one provider error.
A failed multi-input result does **not** identify a culpable message. Do not label or quarantine
one input as poisoned merely because it appeared in a failing batch.

The minimal proposed accounting unit is the **frozen claimed batch**, with a separate conversation
circuit breaker/workspace spending bound. Once execution starts, new input belongs to a different
claim; it must not refresh the failed claim's allowance. Exhaustion visibly defers the whole claim,
preserving its inputs for explicit retry/review, while independent later claims can proceed.
No automatic regrouping of deferred inputs under a fresh key to evade the budget. A source edit
invalidates the old claim as appropriate; newly eligible revisions still face the aggregate budget.
This bounds attempts without pretending to diagnose which message caused an invalid result.

Before implementation, define treatment of provider outages, semantic rejection, and pre-disclosure
staleness, plus the deliberate retry/recovery control. If deferring a whole batch loses too much
useful learning, evaluate bounded batch splitting under the **same total budget**. Do not add that
complexity preemptively or assert that per-input causal attribution already exists.

Crash after provider response but before application must reuse recorded custody where valid,
not create unbounded fresh jobs. Advance ingestion/revision progress only with an applied, no-op,
or explicit deferred/exhausted receipt; record outstanding failures separately. Do not advance a
source-event timestamp and silently skip late arrivals. Late evidence can update historical
understanding without overriding a newer corrected current state.

Do not periodically reflect over reflections without new evidence. Keep generated context labelled
and do not count the bot repeating itself as independent corroboration. Duplicate/syndicated alerts
also are not multiple independent sources of truth.

**Freshness gap:** recent authorized raw context remains available while learning catches up.
A new request must not answer confidently from a summary that predates a visible correction.
Reuse current-input/observation/source readers first, and test that an old edit or rapid correction
is reachable. The worker needs durable progress accounting; a new watermark in every model prompt
does not follow from that requirement. If relevant recent context does not fit, retrieve it or
report the specific limitation rather than silently treating stale knowledge as current.

No separate “dreaming service” or scheduled all-memory rewrite is needed. Tune coalescing delay,
batch sizes, and budgets against replay cost/lag, rather than declaring arbitrary constants to be
universal defaults. Pausing learning must be explicit and observable, not silent data loss.

### 6.6 Later option: procedural learning without self-modifying authority

This is retained as a research direction, not a new worker in the first build. Start with a few
manually reviewed cases through existing proposal/confirmation and repository review workflows.
From a correction/outcome, ask: what specific future behavior should change, under what conditions,
and what evidence demonstrates improvement? Prefer updating an existing runbook or test. No-op
is valid even after a successful substantial episode.

- Host mishandles a valid result → harvested deterministic regression and code review.
- Model behavior is wrong → reviewed prompt/contract evaluation case.
- Repeatable diagnostic lesson → scoped procedure with prerequisites, stop conditions, and checks.
- Operational fact or behavioral guidance → existing proposal/confirmation path.

A reaction, acknowledgment, settled turn, or model-written success claim is not a verified outcome.
Proposed procedures cannot install themselves, rewrite host prompts, schedule operational work,
or gain tool permissions. Ordinary derived subject updates need no new human approval gate.

### 6.7 Acting like a strong engineer

These are acceptance expectations for existing [Work](../elixir-work-runtime.md) and governed
action ownership, not a new memory-owned planner, scheduler, or permission system.

Before treating an anomaly as failure, compare **intended state, deployed state, observed state,
and user impact**. Memory guides where to look; live reads establish the relevant current facts.

For an intentionally downscaled service: recover the decision, inspect the applicable code/ref,
check what is actually deployed, then interpret zero instances in that context. A stale local
checkout alone is not proof of deployed intent. If deployment evidence is unavailable, report the
specific uncertainty rather than asserting either an outage or perfect health.

For a resolved OOM alert: update that incident's alert status without inventing application recovery.
For a PR: proposed, approved, merged, deployed, and verified are distinct states. For a failed
diagnostic: remember the failed approach and its conditions so the next investigation can improve.

Proactivity should detect meaningful changes, unresolved accepted commitments, contradictions,
or repeated failures. Feed candidates into existing admission/Work/wait/schedule mechanisms.
Deduplicate proposals and respect quiet/suppression policy. Act without asking again when a
standing policy already grants the exact authority; otherwise ask for the missing decision.
Do not implement “always ask” as a substitute for reliable bounded autonomy.

### 6.8 Operator experience

Keep existing memory/review pages; these are usability criteria, not a separate dashboard project.

Memory pages should show current understanding first, followed by why it changed, source links,
corrections/history, and freshness/retention. Explicitly distinguish “last changed,” “last verified,”
“expires,” and “kept until removed.” Reading a memory does not make it freshly verified.

Show learning backlog age, processed-through time, failed batches, and meaningful changes—not just
record counts. Provide practical controls to correct/disable a topic, inspect history, rebuild from
eligible sources, and review guidance proposals. A read-only inspection page must remain read-only.
Internal hashes belong in diagnostics, not the main explanation.

## 7. Storage and authorization

### 7.1 Keep storage small without making history false

**First reduce disclosure.** Remove unrelated fallback before fitting the prompt, and offer a
small relevant set (start by evaluating at most eight rather than the batch lane's 32; eight is
a trial setting, not a proven optimum). Do not drop the dependencies of topics already shown to
the model. If six unrelated heads were disclosed, their influence cannot be undone by ignoring
their citations at apply time. Narrow the next run before disclosure.

**Then repair representation and failure behavior.** Reuse `conversation_knowledge_sources` and
the existing `generation`/`introduced_version` fields. Those fields already exist; there is no
current mutable `direct` flag to fix. The missing piece is inherited receipts stored only in the
flattened representation. Represent them incrementally under existing owners, preserving exact
receipt identity, first introduction, and any later direct-support introduction. Edited source
receipts must not overwrite the version used by an old topic revision. If distinguishing direct
and inherited support is added, a later role change must not rewrite historical attribution.

Reuse session `SourceExposure` rows and existing chunked validation rather than duplicate that
ledger. Summary/rollup and observation owners must preserve all inherited dependencies too.
Bind each frozen document to its exact retained owner/version/fingerprint. Raw source identity
does not identify a rewritten observation note. Archived submitted bytes remain immutable audit
evidence, not an alternate operational path. Update `KnowledgeRetention`'s `source_note IS NOT
NULL` assumptions before inherited-only rows become authoritative.

This is an authorization-path replacement, not just serialization. `LearningSources.eligible`
currently unnests JSONB roots before candidate limits; `valid?` locks root rows; `merge` enforces
count/byte caps. Replace eligibility SQL, validators, membership merging, retention, and every
caller together. Do not keep a JSONB authorization path for small topics and a relational path
for large ones. Benchmark concurrent edits as well as reads: the existing shared root locks
conflict with source updates. Any alternative generation fence must prove equivalent revocation
ordering before replacing those locks; a faster unfenced read is not an acceptable optimization.

Avoid copying a complete growing root set for every revision. Adding one root in each of 10,000
updates would materialize 50,005,000 memberships in that design. Incremental memberships can avoid
that particular amplification; they do not magically remove growth caused by disclosing many
unrelated topics into one model context. Measure both storage and authorization query cost.

Return explicit capacity/deferred errors instead of pretending an update or summary succeeded.
Keep blocked compaction groups visible without letting them monopolize every later maintenance
window. Never reset a topic generation merely to fit the next input. A fresh bounded rebuild is
an explicit repair with source evidence and a new attributable revision, not a hidden fallback.

The earlier generic source-set ledger proposal is superseded. No relational layout removes the
cost of authorizing thousands of genuinely inherited roots. Measure grouped validation/query
cost; preserve all-root revocation fencing. If a focused subject still exceeds the supported
budget, defer visibly and qualify a fresh-source rebuild, rather than inventing dependency-free
prose. A knowledge-only conversion that leaves summary/session cliffs is not a complete fix.

### 7.2 Evidence support is not the same as disclosure history

Direct citations help explain a claim. Every source actually disclosed to a persistent model
session can influence later output, whether or not the model cites it. Keep both meanings explicit.
Do not let a model self-report a smaller receipt set to bypass retention or authorization.

The simplest initial safety rule remains conservative invalidation of a derived document when a
required source becomes ineligible. To improve availability, reduce unrelated **disclosure**, use
focused subject updates, and rebuild from still-eligible original sources in a fresh context.
Never drop a dependency and retain the supposedly unaffected prose without a validated rebuild.

Search pages, omitted-topic hints, excerpts, original-source expansion, summaries, and continuation
briefings all count as disclosures. `LearningSources.document_sources` recognizes specific document
shapes; an unknown source-derived shape must not accidentally become dependency-free.

### 7.3 Revocation, privacy, and operational authority

- Derive scope from the active binding/lease and current destination; caller-provided session IDs,
  namespace strings, memory IDs, or source URLs cannot grant access.
- A bot's membership is not automatically permission to reveal everything it has seen to every
  destination. Preserve current repository/workspace/channel restrictions; explicitly evaluate
  private channels, Slack Connect guests, GitHub private repos, user preferences, and membership changes.
- Apply eligibility before bounded candidate selection where possible. Reauthorize before disclosure
  and application, and after source edits/deletions/expiry. Keep deterministic concurrency fencing
  over every inherited root; a read snapshot alone does not settle concurrent revocation races.
- An aggregate cannot expose private influence merely by citing a public source. Titles and aliases
  can leak, too. Scope intersections must survive consolidation and subsequent retrieval.
- Once a source already in a live session is revoked, excluding it from the next search does not
  make the session forget it. Use the existing session invalidation/replacement path.
- Source removal must not cascade away the dependency that proves a descendant is invalid.
  Operator access to retained historical diagnostics is distinct from permission to brief a model.
- Source authenticity proves who supplied content, not its truth. Treat embedded instructions,
  quoted commands, and issue-body attempts to change policy as data. Learning cannot convert them
  into higher-priority instructions or permission to act.

### 7.4 Retention and freshness are separate policies

Do not introduce automatic 24-hour history deletion or copy another product's 28-day memory TTL.
Source custody, operator history, durable decisions, temporary working context, and current
operational observations have different purposes. Exact retention periods need explicit workspace
policy and clear UI; this research does not authorize deleting any existing data.

“Stale for current health” need not mean “delete historical evidence.” A decision can remain useful
until corrected, while current health must be rechecked for the action. Any permitted durable
confirmation must use the existing confirmation owner, not silently relabel revoked input.
Recall must not renew the inherited lifetime of a source. Retention must inspect inherited rows
even when they do not contain a `source_note`. Expired original wording cannot be reconstructed
and presented as an exact quote from a derived summary.

## 8. Evaluation and implementation order

### 8.1 Measure the actual teammate job

The first implementation must carry these eight targeted regressions, in addition to preserving
existing authorization/concurrency tests. Some expose inspected code paths; harvest real inputs
before classifying them as reproduced production defects:

1. A 127-root topic plus three new inputs is not split or rebased. The supported relational path
   preserves the update; a genuine configured limit produces an explicit failure, never success.
2. Six irrelevant topics are excluded **before** the model sees them; roots do not inflate to
   their union. The paired test proves that any actually disclosed topic remains a dependency.
3. A late event and an edit of an old message produce attributable reconsideration, with no
   silent skip and no blind replacement of a later corrected decision.
4. Repeated duplicate-topic output rejected by the host exhausts the configured retry allowance.
5. Adding an input or changing run generation cannot reset a claimed batch's budget; its failed
   inputs cannot be silently regrouped into fresh claims. No unsupported input-level blame;
   deferred work stays visible while unrelated eligible input can progress.
6. Over-capacity groups at the start of a 101-summary queue cannot starve later compactable
   groups; skipped work is visible and original records are preserved.
7. A lexical paraphrase such as “WAL archiving” finds “archiving of WAL”; later pages reach
   relevant topics when earlier pages contain facts, without duplicate loops or scope bypass.
8. An ignored, unmentioned human decision retains the classifier's proposed observation **text**,
   not merely a row. Its separate original Inbox revision is processed by the sole topic-writing
   lane and informs a later mention without any public activity. Force admission capacity pressure:
   the note either survives with complete receipts or has an explicit deferred/loss receipt;
   the still-eligible original remains learnable without disclosing the lost note.

The broader matrix below is the ongoing product-evaluation catalogue. Cross-transport linking,
omission hints, and automated procedural promotion are conditional follow-ups, not hidden
requirements to ship those features in the first repair.

Use the same retained world, source-time ordering, model configuration, and budgets for baseline
and candidate. Keep later messages, resolution events, later code commits, and later guidance out
of earlier questions. Hold out incident families/conversations and later time windows for learning
transfer. Preserve the private, no-public-write replay boundary.

Separate four failure stages: **retained evidence → stored understanding → retrieved context →
answer/action**. For a failed answer, compare against an oracle evidence bundle and the full eligible
stored understanding; determine where the relevant fact disappeared. Do not fix a write-loss bug
with a fancier search engine. Do not give only the candidate a larger model or newer evidence.
These comparisons localize a failure; they do not prove deletion without inspecting the actual
stored material, because reader format and missing contextual cues can also explain a gap.

| Case | Required behavior |
|---|---|
| Unmentioned human keep decision | No unsolicited reply; later mention recalls the decision and rationale |
| Firing → acknowledgment → resolution | One occurrence history; consistent topic; no invented application recovery |
| Same monitor fires again | New occurrence, same service context, not a continuation of a closed incident |
| Intentionally zero replicas | Check intended/deployed/observed state before calling it broken |
| Proposal → merge → deploy | Do not claim a deployment at PR merge time |
| Older decision plus later correction | Correct current understanding and intelligible historical chronology |
| Unrelated channel traffic | No irrelevant context filling or memory inflation |
| Different channel / linked PR | Preserve current denials now; a future approved sharing policy must permit useful recall without unintended episode attachment |
| Ambiguous shared service names | Avoid destructive false merge; retrieve or preserve uncertainty |
| Learning backlog / immediate follow-up | Recent correction is usable before consolidation completes |
| Memory not in first search page | Reachable through bounded pagination; no starvation by another category |
| Optional prompt material omitted | Search/expansion recovers what is needed; test hints only if this baseline misses it |
| Source private/deleted/edited mid-session | No unauthorized later use, including hints and inherited summaries |
| Malicious instruction repeated in a source | No authority promotion, exfiltration, or self-installing procedure |
| Ordinary conversation | No useful memory is an acceptable outcome |
| Repeated correction | Update understanding now; a later reviewed procedural candidate must improve held-out work |
| Worker restart / provider failure | No duplicate apply, lost source progress, or unbounded retry spending |
| 129 / 1,000 / 10,000 source roots | No silent topic reset or skipped summary; bounded measured resource use |
| 10,000 successive updates | Storage growth measured, not hidden by a one-off large-read benchmark |

Track answer correctness, premise errors, false merges/splits, important-fact preservation, source
attribution, abstention quality, unsolicited replies, repeated corrections, learning lag, DB work,
tokens/cost including background writes, and action outcome verification. Memory-record count is
diagnostic, not an optimization target. A fixed “900 memories for 1,034 messages” ratio is neither
automatically good nor bad; inspect duplicates, durable value, and retrieval utility.

Hard gates: zero unauthorized disclosures/actions in the test suite; no changed frozen history;
no silent learning loss; bounded recovery. Behavioral gates: pass each named regression, compare
repeated trials against baseline, and review false positives/negatives with an engineer. A finite
suite passing is not a claim of zero real-world failure probability.

To substantiate the human-teammate goal, have an experienced SRE review blinded baseline/candidate
outputs against the same available code, messages, and telemetry. Score investigation choices,
recognition of intended state, useful silence, escalation quality, and verified outcomes—not just
answer phrasing. Record disagreements. Do not claim “top-tier human equivalent” from a memory-QA
score or an assessor model alone. Until that evidence exists, unattended use must stay within
already-authorized action classes and demonstrable host safeguards.

### 8.2 Small implementation slices

1. **Pin failures; reduce disclosure; stop silent loss.** Harvest the split-incident, WAL loss,
   and positive decision cases. Remove unrelated fallback, surface capacity failures, prohibit
   implicit rebase, and avoid compaction head-of-line starvation. Done: the owning regressions
   fail before the fix and pass after it; no receipts or historical prose are silently dropped.
2. **Repair incremental source ownership.** Extend existing membership/exposure owners rather
   than building a generic ledger. Replace eligibility SQL, locked validation, merging/caps, and
   retention together; no small/large-topic dual authorization path. Cover frozen documents,
   observation/summary loss, late events, and validation under concurrent edits. Done:
   129/1,000/10,000-root and successive-update experiments establish supported bounds, preserved
   attribution, and revocation/concurrency correctness.
   This is not permission to promise unbounded topics or silently enlarge all limits.
3. **Make passive learning one writer.** Replace inline topic generation with one coalesced
   worker over retained input revisions. Preserve admission observations and recent context;
   repair retry accounting before unattended operation. Done: ignore/shadow inputs improve
   later understanding; restart, semantic rejection, and changing-batch tests remain bounded.
4. **Make existing recall useful.** Reuse full-text primitives for explicit search, deliberate
   per-kind budgets, source-time filters, stable scoped cursors, and existing source readers.
   Add bounded exact anchors only where the harvested identity case requires them. Done: older
   relevant context is reachable; no false merges or authorization/exposure regression.
5. **Qualify and explicitly repair known topics.** Rebuild fragmented/lost-context heads from
   eligible retained evidence while preserving history. Resume the remaining private replay
   only under existing guards. Done: demonstrate corrected knowledge and better held-out work,
   measured lag/cost, and no unauthorized activity—not merely completed batches.

Do not add a second initial reflection trigger, new prompt-watermark protocol, model-visible
omission index, generic alias/entity graph, cross-transport scope bypass, or automatic skill
promotion to these slices. Their research remains above so measured needs can be revisited.

Use owning tests during iteration, `make dev-check` before a future implementation commit, and
the required full gate before shipping persistence/security/concurrency/contract changes. Contract
and prompt changes need the appropriate model evaluation lane. A future implementation finishes
with the prescribed deployment and exact running-version proof; this research document does not
change or deploy the runtime.

## 9. Fable review

Reviewed on 2026-09-08 by **Fable 5.1**, actual CLI model **`claude-fable-5-1`**, with the full draft
in the request and read-only access to this Elixir checkout. The recorded initialization confirmed
the model and only Read/Glob/Grep tools. No model substitution, external writes, or runtime
mutations were used. Fable inspected source; external papers/docs were supplied by the primary
researcher, not independently fetched by the reviewer.

**First verdict: not ready as an implementation roadmap.** Fable agreed with keeping PostgreSQL
and avoiding another runtime/graph/vector service, but rejected the breadth and several assumptions.
The revised document accepts these changes:

- Put excess disclosure, not JSON storage alone, at the root of the capacity problem.
- Remove irrelevant candidate filling before disclosure; retain conservative dependency accounting.
- Make capacity skips, implicit rebasing, and compaction starvation explicit defects to test.
- Add late-event and semantic-retry/batch-reset gaps found in the source.
- Choose one topic writer, with a clean removal of admission's topic-generation path.
- State that exact external anchors are proposed schema, not an existing capability, and that
  the present knowledge scopes do not provide Slack/GitHub shared recall.
- Reuse existing generation/version and session-exposure ownership; correct the implication
  that a mutable direct-source flag already existed.
- Defer omission hints, prompt watermark additions, and automated procedural reflection; keep
  the first build centered on eight concrete regression invariants.

**Deliberate disagreements/qualifications:** the external comparison and future procedure/operator
criteria stay in this research KB, clearly outside the initial build. They directly serve the
requested teammate goal; deleting them would lose useful research, not simplify running code.
Fable's suggested “unrelated topics but no inherited roots” test is safe only when those topics
were never disclosed. Eight candidate topics is an evaluation starting point, not a magic
correctness threshold. Cross-transport sharing is deferred, not declared solved.

**Second verdict:** coherent and honestly scoped, but not a clean pass without further corrections.
Fable identified ambiguity between raw-input learning and observation-note learning, a third silent
loss path in admission observations, unsupported per-input attribution of batch failures, and
understated authorization changes behind relational receipts. It also identified the narrow existing
episode-routed GitHub feedback bridge. The primary researcher checked those paths and amended
sections 5–8: raw Inbox revisions only for the initial lane; explicit observation-loss coverage;
frozen-claim budgeting without causal blame; one complete authorization-path replacement; and the
feedback bridge's actual scope/initial learning limitation.

Both reports were completed using `claude-fable-5-1`. The last amendments address the second report;
they were not sent through a third review, so this is not an unconditional Fable approval. Exact
retry/error-class policy and large-root locking strategy still require an implementation-level
decision and tests. Neither review substitutes for regressions, replay evidence, or an
authorization/concurrency qualification. No reviewed proposal here has been implemented.

## 10. Source register

Accessed 2026-09-08 unless a pinned version is stated. Dynamic docs are dated observations;
implementation work should recheck them. Linked papers are research evidence, not product SLAs.

| ID | Primary source | Evidence used / limitation |
|---|---|---|
| L1 | [Letta repository](https://github.com/letta-ai/letta) | Current code owner and retired-server warning |
| L2 | [MemFS](https://docs.letta.com/concepts/memfs) | Current progressive disclosure/search/versioning documentation |
| L3 | [Recall prompt, pinned](https://github.com/letta-ai/letta-code/blob/2f0fb7c12c6973be7d52d9c7d3bf0bf4d9120cb8/src/agent/prompts/recall_subagent.md) | Source read in matching local checkout; search/expand instructions, not tool-success proof |
| L4 | [Reflection prompt, pinned](https://github.com/letta-ai/letta-code/blob/2f0fb7c12c6973be7d52d9c7d3bf0bf4d9120cb8/src/agent/subagents/builtin/reflection-v2.md) | Source read; selective learning and procedure distinction |
| L5 | [Memory and dreaming](https://docs.letta.com/configuration/memory) | Current product configuration; second-agent review is not human review |
| L6 | [Sleep-time compute](https://www.letta.com/blog/sleep-time-compute/) | 2025 motivation and historical implementation, not today's runtime specification |
| A1 | [Claude Code memory](https://code.claude.com/docs/en/memory) | Selective notes, index limits, policy distinction |
| A2 | [Context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) | Engineering guidance on context/tool complexity |
| O1 | [OpenAI local memories](https://learn.chatgpt.com/docs/customization/memories) | Official documentation fetched; local Codex/ChatGPT distinction and background controls |
| G1 | [Copilot Memory](https://docs.github.com/en/copilot/concepts/agents/copilot-memory) | Current-branch citations, scopes, documented retention; public preview |
| D1 | [Devin Knowledge](https://docs.devin.ai/product-guides/knowledge) | Triggered items and reviewed create/update suggestions |
| LG1 | [LangChain memory concepts](https://docs.langchain.com/oss/python/concepts/memory) | Profile/collection and hot-path/background tradeoffs |
| M1 | [Mem0 paper v1](https://arxiv.org/html/2504.19413v1) | Read extraction/update and cost discussion; vendor-authored LoCoMo experiment |
| M2 | [Mem0 issue 7123](https://github.com/mem0ai/mem0/issues/7123) | First-hand SDK 3.0.7 report, opened 2026-08-26; API showed open at inspection; not reproduced |
| Z1 | [Zep paper v1](https://arxiv.org/html/2501.13956v1) | Read temporal/entity/retrieval sections; vendor-authored experiment |
| Z2 | [Graphiti issue 1734](https://github.com/getzep/graphiti/issues/1734) | First-hand 0.29.2 report, opened 2026-08-05; API showed open at inspection; not reproduced |
| H1 | [Hindsight paper v1](https://arxiv.org/abs/2512.12818v1) | Architecture and reported results from abstract; no reproduced benchmark |
| H2 | [Recall versus reflect](https://hindsight.vectorize.io/blog/2026/07/24/recall-vs-reflect) | Vendor-described read paths and cost distinction |
| H3 | [Inside retain](https://hindsight.vectorize.io/blog/2026/07/13/inside-retain-agent-memory) | Vendor-described original retention/consolidation |
| C1 | [Cleric investigation memory](https://cleric.ai/glossary/what-is-investigation-memory) | Vendor-described case history, corrections, and explicit reuse failure modes |
| I1 | [incident.io remote MCP](https://docs.incident.io/ai/remote-mcp) | Official compact/deep investigation retrieval and telemetry interfaces; no runtime trial |
| P1 | [SimpleMem v3](https://arxiv.org/abs/2601.02553v3) | Abstract-level technique and claims; not an audited compression guarantee |
| P2 | [ACE v3](https://arxiv.org/abs/2510.04618v3) | Abstract-level collapse/incremental-update findings; ICLR 2026 |
| P3 | [LongMemEval v2](https://arxiv.org/html/2410.10813v2) | Abstract, representation experiment 5.2, and error analysis E.5 inspected; ICLR 2025 |
| P4 | [LongMemEval-V2 v1](https://arxiv.org/abs/2605.12493v1) | Abstract-level environment/workflow evaluation; labelled work in progress |
| P5 | [WhenLoss v1](https://arxiv.org/html/2605.24579v1) | Abstract, diagnostic conditions/caveats 3.2, and case-study material inspected; fixed-budget setting |
| P6 | [MINJA v5](https://arxiv.org/abs/2503.03704v5) | Abstract-level demonstrated interaction-based memory poisoning |

### Maintenance rule

Keep the recommendation compact and the evidence attributable. Add an idea when it changes a
decision, supplies a counterexample, or closes an uncertainty—not merely because another memory
paper exists. Record negative results and superseded decisions. Do not promote a proposal to
“implemented,” a test to “deployed,” or an external benchmark to “trusted unattended teammate.”
