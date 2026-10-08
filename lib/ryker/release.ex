defmodule Ryker.Release do
  @moduledoc """
  What the assembled release runs through its `eval` command: migrating the
  database as the container starts, preparing the bundled worker, and the
  operator commands `scripts/compose.sh` runs inside the container.

  There is no rollback: going back is restoring the backup taken before the
  release (`docs/operations.md`, "The schema baseline").
  """
  alias Ryker.{Bootstrap, Settings}
  alias Ryker.CoopFleet
  alias Ryker.Operator
  alias Ryker.Runtime

  @app :ryker
  @fields [:log, :migrations_path, :pool_size, :prefix, :repo]

  @spec migrate(keyword()) :: [integer()]
  def migrate(options \\ []) do
    settings = settings!(options)

    with_repo!(settings, fn repo ->
      repo
      |> Ecto.Migrator.migrations([settings.migrations_path], migrator_options(settings))
      |> refuse_newer_schema!()

      Ecto.Migrator.run(
        repo,
        settings.migrations_path,
        :up,
        migrator_options(settings, all: true)
      )
    end)
  end

  @doc """
  The applied migrations newer than the newest one this release carries.

  Ecto skips an applied version it has no file for, so the release a failed
  deploy left pinned booted on a schema a newer release had migrated and wrote
  to it (2026-10-04 review). The baseline replaced the older ladder, whose
  versions are all older than it, so they never count.
  """
  @spec newer_than_release([{:up | :down, integer(), String.t()}]) :: [integer()]
  def newer_than_release(migrations) do
    newest =
      migrations
      |> Enum.reject(&missing_file?/1)
      |> Enum.map(&elem(&1, 1))
      |> Enum.max(fn -> 0 end)

    for {:up, version, _name} = migration <- migrations,
        missing_file?(migration) and version > newest,
        do: version
  end

  defp missing_file?({_state, _version, name}), do: name == "** FILE NOT FOUND **"

  defp refuse_newer_schema!(migrations) do
    case newer_than_release(migrations) do
      [] ->
        :ok

      newer ->
        raise "the database has migrations newer than this release (#{Enum.join(newer, ", ")}); " <>
                "restore the backup taken before the newer release, or deploy that release again"
    end
  end

  @doc "Prepares the bundled Compose worker without starting a second Ryker runtime."
  @spec prepare_bundled_coop(keyword()) :: :ok
  def prepare_bundled_coop(options \\ []) do
    settings = settings!(options)

    with_repo!(settings, fn _repo ->
      with_settings_pubsub(fn -> Ryker.BundledCoop.prepare_distribution!() end)
    end)
  end

  @doc "Checks the authenticated bundled worker and its automatically pinned ordinary policies."
  @spec bundled_coop_ready?(keyword()) :: boolean()
  def bundled_coop_ready?(options \\ []) do
    settings = settings!(options)
    with_repo!(settings, fn _repo -> Ryker.BundledCoop.ready?() end)
  end

  @doc """
  Issues a one-time enrolment token for a worker the installation does not
  run itself, and prints it once as JSON. `scripts/compose.sh worker-token`
  runs this inside the container, where there is no Mix.
  """
  @spec issue_worker_token(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def issue_worker_token(worker_id, workspace_ref, operator_ref, options \\ []) do
    settings = settings!(options)

    with_repo!(settings, fn _repo ->
      with {:ok, issued} <-
             CoopFleet.Enrollment.issue_token(worker_id, workspace_ref, operator_ref) do
        report(settings, issued)
        {:ok, issued}
      end
    end)
  end

  @doc """
  Drains a worker (no new work; what it holds finishes), resumes one, or
  revokes one at once with its certificates and unused enrolment tokens, and
  prints the result as JSON. `scripts/compose.sh worker-drain`,
  `worker-resume` and `worker-revoke` run this inside the container, where
  there is no Mix to run `mix ryker.coop_worker` with.
  """
  @spec worker_lifecycle(:drain | :resume | :revoke, String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def worker_lifecycle(action, worker_id, operator_ref, options \\ [])
      when action in [:drain, :resume, :revoke] do
    settings = settings!(options)

    with_repo!(settings, fn _repo ->
      changed =
        case action do
          :drain -> CoopFleet.WorkerLifecycle.drain(worker_id, operator_ref)
          :resume -> CoopFleet.WorkerLifecycle.resume(worker_id, operator_ref)
          :revoke -> CoopFleet.WorkerLifecycle.revoke(worker_id, operator_ref)
        end

      with {:ok, %{status: status, worker: worker}} <- changed do
        result = %{
          "state" => Atom.to_string(worker.state),
          "status" => Atom.to_string(status),
          "worker_id" => worker.id
        }

        report(settings, result)
        {:ok, result}
      end
    end)
  end

  @doc """
  Replays one retained Slack message privately, as a Slack operator, and
  prints the result as JSON. The replay runs the normal admission and Work
  path with every visible Slack effect forbidden; repeating `action_ref`
  returns the first result. `scripts/compose.sh replay` runs this inside the
  container, where there is no Mix to run `mix ryker.replay` with.
  """
  @spec replay(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def replay(source_input_ref, request_ref, operator, action_ref, options \\ []) do
    settings = settings!(options)

    with_repo!(settings, fn _repo ->
      with_settings_pubsub(fn ->
        enqueue_replay(settings, source_input_ref, request_ref, operator, action_ref)
      end)
    end)
  end

  defp enqueue_replay(settings, source_input_ref, request_ref, operator, action_ref) do
    with {:ok, actor_ref} <- Operator.Actions.operator_actor(operator),
         {:ok, replay} <-
           Operator.SlackReplay.enqueue(source_input_ref, request_ref,
             action_ref: action_ref,
             actor_ref: actor_ref
           ) do
      report(settings, replay)
      {:ok, replay}
    end
  end

  @doc """
  Where a private replay is, and what Ryker would have done, as JSON.
  `scripts/compose.sh replay-show` runs this inside the container.
  """
  @spec replay_status(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def replay_status(replay_input_ref, options \\ []) do
    settings = settings!(options)

    with_repo!(settings, fn _repo ->
      with {:ok, replay} <- Operator.SlackReplay.fetch(replay_input_ref) do
        report(settings, replay)
        {:ok, replay}
      end
    end)
  end

  @doc """
  Runs every read-only preflight check against the saved settings and prints
  the report as JSON: whether the settings were applied and the durable queues
  are ready. `scripts/compose.sh doctor` runs this inside the container.
  """
  @spec doctor(keyword()) :: {:ok, map()} | {:error, term()}
  def doctor(options \\ []) do
    settings = settings!(options)

    with_repo!(settings, fn _repo ->
      with {:ok, stored} <- Settings.fetch(),
           {:ok, configuration} <- Runtime.Assembly.build(Bootstrap.load!(), stored) do
        configuration |> preflight() |> tap(&report_preflight(settings, &1))
      end
    end)
  end

  defp preflight(configuration) do
    Operator.Preflight.run(
      configuration: configuration,
      check_progress: false,
      check_runtimes: false
    )
  end

  defp report_preflight(settings, {_status, report}) when is_map(report),
    do: report(settings, report)

  defp report_preflight(_settings, _result), do: :ok

  defp report(%{log: false}, _value), do: :ok
  defp report(_settings, value), do: IO.puts(Jason.encode!(value))

  defp with_repo!(settings, function) do
    load_app!()

    case Ecto.Migrator.with_repo(
           settings.repo,
           function,
           pool_size: settings.pool_size
         ) do
      {:ok, result, _started_apps} -> result
      {:error, reason} -> raise "could not start migration repository: #{inspect(reason)}"
    end
  end

  # Release `eval` deliberately starts only the repository. Distribution
  # bootstrap writes settings and therefore needs the event bus long enough to
  # complete the same transaction path used by the running application.
  defp with_settings_pubsub(function) do
    case Process.whereis(Ryker.PubSub.Server) do
      nil ->
        {:ok, _started} = Application.ensure_all_started(:phoenix_pubsub)
        {:ok, pubsub} = Supervisor.start_link([Ryker.PubSub], strategy: :one_for_one)

        try do
          function.()
        after
          Supervisor.stop(pubsub)
        end

      _running ->
        function.()
    end
  end

  defp settings!(options) when is_list(options) do
    validate_option_keys!(options)

    repo = Keyword.get(options, :repo, Ryker.Repo)
    prefix = Keyword.get(options, :prefix)
    pool_size = Keyword.get(options, :pool_size, 2)
    log = Keyword.get(options, :log, :info)
    validate_runtime_options!(repo, prefix, pool_size, log)

    migrations_path =
      Keyword.get_lazy(options, :migrations_path, fn ->
        Application.app_dir(@app, "priv/repo/migrations")
      end)

    validate_migrations_path!(migrations_path)

    %{
      log: log,
      migrations_path: migrations_path,
      pool_size: pool_size,
      prefix: prefix,
      repo: repo
    }
  end

  defp settings!(_options),
    do: raise(ArgumentError, "release migration options must be a keyword")

  defp validate_option_keys!(options) do
    valid? =
      Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
        Keyword.keys(options) -- @fields == []

    unless valid?,
      do: raise(ArgumentError, "release migration options must use unique known keys")
  end

  defp validate_runtime_options!(repo, prefix, pool_size, log) do
    valid? =
      is_atom(repo) and (is_nil(prefix) or valid_prefix?(prefix)) and
        is_integer(pool_size) and pool_size >= 2 and valid_log?(log)

    unless valid?, do: raise(ArgumentError, "release migration options are invalid")
  end

  defp validate_migrations_path!(path) do
    unless is_binary(path) and Path.type(path) == :absolute,
      do: raise(ArgumentError, "release migrations path must be absolute")
  end

  defp valid_log?(value),
    do: is_boolean(value) or value in [:debug, :info, :notice, :warning, :error]

  defp migrator_options(settings, strategy \\ []) do
    [log: settings.log]
    |> put_optional(:prefix, settings.prefix)
    |> Keyword.merge(strategy)
  end

  defp put_optional(options, _key, nil), do: options
  defp put_optional(options, key, value), do: Keyword.put(options, key, value)

  defp valid_prefix?(value) do
    is_binary(value) and Regex.match?(~r/\A[a-z_][a-z0-9_]{0,62}\z/, value)
  end

  defp load_app! do
    case Application.load(@app) do
      :ok -> :ok
      {:error, {:already_loaded, @app}} -> :ok
      {:error, reason} -> raise "could not load #{@app}: #{inspect(reason)}"
    end
  end
end
