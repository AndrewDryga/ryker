# Bounded Airflow timer regression

`airflow_after_observation_window.json` preserves the first `record_history`
entry and `runtime.turns[0].candidate` from the fresh private model-world report
`airflow-verification-arms-wait-1788782569746.json` (SHA256
`c3f6a0557bb8b2a8031bd31e6af23a44f03b91d598c1b386d3eeff976db83a80`).
The original failed report remains unchanged. No model reasoning is included.

The model chose `after: 10m` and a bounded deadline. Its valid first turn was
accepted and delivered, but the evaluator rejected the next checkpoint because
it only supported a source-event poll subscription.

The deterministic regression projects the persisted payload back to `wait_for`
arguments, moving `event_matcher.on_timeout` to the tool's top-level argument.
It changes only the deadline to 15 minutes after the test clock, the corresponding
displayed `HH:MM`, and the record reference to the actual tool-created record.
All other trigger, verification, timeout, and candidate text is retained.
The later two turns come unchanged from the older Airflow host replay; they are
not represented as fresh model continuation results. This regression proves
host custody and evaluator execution, not fresh model quality or live delivery.
