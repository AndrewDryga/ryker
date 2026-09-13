# Episode replay fixtures

These fixtures are sanitized, normalized commands derived from the deployed Responder databases. They
are not invented model transcripts and they are not copies of the legacy event schema.

Each fixture records the old episode, input, wakeup, incident, or task identities that motivated it.
The command sequence expresses the behavior the replacement kernel must preserve. User identifiers,
unnecessary prose, provider payloads, and secrets are reduced to bounded labels. Stable source IDs,
Slack destinations, lifecycle times, and task/thread relationships remain where the regression depends
on them.

The suite has four guarantees:

1. a compact expected view pins final state, owner, destination, semantic version, and event order;
2. the checked-in `.golden.json` pins the normalized state after every command plus the full event
   transcript;
3. a second replay must produce byte-identical canonical output; and
4. every fixture, including its linked historical episodes, must produce the same transcript through
   Postgres as it does through the pure reducer.

The checked-in corpus covers both deployed Responder databases. It includes cancellation from input
and event waits, an Emisar question answered in the original thread, and a silent lifecycle decision
that advances already queued work. These are lifecycle regressions, not model-quality examples.

`setup` contains linked historical episodes when a regression depends on history. It never changes the
current episode's destination. Event waits are resumed only by the exact dedupe key of a timer or source
event first admitted as a normal durable input, so unrelated conversation cannot wake them and a
reconstructed turn can explain why it woke.

Promote a new fixture only when a production episode reveals a distinct kernel invariant. Model answer
quality belongs in the fabricated-world eval corpus, not in this deterministic suite.
