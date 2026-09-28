# Training data for a self-hosted routing model

Andrew, 2026-09-27: "is our current model saves enough data for model training / fine-tuning?" and
"is our current retention policy defeats the purpose deleting data that will be used for learning
too quickly?"

Short answers. Ryker already saves almost everything one routing example needs, but in four places,
and nothing joins them. The default retention then deletes the prompt, the answer and the outcome
within about a month. So the answer to both questions was: no, and yes. Routing examples, below, fix
that.

## What one routing example needs

Routing reads each incoming message and decides what to do: start work, continue work, reply,
answer briefly, react, or ignore. A model that learns to route needs, per decision:

1. **The exact prompt** routing sent, and the JSON Schema the answer had to follow.
2. **The model's answer**, and which model gave it.
3. **The decision's outcome**: what Ryker then did and how it ended.
4. **Feedback**: what people thought of it (reactions, asking again, review outcomes).

Tokens and cost come with it, so a cheaper model can be compared with the one it replaces.

## Where each piece lives today, and when retention deletes it

The table names what the Elixir release keeps. The Go release's `context_manifests` and
`agent_runs` are gone; their `submitted_prompt` and `result_json` are now the admission attempt's
`submission` and `response`.

| Piece | Where it lives | When it is deleted (default settings) |
| --- | --- | --- |
| Exact prompt and schema | `admission_attempts.submission` | Replaced by `{"retention":"pruned"}` 30 days after the message was routed, once the work it started has let go of its sessions ("Prompts, replies and tool activity") |
| What the prompt quoted, with references | `ingress_inbox_entries.admission_context` | The same, with the message's own text |
| Model's answer and model | `admission_attempts.response` (`assistant_message`), `.execution_target` | The same |
| Decision | `ingress_inbox_entries.decision_action` and `.decision_document` | The document goes with the prompt; the action stays until the row is deleted at the audit limit (another 30 days) |
| Outcome of work | `episode_kernel_episodes.state`, `episode_work_turns.status` | History 30 days after the request finished ("Request history"), the rows at the audit limit |
| Outcome of a quick reply or reaction | `delivery_routing_responses.status` | 30 days after it was delivered |
| Tokens and cost | `admission_attempts.measurements`, `execution_usage` (kind `admission`) | `execution_usage` is kept; the attempt's copy goes with the prompt |
| Feedback | Being built on `feature/feedback`, one table keyed by request | Its own rule |

So after 30 days the prompt and the answer are gone. The decision's label and the usage row remain,
but with nothing left to train on.

## What routing examples change

**A copy with its own retention.** With **Keep routing examples for training** on (Settings › Data
retention), Ryker copies each routing decision into `routing_examples`. The copy is kept for its own
limit, **Routing examples**, a year by default, counted from the decision. The limits above never
reach it: it names the message and the request it came from without a foreign key, so pruning the
source rows leaves it alone. Only its own limit removes it, or turning the setting off, which
deletes every copy and asks first. The setting is off until someone turns it on.

**When a decision is copied.** Once it has settled: routing committed it, and nothing it started is
still running. The work it started or joined has come to rest (answered, waiting for a person or an
event, blocked, cancelled or closed), the same rest learning waits for. Any quick reply or reaction
it chose has been delivered or given up. The outcome is known then, and the bodies are still there,
because they are pruned only after that work's sessions are discarded. Decisions still within the
operational limit when the setting is turned on are copied too.

**What a copy holds.**

- `prompt`, `output_schema`: the exact prompt and schema routing sent.
- `answer`: the model's exact answer. `execution_target` is the model, `policy` the routing policy.
- `decision`: action, work class, relation, repository, reaction names, number of messages.
- `outcome`: `request` (the request's state, or null when routing answered by itself), `turn` (its
  last work turn's status) and `sent` (routing's own replies and reactions by status).
- `usage`: input, cached, output and reasoning tokens, the provider's cost if it reported one,
  otherwise an estimate at the saved model price, and timings.
- `episode_id` and `episode_ref`: the request, the key feedback is kept under. `input_id`, the
  conversation, thread, repository, live or shadow, and `decided_at`.

**Redaction.** The prompt and the answer pass through the redaction inspection uses
(`Ryker.InspectionRedactor`), with every stored integration credential among the values it
removes: keys named like credentials, tokens, private keys, `password=`-style assignments, and the
part of each link after `?`. Only what redaction changes differs; everything else stays byte for
byte. On the live install on 2026-09-27, 77 of 82 prompts came through unchanged; the other five
lost the query of a link.

**A person forgetting wins.** Forgetting a fact or a learned topic, deleting a message in Slack,
editing its words, or deleting a Slack channel erases, in the same transaction, every copy whose
prompt quoted that message, topic or conversation: its own message, the earlier messages of its
thread or channel, learned observations and topics, and the opening and latest message of each
earlier request offered as a candidate: routing shows those as short previews and records which
messages they are. An edit takes back the words it replaced; one that leaves the text as it was,
as Slack reports a link's preview arriving, takes back nothing. The copy keeps only its identity,
so it is never copied again. A message forgotten, deleted or edited before its decision is copied
is checked at the copy, which then records only that identity. Copies and forgetting share one
lock, so a copy in flight cannot slip past a forgetting that is committing. Decisions routed
before 2026-09-28 recorded no messages for their previews, so forgetting cannot trace those
previews.

## Getting the examples out

**Download routing examples** on Settings › Data retention saves a JSON Lines file, or from a source
checkout:

```bash
MIX_ENV=prod mix ryker.routing_examples --output routing-examples.jsonl
```

Each line is one chat fine-tuning example, oldest decision first, forgotten ones left out:

```json
{"messages":[{"role":"user","content":"<exact prompt>"},{"role":"assistant","content":"<exact answer>"}],
 "output_schema":{...},
 "labels":{"example_id":"...","request_id":"...","request_ref":"...","input_id":"...",
           "decided_at":"...","settled_at":"...","transport":"slack","conversation_ref":"...",
           "thread_ref":"...","repository_ref":null,"execution_mode":"live",
           "model":"codex:gpt-5.6-luna/low@default","policy":"ryker-admission",
           "decision":{...},"outcome":{...},"usage":{...}}}
```

The download reads the rows in batches and sends each line as it goes, so a large set never sits
in memory.

## What an example still lacks

- **Feedback.** `labels.request_id` is the request id the feedback table is keyed by, so a training
  set can join it once that table lands. Routing's own quick replies and reactions start no
  request, so their `request_id` is null.
- **Rejected answers.** When host validation sends an answer back, only the accepted one is kept.
- **Work's own model calls.** Only routing decisions are copied.
