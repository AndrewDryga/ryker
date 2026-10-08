defmodule Ryker.Memories.MemoryReviewItem.Query do
  @moduledoc "Reviews of stale and duplicate memories, for every read of `memory_review_items`."
  use Ryker, :query
  alias Ryker.Memories.MemoryReviewItem

  def all, do: from(reviews in MemoryReviewItem, as: :memory_review_items)

  def by_ref(queryable \\ all(), ref),
    do: where(queryable, [memory_review_items: r], r.ref == ^ref)

  def by_workspace(queryable \\ all(), workspace_ref),
    do: where(queryable, [memory_review_items: r], r.workspace_ref == ^workspace_ref)

  def excluding_id(queryable, id), do: where(queryable, [memory_review_items: r], r.id != ^id)

  def pending(queryable \\ all()), do: by_status(queryable, :pending)

  @doc "Reviews in `status`; nil leaves every status."
  def by_status(queryable, nil), do: queryable

  def by_status(queryable, status),
    do: where(queryable, [memory_review_items: r], r.status == ^status)

  @doc """
  Reviews an App Home actor may act on: each names at least one entry, and
  every entry is a fact anyone in the workspace may see, guidance anyone in
  it may see, or the actor's own guidance.
  """
  def home_visible(queryable, workspace_ref, actor_ref) do
    where(
      queryable,
      [memory_review_items: r],
      fragment(
        """
        jsonb_array_length(?::jsonb) > 0 AND NOT EXISTS (
          SELECT 1
          FROM jsonb_array_elements_text(?::jsonb) AS source(ref)
          WHERE NOT (
            EXISTS (
              SELECT 1 FROM operational_memory_entries AS memory
              WHERE memory.ref = source.ref
                AND memory.workspace_ref = ?
                AND memory.visibility = 'workspace'
                AND memory.scope_kind IN ('repository', 'workspace')
            ) OR EXISTS (
              SELECT 1 FROM operator_behaviors AS behavior
              WHERE behavior.ref = source.ref
                AND behavior.workspace_ref = ?
                AND (
                  (behavior.scope_kind = 'operator' AND behavior.scope_ref = ?) OR
                  (behavior.scope_kind IN ('repository', 'workspace') AND
                    behavior.payload::jsonb->>'visibility' = 'workspace')
                )
            )
          )
        )
        """,
        r.entry_refs,
        r.entry_refs,
        ^workspace_ref,
        ^workspace_ref,
        ^actor_ref
      )
    )
  end

  @doc "Reviews that name at most `count` entries."
  def by_entry_count_at_most(queryable, count) do
    where(
      queryable,
      [memory_review_items: r],
      fragment("jsonb_array_length(?::jsonb) <= ?", r.entry_refs, ^count)
    )
  end

  def select_distinct_workspace_refs(queryable) do
    queryable
    |> distinct(true)
    |> select([memory_review_items: r], r.workspace_ref)
  end

  def ordered_by_oldest(queryable),
    do: order_by(queryable, [memory_review_items: r], asc: r.inserted_at, asc: r.id)

  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
