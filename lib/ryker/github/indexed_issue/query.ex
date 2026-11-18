defmodule Ryker.GitHub.IndexedIssue.Query do
  @moduledoc false
  use Ryker, :query
  alias Ryker.GitHub.IndexedIssue

  def all, do: from(issues in IndexedIssue, as: :github_indexed_issues)

  def by_index_id(queryable \\ all(), id),
    do: where(queryable, [github_indexed_issues: i], i.index_id == ^id)

  def by_number(queryable, number),
    do: where(queryable, [github_indexed_issues: i], i.number == ^number)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  def next_pending(queryable, now) do
    from(i in queryable,
      where: i.pending and (is_nil(i.next_attempt_at) or i.next_attempt_at <= ^now),
      order_by: [desc: i.triage_pending, asc: i.updated_at, asc: i.id],
      limit: 1
    )
  end

  def search(queryable, text, model, vector) do
    from(i in queryable,
      where: not is_nil(i.document),
      select:
        {i,
         fragment(
           "ts_rank_cd(to_tsvector('simple', ?::text), plainto_tsquery('simple', ?))",
           i.document,
           ^text
         ),
         fragment(
           "CASE WHEN ? = ? THEN (SELECT sum(a * b)::float8 FROM unnest(?, ?::real[]) AS t(a, b)) ELSE 0 END",
           i.embedding_model,
           ^model,
           i.embedding,
           ^vector
         )},
      order_by: [
        desc:
          fragment(
            "ts_rank_cd(to_tsvector('simple', ?::text), plainto_tsquery('simple', ?)) + coalesce(CASE WHEN ? = ? THEN (SELECT sum(a * b)::float8 FROM unnest(?, ?::real[]) AS t(a, b)) ELSE 0 END, 0)",
            i.document,
            ^text,
            i.embedding_model,
            ^model,
            i.embedding,
            ^vector
          )
      ],
      limit: 8
    )
  end
end
