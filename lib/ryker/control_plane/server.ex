defmodule Ryker.ControlPlane.Server do
  @moduledoc """
  Local control plane. Host-native deployments are loopback-only; the Compose
  deployment listens on its private container interface and publishes only to
  the host loopback address.

  Loopback reach is the v1 operator identity. Mutations still require a native
  two-step confirmation with a process-local CSRF token, and the listener
  refuses public bind addresses.
  """

  alias Ryker.ControlPlane.{Actions, Endpoint, Projection}
  alias Ryker.Ingress.WorkProfile
  alias Ryker.Observability
  alias Ryker.Schedules.ScheduleRuntime
  alias Ryker.Work.RepositoryContext

  @loopback_v4 {127, 0, 0, 1}
  @loopback_v6 {0, 0, 0, 0, 0, 0, 0, 1}
  @fields [
    :access,
    :cloudflare_access,
    :coop_api,
    :coop_client,
    :csrf_secret,
    :environments,
    :fallback_work_profile,
    :ip,
    :port,
    :public_url,
    :schedule_policies,
    :task_policies
  ]

  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(configuration) do
    options = options!(configuration)
    :ok = Actions.put_current(actions(options))

    Endpoint.child_spec(
      server: true,
      http: [ip: options.ip, port: options.port],
      url: [host: "localhost", port: options.port],
      check_origin: origins(options.port, options.public_url),
      secret_key_base: Base.encode64(:crypto.hash(:sha512, options.csrf_secret)),
      control_plane: %{
        access: options.access,
        cloudflare_access: options.cloudflare_access,
        public_host: public_host(options.public_url),
        actions: Actions.live(),
        csrf_secret: options.csrf_secret,
        observability: Observability.callbacks(),
        projection: Projection.callbacks()
      }
    )
    |> Map.put(:id, __MODULE__)
  end

  @doc """
  Takes a changed configuration into the running console when its listener stays the same: its
  actions call the new one from now on and open pages stay connected. A new listener needs a new
  console.
  """
  @spec reconfigure(keyword() | map(), keyword() | map()) :: :ok | :restart
  def reconfigure(previous, configuration) do
    if listener(previous) == listener(configuration),
      do: configuration |> options!() |> actions() |> Actions.put_current(),
      else: :restart
  end

  defp listener(configuration),
    do:
      configuration
      |> normalize!()
      |> Map.take([:access, :cloudflare_access, :csrf_secret, :ip, :port, :public_url])

  defp actions(options) do
    Actions.callbacks(
      options.chat,
      options.task_policies,
      %{coop_api: options.coop_api, coop_client: options.coop_client},
      options.schedule_policy_resolver
    )
  end

  @doc false
  @spec options!(keyword() | map()) :: map()
  def options!(configuration) do
    configuration = normalize!(configuration)
    port = Map.fetch!(configuration, :port)
    ip = Map.get(configuration, :ip, @loopback_v4)
    access = Map.get(configuration, :access, :loopback)

    csrf_secret =
      Map.get_lazy(configuration, :csrf_secret, fn -> :crypto.strong_rand_bytes(32) end)

    task_policies = Map.get(configuration, :task_policies, %{})

    schedule_policy_resolver =
      schedule_policy_resolver(Map.get(configuration, :schedule_policies))

    coop_api = Map.get(configuration, :coop_api)
    coop_client = Map.get(configuration, :coop_client)
    public_url = Map.get(configuration, :public_url)
    cloudflare_access = Map.get(configuration, :cloudflare_access)

    validate_listener!(access, ip, port)
    validate_public_url!(public_url)
    validate_cloudflare_access!(cloudflare_access)
    validate_csrf_secret!(csrf_secret)

    # A fresh installation has no reviewed policy yet. The console still starts
    # so setup is reachable; it simply cannot submit Work until one exists.
    chat = %{
      environments: chat_environments!(Map.get(configuration, :environments, %{})),
      fallback_work_profile: work_profile!(Map.get(configuration, :fallback_work_profile))
    }

    task_policies = task_policies!(task_policies)
    validate_coop!(coop_api, coop_client)

    %{
      access: access,
      chat: chat,
      cloudflare_access: cloudflare_access,
      coop_api: coop_api,
      coop_client: coop_client,
      csrf_secret: csrf_secret,
      ip: ip,
      port: port,
      public_url: public_url,
      schedule_policy_resolver: schedule_policy_resolver,
      task_policies: task_policies
    }
  end

  # Each Chat conversation runs in the environment it chose, when that
  # environment can run work, so the console keeps every such environment's
  # Work profile by ref, each placed in its own environment.
  defp chat_environments!(environments) when is_map(environments) do
    Map.new(environments, fn
      {ref, %{work_profile: attributes}} when is_binary(ref) ->
        case work_profile!(attributes) do
          %WorkProfile{environment_ref: ^ref} = profile -> {ref, profile}
          _elsewhere -> raise ArgumentError, "control-plane environments are invalid"
        end

      _invalid ->
        raise ArgumentError, "control-plane environments are invalid"
    end)
  end

  defp chat_environments!(_environments),
    do: raise(ArgumentError, "control-plane environments are invalid")

  defp work_profile!(attributes) do
    case WorkProfile.prepare(attributes) do
      {:ok, profile} -> profile
      {:error, _reason} -> raise ArgumentError, "control-plane work profile is invalid"
    end
  end

  defp validate_listener!(access, ip, port) do
    unless is_integer(port) and port in 1..65_535,
      do: raise(ArgumentError, "control-plane port must be between 1 and 65535")

    unless access in [:loopback, :network],
      do: raise(ArgumentError, "control-plane access must be loopback or network")

    if access == :loopback and ip not in [@loopback_v4, @loopback_v6],
      do: raise(ArgumentError, "control-plane IP must be loopback")
  end

  defp validate_cloudflare_access!(nil), do: :ok

  defp validate_cloudflare_access!(%{team_domain: team, audience: audience} = access)
       when map_size(access) == 2 and is_binary(team) and is_binary(audience),
       do: :ok

  defp validate_cloudflare_access!(_access),
    do: raise(ArgumentError, "control-plane Cloudflare Access is its team domain and audience")

  defp validate_public_url!(nil), do: :ok

  defp validate_public_url!(url) do
    unless is_binary(url) and
             match?(
               %URI{scheme: scheme, host: host}
               when scheme in ["http", "https"] and is_binary(host) and host != "",
               URI.parse(url)
             ),
           do: raise(ArgumentError, "control-plane public URL must be an HTTP or HTTPS address")
  end

  # A browser sends the address it opened as its origin. The console listens on its own port,
  # and Compose publishes it on RYKER_CONTROL_PORT; a setup page reached at the published port
  # rendered and never went live (mac-server, 2026-10-01). A loopback address is the console
  # under each loopback name, any other is accepted only as itself.
  defp origins(port, public_url) do
    published =
      case public_url && URI.parse(public_url) do
        %URI{host: host, port: published_port}
        when host in ["localhost", "127.0.0.1", "[::1]", "::1"] ->
          loopback_origins(published_port)

        %URI{host: host, port: published_port} when is_binary(host) ->
          ["//#{host}:#{published_port}"]

        nil ->
          []
      end

    Enum.uniq(loopback_origins(port) ++ published)
  end

  defp public_host(nil), do: nil
  defp public_host(url), do: URI.parse(url).host

  defp loopback_origins(port),
    do: ["//localhost:#{port}", "//127.0.0.1:#{port}", "//[::1]:#{port}"]

  defp validate_csrf_secret!(secret) do
    unless is_binary(secret) and byte_size(secret) == 32,
      do: raise(ArgumentError, "control-plane CSRF secret must be 32 bytes")
  end

  defp normalize!(configuration) when is_list(configuration) do
    if Keyword.keyword?(configuration) and
         Enum.uniq(Keyword.keys(configuration)) == Keyword.keys(configuration) do
      normalize!(Map.new(configuration))
    else
      raise ArgumentError, "control-plane configuration must use unique fields"
    end
  end

  defp normalize!(%{} = configuration) do
    keys = Map.keys(configuration)

    if :port in keys and keys -- @fields == [],
      do: configuration,
      else:
        raise(
          ArgumentError,
          "control-plane configuration must contain a port plus optional work profiles, IP and CSRF secret"
        )
  end

  defp normalize!(_configuration),
    do: raise(ArgumentError, "control-plane configuration must be a map or keyword list")

  # Contributor policies keyed by environment, then by the repository each
  # places its task in: a task changes the repository it names, as that
  # repository's working copy, with the context mounted for it.
  defp task_policies!(policies) when is_map(policies) do
    Map.new(policies, fn
      {environment_ref, repositories} when is_binary(environment_ref) and is_map(repositories) ->
        {environment_ref,
         Map.new(repositories, fn {repository_ref, policy} ->
           {repository_ref, task_policy!(policy, environment_ref, repository_ref)}
         end)}

      _invalid ->
        raise ArgumentError, "control-plane task policies are invalid"
    end)
  end

  defp task_policies!(_policies),
    do: raise(ArgumentError, "control-plane task policies are invalid")

  defp task_policy!(
         %{
           name: name,
           digest: digest,
           environment_ref: environment_ref,
           repository_ref: repository_ref
         } = policy,
         environment_ref,
         repository_ref
       )
       when is_binary(repository_ref) do
    repository_context = Map.get(policy, :repository_context)

    with {:ok, _profile} <-
           WorkProfile.new(%{policy: name, policy_digest: digest, repository_ref: repository_ref}),
         {:ok, _context} <- RepositoryContext.restore(repository_context, repository_ref) do
      %{
        name: name,
        digest: digest,
        environment_ref: environment_ref,
        repository_ref: repository_ref
      }
      |> maybe_put(:repository_context, repository_context)
    else
      _invalid -> raise ArgumentError, "control-plane task policies are invalid"
    end
  end

  defp task_policy!(_policy, _environment_ref, _repository_ref),
    do: raise(ArgumentError, "control-plane task policies are invalid")

  defp schedule_policy_resolver(nil), do: nil

  defp schedule_policy_resolver(configuration) do
    configuration
    |> ScheduleRuntime.options!()
    |> Map.fetch!(:dispatcher_options)
    |> Keyword.fetch!(:policy_resolver)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp validate_coop!(nil, nil), do: :ok

  defp validate_coop!(api, client) when is_atom(api) and not is_nil(client) do
    unless Code.ensure_loaded?(api) and function_exported?(api, :get_changes_page, 4),
      do: raise(ArgumentError, "control-plane Coop client is invalid")
  end

  defp validate_coop!(_api, _client),
    do: raise(ArgumentError, "control-plane Coop API and client must be configured together")
end
