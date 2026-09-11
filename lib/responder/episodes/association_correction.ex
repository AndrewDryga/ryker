defmodule Responder.Episodes.AssociationCorrection do
  @moduledoc """
  One operator-confirmed change of which episode an input belongs to.

  The row is immutable: it records the original membership, who confirmed the
  change and why, so the effective projection can move without touching the
  event ledger or the model submissions that were built from it.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "episode_association_corrections" do
    field(:kind, Ecto.Enum, values: [:merge, :split, :reassign])
    field(:source_episode_id, :binary_id)
    field(:target_episode_id, :binary_id)
    field(:input_refs, {:array, :string}, default: [])
    field(:actor_ref, :string)
    field(:confirmation_ref, :string)
    field(:reason, :string)
    field(:applied_at, :utc_datetime_usec)
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
