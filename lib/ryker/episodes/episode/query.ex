defmodule Ryker.Episodes.Episode.Query do
  @moduledoc "Requests (episodes), for every read of `episode_kernel_episodes`."
  import Ecto.Query
  alias Ryker.Delivery.PlatformAction
  alias Ryker.Episodes.{Episode, Event, Origin}
  alias Ryker.Work.Turn

  def all, do: from(episodes in Episode, as: :episode_kernel_episodes)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [episode_kernel_episodes: e], e.id == ^id)

  def by_ids(queryable \\ all(), ids),
    do: where(queryable, [episode_kernel_episodes: e], e.id in ^ids)

  @doc "Requests in conversation `conversation_ref` on `transport`."
  def by_conversation(queryable \\ all(), transport, conversation_ref) do
    where(
      queryable,
      [episode_kernel_episodes: e],
      e.destination_transport == ^transport and
        e.destination_conversation_ref == ^conversation_ref
    )
  end

  @doc """
  The latest `limit` other requests of `episode`'s conversation that finished
  or are working, as outcomes recall them.
  """
  def recent_neighbors(episode, limit) do
    from(e in all(),
      where:
        e.id != ^episode.id and e.destination_transport == ^episode.destination_transport and
          e.destination_conversation_ref == ^episode.destination_conversation_ref and
          e.state in [:complete, :working],
      order_by: [desc: e.updated_at, desc: e.id],
      limit: ^limit
    )
  end

  def by_execution_mode(queryable, execution_mode),
    do: where(queryable, [episode_kernel_episodes: e], e.execution_mode == ^execution_mode)

  def ordered_by_id(queryable), do: order_by(queryable, [episode_kernel_episodes: e], asc: e.id)

  @doc "Episodes Work is running a turn of."
  def working_on_turns(queryable \\ all()) do
    where(
      queryable,
      [episode_kernel_episodes: e],
      e.state == :working and e.owner_kind == :turn
    )
  end

  @doc "Episode `id` while it is working and owned by `owner_kind` `owner_ref`."
  def working_for(id, owner_kind, owner_ref) do
    where(
      all(),
      [episode_kernel_episodes: e],
      e.id == ^id and e.state == :working and e.owner_kind == ^owner_kind and
        e.owner_ref == ^owner_ref
    )
  end

  @doc "Episodes that message `native_input_id` started or joined."
  def joined_by_message(native_input_id) do
    origins =
      native_input_id |> Origin.Query.by_native_input_id() |> Origin.Query.select_episode_ids()

    where(all(), [episode_kernel_episodes: e], e.id in subquery(origins))
  end

  @doc "Episodes that answer in a conversation, or that one of its messages joined."
  def touching_conversation(transport, conversation_ref) do
    origins =
      transport
      |> Origin.Query.by_conversation(conversation_ref)
      |> Origin.Query.select_episode_ids()

    where(
      all(),
      [episode_kernel_episodes: e],
      (e.destination_transport == ^transport and
         e.destination_conversation_ref == ^conversation_ref) or
        e.id in subquery(origins)
    )
  end

  def by_key(queryable \\ all(), key),
    do: where(queryable, [episode_kernel_episodes: e], e.key == ^key)

  def select_request_fields(queryable) do
    select(
      queryable,
      [episode_kernel_episodes: e],
      map(e, [:key, :destination_transport, :destination_conversation_ref])
    )
  end

  def select_destinations(queryable) do
    select(
      queryable,
      [episode_kernel_episodes: e],
      {e.destination_transport, e.destination_conversation_ref}
    )
  end

  @doc "Each episode as `{id, destination_transport, destination_conversation_ref}`."
  def select_id_destinations(queryable) do
    select(
      queryable,
      [episode_kernel_episodes: e],
      {e.id, e.destination_transport, e.destination_conversation_ref}
    )
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  def by_thread(queryable \\ all(), transport, conversation_ref, thread_ref) do
    where(
      queryable,
      [episode_kernel_episodes: e],
      e.destination_transport == ^transport and
        e.destination_conversation_ref == ^conversation_ref and
        e.destination_thread_ref == ^thread_ref
    )
  end

  def by_states(queryable, states),
    do: where(queryable, [episode_kernel_episodes: e], e.state in ^states)

  @doc """
  The episode whose Work turn made delivery `delivery_ref`, with the inputs
  that turn answered, as `{episode, selected_input_refs}`.
  """
  def answered_by_delivery(delivery_ref) do
    from(e in all(),
      join: t in Turn,
      on: t.episode_id == e.id,
      where: t.delivery_ref == ^delivery_ref,
      select: {e, t.selected_input_refs}
    )
  end

  @doc """
  The episode that posted Slack update `action_ref` while its turn worked,
  with the inputs it still answers, as `{episode, active_input_refs}`.
  """
  def updated_by_slack_action(action_ref) do
    from(e in all(),
      join: a in PlatformAction,
      on: a.episode_id == e.id,
      where: a.action_ref == ^action_ref and a.tool == :post_slack_update,
      select: {e, e.active_input_refs}
    )
  end

  @doc """
  The episode working on turn `turn_id` of session `session_id`, with that
  turn, while the turn is pending under lease `lease_ref`.
  """
  def working_on_turn(episode_id, turn_id, session_id, lease_ref) do
    episode_id
    |> by_id()
    |> join(:inner, [episode_kernel_episodes: e], t in Turn,
      on: t.episode_id == e.id,
      as: :episode_work_turns
    )
    |> where([episode_work_turns: t], t.id == ^turn_id and t.session_id == ^session_id)
    |> where(
      [episode_kernel_episodes: e, episode_work_turns: t],
      e.state == :working and e.owner_kind == :turn and e.owner_ref == t.turn_ref
    )
    |> where(
      [episode_work_turns: t],
      t.status == :pending and t.lease_ref == ^lease_ref and
        t.lease_expires_at > fragment("clock_timestamp()")
    )
    |> select([episode_kernel_episodes: e, episode_work_turns: t], {e, t})
  end

  @doc """
  Each live request someone asked something in or Ryker answered in between
  `from` and `to`, as it stands now: whether a turn of it waits on Failures,
  how many answers Ryker gave in it then, and when it last changed by `to`.
  """
  def asked_or_answered_between(from, to) do
    {naive_from, naive_to} = {DateTime.to_naive(from), DateTime.to_naive(to)}

    week_events =
      from(event in Event,
        where:
          event.episode_id == parent_as(:episode_kernel_episodes).id and
            event.kind in [:input_admitted, :result_accepted] and
            event.occurred_at >= ^from and event.occurred_at < ^to
      )

    from(episode in all(),
      where: episode.execution_mode == :live and exists(week_events),
      select: %{
        id: episode.id,
        key: episode.key,
        state: episode.state,
        conversation: episode.destination_conversation_ref,
        stuck:
          fragment(
            "EXISTS (SELECT 1 FROM episode_work_turns AS turn WHERE turn.episode_id = ? AND turn.status = 'blocked')",
            episode.id
          ),
        answers:
          fragment(
            "(SELECT count(*) FROM episode_kernel_events AS event WHERE event.episode_id = ? AND event.kind = 'result_accepted' AND event.occurred_at >= ? AND event.occurred_at < ?)",
            episode.id,
            ^naive_from,
            ^naive_to
          ),
        last_at:
          fragment(
            "(SELECT max(event.occurred_at) FROM episode_kernel_events AS event WHERE event.episode_id = ? AND event.occurred_at < ?)",
            episode.id,
            ^naive_to
          )
      }
    )
  end

  @doc "The earliest hard deadline after `since` of an episode waiting for an event."
  def next_event_deadline_after(since) do
    all()
    |> where(
      [episode_kernel_episodes: e],
      e.state == :waiting_for_event and e.owner_kind == :event and e.owner_deadline_at > ^since
    )
    |> select([episode_kernel_episodes: e], min(e.owner_deadline_at))
  end

  def select_ids(queryable), do: select(queryable, [episode_kernel_episodes: e], e.id)
  def select_keys(queryable), do: select(queryable, [episode_kernel_episodes: e], e.key)

  @doc "Each episode as `{id, key, destination_conversation_ref}`."
  def select_key_conversations(queryable) do
    select(
      queryable,
      [episode_kernel_episodes: e],
      {e.id, e.key, e.destination_conversation_ref}
    )
  end

  @doc "Each episode as `{id, key}`."
  def select_id_keys(queryable),
    do: select(queryable, [episode_kernel_episodes: e], {e.id, e.key})

  def select_execution_modes(queryable),
    do: select(queryable, [episode_kernel_episodes: e], e.execution_mode)

  # Keeps the episode from being deleted until the transaction ends, without
  # blocking anything that only updates it.
  def lock_for_key_share(queryable), do: lock(queryable, "FOR KEY SHARE")
end
