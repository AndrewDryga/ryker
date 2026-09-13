# Completion after one real timer

`airflow_completes_after_timer.json` projects only structured candidates,
per-turn state-record payloads, input-clock provenance, and source-call receipts
from `airflow-verification-arms-wait-1788785852030.json` (SHA256
`d44cfad26585fe95fcb062d77b02750b82bfefd939a5204d7d9e3a060a13cd92`).
The original failed report remains unchanged. No model reasoning is included.

Both turns used Coop session `b1f63418-74a8-4313-92c5-6d6d0209247d`.
The first accepted a ten-minute timer. Its wake produced an accepted `complete`
response reporting an unresolved verification gap. The evaluator then demanded
the older scenario's second wait and failed with `event_wait_not_open`.

The regression replays each saved record through production `Records.create/5`
and each candidate through real final validation and inert delivery. It does not
invent model tool arguments: the retained report contains persisted payloads,
not the original state-tool invocation stream. References are substituted with
the newly created test records, including finding dependencies. Only the wait
deadline and its displayed `HH:MM` are moved to twenty minutes after test setup;
the ten-minute delay, timeout instruction, verification objective, and conclusion
remain unchanged. Source calls retain their exact arguments and results; only
the first deployment call belongs to turn one, with the other three in turn two.

This proves that a settled completion needs no additional synthetic wake or
model turn. It does not judge whether stopping then was sufficiently persistent,
rescore the original failure, or qualify fresh health. Source observations still
date from August 27 while the input is rebased to test wall time. Quality remains
explicitly unrun in the deterministic regression.
