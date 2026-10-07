defmodule Ryker.Improvement.CandidateQuery do
  @moduledoc "Requests feedback flagged for review, for every read of `improvement_candidates`."
  import Ecto.Query
  alias Ryker.Improvement.Candidate

  def all, do: from(candidates in Candidate, as: :improvement_candidates)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [improvement_candidates: c], c.id == ^id)

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [improvement_candidates: c], c.episode_id == ^episode_id)

  def by_input_id(queryable \\ all(), input_id),
    do: where(queryable, [improvement_candidates: c], c.input_id == ^input_id)

  def kept(queryable \\ all()),
    do: where(queryable, [improvement_candidates: c], is_nil(c.forgotten_at))

  def created_between(queryable, from, to) do
    where(
      queryable,
      [improvement_candidates: c],
      c.inserted_at >= ^from and c.inserted_at < ^to
    )
  end

  def decided_between(queryable, from, to) do
    where(
      queryable,
      [improvement_candidates: c],
      c.decided_at >= ^from and c.decided_at < ^to
    )
  end

  def with_status(queryable, status),
    do: where(queryable, [improvement_candidates: c], c.status == ^status)

  @doc "Still to analyze, and not dismissed."
  def awaiting_analysis(queryable) do
    where(
      queryable,
      [improvement_candidates: c],
      c.analysis in [:pending, :running] and c.status != :dismissed
    )
  end

  def count_by_category(queryable) do
    queryable
    |> where([improvement_candidates: c], not is_nil(c.category))
    |> group_by([improvement_candidates: c], c.category)
    |> select([improvement_candidates: c], {c.category, count()})
  end

  def quoting_messages(keys) do
    where(
      all(),
      [improvement_candidates: c],
      fragment("? && ?::text[]", c.message_keys, ^keys)
    )
  end

  @doc "Candidates about conversation `conversation_ref` or quoting it."
  def in_conversation(conversation_ref) do
    where(
      all(),
      [improvement_candidates: c],
      c.conversation_ref == ^conversation_ref or
        fragment("? @> ARRAY[?]::text[]", c.conversation_refs, ^conversation_ref)
    )
  end

  @doc """
  What a second signal on a request does to its candidate: one more signal,
  its reason among the others, and the first and last signal times widened.
  """
  def merge_signal do
    from(c in Candidate,
      update: [
        set: [
          reasons:
            fragment(
              "ARRAY(SELECT DISTINCT reason FROM unnest(? || EXCLUDED.reasons) AS reason ORDER BY reason)",
              c.reasons
            ),
          first_signal_at: fragment("LEAST(?, EXCLUDED.first_signal_at)", c.first_signal_at),
          last_signal_at: fragment("GREATEST(?, EXCLUDED.last_signal_at)", c.last_signal_at),
          updated_at: fragment("EXCLUDED.updated_at")
        ],
        inc: [signal_count: 1]
      ]
    )
  end

  def select_ids(queryable), do: select(queryable, [improvement_candidates: c], c.id)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
