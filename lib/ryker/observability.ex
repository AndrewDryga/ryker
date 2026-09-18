defmodule Ryker.Observability do
  @moduledoc """
  Payload-free health, readiness, and Prometheus projections.

  Queue timing is derived from PostgreSQL time. Metrics contain only fixed
  lifecycle labels and aggregate counts; source bodies, prompts, tool output,
  destinations, credentials, and actor identities never cross this boundary.
  """

  import Ecto.Query

  alias Ryker.Ingress.Inbox

  alias Ryker.CoopFleet.{Command, Placement, Worker, WorkspaceCheckpointTransfer}
  alias Ryker.Defaults
  alias Ryker.Delivery.Reaction
  alias Ryker.Emisar.Approval
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Observability.Progress
  alias Ryker.Publication.Custody, as: PublicationCustody
  alias Ryker.Publication.{Followup, LifecycleEvent, Publication}
  alias Ryker.Repo
  alias Ryker.Retention.Custody, as: RetentionCustody
  alias Ryker.Runtime.Owner
  alias Ryker.Settings
  alias Ryker.Slack.{IncidentRoom, TaskCard}
  alias Ryker.State.{Record, Schedule}
  alias Ryker.Work.Custody, as: WorkCustody
  alias Ryker.Work.{Session, Turn}

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

      durable = durable_settings()

      readiness = %{
        fleet: snapshot.fleet,
        fleet_issues: fleet_issues(snapshot.fleet, settings.stall_after_seconds),
        missing_runtimes: Enum.sort(missing),
        queues: snapshot.queues,
        settings: durable,
        stale_progress_lanes: stale_progress,
        stalled_active_leases: snapshot.stalled_active_leases,
        stalled_queues: snapshot.stalled_queues
      }

      if ready?(readiness), do: {:ok, readiness}, else: {:error, readiness}
    end
  end

  @doc """
  The fixed reasons a failed readiness check reports, safe to print on `/readyz`.

  Only reason codes and lane, queue or runtime names: never an identifier, a
  message or an inspected term, so the endpoint stays payload-free while still
  saying why a deployment is not ready.
  """
  @spec problems(map() | term()) :: [String.t()]
  def problems(%{fleet_issues: _} = readiness) do
    Enum.map(readiness.missing_runtimes, &"runtime not running: #{&1}") ++
      Enum.map(readiness.fleet_issues, &to_string/1) ++
      Enum.map(readiness.stale_progress_lanes, &"lane not cycling: #{&1}") ++
      Enum.map(readiness.stalled_active_leases, &"lease held too long: #{&1}") ++
      Enum.map(readiness.stalled_queues, &"queue not draining: #{&1}") ++
      settings_problems(readiness.settings)
  end

  def problems(reason) when is_tuple(reason) and elem(reason, 0) == :database_unavailable,
    do: ["database unavailable"]

  def problems(_reason), do: ["readiness check failed"]

  defp settings_problems(settings) do
    failure = if settings.failure, do: ["settings not applied: #{settings.failure}"], else: []
    failure ++ Enum.map(settings.unconfigured, &"not configured: #{&1}")
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
         retention: retention_snapshot(now),
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
        [:review_pending, :review_ready, :publish_pending, :published_ready],
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

  # Readiness reads the same eligibility custody claims from, so a Work or
  # learning backlog can never be counted differently by the two owners, and so
  # conversation plus grace time is never reported as cleanup stall.
  defp retention_queue(now) do
    base = RetentionCustody.eligible_query(now)

    claimable =
      from([session: session] in base,
        where: is_nil(session.cleanup_lease_ref) or session.cleanup_lease_expires_at <= ^now
      )

    active =
      from([session: session] in base,
        where: not is_nil(session.cleanup_lease_ref) and session.cleanup_lease_expires_at > ^now
      )

    oldest_active = Repo.one(from([session: session] in active, select: min(session.updated_at)))

    %{
      active_leases: Repo.aggregate(active, :count, :id),
      claimable: Repo.aggregate(claimable, :count, :id),
      name: :retention,
      oldest_active_age_seconds: age_seconds(now, oldest_active),
      oldest_age_seconds: age_seconds(now, RetentionCustody.oldest_eligible_at(claimable))
    }
  end

  # Every retained byte must be explainable, so cleanup is reported by reason and
  # not only as a queue depth. An absent measurement stays absent here: the
  # projection never substitutes zero for something no worker has reported.
  defp retention_snapshot(now) do
    eligible = RetentionCustody.eligible_query(now)

    retrying =
      from(session in Session,
        where: session.cleanup_status in [:close_pending, :plan_pending, :discard_pending],
        where: not is_nil(session.cleanup_next_attempt_at),
        where: session.cleanup_next_attempt_at > ^now
      )

    retained =
      from(session in Session,
        where: session.cleanup_status == :retained,
        group_by: session.retained_reason,
        select: {session.retained_reason, count(session.id)}
      )

    last_reclaimed = Repo.one(from(session in Session, select: max(session.discarded_at)))

    %{
      blocked: Repo.aggregate(from(s in Session, where: s.cleanup_status == :blocked), :count),
      eligible: Repo.aggregate(eligible, :count, :id),
      last_reclaimed_age_seconds: age_seconds(now, last_reclaimed),
      oldest_eligible_age_seconds:
        age_seconds(now, RetentionCustody.oldest_eligible_at(eligible)),
      retained: retained |> Repo.all() |> Map.new(),
      retrying: Repo.aggregate(retrying, :count, :id),
      sessions: enum_counts(Session, :cleanup_status)
    }
  end

  defp query_queue(base, name, age_field, now) do
    claimable =
      from(row in base,
        where: is_nil(row.lease_ref) or row.lease_expires_at <= ^now
      )
      |> runnable_queue(name, now)

    active =
      from(row in base,
        where: not is_nil(row.lease_ref) and row.lease_expires_at > ^now
      )

    queue_projection(claimable, active, name, age_field, now)
  end

  # Deliberate peer-custody waits are not stalled claimable work. Keep active
  # lease monitoring separate so a stuck executor is still visible.
  defp runnable_queue(query, name, now) when name in [:work, :cancellation, :delivery] do
    phase = if name == :delivery, do: :delivery, else: :work
    episodes = WorkCustody.claimable_episode_ids_query(now, phase)
    from(turn in query, where: turn.episode_id in subquery(episodes))
  end

  defp runnable_queue(query, :publication, now) do
    publications =
      from(publication in PublicationCustody.claimable_query(now), select: publication.id)

    from(publication in query, where: publication.id in subquery(publications))
  end

  defp runnable_queue(query, _name, _now), do: query

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
      storage: fleet_storage(workers, cutoff, now),
      workers: enum_counts(Worker, :state)
    }
  end

  # Workers measure their own filesystem. A worker that reported nothing is
  # unknown, and a worker whose heartbeat has gone stale is reporting a stale
  # measurement; neither is folded into the live totals as zero.
  defp fleet_storage(workers, cutoff, now) do
    {reported, unreported} = Enum.split_with(workers, &is_map(&1.storage))
    {fresh, stale} = Enum.split_with(reported, &fresh_worker?(&1, cutoff))

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
        if(measured_at == [], do: 0, else: age_seconds(now, Enum.min(measured_at, DateTime))),
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

  defp fleet_settings do
    case Application.get_env(:ryker, :work) do
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

  defp fleet_policy_profiles do
    case Application.get_env(:ryker, :fleet_profiles, %{}) do
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

  defp ready?(readiness) do
    readiness.missing_runtimes == [] and readiness.fleet_issues == [] and
      readiness.stale_progress_lanes == [] and readiness.stalled_active_leases == [] and
      readiness.stalled_queues == [] and is_nil(readiness.settings.failure) and
      readiness.settings.unconfigured == []
  end

  # Configuration is not health. A revision an operator saved but the runtime
  # could not assemble, and an integration this installation turned on but that
  # is not running, are both states where "ready" would be a lie.
  defp durable_settings do
    case Settings.fetch() do
      {:ok, snapshot} ->
        %{
          applied_revision: snapshot.installation.applied_revision,
          failure: snapshot.installation.failure_code,
          revision: snapshot.installation.revision,
          unconfigured: unconfigured_dependencies(snapshot)
        }

      {:error, :settings_not_initialized} ->
        %{applied_revision: 0, failure: nil, revision: 0, unconfigured: []}
    end
  rescue
    error in [DBConnection.ConnectionError, Ecto.NoResultsError, Postgrex.Error] ->
      %{
        applied_revision: 0,
        failure: error.__struct__ |> Module.split() |> List.last() |> Macro.underscore(),
        revision: 0,
        unconfigured: []
      }
  end

  defp unconfigured_dependencies(snapshot) do
    [
      emisar: snapshot.emisar.enabled,
      github: snapshot.github.enabled,
      learning: snapshot.learning.enabled,
      publication: snapshot.publication.enabled,
      slack: snapshot.slack.enabled,
      webhooks: Enum.any?(snapshot.webhook_sources, & &1.enabled),
      work: Defaults.execution() == :fleet and is_binary(snapshot.work.workspace_ref)
    ]
    |> Enum.filter(fn {name, desired} ->
      desired and is_nil(Application.get_env(:ryker, name))
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp runtime_status do
    # The owner knows which setting started which process; several of its
    # children are plain listeners whose module is the web server's, so the
    # supervisor's own child list cannot answer that question.
    running = Owner.running_keys()

    # Keyed by configuration key; the process named beside it is the one a
    # runtime started outside the owner (the isolated test topology) registers.
    [
      admission: {:named, Ryker.Admission.Runtime},
      learning: {:named, Ryker.Learning.Runtime},
      coop_worker_gateway: {:supervised, Ryker.CoopFleet.Server},
      control_plane: {:supervised, Ryker.ControlPlane.Server},
      delivery: {:named, Ryker.Delivery.Runtime},
      emisar: {:named, Ryker.Emisar.ApprovalRuntime},
      event_waits: {:named, Ryker.State.EventWaitWorker},
      github: {:named, Ryker.GitHub.Runtime},
      publication: {:named, Ryker.Publication.Runtime},
      retention: {:named, Ryker.Retention.Runtime},
      schedules: {:named, Ryker.State.ScheduleWorker},
      slack: {:named, Ryker.Slack.Supervisor},
      state_tools: {:supervised, Ryker.StateTools.Server},
      webhooks: {:supervised, Ryker.Webhooks.Server},
      work: {:named, Ryker.Work.Runtime}
    ]
    |> Enum.flat_map(fn {key, owner} ->
      case Application.get_env(:ryker, key) do
        nil -> []
        false -> []
        _configured -> [{key, key in running or runtime_alive?(owner)}]
      end
    end)
    |> Map.new()
  end

  defp required_progress_lanes do
    [
      admission: [:admission],
      learning: [:learning],
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
      case Application.get_env(:ryker, configuration_key) do
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
           "SELECT lane, outcome, cycle_count, observed_at FROM ryker_runtime_progress ORDER BY lane",
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

  # Durable settings moved the product children under the runtime owner's
  # dynamic supervisor; only the owner and the repo stay directly under the
  # application supervisor. Looking in one place reported every unnamed child
  # as missing and held readiness red on a healthy installation.
  defp runtime_alive?({:supervised, child_id}) do
    Enum.any?([Ryker.Runtime.Supervisor, Ryker.Supervisor], fn supervisor ->
      case Process.whereis(supervisor) do
        pid when is_pid(pid) -> child_alive?(pid, child_id)
        nil -> false
      end
    end)
  end

  defp child_alive?(supervisor, child_id) do
    supervisor
    |> children_of()
    |> Enum.any?(fn
      {^child_id, pid, _type, _modules} when is_pid(pid) -> Process.alive?(pid)
      {:undefined, pid, _type, modules} when is_pid(pid) -> child_id in List.wrap(modules)
      _other -> false
    end)
  end

  defp children_of(supervisor) do
    Supervisor.which_children(supervisor)
  rescue
    _error -> []
  catch
    :exit, _reason -> []
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

    fleet_lines = fleet_metric_lines(snapshot.fleet)
    retention_lines = retention_metric_lines(snapshot.retention)

    ([
       "# Ryker aggregate lifecycle metrics. No message or prompt labels are exported.",
       "# An absent storage series is an unmeasured value, never a measured zero.",
       metric("ryker_observability_snapshot", 1)
     ] ++ count_lines ++ queue_lines ++ progress_lines ++ fleet_lines ++ retention_lines)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp fleet_metric_lines(fleet) do
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
      placement_lines ++ command_lines ++ capacity_lines ++ storage_metric_lines(fleet.storage)
  end

  defp storage_metric_lines(storage) do
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

  defp retention_metric_lines(retention) do
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
