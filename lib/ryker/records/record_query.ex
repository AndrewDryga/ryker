defmodule Ryker.Records.RecordQuery do
  @moduledoc "Episode state records (findings, citations, offers), for every read of `episode_state_records`."
  import Ecto.Query
  alias Ryker.Episodes.Episode
  alias Ryker.Records.Record
  alias Ryker.Work.Turn

  def all, do: from(records in Record, as: :episode_state_records)

  def by_id(queryable \\ all(), id), do: where(queryable, [episode_state_records: r], r.id == ^id)

  def by_ref(queryable \\ all(), ref),
    do: where(queryable, [episode_state_records: r], r.ref == ^ref)

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [episode_state_records: r], r.episode_id == ^episode_id)

  def open(queryable \\ all()),
    do: where(queryable, [episode_state_records: r], r.status == :open)

  def with_wait_error(queryable, code),
    do: where(queryable, [episode_state_records: r], r.wait_error == ^code)

  @doc "An episode's open wait `wait_ref`."
  def open_wait(episode_id, wait_ref) do
    episode_id
    |> by_episode_id()
    |> open()
    |> where([episode_state_records: r], r.ref == ^wait_ref and r.kind == "event_wait")
  end

  @doc """
  A watch for a source event with no hard deadline: a question may leave it
  open beside it, and it holds no episode by itself.
  """
  def event_only_wait do
    dynamic(
      [episode_state_records: r],
      r.kind == "event_wait" and
        fragment("?::jsonb->'event_matcher'->>'type' = 'source_event'", r.payload) and
        fragment("?::jsonb->>'deadline_at' IS NULL", r.payload)
    )
  end

  def event_only_waits(queryable), do: where(queryable, ^event_only_wait())

  def oldest_first(queryable),
    do: order_by(queryable, [episode_state_records: r], asc: r.inserted_at, asc: r.id)

  def select_rows(queryable), do: select(queryable, [episode_state_records: r], r)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  def of_kinds(queryable \\ all(), kinds),
    do: where(queryable, [episode_state_records: r], r.kind in ^kinds)

  @doc """
  The offer `ref` of one of `kinds` with the episode and Work turn that made
  it, all three locked, as its confirmation reads them.
  """
  def offer_with_origin(ref, kinds) do
    ref
    |> by_ref()
    |> of_kinds(kinds)
    |> with_origin()
    |> lock("FOR UPDATE")
  end

  @doc "Each record with the episode and the Work turn that made it."
  def with_origin(queryable) do
    queryable
    |> join(:inner, [episode_state_records: r], e in Episode,
      on: e.id == r.episode_id,
      as: :episode_kernel_episodes
    )
    |> join(:inner, [episode_state_records: r], t in Turn,
      on: t.id == r.turn_id and t.episode_id == r.episode_id,
      as: :episode_work_turns
    )
    |> select(
      [episode_state_records: r, episode_kernel_episodes: e, episode_work_turns: t],
      {r, e, t}
    )
  end
end
