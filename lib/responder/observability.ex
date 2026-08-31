defmodule Responder.Observability do
  @moduledoc """
  Payload-free health, readiness, and Prometheus projections.

  Queue timing is derived from PostgreSQL time. Metrics contain only fixed
  lifecycle labels and aggregate counts; source bodies, prompts, tool output,
  destinations, credentials, and actor identities never cross this boundary.
  """

  import Ecto.Query

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
        missing_runtimes: Enum.sort(missing),
        queues: snapshot.queues,
        stale_progress_lanes: stale_progress,
        stalled_active_leases: snapshot.stalled_active_leases,
        stalled_queues: snapshot.stalled_queues
      }

      if missing == [] and stale_progress == [] and snapshot.stalled_active_leases == [] and
           snapshot.stalled_queues == [],
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
    schema
    |> then(fn schema ->
      from(row in schema,
        group_by: row.status,
        order_by: row.status,
        select: {row.status, count(row.id)}
      )
    end)
    |> Repo.all()
    |> Map.new()
  end

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
      admission: {:admission, {:named, Responder.Admission.Worker}},
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

    ([
       "# Responder aggregate lifecycle metrics. No message or prompt labels are exported.",
       metric("responder_observability_snapshot", 1)
     ] ++ count_lines ++ queue_lines ++ progress_lines)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp metric(name, value), do: "#{name} #{value}"
  defp metric(name, value, labels), do: "#{name}{#{labels}} #{value}"
end
