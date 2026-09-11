# Contextual retrieval originals

`readiness_thread.json` was harvested on 2026-09-10 from the existing Emisar
`#test` disposable QA thread `1789058307.523479` using the running Slack client.
Only `ts`, `thread_ts`, `text` and `user` were selected; their values are unchanged.
The original failed readiness probe and retained candidate were not changed.

These are actual conversations.replies originals, **not** a successful search
response or a model evaluation. Tests assemble the documented search envelope to
exercise host source identity and cardinality. A fresh action-token-bound search
still needs separate live qualification. The four retained search invocations
inspected before this capture all failed; none is claimed as success evidence.

The two `retained_lookup_*` entries in `testdata/elixir-eval/work.jsonl` use these
unchanged originals with an authored interpretation question. Their bundle structure
is structural; the shared-reference variant is checked against the current
`LookupOriginals.fit` projection. They qualify interpretation, not provider I/O,
MCP tool use, or live end-to-end behavior. Their literal-term score is deliberately
small; inspect the returned full reply as well as its score.
