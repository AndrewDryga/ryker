# A brief check in an existing conversation with Ryker gets an answer

On 2026-10-19 a person's `test` reached routing in a thread where they had
mentioned Ryker, received `Hi!`, asked about infrastructure, and received a
report four days earlier. Routing saw those four messages but chose `ignore`:
the check contained no explicit request or operational event. The person
received nothing and reasonably thought Ryker was down.

`recorded.jsonl` contains the retained admission attempt's submitted prompt,
output schema, and actual accepted **incorrect** answer, packaged in the
routing replay's export envelope. Its example ID is the source input ID;
there was no retained training-example row for this input. Tenant
identifiers, organization and repository names, application names, and
operational URLs have one-for-one pseudonyms. Source timestamps, internal
record references, ordering, stale summaries, candidate relations, and the
message and answer are preserved. No model answer was invented or corrected.
The source input is `01a155de-c8c4-70cc-8025-f0aec94a3e1b`; it was captured on
2026-10-20.

This is a model-routing regression, not a deterministic host failure. Run it
on the isolated eval worker with the production model and effort
(`codex:gpt-5.6-sol/medium`, using the evaluation account):

```sh
export RYKER_EVAL_ROUTING_TARGET=codex:gpt-5.6-sol/medium@personal
report=$(mktemp /tmp/ryker-thread-liveness.XXXXXX)
MIX_ENV=test scripts/elixir-mix.sh ryker.eval routing-replay \
  --examples "$PWD/testdata/admission/thread-liveness/recorded.jsonl" \
  --results "$report"
jq --exit-status '
  .total == 1 and .changed == 1 and .not_answered == 0 and
  (.examples | length) == 1 and
  .examples[0].replayed.action == "quick_reply" and
  .examples[0].replayed.episode_ref == null and
  .examples[0].replayed.relation == "unrelated"
' "$report"
```

The replay intentionally reports a **changed** decision: matching the
recorded `ignore` is the regression. The expected route is a brief answer
without starting or continuing infrastructure work. Inspect the generated
answer for a simple acknowledgement, with no claim to have checked current
system health. The old report remains historical background.

The existing routing replay corpus and model-world smoke suite remain the
broader checks for unrelated ambient conversation and operational requests.
These isolated replays send no Slack messages and do not prove live delivery.
