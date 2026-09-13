defmodule Ryker.ControlPlane.OverviewProjection do
  @moduledoc """
  The Activity page's summary strip: live counts, fleet health, what needs an
  operator, and how far admission and Slack status delivery are behind.
  """

  import Ecto.Query

  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Observability
  alias Ryker.Repo
  alias Ryker.Slack.{IncidentRoom, ThreadStatus}
  alias Ryker.Work.Turn

  @active_states [:working, :waiting_for_input, :waiting_for_event]

  @doc "The counts, fleet state, attention list and queue progress the Activity page leads with."
  def overview do
    active_query = from(episode in Episode, where: episode.state in ^@active_states)

    waiting_query =
      from(episode in Episode, where: episode.state in [:waiting_for_input, :waiting_for_event])

    blocked_query =
      from(turn in Turn,
        join: episode in Episode,
        on:
          episode.id == turn.episode_id and episode.owner_kind == :turn and
            episode.owner_ref == turn.turn_ref,
        where: turn.status == :blocked and episode.state == :working
      )

    delivery_query = from(turn in Turn, where: turn.status == :delivery_pending)

    %{
      counts: %{
        active: count(active_query),
        blocked: count(blocked_query),
        delivery_pending: count(delivery_query),
        waiting: count(waiting_query)
      },
      fleet: fleet_overview(),
      needs_attention: needs_attention(),
      progress: %{
        admission: admission_progress(),
        slack_status: slack_status_progress()
      }
    }
  end

  defp admission_progress do
    Repo.one!(
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
    )
  end

  defp slack_status_progress do
    Repo.one!(
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
    )
  end

  defp fleet_overview do
    case Observability.fleet() do
      {:ok, fleet} -> fleet
      {:error, _reason} -> %{required: true, unavailable: true}
    end
  end

  defp needs_attention do
    waits =
      Repo.all(
        from(episode in Episode,
          where: episode.state == :waiting_for_input,
          order_by: [desc: episode.updated_at, desc: episode.id],
          limit: 10,
          select: %{
            kind: :operator_input,
            ref: episode.key,
            title: episode.key,
            updated_at: episode.updated_at
          }
        )
      )

    blocks =
      Repo.all(
        from(turn in Turn,
          join: episode in Episode,
          on:
            episode.id == turn.episode_id and episode.owner_kind == :turn and
              episode.owner_ref == turn.turn_ref,
          where: turn.status == :blocked and episode.state == :working,
          order_by: [desc: turn.updated_at, desc: turn.id],
          limit: 10,
          select: %{
            kind: :blocked_work,
            ref: episode.key,
            title: episode.key,
            updated_at: turn.updated_at
          }
        )
      )

    incident_blocks =
      Repo.all(
        from(room in IncidentRoom,
          where: room.status == :blocked,
          order_by: [desc: room.updated_at, desc: room.id],
          limit: 10,
          select: %{
            kind: :blocked_incident,
            ref: room.ref,
            title: room.title,
            updated_at: room.updated_at
          }
        )
      )

    (waits ++ blocks ++ incident_blocks)
    |> Enum.sort_by(&{DateTime.to_unix(&1.updated_at, :microsecond), &1.ref}, :desc)
    |> Enum.take(20)
    |> Enum.map(&Map.delete(&1, :updated_at))
  end

  defp count(query), do: Repo.aggregate(query, :count, :id)
end
