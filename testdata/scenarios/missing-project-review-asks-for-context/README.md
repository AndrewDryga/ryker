# Missing project after a deployment review

The attached review and Terraform notification are copied unchanged from
`testdata/work/missing-project-clarification.json`: episode
`d60296db-9f67-40db-86ed-f39b7895f23b`, turn
`fd316279-9146-4866-831d-7badf1130f75`, delivered 10 September 2026 at
01:25:14.645141 UTC. The original answer stopped at a missing GCP project ID.

The operator's continuation request and isolated Slack destination are authored
scenario setup, not a captured production request. Hence `synthetic` provenance.
There is no invented model answer, project list, health result or provider receipt.
No discovery provider is configured in this scenario: after checking memory, the
model must ask for the missing project and keep the exact run watch. This tests
the no-candidates branch, not successful external project discovery.

The catalog is generated from the actual fixed state-tool schemas. Production
source/action tools are absent; delivery remains inside the model-world publisher.
Host behavior is independently covered by the typed/native question end-to-end
tests. A passing offline schema test is not a model-world or live Slack result.
