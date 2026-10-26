defmodule Ryker.Work.CompletionReview.Run.Query do
  @moduledoc false
  use Ryker, :query
  alias Ryker.Work.CompletionReview.Run

  def all, do: from(reviews in Run, as: :work_completion_reviews)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [work_completion_reviews: r], r.id == ^id)

  def by_turn_id(queryable \\ all(), id),
    do: where(queryable, [work_completion_reviews: r], r.turn_id == ^id)

  def by_turn_ids(queryable \\ all(), ids),
    do: where(queryable, [work_completion_reviews: r], r.turn_id in ^ids)

  def ordered_by_generation(queryable),
    do: order_by(queryable, [work_completion_reviews: r], asc: r.generation)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
