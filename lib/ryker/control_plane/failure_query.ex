defmodule Ryker.ControlPlane.FailureQuery do
  @moduledoc """
  What the Failures page reads (`Ryker.ControlPlane.FailureProjection`) across
  tables: stopped work with the request it holds, stopped cleanups and
  publications with their requests, stops nobody confirmed, learning only a
  person can move, and the facts each row is decorated with. A list reads
  newest first; `limit_to/2` bounds it.
  """
  import Ecto.Query
  alias Ryker.CoopFleet.{Placement, Worker}
  alias Ryker.Episodes.Episode
  alias Ryker.Learning.Batch
  alias Ryker.Learning.LearningRun
  alias Ryker.Publication.Publication
  alias Ryker.Slack.IncidentRoom
  alias Ryker.Work.{Session, Turn}

  def limit_to(queryable, count), do: limit(queryable, ^count)

  @doc """
  Blocked turns that hold their working episode, not delivering, as `{turn,
  episode}`, newest first.
  """
  def blocked_work do
    from(turn in Turn,
      join: episode in Episode,
      as: :episode,
      on:
        episode.id == turn.episode_id and episode.state == :working and
          episode.owner_kind == :turn and episode.owner_ref == turn.turn_ref,
      where: turn.status == :blocked and is_nil(turn.delivery_ref),
      order_by: [desc: turn.updated_at, desc: turn.id],
      select: {turn, episode}
    )
  end

  @doc """
  The episode's own run, asked to stop, that its worker has not confirmed
  stopped after `attempts` tries, as `{turn, episode}`, newest first.
  """
  def stalled_stops(attempts) do
    from(turn in Turn,
      join: episode in Episode,
      as: :episode,
      on:
        episode.id == turn.episode_id and episode.state == :working and
          episode.owner_kind == :turn and episode.owner_ref == turn.turn_ref,
      where: turn.status == :cancel_pending and turn.cancel_attempt_count >= ^attempts,
      order_by: [desc: turn.updated_at, desc: turn.id],
      select: {turn, episode}
    )
  end

  @doc "Rows of `blocked_work/0` or `stalled_stops/1` for request `key`."
  def of_request(queryable, key), do: where(queryable, [episode: e], e.key == ^key)

  @doc """
  Sessions whose cleanup is blocked, with their episode if they have one, as
  `{session, episode}`, newest first. A learning session has no episode; an
  inner join hid every blocked learning cleanup.
  """
  def blocked_cleanups do
    from(session in Session,
      left_join: episode in Episode,
      on: episode.id == session.episode_id,
      where: session.cleanup_status == :blocked,
      order_by: [desc: session.updated_at, desc: session.id],
      select: {session, episode}
    )
  end

  @doc "The blocked cleanup of session `external_ref`."
  def blocked_cleanup(external_ref),
    do: where(blocked_cleanups(), [session], session.external_ref == ^external_ref)

  @doc """
  Publications in one of `statuses` that recorded a failure, with their
  episode, as `{publication, episode}`, newest first.
  """
  def failing_publications(statuses) do
    from(publication in Publication,
      join: episode in Episode,
      on: episode.id == publication.episode_id,
      where: publication.status in ^statuses and not is_nil(publication.last_error_code),
      order_by: [desc: publication.updated_at, desc: publication.id],
      select: {publication, episode}
    )
  end

  @doc "The failing publication `ref` of `failing_publications/1`."
  def failing_publication(statuses, ref),
    do: where(failing_publications(statuses), [publication], publication.ref == ^ref)

  @doc """
  Deferred learning batches with no run left to reconcile, newest first: a
  deferred batch is claimed again only while it has one, and that one moves
  on by itself. Without one, only a person granting it another start moves it.
  """
  def stalled_learning do
    outstanding =
      from(run in LearningRun,
        where:
          run.batch_id == parent_as(:batch).id and not is_nil(run.started_at) and
            is_nil(run.remote_stopped_at),
        select: 1
      )

    from(batch in Batch,
      as: :batch,
      where: batch.status == :deferred and not exists(outstanding),
      order_by: [desc: batch.updated_at, desc: batch.id]
    )
  end

  @doc "Batch `id` of `stalled_learning/0`."
  def stalled_batch(id), do: where(stalled_learning(), [batch: b], b.id == ^id)

  @doc "What the last attempt of batch `batch_id` that failed stopped on."
  def last_attempt_error(batch_id) do
    from(run in LearningRun,
      where: run.batch_id == ^batch_id and not is_nil(run.error_code),
      order_by: [desc: run.inserted_at, desc: run.id],
      limit: 1,
      select: run.error_code
    )
  end

  @doc "The name and state of an incident room investigating `episode_id`."
  def room_of(episode_id) do
    from(room in IncidentRoom,
      where: room.episode_id == ^episode_id,
      select: %{channel_name: room.channel_name, channel_state: room.channel_state},
      limit: 1
    )
  end

  @doc """
  The replies `delivery_refs` names that belong to a request whose incident
  room was deleted, as `{delivery_ref, delivery_target, room}`.
  """
  def replies_to_deleted_rooms(delivery_refs) do
    from(turn in Turn,
      join: room in IncidentRoom,
      on: room.episode_id == turn.episode_id,
      where: turn.delivery_ref in ^delivery_refs and room.channel_state == :deleted,
      select: {turn.delivery_ref, turn.delivery_target, room}
    )
  end

  @doc """
  The latest placement of each of `session_ids`, with its session and the
  worker it named if that worker is still enrolled, as `{%{session_id,
  worker_id, requirements}, session, worker}`.
  """
  def session_workers(session_ids) do
    latest =
      from(placement in Placement,
        where: placement.session_id in ^session_ids,
        distinct: placement.session_id,
        order_by: [asc: placement.session_id, desc: placement.generation],
        select: %{
          session_id: placement.session_id,
          worker_id: placement.worker_id,
          requirements: placement.requirements
        }
      )

    from(placement in subquery(latest),
      join: session in Session,
      on: session.id == placement.session_id,
      left_join: worker in Worker,
      on: worker.id == placement.worker_id,
      select: {placement, session, worker}
    )
  end
end
