defmodule Ryker.ControlPlane.Findings.Query do
  @moduledoc """
  What the Findings page reads (`Ryker.ControlPlane.FindingsProjection`):
  every finding with the request it came from, each view a person or Ryker
  settles it into, its search, the evidence it cites, and which records a
  request's timeline still shows.
  """
  import Ecto.Query
  alias Ryker.Episodes.Episode
  alias Ryker.Records.Record

  @doc "Every finding with its request's id, as `{record, episode_id}`."
  def findings do
    from([episode_state_records: record] in Record.Query.all(),
      join: episode in Episode,
      on: episode.id == record.episode_id,
      where: record.kind == "finding",
      select: {record, episode.id}
    )
  end

  @doc "Record `id` with its request's id, as `{record, episode_id}`."
  def by_id_with_request(id) do
    from([episode_state_records: record] in Record.Query.all(),
      join: episode in Episode,
      on: episode.id == record.episode_id,
      where: record.id == ^id,
      select: {record, episode.id}
    )
  end

  @doc """
  The findings of `queryable` in one view. Settled comes first: a finding a person
  forgot is forgotten, one they marked explained is explained; an open one is
  what Ryker classified it.
  """
  def in_view(queryable, "forgotten"),
    do: where(queryable, [episode_state_records: r], r.status == :dismissed)

  def in_view(queryable, "explained") do
    where(
      queryable,
      [episode_state_records: r],
      r.status == :answered or
        (r.status == :open and fragment("?::jsonb->>'status' = 'explained'", r.payload))
    )
  end

  def in_view(queryable, classification) do
    where(
      queryable,
      [episode_state_records: r],
      r.status == :open and
        fragment("?::jsonb->>'status' = ?", r.payload, ^classification)
    )
  end

  @doc "How many findings of `queryable` each status and classification holds."
  def counts(queryable) do
    from([episode_state_records: r] in exclude(queryable, :select),
      group_by: [r.status, fragment("?::jsonb->>'status'", r.payload)],
      select: {r.status, fragment("?::jsonb->>'status'", r.payload), count()}
    )
  end

  @doc "The findings of `queryable` whose conclusion, reason or scope contains `pattern`."
  def matching(queryable, pattern) do
    where(
      queryable,
      [episode_state_records: r],
      fragment("?::jsonb->>'what' ILIKE ?", r.payload, ^pattern) or
        fragment("?::jsonb->>'reason' ILIKE ?", r.payload, ^pattern) or
        fragment("?::jsonb->>'scope' ILIKE ?", r.payload, ^pattern)
    )
  end

  @doc "The evidence records `refs` of `episode_id`."
  def evidence(episode_id, refs) do
    from(item in Record,
      where: item.kind == "evidence" and item.ref in ^refs and item.episode_id == ^episode_id
    )
  end

  @doc "The ids of the newest `limit` records of each of `episode_ids`: the ones its timeline shows."
  def shown_on_timeline(episode_ids, limit) do
    ranked =
      from(record in Record,
        where: record.episode_id in ^episode_ids,
        select: %{
          id: record.id,
          position:
            over(row_number(),
              partition_by: record.episode_id,
              order_by: [desc: record.sequence, desc: record.id]
            )
        }
      )

    from(record in subquery(ranked), where: record.position <= ^limit, select: record.id)
  end
end
