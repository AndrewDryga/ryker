defmodule Ryker.ControlPlane.OverviewQuery do
  @moduledoc """
  What the Activity page leads with (`Ryker.ControlPlane.OverviewProjection`):
  how much work is under way, blocked or waiting, how routing and Slack
  statuses are keeping up, and the latest things that need a person.
  """
  import Ecto.Query
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Slack.{IncidentRoom, ThreadStatus}
  alias Ryker.Work.Turn

  @doc "Turns that own their working request and stopped."
  def blocked_work do
    from(turn in Turn,
      join: episode in Episode,
      on:
        episode.id == turn.episode_id and episode.owner_kind == :turn and
          episode.owner_ref == turn.turn_ref,
      where: turn.status == :blocked and episode.state == :working
    )
  end

  @doc """
  How routing keeps up: how many messages it routes now, stopped, queued and
  retrying, and how long the oldest has waited.
  """
  def admission_progress do
    from(entry in Entry,
      select: %{
        admitting:
          type(
            fragment(
              "COUNT(*) FILTER (WHERE ? = 'pending' AND ? IS NOT NULL AND ? > clock_timestamp())::bigint",
              entry.status,
              entry.lease_ref,
              entry.lease_expires_at
            ),
            :integer
          ),
        blocked:
          type(
            fragment("COUNT(*) FILTER (WHERE ? = 'blocked')::bigint", entry.status),
            :integer
          ),
        oldest_active_ms:
          type(
            fragment(
              "GREATEST(0, COALESCE(EXTRACT(EPOCH FROM (clock_timestamp() - MIN(?) FILTER (WHERE ? = 'pending'))) * 1000, 0))::bigint",
              entry.inserted_at,
              entry.status
            ),
            :integer
          ),
        queued:
          type(
            fragment(
              "COUNT(*) FILTER (WHERE ? = 'pending' AND (? IS NULL OR ? <= clock_timestamp()) AND (? IS NULL OR ? <= clock_timestamp()))::bigint",
              entry.status,
              entry.lease_expires_at,
              entry.lease_expires_at,
              entry.next_attempt_at,
              entry.next_attempt_at
            ),
            :integer
          ),
        retrying:
          type(
            fragment(
              "COUNT(*) FILTER (WHERE ? = 'pending' AND (? IS NULL OR ? <= clock_timestamp()) AND ? > clock_timestamp())::bigint",
              entry.status,
              entry.lease_expires_at,
              entry.lease_expires_at,
              entry.next_attempt_at
            ),
            :integer
          )
      }
    )
  end

  @doc "How Slack statuses keep up: how many wait to be written, and the oldest wait."
  def slack_status_progress do
    from(status in ThreadStatus,
      select: %{
        oldest_pending_ms:
          type(
            fragment(
              "COALESCE(EXTRACT(EPOCH FROM (clock_timestamp() - MIN(?) FILTER (WHERE ? = 'pending'))) * 1000, 0)::bigint",
              status.updated_at,
              status.status
            ),
            :integer
          ),
        pending:
          type(
            fragment("COUNT(*) FILTER (WHERE ? = 'pending')::bigint", status.status),
            :integer
          )
      }
    )
  end

  @doc "The `limit` latest requests waiting for a person, as the attention list shows them."
  def waiting_for_people(limit) do
    from(episode in Episode,
      where: episode.state == :waiting_for_input,
      order_by: [desc: episode.updated_at, desc: episode.id],
      limit: ^limit,
      select: %{
        kind: :operator_input,
        ref: episode.key,
        title: episode.key,
        updated_at: episode.updated_at
      }
    )
  end

  @doc "The `limit` latest stopped work, as the attention list shows it."
  def stopped_work(limit) do
    from([turn, episode] in blocked_work(),
      order_by: [desc: turn.updated_at, desc: turn.id],
      limit: ^limit,
      select: %{
        kind: :blocked_work,
        ref: episode.key,
        title: episode.key,
        updated_at: turn.updated_at
      }
    )
  end

  @doc "The `limit` latest stopped incident rooms, as the attention list shows them."
  def stopped_rooms(limit) do
    from(room in IncidentRoom,
      where: room.status == :blocked,
      order_by: [desc: room.updated_at, desc: room.id],
      limit: ^limit,
      select: %{
        kind: :blocked_incident,
        ref: room.ref,
        title: room.title,
        updated_at: room.updated_at
      }
    )
  end
end
