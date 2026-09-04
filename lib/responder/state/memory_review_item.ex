defmodule Responder.State.MemoryReviewItem do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "memory_review_items" do
    field(:ref, :string)
    field(:workspace_ref, :string)
    field(:kind, Ecto.Enum, values: [:stale, :duplicate])
    field(:entry_refs, Responder.CanonicalJSON.Type)
    field(:reason, :string)
    field(:source_digest, :string)
    field(:status, Ecto.Enum, values: [:pending, :kept, :applied, :dismissed])
    field(:action, Ecto.Enum, values: [:keep, :merge, :edit, :forget, :dismiss])
    field(:reviewed_by_actor_ref, :string)
    field(:reviewed_at, :utc_datetime_usec)
    field(:replacement, Responder.CanonicalJSON.Type)
    timestamps(type: :utc_datetime_usec)
  end
end
