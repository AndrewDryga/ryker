defmodule Ryker.Memories.MemoryReviewItem do
  @moduledoc false
  use Ryker, :schema

  schema "memory_review_items" do
    field(:ref, :string)
    field(:workspace_ref, :string)
    field(:kind, Ecto.Enum, values: [:stale, :duplicate])
    field(:entry_refs, Ryker.CanonicalJSON.Type)
    field(:reason, :string)
    field(:source_digest, :string)
    field(:status, Ecto.Enum, values: [:pending, :kept, :applied, :dismissed])
    field(:action, Ecto.Enum, values: [:keep, :merge, :edit, :forget, :dismiss])
    field(:reviewed_by_actor_ref, :string)
    field(:reviewed_at, :utc_datetime_usec)
    field(:replacement, Ryker.CanonicalJSON.Type)
    timestamps()
  end

  @type t :: %__MODULE__{}
end
