defmodule Responder.State.CaseRecord do
  @moduledoc """
  One compact record of work that finished, kept without routine age expiry.

  A case is derived from the episode's own retained evidence and holds no raw
  payload: the problem, the occurrence identities it was reported under, the
  cause when it was actually established, what was attempted, how it ended,
  and the links back to the sources. It outlives the transcript it came from,
  so a matching incident a year later starts new work with the old fix in hand.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "episode_case_records" do
    field(:case_ref, :string)
    field(:episode_id, :binary_id)
    field(:episode_key, :string)
    field(:execution_mode, Ecto.Enum, values: [:live, :shadow])
    field(:transport, :string)
    field(:conversation_ref, :string)
    field(:workspace_ref, :string)
    field(:repository_ref, :string)
    field(:problem, :string)
    field(:occurrence_refs, {:array, :string}, default: [])
    field(:cause, :string)
    field(:attempted_actions, {:array, :string}, default: [])
    field(:outcome, :string)
    field(:links, {:array, :string}, default: [])
    field(:anchor_keys, {:array, :string}, default: [])
    field(:search_text, :string)
    field(:source_refs, {:array, :string}, default: [])
    field(:status, Ecto.Enum, values: [:active, :deleted], default: :active)
    field(:closed_at, :utc_datetime_usec)
    field(:content_fingerprint, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
