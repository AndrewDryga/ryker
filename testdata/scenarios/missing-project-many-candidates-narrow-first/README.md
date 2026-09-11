# Too many candidates need a narrowing step, not truncation

Same unchanged harvested review and Terraform notification as
`missing-project-review-asks-for-context`; the operator's continuation request is
authored scenario input, hence `synthetic` provenance.

The fabricated `gcp.projects.list` tool (declared in `world.tool_rules`, served by the
offline cassette) answers a broad workload query with twelve projects — more than the
native question pattern can offer — and answers a query narrowed to the portal with
the four portal projects. Rules are matched in id order, so the narrower
`emisar-portal-projects` rule wins whenever both could match, and the broad
`emisar-workload-projects` rule answers everything else.

The product contract says more candidates than the question supports require a
bounded narrowing step, never silent truncation. Either narrowing route is
acceptable: a further scoped listing, or one bounded narrowing question. Offering an
arbitrary subset as if it were the whole list, or implying the unoffered projects do
not exist, fails this case.

No real provider is contacted. A passing offline schema test is not a model-world
result.
