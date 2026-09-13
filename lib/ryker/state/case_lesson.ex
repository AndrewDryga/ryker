defmodule Ryker.State.CaseLesson do
  @moduledoc """
  One reusable procedure drawn from a completed case.

  Extraction produces a draft. Only an explicitly reviewed lesson is presented
  as approved guidance, because a historical fix is advice about what worked
  once, never proof that the new incident has the same cause or permission to
  run the same commands.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "episode_case_lessons" do
    field(:lesson_ref, :string)
    field(:case_id, :binary_id)
    field(:workspace_ref, :string)
    field(:conditions, :string)
    field(:steps, :string)
    field(:verification, :string)
    field(:risks, :string)
    field(:status, Ecto.Enum, values: [:draft, :approved, :superseded, :removed], default: :draft)
    field(:reviewed_by_actor_ref, :string)
    field(:reviewed_at, :utc_datetime_usec)
    field(:review_ref, :string)
    field(:supersedes_lesson_id, :binary_id)
    field(:anchor_keys, {:array, :string}, default: [])
    field(:search_text, :string)
    field(:source_refs, {:array, :string}, default: [])
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
