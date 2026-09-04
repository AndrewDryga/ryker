defmodule Responder.Retention.Policy do
  @moduledoc """
  Reviewable retention ownership for every PostgreSQL table Responder creates.

  A schema-coverage test compares this list with the migrated database. New
  tables therefore cannot silently become permanent merely because a pruning
  query was forgotten.
  """

  @type class ::
          :operational
          | :conversation_memory
          | :closed_work
          | :episode_history
          | :audit
          | :cascade
          | :kept
  @type policy :: %{class: class(), table: String.t(), why: String.t()}

  @policies [
    %{
      table: "conversation_rollups",
      class: :conversation_memory,
      why: "bounded derived continuity retained after source-summary compaction"
    },
    %{
      table: "conversation_summaries",
      class: :conversation_memory,
      why: "latest typed derived situation for one exact conversation"
    },
    %{
      table: "conversation_summary_drafts",
      class: :operational,
      why: "turn-scoped summary staged until validated result acceptance"
    },
    %{
      table: "coop_session_placements",
      class: :audit,
      why: "immutable worker placement and authority generation for one Coop session"
    },
    %{
      table: "coop_worker_certificates",
      class: :audit,
      why: "issued, rotated, expired, and revoked worker transport identities"
    },
    %{
      table: "coop_worker_commands",
      class: :operational,
      why: "bounded idempotent worker command and result journal"
    },
    %{
      table: "coop_worker_enrollment_tokens",
      class: :operational,
      why: "short-lived single-use bootstrap secret digest and consumption receipt"
    },
    %{
      table: "coop_worker_events",
      class: :operational,
      why: "ordered remote session event staging before local projection"
    },
    %{
      table: "coop_worker_output_transfers",
      class: :cascade,
      why: "temporary verified output bytes owned by one worker command"
    },
    %{
      table: "coop_worker_review_patch_transfers",
      class: :cascade,
      why: "temporary verified review patch owned by one worker command"
    },
    %{
      table: "coop_worker_workspace_checkpoints",
      class: :cascade,
      why: "encrypted portable workspace snapshot owned by one completed worker command"
    },
    %{
      table: "coop_workers",
      class: :kept,
      why: "current operator-authorized worker and certificate registry"
    },
    %{
      table: "delivery_reactions",
      class: :operational,
      why: "one outbound social action and its transport receipt"
    },
    %{
      table: "episode_emisar_approvals",
      class: :episode_history,
      why: "governed action state retained with the episode that requested it"
    },
    %{
      table: "episode_kernel_episodes",
      class: :episode_history,
      why: "the durable aggregate and its routing identity"
    },
    %{
      table: "episode_kernel_events",
      class: :cascade,
      why: "the indivisible event stream of one episode"
    },
    %{
      table: "episode_publication_followups",
      class: :cascade,
      why: "monitoring state owned by one publication"
    },
    %{
      table: "episode_publication_lifecycle_events",
      class: :cascade,
      why: "publication history owned by one publication"
    },
    %{
      table: "episode_publications",
      class: :episode_history,
      why: "review and publication evidence attached to an episode"
    },
    %{
      table: "episode_schedule_occurrences",
      class: :episode_history,
      why: "the account of each durable schedule firing"
    },
    %{
      table: "episode_schedules",
      class: :kept,
      why: "operator-confirmed recurring work kept until terminal and expired"
    },
    %{
      table: "episode_state_record_responses",
      class: :cascade,
      why: "an answer owned by one episode state record"
    },
    %{
      table: "episode_state_records",
      class: :episode_history,
      why: "goals, evidence, waits, findings, and offers in the episode trace"
    },
    %{
      table: "episode_work_sessions",
      class: :audit,
      why: "immutable Coop authority binding and cleanup receipt"
    },
    %{
      table: "episode_work_turns",
      class: :episode_history,
      why: "logical turn history whose large transport bodies expire earlier"
    },
    %{
      table: "ingress_inbox_entries",
      class: :operational,
      why: "normalized source transport and classifier custody"
    },
    %{
      table: "ingress_input_artifact_references",
      class: :cascade,
      why: "input-artifact ownership released when the normalized source body is pruned"
    },
    %{
      table: "input_artifacts",
      class: :operational,
      why: "authenticated downloaded attachment bytes"
    },
    %{
      table: "memory_review_items",
      class: :audit,
      why: "operator keep edit merge forget and dismiss decisions over bounded memory"
    },
    %{
      table: "operational_memory_entries",
      class: :conversation_memory,
      why: "bounded operator-confirmed conversational memory"
    },
    %{
      table: "operator_behaviors",
      class: :kept,
      why: "operator-confirmed preference, guidance, or standing authority"
    },
    %{
      table: "platform_actions",
      class: :episode_history,
      why: "host-authorized Slack or GitHub action intent and exact provider receipt"
    },
    %{
      table: "responder_cutover_items",
      class: :kept,
      why:
        "source-to-target decisions and rollback fingerprints kept after copied legacy bodies expire"
    },
    %{
      table: "responder_cutover_runs",
      class: :kept,
      why: "reviewed legacy-state migration and rollback provenance for this replacement"
    },
    %{
      table: "responder_runtime_progress",
      class: :kept,
      why: "one bounded payload-free current scheduler heartbeat per runtime lane"
    },
    %{
      table: "responder_operator_actions",
      class: :audit,
      why: "idempotent privileged retry and replay decision ledger"
    },
    %{
      table: "retention_operator_actions",
      class: :audit,
      why: "local operator recovery and unmerged-discard decision ledger"
    },
    %{
      table: "schema_migrations",
      class: :kept,
      why: "Ecto migration ledger required to open and upgrade the database"
    },
    %{
      table: "slack_channel_configurations",
      class: :kept,
      why: "saved operator channel configuration"
    },
    %{
      table: "slack_channel_membership_events",
      class: :audit,
      why: "membership transition ledger"
    },
    %{
      table: "slack_channel_memberships",
      class: :kept,
      why: "current bounded workspace membership projection"
    },
    %{
      table: "slack_channel_setting_audit",
      class: :audit,
      why: "operator-facing configuration decision ledger"
    },
    %{
      table: "slack_channel_setting_overrides",
      class: :kept,
      why: "current explicit channel setting overrides"
    },
    %{
      table: "slack_configuration_actions",
      class: :cascade,
      why: "actions owned by one temporary configuration session"
    },
    %{
      table: "slack_configuration_sessions",
      class: :operational,
      why: "temporary App Home and channel setup conversation"
    },
    %{
      table: "slack_incident_room_lifecycle_events",
      class: :cascade,
      why: "platform lifecycle owned by one incident room"
    },
    %{
      table: "slack_incident_rooms",
      class: :closed_work,
      why: "closed incident collaboration surface"
    },
    %{
      table: "slack_interaction_audit",
      class: :audit,
      why: "denied controls and stale-message repaint custody"
    },
    %{
      table: "slack_source_audits",
      class: :audit,
      why: "zero-copy Slack source invocation metadata without returned source bodies"
    },
    %{
      table: "slack_task_cards",
      class: :closed_work,
      why: "presentation projection for a task episode"
    },
    %{
      table: "slack_thread_statuses",
      class: :operational,
      why: "current generation-fenced Slack status intent, retry, and delivery receipt"
    },
    %{
      table: "standing_assignment_runs",
      class: :episode_history,
      why: "the account and dedupe receipt of one assignment firing"
    },
    %{
      table: "work_input_artifact_references",
      class: :cascade,
      why: "input-artifact ownership released with the frozen Work transport body"
    },
    %{
      table: "work_output_artifacts",
      class: :operational,
      why: "generated bytes owned by one logical work turn"
    }
  ]

  @spec all() :: [policy()]
  def all, do: @policies

  @spec fetch(String.t()) :: {:ok, policy()} | :error
  def fetch(table) when is_binary(table) do
    case Enum.find(@policies, &(&1.table == table)) do
      nil -> :error
      policy -> {:ok, policy}
    end
  end

  def fetch(_table), do: :error
end
