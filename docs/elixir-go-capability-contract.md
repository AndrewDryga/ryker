# Go to Elixir capability contract

This is the current product-parity ledger for all P0 and P1 behavior retained from the Go runtime or
required by the replacement design. The machine-checked source is
[`elixir-go-capability-contract.json`](elixir-go-capability-contract.json). It names the complete
required behavior, design capability, origin, current Elixir implementation, deterministic proof,
remaining gap, and owning task for every row.

**Implementation status is not deployment proof.** `implemented` means the referenced code and
deterministic test exist in this checkout. It does not mean that commit is deployed, configured, or
proved against Slack, GitHub, Emisar, Coop fleet workers, backup/restore, or another live boundary.
`partial` means the listed subset is usable and tested but the exact gap still belongs to the named
task. A green neighboring capability cannot close that gap.

This whole-product contract complements the narrower
[`elixir-episode-kernel-go-parity.json`](elixir-episode-kernel-go-parity.json), which tracks 230 tests
in 25 legacy lifecycle files. That test manifest is strong evidence for its scope, but it is not a
claim of whole-product parity.

## Snapshot

| Priority | Implemented | Partial | Total |
|---|---:|---:|---:|
| P0 | 28 | 0 | 28 |
| P1 | 6 | 9 | 15 |
| **All** | **34** | **9** | **43** |

## Implemented behavior

| Priority | Capability | Primary implementation | Deterministic proof |
|---|---|---|---|
| P0 | `episode-lifecycle-and-destination` | [`Episodes.Kernel`](../lib/responder/episodes/kernel.ex) | [`kernel_test.exs`](../test/responder/episodes/kernel_test.exs) |
| P0 | `generic-authenticated-webhook-ingress` | [`Webhooks.Router`](../lib/responder/webhooks/router.ex) | [`end_to_end_test.exs`](../test/responder/webhooks/end_to_end_test.exs) |
| P0 | `grafana-lifecycle-webhook-adapter` | [`Webhooks.Transforms`](../lib/responder/webhooks/transforms.ex) | [`adapter_end_to_end_test.exs`](../test/responder/webhooks/adapter_end_to_end_test.exs) |
| P0 | `mapped-json-webhook-adapters` | [`Webhooks.Transforms`](../lib/responder/webhooks/transforms.ex) | [`transforms_test.exs`](../test/responder/webhooks/transforms_test.exs) |
| P0 | `slack-messages-edits-deletes` | [`Slack.Gateway`](../lib/responder/slack/gateway.ex) | [`gateway_test.exs`](../test/responder/slack/gateway_test.exs) |
| P0 | `slack-thread-and-channel-continuation` | [`Slack.Engagement`](../lib/responder/slack/engagement.ex) | [`question_end_to_end_test.exs`](../test/responder/slack/question_end_to_end_test.exs) |
| P0 | `github-comments-reviews-inline-and-reactions` | [`GitHub.Router`](../lib/responder/github/router.ex) | [`github/end_to_end_test.exs`](../test/responder/github/end_to_end_test.exs) |
| P0 | `generic-admission-and-model-routing` | [`Admission.Executor`](../lib/responder/admission/executor.ex) | [`admission/executor_test.exs`](../test/responder/admission/executor_test.exs) |
| P0 | `coop-work-and-same-session-repair` | [`Work.Executor`](../lib/responder/work/executor.ex) | [`work/executor_test.exs`](../test/responder/work/executor_test.exs) |
| P0 | `responder-mcp-state-tools` | [`StateTools.Router`](../lib/responder/state_tools/router.ex) | [`state_tools/router_test.exs`](../test/responder/state_tools/router_test.exs) |
| P0 | `input-attachments-and-screenshots` | [`Slack.AttachmentIngestor`](../lib/responder/slack/attachment_ingestor.ex) | [`attachment_ingestor_test.exs`](../test/responder/slack/attachment_ingestor_test.exs) |
| P0 | `output-files-images-and-charts` | [`Artifacts.Outputs`](../lib/responder/artifacts/outputs.ex) | [`artifact_end_to_end_test.exs`](../test/responder/slack/artifact_end_to_end_test.exs) |
| P0 | `slack-replies-reactions-and-idempotency` | [`Slack.Publisher`](../lib/responder/slack/publisher.ex) | [`publisher_test.exs`](../test/responder/slack/publisher_test.exs) |
| P0 | `github-replies-reactions-and-idempotency` | [`GitHub.Publisher`](../lib/responder/github/publisher.ex) | [`github/publisher_test.exs`](../test/responder/github/publisher_test.exs) |
| P0 | `channel-setup-and-configuration` | [`Slack.ChannelSetup`](../lib/responder/slack/channel_setup.ex) | [`channel_setup_test.exs`](../test/responder/slack/channel_setup_test.exs) |
| P1 | `durable-preferences-rules-and-guidance` | [`State.Memories`](../lib/responder/state/memories.ex) | [`state/memories_test.exs`](../test/responder/state/memories_test.exs) |
| P0 | `engineering-task-fork-diff-and-draft-pr` | [`Slack.TaskCards`](../lib/responder/slack/task_cards.ex) | [`task_end_to_end_test.exs`](../test/responder/slack/task_end_to_end_test.exs) |
| P0 | `contextual-next-step-controls` | [`Slack.InteractionHandler`](../lib/responder/slack/interaction_handler.ex) | [`interaction_handler_test.exs`](../test/responder/slack/interaction_handler_test.exs) |
| P0 | `incident-rooms-timeline-and-postmortem` | [`Slack.IncidentRooms`](../lib/responder/slack/incident_rooms.ex) | [`incident_rooms_test.exs`](../test/responder/slack/incident_rooms_test.exs) |
| P0 | `governed-emisar-actions-and-approvals` | [`Emisar.Approvals`](../lib/responder/emisar/approvals.ex) | [`emisar/end_to_end_test.exs`](../test/responder/emisar/end_to_end_test.exs) |
| P0 | `slack-task-and-incident-cards` | [`Slack.TaskCardProjection`](../lib/responder/slack/task_card_projection.ex) | [`task_end_to_end_test.exs`](../test/responder/slack/task_end_to_end_test.exs) |
| P1 | `slack-app-home-core` | [`Slack.AppHome`](../lib/responder/slack/app_home.ex) | [`app_home_test.exs`](../test/responder/slack/app_home_test.exs) |
| P0 | `local-control-plane-and-conversation-lab` | [`ControlPlane.ConversationLab`](../lib/responder/control_plane/conversation_lab.ex) | [`conversation_lab_end_to_end_test.exs`](../test/responder/control_plane/conversation_lab_end_to_end_test.exs) |
| P0 | `slack-message-shortcut` | [`Slack.Shortcut`](../lib/responder/slack/shortcut.ex) | [`gateway_test.exs`](../test/responder/slack/gateway_test.exs) |
| P0 | `slack-progress-and-bounded-admission` | [`Slack.ThreadStatusWorker`](../lib/responder/slack/thread_status_worker.ex) | [`thread_status_worker_test.exs`](../test/responder/slack/thread_status_worker_test.exs) |
| P0 | `retention-cleanup-and-restart-recovery` | [`Retention.Custody`](../lib/responder/retention/custody.ex) | [`retention/custody_test.exs`](../test/responder/retention/custody_test.exs) |
| P0 | `release-backup-restore-proof` | [`Release`](../lib/responder/release.ex) | [`release_test.exs`](../test/responder/release_test.exs) |
| P0 | `operator-preflight-status-failure-replay` | [`Operator.Actions`](../lib/responder/operator/actions.ex) | [`operator/workflows_test.exs`](../test/responder/operator/workflows_test.exs) |
| P0 | `repository-freshness-receipts` | [`Work.Executor`](../lib/responder/work/executor.ex) and Coop session custody | [`work/executor_test.exs`](../test/responder/work/executor_test.exs) |
| P0 | `publication-conflict-recovery-and-deployment-verification` | [`Publication.Custody`](../lib/responder/publication/custody.ex) | [`publication/followups_test.exs`](../test/responder/publication/followups_test.exs) |
| P1 | `model-choice-byoc-and-execution-metadata` | [`Ingress.WorkProfile`](../lib/responder/ingress/work_profile.ex) | [`product_contracts_test.exs`](../test/responder/product_contracts_test.exs) |
| P1 | `standing-assignments` | [`State.Automations`](../lib/responder/state/automations.ex) | [`automations_test.exs`](../test/responder/state/automations_test.exs) |
| P1 | `github-bounded-context-and-search` | [`GitHub.CapabilityTools`](../lib/responder/github/capability_tools.ex) | [`github/client_test.exs`](../test/responder/github/client_test.exs) |
| P1 | `github-confirmation-backed-actions` | [`GitHub.Confirmations`](../lib/responder/github/confirmations.ex) | [`github/confirmations_test.exs`](../test/responder/github/confirmations_test.exs) |

