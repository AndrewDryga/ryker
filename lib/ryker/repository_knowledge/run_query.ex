defmodule Ryker.RepositoryKnowledge.RunQuery do
  @moduledoc "Each attempt to write a repository's RYKER.md, for every read of `repository_knowledge_runs`."
  import Ecto.Query
  alias Ryker.RepositoryKnowledge.Run

  def all, do: from(runs in Run, as: :repository_knowledge_runs)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [repository_knowledge_runs: r], r.id == ^id)

  def by_repository(queryable \\ all(), ref),
    do: where(queryable, [repository_knowledge_runs: r], r.repository_ref == ^ref)

  @doc "Started and with no stop proof from Coop yet."
  def outstanding(queryable) do
    where(
      queryable,
      [repository_knowledge_runs: r],
      not is_nil(r.started_at) and is_nil(r.remote_stopped_at)
    )
  end

  @doc "An outstanding run of the repository of the parent query's `:repository_knowledge` entry."
  def outstanding_for_parent do
    from(run in Run,
      where:
        run.repository_ref == parent_as(:repository_knowledge).repository_ref and
          not is_nil(run.started_at) and is_nil(run.remote_stopped_at)
    )
  end

  def prepared_unstarted(queryable) do
    where(
      queryable,
      [repository_knowledge_runs: r],
      r.status == :prepared and is_nil(r.started_at)
    )
  end

  def by_ids(queryable \\ all(), ids),
    do: where(queryable, [repository_knowledge_runs: r], r.id in ^ids)

  def newest_first(queryable),
    do: order_by(queryable, [repository_knowledge_runs: r], desc: r.inserted_at, desc: r.id)

  # What a run's card reads before its prompt and answer are opened: every
  # column but the large ones.
  @card_fields Run.__schema__(:fields) -- [:prompt, :result, :document]

  @doc """
  Each run as its card reads it, with the size of its prompt and answer, as
  `{run, prompt_bytes, result_bytes}`.
  """
  def select_cards(queryable) do
    select(
      queryable,
      [repository_knowledge_runs: r],
      {struct(r, ^@card_fields), fragment("octet_length(?)", r.prompt),
       fragment("octet_length(?)", r.result)}
    )
  end

  @doc "Each run's prompt and answer, as `{id, prompt, result}`."
  def select_texts(queryable),
    do: select(queryable, [repository_knowledge_runs: r], {r.id, r.prompt, r.result})

  def oldest_generation_first(queryable),
    do: order_by(queryable, [repository_knowledge_runs: r], asc: r.generation)

  def newest_generation_first(queryable),
    do: order_by(queryable, [repository_knowledge_runs: r], desc: r.generation)

  def select_error_codes(queryable),
    do: select(queryable, [repository_knowledge_runs: r], r.error_code)

  def select_latest_generation(queryable),
    do: select(queryable, [repository_knowledge_runs: r], max(r.generation))

  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
