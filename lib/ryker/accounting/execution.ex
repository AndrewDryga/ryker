defmodule Ryker.Accounting.Execution do
  @moduledoc "Compact per-Coop-turn accounting for admission, Work and learning executions; this is not a claim of per-provider-call visibility."
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}

  schema "execution_usage" do
    field(:kind, :string)
    field(:source_id, :binary_id)
    field(:generation, :string)
    field(:episode_id, :binary_id)
    field(:session_id, :binary_id)
    field(:transport, :string)
    field(:conversation_ref, :string)
    field(:repository_ref, :string)
    field(:execution_mode, :string)
    field(:remote_ref, :string)
    field(:status, :string)
    field(:execution_target, :string)
    field(:usage_recorded, :boolean, default: false)
    field(:usage_cost_recorded, :boolean, default: false)
    field(:usage_cost_usd, :decimal)
    field(:timing_recorded, :boolean, default: false)
    field(:measurement_error_code, :string)

    for field <- [
          :usage_input_tokens,
          :usage_cached_input_tokens,
          :usage_output_tokens,
          :usage_reasoning_tokens,
          :usage_queued_ms,
          :usage_provider_ms,
          :usage_host_ms
        ] do
      field(field, :integer)
    end

    for field <- [:remote_queued_at, :remote_started_at, :remote_finished_at, :recorded_at] do
      field(field, :utc_datetime_usec)
    end

    timestamps(type: :utc_datetime_usec)
  end
end
