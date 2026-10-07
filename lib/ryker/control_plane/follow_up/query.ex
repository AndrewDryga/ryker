defmodule Ryker.ControlPlane.FollowUp.Query do
  @moduledoc """
  What the Follow-ups page reads (`Ryker.ControlPlane.SubscriptionProjection`):
  every event subscription Ryker holds, with the request it serves and what
  it waits for, still waiting first and soonest due first, then the newest.
  """
  import Ecto.Query
  alias Ryker.Episodes.Episode
  alias Ryker.Records.Record
  alias Ryker.Waits.EventSubscription

  @doc "The first `limit` follow-ups in the page's order."
  def follow_ups(limit) do
    from([episode_event_subscriptions: subscription] in EventSubscription.Query.all(),
      left_join: episode in Episode,
      on: episode.id == subscription.episode_id,
      join: record in Record,
      on: record.id == subscription.record_id,
      order_by: [
        asc: fragment("CASE WHEN ? = 'active' THEN 0 ELSE 1 END", subscription.status),
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
        resolution_kind: subscription.resolution_kind,
        revision: subscription.revision,
        source_kind: subscription.source_kind,
        status: subscription.status,
        trigger_type: fragment("?::jsonb -> 'event_matcher' ->> 'type'", record.payload),
        updated_at: subscription.updated_at
      }
    )
  end

  def in_statuses(queryable, statuses),
    do: where(queryable, [episode_event_subscriptions: s], s.status in ^statuses)

  def by_ref(queryable, ref),
    do: where(queryable, [episode_event_subscriptions: s], s.ref == ^ref)
end
