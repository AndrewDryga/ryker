# Routing sentiment fixtures

Harvested on 2026-09-27 from the local Compose install (`ryker-database-1`),
read only, for `test/ryker/admission/sentiment_test.exs`. Each is a person's
Slack message that followed one of Ryker's answers in the same thread, with
the answer before it and the routing model's recorded result for the message
(`admission_attempts.response.assistant_message`), byte for byte.

- `readme-publication-correction.json`: attempt
  `5c743ec2-29a7-4e42-b40f-31f563c7c5e0`. Ryker's Work reply said a push had
  failed and asked for publication access; the person corrected it. Routing
  started new work with the earlier request as history.
- `file-after-quick-answer.json`: attempt
  `ef1234f4-1717-4cfd-a7be-4bffb20427ef`. Routing had answered "Count to 10"
  itself; the person then shared a file nobody could read, and routing left
  it alone.

No recorded answer carries `sentiment` yet: the contract added it on
2026-09-27. Where a test needs one, the fixture says which value was added
and why (`source.reshaped`); the decision fields stay as recorded, except
the reshaping each fixture names.
