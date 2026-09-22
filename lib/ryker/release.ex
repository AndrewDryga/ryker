defmodule Ryker.Release do
  @moduledoc """
  Release-safe database migration entry points.

  Invoke these through the assembled release's `eval` command. Rollback is
  deliberately guarded by the exact latest version the operator reviewed; it
  never interprets a stale version as permission to remove several migrations.
  """

  @app :ryker
  @fields [:log, :migrations_path, :pool_size, :prefix, :repo]

  @spec migrate(keyword()) :: [integer()]
  def migrate(options \\ []) do
    settings = settings!(options)

    with_repo!(settings, fn repo ->
      Ecto.Migrator.run(
        repo,
        settings.migrations_path,
        :up,
        migrator_options(settings, all: true)
      )
    end)
  end

  @spec rollback(pos_integer(), keyword()) :: [integer()]
  def rollback(expected_version, options \\ [])

  def rollback(expected_version, options)
      when is_integer(expected_version) and expected_version > 0 do
    settings = settings!(options)

    with_repo!(settings, fn repo ->
      latest = latest_applied(repo, settings)

      if latest != expected_version do
        raise ArgumentError,
              "latest applied migration #{inspect(latest)} does not match expected #{expected_version}"
      end

      Ecto.Migrator.run(
        repo,
        settings.migrations_path,
        :down,
        migrator_options(settings, step: 1)
      )
    end)
  end

  def rollback(_expected_version, _options) do
    raise ArgumentError, "rollback version must be a positive integer"
  end

  @spec migrations(keyword()) :: [{:up | :down, integer(), String.t()}]
  def migrations(options \\ []) do
    settings = settings!(options)

    with_repo!(settings, fn repo ->
      Ecto.Migrator.migrations(
        repo,
        [settings.migrations_path],
        migrator_options(settings)
      )
    end)
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

  defp latest_applied(repo, settings) do
    repo
    |> Ecto.Migrator.migrations(
      [settings.migrations_path],
      migrator_options(settings)
    )
    |> Enum.flat_map(fn
      {:up, version, _name} -> [version]
      {:down, _version, _name} -> []
    end)
    |> Enum.max(fn -> nil end)
  end

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
    case Process.whereis(Ryker.ControlPlane.PubSub) do
      nil ->
        {:ok, _started} = Application.ensure_all_started(:phoenix_pubsub)

        {:ok, pubsub} =
          Supervisor.start_link(
            [{Phoenix.PubSub, name: Ryker.ControlPlane.PubSub}],
            strategy: :one_for_one
          )

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
