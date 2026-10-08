defmodule Ryker.Work.OwningTurn.Query do
  @moduledoc """
  Each episode with the turn that owns it: the one Work runs, or the one
  whose accepted answer is being delivered. The Work pool claims from these
  (`Ryker.Work.Custody.Claims`), and learning, routing and work examples and
  self-analysis wait for them to come to rest. Queries bind the episode as
  `:episode_kernel_episodes` and the turn as `:episode_work_turns`.
  """
  use Ryker, :query
  alias Ryker.Episodes
  alias Ryker.Publication
  alias Ryker.Work.{Session, Turn}

  @doc """
  The least recently updated episode the Work pool may claim at `now` in
  `phase`, leaving out `skipped` and skipping any another worker holds.
  """
  def next_claimable_episode(now, phase, skipped) do
    from(episode in Episodes.Episode.Query.all(),
      where: episode.id in subquery(claimable_episode_ids(now, phase)),
      where: episode.id not in ^skipped,
      order_by: [asc: episode.updated_at, asc: episode.id],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  @doc """
  The ids of the episodes the Work pool may claim at `now` in `phase`
  (`:work`, `:delivery` or `:any`): working on a turn or a delivery, pinned to
  a session, due and unleased or with a lapsed lease, and, for Work, not held
  by a readiness review.
  """
  def claimable_episode_ids(now, phase) do
    pinned_episode_ids = from(session in Session, select: session.episode_id)

    reviewing_episode_ids =
      from(publication in Publication.Publication,
        where: publication.status == :review_pending and publication.lease_expires_at > ^now,
        select: publication.episode_id
      )

    phase_filter = phase_filter(phase, now)

    from([episode_kernel_episodes: episode] in owning_turns(),
      where: episode.state == :working and episode.owner_kind in [:turn, :delivery],
      where: episode.id in subquery(pinned_episode_ids),
      where: ^phase_filter,
      where: episode.owner_kind == :delivery or episode.id not in subquery(reviewing_episode_ids),
      select: episode.id
    )
  end

  @doc """
  Every episode Work was pinned to, with whether that Work is still running
  and when it last changed. Running is every state the pool claims from
  (`claimable_episode_ids/2`), whatever the clock says: a turn about to
  start, running, waiting to retry or stopping, or an accepted answer not
  yet delivered. Anything else is at rest, with nothing left for Work to do
  until something new arrives or a person acts: answered, waiting for a
  person or an event, blocked, cancelled or closed. For Work at rest the
  last change is when it came to rest, on the episode, or on the turn
  blocked under it. Learning waits for this (`Ryker.Learning.Batches`).
  """
  def work_rest do
    from([episode_kernel_episodes: episode, episode_work_turns: turn] in owning_turns(),
      where:
        exists(
          from(session in Session,
            where: session.episode_id == parent_as(:episode_kernel_episodes).id
          )
        ),
      select: %{
        episode_id: episode.id,
        running:
          episode.state == :working and
            ((episode.owner_kind == :turn and
                (is_nil(turn.id) or turn.status in [:pending, :cancel_pending])) or
               (episode.owner_kind == :delivery and turn.status == :delivery_pending)),
        rested_at: fragment("GREATEST(?, ?)", episode.updated_at, turn.updated_at)
      }
    )
  end

  defp owning_turns do
    from(episode in Episodes.Episode.Query.all(),
      left_join: turn in Turn,
      as: :episode_work_turns,
      on:
        turn.episode_id == episode.id and
          ((episode.owner_kind == :turn and turn.turn_ref == episode.owner_ref) or
             (episode.owner_kind == :delivery and turn.delivery_ref == episode.owner_ref))
    )
  end

  defp phase_filter(:work, now) do
    dynamic(
      [episode_kernel_episodes: episode, episode_work_turns: turn],
      episode.owner_kind == :turn and
        (is_nil(turn.id) or
           (turn.status in [:pending, :cancel_pending] and
              (is_nil(turn.next_attempt_at) or turn.next_attempt_at <= ^now) and
              (is_nil(turn.lease_ref) or turn.lease_expires_at <= ^now)))
    )
  end

  defp phase_filter(:delivery, now) do
    dynamic(
      [episode_kernel_episodes: episode, episode_work_turns: turn],
      episode.owner_kind == :delivery and not is_nil(turn.id) and
        turn.status == :delivery_pending and
        (is_nil(turn.next_attempt_at) or turn.next_attempt_at <= ^now) and
        (is_nil(turn.lease_ref) or turn.lease_expires_at <= ^now)
    )
  end

  defp phase_filter(:any, now) do
    work = phase_filter(:work, now)
    delivery = phase_filter(:delivery, now)
    dynamic(^work or ^delivery)
  end
end
