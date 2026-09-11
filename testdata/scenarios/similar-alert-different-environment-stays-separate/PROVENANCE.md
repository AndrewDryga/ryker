# Authored negative routing scenario

`scenario.json` is authored, not harvested, and its provenance says so. It is the negative half of
the cross-conversation routing matrix: two alerts that share a service, an alert name, a symptom and
almost all of their wording, and differ only in the environment and the run identity they carry.

The shape follows the harvested lifecycle cards in the admission corpus, where the run identity is
the only trustworthy discriminator between two cycles of one alert rule. No model answer, tool
result or Slack receipt is fabricated: `host_replay.model_events` and `world.tool_rules` are empty.

The hard expectation only fixes where the second answer belongs. Whether the two stay separate is a
judgement about evidence, so it is scored by the rubric rather than asserted as a host fact — a
false merge here is a routing failure, and a finite suite cannot prove the model never makes one.

Evaluation-world setup: the world runner joins the channels this scenario's own inputs arrive in as
ordinary non-private, non-externally-shared channels.
