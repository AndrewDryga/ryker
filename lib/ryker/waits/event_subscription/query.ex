defmodule Ryker.Waits.EventSubscription.Query do
  @moduledoc "When each open wait is next looked at, for every read of `episode_event_subscriptions`."
  use Ryker, :query
  alias Ryker.Episodes
  alias Ryker.Records
  alias Ryker.Waits.EventSubscription

  @deadline_matches_payload "CASE WHEN pg_input_is_valid(?::jsonb->>'deadline_at', 'timestamptz') THEN (?::jsonb->>'deadline_at')::timestamptz = ? ELSE false END"

  def all, do: from(subscriptions in EventSubscription, as: :episode_event_subscriptions)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [episode_event_subscriptions: s], s.id == ^id)

  def by_record_id(queryable \\ all(), record_id),
    do: where(queryable, [episode_event_subscriptions: s], s.record_id == ^record_id)

  def active(queryable \\ all()),
    do: where(queryable, [episode_event_subscriptions: s], s.status == :active)

  @doc "The active subscriptions of `episode_id`'s own waits, each with the wait's id and ref."
  def active_in_episode(episode_id) do
    from(subscription in active(),
      join: record in Records.Record,
      on: record.id == subscription.record_id,
      where: subscription.episode_id == ^episode_id and record.episode_id == ^episode_id,
      select: %{record_id: record.id, ref: record.ref, subscription_id: subscription.id}
    )
  end

  @doc """
  Open waits with no subscription yet, the earliest deadline first and at
  most `limit`: each with the episode it belongs to. A wait Ryker failed to
  schedule before `retry_before` is taken again.
  """
  def unsubscribed_waits(retry_before, limit) do
    from(episode in Episodes.Episode,
      as: :episode_kernel_episodes,
      join: record in Records.Record,
      as: :episode_state_records,
      on: record.episode_id == episode.id,
      left_join: subscription in EventSubscription,
      on: subscription.record_id == record.id,
      where: ^retained_wait([:waiting_for_input]),
      where: record.kind == "event_wait" and record.status == :open,
      where:
        is_nil(record.wait_error) or
          (record.wait_error == "schedule_failed" and record.updated_at <= ^retry_before),
      where: is_nil(subscription.id),
      where:
        fragment("?::jsonb->'event_matcher'->>'type'", record.payload) in [
          "after",
          "at",
          "source_event"
        ],
      order_by: [asc: episode.owner_deadline_at, asc: episode.id],
      limit: ^limit,
      select: %{episode: episode, record_id: record.id}
    )
  end

  @doc "Active subscriptions whose wait no longer holds its episode or is no longer open, at most `limit`."
  def stale(limit) do
    stale_wait =
      dynamic(
        [episode_state_records: record],
        not (^retained_wait([:waiting_for_input, :working])) or record.status != :open
      )

    from(subscription in all(),
      join: episode in Episodes.Episode,
      as: :episode_kernel_episodes,
      on: episode.id == subscription.episode_id,
      join: record in Records.Record,
      as: :episode_state_records,
      on: record.id == subscription.record_id,
      where: subscription.status == :active,
      where: ^stale_wait,
      order_by: [asc: subscription.id],
      limit: ^limit,
      select: %{
        episode_id: subscription.episode_id,
        episode_state: episode.state,
        record_id: record.id,
        record_status: record.status,
        ref: record.ref,
        subscription_id: subscription.id
      }
    )
  end

  @doc """
  The subscribed wait due first at `now`: its poll time has come before its
  deadline, it still holds its episode, and a wait Ryker failed to resume
  before `retry_before` is taken again.
  """
  def due(now, retry_before) do
    from(subscription in all(),
      join: episode in Episodes.Episode,
      on: episode.id == subscription.episode_id,
      join: record in Records.Record,
      on: record.id == subscription.record_id,
      where:
        subscription.status == :active and subscription.poll_after <= ^now and
          subscription.deadline_at > ^now,
      where: episode.state == :waiting_for_event and episode.owner_kind == :event,
      where: episode.owner_ref == record.ref and record.episode_id == episode.id,
      where: record.status == :open,
      where:
        is_nil(record.wait_error) or
          (record.wait_error == "resume_failed" and record.updated_at <= ^retry_before),
      where: subscription.deadline_at == episode.owner_deadline_at,
      where:
        fragment(
          @deadline_matches_payload,
          record.payload,
          record.payload,
          episode.owner_deadline_at
        ),
      order_by: [asc: subscription.poll_after, asc: subscription.id],
      limit: 1,
      select: %{
        episode_id: episode.id,
        record_id: record.id,
        subscription_id: subscription.id
      }
    )
  end

  @doc """
  The wait whose hard deadline passed first by `now`, with or without a
  subscription: one Ryker failed to resume before `retry_before` is taken
  again.
  """
  def deadline_due(now, retry_before) do
    from(episode in Episodes.Episode,
      join: record in Records.Record,
      on: record.episode_id == episode.id and record.ref == episode.owner_ref,
      left_join: subscription in EventSubscription,
      on: subscription.record_id == record.id,
      where: episode.state == :waiting_for_event and episode.owner_kind == :event,
      where: episode.owner_deadline_at <= ^now,
      where: record.kind == "event_wait" and record.status == :open,
      where:
        is_nil(record.wait_error) or record.wait_error != "resume_failed" or
          record.updated_at <= ^retry_before,
      where:
        fragment(
          @deadline_matches_payload,
          record.payload,
          record.payload,
          episode.owner_deadline_at
        ),
      where:
        is_nil(subscription.id) or
          (subscription.status == :active and subscription.episode_id == episode.id and
             subscription.deadline_at == episode.owner_deadline_at),
      order_by: [asc: episode.owner_deadline_at, asc: episode.id],
      limit: 1,
      select: %{episode_id: episode.id, record_id: record.id}
    )
  end

  @doc "The next poll time and the next deadline of the active subscriptions after `since`."
  def select_next_due_after(since) do
    from(subscription in active(),
      select: [
        filter(min(subscription.poll_after), subscription.poll_after > ^since),
        filter(min(subscription.deadline_at), subscription.deadline_at > ^since)
      ]
    )
  end

  @doc """
  The update that resolves the active subscription of wait `wait_ref` as
  `status` by `resolution_kind`, with what was observed at `now`.
  """
  def resolving(wait_ref, status, resolution_kind, observation, now) do
    from(subscription in all(),
      join: record in Records.Record,
      on: record.id == subscription.record_id,
      where: record.ref == ^wait_ref and subscription.status == :active,
      update: [
        set: [
          status: ^status,
          resolution_kind: ^resolution_kind,
          last_observation: ^observation,
          last_observed_at: ^now,
          updated_at: ^now
        ],
        inc: [revision: 1]
      ],
      select: {subscription.id, subscription.episode_id}
    )
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  # A wait holds its episode while the episode waits on it. An event-only
  # watch holds it while the episode is parked in one of `parked_states`, or
  # waits on an approval (`Ryker.Waits.EventSubscriptions`).
  defp retained_wait(parked_states) do
    event_only = Records.Record.Query.event_only_wait()

    dynamic(
      [episode_kernel_episodes: episode],
      ^waited_on() or
        (^event_only and (episode.state in ^parked_states or ^waiting_on_approval()))
    )
  end

  defp waited_on do
    dynamic(
      [episode_kernel_episodes: episode, episode_state_records: record],
      episode.state == :waiting_for_event and episode.owner_kind == :event and
        episode.owner_ref == record.ref
    )
  end

  # No event wait of the episode's own owns the wait it waits on.
  defp waiting_on_approval do
    dynamic(
      [episode_kernel_episodes: episode],
      episode.state == :waiting_for_event and
        not exists(
          from(owner in Records.Record,
            where:
              owner.episode_id == parent_as(:episode_kernel_episodes).id and
                owner.ref == parent_as(:episode_kernel_episodes).owner_ref and
                owner.kind == "event_wait" and owner.status == :open
          )
        )
    )
  end
end
