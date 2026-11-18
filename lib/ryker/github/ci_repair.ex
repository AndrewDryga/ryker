defmodule Ryker.GitHub.CIRepair do
  @moduledoc "One PR's automatic repair policy, consecutive-failure budget and delivery custody."
  use Ryker, :schema

  schema "github_ci_repairs" do
    field(:identity, :string)
    field(:binding_ref, :string)
    field(:repository_ref, :string)
    field(:repository_id, :integer)
    field(:installation_id, :integer)
    field(:number, :integer)
    field(:revision, :integer, default: 0)
    field(:generation, :integer, default: 1)
    field(:rounds, :integer, default: 0)
    field(:failure_open, :boolean, default: false)
    field(:pending_heads, {:array, :string}, default: [])
    field(:refresh_requested, :boolean, default: false)
    field(:current_round_id, :binary_id)
    field(:allowed, :boolean, default: false)
    field(:last_attempt_head, :string)
    field(:status, :string, default: "pending")
    field(:observation, Ryker.CanonicalJSON.Type)
    field(:external_receipt, Ryker.CanonicalJSON.Type)
    field(:rendered_fingerprint, :string)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:attempt_count, :integer, default: 0)
    field(:lease_ref, :binary_id)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:last_error, :string)
    timestamps()
  end

  @type t :: %__MODULE__{}
end
