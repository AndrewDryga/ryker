defmodule Ryker.Observability.Metrics do
  @moduledoc """
  The Prometheus text exposition of one observability snapshot.

  Only fixed lifecycle labels and aggregate numbers are exported: never a
  message, prompt, identifier or destination. Series that come from a map are
  written in the map's own order.
  """

  @doc "Renders every series of `snapshot`, one per line, ending with a newline."
  @spec render(map()) :: binary()
  def render(snapshot) do
    count_lines =
      snapshot.counts
      |> Enum.flat_map(fn
        {family, %{total: total}} ->
          [metric("ryker_#{family}_total", total)]

        {family, statuses} ->
          Enum.map(statuses, fn {status, count} ->
            metric(
              "ryker_#{family}_total",
              count,
              ~s(status="#{Atom.to_string(status)}")
            )
          end)
      end)

    queue_lines =
      Enum.flat_map(snapshot.queues, fn queue ->
        label = ~s(queue="#{Atom.to_string(queue.name)}")

        [
          metric("ryker_queue_active_leases", queue.active_leases, label),
          metric("ryker_queue_claimable", queue.claimable, label),
          metric(
            "ryker_queue_oldest_active_age_seconds",
            queue.oldest_active_age_seconds,
            label
          ),
          metric("ryker_queue_oldest_age_seconds", queue.oldest_age_seconds, label)
        ]
      end)

    progress_lines =
      Enum.flat_map(snapshot.progress, fn heartbeat ->
        label = ~s(lane="#{Atom.to_string(heartbeat.lane)}")

        [
          metric("ryker_runtime_progress_age_seconds", heartbeat.age_seconds, label),
          metric("ryker_runtime_progress_cycles", heartbeat.cycle_count, label)
        ]
      end)

    ([
       "# Ryker aggregate lifecycle metrics. No message or prompt labels are exported.",
       "# An absent storage series is an unmeasured value, never a measured zero.",
       metric("ryker_observability_snapshot", 1)
     ] ++
       count_lines ++
       queue_lines ++
       progress_lines ++ fleet_lines(snapshot.fleet) ++ retention_lines(snapshot.retention))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp fleet_lines(fleet) do
    worker_lines =
      Enum.map(fleet.workers, fn {state, count} ->
        metric("ryker_coop_fleet_workers", count, ~s(state="#{Atom.to_string(state)}"))
      end)

    provider_lines =
      Enum.map(fleet.provider_states, fn {state, count} ->
        metric("ryker_coop_fleet_provider_workers", count, ~s(state="#{state}"))
      end)

    placement_lines =
      Enum.map(fleet.placements, fn {state, count} ->
        metric(
          "ryker_coop_fleet_placements",
          count,
          ~s(state="#{Atom.to_string(state)}")
        )
      end)

    command_lines =
      Enum.map(fleet.commands, fn {status, count} ->
        metric(
          "ryker_coop_fleet_commands",
          count,
          ~s(status="#{Atom.to_string(status)}")
        )
      end)

    capacity_lines =
      Enum.flat_map(fleet.capacity, fn {kind, capacity} ->
        label = ~s(kind="#{Atom.to_string(kind)}")

        [
          metric("ryker_coop_fleet_slots_free", capacity.free, label),
          metric("ryker_coop_fleet_slots_total", capacity.total, label)
        ]
      end)

    [
      metric("ryker_coop_fleet_required", if(fleet.required, do: 1, else: 0)),
      metric("ryker_coop_fleet_fresh_workers", fleet.fresh_workers),
      metric("ryker_coop_fleet_stale_workers", fleet.stale_workers),
      metric("ryker_coop_fleet_eligible_workers", fleet.eligible_workers),
      metric("ryker_coop_fleet_required_policy_profiles", fleet.required_policy_profiles),
      metric("ryker_coop_fleet_available_policy_profiles", fleet.available_policy_profiles),
      metric("ryker_coop_fleet_current_placements", fleet.current_placements),
      metric(
        "ryker_coop_fleet_expired_current_placements",
        fleet.expired_current_placements
      ),
      metric("ryker_coop_fleet_event_cursor_lag", fleet.event_cursor_lag),
      metric(
        "ryker_coop_fleet_oldest_queued_command_age_seconds",
        fleet.oldest_queued_command_age_seconds
      ),
      metric("ryker_coop_fleet_checkpoints", fleet.checkpoints.total),
      metric(
        "ryker_coop_fleet_latest_checkpoint_age_seconds",
        fleet.checkpoints.latest_age_seconds
      )
    ] ++
      worker_lines ++
      provider_lines ++
      placement_lines ++ command_lines ++ capacity_lines ++ storage_lines(fleet.storage)
  end

  defp storage_lines(storage) do
    byte_lines =
      Enum.map(storage.bytes, fn {kind, value} ->
        metric(
          "ryker_coop_fleet_storage_bytes",
          value,
          ~s(kind="#{String.replace_suffix(kind, "_bytes", "")}")
        )
      end)

    unattributed_lines =
      case storage.unattributed_bytes do
        nil -> []
        value -> [metric("ryker_coop_fleet_storage_bytes", value, ~s(kind="unattributed"))]
      end

    [
      metric("ryker_coop_fleet_storage_reporting_workers", storage.reporting),
      metric("ryker_coop_fleet_storage_stale_workers", storage.stale),
      metric("ryker_coop_fleet_storage_unknown_workers", storage.unknown),
      metric("ryker_coop_fleet_storage_refused_workers", storage.refused),
      metric("ryker_coop_fleet_storage_reclaimed_bytes", storage.reclaimed_bytes),
      metric(
        "ryker_coop_fleet_storage_oldest_measurement_age_seconds",
        storage.oldest_measurement_age_seconds
      )
    ] ++ byte_lines ++ unattributed_lines
  end

  defp retention_lines(retention) do
    session_lines =
      Enum.map(retention.sessions, fn {status, count} ->
        metric("ryker_retention_sessions", count, ~s(status="#{Atom.to_string(status)}"))
      end)

    retained_lines =
      Enum.map(retention.retained, fn {reason, count} ->
        metric("ryker_retention_retained", count, ~s(reason="#{reason || "unknown"}"))
      end)

    [
      metric("ryker_retention_blocked", retention.blocked),
      metric("ryker_retention_eligible", retention.eligible),
      metric("ryker_retention_retrying", retention.retrying),
      metric(
        "ryker_retention_oldest_eligible_age_seconds",
        retention.oldest_eligible_age_seconds
      ),
      metric(
        "ryker_retention_last_reclaimed_age_seconds",
        retention.last_reclaimed_age_seconds
      )
    ] ++ session_lines ++ retained_lines
  end

  defp metric(name, value), do: "#{name} #{value}"
  defp metric(name, value, labels), do: "#{name}{#{labels}} #{value}"
end
