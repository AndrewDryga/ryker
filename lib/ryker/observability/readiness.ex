defmodule Ryker.Observability.Readiness do
  @moduledoc """
  Whether this installation can do its work, judged from one observability
  snapshot, the runtimes its settings started, and its durable settings.

  It is not ready while a configured runtime is not running, a lane has
  stopped cycling, a queue has stopped draining, a lease is held too long, a
  required fleet cannot start work, or settings were saved but not applied or
  turned on but never started. Every reason is a fixed code or a lane, queue
  or runtime name, so `/readyz` can say why without printing anything it read.
  """
  alias Ryker.Config
  alias Ryker.Defaults
  alias Ryker.Observability.Fleet
  alias Ryker.Runtime.Owner
  alias Ryker.Settings

  @type check :: %{
          check_progress: boolean(),
          check_runtimes: boolean(),
          stall_after_seconds: pos_integer()
        }

  @doc "The readiness verdict: the same map either way, `:error` when anything stops work."
  @spec evaluate(map(), check()) :: {:ok, map()} | {:error, map()}
  def evaluate(snapshot, check) do
    runtimes = if check.check_runtimes, do: runtime_status(), else: %{}
    missing = for {name, false} <- runtimes, do: name

    stale_progress =
      if check.check_progress do
        stale_progress_lanes(
          snapshot.progress,
          required_progress_lanes(),
          check.stall_after_seconds
        )
      else
        []
      end

    readiness = %{
      fleet: snapshot.fleet,
      fleet_issues: Fleet.issues(snapshot.fleet, check.stall_after_seconds),
      missing_runtimes: Enum.sort(missing),
      queues: snapshot.queues,
      settings: durable_settings(),
      stale_progress_lanes: stale_progress,
      stalled_active_leases: snapshot.stalled_active_leases,
      stalled_queues: snapshot.stalled_queues
    }

    if ready?(readiness), do: {:ok, readiness}, else: {:error, readiness}
  end

  @doc "Why a verdict is not ready, as fixed reasons in a fixed order."
  @spec reasons(map()) :: [String.t()]
  def reasons(readiness) do
    Enum.map(readiness.missing_runtimes, &"runtime not running: #{&1}") ++
      Enum.map(readiness.fleet_issues, &to_string/1) ++
      Enum.map(readiness.stale_progress_lanes, &"lane not cycling: #{&1}") ++
      Enum.map(readiness.stalled_active_leases, &"lease held too long: #{&1}") ++
      Enum.map(readiness.stalled_queues, &"queue not draining: #{&1}") ++
      settings_reasons(readiness.settings)
  end

  defp settings_reasons(settings) do
    failure = if settings.failure, do: ["settings not applied: #{settings.failure}"], else: []
    failure ++ Enum.map(settings.unconfigured, &"not configured: #{&1}")
  end

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
    case fetch_settings() do
      {:ok, snapshot} ->
        %{
          applied_revision: snapshot.installation.applied_revision,
          failure: snapshot.installation.failure_code,
          revision: snapshot.installation.revision,
          unconfigured: unconfigured_dependencies(snapshot)
        }

      {:error, :settings_not_initialized} ->
        %{applied_revision: 0, failure: nil, revision: 0, unconfigured: []}

      {:error, {:settings_unreadable, failure}} ->
        %{applied_revision: 0, failure: failure, revision: 0, unconfigured: []}
    end
  end

  # The settings read raises when the database refuses it. Readiness reports
  # that as a settings failure named by the error's kind rather than failing
  # the whole check.
  defp fetch_settings do
    Settings.fetch()
  rescue
    error in [DBConnection.ConnectionError, Ecto.NoResultsError, Postgrex.Error] ->
      {:error,
       {:settings_unreadable,
        error.__struct__ |> Module.split() |> List.last() |> Macro.underscore()}}
  end

  defp unconfigured_dependencies(snapshot) do
    [
      emisar: Enum.any?(snapshot.emisar_connections, & &1.monitoring_enabled),
      github: snapshot.github.enabled,
      learning: learning_runtime_expected?(snapshot),
      publication: snapshot.publication.enabled,
      slack: snapshot.slack.enabled,
      webhooks: Enum.any?(snapshot.webhook_sources, & &1.enabled),
      work: Defaults.execution() == :fleet and is_binary(snapshot.work.workspace_ref)
    ]
    |> Enum.filter(fn {name, desired} ->
      desired and is_nil(Config.get_env(name))
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp learning_runtime_expected?(snapshot) do
    snapshot.learning.enabled and Defaults.execution() == :fleet and
      is_binary(snapshot.work.workspace_ref)
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
      admission_ready: {:named, Ryker.Admission.ReadyPool},
      learning: {:named, Ryker.Learning.Runtime},
      improvement: {:named, Ryker.Improvement.Runtime},
      coop_worker_gateway: {:supervised, Ryker.CoopFleet.Server},
      control_plane: {:supervised, Ryker.ControlPlane.Server},
      delivery: {:named, Ryker.Delivery.Runtime},
      emisar: {:named, Ryker.Emisar.ApprovalRuntime},
      event_waits: {:named, Ryker.Waits.EventWaitWorker},
      github: {:named, Ryker.GitHub.Runtime},
      publication: {:named, Ryker.Publication.Runtime},
      retention: {:named, Ryker.Retention.Runtime},
      schedules: {:named, Ryker.Schedules.ScheduleWorker},
      slack: {:named, Ryker.Slack.Supervisor},
      webhooks: {:supervised, Ryker.Webhooks.Server},
      weekly_report: {:named, Ryker.WeeklyReport.Worker},
      work: {:named, Ryker.Work.Runtime}
    ]
    |> Enum.flat_map(fn {key, owner} ->
      case Config.get_env(key) do
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
      case Config.get_env(configuration_key) do
        nil -> []
        false -> []
        _configured -> lanes
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
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

  # Each runtime key runs under a supervisor of its own (`Ryker.Runtime.Child`),
  # so a listener is found one level down.
  defp child_alive?(supervisor, child_id) do
    supervisor
    |> children_of()
    |> Enum.any?(fn
      {^child_id, pid, _type, _modules} when is_pid(pid) ->
        Process.alive?(pid)

      {:undefined, pid, _type, modules} when is_pid(pid) ->
        child_id in List.wrap(modules) or
          (Ryker.Runtime.Child in List.wrap(modules) and child_alive?(pid, child_id))

      _other ->
        false
    end)
  end

  # A supervisor can stop between looking it up and asking for its children.
  defp children_of(supervisor) do
    Supervisor.which_children(supervisor)
  catch
    :exit, _reason -> []
  end

  defp alive?(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> Process.alive?(pid)
      nil -> false
    end
  end
end
