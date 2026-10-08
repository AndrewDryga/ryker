defmodule Ryker.Observability.Fleet do
  @moduledoc """
  The Coop worker fleet as readiness and metrics see it.

  A worker counts only while its heartbeat is fresh, and is eligible only when
  it serves this installation's workspace with every required capability and a
  free session, turn and workspace slot. Storage is each worker's own
  measurement: a worker that reported nothing is unknown and a stale heartbeat
  is a stale measurement, and neither is folded into the live totals as zero.
  """
  alias Ryker.Config
  alias Ryker.CoopFleet.{Command, Placement, Worker}
  alias Ryker.CoopFleet.WorkspaceCheckpointTransfer
  alias Ryker.Defaults
  alias Ryker.Observability.Reads

  @slot_kinds ~w(session turn workspace)a

  @event_cursor_lag """
  SELECT COALESCE(SUM(
    GREATEST(
      COALESCE(events.maximum_coarse_sequence, 0) - placement.last_acked_event_sequence,
      0
    ) +
    GREATEST(
      COALESCE(events.maximum_session_sequence, 0) - placement.last_acked_session_event_sequence,
      0
    )
  ), 0)::bigint
  FROM coop_session_placements AS placement
  LEFT JOIN LATERAL (
    SELECT
      MAX(event.sequence) FILTER (WHERE event.kind <> 'session_event') AS maximum_coarse_sequence,
      MAX(event.sequence) FILTER (WHERE event.kind = 'session_event') AS maximum_session_sequence
    FROM coop_worker_events AS event
    WHERE event.placement_id = placement.id
  ) AS events ON TRUE
  WHERE placement.state IN ('active', 'revoking')
  """

  @doc "The fleet at the database clock reading `now`."
  @spec snapshot(DateTime.t()) :: {:ok, map()} | {:error, Reads.failure()}
  def snapshot(now) do
    settings = settings()
    cutoff = DateTime.add(now, -Worker.heartbeat_seconds(), :second)

    current_placements = Placement.Query.current()
    expired_placements = Placement.Query.lease_expired_at(current_placements, now)
    transfers = WorkspaceCheckpointTransfer.Query.all()

    with {:ok, workers} <- Reads.all(Worker.Query.all()),
         {:ok, oldest_queued_command} <-
           Reads.one(Command.Query.select_oldest_insert(Command.Query.queued())),
         {:ok, latest_checkpoint} <-
           Reads.one(WorkspaceCheckpointTransfer.Query.select_latest_insert(transfers)),
         {:ok, checkpoints} <- Reads.count(transfers),
         {:ok, commands} <- Reads.counts(Command.Query.all(), :status),
         {:ok, current} <- Reads.count(current_placements),
         {:ok, event_cursor_lag} <- event_cursor_lag(),
         {:ok, expired} <- Reads.count(expired_placements),
         {:ok, placements} <- Reads.counts(Placement.Query.all(), :state),
         {:ok, worker_states} <- Reads.counts(Worker.Query.all(), :state) do
      fresh = Enum.filter(workers, &fresh?(&1, cutoff))
      eligible = Enum.filter(fresh, &eligible?(&1, settings.workspace_ref, settings.capabilities))

      {:ok,
       %{
         capacity: capacity(eligible),
         checkpoints: %{
           latest_age_seconds: Reads.age_seconds(now, latest_checkpoint),
           total: checkpoints
         },
         commands: commands,
         current_placements: current,
         eligible_workers: length(eligible),
         event_cursor_lag: event_cursor_lag,
         expired_current_placements: expired,
         fresh_workers: length(fresh),
         oldest_queued_command_age_seconds: Reads.age_seconds(now, oldest_queued_command),
         placements: placements,
         provider_states: Enum.frequencies_by(fresh, &provider_state/1),
         required: settings.required,
         required_capabilities: length(settings.capabilities),
         stale_workers: Enum.count(workers, &(not fresh?(&1, cutoff))),
         storage: storage(workers, cutoff, now),
         workers: worker_states
       }}
    end
  end

  @doc """
  Why a required fleet cannot start work, in a fixed order; a fleet this
  installation does not execute on has no issues.
  """
  @spec issues(map(), pos_integer()) :: [atom()]
  def issues(%{required: false}, _stall_after_seconds), do: []

  def issues(fleet, stall_after_seconds) do
    []
    |> maybe_issue(fleet.eligible_workers == 0, :no_eligible_workers)
    |> maybe_issue(fleet.capacity.session.free == 0, :no_session_capacity)
    |> maybe_issue(fleet.capacity.turn.free == 0, :no_turn_capacity)
    |> maybe_issue(fleet.capacity.workspace.free == 0, :no_workspace_capacity)
    # Slot capacity and storage are separate refusals. On 2026-09-13 every Slack
    # message stopped being processed while workers still advertised free
    # session slots, because Coop refused every workspace on the volume
    # watermark — and readiness said "ready" throughout. A fleet that cannot
    # allocate a workspace cannot start work, whatever its slot counts say.
    |> maybe_issue(
      fleet.storage.reporting > 0 and fleet.storage.refused >= fleet.storage.reporting,
      :no_workspace_storage
    )
    |> maybe_issue(fleet.expired_current_placements > 0, :expired_current_placements)
    |> maybe_issue(fleet.event_cursor_lag > 0, :event_cursor_lag)
    |> maybe_issue(
      fleet.oldest_queued_command_age_seconds > stall_after_seconds,
      :stalled_queued_commands
    )
  end

  defp maybe_issue(issues, true, issue), do: issues ++ [issue]
  defp maybe_issue(issues, false, _issue), do: issues

  defp storage(workers, cutoff, now) do
    {reported, unreported} = Enum.split_with(workers, &is_map(&1.storage))
    {fresh, stale} = Enum.split_with(reported, &fresh?(&1, cutoff))

    measured_at =
      fresh
      |> Enum.map(&parse_measured_at(&1.storage["measured_at"]))
      |> Enum.reject(&is_nil/1)

    %{
      bytes:
        Map.new(
          ~w(capacity_bytes free_bytes reserve_bytes disposable_bytes protected_bytes),
          &{&1, Enum.sum(Enum.map(fresh, fn worker -> worker.storage[&1] || 0 end))}
        ),
      oldest_measurement_age_seconds:
        if(measured_at == [],
          do: 0,
          else: Reads.age_seconds(now, Enum.min(measured_at, DateTime))
        ),
      reclaimed_bytes: Enum.sum(Enum.map(workers, & &1.storage_reclaimed_bytes)),
      refused: Enum.count(fresh, &(&1.storage["allocation"] == "refused")),
      reporting: length(fresh),
      stale: length(stale),
      unattributed_bytes: sum_or_unknown(fresh, "unattributed_bytes"),
      unknown: length(unreported)
    }
  end

  defp sum_or_unknown(workers, field) do
    if Enum.any?(workers, &is_nil(&1.storage[field])),
      do: nil,
      else: Enum.sum(Enum.map(workers, & &1.storage[field]))
  end

  defp parse_measured_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{} = measured_at, _offset} -> measured_at
      _invalid -> nil
    end
  end

  defp parse_measured_at(_value), do: nil

  defp settings do
    case Config.get_env(:work) do
      %{
        api: Ryker.CoopFleet.Client,
        client: %Ryker.CoopFleet.Client{bridge_options: options}
      }
      when is_list(options) ->
        %{
          capabilities:
            Keyword.get(options, :capability_names, Defaults.fetch!(:work).capability_names),
          required: true,
          workspace_ref: Keyword.get(options, :workspace_ref)
        }

      _direct_or_disabled ->
        %{capabilities: [], required: false, workspace_ref: nil}
    end
  end

  defp fresh?(%Worker{last_seen_at: %DateTime{} = last_seen_at}, cutoff) do
    DateTime.compare(last_seen_at, cutoff) != :lt
  end

  defp fresh?(_worker, _cutoff), do: false

  defp eligible?(worker, workspace_ref, capabilities) do
    worker.protocol_version == "2" and worker.workspace_ref == workspace_ref and
      worker.state == :eligible and
      is_nil(worker.drain_requested_at) and is_nil(worker.revoked_at) and
      provider_state(worker) == "eligible" and capabilities?(worker, capabilities) and
      Enum.all?(@slot_kinds, &(slot(worker, &1, :free) > 0))
  end

  defp capabilities?(worker, required) do
    available = MapSet.new(worker.capabilities, & &1["name"])
    Enum.all?(required, &MapSet.member?(available, &1))
  end

  defp provider_state(worker) do
    case worker.capacity["state"] do
      state when state in ~w(eligible busy cooldown needs_auth) -> state
      _unknown -> "unknown"
    end
  end

  defp capacity(workers) do
    Map.new(@slot_kinds, fn kind ->
      {kind,
       %{
         free: Enum.sum(Enum.map(workers, &slot(&1, kind, :free))),
         total: Enum.sum(Enum.map(workers, &slot(&1, kind, :total)))
       }}
    end)
  end

  defp slot(worker, kind, bound) do
    case worker.capacity["#{kind}_slots_#{bound}"] do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> 0
    end
  end

  defp event_cursor_lag do
    case Reads.rows(@event_cursor_lag) do
      {:ok, [[lag]]} when is_integer(lag) ->
        {:ok, lag}

      {:ok, _unexpected} ->
        {:error, {:observability_query_failed, "event cursor lag returned no count"}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
