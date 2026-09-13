defmodule Ryker.Learning.Batch do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "conversation_learning_batches" do
    field(:scope_key, :string)
    field(:transport, :string)
    field(:conversation_ref, :string)
    field(:repository_ref, :string)
    field(:execution_mode, Ecto.Enum, values: [:live, :shadow])
    field(:policy, :string)
    field(:policy_digest, :string)
    field(:rebuild_target_id, :binary_id)
    field(:rebuild_target_version, :integer)
    field(:rebuild_target_generation, :integer)
    field(:rebuild_selection, Ryker.CanonicalJSON.Type)

    field(:status, Ecto.Enum,
      values: [:queued, :running, :applied, :no_change, :deferred, :superseded]
    )

    field(:start_count, :integer, default: 0)
    field(:start_limit, :integer, default: 3)
    field(:budget_version, :integer, default: 0)
    field(:input_count, :integer)
    field(:lease_ref, Ecto.UUID)
    field(:lease_owner, :string)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:heartbeat_at, :utc_datetime_usec)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:error_code, :string)
    field(:completed_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @doc "The one key a conversation scope owns a queued or running batch under."
  @spec scope_key(map()) :: String.t()
  def scope_key(scope) do
    scope
    |> Map.update!(:execution_mode, &Atom.to_string/1)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
    |> Ryker.CanonicalJSON.digest()
  end

  @doc """
  Serializes queue assignment — never model execution — so exclusive
  membership and the single active scope stay one decision.
  """
  @spec lock_queue!() :: :ok
  def lock_queue! do
    unless Ryker.Repo.in_transaction?(),
      do: raise(ArgumentError, "the learning queue lock requires a transaction")

    Ryker.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended('learning-queue', 0))")
    :ok
  end
end
