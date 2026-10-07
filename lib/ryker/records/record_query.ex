defmodule Ryker.Records.RecordQuery do
  @moduledoc "Episode state records (findings, citations, offers), for every read of `episode_state_records`."
  import Ecto.Query
  alias Ryker.Episodes.Episode
  alias Ryker.Records.Record
  alias Ryker.Work.Turn

  def all, do: from(records in Record, as: :episode_state_records)

  def by_ref(queryable \\ all(), ref),
    do: where(queryable, [episode_state_records: r], r.ref == ^ref)

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
    |> lock("FOR UPDATE")
  end
end
