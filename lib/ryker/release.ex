defmodule Ryker.Release do
  @moduledoc """
  What the assembled release runs through its `eval` command: migrating the
  database as the container starts, preparing the bundled worker, and the
  operator commands `scripts/compose.sh` runs inside the container.

  There is no rollback: going back is restoring the backup taken before the
  release (`docs/operations.md`, "The schema baseline").
  """
  alias Ryker.{Bootstrap, Maps, Settings}
  alias Ryker.CoopFleet
  alias Ryker.Operator
  alias Ryker.Runtime

  @app :ryker
  @fields [:log, :migrations_path, :pool_size, :prefix, :repo]

  @doc """
  Runs every pending migration, after refusing a database a newer release has
  migrated (`newer_than_release/1`), and answers the versions it ran.
  """
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
      with_pubsub(fn -> Ryker.BundledCoop.prepare_distribution!() end)
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
    settings = settings!(Keyword.drop(options, [:stop_admission]))

    with_repo!(settings, fn _repo ->
      with {:ok, issued} <-
             CoopFleet.Enrollment.issue_token(
               worker_id,
               workspace_ref,
               operator_ref,
               900,
               Keyword.take(options, [:stop_admission])
             ) do
        report(settings, issued)
        {:ok, issued}
      end
    end)
  end

  @doc "Read configured controller model access without returning or refreshing credentials."
  def model_account_statuses(workspace_ref, options \\ []) do
    with_repo!(settings!(options), fn _repo -> CoopFleet.model_account_statuses(workspace_ref) end)
  end

  @doc "Read controller-wide inference capacity for one configured model account."
  def model_capacity(reference, options \\ []) do
    with_repo!(settings!(options), fn _repo -> CoopFleet.model_capacity(reference) end)
  end

  @doc "Set provider request concurrency for an account and its aliases."
  def set_model_concurrency(reference, count, actor, options \\ []) do
    with_repo!(settings!(options), fn _repo ->
      CoopFleet.set_model_concurrency(reference, count, actor)
    end)
  end

  @doc "List inference holds without provider credentials."
  def held_model_requests(options \\ []) do
    with_repo!(settings!(options), fn _repo -> CoopFleet.held_model_requests() end)
  end

  @doc "Confirm a prior controller has stopped before releasing one of its inference holds."
  def confirm_model_controller_stopped(id, boot, actor, options \\ []) do
    with_repo!(settings!(options), fn _repo ->
      CoopFleet.confirm_model_controller_stopped(id, boot, actor)
    end)
  end

  @doc """
  Drains a worker (no new work; what it holds finishes), resumes one, or
  revokes one at once with its certificates and unused enrolment tokens, and
  prints the result as JSON. `scripts/compose.sh worker-drain`,
  `worker-resume` and `worker-revoke` run this inside the container, where
  there is no Mix to run `mix ryker.coop_worker` with.

  `:stop_admission` holds only new assignments while existing workflows continue;
  `:start_admission` reopens assignments without clearing a separate drain.
  """
  @spec worker_lifecycle(
          :stop_admission | :start_admission | :drain | :resume | :revoke,
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def worker_lifecycle(action, worker_id, operator_ref, options \\ [])
      when action in [:stop_admission, :start_admission, :drain, :resume, :revoke] do
    settings = settings!(options)

    with_repo!(settings, fn _repo ->
      changed =
        case action do
          :stop_admission -> CoopFleet.WorkerLifecycle.stop_admission(worker_id, operator_ref)
          :start_admission -> CoopFleet.WorkerLifecycle.start_admission(worker_id, operator_ref)
          :drain -> CoopFleet.WorkerLifecycle.drain(worker_id, operator_ref)
          :resume -> CoopFleet.WorkerLifecycle.resume(worker_id, operator_ref)
          :revoke -> CoopFleet.WorkerLifecycle.revoke(worker_id, operator_ref)
        end

      with {:ok, %{status: status, worker: worker}} <- changed do
        result = %{
          "state" => Atom.to_string(worker.state),
          "status" => Atom.to_string(status),
          "worker_id" => worker.id,
          "admission_stopped_at" => worker.admission_stopped_at,
          "admission_stopped_by" => worker.admission_stopped_by,
          "drain_requested_at" => worker.drain_requested_at,
          "drain_requested_by" => worker.drain_requested_by
        }

        report(settings, result)
        {:ok, result}
      end
    end)
  end

  @doc "Resume only the drain acquired by this worker upgrade, identified by operator and timestamp."
  @spec resume_worker_upgrade(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resume_worker_upgrade(worker_id, operator_ref, requested_at, options \\ []) do
    settings = settings!(options)

    with {:ok, timestamp, 0} <- DateTime.from_iso8601(requested_at) do
      with_repo!(settings, fn _repo ->
        CoopFleet.WorkerLifecycle.resume_if_drained_by(worker_id, operator_ref, timestamp)
      end)
    end
  end

  @doc "Activate a qualified worker only while the exact bootstrap admission hold remains."
  @spec resume_worker_admission(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resume_worker_admission(worker_id, operator_ref, stopped_at, options \\ []) do
    settings = settings!(options)

    with {:ok, timestamp, 0} <- DateTime.from_iso8601(stopped_at) do
      with_repo!(settings, fn _repo ->
        CoopFleet.WorkerLifecycle.start_admission_if_stopped_by(
          worker_id,
          operator_ref,
          timestamp
        )
      end)
    end
  end

  @doc "Submit a local job using the selected environment's reviewed contributor policy."
  def fleet_submit(id, placement, prompt, options \\ []) do
    settings = settings!(options)

    with_repo!(settings, fn _repo ->
      with_pubsub(fn ->
        Operator.FleetJobs.submit(id, placement, prompt, &fleet_policy/2)
      end)
    end)
  end

  @doc "Submit local source and its prompt from the operator command's single binary input stream."
  def fleet_submit_local(id, placement, prompt_size, reference) when prompt_size in 1..12_000 do
    # Reading the file descriptor in binary mode keeps arbitrary Git objects and
    # the UTF-8 prompt on the same pipe without terminal encoding or lookahead.
    File.open!("/dev/stdin", [:read, :binary], fn file ->
      case :file.read(file, prompt_size) do
        {:ok, prompt} when byte_size(prompt) == prompt_size ->
          submit_local_stream(id, placement, prompt, reference, IO.binstream(file, 262_144))

        _incomplete ->
          {:error, :invalid_fleet_prompt}
      end
    end)
  end

  def fleet_submit_local(_id, _placement, _size, _reference), do: {:error, :invalid_fleet_prompt}

  defp submit_local_stream(id, placement, prompt, reference, chunks) do
    submit = fn job, placed ->
      with_pubsub(fn -> Operator.FleetJobs.submit(job, placed, prompt, &fleet_policy/2) end)
    end

    with_repo!(settings!([]), fn _repo ->
      Operator.WorkspaceInputs.submit(
        id,
        placement,
        reference,
        chunks,
        fleet_body_options(),
        submit
      )
    end)
  end

  defp fleet_body_options do
    [
      body_root: Path.join(Bootstrap.storage_root!(), "worker-bodies"),
      checkpoint_key: Ryker.Secret.new(Bootstrap.checkpoint_key!())
    ]
  end

  defp fleet_policy(environment, repository) do
    with {:ok, stored} <- Settings.fetch(),
         {:ok, configuration} <- Runtime.Assembly.build(Bootstrap.load!(), stored),
         %{} <- Map.get(configuration, :work),
         %{} = policy <-
           get_in(configuration, [:control_plane, :task_policies, environment, repository]) do
      {:ok, policy}
    else
      _unavailable -> {:error, :fleet_job_policy_unavailable}
    end
  end

  @doc "Read one operator job, or list recent submissions when id is nil."
  def fleet_status(id, options \\ []) do
    with_repo!(settings!(options), fn _repo ->
      if id, do: Operator.FleetJobs.fetch(id), else: Operator.FleetJobs.list()
    end)
  end

  @doc "Read a counted page of operator jobs, workers or one job's retained events."
  def fleet_page(kind, id, raw_page) do
    case Integer.parse(raw_page) do
      {page, ""} when page in 1..2_147_483_647 ->
        with_repo!(settings!([]), fn _repo -> read_fleet_page(kind, id, page) end)

      _invalid ->
        {:error, :invalid_fleet_page}
    end
  end

  defp read_fleet_page(:events, id, page), do: Operator.FleetJobs.events(id, page)
  defp read_fleet_page(:workers, _id, page), do: Operator.FleetJobs.workers(page)
  defp read_fleet_page(:jobs, _id, page), do: Operator.FleetJobs.list(page)

  @doc "Inspect the Compose services of the job's current authenticated placement."
  def fleet_services(id) do
    with_repo!(settings!([]), fn _repo ->
      with_pubsub(fn -> Operator.FleetJobs.services(id, fleet_body_options()) end)
    end)
  end

  @doc "Read one page of a job-owned Compose container's log records."
  def fleet_service_logs(id, service, container, cursor) do
    with_repo!(settings!([]), fn _repo ->
      with_pubsub(fn ->
        Operator.FleetJobs.service_logs(id, service, container, cursor, fleet_body_options())
      end)
    end)
  end

  @doc "Write a temporary operator preview grant to the release caller's private directory."
  def fleet_forward(id, service, port) do
    with_repo!(settings!([]), fn _repo ->
      with_pubsub(fn -> issue_fleet_preview(id, service, port) end)
    end)
  end

  defp issue_fleet_preview(id, service, port) do
    with {number, ""} <- Integer.parse(port),
         {:ok, grant} <-
           Ryker.CoopFleet.ServiceRelays.issue(id, service, number, fleet_body_options()),
         %{ca_pem: ca, controller_url: url} <- CoopFleet.worker_connection(),
         %URI{scheme: "https", host: server} when is_binary(server) <- URI.parse(url) do
      File.write!(
        "preview.json",
        Jason.encode!(Map.merge(grant, %{ca_pem: ca, server_name: server})),
        [:exclusive]
      )

      {:ok, %{issued: true}}
    else
      _refused -> {:error, :fleet_service_unavailable}
    end
  end

  @doc "Stream the authenticated workspace checkpoint through the local operator command's private FIFO."
  def fleet_export(id) do
    with_repo!(settings!([]), fn _repo ->
      Operator.FleetJobs.export(id, fleet_body_options(), &write_fleet_checkpoint/2)
    end)
  end

  defp write_fleet_checkpoint(descriptor, chunks) do
    # The operator command creates this FIFO in a fresh 0700 directory. A failed
    # invocation must never truncate a regular file or follow a symlink here.
    %{mode: mode} = File.lstat!("workspace.pipe")
    if Bitwise.band(mode, 0o170000) != 0o010000, do: raise("expected a checkpoint output pipe")

    File.open!("workspace.pipe", [:write, :binary, :raw], fn file ->
      :ok = :file.write(file, [Jason.encode!(descriptor), "\n"])
      Enum.each(chunks, fn chunk -> :ok = :file.write(file, chunk) end)
    end)

    {:ok, %{checkpoint_ref: descriptor["checkpoint_ref"]}}
  end

  @doc "Cancel this job using its current Work owner and return the cancellation receipt."
  def fleet_cancel(id, options \\ []) do
    with_repo!(settings!(options), fn _repo ->
      with_pubsub(fn -> Operator.FleetJobs.cancel(id) end)
    end)
  end

  @doc false
  def print_fleet_result({:ok, result}), do: IO.puts(Jason.encode!(result))

  def print_fleet_result({:error, reason}) do
    code = if is_atom(reason), do: reason, else: :fleet_job_refused
    IO.puts(:stderr, Jason.encode!(%{error: code}))
    System.halt(1)
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
      with_pubsub(fn ->
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

  @doc """
  Prints a link that signs the host's owner in to the console once, within the hour, and then
  opens `:return_to`, a page of the console (`Ryker.ConsoleAccess.owner_link/1`). Whoever can
  run this on the host can already read everything Ryker keeps, so the link grants nothing new.
  `scripts/compose.sh sign-in` runs it inside the container, and the install prints one for setup.
  """
  @spec sign_in_link(keyword()) :: :ok
  def sign_in_link(options \\ []) do
    settings = settings!(Keyword.delete(options, :return_to))

    with_repo!(settings, fn _repo ->
      {:ok, url} = Ryker.ConsoleAccess.owner_link(Keyword.get(options, :return_to))
      IO.puts(url)
    end)

    :ok
  end

  @doc "Runs one flywheel JSON request from stdin against this installation; prints JSON or exits unsuccessfully."
  @spec flywheel(keyword()) :: :ok
  def flywheel(options \\ []) do
    settings = settings!(options)

    result =
      with_repo!(settings, fn _repo ->
        with bytes when is_binary(bytes) <- IO.read(:stdio, 8_000_001),
             {:ok, request} <- Jason.decode(bytes) do
          Ryker.Flywheel.execute(request)
        else
          _invalid -> {:error, :invalid_flywheel_json}
        end
      end)

    case result do
      {:ok, document} -> report(settings, document)
      {:error, reason} -> raise "flywheel failed: #{inspect(reason)}"
    end

    :ok
  end

  @doc """
  Performs one audited quarantine recovery request or reconciles its receipt.
  Local host operators call this through the release with
  `{:request, attributes}` or `{:settle, action_ref}`. This does not delete a
  working copy or resume its episode. The request names the exact worker
  revision, placement generation, actor and action.
  """
  @spec quarantine({:request, map()} | {:settle, String.t()}, keyword()) ::
          {:ok, term()} | {:error, term()}
  def quarantine(operation, options \\ []) do
    settings = settings!(options)

    with_repo!(settings, fn _repo ->
      with_pubsub(fn -> quarantine_operation(operation) end)
    end)
  end

  defp quarantine_operation({:request, attributes}), do: Operator.Quarantine.request(attributes)
  defp quarantine_operation({:settle, action_ref}), do: Operator.Quarantine.settle(action_ref)
  defp quarantine_operation(_invalid), do: {:error, :invalid_quarantine_recovery}

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

  # Release `eval` deliberately starts only the repository. Operator writes
  # also need the event bus until their committed announcements have run,
  # without starting a second application runtime.
  defp with_pubsub(function) do
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
    |> Maps.put_present(:prefix, settings.prefix)
    |> Keyword.merge(strategy)
  end

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
