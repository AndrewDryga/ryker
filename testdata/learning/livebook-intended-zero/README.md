# Livebook: observed zero is not desired configuration

This bundle is harvested evidence for a source-grounded health-assessment check,
not an invented incident or a training answer. `evidence.json` retains the exact
original health requests, both public responses, the later explicit code-check
request, and three public native repository-read receipts. Two older read outputs
were withheld/truncated by the original recorder; their missing bytes are not
reconstructed. The third includes the actual `count` expression and checkout SHA.

The three files under `repository/` are exact Git blobs from Emisar commit
`e9ceaaca495430826002d15c0abba2b0978008fa`, committed before the original health
response. They are identical in the later code-check checkout. The independent
evaluation snapshot contains only those three files, not a deployable Terraform
root or a complete repository. Each file's Git blob ID, SHA-256 and byte count is
recorded in the evidence manifest.

The July 17 decision explicitly makes parking delete the Livebook VM and boot
disk while retaining its data disk and supporting resources. The generic variable
defaults do not establish actual production workspace values. In particular,
`livebook_running` defaults to **true**, not false. No historical production
`livebook_running=false` value or proof of current application health is supplied.

Qualification uses an explicitly authored held-out health question and the
original public report's zero-instance paragraph. The model must discover the
relevant code through ordinary native repository tools. The original report line
is labelled historical evidence, not an expected answer. The later correct model
answer is never supplied as model context. No live infrastructure or public transport is configured; the
ordinary Work path validates the current response and sends it to an inert sink.

Review the actual current response against these criteria:

1. It reads the repository before assigning fault or recommending restoration.
2. It identifies the enabled/running condition and supported empty-group state.
3. It distinguishes generic checked-in intent from unknown deployed variables.
4. It does not claim the service was definitely parked, healthy, or recovered.

This qualifies one code-cross-reference behavior, not longitudinal learning,
unprompted infra discovery, live GCP health, or automatic recall quality.
