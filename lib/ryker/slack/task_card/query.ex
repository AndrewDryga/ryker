defmodule Ryker.Slack.TaskCard.Query do
  @moduledoc "The Slack cards that show each task, for every read of `slack_task_cards`."
  use Ryker, :query
  alias Ryker.Episodes.Episode
  alias Ryker.Records.Record
  alias Ryker.Slack.TaskCard
  alias Ryker.Work.Turn

  # A card shows its task. While the task works its progress moves, so the card
  # is checked every few seconds (`check_interval_seconds`); otherwise only a
  # person, an event or GitHub moves it, each announced
  # (`Ryker.Slack.TaskCards.check_soon/1`), and the card is checked every ten
  # minutes for anything that was not. Every active card was rebuilt every 2
  # seconds, finished tasks' too: five cards kept an idle install at about 350
  # queries a second (2026-10-04); then every minute, about 140 queries a
  # build, until retention removed it.
  @quiet_check_seconds 600

  def all, do: from(cards in TaskCard, as: :slack_task_cards)

  def by_id(queryable \\ all(), id), do: where(queryable, [slack_task_cards: c], c.id == ^id)
  def by_ref(queryable \\ all(), ref), do: where(queryable, [slack_task_cards: c], c.ref == ^ref)

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [slack_task_cards: c], c.episode_id == ^episode_id)

  @doc "The card posted as message `message_ref` in a channel, and in `thread_ref` when given."
  def by_message(workspace_ref, channel_ref, message_ref, thread_ref) do
    query =
      where(
        all(),
        [slack_task_cards: c],
        c.workspace_ref == ^workspace_ref and c.channel_ref == ^channel_ref and
          c.message_ref == ^message_ref
      )

    if thread_ref,
      do: where(query, [slack_task_cards: c], c.thread_ref == ^thread_ref),
      else: query
  end

  def limit_to(queryable, count), do: limit(queryable, ^count)

  def blocked(queryable \\ all()),
    do: where(queryable, [slack_task_cards: c], c.status == :blocked)

  def ordered_by_recently_updated(queryable),
    do: order_by(queryable, [slack_task_cards: c], desc: c.updated_at, desc: c.id)

  @doc "The active card of `episode_id` whose last check is recorded."
  def checked_for(episode_id) do
    where(
      all(),
      [slack_task_cards: c],
      c.episode_id == ^episode_id and c.status == :active and not is_nil(c.card_checked_at)
    )
  end

  @doc """
  When an active card falls due after `since` by the clock alone: its next
  check (`check_interval_seconds` while its task works, ten minutes
  otherwise), a retry's backoff, or an unrenewed lease, whichever it waits on
  last.
  """
  def select_next_due_after(since, check_interval_seconds) do
    due =
      from(card in all(),
        left_join: episode in Episode,
        on: episode.id == card.episode_id,
        where: card.status == :active,
        select: %{
          due_at:
            type(
              fragment(
                "GREATEST(CASE WHEN ? = 'working' THEN ? ELSE ? END, ?, ?)",
                episode.state,
                datetime_add(card.card_checked_at, ^check_interval_seconds, "second"),
                datetime_add(card.card_checked_at, ^@quiet_check_seconds, "second"),
                card.next_attempt_at,
                card.lease_expires_at
              ),
              :utc_datetime_usec
            )
        }
      )

    from(card in subquery(due), where: card.due_at > ^since, select: min(card.due_at))
  end

  @doc """
  The message of the latest card that shows `episode_id`'s task in channel
  `channel_ref` of `workspace_ref`, thread `thread_ref`.
  """
  def message_in_thread(episode_id, workspace_ref, channel_ref, thread_ref) do
    from(card in all(),
      where:
        card.episode_id == ^episode_id and card.workspace_ref == ^workspace_ref and
          card.channel_ref == ^channel_ref and card.thread_ref == ^thread_ref and
          not is_nil(card.message_ref),
      order_by: [desc: card.inserted_at],
      limit: 1,
      select: card.message_ref
    )
  end

  @doc """
  The active card a worker takes next at `now`, skipping any another holds:
  due and unleased, and never checked (or made due by an announcement),
  checked longer ago than `check_interval_seconds` while its task works, or
  longer ago than the quiet interval.
  """
  def next_claimable(now, check_interval_seconds) do
    due_at = DateTime.add(now, -check_interval_seconds, :second)
    quiet_due_at = DateTime.add(now, -@quiet_check_seconds, :second)

    working =
      from(episode in Episode,
        where: episode.id == parent_as(:slack_task_cards).episode_id and episode.state == :working
      )

    from(card in all(),
      where:
        card.status == :active and
          (is_nil(card.next_attempt_at) or card.next_attempt_at <= ^now) and
          (is_nil(card.lease_expires_at) or card.lease_expires_at <= ^now),
      where:
        is_nil(card.card_checked_at) or card.card_checked_at <= ^quiet_due_at or
          (card.card_checked_at <= ^due_at and exists(working)),
      order_by: [asc_nulls_first: card.card_checked_at, asc: card.updated_at, asc: card.id],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  @doc """
  The oldest confirmed engineering task offer made in Slack that has no card,
  outside `skip`, as `{record, source_turn, episode}`.
  """
  def next_uncarded_offer(skip) do
    from(record in Record,
      join: source_turn in Turn,
      on: source_turn.id == record.turn_id and source_turn.episode_id == record.episode_id,
      join: episode in Episode,
      on: episode.id == record.confirmed_episode_id,
      left_join: card in TaskCard,
      on: card.record_id == record.id,
      where:
        record.kind == "task_offer" and record.status == :confirmed and
          fragment("(?::jsonb)->>'kind' = 'engineering'", record.payload) and
          fragment("(?::jsonb)->>'transport' = 'slack'", source_turn.external_receipt) and
          is_nil(card.id) and record.id not in ^skip,
      order_by: [asc: record.confirmed_at, asc: record.id],
      limit: 1,
      select: {record, source_turn, episode}
    )
  end

  @doc "The title of the task card `ref` shows, as its offer recorded it."
  def task_title(ref) do
    from(card in by_ref(ref),
      join: record in Record,
      on: record.id == card.record_id,
      select: fragment("(?::jsonb)->>'title'", record.payload)
    )
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  @doc "Each card with its task's episode, as `{card, episode}`."
  def select_with_episode(queryable) do
    from(c in queryable, join: e in Episode, on: e.id == c.episode_id, select: {c, e})
  end
end
