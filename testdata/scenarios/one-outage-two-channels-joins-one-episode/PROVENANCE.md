# Authored cross-conversation routing scenario

`scenario.json` is authored, not harvested, and its provenance says so. The harvested admission
corpus contains no cross-channel case: `docs/elixir-slack-admission-corpus.md` and the routing
baseline both record that the only multi-thread joins on disk are root-to-root inside one channel.
Capturing a real one would require posting a synthetic incident into a production channel, which
the task explicitly forbids.

The two messages are therefore written in the shape the corpus does contain — an Alertmanager
firing card in an alerts channel and an ordinary human question in an engineering channel — and
name the same host, the same symptom and the same environment. No model answer, tool result or
Slack receipt is fabricated: `host_replay.model_events` and `world.tool_rules` are empty, so every
recorded outcome of this scenario comes from a real model run against the real host.

The expectations are host facts, not opinions about wording. `same_session_continuation` holds only
if both messages reached one episode and one session, which is the cross-conversation join itself.
`delivery_target` holds only if the answer was published in the engineering thread the question was
asked in rather than in the alert's channel.

Evaluation-world setup: the world runner joins the channels this scenario's own inputs arrive in as
ordinary non-private, non-externally-shared channels. That is the membership correlation requires;
it grants no access to anything the scenario did not declare.
