# Recorded review transport failure

`completed_review_after_timeout.json` is the unchanged public response harvested
on 2026-09-10 from the exact already-succeeded `RunReview` operation
`op_465712a7ea4ff7992bfe9b6cd9184730`, after #test automatic-readiness QA.
The same-key POST replay returned the saved result without another gate invocation.
Coop took 54 seconds; the worker's 30-second HTTP request had already timed out.
The review is genuinely unpublishable (`gate_failed`). The 279-byte patch adds one
disclosed disposable QA documentation file, not production changes.

This fixture proves recovery of the actual result, not publication eligibility.
It also records the producer's original omission of empty `policy_findings`.
The paired Coop producer regression now requires both findings/reasons arrays in
its public DTO; Responder's publication validator is not made more permissive.
