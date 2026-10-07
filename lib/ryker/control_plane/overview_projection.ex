defmodule Ryker.ControlPlane.OverviewProjection do
  @moduledoc """
  The Activity page's summary strip: live counts, fleet health, what needs an
  operator, and how far admission and Slack status delivery are behind.
  """

  alias Ryker.ControlPlane.Overview
  alias Ryker.Episodes.Episode
  alias Ryker.Observability
  alias Ryker.Repo
  alias Ryker.Work.Turn

  @active_states [:working, :waiting_for_input, :waiting_for_event]

  @doc "The counts, fleet state, attention list and queue progress the Activity page leads with."
  def overview do
    %{
      counts: %{
        active: @active_states |> in_states() |> count(),
        blocked: count(Overview.Query.blocked_work()),
        delivery_pending: :delivery_pending |> Turn.Query.with_status() |> count(),
        waiting: [:waiting_for_input, :waiting_for_event] |> in_states() |> count()
      },
      fleet: fleet(),
      needs_attention: needs_attention(),
      progress: %{
        admission: Repo.one!(Overview.Query.admission_progress()),
        slack_status: Repo.one!(Overview.Query.slack_status_progress())
      }
    }
  end

  defp in_states(states), do: Episode.Query.in_states(Episode.Query.all(), states)

  @doc """
  The worker fleet's state, all the Activity page shows of the overview: it
  read the whole overview, nine queries with whole-table counts, on every
  refresh (2026-10-04 review).
  """
  @spec fleet() :: map()
  def fleet do
    case Observability.fleet() do
      {:ok, fleet} -> fleet
      {:error, _reason} -> %{required: true, unavailable: true}
    end
  end

  defp needs_attention do
    (Repo.all(Overview.Query.waiting_for_people(10)) ++
       Repo.all(Overview.Query.stopped_work(10)) ++ Repo.all(Overview.Query.stopped_rooms(10)))
    |> Enum.sort_by(&{DateTime.to_unix(&1.updated_at, :microsecond), &1.ref}, :desc)
    |> Enum.take(20)
    |> Enum.map(&Map.delete(&1, :updated_at))
  end

  defp count(query), do: Repo.aggregate(query, :count, :id)
end
