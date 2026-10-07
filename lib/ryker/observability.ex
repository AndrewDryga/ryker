defmodule Ryker.Observability do
  @moduledoc """
  Payload-free health, readiness, and Prometheus projections.

  Queue timing is derived from PostgreSQL time. Metrics contain only fixed
  lifecycle labels and aggregate counts; source bodies, prompts, tool output,
  destinations, credentials, and actor identities never cross this boundary.

  This is the entry point the control plane and the operator commands call.
  `Queues`, `Progress`, `Fleet` and `Retention` each read one part of a
  snapshot at one database clock reading, `Readiness` judges it and `Metrics`
  renders it. Every read answers a database failure as an error where it
  happens, so a probe reports it instead of crashing.
  """
  alias Ryker.Delivery.RoutingResponse
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Observability.{Fleet, Metrics, Progress, Queues, Readiness, Reads, Retention}
  alias Ryker.Publication.Publication
  alias Ryker.Schedules.Schedule
  alias Ryker.Slack.{IncidentRoom, TaskCard}
  alias Ryker.Work.Turn

  @default_stall_after_seconds 15 * 60
  @readiness_options [:check_progress, :check_runtimes, :stall_after_seconds]

  @spec callbacks() :: map()
  def callbacks do
    %{health: &health/0, metrics: &metrics/0, ready: &ready/0}
  end

  @spec health() :: {:ok, map()} | {:error, term()}
  def health do
    case Reads.sql("SELECT 1") do
      {:ok, _result} -> {:ok, %{database: :ok}}
      {:error, reason} -> {:error, {:database_unavailable, reason}}
    end
  end

  @spec ready(keyword()) :: {:ok, map()} | {:error, map() | term()}
  def ready(options \\ []) do
    with {:ok, check} <- readiness_options(options),
         {:ok, snapshot} <- snapshot(check.stall_after_seconds) do
      Readiness.evaluate(snapshot, check)
    end
  end

  @doc """
  The fixed reasons a failed readiness check reports, safe to print on `/readyz`.

  Only reason codes and lane, queue or runtime names: never an identifier, a
  message or an inspected term, so the endpoint stays payload-free while still
  saying why a deployment is not ready.
  """
  @spec problems(map() | term()) :: [String.t()]
  def problems(%{fleet_issues: _} = readiness), do: Readiness.reasons(readiness)

  def problems(reason) when is_tuple(reason) and elem(reason, 0) == :database_unavailable,
    do: ["database unavailable"]

  def problems(_reason), do: ["readiness check failed"]

  @spec metrics() :: {:ok, binary()} | {:error, term()}
  def metrics do
    with {:ok, snapshot} <- snapshot(@default_stall_after_seconds) do
      {:ok, Metrics.render(snapshot)}
    end
  end

  @spec fleet() :: {:ok, map()} | {:error, term()}
  def fleet do
    with {:ok, now} <- database_now(), do: Fleet.snapshot(now)
  end

  @spec snapshot(pos_integer()) :: {:ok, map()} | {:error, term()}
  def snapshot(stall_after_seconds \\ @default_stall_after_seconds)

  def snapshot(stall_after_seconds)
      when is_integer(stall_after_seconds) and stall_after_seconds > 0 do
    with {:ok, now} <- database_now(),
         {:ok, queues} <- Queues.snapshot(now),
         {:ok, progress} <- Progress.snapshot(now),
         {:ok, counts} <- counts(),
         {:ok, fleet} <- Fleet.snapshot(now),
         {:ok, retention} <- Retention.snapshot(now) do
      {:ok,
       %{
         counts: counts,
         fleet: fleet,
         generated_at: now,
         progress: progress,
         queues: queues,
         retention: retention,
         stalled_active_leases: Queues.stalled_leases(queues, stall_after_seconds),
         stalled_queues: Queues.stalled(queues, stall_after_seconds)
       }}
    end
  end

  def snapshot(_stall_after_seconds),
    do: {:error, {:invalid_observability, :stall_after_seconds}}

  defp counts do
    with {:ok, incidents} <- Reads.counts(IncidentRoom, :status),
         {:ok, ingress} <- Reads.counts(Entry, :status),
         {:ok, publications} <- Reads.counts(Publication, :status),
         {:ok, routing_responses} <- Reads.counts(RoutingResponse, :status),
         {:ok, schedules} <- Reads.counts(Schedule, :status),
         {:ok, task_cards} <- Reads.count(TaskCard),
         {:ok, work} <- Reads.counts(Turn, :status) do
      {:ok,
       %{
         incidents: incidents,
         ingress: ingress,
         publications: publications,
         routing_responses: routing_responses,
         schedules: schedules,
         task_cards: %{total: task_cards},
         work: work
       }}
    end
  end

  defp database_now do
    case Reads.sql("SELECT clock_timestamp()") do
      {:ok, %{rows: [[%DateTime{} = now]]}} -> {:ok, now}
      {:ok, _unexpected} -> {:error, {:observability_query_failed, :database_clock}}
      {:error, reason} -> {:error, {:database_unavailable, reason}}
    end
  end

  defp readiness_options(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Keyword.keys(options) -- @readiness_options == [] do
      check_runtimes = Keyword.get(options, :check_runtimes, true)
      check_progress = Keyword.get(options, :check_progress, true)

      stall_after_seconds =
        Keyword.get(options, :stall_after_seconds, @default_stall_after_seconds)

      if is_boolean(check_progress) and is_boolean(check_runtimes) and
           is_integer(stall_after_seconds) and
           stall_after_seconds > 0 do
        {:ok,
         %{
           check_progress: check_progress,
           check_runtimes: check_runtimes,
           stall_after_seconds: stall_after_seconds
         }}
      else
        {:error, {:invalid_observability, :readiness_options}}
      end
    else
      {:error, {:invalid_observability, :readiness_options}}
    end
  end

  defp readiness_options(_options),
    do: {:error, {:invalid_observability, :readiness_options}}
end
