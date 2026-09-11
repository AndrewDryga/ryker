# The answered project unblocks the checks it was blocking

Variant of `missing-project-answer-is-remembered` with tools available. The
review and Terraform notification in the first event are copied unchanged from
`testdata/work/missing-project-clarification.json`: episode
`d60296db-9f67-40db-86ed-f39b7895f23b`, turn `fd316279-9146-4866-831d-7badf1130f75`,
delivered 10 September 2026 at 01:25:14.645141 UTC.

The operator's continuation request, the `emisar-project-qa` answer and the later
follow-up request are **authored** scenario input, which is why the provenance is
`synthetic`. `emisar-project-qa` is an isolated authored value, not a discovered or
real GCP project. No model answer, health result or provider receipt is invented.

`gcp.backend_health` and `gcp.backup_config` are **fabricated tools declared in this
scenario's world** (`world.tool_rules`) and catalog. They are served by the offline
cassette, so no Google Cloud account, credential or real provider is reached. There
is deliberately **no project-listing tool here**: the model must ask, because nothing
in the scenario can discover the project. That is the point of this case.

What this scenario holds: after the authorized answer the previously blocked
infrastructure health and backup checks actually run against the answered project,
the mapping is saved through the real `remember_answer` tool without a second
confirmation, the work stays in one session, and the exact `run-t2W6yCNeLUU9xFso`
watch survives the human question.

What it does not prove: cross-episode global recall. The world runner pins every
event in a scenario to one episode, so a later turn here can also see the answer in
its own conversation history. Global recall across a new channel, episode, session,
process restart and raw-history expiry is held by the deterministic host tests in
`test/responder/state/global_memories_test.exs` and
`test/responder/slack/question_end_to_end_test.exs`. A passing offline schema test is
not a model-world or live Slack result.
