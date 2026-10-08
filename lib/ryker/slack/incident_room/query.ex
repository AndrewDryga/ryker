defmodule Ryker.Slack.IncidentRoom.Query do
  @moduledoc "Slack channels opened for incidents, for every read of `slack_incident_rooms`."
  use Ryker, :query
  alias Ryker.Episodes
  alias Ryker.Records
  alias Ryker.Slack.{ChannelConfiguration, IncidentRoom}
  alias Ryker.Work

  # A ready room's pinned card shows its investigation. While that works the
  # card moves, so it is checked every few seconds (`root_card_check_seconds`);
  # otherwise its changes are announced (`Ryker.Slack.IncidentRooms.check_card_soon/1`)
  # and it is checked every ten minutes for anything that was not. Every ready
  # room was checked every 2 seconds, two writes and a full card build each
  # time (2026-10-04 review).
  @quiet_root_card_seconds 600

  def all, do: from(rooms in IncidentRoom, as: :slack_incident_rooms)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [slack_incident_rooms: r], r.id == ^id)

  def by_ref(queryable \\ all(), ref),
    do: where(queryable, [slack_incident_rooms: r], r.ref == ^ref)

  def by_record_id(queryable \\ all(), record_id),
    do: where(queryable, [slack_incident_rooms: r], r.record_id == ^record_id)

  def by_channel(queryable \\ all(), workspace_ref, channel_ref) do
    where(
      queryable,
      [slack_incident_rooms: r],
      r.workspace_ref == ^workspace_ref and r.channel_ref == ^channel_ref
    )
  end

  @doc "The room whose pinned card is message `message_ref` of a channel."
  def by_root_message(workspace_ref, channel_ref, message_ref) do
    where(
      all(),
      [slack_incident_rooms: r],
      r.workspace_ref == ^workspace_ref and r.channel_ref == ^channel_ref and
        r.root_message_ref == ^message_ref
    )
  end

  def limit_to(queryable, count), do: limit(queryable, ^count)

  @doc "The rooms `episode_id` investigates or was opened from."
  def by_episode_or_source(queryable \\ all(), episode_id) do
    where(
      queryable,
      [slack_incident_rooms: r],
      r.episode_id == ^episode_id or r.source_episode_id == ^episode_id
    )
  end

  def ordered_by_requested_at_desc(queryable),
    do: order_by(queryable, [slack_incident_rooms: r], desc: r.requested_at, desc: r.id)

  def blocked(queryable \\ all()),
    do: where(queryable, [slack_incident_rooms: r], r.status == :blocked)

  def ordered_by_recently_updated(queryable),
    do: order_by(queryable, [slack_incident_rooms: r], desc: r.updated_at, desc: r.id)

  @doc "Rooms of `workspace_ref` not closed yet."
  def open_in_workspace(workspace_ref) do
    where(
      all(),
      [slack_incident_rooms: r],
      r.workspace_ref == ^workspace_ref and r.status != :closed
    )
  end

  @doc "The ready room investigating `episode_id` whose pinned card was checked."
  def card_checked_for(episode_id) do
    where(
      all(),
      [slack_incident_rooms: r],
      r.episode_id == ^episode_id and r.status == :ready and not is_nil(r.root_card_checked_at)
    )
  end

  @doc """
  The open incident offers delivered in `workspace_ref`'s channels set to open
  a room by themselves, with no room yet and not among `refused`, as
  `{record, turn, episode}`, the earliest delivered first; at most 25.
  """
  def automatic_candidates(workspace_ref, refused) do
    offers = offers_with_channel(workspace_ref)

    from(
      [episode_state_records: record, episode_work_turns: turn, episode_kernel_episodes: episode] in offers,
      where: ^open_incident_offer(refused),
      where: ^delivered_in_slack(),
      where: ^automatic_without_room(workspace_ref),
      order_by: [asc: turn.delivered_at, asc: record.inserted_at, asc: record.id],
      limit: 25,
      select: {record, turn, episode}
    )
  end

  # Each offer with the turn that delivered it, its episode, the setup of the
  # channel it was delivered to in `workspace_ref`, and its room if it has one.
  defp offers_with_channel(workspace_ref) do
    from([episode_state_records: record] in Records.Record.Query.all(),
      join: turn in Work.Turn,
      as: :episode_work_turns,
      on: turn.id == record.turn_id and turn.episode_id == record.episode_id,
      join: episode in Episodes.Episode,
      as: :episode_kernel_episodes,
      on: episode.id == record.episode_id,
      join: configuration in ChannelConfiguration,
      as: :slack_channel_configurations,
      on:
        configuration.workspace_ref == ^workspace_ref and
          configuration.channel_ref ==
            fragment("split_part(?, ':', 3)", episode.destination_conversation_ref),
      left_join: room in IncidentRoom,
      as: :slack_incident_rooms,
      on: room.record_id == record.id
    )
  end

  defp open_incident_offer(refused) do
    dynamic(
      [episode_state_records: r],
      r.kind == "task_offer" and r.status == :open and
        fragment("(?::jsonb ->> 'kind') = 'incident'", r.payload) and r.ref not in ^refused
    )
  end

  defp delivered_in_slack do
    dynamic(
      [episode_work_turns: t, episode_kernel_episodes: e],
      t.status == :settled and not is_nil(t.external_receipt) and
        e.destination_transport == "slack"
    )
  end

  defp automatic_without_room(workspace_ref) do
    dynamic(
      [episode_kernel_episodes: e, slack_channel_configurations: c, slack_incident_rooms: i],
      fragment("split_part(?, ':', 2)", e.destination_conversation_ref) == ^workspace_ref and
        c.alert_policy == :automatic and is_nil(i.id)
    )
  end

  @doc """
  When rooms have work by the clock alone after `since`, as `[lifecycle,
  health, root_card]`: a request or lifecycle change retried after a backoff,
  a health check due `health_check_seconds` after the last, a pinned card due
  its check `root_card_check_seconds` after the last, or an unrenewed lease
  running out.
  """
  def select_next_due_after(since, health_check_seconds, root_card_check_seconds) do
    phases =
      from(room in all(),
        where: room.status in [:requested, :ready],
        select: %{
          lifecycle:
            type(
              fragment(
                "CASE WHEN (? = 'requested' AND ? IN ('pending', 'active')) OR (? = 'ready' AND ? <> ?) OR (? IN ('requested', 'ready') AND ? IS NOT NULL) THEN GREATEST(?, ?) END",
                room.status,
                room.channel_state,
                room.status,
                room.channel_state,
                room.reconciled_channel_state,
                room.status,
                room.close_requested_at,
                room.next_attempt_at,
                room.lease_expires_at
              ),
              :utc_datetime_usec
            ),
          health:
            type(
              fragment(
                "CASE WHEN ? = 'ready' AND ? <> 'deleted' AND ? = ? AND ? IS NULL THEN GREATEST(?, ?) END",
                room.status,
                room.channel_state,
                room.channel_state,
                room.reconciled_channel_state,
                room.close_requested_at,
                datetime_add(room.channel_checked_at, ^health_check_seconds, "second"),
                room.lease_expires_at
              ),
              :utc_datetime_usec
            ),
          root_card:
            type(
              fragment(
                "CASE WHEN ? = 'ready' AND ? = 'active' AND ? = 'active' AND ? IS NOT NULL AND ? IS NULL THEN GREATEST(?, ?) END",
                room.status,
                room.channel_state,
                room.reconciled_channel_state,
                room.root_message_ref,
                room.close_requested_at,
                fragment(
                  "? + (CASE WHEN EXISTS (SELECT 1 FROM episode_kernel_episodes AS episode WHERE episode.id = ? AND episode.state = 'working') THEN ?::integer ELSE ?::integer END) * interval '1 second'",
                  room.root_card_checked_at,
                  room.episode_id,
                  ^root_card_check_seconds,
                  ^@quiet_root_card_seconds
                ),
                room.lease_expires_at
              ),
              :utc_datetime_usec
            )
        }
      )

    from(room in subquery(phases),
      select: [
        filter(min(room.lifecycle), room.lifecycle > ^since),
        filter(min(room.health), room.health > ^since),
        filter(min(room.root_card), room.root_card > ^since)
      ]
    )
  end

  @doc """
  The closed room of a deleted channel whose investigation still waits or
  works, oldest first: an investigation nothing will ever answer.
  """
  def next_orphaned_investigation do
    from(room in all(),
      join: episode in Episodes.Episode,
      on: episode.id == room.episode_id,
      left_join: turn in Work.Turn,
      on:
        turn.episode_id == episode.id and episode.owner_kind == :turn and
          turn.turn_ref == episode.owner_ref,
      where: room.status == :closed and room.channel_state == :deleted,
      where:
        episode.state in [:waiting_for_input, :waiting_for_event] or
          (episode.state == :working and episode.owner_kind == :turn and
             (is_nil(turn.id) or turn.status != :cancel_pending)),
      order_by: [asc: room.updated_at, asc: room.id],
      limit: 1,
      select: {room, episode}
    )
  end

  @doc """
  The room a worker takes next at `now`, skipping any another holds: one with
  a step to take (setting up, catching up with its channel, or closing on a
  person's request), due and unleased. A room a person asked to close comes
  first, whatever step it is at.
  """
  def next_claimable(now) do
    from(room in all(),
      where: ^next_step(),
      where: ^unleased_and_due(now),
      order_by: [
        asc_nulls_last: room.close_requested_at,
        asc: fragment("CASE WHEN ? = 'ready' THEN 0 ELSE 1 END", room.status),
        asc: room.updated_at,
        asc: room.id
      ],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  defp next_step do
    dynamic(
      [slack_incident_rooms: r],
      (r.status == :requested and r.channel_state in [:pending, :active]) or
        (r.status == :ready and r.channel_state != r.reconciled_channel_state) or
        (r.status in [:requested, :ready] and not is_nil(r.close_requested_at))
    )
  end

  defp unleased_and_due(now) do
    dynamic(
      [slack_incident_rooms: r],
      (is_nil(r.next_attempt_at) or r.next_attempt_at <= ^now) and
        (is_nil(r.lease_expires_at) or r.lease_expires_at <= ^now)
    )
  end

  @doc """
  The open room settled with its channel whose last check is no later than
  `due_at`, unleased at `now`, the longest unchecked first; a room being
  closed is checked no more.
  """
  def next_health_check(due_at, now) do
    from(room in all(),
      where:
        room.status == :ready and room.channel_state != :deleted and
          room.channel_state == room.reconciled_channel_state and
          is_nil(room.close_requested_at) and
          (is_nil(room.channel_checked_at) or room.channel_checked_at <= ^due_at) and
          (is_nil(room.lease_expires_at) or room.lease_expires_at <= ^now),
      order_by: [asc_nulls_first: room.channel_checked_at, asc: room.id],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  @doc """
  The ready room whose pinned card is due its check at `now`: never checked
  (or made due by an announcement), checked longer ago than
  `check_interval_seconds` while its investigation works, or longer ago than
  the quiet interval.
  """
  def next_root_card(now, check_interval_seconds) do
    due_at = DateTime.add(now, -check_interval_seconds, :second)
    quiet_due_at = DateTime.add(now, -@quiet_root_card_seconds, :second)

    working =
      from(episode in Episodes.Episode,
        where:
          episode.id == parent_as(:slack_incident_rooms).episode_id and
            episode.state == :working
      )

    from(room in all(),
      where: ^pinned_in_live_channel(now),
      where:
        is_nil(room.root_card_checked_at) or room.root_card_checked_at <= ^quiet_due_at or
          (room.root_card_checked_at <= ^due_at and exists(working)),
      order_by: [
        asc_nulls_first: room.root_card_checked_at,
        asc: room.updated_at,
        asc: room.id
      ],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  # A ready room with a pinned card in a channel settled active, no close
  # asked for, and unleased at `now`.
  defp pinned_in_live_channel(now) do
    dynamic(
      [slack_incident_rooms: r],
      r.status == :ready and r.channel_state == :active and
        r.reconciled_channel_state == :active and not is_nil(r.root_message_ref) and
        is_nil(r.close_requested_at) and
        (is_nil(r.lease_expires_at) or r.lease_expires_at <= ^now)
    )
  end

  def select_titles(queryable), do: select(queryable, [slack_incident_rooms: r], r.title)

  def select_episode_ids(queryable),
    do: select(queryable, [slack_incident_rooms: r], r.episode_id)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  @doc "Each room with its investigation's episode, as `{room, episode}`."
  def select_with_episode(queryable) do
    from(r in queryable, join: e in Episodes.Episode, on: e.id == r.episode_id, select: {r, e})
  end
end
