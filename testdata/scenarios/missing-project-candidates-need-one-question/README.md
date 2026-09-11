# Several real candidates become one narrowing question

Same unchanged harvested review and Terraform notification as
`missing-project-review-asks-for-context`; the operator's continuation request is
authored scenario input, hence `synthetic` provenance.

The fabricated `gcp.projects.list` tool (declared in `world.tool_rules`, served by the
offline cassette, never a real provider) returns four genuinely ambiguous candidates
for this workload. They differ only by environment, which is exactly the fact the
review is missing, so no evidence in the scenario can choose between them.

The expected behavior is one narrowing question offering the real projects with
useful names and exact project IDs — a project ID is meaningful selection data,
unlike an internal record ID — while keeping the exact `run-t2W6yCNeLUU9xFso` watch
and marking the mapping question reusable. Guessing an environment, inventing a
project or falling back to the verification-gap paragraph all fail this case.

Candidate counts above what one question can offer are covered separately by
`missing-project-many-candidates-narrow-first`. A passing offline schema test is not
a model-world result.
