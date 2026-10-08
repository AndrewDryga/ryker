defmodule Ryker.ControlPlane.RepositoryPage.Query do
  @moduledoc """
  What the Repositories pages read across tables
  (`Ryker.ControlPlane.RepositoryProjection`): how many rows of a kind each
  repository has, and the receipt of the code its tasks last recorded.
  """
  use Ryker, :query
  alias Ryker.Work

  @doc "How many rows of `queryable` name each of `refs` in `field`, as `{ref, count}`."
  def count_by(queryable, field, refs) do
    from(row in queryable,
      where: field(row, ^field) in ^refs,
      group_by: field(row, ^field),
      select: {field(row, ^field), count(row.id)}
    )
  end

  @doc """
  The receipt each of `refs`' tasks last recorded at JSON path `receipt_path`
  of its frozen prompt, as `{ref, recorded_at, receipt}`: its tasks newest
  first, read until a prompt that recorded one. The list read the 500 newest
  tasks' whole prompts, up to 640 KB each, to find these, on every change to
  any request (2026-10-04 review).
  """
  def freshness(refs, receipt_path) do
    # OFFSET 0 keeps the receipt check above the ordering, so it reads each
    # prompt in turn and stops at the first with a receipt, instead of
    # reading every prompt before ordering them.
    newest_first =
      from(turn in Work.Turn,
        join: session in Work.Session,
        on: session.id == turn.session_id,
        where:
          session.repository_ref == parent_as(:repository).ref and not is_nil(turn.submission),
        order_by: [desc: turn.updated_at, desc: turn.id],
        offset: 0,
        select: %{recorded_at: turn.updated_at, submission: turn.submission}
      )

    last_receipt =
      from(task in subquery(newest_first),
        where:
          fragment(
            "jsonb_path_exists(?::jsonb, ?::text::jsonpath)",
            task.submission,
            ^receipt_path
          ),
        limit: 1,
        select: %{
          recorded_at: task.recorded_at,
          receipt:
            fragment(
              "jsonb_path_query_first(?::jsonb, ?::text::jsonpath)",
              task.submission,
              ^receipt_path
            )
        }
      )

    from(repository in fragment("SELECT unnest(?::text[]) AS ref", ^refs),
      as: :repository,
      inner_lateral_join: freshness in subquery(last_receipt),
      on: true,
      select: {repository.ref, freshness.recorded_at, freshness.receipt}
    )
  end
end
