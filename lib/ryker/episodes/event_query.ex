defmodule Ryker.Episodes.EventQuery do
  @moduledoc "What happened in each request, for every read of `episode_kernel_events`."
  import Ecto.Query
  alias Ryker.Episodes.Event

  def all, do: from(events in Event, as: :episode_kernel_events)

  @doc "The events of the episode keyed `key`, in order."
  def for_episode_key(key) do
    all()
    |> join(:inner, [episode_kernel_events: e], episode in assoc(e, :episode),
      as: :episode_kernel_episodes
    )
    |> where([episode_kernel_episodes: episode], episode.key == ^key)
    |> order_by([episode_kernel_events: e], e.sequence)
  end

  def of_kind(queryable, kind), do: where(queryable, [episode_kernel_events: e], e.kind == ^kind)

  @doc """
  The events that started wait `wait_ref`, or confirmed a delivery that went
  on to wait on it: the moments a later input answers it.
  """
  def wait_marks(queryable, wait_ref) do
    wait_kinds = [:input_wait_started, :event_wait_started]

    where(
      queryable,
      [episode_kernel_events: e],
      (e.kind in ^wait_kinds and fragment("(?::jsonb)->>'wait_ref' = ?", e.payload, ^wait_ref)) or
        (e.kind == :delivery_confirmed and
           fragment("(?::jsonb)->'next_wait'->>'ref' = ?", e.payload, ^wait_ref))
    )
  end

  def earliest_first(queryable),
    do: order_by(queryable, [episode_kernel_events: e], asc: e.occurred_at, asc: e.sequence)

  def latest_first(queryable),
    do: order_by(queryable, [episode_kernel_events: e], desc: e.occurred_at, desc: e.sequence)

  def select_endpoints(queryable) do
    select(queryable, [episode_kernel_events: e], %{
      episode_id: e.episode_id,
      occurred_at: e.occurred_at,
      payload: e.payload
    })
  end

  def limit_to(queryable, count), do: limit(queryable, ^count)

  def by_dedupe_key(queryable, dedupe_key),
    do: where(queryable, [episode_kernel_events: e], e.dedupe_key == ^dedupe_key)

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [episode_kernel_events: e], e.episode_id == ^episode_id)

  @doc "The admissions of the inputs `dedupe_keys` names."
  def admitted_inputs(queryable, dedupe_keys) do
    where(
      queryable,
      [episode_kernel_events: e],
      e.kind == :input_admitted and e.dedupe_key in ^dedupe_keys
    )
  end

  @doc """
  The admissions from `sequence` on, and of the inputs still queued, which
  `queued_refs` names: what a turn has not answered yet.
  """
  def admitted_since_or_queued(queryable, sequence, queued_refs) do
    where(
      queryable,
      [episode_kernel_events: e],
      e.kind == :input_admitted and (e.sequence >= ^sequence or e.dedupe_key in ^queued_refs)
    )
  end

  def select_payloads(queryable), do: select(queryable, [episode_kernel_events: e], e.payload)

  def by_id(queryable \\ all(), id), do: where(queryable, [episode_kernel_events: e], e.id == ^id)

  def by_episode_ids(queryable \\ all(), episode_ids),
    do: where(queryable, [episode_kernel_events: e], e.episode_id in ^episode_ids)

  def before_sequence(queryable, sequence),
    do: where(queryable, [episode_kernel_events: e], e.sequence < ^sequence)

  def excluding_dedupe_key(queryable, dedupe_key),
    do: where(queryable, [episode_kernel_events: e], e.dedupe_key != ^dedupe_key)

  @doc "The latest `limit` reactions of `episode_id` before `next_sequence`, in order."
  def reactions_before(episode_id, next_sequence, limit) do
    latest =
      episode_id
      |> by_episode_id()
      |> of_kind(:reaction_recorded)
      |> before_sequence(next_sequence)
      |> newest_first()
      |> limit(^limit)
      |> select([episode_kernel_events: e], %{payload: e.payload, sequence: e.sequence})

    from(e in subquery(latest), order_by: e.sequence)
  end

  @doc "The latest `limit` reactions recorded on any of `episode_ids`, in the order recorded."
  def recent_reactions(episode_ids, limit) do
    latest =
      from(e in by_episode_ids(episode_ids),
        where: e.kind == :reaction_recorded,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: ^limit,
        select: %{
          episode_id: e.episode_id,
          id: e.id,
          inserted_at: e.inserted_at,
          occurred_at: e.occurred_at,
          payload: e.payload,
          sequence: e.sequence
        }
      )

    from(e in subquery(latest), order_by: [asc: e.inserted_at, asc: e.id])
  end

  def oldest_first(queryable),
    do: order_by(queryable, [episode_kernel_events: e], asc: e.sequence)

  def newest_first(queryable),
    do: order_by(queryable, [episode_kernel_events: e], desc: e.sequence)
end