## Partial behavior and exact owner

| Priority | Capability | What is still missing | Owning task |
|---|---|---|---|
| P1 | `conversation-summaries-and-rollups` | Durable typed situations and bounded continuity rollups. | `2026-09-04-restore-durable-conversation-continuity-and-memo` |
| P1 | `privacy-aware-cross-channel-recall` | Conversation-summary recall with current private-membership intersection. | `2026-09-04-restore-durable-conversation-continuity-and-memo` |
| P1 | `memory-review-controls` | Keep, merge, and edit review in addition to existing forget paths. | `2026-09-04-restore-durable-conversation-continuity-and-memo` |
| P1 | `app-home-navigation-and-recovery-controls` | Exact titles/deep links plus memory, schedule, publication, and workspace recovery actions. | `2026-09-04-complete-slack-app-home-and-task-recovery-contro` |
| P1 | `goal-planning-and-dependencies` | Model-callable goal tools, prerequisite validation, parallel execution, and coordinated finalization. | `2026-09-04-finish-goals-and-multi-repository-orchestration` |
| P1 | `multi-repository-orchestration` | Repository sets, companion snapshots, child goals, and multi-workspace coordination. | `2026-09-04-finish-goals-and-multi-repository-orchestration` |
| P1 | `schedules-run-now-replace-and-history` | Run-now, replace, complete surface coverage, and useful execution history. | `2026-09-04-finish-schedules-subscriptions-and-execution-his` |
| P1 | `subscriptions-and-poll-fallback` | General source subscription state, cursors, and lost-event polling. | `2026-09-04-finish-schedules-subscriptions-and-execution-his` |
| P1 | `operator-incident-schedule-repository-views` | Complete search, incident, schedule, channel, repository, topology, grant, and calibration views. | `2026-09-04-complete-the-local-operator-product-for-incident` |

## Maintenance rule

Any change to one of these behaviors updates the JSON contract and this readable projection in the
same commit. An implemented row must retain at least one real implementation path and deterministic
proof path. A partial row must retain a concrete gap and task owner. Before deployment, live
acceptance is recorded separately for each configured external boundary; it never changes a code row
from partial to implemented.
