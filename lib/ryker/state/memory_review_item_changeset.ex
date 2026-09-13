defmodule Ryker.State.MemoryReviewItemChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Ryker.State.MemoryReviewItem

  @insert_fields [
    :entry_refs,
    :id,
    :kind,
    :reason,
    :ref,
    :source_digest,
    :status,
    :workspace_ref
  ]

  @spec insert(map()) :: Ecto.Changeset.t()
  def insert(attributes) do
    %MemoryReviewItem{}
    |> cast(attributes, @insert_fields)
    |> validate_required(@insert_fields)
    |> validate_length(:ref, min: 1, max: 256)
    |> validate_length(:workspace_ref, min: 1, max: 1_024)
    |> validate_length(:reason, min: 1, max: 2_000)
    |> validate_format(:source_digest, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint(:ref)
    |> unique_constraint(:source_digest)
    |> check_constraint(:kind, name: :memory_review_item_valid)
  end

  @spec resolve(MemoryReviewItem.t(), map()) :: Ecto.Changeset.t()
  def resolve(%MemoryReviewItem{} = review, attributes) do
    review
    |> cast(attributes, [
      :action,
      :replacement,
      :reviewed_at,
      :reviewed_by_actor_ref,
      :status
    ])
    |> validate_required([:action, :reviewed_at, :reviewed_by_actor_ref, :status])
    |> validate_length(:reviewed_by_actor_ref, min: 1, max: 1_024)
    |> check_constraint(:status, name: :memory_review_item_valid)
  end
end
