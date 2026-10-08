defmodule Ryker.ControlPlane.FollowUp.Query do
  @moduledoc """
  What the Follow-ups page reads (`Ryker.ControlPlane.SubscriptionProjection`):
  every event subscription Ryker holds, with the request it serves and what
  it waits for, still waiting first and soonest due first, then the newest.
  """
  use Ryker, :query
  alias Ryker.Episodes
  alias Ryker.Records
  alias Ryker.Waits

  # A watch beside a timer that owns the wait gives the timer the episode's one
  # subscription and stays open (`Ryker.Waits.EventSubscriptions`): it still
  # waits, though its subscription row reads cancelled.
  @released "(? = 'cancelled' AND (?::jsonb ->> 'kind') = 'released' AND ? = 'open')"
  @waiting_first "CASE WHEN ? = 'active' OR (? = 'cancelled' AND (?::jsonb ->> 'kind') = 'released' AND ? = 'open') THEN 0 ELSE 1 END"

  @doc "The first `limit` follow-ups in the page's order."
  def follow_ups(limit) do
    from([episode_event_subscriptions: subscription] in Waits.EventSubscription.Query.all(),
      left_join: episode in Episodes.Episode,
      on: episode.id == subscription.episode_id,
      join: record in Records.Record,
      as: :episode_state_records,
      on: record.id == subscription.record_id,
      order_by: [
        asc:
          fragment(
            @waiting_first,
            subscription.status,
            subscription.status,
            subscription.last_observation,
            record.status
          ),
        asc_nulls_last:
          fragment(
            "CASE WHEN ? = 'active' THEN coalesce(?, ?) END",
            subscription.status,
            subscription.poll_after,
            subscription.deadline_at
          ),
        desc: subscription.updated_at,
        desc: subscription.id
      ],
      limit: ^limit,
      select: %{
        cursor: subscription.cursor,
        deadline_at: subscription.deadline_at,
        episode_ref: episode.key,
        last_observation: subscription.last_observation,
        last_observed_at: subscription.last_observed_at,
        matcher: subscription.matcher,
        poll_after: subscription.poll_after,
        ref: subscription.ref,
        released:
          fragment(
            @released,
            subscription.status,
            subscription.last_observation,
            record.status
          ),
        resolution_kind: subscription.resolution_kind,
        revision: subscription.revision,
        source_kind: subscription.source_kind,
        status: subscription.status,
        trigger_type: fragment("?::jsonb -> 'event_matcher' ->> 'type'", record.payload),
        updated_at: subscription.updated_at
      }
    )
  end

  @doc "Follow-ups still waiting, a released watch's among them."
  def waiting(queryable) do
    where(
      queryable,
      [episode_event_subscriptions: s, episode_state_records: r],
      s.status == :active or fragment(@released, s.status, s.last_observation, r.status)
    )
  end

  @doc "Follow-ups that ended."
  def ended(queryable) do
    where(
      queryable,
      [episode_event_subscriptions: s, episode_state_records: r],
      s.status != :active and not fragment(@released, s.status, s.last_observation, r.status)
    )
  end

  def by_ref(queryable, ref),
    do: where(queryable, [episode_event_subscriptions: s], s.ref == ^ref)
end
