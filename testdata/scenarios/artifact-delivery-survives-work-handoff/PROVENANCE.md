# Artifact handoff fixture

Harvested from the successful local Conversation Lab acceptance, not an external
Slack conversation. The chart's values are explicitly synthetic. Its complete
input, model response and PNG bytes are retained without changing the no-Slack
or no-infrastructure instructions.

- Episode: `ingress-input:936792c0-5a24-4146-a8a5-035737fe6681`
- Input: `a6e8687c-4884-4fdc-bc79-d2c0ce3e32bc`
- Input fingerprint: `ad54c434607ceb0f3b5a4e0cd0799acf7edb80a71a7eaca05979b86883b0a392`
- Source item: `control-plane-item:e07b4a73-63a4-409e-9ecc-774a379e33cc`
- Turn: `132a164e-e0e6-4fe9-8bb9-c4b1e5429f2c`
- Candidate SHA256: `f0d3ea26964510a6ac48228e9e4421f8f02d72f7ea5939e0a4fd91901f376590`
- PNG: `synthetic-request-rate.png`, 82,746 bytes,
  SHA256 `65115459af7411aa45ed14005ba85d13c08f89b7526f29029d1b13532018f966`.

The delivery-response-loss fault is deliberately injected to test the handoff
between Work and delivery. It is not a claim that the original Lab request lost
its receipt. The model-world lane must independently generate and deliver an
image; the stored image is used only by deterministic host replay.
