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
| P1 | 16 | 0 | 16 |
| **All** | **44** | **0** | **44** |

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
| P1 | `conversation-summaries-and-rollups` | [`State.Continuity`](../lib/responder/state/continuity.ex) | [`state/continuity_test.exs`](../test/responder/state/continuity_test.exs) |
| P1 | `learning-without-responding` | [`Learning.Executor`](../lib/responder/learning/executor.ex), [`State.Learning`](../lib/responder/state/learning.ex), and [`State.Knowledge`](../lib/responder/state/knowledge.ex) | [`learning/dispatcher_test.exs`](../test/responder/learning/dispatcher_test.exs), [`state/learning_failure_test.exs`](../test/responder/state/learning_failure_test.exs), and [`state/knowledge_anchors_test.exs`](../test/responder/state/knowledge_anchors_test.exs) |
| P1 | `privacy-aware-cross-channel-recall` | [`State.MemorySearch`](../lib/responder/state/memory_search.ex), [`State.Continuity`](../lib/responder/state/continuity.ex), and [`State.KnowledgeSnapshot`](../lib/responder/state/knowledge_snapshot.ex) | [`state_tools/memory_search_test.exs`](../test/responder/state_tools/memory_search_test.exs), [`state/continuity_test.exs`](../test/responder/state/continuity_test.exs), and [`state/knowledge_snapshot_capacity_test.exs`](../test/responder/state/knowledge_snapshot_capacity_test.exs) |
| P1 | `memory-review-controls` | [`Slack.AppHomeEditor`](../lib/responder/slack/app_home_editor.ex) and [`State.Memories`](../lib/responder/state/memories.ex) | [`slack/app_home_editor_test.exs`](../test/responder/slack/app_home_editor_test.exs) and [`state/memories_test.exs`](../test/responder/state/memories_test.exs) |
| P1 | `app-home-navigation-and-recovery-controls` | [`Slack.AppHomeProjection`](../lib/responder/slack/app_home_projection.ex) and [`Slack.AppHomeControls`](../lib/responder/slack/app_home_controls.ex) | [`slack/app_home_projection_test.exs`](../test/responder/slack/app_home_projection_test.exs) and [`slack/app_home_actions_test.exs`](../test/responder/slack/app_home_actions_test.exs) |
| P1 | `operator-incident-schedule-repository-views` | [`ControlPlane.OperatorProjection`](../lib/responder/control_plane/operator_projection.ex) | [`control_plane/projection_test.exs`](../test/responder/control_plane/projection_test.exs) and [`control_plane/router_test.exs`](../test/responder/control_plane/router_test.exs) |
| P1 | `goal-planning-and-dependencies` | [`State.Records`](../lib/responder/state/records.ex) and [`StateTools.FixedTools`](../lib/responder/state_tools/fixed_tools.ex) | [`state/records_test.exs`](../test/responder/state/records_test.exs) and [`state_tools/router_test.exs`](../test/responder/state_tools/router_test.exs) |
| P1 | `multi-repository-orchestration` | [`RuntimeConfiguration`](../lib/responder/runtime_configuration.ex), [`Ingress.WorkProfile`](../lib/responder/ingress/work_profile.ex), and [`Work.Executor`](../lib/responder/work/executor.ex) | [`runtime_configuration_test.exs`](../test/responder/runtime_configuration_test.exs), [`work/custody_test.exs`](../test/responder/work/custody_test.exs), and [`work/executor_test.exs`](../test/responder/work/executor_test.exs) |
| P1 | `schedules-run-now-replace-and-history` | [`State.Schedules`](../lib/responder/state/schedules.ex), [`State.Automations`](../lib/responder/state/automations.ex), and [`ControlPlane.OperatorProjection`](../lib/responder/control_plane/operator_projection.ex) | [`state/schedules_test.exs`](../test/responder/state/schedules_test.exs), [`state/automations_test.exs`](../test/responder/state/automations_test.exs), and [`control_plane/projection_test.exs`](../test/responder/control_plane/projection_test.exs) |
| P1 | `subscriptions-and-poll-fallback` | [`State.EventSubscriptions`](../lib/responder/state/event_subscriptions.ex) and [`State.EventWaits`](../lib/responder/state/event_waits.ex) | [`state/event_waits_test.exs`](../test/responder/state/event_waits_test.exs) and [`work/result_custody_test.exs`](../test/responder/work/result_custody_test.exs) |

## Partial behavior and exact owner

There are no remaining P0 or P1 implementation gaps in this contract. Deployment, configured live
acceptance, and production qualification remain separate evidence boundaries.

For the memory changes, the checked implementation boundary includes independent learning,
update-or-create identity, source custody, and paged historical recall. It does not assert that a
configured learning policy is running or that a real model reliably chooses the right topic.
[The runtime contract](elixir-work-runtime.md#memory-and-background-learning) describes those
interfaces; [memory evaluation](memory-evaluation.md) separates deterministic regression proof from
the required harvested, longitudinal model cases and live cleanup qualification.

## Maintenance rule

Any change to one of these behaviors updates the JSON contract and this readable projection in the
same commit. An implemented row must retain at least one real implementation path and deterministic
proof path. A partial row must retain a concrete gap and task owner. Before deployment, live
acceptance is recorded separately for each configured external boundary; it never changes a code row
from partial to implemented.
