# Fabricated endpoint scope

The retained source bodies, recorded model events, tool-response cassettes, and expectations in
`scenario.json` are unchanged. Its SHA256 is
`3cd6f0ace1aa08dfa2cae2ee116536e96442708b34a6408d96d42c9e0829b80f`.

On September 8, 2026, three real-model runs failed the required monitoring result because the
cassette only accepted environment `production` or `prod`, while the fixture had not supplied
that scope. The models queried with unknown, unspecified, or empty environment and correctly
reported that independent monitoring verification was unavailable. These original failed reports
are retained; they are not reclassified as passes.

The scenario now owns its catalog instead of borrowing the VA1 catalog. Its one authored change
is the fabricated `monitoring.query` description, which discloses the endpoint's production scope
and says results are historical replay observations. It does not alter source text or add current
health evidence. All external tool schemas and the other external descriptions remain unchanged;
Responder tool definitions are generated from the current registered host catalog as elsewhere.

This is explicit evaluation-world setup, not an additional captured Slack statement or operational
authority. The corrected scenario must be qualified separately from the preserved original runs.
