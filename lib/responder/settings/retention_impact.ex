defmodule Responder.Settings.RetentionImpact do
  @moduledoc """
  Bounded estimates of what a shorter horizon would newly expose to cleanup.

  Counts are read from PostgreSQL time and are an operator preview, not the
  cleanup decision: pruning still runs through Retention.Data with every
  custody pin intact.
  """

  alias Responder.Repo

  @queries %{
    operational_data_seconds: [
      {"ingress inputs",
       "SELECT count(*) FROM ingress_inbox_entries WHERE operational_pruned_at IS NULL AND updated_at < clock_timestamp() - ($1 * interval '1 second')"},
      {"work turns",
       "SELECT count(*) FROM episode_work_turns WHERE operational_pruned_at IS NULL AND updated_at < clock_timestamp() - ($1 * interval '1 second')"}
    ],
    conversation_memory_seconds: [
      {"memory entries",
       "SELECT count(*) FROM operational_memory_entries WHERE scope_kind <> 'global' AND updated_at < clock_timestamp() - ($1 * interval '1 second')"},
      {"knowledge topics",
       "SELECT count(*) FROM conversation_knowledge WHERE updated_at < clock_timestamp() - ($1 * interval '1 second')"}
    ],
    closed_work_seconds: [
      {"closed work sessions",
       "SELECT count(*) FROM episode_work_sessions WHERE cleanup_status = 'discarded' AND updated_at < clock_timestamp() - ($1 * interval '1 second')"}
    ],
    episode_history_seconds: [
      {"terminal episodes",
       "SELECT count(*) FROM episode_kernel_episodes WHERE state IN ('complete', 'cancelled') AND history_pruned_at IS NULL AND updated_at < clock_timestamp() - ($1 * interval '1 second')"}
    ],
    audit_data_seconds: [
      {"settings edits",
       "SELECT count(*) FROM settings_edits WHERE inserted_at < clock_timestamp() - ($1 * interval '1 second')"},
      {"instruction edits",
       "SELECT count(*) FROM model_instruction_edits WHERE inserted_at < clock_timestamp() - ($1 * interval '1 second')"},
      {"channel setting audit",
       "SELECT count(*) FROM slack_channel_setting_audit WHERE inserted_at < clock_timestamp() - ($1 * interval '1 second')"}
    ]
  }

  @spec estimate(map(), map()) :: %{atom() => [%{label: String.t(), count: non_neg_integer()}]}
  def estimate(current, proposed) do
    @queries
    |> Enum.filter(fn {field, _queries} ->
      Map.fetch!(proposed, field) < Map.fetch!(current, field)
    end)
    |> Map.new(fn {field, queries} ->
      {field,
       Enum.map(queries, fn {label, sql} ->
         %{rows: [[count]]} = Repo.query!(sql, [Map.fetch!(proposed, field)], log: false)
         %{label: label, count: count}
       end)}
    end)
  end
end
