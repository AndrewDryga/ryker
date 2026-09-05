defmodule Responder.Observability do
  @moduledoc """
  Payload-free health, readiness, and Prometheus projections.

  Queue timing is derived from PostgreSQL time. Metrics contain only fixed
  lifecycle labels and aggregate counts; source bodies, prompts, tool output,
  destinations, credentials, and actor identities never cross this boundary.
  """

  import Ecto.Query

  alias Responder.Ingress.Inbox

  alias Responder.CoopFleet.{Command, Placement, Worker, WorkspaceCheckpointTransfer}
  alias Responder.Delivery.Reaction
  alias Responder.Emisar.Approval
  alias Responder.Episodes.Episode
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Observability.Progress
  alias Responder.Publication.{Followup, LifecycleEvent, Publication}
  alias Responder.Repo
  alias Responder.Slack.{IncidentRoom, TaskCard}
  alias Responder.State.{Record, Schedule}
  alias Responder.Work.{Session, Turn}

  @default_stall_after_seconds 15 * 60
  @fleet_heartbeat_stale_seconds 60
  @current_placement_states [:assigning, :active, :draining, :revoking]
  @readiness_options [:check_progress, :check_runtimes, :stall_after_seconds]

  @spec callbacks() :: map()
  def callbacks do
    %{health: &health/0, metrics: &metrics/0, ready: &ready/0}
  end

  @spec health() :: {:ok, map()} | {:error, term()}
  def health do
    case Repo.query("SELECT 1", [], log: false) do
      {:ok, _result} -> {:ok, %{database: :ok}}
      {:error, reason} -> {:error, {:database_unavailable, reason}}
    end
  rescue
    error -> {:error, {:database_unavailable, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:database_unavailable, kind, inspect(reason)}}
  end

  @spec ready(keyword()) :: {:ok, map()} | {:error, map() | term()}
  def ready(options \\ []) do
    with {:ok, settings} <- readiness_settings(options),
         {:ok, snapshot} <- snapshot(settings.stall_after_seconds) do
      runtimes = if settings.check_runtimes, do: runtime_status(), else: %{}
      missing = for {name, false} <- runtimes, do: name

      stale_progress =
        if settings.check_progress do
          stale_progress_lanes(
            snapshot.progress,
            required_progress_lanes(),
            settings.stall_after_seconds
          )
        else
          []
        end

      readiness = %{
        fleet: snapshot.fleet,
        fleet_issues: fleet_issues(snapshot.fleet, settings.stall_after_seconds),
        missing_runtimes: Enum.sort(missing),
        queues: snapshot.queues,
        stale_progress_lanes: stale_progress,
        stalled_active_leases: snapshot.stalled_active_leases,
        stalled_queues: snapshot.stalled_queues
      }

      if missing == [] and readiness.fleet_issues == [] and stale_progress == [] and
           snapshot.stalled_active_leases == [] and snapshot.stalled_queues == [],
         do: {:ok, readiness},
         else: {:error, readiness}
    end
  end

  @spec metrics() :: {:ok, binary()} | {:error, term()}
  def metrics do
    with {:ok, snapshot} <- snapshot(@default_stall_after_seconds) do
      {:ok, render_metrics(snapshot)}
    end
  end

  @spec fleet() :: {:ok, map()} | {:error, term()}
  def fleet do
    with {:ok, now} <- database_now() do
      {:ok, fleet_snapshot(now)}
    end
  rescue
    error -> {:error, {:observability_query_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:observability_query_failed, kind, inspect(reason)}}
  end

  @spec snapshot(pos_integer()) :: {:ok, map()} | {:error, term()}
  def snapshot(stall_after_seconds \\ @default_stall_after_seconds)

  def snapshot(stall_after_seconds)
      when is_integer(stall_after_seconds) and stall_after_seconds > 0 do
    with {:ok, now} <- database_now() do
      queues = queues(now)
      progress = progress_snapshot(now)

      {:ok,
       %{
         counts: %{
           incidents: status_counts(IncidentRoom),
           ingress: status_counts(Entry),
           publications: status_counts(Publication),
           reactions: status_counts(Reaction),
           schedules: status_counts(Schedule),
           task_cards: %{total: Repo.aggregate(TaskCard, :count, :id)},
           work: status_counts(Turn)
         },
         fleet: fleet_snapshot(now),
         generated_at: now,
         progress: progress,
         queues: queues,
         stalled_active_leases:
           queues
           |> Enum.filter(
             &(&1.active_leases > 0 and
                 &1.oldest_active_age_seconds > stall_after_seconds)
           )
           |> Enum.map(& &1.name)
           |> Enum.sort(),
         stalled_queues:
           queues
           |> Enum.filter(&(&1.claimable > 0 and &1.oldest_age_seconds > stall_after_seconds))
           |> Enum.map(& &1.name)
           |> Enum.sort()
       }}
    end
  rescue
    error -> {:error, {:observability_query_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:observability_query_failed, kind, inspect(reason)}}
  end

  def snapshot(_stall_after_seconds),
    do: {:error, {:invalid_observability, :stall_after_seconds}}

  defp queues(now) do
    [
      queue(Entry, :ingress, [:pending], :inserted_at, now),
      queue(Turn, :work, [:pending], :inserted_at, now),
      queue(Turn, :cancellation, [:cancel_pending], :updated_at, now),
      queue(Turn, :delivery, [:delivery_pending], :accepted_at, now),
      queue(Reaction, :reaction_delivery, [:pending], :inserted_at, now),
      queue(
        Publication,
        :publication,
        [:review_pending, :publish_pending, :published_ready],
        :updated_at,
        now
      ),
      approval_queue(now),
      publication_followup_queue(now),
      publication_lifecycle_queue(now),
      retention_queue(now),
      due_schedule_queue(now)
    ]
  end

  defp queue(Entry, :ingress, [:pending], age_field, now) do
    active =
      from(entry in Entry,
        where:
          entry.status == :pending and not is_nil(entry.lease_ref) and
            entry.lease_expires_at > ^now
      )

    queue_projection(
      Inbox.claimable_query(now),
      active,
      :ingress,
      age_field,
      now
    )
  end

  defp queue(schema, name, statuses, age_field, now) do
    base =
      from(row in schema,
        where: row.status in ^statuses,
        where: is_nil(row.next_attempt_at) or row.next_attempt_at <= ^now
      )

    query_queue(base, name, age_field, now)
  end

  defp due_schedule_queue(now) do
    base =
      from(schedule in Schedule,
        where: schedule.status == :active,
        where: schedule.next_occurrence_at <= ^now,
        where: is_nil(schedule.next_attempt_at) or schedule.next_attempt_at <= ^now
      )

    query_queue(base, :schedule, :next_occurrence_at, now)
  end

  defp approval_queue(now) do
    base =
      from(approval in Approval,
        join: record in Record,
        on: record.id == approval.record_id and record.episode_id == approval.episode_id,
        join: episode in Episode,
        on: episode.id == approval.episode_id,
        where: approval.status == :monitoring,
        where: record.kind == "emisar_approval" and record.status == :open,
        where:
          episode.state == :waiting_for_event and episode.owner_kind == :event and
            episode.owner_ref == record.ref,
        where: is_nil(approval.next_attempt_at) or approval.next_attempt_at <= ^now
      )

    query_queue(base, :emisar_approval, :inserted_at, now)
  end

  defp publication_followup_queue(now) do
    base =
      from(followup in Followup,
        where: followup.next_poll_at <= ^now
      )

    query_queue(base, :publication_followup, :next_poll_at, now)
  end

  defp publication_lifecycle_queue(now) do
    base =
      from(event in LifecycleEvent,
        where: event.delivery_state == :pending,
        where: is_nil(event.next_attempt_at) or event.next_attempt_at <= ^now
      )

    query_queue(base, :publication_lifecycle, :inserted_at, now)
  end

  defp retention_queue(now) do
    unfinished_sessions =
      from(turn in Turn,
        where: turn.status in [:pending, :cancel_pending, :delivery_pending],
        select: turn.session_id
      )

    published_record_ids =
      from(publication in Publication,
        where: publication.status == :published,
        select: publication.record_id
      )

    open_episode_ids =
      from(record in Record,
        where:
          record.status == :open and
            (record.kind != "publication_offer" or
               record.id not in subquery(published_record_ids)),
        select: record.episode_id
      )

    unpublished_sessions =
      from(publication in Publication,
        where: publication.status != :published,
        select: publication.session_id
      )

    base =
      from(session in Session,
        join: episode in Episode,
        on: episode.id == session.episode_id,
        where: episode.state in [:complete, :cancelled],
        where: session.id not in subquery(unfinished_sessions),
        where: episode.id not in subquery(open_episode_ids),
        where: session.id not in subquery(unpublished_sessions),
        where:
          fragment(
            "? = 'active' OR (? IN ('close_pending', 'plan_pending', 'discard_pending') AND (? IS NULL OR ? <= ?)) OR (? = 'grace' AND ? <= ?) OR (? = 'retained' AND ? = 'unpublished_unmerged' AND ? IN (SELECT session_id FROM episode_publications WHERE status = 'published'))",
            session.cleanup_status,
            session.cleanup_status,
            session.cleanup_next_attempt_at,
            session.cleanup_next_attempt_at,
            ^now,
            session.cleanup_status,
            session.discard_after,
            ^now,
            session.cleanup_status,
            session.retained_reason,
            session.id
          )
      )

    query_cleanup_queue(base, :retention, :inserted_at, now)
  end

  defp query_queue(base, name, age_field, now) do
    claimable =
      from(row in base,
        where: is_nil(row.lease_ref) or row.lease_expires_at <= ^now
      )

    active =
      from(row in base,
        where: not is_nil(row.lease_ref) and row.lease_expires_at > ^now
      )

    queue_projection(claimable, active, name, age_field, now)
  end

  defp query_cleanup_queue(base, name, age_field, now) do
    claimable =
      from(row in base,
        where: is_nil(row.cleanup_lease_ref) or row.cleanup_lease_expires_at <= ^now
      )

    active =
      from(row in base,
        where: not is_nil(row.cleanup_lease_ref) and row.cleanup_lease_expires_at > ^now
      )

    queue_projection(claimable, active, name, age_field, now)
  end

  defp queue_projection(claimable, active, name, age_field, now) do
    oldest_claimable = Repo.one(from(row in claimable, select: min(field(row, ^age_field))))
    oldest_active = Repo.one(from(row in active, select: min(row.updated_at)))

    %{
      active_leases: Repo.aggregate(active, :count, :id),
      claimable: Repo.aggregate(claimable, :count, :id),
      name: name,
      oldest_active_age_seconds: age_seconds(now, oldest_active),
      oldest_age_seconds: age_seconds(now, oldest_claimable)
    }
  end

  defp age_seconds(_now, nil), do: 0

  defp age_seconds(%DateTime{} = now, %NaiveDateTime{} = datetime),
    do: max(NaiveDateTime.diff(DateTime.to_naive(now), datetime, :second), 0)

  defp age_seconds(now, datetime), do: max(DateTime.diff(now, datetime, :second), 0)

  defp status_counts(schema) do
    enum_counts(schema, :status)
  end

  defp enum_counts(schema, field) do
    schema
    |> then(fn schema ->
      from(row in schema,
        group_by: field(row, ^field),
        order_by: field(row, ^field),
        select: {field(row, ^field), count(row.id)}
      )
    end)
    |> Repo.all()
    |> Map.new()
  end

  defp fleet_snapshot(now) do
    settings = fleet_settings()
    workers = Repo.all(Worker)
    cutoff = DateTime.add(now, -@fleet_heartbeat_stale_seconds, :second)

    fresh_workers = Enum.filter(workers, &fresh_worker?(&1, cutoff))

    eligible_workers =
      Enum.filter(
        fresh_workers,
        &eligible_worker?(&1, settings.workspace_ref, settings.capabilities)
      )

    profiles = fleet_policy_profiles()

    available_profiles =
      Enum.count(profiles, fn profile ->
        Enum.any?(eligible_workers, &worker_supports_profile?(&1, profile))
      end)

    current_placements =
      from(placement in Placement, where: placement.state in ^@current_placement_states)

    expired_placements =
      from(placement in current_placements, where: placement.lease_expires_at <= ^now)

    oldest_queued_command =
      Repo.one(
        from(command in Command,
          where: command.status == :queued,
          select: min(command.inserted_at)
        )
      )

    latest_checkpoint =
      Repo.one(
        from(checkpoint in WorkspaceCheckpointTransfer, select: max(checkpoint.inserted_at))
      )

    %{
      available_policy_profiles: available_profiles,
      capacity: fleet_capacity(eligible_workers),
      checkpoints: %{
        latest_age_seconds: age_seconds(now, latest_checkpoint),
        total: Repo.aggregate(WorkspaceCheckpointTransfer, :count, :id)
      },
      commands: status_counts(Command),
      current_placements: Repo.aggregate(current_placements, :count, :id),
      eligible_workers: length(eligible_workers),
      event_cursor_lag: fleet_event_cursor_lag(),
      expired_current_placements: Repo.aggregate(expired_placements, :count, :id),
      fresh_workers: length(fresh_workers),
      oldest_queued_command_age_seconds: age_seconds(now, oldest_queued_command),
      placements: enum_counts(Placement, :state),
      provider_states: Enum.frequencies_by(fresh_workers, &provider_state/1),
      required: settings.required,
      required_capabilities: length(settings.capabilities),
      required_policy_profiles: length(profiles),
      stale_workers: Enum.count(workers, &(not fresh_worker?(&1, cutoff))),
      workers: enum_counts(Worker, :state)
    }
  end

  defp fleet_settings do
    case Application.get_env(:responder, :work) do
      %{
        api: Responder.CoopFleet.Client,
        client: %Responder.CoopFleet.Client{bridge_options: options}
      }
      when is_list(options) ->
        %{
          capabilities: Keyword.get(options, :capability_names, ["responder-state"]),
          required: true,
          workspace_ref: Keyword.get(options, :workspace_ref)
        }

      _direct_or_disabled ->
        %{capabilities: [], required: false, workspace_ref: nil}
    end
  end

  defp fleet_policy_profiles do
    case Application.get_env(:responder, :cutover_profiles, %{}) do
      profiles when is_map(profiles) ->
        profiles
        |> Map.values()
        |> Enum.filter(fn profile ->
          is_map(profile) and is_binary(profile.policy) and is_binary(profile.policy_digest)
        end)
        |> Enum.uniq_by(&{&1.policy, &1.policy_digest, Map.get(&1, :repository_ref)})

      _invalid ->
        []
    end
  end

  defp fresh_worker?(%Worker{last_seen_at: %DateTime{} = last_seen_at}, cutoff) do
    DateTime.compare(last_seen_at, cutoff) != :lt
  end

  defp fresh_worker?(_worker, _cutoff), do: false

  defp eligible_worker?(worker, workspace_ref, capabilities) do
    worker.workspace_ref == workspace_ref and worker.state == :eligible and
      is_nil(worker.drain_requested_at) and is_nil(worker.revoked_at) and
      provider_state(worker) == "eligible" and worker_capabilities?(worker, capabilities) and
      Enum.all?(~w(session turn workspace), &(capacity_slot(worker, &1, :free) > 0))
  end

  defp worker_capabilities?(worker, required) do
    available = MapSet.new(worker.capabilities, & &1["name"])
    Enum.all?(required, &MapSet.member?(available, &1))
  end

  defp worker_supports_profile?(worker, profile) do
    worker.policy_digests[profile.policy] == profile.policy_digest and
      repository_available?(worker.repositories, Map.get(profile, :repository_ref))
  end

  defp repository_available?(_repositories, nil), do: true

  defp repository_available?(repositories, repository_ref) do
    Enum.any?(repositories, &(&1["ref"] == repository_ref))
  end

  defp provider_state(worker) do
    case worker.capacity["state"] do
      state when state in ~w(eligible busy cooldown needs_auth) -> state
      _unknown -> "unknown"
    end
  end

  defp fleet_capacity(workers) do
    Map.new(~w(session turn workspace), fn kind ->
      {String.to_atom(kind),
       %{
         free: Enum.sum(Enum.map(workers, &capacity_slot(&1, kind, :free))),
         total: Enum.sum(Enum.map(workers, &capacity_slot(&1, kind, :total)))
       }}
    end)
  end

  defp capacity_slot(worker, kind, bound) do
    case worker.capacity["#{kind}_slots_#{bound}"] do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> 0
    end
  end

  defp fleet_event_cursor_lag do
    query = """
    SELECT COALESCE(SUM(GREATEST(COALESCE(events.maximum_sequence, 0) - placement.last_acked_event_sequence, 0)), 0)::bigint
    FROM coop_session_placements AS placement
    LEFT JOIN LATERAL (
      SELECT MAX(event.sequence) AS maximum_sequence
      FROM coop_worker_events AS event
      WHERE event.placement_id = placement.id
    ) AS events ON TRUE
    WHERE placement.state IN ('assigning', 'active', 'draining', 'revoking')
    """

    case Repo.query!(query, [], log: false) do
      %{rows: [[lag]]} when is_integer(lag) -> lag
    end
  end

  defp fleet_issues(%{required: false}, _stall_after_seconds), do: []

  defp fleet_issues(fleet, stall_after_seconds) do
    []
    |> maybe_issue(
      fleet.available_policy_profiles < fleet.required_policy_profiles,
      :missing_policy_capacity
    )
    |> maybe_issue(fleet.eligible_workers == 0, :no_eligible_workers)
    |> maybe_issue(fleet.capacity.session.free == 0, :no_session_capacity)
    |> maybe_issue(fleet.capacity.turn.free == 0, :no_turn_capacity)
    |> maybe_issue(fleet.capacity.workspace.free == 0, :no_workspace_capacity)
    |> maybe_issue(fleet.expired_current_placements > 0, :expired_current_placements)
    |> maybe_issue(fleet.event_cursor_lag > 0, :event_cursor_lag)
    |> maybe_issue(
      fleet.oldest_queued_command_age_seconds > stall_after_seconds,
      :stalled_queued_commands
    )
  end

  defp maybe_issue(issues, true, issue), do: issues ++ [issue]
  defp maybe_issue(issues, false, _issue), do: issues

  defp database_now do
    case Repo.query("SELECT clock_timestamp()", [], log: false) do
      {:ok, %{rows: [[%DateTime{} = now]]}} -> {:ok, now}
      {:ok, _unexpected} -> {:error, {:observability_query_failed, :database_clock}}
      {:error, reason} -> {:error, {:database_unavailable, reason}}
    end
  end

  defp readiness_settings(options) when is_list(options) do
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

  defp readiness_settings(_options),
    do: {:error, {:invalid_observability, :readiness_options}}

  defp runtime_status do
    [
      admission: {:admission, {:named, Responder.Admission.Runtime}},
      coop_worker_gateway: {:coop_worker_gateway, {:supervised, Responder.CoopFleet.Server}},
      control_plane: {:control_plane, {:supervised, Responder.ControlPlane.Server}},
      delivery: {:delivery, {:named, Responder.Delivery.Runtime}},
      emisar: {:emisar, {:named, Responder.Emisar.ApprovalRuntime}},
      event_waits: {:event_waits, {:named, Responder.State.EventWaitWorker}},
      github: {:github, {:named, Responder.GitHub.Runtime}},
      publication: {:publication, {:named, Responder.Publication.Runtime}},
      retention: {:retention, {:named, Responder.Retention.Runtime}},
      schedules: {:schedules, {:named, Responder.State.ScheduleWorker}},
      slack: {:slack, {:named, Responder.Slack.Supervisor}},
      state_tools: {:state_tools, {:supervised, Responder.StateTools.Server}},
      webhooks: {:webhooks, {:supervised, Responder.Webhooks.Server}},
      work: {:work, {:named, Responder.Work.Runtime}}
    ]
    |> Enum.flat_map(fn {name, {configuration_key, owner}} ->
      case Application.get_env(:responder, configuration_key) do
        nil -> []
        false -> []
        _configured -> [{name, runtime_alive?(owner)}]
      end
    end)
    |> Map.new()
  end

  defp required_progress_lanes do
    [
      admission: [:admission],
      delivery: [:delivery],
      emisar: [:emisar_approval],
      event_waits: [:event_waits],
      publication: [:publication, :publication_followup],
      retention: [:retention],
      schedules: [:schedule],
      slack: [:slack_incidents, :slack_interactions, :slack_task_cards],
      work: [:work]
    ]
    |> Enum.flat_map(fn {configuration_key, lanes} ->
      case Application.get_env(:responder, configuration_key) do
        nil -> []
        false -> []
        _configured -> lanes
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp progress_snapshot(now) do
    case Repo.query(
           "SELECT lane, outcome, cycle_count, observed_at FROM responder_runtime_progress ORDER BY lane",
           [],
           log: false
         ) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [lane, outcome, cycle_count, observed_at] ->
          lane = parse_progress_lane!(lane)

          %{
            age_seconds: age_seconds(now, observed_at),
            cycle_count: cycle_count,
            lane: lane,
            outcome: String.to_existing_atom(outcome),
            observed_at: observed_at
          }
        end)

      {:error, reason} ->
        raise "runtime progress query failed: #{inspect(reason)}"
    end
  end

  defp parse_progress_lane!(lane) do
    Enum.find(Progress.lanes(), &(Atom.to_string(&1) == lane)) ||
      raise "unknown runtime progress lane: #{inspect(lane)}"
  end

  defp stale_progress_lanes(progress, required, stall_after_seconds) do
    progress_by_lane = Map.new(progress, &{&1.lane, &1})

    Enum.filter(required, fn lane ->
      case Map.get(progress_by_lane, lane) do
        nil -> true
        heartbeat -> heartbeat.age_seconds > stall_after_seconds
      end
    end)
  end

  defp runtime_alive?({:named, name}), do: alive?(name)

  defp runtime_alive?({:supervised, child_id}) do
    case Process.whereis(Responder.Supervisor) do
      supervisor when is_pid(supervisor) ->
        Supervisor.which_children(supervisor)
        |> Enum.any?(fn
          {^child_id, pid, _type, _modules} when is_pid(pid) -> Process.alive?(pid)
          _other -> false
        end)

      nil ->
        false
    end
  end

  defp alive?(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> Process.alive?(pid)
      nil -> false
    end
  end

  defp render_metrics(snapshot) do
    count_lines =
      snapshot.counts
      |> Enum.flat_map(fn
        {family, %{total: total}} ->
          [metric("responder_#{family}_total", total)]

        {family, statuses} ->
          Enum.map(statuses, fn {status, count} ->
            metric(
              "responder_#{family}_total",
              count,
              ~s(status="#{Atom.to_string(status)}")
            )
          end)
      end)

    queue_lines =
      Enum.flat_map(snapshot.queues, fn queue ->
        label = ~s(queue="#{Atom.to_string(queue.name)}")

        [
          metric("responder_queue_active_leases", queue.active_leases, label),
          metric("responder_queue_claimable", queue.claimable, label),
          metric(
            "responder_queue_oldest_active_age_seconds",
            queue.oldest_active_age_seconds,
            label
          ),
          metric("responder_queue_oldest_age_seconds", queue.oldest_age_seconds, label)
        ]
      end)

    progress_lines =
      Enum.flat_map(snapshot.progress, fn heartbeat ->
        label = ~s(lane="#{Atom.to_string(heartbeat.lane)}")

        [
          metric("responder_runtime_progress_age_seconds", heartbeat.age_seconds, label),
          metric("responder_runtime_progress_cycles", heartbeat.cycle_count, label)
        ]
      end)

    fleet_lines = fleet_metric_lines(snapshot.fleet)

    ([
       "# Responder aggregate lifecycle metrics. No message or prompt labels are exported.",
       metric("responder_observability_snapshot", 1)
     ] ++ count_lines ++ queue_lines ++ progress_lines ++ fleet_lines)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp fleet_metric_lines(fleet) do
    worker_lines =
      Enum.map(fleet.workers, fn {state, count} ->
        metric("responder_coop_fleet_workers", count, ~s(state="#{Atom.to_string(state)}"))
      end)

    provider_lines =
      Enum.map(fleet.provider_states, fn {state, count} ->
        metric("responder_coop_fleet_provider_workers", count, ~s(state="#{state}"))
      end)

    placement_lines =
      Enum.map(fleet.placements, fn {state, count} ->
        metric(
          "responder_coop_fleet_placements",
          count,
          ~s(state="#{Atom.to_string(state)}")
        )
      end)

    command_lines =
      Enum.map(fleet.commands, fn {status, count} ->
        metric(
          "responder_coop_fleet_commands",
          count,
          ~s(status="#{Atom.to_string(status)}")
        )
      end)

    capacity_lines =
      Enum.flat_map(fleet.capacity, fn {kind, capacity} ->
        label = ~s(kind="#{Atom.to_string(kind)}")

        [
          metric("responder_coop_fleet_slots_free", capacity.free, label),
          metric("responder_coop_fleet_slots_total", capacity.total, label)
        ]
      end)

    [
      metric("responder_coop_fleet_required", if(fleet.required, do: 1, else: 0)),
      metric("responder_coop_fleet_fresh_workers", fleet.fresh_workers),
      metric("responder_coop_fleet_stale_workers", fleet.stale_workers),
      metric("responder_coop_fleet_eligible_workers", fleet.eligible_workers),
      metric("responder_coop_fleet_required_policy_profiles", fleet.required_policy_profiles),
      metric("responder_coop_fleet_available_policy_profiles", fleet.available_policy_profiles),
      metric("responder_coop_fleet_current_placements", fleet.current_placements),
      metric(
        "responder_coop_fleet_expired_current_placements",
        fleet.expired_current_placements
      ),
      metric("responder_coop_fleet_event_cursor_lag", fleet.event_cursor_lag),
      metric(
        "responder_coop_fleet_oldest_queued_command_age_seconds",
        fleet.oldest_queued_command_age_seconds
      ),
      metric("responder_coop_fleet_checkpoints", fleet.checkpoints.total),
      metric(
        "responder_coop_fleet_latest_checkpoint_age_seconds",
        fleet.checkpoints.latest_age_seconds
      )
    ] ++ worker_lines ++ provider_lines ++ placement_lines ++ command_lines ++ capacity_lines
  end

  defp metric(name, value), do: "#{name} #{value}"
  defp metric(name, value, labels), do: "#{name}{#{labels}} #{value}"
end
