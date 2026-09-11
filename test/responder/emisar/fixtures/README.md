# Emisar review receipt fixture

`wait_for_run_review_v1.json` is a byte-for-byte copy of Emisar's own published
example, `portal/apps/emisar_web/test/fixtures/mcp/wait_for_run_review_v1.json`
in the Emisar repository, where a portal test asserts it is what `wait_for_run`
actually returns for a gated run. Responder's client, status document and Slack
renderer are exercised against these exact bytes, so a shape change on either
side fails a test here instead of failing closed in production.

Do not edit it to make a Responder test pass: re-copy it from Emisar after that
repository's example changes, and widen the allowlists in the same commit.
