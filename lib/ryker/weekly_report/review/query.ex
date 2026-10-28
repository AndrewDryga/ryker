defmodule Ryker.WeeklyReport.Review.Query do
  @moduledoc "The weekly review queue and saved results."
  use Ryker, :query
  alias Ryker.{Episodes, Work}
  alias Ryker.WeeklyReport.Review

  def all, do: from(reviews in Review, as: :weekly_report_reviews)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [weekly_report_reviews: r], r.id == ^id)

  def by_identity(queryable \\ all(), identity),
    do: where(queryable, [weekly_report_reviews: r], r.identity == ^identity)

  def by_period(queryable \\ all(), from, until, destination) do
    where(
      queryable,
      [weekly_report_reviews: r],
      r.period_start == ^from and r.period_end == ^until and r.conversation_ref == ^destination
    )
  end

  def outstanding(queryable \\ all()),
    do: where(queryable, [weekly_report_reviews: r], is_nil(r.remote_stopped_at))

  def next_claimable(now) do
    all()
    |> where([weekly_report_reviews: r], is_nil(r.remote_stopped_at))
    |> where([weekly_report_reviews: r], is_nil(r.lease_expires_at) or r.lease_expires_at <= ^now)
    |> where([weekly_report_reviews: r], is_nil(r.next_attempt_at) or r.next_attempt_at <= ^now)
    |> order_by([weekly_report_reviews: r], asc: r.period_end, asc: r.id)
    |> limit(1)
    |> lock("FOR UPDATE SKIP LOCKED")
  end

  # Only the text already delivered to a public channel enters the review. A
  # joined private input on the same episode cannot supply any other field.
  def delivered_evidence(from, until, conversations, maximum) do
    from(turn in Work.Turn,
      as: :episode_work_turns,
      join: episode in Episodes.Episode,
      as: :episode_kernel_episodes,
      on: episode.id == turn.episode_id,
      where: episode.execution_mode == :live and is_nil(episode.history_pruned_at),
      where: turn.status == :settled and is_nil(turn.operational_pruned_at),
      where: turn.delivered_at >= ^from and turn.delivered_at < ^until,
      where: fragment("?::jsonb->>'transport' = 'slack'", turn.external_receipt),
      where: fragment("?::jsonb->>'conversation_ref'", turn.external_receipt) in ^conversations,
      order_by: [desc: turn.delivered_at, desc: turn.id],
      limit: ^maximum,
      lock: fragment("FOR SHARE OF ?", turn),
      select: %{
        turn_id: turn.id,
        episode_id: turn.episode_id,
        inserted_at: turn.inserted_at,
        delivered_at: turn.delivered_at,
        receipt: turn.external_receipt,
        message: fragment("?::jsonb->>'message'", turn.delivery_document)
      }
    )
  end

  def from_sources_or_messages(queryable \\ all(), identities, keys) do
    where(
      queryable,
      [weekly_report_reviews: r],
      fragment("? && ?::text[]", r.source_identities, ^identities) or
        fragment("? && ?::text[]", r.message_keys, ^keys)
    )
  end

  def by_source_conversation(queryable \\ all(), conversation) do
    where(
      queryable,
      [weekly_report_reviews: r],
      fragment("? @> ARRAY[?]::text[]", r.source_conversation_refs, ^conversation)
    )
  end

  def kept(queryable), do: where(queryable, [weekly_report_reviews: r], is_nil(r.forgotten_at))
  def select_ids(queryable), do: select(queryable, [weekly_report_reviews: r], r.id)

  def ordered_by_recent(queryable),
    do: order_by(queryable, [weekly_report_reviews: r], desc: r.inserted_at, desc: r.id)

  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_for_share(queryable), do: lock(queryable, "FOR SHARE")
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
