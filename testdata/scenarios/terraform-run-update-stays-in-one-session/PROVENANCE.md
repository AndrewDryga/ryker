# Two retained Terraform histories

The positive host replay is harvested from the structured private report
`terraform-run-update-stays-in-one-session-1788782169504.json`, generated
`2026-09-07T11:57:44.066990Z`, SHA256
`ef557caa112595767d45bd7320332f462b3cac391ef9444c916bde02800313c6`.
That report remains unchanged. Its two accepted turns shared Coop session
`b59e7c0b-0420-4256-a63e-d244eeb0f230`; no model reasoning is copied.

Both candidate bodies are retained exactly except their single record reference,
which is replaced with the existing `$call:0:record_ref` test placeholder.
The first saved wait payload is projected back through the verified `wait_for`
contract: `deadline_at` becomes `deadline`, `event_matcher.on_timeout` becomes the
top-level timeout instruction, and the remaining matcher becomes `trigger`.
The second saved evidence payload maps `source_id` to `cite_source.source_ref`,
`target` to `subject`, and preserves `observation`, `relation`, and `supersedes`.
These are deterministic projections of accepted persisted records, not a claim
that the fixture contains original raw tool-call arguments.

Only the wait's poll/deadline dates move from September 7, 2026 to September 7,
2099, retaining the original times and 25-minute gap. The messages' `12:01` and
`12:26` remain unchanged. This keeps a historical host fixture nonexpired; it
does not qualify realistic wait duration. Input timestamps, content, source
references, source observations, and actor profiles are unchanged. Reports retain
historical timestamps alongside the causally rebased input clock.

The actual envelope source is `slack` and the captured matcher names `slack`,
matching the exact `run_id`. The later canonical source reference is
`slack-source:v1:TEVAL:CTERRAFORM:message:1787846700.000000`, exactly the captured
citation. A payload field named `source_kind=terraform` never changes the trusted
envelope source or proves a Terraform ingress adapter shipped.

The reached second turn deliberately injects `lose_submit_response`. The owning
regression proves one session, two distinct remote turns, one submit each, an
extra exact-key operation-journal lookup, two accepted validations, and settled
inert deliveries. That controlled host fault earns reconnect coverage; the
harvested model report itself is not claimed to have experienced network loss.

The superseded host replay remains byte-for-byte equivalent as JSON under
`test/responder/evals/fixtures/terraform_invalid_source_matcher.json`. Its wait
incorrectly names `source_kind=terraform`; the negative regression still stops
after one model turn, retains the open wait, queues the unmatched Slack input,
and proves its second-turn loss fault was never installed. No recorded output
or invalid matcher was rewritten to manufacture the positive case.
