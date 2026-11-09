# Emisar review receipt fixture

`wait_for_run_review_v1.json` is a byte-for-byte copy of Emisar's own published
example, `portal/apps/emisar_web/test/fixtures/mcp/wait_for_run_review_v1.json`
in the Emisar repository, where a portal test asserts it is what `wait_for_run`
actually returns for a gated run. Responder's client, status document and Slack
renderer are exercised against these exact bytes, so a shape change on either
side fails a test here instead of failing closed in production.

Do not edit it to make a Responder test pass: re-copy it from Emisar after that
repository's example changes, and widen the allowlists in the same commit.

`approval_result_already_read.json` is the retained `wait_for_run` response from
2026-11-09: an approved diagnostic completed while Work was still investigating;
Work read its output, then the queued approval event caused another silent model
turn (51 seconds, $0.56). It preserves the successful action's missing-log output,
review decision, timing, truncation flags and output shape. Account, person, host,
resource, run, request and operation identities are pseudonyms; the immutable pack
digest is derived from the fixture identity. The test runs both monitor orderings
through the actual proxy and candidate acceptance, without a model or remote call.
