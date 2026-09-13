defmodule Ryker.ControlPlane.Server do
  @moduledoc """
  Optional loopback-only local control plane.

  Loopback reach is the v1 operator identity. Mutations still require a native
  two-step confirmation with a process-local CSRF token, and the listener
  refuses public bind addresses.
  """

  alias Ryker.ControlPlane.{Actions, Endpoint, Projection}
  alias Ryker.Ingress.WorkProfile
  alias Ryker.Observability
  alias Ryker.State.ScheduleRuntime

  @loopback_v4 {127, 0, 0, 1}
  @loopback_v6 {0, 0, 0, 0, 0, 0, 0, 1}
  @fields [
    :coop_api,
    :coop_client,
    :csrf_secret,
    :ip,
    :port,
    :schedule_policies,
    :task_policies,
    :work_profile
  ]

  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(configuration) do
    options = options!(configuration)

    Endpoint.child_spec(
      server: true,
      http: [ip: options.ip, port: options.port],
      url: [host: "localhost", port: options.port],
      check_origin: [
        "//localhost:#{options.port}",
        "//127.0.0.1:#{options.port}",
        "//[::1]:#{options.port}"
      ],
      secret_key_base: Base.encode64(:crypto.hash(:sha512, options.csrf_secret)),
      control_plane: %{
        actions:
          Actions.callbacks(
            options.work_profile,
            options.task_policies,
            %{
              coop_api: options.coop_api,
              coop_client: options.coop_client
            },
            options.schedule_policy_resolver
          ),
        csrf_secret: options.csrf_secret,
        observability: Observability.callbacks(),
        projection: Projection.callbacks()
      }
    )
    |> Map.put(:id, __MODULE__)
  end

  @doc false
  @spec options!(keyword() | map()) :: map()
  def options!(configuration) do
    configuration = normalize!(configuration)
    port = Map.fetch!(configuration, :port)
    ip = Map.get(configuration, :ip, @loopback_v4)

    csrf_secret =
      Map.get_lazy(configuration, :csrf_secret, fn -> :crypto.strong_rand_bytes(32) end)

    work_profile = Map.get(configuration, :work_profile)
    task_policies = Map.get(configuration, :task_policies, %{})

    schedule_policy_resolver =
      schedule_policy_resolver(Map.get(configuration, :schedule_policies))

    coop_api = Map.get(configuration, :coop_api)
    coop_client = Map.get(configuration, :coop_client)

    unless is_integer(port) and port in 1..65_535,
      do: raise(ArgumentError, "control-plane port must be between 1 and 65535")

    unless ip in [@loopback_v4, @loopback_v6],
      do: raise(ArgumentError, "control-plane IP must be loopback")

    unless is_binary(csrf_secret) and byte_size(csrf_secret) == 32,
      do: raise(ArgumentError, "control-plane CSRF secret must be 32 bytes")

    # A fresh installation has no reviewed policy yet. The console still starts
    # so setup is reachable; it simply cannot submit Work until one exists.
    work_profile =
      case WorkProfile.prepare(work_profile) do
        {:ok, %WorkProfile{} = profile} -> profile
        {:ok, nil} -> nil
        _invalid -> raise ArgumentError, "control-plane work profile is invalid"
      end

    task_policies = task_policies!(task_policies)
    validate_coop!(coop_api, coop_client)

    %{
      coop_api: coop_api,
      coop_client: coop_client,
      csrf_secret: csrf_secret,
      ip: ip,
      port: port,
      schedule_policy_resolver: schedule_policy_resolver,
      task_policies: task_policies,
      work_profile: work_profile
    }
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
          "control-plane configuration must contain a port plus optional work profile, IP and CSRF secret"
        )
  end

  defp normalize!(_configuration),
    do: raise(ArgumentError, "control-plane configuration must be a map or keyword list")

  defp task_policies!(policies) when is_map(policies) do
    Map.new(policies, fn
      {context_ref, %{name: name, digest: digest} = policy} ->
        repository_ref = Map.get(policy, :repository_ref, context_ref)
        repository_context = Map.get(policy, :repository_context)

        case WorkProfile.new(%{
               policy: name,
               policy_digest: digest,
               repository_context: restore_repository_context(repository_context),
               repository_ref: repository_ref
             }) do
          {:ok, _profile} ->
            prepared =
              %{name: name, digest: digest}
              |> maybe_put(:repository_ref, Map.get(policy, :repository_ref))
              |> maybe_put(:repository_context, repository_context)

            {context_ref, prepared}

          _invalid ->
            raise ArgumentError, "control-plane task policies are invalid"
        end

      _invalid ->
        raise ArgumentError, "control-plane task policies are invalid"
    end)
  end

  defp task_policies!(_policies),
    do: raise(ArgumentError, "control-plane task policies are invalid")

  defp schedule_policy_resolver(nil), do: nil

  defp schedule_policy_resolver(configuration) do
    configuration
    |> ScheduleRuntime.options!()
    |> Map.fetch!(:dispatcher_options)
    |> Keyword.fetch!(:policy_resolver)
  end

  defp restore_repository_context(nil), do: nil

  defp restore_repository_context(context) when is_map(context) do
    %{
      context_ref: context["context_ref"],
      parallel_goal_limit: context["parallel_goal_limit"],
      primary_repository: context["primary_repository"],
      read_only_repositories: context["read_only_repositories"]
    }
  end

  defp restore_repository_context(value), do: value

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
