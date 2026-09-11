defmodule Responder.RuntimeConfiguration do
  @moduledoc """
  Strict host configuration for the Elixir product runtime.

  YAML keys remain strings while decoding and are mapped only to a fixed set of
  application keys. Platform tokens stay behind callbacks and are read for
  each outbound request; webhook verification and local MCP secrets are read
  once into the owning trusted adapter at startup.
  """

  alias Responder.ControlPlane.CapabilityTools, as: ControlPlaneCapabilityTools
  alias Responder.ControlPlane.ConversationLab
  alias Responder.ControlPlane.Server, as: ControlPlaneServer
  alias Responder.Delivery.{JSONClient, Request}
  alias Responder.Emisar.ApprovalRuntime

  alias Responder.GitHub.{
    AppJWT,
    Binding,
    Client,
    Confirmations,
    InstallationTokens,
    Publisher,
    Runtime,
    Target
  }

  alias Responder.GitHub.CapabilityTools, as: GitHubCapabilityTools

  alias Responder.Ingress.WorkProfile
  alias Responder.Publication.{Git, GitCommand, GitHubPublisher}
  alias Responder.Slack.ActionTokens
  alias Responder.Slack.CapabilityTools, as: SlackCapabilityTools
  alias Responder.Slack.Client, as: SlackClient
  alias Responder.Slack.Target, as: SlackTarget
  alias Responder.State.ScheduleRuntime

  @configuration_env "RESPONDER_ELIXIR_CONFIG"
  @coop_repository_name ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/
  @maximum_bytes 512 * 1_024
  @managed_application_keys [
    :admission,
    :learning,
    :control_plane,
    :fleet_profiles,
    :coop_worker_gateway,
    :delivery,
    :emisar,
    :event_waits,
    :github,
    :model_evals,
    :publication,
    :retention,
    :runtime_mode,
    :schedules,
    :slack,
    :state_tools,
    :webhooks,
    :work
  ]
  @root_required ~w(version mode host_ref coop repositories admission work)
  @root_optional ~w(control_plane coop_worker_gateway delivery publication retention state_tools event_waits schedules emisar slack github webhooks model_evals repository_sets learning)

  @spec install_from_env!() :: :ok
  def install_from_env! do
    case System.get_env(@configuration_env) do
      nil ->
        :ok

      "" ->
        raise ArgumentError, "#{@configuration_env} must name a configuration file"

      path ->
        configuration = load!(path)

        Enum.each(configuration, fn {key, value} ->
          Application.put_env(:responder, key, value, persistent: true)
        end)

        @managed_application_keys
        |> Kernel.--(Map.keys(configuration))
        |> Enum.each(&Application.delete_env(:responder, &1, persistent: true))

        :ok
    end
  end

  @spec load!(Path.t(), keyword()) :: map()
  def load!(path, options \\ []) do
    unless is_binary(path) and Path.type(path) == :absolute do
      raise ArgumentError, "Elixir runtime configuration path must be absolute"
    end

    document = File.read!(path)

    if byte_size(document) > @maximum_bytes do
      raise ArgumentError, "Elixir runtime configuration exceeds #{@maximum_bytes} bytes"
    end

    from_string!(document, options)
  end

  @spec from_string!(binary(), keyword()) :: map()
  def from_string!(document, options \\ []) do
    env_provider = Keyword.get(options, :env_provider, &System.fetch_env/1)

    unless Keyword.keyword?(options) and
             Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
             Keyword.keys(options) -- [:env_provider] == [] and is_function(env_provider, 1) do
      raise ArgumentError, "runtime configuration options are invalid"
    end

    unless is_binary(document) and byte_size(document) <= @maximum_bytes do
      raise ArgumentError, "Elixir runtime configuration must be bounded UTF-8 YAML"
    end

    decoded =
      case YamlElixir.read_from_string(document) do
        {:ok, value} -> value
        {:error, reason} -> raise ArgumentError, "invalid Elixir runtime YAML: #{inspect(reason)}"
      end

    build!(decoded, env_provider)
  end

  defp build!(decoded, env_provider) do
    root = object!(decoded, @root_required, @root_optional, "configuration")

    unless root["version"] == 1,
      do: raise(ArgumentError, "configuration version must be 1")

    mode = mode!(root["mode"])
    host_ref = reference!(root["host_ref"], "host_ref")
    coop = coop!(root["coop"], mode)
    repositories = repositories!(root["repositories"])
    repository_sets = repository_sets!(root["repository_sets"], repositories)
    repository_contexts = repository_contexts(repositories, repository_sets)
    work = work!(root["work"], coop, host_ref, mode)
    admission = admission!(root["admission"], coop, host_ref, mode, work)
    learning = optional(root, "learning", &learning!(&1, coop, host_ref, mode, work))

    model_evals =
      optional(
        root,
        "model_evals",
        &model_evals!(&1, admission, repositories, repository_sets, coop)
      )

    coop_worker_gateway =
      optional(root, "coop_worker_gateway", &coop_worker_gateway!(&1, env_provider))

    schedules = schedules!(root["schedules"], repositories, host_ref)

    github =
      optional(
        root,
        "github",
        &github!(&1, repositories, repository_contexts, env_provider)
      )

    slack =
      optional(
        root,
        "slack",
        &slack!(&1, repository_contexts, work, schedules, env_provider)
      )

    control_plane =
      optional(root, "control_plane", &control_plane!(&1, repository_contexts, work, schedules))

    adapters = adapters!(slack, github, control_plane)
    delivery = delivery!(root["delivery"], adapters, host_ref)

    webhooks =
      webhooks!(root["webhooks"], env_provider, adapters, repositories, repository_contexts)

    publication =
      publication!(
        root["publication"],
        coop,
        work,
        repositories,
        github,
        adapters,
        host_ref,
        env_provider
      )

    retention = retention!(root["retention"], work, learning, host_ref)
    event_waits = event_waits!(root["event_waits"])

    emisar =
      optional(
        root,
        "emisar",
        &emisar!(&1, adapters, presentation_timeout_ms(slack, github), host_ref, env_provider)
      )

    state_tools =
      state_tools!(root["state_tools"], emisar, slack, github, control_plane, env_provider, %{
        emisar_approvals: not is_nil(emisar),
        event_waits: not is_nil(event_waits),
        publication: not is_nil(publication),
        schedules: not is_nil(schedules)
      })

    {work, coop_worker_gateway} =
      bind_state_tools!(work, coop_worker_gateway, state_tools)

    %{
      admission: admission,
      fleet_profiles: fleet_profiles(repositories, admission),
      runtime_mode: mode,
      work: work
    }
    |> put_optional(:emisar, emisar && emisar.runtime)
    |> put_optional(:learning, learning)
    |> put_optional(:model_evals, model_evals)
    |> put_optional(:slack, slack && slack.runtime)
    |> put_optional(:github, github && github.runtime)
    |> put_optional(:control_plane, control_plane)
    |> put_optional(:coop_worker_gateway, coop_worker_gateway)
    |> put_optional(:delivery, delivery)
    |> put_optional(:publication, publication)
    |> put_optional(:retention, retention)
    |> put_optional(:state_tools, state_tools)
    |> put_optional(:event_waits, event_waits)
    |> put_optional(:schedules, schedules)
    |> put_optional(:webhooks, webhooks)
    |> validate_product_mode!()
    |> validate_runtimes!()
  end

  defp fleet_profiles(repositories, admission) do
    repository_profiles =
      Enum.flat_map(repositories, fn {name, repository} ->
        [
          {{"read_only", name},
           maybe_put_policy_authority(
             %{
               policy: repository.conversation_policy.name,
               policy_digest: repository.conversation_policy.digest,
               repository_ref: name
             },
             Map.get(repository.conversation_policy, :authority_digest)
           )},
          {{"repository_write", name},
           maybe_put_policy_authority(
             %{
               policy: repository.contributor_policy.name,
               policy_digest: repository.contributor_policy.digest,
               repository_ref: name
             },
             Map.get(repository.contributor_policy, :authority_digest)
           )}
        ]
      end)

    Map.new([
      {{"read_only", nil},
       %{
         policy: admission.policy,
         policy_digest: admission.policy_digest,
         repository_ref: nil
       }}
      | repository_profiles
    ])
  end

  defp mode!("product"), do: :product
  defp mode!("component"), do: :component

  defp mode!(_value),
    do: raise(ArgumentError, "configuration mode must be product or component")

  defp validate_product_mode!(%{runtime_mode: :component} = configuration), do: configuration

  defp validate_product_mode!(
         %{
           runtime_mode: :product,
           retention: retention,
           coop_worker_gateway: gateway,
           state_tools: state_tools,
           admission: %{api: Responder.CoopFleet.Client},
           work: %{api: Responder.CoopFleet.Client}
         } = configuration
       )
       when not is_nil(retention) and not is_nil(gateway) and not is_nil(state_tools),
       do: configuration

  defp validate_product_mode!(%{runtime_mode: :product}) do
    raise ArgumentError,
          "product mode requires fleet Work execution, the mTLS worker gateway, state tools, and retention"
  end

  defp coop!(value, mode) do
    object = object!(value, [], ~w(socket receive_timeout_ms), "coop")

    configuration = %{
      receive_timeout_ms: integer!(object, "receive_timeout_ms", 30_000, 100, 99_999, "coop")
    }

    case {mode, Map.get(object, "socket")} do
      {:component, socket} when is_binary(socket) ->
        Map.put(configuration, :socket, absolute_path!(socket, "coop.socket"))

      {:component, _missing} ->
        raise ArgumentError, "component mode requires a local Coop socket"

      {:product, nil} ->
        configuration

      {:product, _socket} ->
        raise ArgumentError, "product mode forbids a local Coop socket"
    end
  end

  defp repositories!(value) when is_map(value) do
    Map.new(value, fn {name, attributes} ->
      name = reference!(name, "repositories.name")

      repository =
        object!(
          attributes,
          ~w(path github_repository github_binding base_branch conversation_policy contributor_policy schedule_policy),
          ~w(standard_policy deep_policy),
          "repositories.#{name}"
        )

      conversation_policy =
        policy!(repository["conversation_policy"], "repositories.#{name}.conversation_policy")

      standard_policy =
        optional_policy!(
          repository["standard_policy"],
          conversation_policy,
          "repositories.#{name}.standard_policy"
        )

      deep_policy =
        optional_policy!(
          repository["deep_policy"],
          standard_policy,
          "repositories.#{name}.deep_policy"
        )

      validate_class_policy_authority!(
        [conversation_policy, standard_policy, deep_policy],
        "repositories.#{name}"
      )

      {name,
       %{
         base_branch: git_ref!(repository["base_branch"], "repositories.#{name}.base_branch"),
         conversation_policy: conversation_policy,
         contributor_policy:
           policy!(repository["contributor_policy"], "repositories.#{name}.contributor_policy"),
         deep_policy: deep_policy,
         github_binding:
           reference!(repository["github_binding"], "repositories.#{name}.github_binding"),
         github_repository:
           github_repository!(
             repository["github_repository"],
             "repositories.#{name}.github_repository"
           ),
         path: absolute_path!(repository["path"], "repositories.#{name}.path"),
         schedule_policy:
           policy!(repository["schedule_policy"], "repositories.#{name}.schedule_policy"),
         standard_policy: standard_policy
       }}
    end)
  end

  defp repositories!(_value),
    do: raise(ArgumentError, "repositories must be a map")

  defp repository_sets!(nil, _repositories), do: %{}

  defp repository_sets!(value, repositories) when is_map(value) do
    Map.new(value, fn {name, attributes} ->
      name = reference!(name, "repository_sets.name")

      if Map.has_key?(repositories, name) do
        raise ArgumentError, "repository_sets.#{name} conflicts with a repository name"
      end

      set =
        object!(
          attributes,
          ~w(primary_repository read_only_repositories conversation_policy contributor_policy),
          ~w(standard_policy deep_policy parallel_goal_limit),
          "repository_sets.#{name}"
        )

      conversation_policy =
        policy!(set["conversation_policy"], "repository_sets.#{name}.conversation_policy")

      standard_policy =
        optional_policy!(
          set["standard_policy"],
          conversation_policy,
          "repository_sets.#{name}.standard_policy"
        )

      deep_policy =
        optional_policy!(
          set["deep_policy"],
          standard_policy,
          "repository_sets.#{name}.deep_policy"
        )

      validate_class_policy_authority!(
        [conversation_policy, standard_policy, deep_policy],
        "repository_sets.#{name}"
      )

      primary =
        known_repository!(
          set["primary_repository"],
          repositories,
          "repository_sets.#{name}.primary_repository"
        )

      read_only =
        references!(
          set["read_only_repositories"],
          "repository_sets.#{name}.read_only_repositories"
        )

      if length(read_only) > 32 or primary in read_only or
           not Regex.match?(@coop_repository_name, primary) or
           not Enum.all?(read_only, &Regex.match?(@coop_repository_name, &1)) or
           not Enum.all?(read_only, &Map.has_key?(repositories, &1)) do
        raise ArgumentError,
              "repository_sets.#{name} must name at most 32 distinct read-only repositories and exclude its primary"
      end

      {name,
       %{
         conversation_policy: conversation_policy,
         contributor_policy:
           policy!(set["contributor_policy"], "repository_sets.#{name}.contributor_policy"),
         deep_policy: deep_policy,
         parallel_goal_limit:
           integer!(
             set,
             "parallel_goal_limit",
             3,
             1,
             3,
             "repository_sets.#{name}"
           ),
         primary_repository: primary,
         read_only_repositories: read_only,
         standard_policy: standard_policy
       }}
    end)
  end

  defp repository_sets!(_value, _repositories),
    do: raise(ArgumentError, "repository_sets must be a map")

  defp repository_contexts(repositories, repository_sets) do
    direct =
      Map.new(repositories, fn {name, repository} ->
        {name,
         %{
           contributor_policy: repository.contributor_policy,
           work_profile: repository_work_profile(name, repository)
         }}
      end)

    sets =
      Map.new(repository_sets, fn {name, set} ->
        {name,
         %{
           contributor_policy:
             set.contributor_policy
             |> Map.put(:repository_ref, set.primary_repository)
             |> Map.put(
               :repository_context,
               repository_context_document(name, set)
             ),
           work_profile: repository_set_work_profile(name, set)
         }}
      end)

    Map.merge(direct, sets)
  end

  defp admission!(value, coop, host_ref, mode, work) do
    object =
      object!(
        value,
        ~w(policy),
        ~w(concurrency decision_timeout_ms poll_interval_ms),
        "admission"
      )

    policy = policy!(object["policy"], "admission.policy")

    configuration = %{
      policy: policy.name,
      policy_digest: policy.digest,
      concurrency: integer!(object, "concurrency", 4, 1, 32, "admission"),
      decision_timeout_ms:
        integer!(object, "decision_timeout_ms", 30_000, 1_000, 300_000, "admission"),
      poll_interval_ms: integer!(object, "poll_interval_ms", 250, 1, 60_000, "admission"),
      receive_timeout_ms: coop.receive_timeout_ms,
      worker_ref: "#{host_ref}:admission"
    }

    case mode do
      :product -> Map.merge(configuration, %{api: work.api, client: work.client})
      :component -> Map.put(configuration, :socket, coop.socket)
    end
  end

  defp learning!(value, coop, host_ref, mode, work) do
    object =
      object!(
        value,
        ~w(policy),
        ~w(concurrency batch_size quiet_seconds maximum_delay_seconds poll_interval_ms execution_timeout_seconds),
        "learning"
      )

    policy = policy!(object["policy"], "learning.policy")

    config = %{
      policy: policy.name,
      policy_digest: policy.digest,
      worker_ref: "#{host_ref}:learning",
      concurrency: integer!(object, "concurrency", 1, 1, 8, "learning"),
      batch_size: integer!(object, "batch_size", 16, 1, 16, "learning"),
      quiet_seconds: integer!(object, "quiet_seconds", 10, 0, 300, "learning"),
      maximum_delay_seconds: integer!(object, "maximum_delay_seconds", 60, 1, 600, "learning"),
      poll_interval_ms: integer!(object, "poll_interval_ms", 1000, 100, 60_000, "learning"),
      execution_timeout_seconds:
        integer!(object, "execution_timeout_seconds", 600, 30, 1800, "learning"),
      receive_timeout_ms: min(coop.receive_timeout_ms, 30_000)
    }

    case mode do
      :product -> Map.merge(config, %{api: work.api, client: work.client})
      :component -> Map.put(config, :socket, coop.socket)
    end
  end

  defp model_evals!(value, admission, repositories, repository_sets, coop) do
    object =
      object!(
        value,
        ~w(no_tools_policy socket world_policy),
        ~w(world_baseline_policy),
        "model_evals"
      )

    socket = absolute_path!(object["socket"], "model_evals.socket")

    if Map.get(coop, :socket) == socket do
      raise ArgumentError, "model_evals.socket must be isolated from coop.socket"
    end

    no_tools = policy!(object["no_tools_policy"], "model_evals.no_tools_policy")
    world = policy!(object["world_policy"], "model_evals.world_policy")

    baseline =
      if Map.has_key?(object, "world_baseline_policy"),
        do: policy!(object["world_baseline_policy"], "model_evals.world_baseline_policy"),
        else: nil

    eval_policies = Enum.reject([no_tools, world, baseline], &is_nil/1)

    production_policies =
      [
        %{name: admission.policy, digest: admission.policy_digest}
        | Enum.flat_map(repositories, fn {_name, repository} ->
            [
              repository.conversation_policy,
              repository.contributor_policy,
              repository.standard_policy,
              repository.deep_policy,
              repository.schedule_policy
            ]
          end) ++
            Enum.flat_map(repository_sets, fn {_name, set} ->
              [
                set.conversation_policy,
                set.contributor_policy,
                set.standard_policy,
                set.deep_policy
              ]
            end)
      ]
      |> List.flatten()

    if Enum.any?(eval_policies, fn eval_policy ->
         Enum.any?(production_policies, fn production_policy ->
           eval_policy.name == production_policy.name or
             eval_policy.digest == production_policy.digest
         end)
       end) do
      raise ArgumentError, "model_evals must not reuse production policy authority"
    end

    names = Enum.map(eval_policies, & &1.name)
    digests = Enum.map(eval_policies, & &1.digest)

    if Enum.uniq(names) != names or Enum.uniq(digests) != digests do
      raise ArgumentError, "model_evals policies must have distinct authority"
    end

    configuration = %{
      no_tools_policy: no_tools.name,
      no_tools_policy_digest: no_tools.digest,
      receive_timeout_ms: coop.receive_timeout_ms,
      socket: socket,
      world_policy: world.name,
      world_policy_digest: world.digest
    }

    if baseline do
      Map.merge(configuration, %{
        world_baseline_policy: baseline.name,
        world_baseline_policy_digest: baseline.digest
      })
    else
      configuration
    end
  end

  defp work!(value, coop, host_ref, mode) do
    object =
      object!(
        value,
        [],
        ~w(execution workspace_ref capability_names concurrency poll_interval_ms source_and_action_tools),
        "work"
      )

    execution = Map.get(object, "execution", if(mode == :product, do: "fleet", else: "direct"))
    poll_interval_ms = integer!(object, "poll_interval_ms", 250, 1, 60_000, "work")

    {api, client} =
      case execution do
        "direct" ->
          if Map.has_key?(object, "workspace_ref") or Map.has_key?(object, "capability_names"),
            do: raise(ArgumentError, "direct work execution cannot configure fleet placement")

          {Responder.Coop.Client, coop_client!(coop, "work")}

        "fleet" ->
          workspace_ref = reference!(object["workspace_ref"], "work.workspace_ref")

          capabilities =
            references!(
              Map.get(object, "capability_names", ["responder-state"]),
              "work.capability_names"
            )

          fleet_client!(workspace_ref, capabilities, coop.receive_timeout_ms, poll_interval_ms)

        _other ->
          raise ArgumentError, "work.execution must be direct or fleet"
      end

    %{
      api: api,
      client: client,
      concurrency: integer!(object, "concurrency", 4, 1, 32, "work"),
      poll_interval_ms: poll_interval_ms,
      receive_timeout_ms: coop.receive_timeout_ms,
      worker_ref: "#{host_ref}:work"
    }
    |> put_optional(
      :platform_tools,
      source_and_action_tools!(object["source_and_action_tools"])
    )
  end

  defp retention!(nil, _work, _learning, _host_ref), do: nil

  defp retention!(value, work, learning, host_ref) do
    fields =
      ~w(poll_interval_ms lease_seconds max_attempts retry_base_seconds retry_max_seconds closed_session_grace_seconds operational_data_seconds conversation_memory_seconds closed_work_seconds episode_history_seconds audit_data_seconds)

    # Draining and storage budgets carry the documented defaults so an existing
    # installation keeps starting; the retention horizons above stay explicit.
    budgets =
      ~w(batch_limit batch_seconds retained_recheck_seconds disposable_bytes_limit reclaim_target_seconds storage_high_watermark_bytes storage_low_watermark_bytes storage_reserve_bytes)

    object = object!(value, fields, budgets, "retention")

    learning_adapter =
      if learning,
        do: Responder.Learning.Runtime.options!(learning),
        else: work

    poll_interval_ms = integer!(object, "poll_interval_ms", nil, 1, 3_600_000, "retention")
    # One drain pass must fit inside its own poll; the default follows the poll.
    default_batch_seconds = min(30, max(div(poll_interval_ms, 1_000), 1))

    retention = %{
      audit_data_seconds:
        integer!(object, "audit_data_seconds", nil, 60, 10 * 365 * 86_400, "retention"),
      api: work.api,
      batch_limit: integer!(object, "batch_limit", 25, 1, 1_000, "retention"),
      batch_seconds:
        integer!(object, "batch_seconds", default_batch_seconds, 1, 3_600, "retention"),
      client: work.client,
      closed_session_grace_seconds:
        integer!(object, "closed_session_grace_seconds", nil, 0, 30 * 86_400, "retention"),
      closed_work_seconds:
        integer!(object, "closed_work_seconds", nil, 60, 10 * 365 * 86_400, "retention"),
      conversation_memory_seconds:
        integer!(
          object,
          "conversation_memory_seconds",
          nil,
          60,
          10 * 365 * 86_400,
          "retention"
        ),
      episode_history_seconds:
        integer!(
          object,
          "episode_history_seconds",
          nil,
          60,
          10 * 365 * 86_400,
          "retention"
        ),
      lease_seconds: integer!(object, "lease_seconds", nil, 1, 3_600, "retention"),
      learning_api: learning_adapter.api,
      learning_client: learning_adapter.client,
      max_attempts: integer!(object, "max_attempts", nil, 1, 100, "retention"),
      operational_data_seconds:
        integer!(
          object,
          "operational_data_seconds",
          nil,
          60,
          10 * 365 * 86_400,
          "retention"
        ),
      poll_interval_ms: poll_interval_ms,
      retained_recheck_seconds:
        integer!(object, "retained_recheck_seconds", 21_600, 60, 30 * 86_400, "retention"),
      retry_base_seconds: integer!(object, "retry_base_seconds", nil, 1, 3_600, "retention"),
      retry_max_seconds: integer!(object, "retry_max_seconds", nil, 1, 86_400, "retention"),
      worker_ref: "#{host_ref}:retention"
    }

    retention = Map.merge(retention, retention_storage!(object))

    unless retention.retry_max_seconds >= retention.retry_base_seconds and
             retention.operational_data_seconds <= retention.closed_work_seconds and
             retention.closed_work_seconds <= retention.episode_history_seconds and
             retention.episode_history_seconds <= retention.audit_data_seconds and
             retention.operational_data_seconds <= retention.conversation_memory_seconds and
             retention.batch_seconds * 1_000 <= retention.poll_interval_ms do
      raise ArgumentError,
            "retention horizons must be ordered, retry bounds must increase, " <>
              "and one drain pass must fit its poll"
    end

    retention
  end

  # Workspace storage policy Responder documents and reports. Workers enforce
  # their own allocation refusal and low-watermark recovery from these bounds.
  # Defaults: 10 GiB of inactive disposable forks reclaimed within an hour, a
  # 60 GiB high and 45 GiB low watermark, and a 5 GiB reserve for cleanup.
  defp retention_storage!(object) do
    bytes = fn field, default ->
      integer!(object, field, default, 1_048_576, 1_099_511_627_776, "retention")
    end

    storage = %{
      disposable_bytes_limit: bytes.("disposable_bytes_limit", 10_737_418_240),
      reclaim_target_seconds:
        integer!(object, "reclaim_target_seconds", 3_600, 60, 30 * 86_400, "retention"),
      storage_high_watermark_bytes: bytes.("storage_high_watermark_bytes", 64_424_509_440),
      storage_low_watermark_bytes: bytes.("storage_low_watermark_bytes", 48_318_382_080),
      storage_reserve_bytes: bytes.("storage_reserve_bytes", 5_368_709_120)
    }

    unless storage.storage_low_watermark_bytes < storage.storage_high_watermark_bytes and
             storage.storage_reserve_bytes < storage.storage_high_watermark_bytes and
             storage.disposable_bytes_limit <= storage.storage_high_watermark_bytes do
      raise ArgumentError, "retention storage watermarks must be ordered below capacity"
    end

    storage
  end

  defp control_plane!(value, repository_contexts, work, schedules) do
    object = object!(value, ~w(port work_profile), ~w(ip), "control_plane")
    ip = ip!(Map.get(object, "ip", "127.0.0.1"), "control_plane.ip")

    unless ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}],
      do: raise(ArgumentError, "control_plane.ip must be loopback")

    %{
      coop_api: work.api,
      coop_client: work.client,
      ip: ip,
      port: positive_port!(object["port"], "control_plane.port"),
      schedule_policies: schedules,
      task_policies:
        Map.new(repository_contexts, fn {repository_ref, context} ->
          {repository_ref, context.contributor_policy}
        end),
      work_profile:
        work_profile!(
          object["work_profile"],
          "control_plane.work_profile",
          repository_contexts
        )
    }
  end

  defp coop_worker_gateway!(value, env_provider) do
    object =
      object!(
        value,
        ~w(port public_url cacertfile ca_keyfile certfile checkpoint_key_env checkpoint_secret_scan_env keyfile),
        ~w(ip certificate_ttl_seconds),
        "coop_worker_gateway"
      )

    checkpoint_key =
      object["checkpoint_key_env"]
      |> required_secret!(env_provider, "coop_worker_gateway.checkpoint_key_env")
      |> decode_checkpoint_key!()

    checkpoint_secrets =
      object["checkpoint_secret_scan_env"]
      |> references!("coop_worker_gateway.checkpoint_secret_scan_env")
      |> Enum.map(
        &required_secret!(&1, env_provider, "coop_worker_gateway.checkpoint_secret_scan_env")
      )

    %{
      cacertfile: absolute_path!(object["cacertfile"], "coop_worker_gateway.cacertfile"),
      ca_keyfile: absolute_path!(object["ca_keyfile"], "coop_worker_gateway.ca_keyfile"),
      certificate_ttl_seconds:
        integer!(
          object,
          "certificate_ttl_seconds",
          86_400,
          300,
          604_800,
          "coop_worker_gateway"
        ),
      certfile: absolute_path!(object["certfile"], "coop_worker_gateway.certfile"),
      checkpoint_key: checkpoint_key,
      checkpoint_secrets: checkpoint_secrets,
      ip: ip!(Map.get(object, "ip", "127.0.0.1"), "coop_worker_gateway.ip"),
      keyfile: absolute_path!(object["keyfile"], "coop_worker_gateway.keyfile"),
      port: positive_port!(object["port"], "coop_worker_gateway.port"),
      public_url: https_origin!(object["public_url"], "coop_worker_gateway.public_url")
    }
  end

  defp decode_checkpoint_key!(encoded) do
    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) == 32 ->
        key

      _invalid ->
        raise ArgumentError,
              "coop_worker_gateway checkpoint key must be base64 for exactly 32 bytes"
    end
  end

  defp bind_state_tools!(work, nil, state_tools),
    do: {bind_platform_tools!(work, state_tools), nil}

  defp bind_state_tools!(work, gateway, nil),
    do: {bind_platform_tools!(work, nil), gateway}

  defp bind_state_tools!(work, gateway, state_tools) do
    endpoint = gateway.public_url <> "/v1/state-tools/mcp"
    work = bind_platform_tools!(work, state_tools)

    {
      work
      |> Map.put(:state_tool_capabilities, state_tools.capabilities)
      |> Map.put(:state_tools_endpoint, endpoint)
      |> Map.put(:state_tools_secret, state_tools.token),
      Map.put(gateway, :state_tools, %{
        capabilities: state_tools.capabilities,
        emisar_rpc_url: Map.get(state_tools, :emisar_rpc_url),
        additional_tools: Map.get(state_tools, :additional_tools),
        additional_call: Map.get(state_tools, :additional_call),
        answer_authorizer: Map.get(state_tools, :answer_authorizer),
        token_secret: state_tools.token
      })
    }
  end

  defp bind_platform_tools!(work, state_tools) do
    configured = Map.get(work, :platform_tools, [])

    hosted =
      case state_tools do
        %{additional_tools: tools} when is_list(tools) -> tools
        _other -> []
      end

    tools = configured ++ hosted

    names =
      Enum.map(tools, fn
        %{"name" => name} -> name
        name -> name
      end)

    cond do
      names != Enum.uniq(names) ->
        raise ArgumentError,
              "work.source_and_action_tools must not overlap configured host capability tools"

      tools == [] ->
        Map.delete(work, :platform_tools)

      true ->
        Map.put(work, :platform_tools, tools)
    end
  end

  defp github!(value, repositories, repository_contexts, env_provider) do
    object =
      object!(
        value,
        ~w(api_url app_id private_key_env webhook_secret_env bindings port),
        ~w(ip receive_timeout_ms),
        "github"
      )

    api_url = reference!(object["api_url"], "github.api_url")
    receive_timeout = integer!(object, "receive_timeout_ms", 30_000, 100, 60_000, "github")
    bindings = map_nonempty!(object["bindings"], "github.bindings")
    app_id = positive_integer!(object["app_id"], "github.app_id")

    private_key =
      object["private_key_env"]
      |> required_secret!(env_provider, "github.private_key_env")
      |> github_private_key()

    webhook_secret =
      required_secret!(object["webhook_secret_env"], env_provider, "github.webhook_secret_env")

    signer =
      case AppJWT.new(app_id, private_key) do
        {:ok, signer} ->
          signer

        {:error, reason} ->
          raise ArgumentError, "invalid GitHub App private key: #{inspect(reason)}"
      end

    app_http =
      json_client!(
        api_url,
        receive_timeout,
        fn -> AppJWT.token(signer) end,
        "github.app_http"
      )

    prepared =
      Map.new(bindings, fn {name, attributes} ->
        name = adapter_name!(name, "github.bindings.name")

        binding =
          object!(
            attributes,
            ~w(repository installation_id repository_id responder_actor_id authorized_actor_ids),
            ~w(max_body_bytes repository_context),
            "github.bindings.#{name}"
          )

        repository_alias = reference!(binding["repository"], "github.bindings.#{name}.repository")
        repository = fetch_repository!(repositories, repository_alias, "github.bindings.#{name}")

        context_ref =
          optional_reference!(
            binding["repository_context"],
            "github.bindings.#{name}.repository_context"
          ) || repository_alias

        repository_context =
          Map.get(repository_contexts, context_ref) ||
            raise ArgumentError,
                  "github.bindings.#{name}.repository_context names an unknown repository context"

        unless repository_context.work_profile.repository_ref == repository_alias do
          raise ArgumentError,
                "github.bindings.#{name}.repository_context primary must match repository #{repository_alias}"
        end

        unless repository.github_binding == name do
          raise ArgumentError,
                "github binding #{name} does not match repository #{repository_alias} placement"
        end

        delivery_token_provider = fn -> InstallationTokens.token(name, :delivery) end
        publication_token_provider = fn -> InstallationTokens.token(name, :publication) end

        repository_write_token_provider = fn ->
          InstallationTokens.token(name, :repository_write)
        end

        delivery_http =
          json_client!(
            api_url,
            receive_timeout,
            delivery_token_provider,
            "github.bindings.#{name}.delivery"
          )

        publication_http =
          json_client!(
            api_url,
            receive_timeout,
            publication_token_provider,
            "github.bindings.#{name}.publication"
          )

        delivery_client = github_client!(delivery_http, "github.bindings.#{name}.delivery")

        publication_client =
          github_client!(publication_http, "github.bindings.#{name}.publication")

        attributes = %{
          authorized_actor_ids:
            positive_ids!(
              binding["authorized_actor_ids"],
              "github.bindings.#{name}.authorized_actor_ids"
            ),
          installation_id:
            positive_integer!(
              binding["installation_id"],
              "github.bindings.#{name}.installation_id"
            ),
          max_body_bytes:
            integer!(binding, "max_body_bytes", 40_000, 1_024, 40_000, "github.bindings.#{name}"),
          name: name,
          repository_full_name: repository.github_repository,
          repository_id:
            positive_integer!(binding["repository_id"], "github.bindings.#{name}.repository_id"),
          responder_actor_id:
            positive_integer!(
              binding["responder_actor_id"],
              "github.bindings.#{name}.responder_actor_id"
            ),
          secret: webhook_secret,
          work_profile: repository_context.work_profile
        }

        {:ok, trusted_binding} = Binding.new(attributes)

        {name,
         %{
           client: delivery_client,
           publication_client: publication_client,
           repository: repository,
           repository_alias: repository_alias,
           repository_write_token_provider: repository_write_token_provider,
           trusted_binding: trusted_binding
         }}
      end)

    confirmations =
      Confirmations.options!(%{
        repositories:
          Map.new(repository_contexts, fn {context_ref, context} ->
            {context_ref, %{contributor_policy: context.contributor_policy}}
          end)
      })

    server = %{
      bindings: Map.new(prepared, fn {name, item} -> {name, item.trusted_binding} end),
      confirmations: confirmations,
      ip: ip!(Map.get(object, "ip", "127.0.0.1"), "github.ip"),
      port: positive_port!(object["port"], "github.port"),
      secret: webhook_secret
    }

    tokens = %{
      app_http: app_http,
      bindings:
        Map.new(prepared, fn {name, item} ->
          {name,
           %{
             installation_id: item.trusted_binding.installation_id,
             repository_id: item.trusted_binding.repository_id
           }}
        end),
      requester: JSONClient
    }

    delivery_binding = %{
      bindings:
        Map.new(prepared, fn {name, item} ->
          {name,
           %{
             api: Client,
             client: item.client,
             repository_full_name: item.repository.github_repository,
             repository_id: item.trusted_binding.repository_id
           }}
        end)
    }

    %{
      bindings: prepared,
      capability_tools: GitHubCapabilityTools.options!(delivery_binding),
      delivery_binding: delivery_binding,
      receive_timeout_ms: receive_timeout,
      runtime: %{server: server, tokens: tokens}
    }
  end

  defp github_private_key("-----BEGIN " <> _rest = private_key), do: private_key

  defp github_private_key(encoded) do
    case Base.decode64(encoded) do
      {:ok, private_key}
      when byte_size(private_key) in 16..4_096 and is_binary(private_key) ->
        private_key

      _invalid ->
        encoded
    end
  end

  defp slack!(value, repository_contexts, work, schedules, env_provider) do
    object =
      object!(
        value,
        ~w(api_url app_token_env bot_token_env default_repository identity incident_policy operators watch_channels),
        ~w(channel_prefix handshake_timeout_ms incident_invite_users incident_private incident_room_interval_ms incident_room_reconcile_ms maximum_open_incidents membership_reconcile_ms receive_timeout_ms reconnect_ms task_card_interval_ms task_card_reconcile_ms thread_status_interval_ms),
        "slack"
      )

    receive_timeout = integer!(object, "receive_timeout_ms", 30_000, 100, 60_000, "slack")
    api_url = reference!(object["api_url"], "slack.api_url")

    app_http =
      json_client!(
        api_url,
        receive_timeout,
        token_provider!(object["app_token_env"], env_provider, "slack.app_token_env"),
        "slack.app_http"
      )

    bot_http =
      json_client!(
        api_url,
        receive_timeout,
        token_provider!(object["bot_token_env"], env_provider, "slack.bot_token_env"),
        "slack.bot_http"
      )

    {:ok, bot_client} = SlackClient.new(http: bot_http, requester: JSONClient)

    identity =
      object!(object["identity"], ~w(workspace_ref bot_ref bot_user_ref), [], "slack.identity")

    runtime =
      %{
        app_http: app_http,
        bot_client: bot_client,
        channel_prefix: Map.get(object, "channel_prefix", "ems"),
        coop_api: work.api,
        coop_client: work.client,
        default_repository: reference!(object["default_repository"], "slack.default_repository"),
        handshake_timeout_ms:
          integer!(object, "handshake_timeout_ms", 10_000, 100, 60_000, "slack"),
        identity: %{
          bot_ref: reference!(identity["bot_ref"], "slack.identity.bot_ref"),
          bot_user_ref: reference!(identity["bot_user_ref"], "slack.identity.bot_user_ref"),
          workspace_ref: reference!(identity["workspace_ref"], "slack.identity.workspace_ref")
        },
        incident_invite_users:
          references!(Map.get(object, "incident_invite_users", []), "slack.incident_invite_users"),
        incident_policy: policy!(object["incident_policy"], "slack.incident_policy"),
        incident_private:
          boolean!(Map.get(object, "incident_private", true), "slack.incident_private"),
        incident_room_interval_ms:
          integer!(object, "incident_room_interval_ms", 1_000, 1, 86_400_000, "slack"),
        incident_room_reconcile_ms:
          integer!(object, "incident_room_reconcile_ms", 300_000, 1_000, 86_400_000, "slack"),
        maximum_open_incidents: integer!(object, "maximum_open_incidents", 25, 1, 1_000, "slack"),
        membership_reconcile_ms:
          integer!(object, "membership_reconcile_ms", 300_000, 1, 86_400_000, "slack"),
        operators: references!(object["operators"], "slack.operators"),
        receive_timeout_ms: receive_timeout,
        reconnect_ms: integer!(object, "reconnect_ms", 1_000, 1, 60_000, "slack"),
        schedule_policies: schedules,
        repositories: repository_contexts,
        task_card_interval_ms:
          integer!(object, "task_card_interval_ms", 1_000, 1, 86_400_000, "slack"),
        task_card_reconcile_ms:
          integer!(object, "task_card_reconcile_ms", 2_000, 1_000, 86_400_000, "slack"),
        thread_status_interval_ms:
          integer!(object, "thread_status_interval_ms", 1_000, 50, 60_000, "slack"),
        watch_channels: references!(object["watch_channels"], "slack.watch_channels")
      }

    capability_tools =
      SlackCapabilityTools.options!(%{
        action_tokens: {ActionTokens, ActionTokens},
        api: SlackClient,
        client: bot_client,
        workspace_ref: runtime.identity.workspace_ref
      })

    %{
      capability_tools: capability_tools,
      delivery_adapter: Responder.Slack.Runtime.delivery_adapter!(runtime),
      runtime: runtime
    }
  end

  defp adapters!(slack, github, control_plane) do
    %{}
    |> put_optional(
      "control_plane",
      control_plane &&
        %{
          binding: nil,
          message_publisher: Responder.ControlPlane.Publisher,
          reaction_publisher: Responder.ControlPlane.Publisher
        }
    )
    |> put_optional("slack", slack && slack.delivery_adapter)
    |> put_optional(
      "github",
      github &&
        %{
          binding: github.delivery_binding,
          message_publisher: Publisher,
          reaction_publisher: Publisher
        }
    )
  end

  defp delivery!(nil, adapters, _host_ref) when map_size(adapters) == 0, do: nil

  defp delivery!(nil, adapters, _host_ref) when map_size(adapters) > 0 do
    raise ArgumentError, "delivery must be configured when a platform adapter is enabled"
  end

  defp delivery!(value, adapters, host_ref) do
    if map_size(adapters) == 0,
      do: raise(ArgumentError, "delivery requires at least one local, Slack, or GitHub adapter")

    object =
      object!(
        value,
        [],
        ~w(action_concurrency lease_seconds max_attempts message_concurrency poll_interval_ms reaction_concurrency retry_base_seconds retry_max_seconds),
        "delivery"
      )

    %{
      action_concurrency: integer!(object, "action_concurrency", 1, 1, 30, "delivery"),
      adapters: adapters,
      lease_seconds: integer!(object, "lease_seconds", 60, 1, 86_400, "delivery"),
      max_attempts: integer!(object, "max_attempts", 8, 1, 1_000, "delivery"),
      message_concurrency: integer!(object, "message_concurrency", 2, 1, 31, "delivery"),
      poll_interval_ms: integer!(object, "poll_interval_ms", 250, 1, 60_000, "delivery"),
      reaction_concurrency: integer!(object, "reaction_concurrency", 1, 1, 31, "delivery"),
      retry_base_seconds: integer!(object, "retry_base_seconds", 1, 1, 86_400, "delivery"),
      retry_max_seconds: integer!(object, "retry_max_seconds", 60, 1, 86_400, "delivery"),
      worker_ref: "#{host_ref}:delivery"
    }
  end

  defp publication!(nil, _coop, _work, _repositories, _github, adapters, _host_ref, _env)
       when map_size(adapters) == 0,
       do: nil

  defp publication!(nil, coop, work, _repositories, _github, adapters, host_ref, _env) do
    # Readiness uses the existing Coop authority, not GitHub credentials. An
    # empty publication allowlist keeps external writes explicitly unavailable.
    options = %{"lease_seconds" => max(60, div(coop.receive_timeout_ms, 1_000) + 1)}
    publication_runtime!(options, coop, work, %{}, adapters, host_ref)
  end

  defp publication!(value, coop, work, repositories, github, adapters, host_ref, env_provider) do
    if is_nil(github), do: raise(ArgumentError, "publication requires GitHub configuration")
    if map_size(adapters) == 0, do: raise(ArgumentError, "publication requires delivery adapters")

    object =
      object!(
        value,
        ~w(branch_prefix state_dir commit_name commit_email secret_scan_env),
        ~w(concurrency followup_interval_seconds lease_seconds poll_interval_ms retry_base_seconds retry_max_seconds),
        "publication"
      )

    secret_scan_env =
      references!(object["secret_scan_env"], "publication.secret_scan_env")

    common_git_binding = %{
      branch_prefix: git_ref!(object["branch_prefix"], "publication.branch_prefix"),
      command: GitCommand,
      commit_email: email!(object["commit_email"], "publication.commit_email"),
      commit_name: reference!(object["commit_name"], "publication.commit_name"),
      secrets:
        Enum.map(
          secret_scan_env,
          &required_secret!(&1, env_provider, "publication.secret_scan_env")
        ),
      state_dir: absolute_path!(object["state_dir"], "publication.state_dir")
    }

    publication_repositories =
      Map.new(repositories, fn {name, repository} ->
        binding =
          fetch_binding!(
            github.bindings,
            repository.github_binding,
            "repositories.#{name}.github_binding"
          )

        {name,
         %{
           api: Client,
           base_branch: repository.base_branch,
           client: binding.publication_client,
           git_binding:
             Map.put(
               common_git_binding,
               :token_provider,
               binding.repository_write_token_provider
             ),
           github_repository: repository.github_repository,
           path: repository.path,
           responder_actor_id: binding.trusted_binding.responder_actor_id
         }}
      end)

    if map_size(publication_repositories) == 0,
      do: raise(ArgumentError, "publication requires at least one GitHub-bound repository")

    publication_runtime!(object, coop, work, publication_repositories, adapters, host_ref)
  end

  defp publication_runtime!(object, coop, work, publication_repositories, adapters, host_ref) do
    status_client = %{repositories: publication_repositories}

    publisher_binding = %{
      api: GitHubPublisher,
      client: status_client,
      git: Git,
      repositories: publication_repositories
    }

    %{
      concurrency: integer!(object, "concurrency", 2, 1, 16, "publication"),
      coop_api: work.api,
      coop_client: work.client,
      delivery_adapters: adapters,
      followup_interval_seconds:
        integer!(object, "followup_interval_seconds", 120, 30, 3_600, "publication"),
      lease_seconds: integer!(object, "lease_seconds", 60, 1, 86_400, "publication"),
      poll_interval_ms: integer!(object, "poll_interval_ms", 250, 1, 60_000, "publication"),
      publisher: GitHubPublisher,
      publisher_binding: publisher_binding,
      receive_timeout_ms: coop.receive_timeout_ms,
      retry_base_seconds: integer!(object, "retry_base_seconds", 1, 1, 86_400, "publication"),
      retry_max_seconds: integer!(object, "retry_max_seconds", 60, 1, 86_400, "publication"),
      worker_ref: "#{host_ref}:publication"
    }
  end

  defp emisar!(value, adapters, presentation_timeout_ms, host_ref, env_provider) do
    object =
      object!(
        value,
        ~w(rpc_url token_env),
        ~w(concurrency lease_seconds poll_interval_ms poll_seconds receive_timeout_ms retry_base_seconds retry_max_seconds),
        "emisar"
      )

    endpoint = emisar_endpoint!(object["rpc_url"], "emisar.rpc_url")
    receive_timeout = integer!(object, "receive_timeout_ms", 30_000, 100, 60_000, "emisar")

    http =
      json_client!(
        endpoint.origin,
        receive_timeout,
        token_provider!(object["token_env"], env_provider, "emisar.token_env"),
        "emisar.http"
      )

    client =
      case Responder.Emisar.Client.new(%{
             http: http,
             requester: JSONClient,
             rpc_origin: endpoint.origin,
             rpc_path: endpoint.path
           }) do
        {:ok, client} -> client
        {:error, reason} -> raise ArgumentError, "invalid emisar client: #{inspect(reason)}"
      end

    runtime = %{
      api: Responder.Emisar.Client,
      client: client,
      concurrency: integer!(object, "concurrency", 2, 1, 16, "emisar"),
      lease_seconds: integer!(object, "lease_seconds", 60, 1, 86_400, "emisar"),
      poll_interval_ms: integer!(object, "poll_interval_ms", 1_000, 1, 300_000, "emisar"),
      poll_seconds: integer!(object, "poll_seconds", 3, 1, 86_400, "emisar"),
      presentation: adapters,
      presentation_timeout_ms: presentation_timeout_ms,
      presenter: Responder.Emisar.ApprovalPresenter,
      retry_base_seconds: integer!(object, "retry_base_seconds", 2, 1, 86_400, "emisar"),
      retry_max_seconds: integer!(object, "retry_max_seconds", 300, 1, 86_400, "emisar"),
      worker_ref: "#{host_ref}:emisar-approval"
    }

    %{rpc_url: endpoint.url, runtime: runtime}
  end

  defp presentation_timeout_ms(slack, github) do
    [
      slack && slack.runtime.receive_timeout_ms,
      github && github.receive_timeout_ms
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> 0 end)
  end

  defp state_tools!(nil, nil, _slack, _github, _control_plane, _env_provider, _capabilities),
    do: nil

  defp state_tools!(nil, _emisar, _slack, _github, _control_plane, _env_provider, _capabilities) do
    raise ArgumentError, "emisar requires state_tools for the approval handoff"
  end

  defp state_tools!(value, emisar, slack, github, control_plane, env_provider, capabilities) do
    object = object!(value, ~w(port token_env), ~w(ip), "state_tools")

    %{
      capabilities:
        capabilities
        |> Enum.filter(fn {_capability, enabled} -> enabled end)
        |> Enum.map(fn {capability, true} -> capability end)
        |> Enum.sort(),
      ip: ip!(Map.get(object, "ip", "127.0.0.1"), "state_tools.ip"),
      port: positive_port!(object["port"], "state_tools.port"),
      token: required_secret!(object["token_env"], env_provider, "state_tools.token_env")
    }
    |> put_optional(:emisar_rpc_url, emisar && emisar.rpc_url)
    |> Map.put(:answer_authorizer, answer_authorizer(slack, control_plane))
    |> add_platform_capability_tools(slack, github, control_plane)
  end

  defp answer_authorizer(slack, control_plane) do
    fn
      %{source_kind: "slack", source_ref: workspace, actor_kind: :user, actor_ref: actor} ->
        not is_nil(slack) and workspace == slack.runtime.identity.workspace_ref and
          actor in slack.runtime.operators

      %{
        source_kind: "control_plane",
        source_ref: "local",
        actor_kind: :user,
        actor_ref: "local-operator"
      } ->
        not is_nil(control_plane)

      _ ->
        false
    end
  end

  defp add_platform_capability_tools(configuration, slack, github, control_plane) do
    slack_tools =
      cond do
        slack -> SlackCapabilityTools.list(slack.capability_tools)
        control_plane -> ControlPlaneCapabilityTools.list()
        true -> []
      end

    github_tools = if github, do: GitHubCapabilityTools.list(github.capability_tools), else: []
    tools = slack_tools ++ github_tools
    names = Enum.map(tools, & &1["name"])

    if names != Enum.uniq(names),
      do: raise(ArgumentError, "platform capability-tool names must be unique")

    if tools == [] do
      configuration
    else
      configuration
      |> Map.put(:additional_tools, tools)
      |> Map.put(:additional_call, fn name, arguments, binding ->
        call_platform_tool(slack, github, control_plane, name, arguments, binding)
      end)
    end
  end

  defp call_platform_tool(slack, github, control_plane, name, arguments, binding) do
    transport = binding_transport(binding)

    case transport do
      "slack" when not is_nil(slack) ->
        call_platform_package(
          SlackCapabilityTools,
          slack.capability_tools,
          name,
          arguments,
          binding
        )

      "github" when not is_nil(github) ->
        call_platform_package(
          GitHubCapabilityTools,
          github.capability_tools,
          name,
          arguments,
          binding
        )

      "control_plane" when not is_nil(control_plane) ->
        if Enum.any?(ControlPlaneCapabilityTools.list(), &(&1["name"] == name)),
          do: ControlPlaneCapabilityTools.call(name, arguments, binding),
          else: {:error, "unknown_tool"}

      _unsupported ->
        {:error, "unknown_tool"}
    end
  end

  defp binding_transport(%{episode: %{destination_transport: transport}})
       when is_binary(transport),
       do: transport

  defp binding_transport(_binding), do: nil

  defp call_platform_package(module, options, name, arguments, binding) do
    if Enum.any?(module.list(options), &(&1["name"] == name)),
      do: module.call(name, arguments, binding, options),
      else: {:error, "unknown_tool"}
  end

  defp event_waits!(nil), do: nil

  defp event_waits!(value) do
    object = object!(value, [], ~w(poll_interval_ms), "event_waits")

    %{poll_interval_ms: integer!(object, "poll_interval_ms", 1_000, 1, 300_000, "event_waits")}
  end

  defp schedules!(nil, _repositories, _host_ref), do: nil

  defp schedules!(value, repositories, host_ref) do
    object =
      object!(
        value,
        ~w(read_only_policy governed_operation_policy),
        ~w(lease_seconds misfire_grace_seconds poll_interval_ms retry_base_seconds retry_max_seconds),
        "schedules"
      )

    %{
      governed_operation_policy:
        policy!(object["governed_operation_policy"], "schedules.governed_operation_policy"),
      lease_seconds: integer!(object, "lease_seconds", 60, 1, 86_400, "schedules"),
      misfire_grace_seconds:
        integer!(object, "misfire_grace_seconds", 900, 0, 31_536_000, "schedules"),
      poll_interval_ms: integer!(object, "poll_interval_ms", 1_000, 1, 300_000, "schedules"),
      read_only_policy: policy!(object["read_only_policy"], "schedules.read_only_policy"),
      repositories:
        Map.new(repositories, fn {name, repository} -> {name, repository.schedule_policy} end),
      retry_base_seconds: integer!(object, "retry_base_seconds", 5, 1, 86_400, "schedules"),
      retry_max_seconds: integer!(object, "retry_max_seconds", 1_800, 1, 86_400, "schedules"),
      worker_ref: "#{host_ref}:schedules"
    }
  end

  defp webhooks!(nil, _env_provider, _adapters, _repositories, _repository_contexts), do: nil

  defp webhooks!(value, env_provider, adapters, repositories, repository_contexts) do
    object = object!(value, ~w(port routes), ~w(ip), "webhooks")
    routes = map_nonempty!(object["routes"], "webhooks.routes")

    %{
      ip: ip!(Map.get(object, "ip", "127.0.0.1"), "webhooks.ip"),
      port: positive_port!(object["port"], "webhooks.port"),
      routes:
        Map.new(routes, fn {name, attributes} ->
          name = adapter_name!(name, "webhooks.routes.name")

          route =
            object!(
              attributes,
              ~w(auth destination work_profile),
              ~w(adapter max_body_bytes max_clock_skew_seconds publication_lifecycle),
              "webhooks.routes.#{name}"
            )

          prepared = %{
            adapter: webhook_adapter!(route["adapter"], "webhooks.routes.#{name}.adapter"),
            auth: webhook_auth!(route["auth"], env_provider, "webhooks.routes.#{name}.auth"),
            destination:
              destination!(route["destination"], "webhooks.routes.#{name}.destination"),
            max_body_bytes:
              integer!(route, "max_body_bytes", 40_000, 1_024, 40_000, "webhooks.routes.#{name}"),
            max_clock_skew_seconds:
              integer!(
                route,
                "max_clock_skew_seconds",
                300,
                1,
                3_600,
                "webhooks.routes.#{name}"
              ),
            publication_lifecycle:
              webhook_publication_lifecycle!(
                route["publication_lifecycle"],
                repositories,
                "webhooks.routes.#{name}.publication_lifecycle"
              ),
            work_profile:
              work_profile!(
                route["work_profile"],
                "webhooks.routes.#{name}.work_profile",
                repository_contexts
              )
          }

          validate_webhook_destination!(prepared.destination, adapters, name)
          {name, prepared}
        end)
    }
  end

  defp webhook_publication_lifecycle!(nil, _repositories, _path), do: nil

  defp webhook_publication_lifecycle!(value, repositories, path) do
    scope = object!(value, ~w(environments kinds repositories targets), [], path)

    prepared = %{
      environments: scoped_references!(scope["environments"], "#{path}.environments"),
      kinds: scoped_references!(scope["kinds"], "#{path}.kinds"),
      repositories: scoped_references!(scope["repositories"], "#{path}.repositories"),
      targets: scoped_references!(scope["targets"], "#{path}.targets")
    }

    unless Enum.all?(prepared.kinds, &(&1 in ~w(deployment terraform))),
      do: raise(ArgumentError, "#{path}.kinds must contain only deployment or terraform")

    unless Enum.all?(prepared.repositories, &Map.has_key?(repositories, &1)),
      do: raise(ArgumentError, "#{path}.repositories references an unknown repository")

    prepared
  end

  defp scoped_references!(values, path) do
    case references!(values, path) do
      [] -> raise ArgumentError, "#{path} must not be empty"
      prepared when length(prepared) <= 64 -> Enum.sort(prepared)
      _too_many -> raise ArgumentError, "#{path} must contain at most 64 values"
    end
  end

  defp webhook_adapter!(nil, _path), do: %{kind: :universal}

  defp webhook_adapter!(value, path) do
    kind = value |> object!(~w(kind), ~w(group_by_labels mapping), path) |> Map.fetch!("kind")

    case kind do
      "universal" ->
        _adapter = object!(value, ~w(kind), [], path)
        %{kind: :universal}

      "grafana" ->
        adapter = object!(value, ~w(kind), ~w(group_by_labels), path)

        %{
          kind: :grafana,
          group_by_labels:
            references!(Map.get(adapter, "group_by_labels", []), "#{path}.group_by_labels")
        }

      "mapped_json" ->
        adapter = object!(value, ~w(kind mapping), ~w(group_by_labels), path)
        mapping_path = "#{path}.mapping"

        mapping =
          object!(
            adapter["mapping"],
            ~w(event_id status title),
            ~w(annotations ends_at incident_id item_id labels revision severity source_url starts_at summary),
            mapping_path
          )

        %{
          kind: :mapped_json,
          group_by_labels:
            references!(Map.get(adapter, "group_by_labels", []), "#{path}.group_by_labels"),
          mapping:
            Map.new(mapping, fn {key, value} ->
              {webhook_mapping_field!(key), reference!(value, "#{mapping_path}.#{key}")}
            end)
        }

      _unsupported ->
        raise ArgumentError, "#{path}.kind must be universal, grafana, or mapped_json"
    end
  end

  defp webhook_mapping_field!("annotations"), do: :annotations
  defp webhook_mapping_field!("ends_at"), do: :ends_at
  defp webhook_mapping_field!("event_id"), do: :event_id
  defp webhook_mapping_field!("incident_id"), do: :incident_id
  defp webhook_mapping_field!("item_id"), do: :item_id
  defp webhook_mapping_field!("labels"), do: :labels
  defp webhook_mapping_field!("revision"), do: :revision
  defp webhook_mapping_field!("severity"), do: :severity
  defp webhook_mapping_field!("source_url"), do: :source_url
  defp webhook_mapping_field!("starts_at"), do: :starts_at
  defp webhook_mapping_field!("status"), do: :status
  defp webhook_mapping_field!("summary"), do: :summary
  defp webhook_mapping_field!("title"), do: :title

  defp validate_webhook_destination!(destination, adapters, route_name) do
    path = "webhooks.routes.#{route_name}.destination"

    with {:ok, adapter} <- Map.fetch(adapters, destination.transport),
         {:ok, request} <-
           Request.new(%{
             conversation_ref: destination.conversation_ref,
             document: %{"message" => "configuration probe"},
             kind: :message,
             ref: "configuration-probe",
             source_item_ref: nil,
             thread_ref: destination.thread_ref,
             transport: destination.transport
           }),
         :ok <- validate_webhook_target(request, adapter.binding) do
      :ok
    else
      :error ->
        raise ArgumentError, "#{path}.transport has no configured delivery adapter"

      {:error, reason} ->
        raise ArgumentError, "invalid #{path}: #{inspect(reason)}"
    end
  end

  defp validate_webhook_target(%Request{transport: "slack"} = request, binding) do
    with {:ok, target} <- SlackTarget.parse(request),
         true <-
           is_map(binding[:workspaces]) and Map.has_key?(binding.workspaces, target.workspace_ref) do
      :ok
    else
      false -> {:error, :slack_workspace_not_configured}
      {:error, _reason} = error -> error
    end
  end

  defp validate_webhook_target(%Request{transport: "github"} = request, binding) do
    with {:ok, target} <- Target.parse(request),
         {:ok, configured} <- Map.fetch(binding[:bindings] || %{}, target.binding),
         true <- configured.repository_id == target.repository_id do
      :ok
    else
      :error -> {:error, :github_binding_not_configured}
      false -> {:error, :github_repository_not_configured}
      {:error, _reason} = error -> error
    end
  end

  defp validate_webhook_target(
         %Request{
           transport: "control_plane",
           conversation_ref: "control-plane:lab:" <> conversation_id = conversation_ref,
           thread_ref: conversation_ref
         },
         _binding
       ) do
    case ConversationLab.conversation_ref(conversation_id) do
      {:ok, ^conversation_ref} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_webhook_target(%Request{transport: transport}, _binding),
    do: {:error, {:delivery_adapter_not_supported, transport}}

  defp webhook_auth!(value, env_provider, path) do
    object = object!(value, ~w(kind secret_env), [], path)
    secret = required_secret!(object["secret_env"], env_provider, path)

    case object["kind"] do
      "bearer" -> {:bearer, secret}
      "hmac_sha256" -> {:hmac_sha256, secret}
      _other -> raise ArgumentError, "#{path}.kind must be bearer or hmac_sha256"
    end
  end

  defp destination!(value, path) do
    object = object!(value, ~w(transport conversation_ref thread_ref), [], path)

    %{
      conversation_ref: reference!(object["conversation_ref"], "#{path}.conversation_ref"),
      thread_ref: optional_reference!(object["thread_ref"], "#{path}.thread_ref"),
      transport: adapter_name!(object["transport"], "#{path}.transport")
    }
  end

  defp work_profile!(value, path, repository_contexts) do
    object =
      object!(
        value,
        ~w(policy policy_digest repository_ref),
        ~w(authority_digest class_policies),
        path
      )

    context_ref = object["repository_ref"]

    placement =
      if is_nil(context_ref) do
        nil
      else
        Map.get(repository_contexts, context_ref) ||
          raise ArgumentError, "#{path}.repository_ref names an unknown repository context"
      end

    repository_ref =
      if placement, do: placement.work_profile.repository_ref, else: nil

    repository_context =
      if placement, do: Map.get(placement.work_profile, :repository_context), else: nil

    case WorkProfile.new(%{
           class_policies: class_policies!(object["class_policies"], "#{path}.class_policies"),
           authority_digest: object["authority_digest"],
           policy: object["policy"],
           policy_digest: object["policy_digest"],
           repository_context: repository_context,
           repository_ref: repository_ref
         }) do
      {:ok, profile} -> profile
      {:error, reason} -> raise ArgumentError, "invalid #{path}: #{inspect(reason)}"
    end
  end

  defp class_policies!(nil, _path), do: nil

  defp class_policies!(value, path) do
    policies = object!(value, ~w(conversational standard deep), [], path)

    Map.new(~w(conversational standard deep), fn work_class ->
      policy =
        object!(
          policies[work_class],
          ~w(policy policy_digest),
          ~w(authority_digest),
          "#{path}.#{work_class}"
        )

      {String.to_existing_atom(work_class),
       %{
         authority_digest: policy["authority_digest"],
         policy: policy["policy"],
         policy_digest: policy["policy_digest"]
       }}
    end)
  end

  defp repository_work_profile(repository_ref, repository) do
    %{
      class_policies: %{
        conversational: policy_profile(repository.conversation_policy),
        deep: policy_profile(repository.deep_policy),
        standard: policy_profile(repository.standard_policy)
      },
      authority_digest: Map.get(repository.conversation_policy, :authority_digest),
      policy: repository.conversation_policy.name,
      policy_digest: repository.conversation_policy.digest,
      repository_ref: repository_ref
    }
  end

  defp repository_set_work_profile(context_ref, set) do
    %{
      class_policies: %{
        conversational: policy_profile(set.conversation_policy),
        deep: policy_profile(set.deep_policy),
        standard: policy_profile(set.standard_policy)
      },
      authority_digest: Map.get(set.conversation_policy, :authority_digest),
      policy: set.conversation_policy.name,
      policy_digest: set.conversation_policy.digest,
      repository_context: repository_context(context_ref, set),
      repository_ref: set.primary_repository
    }
  end

  defp repository_context(context_ref, set) do
    %{
      context_ref: context_ref,
      parallel_goal_limit: set.parallel_goal_limit,
      primary_repository: set.primary_repository,
      read_only_repositories: set.read_only_repositories
    }
  end

  defp repository_context_document(context_ref, set) do
    context_ref
    |> repository_context(set)
    |> WorkProfile.repository_context_document()
  end

  defp known_repository!(value, repositories, path) do
    repository_ref = reference!(value, path)

    if Map.has_key?(repositories, repository_ref),
      do: repository_ref,
      else: raise(ArgumentError, "#{path} references an unknown repository")
  end

  defp policy_profile(policy) do
    %{policy: policy.name, policy_digest: policy.digest}
    |> maybe_put_policy_authority(Map.get(policy, :authority_digest))
  end

  defp validate_class_policy_authority!(policies, path) do
    identities = Enum.map(policies, &{&1.name, &1.digest}) |> Enum.uniq()
    authorities = Enum.map(policies, &Map.get(&1, :authority_digest)) |> Enum.uniq()

    unless length(identities) == 1 or
             match?([authority] when is_binary(authority), authorities) do
      raise ArgumentError,
            "#{path} conversational, standard, and deep policies must share one authority_digest"
    end
  end

  defp maybe_put_policy_authority(policy, nil), do: policy
  defp maybe_put_policy_authority(policy, digest), do: Map.put(policy, :authority_digest, digest)

  defp optional_policy!(nil, fallback, _path), do: fallback
  defp optional_policy!(value, _fallback, path), do: policy!(value, path)

  defp validate_runtimes!(configuration) do
    Responder.Admission.Runtime.options!(configuration.admission)
    if configuration[:learning], do: Responder.Learning.Runtime.options!(configuration.learning)
    Responder.Work.Runtime.options!(configuration.work)

    validate_platform_runtimes(configuration)
    validate_state_runtimes(configuration)
    validate_edge_runtimes(configuration)

    configuration
  end

  defp validate_platform_runtimes(configuration) do
    if configuration[:slack], do: Responder.Slack.Runtime.options!(configuration.slack)
    if configuration[:github], do: Runtime.options!(configuration.github)
    if configuration[:delivery], do: Responder.Delivery.Runtime.options!(configuration.delivery)

    if configuration[:publication],
      do: Responder.Publication.Runtime.options!(configuration.publication)

    if configuration[:retention],
      do: Responder.Retention.Runtime.options!(configuration.retention)
  end

  defp validate_state_runtimes(configuration) do
    if configuration[:emisar], do: ApprovalRuntime.options!(configuration.emisar)

    if configuration[:state_tools],
      do: Responder.StateTools.Server.options!(configuration.state_tools)

    if configuration[:schedules],
      do: ScheduleRuntime.options!(configuration.schedules)
  end

  defp validate_edge_runtimes(configuration) do
    if configuration[:webhooks], do: Responder.Webhooks.Server.options!(configuration.webhooks)

    if configuration[:control_plane],
      do: ControlPlaneServer.options!(configuration.control_plane)
  end

  defp json_client!(base_url, receive_timeout, token_provider, path) do
    case JSONClient.new(%{
           base_url: base_url,
           finch: Responder.CoopFinch,
           receive_timeout: receive_timeout,
           token_provider: token_provider
         }) do
      {:ok, client} -> client
      {:error, reason} -> raise ArgumentError, "invalid #{path}: #{inspect(reason)}"
    end
  end

  defp emisar_endpoint!(value, path) do
    value = reference!(value, path)

    case URI.parse(value) do
      %URI{
        scheme: "https",
        host: host,
        path: rpc_path,
        query: nil,
        fragment: nil,
        userinfo: nil
      } = uri
      when is_binary(host) and host != "" and is_binary(rpc_path) and rpc_path != "" ->
        origin =
          uri
          |> Map.put(:path, nil)
          |> Map.put(:query, nil)
          |> Map.put(:fragment, nil)
          |> URI.to_string()

        %{origin: String.trim_trailing(origin, "/"), path: rpc_path, url: URI.to_string(uri)}

      _invalid ->
        raise ArgumentError, "#{path} must be an exact HTTPS RPC URL"
    end
  end

  defp https_origin!(value, path) do
    value = reference!(value, path)

    case URI.parse(value) do
      %URI{
        scheme: "https",
        host: host,
        path: uri_path,
        query: nil,
        fragment: nil,
        userinfo: nil
      } = uri
      when is_binary(host) and host != "" and uri_path in [nil, "", "/"] ->
        uri |> Map.put(:path, nil) |> URI.to_string() |> String.trim_trailing("/")

      _invalid ->
        raise ArgumentError, "#{path} must be an exact HTTPS origin"
    end
  end

  defp coop_client!(coop, path) do
    case Responder.Coop.Client.new(%{
           finch: Responder.CoopFinch,
           receive_timeout: coop.receive_timeout_ms,
           socket: coop.socket
         }) do
      {:ok, client} -> client
      {:error, reason} -> raise ArgumentError, "invalid #{path}: #{inspect(reason)}"
    end
  end

  defp fleet_client!(workspace_ref, capabilities, receive_timeout_ms, poll_interval_ms) do
    max_waits = max(div(receive_timeout_ms + poll_interval_ms - 1, poll_interval_ms), 1)

    case Responder.CoopFleet.Client.new(
           capability_names: capabilities,
           capability_versions: %{"repository-freshness" => "2"},
           max_waits: max_waits,
           poll_interval_ms: poll_interval_ms,
           workspace_ref: workspace_ref
         ) do
      {:ok, client} -> {Responder.CoopFleet.Client, client}
      {:error, reason} -> raise ArgumentError, "invalid fleet Work client: #{inspect(reason)}"
    end
  end

  defp github_client!(http, path) do
    case Client.new(http: http, requester: JSONClient) do
      {:ok, client} -> client
      {:error, reason} -> raise ArgumentError, "invalid #{path}: #{inspect(reason)}"
    end
  end

  defp token_provider!(name, env_provider, path) do
    name = environment_name!(name, path)

    fn ->
      case env_provider.(name) do
        {:ok, value} when is_binary(value) and byte_size(value) in 1..4_096 -> {:ok, value}
        {:ok, _invalid} -> {:error, {:invalid_environment_secret, name}}
        :error -> {:error, {:environment_variable_missing, name}}
        other -> {:error, {:invalid_environment_provider, name, other}}
      end
    end
  end

  defp required_secret!(name, env_provider, path) do
    name = environment_name!(name, path)

    case env_provider.(name) do
      {:ok, value} when is_binary(value) and byte_size(value) in 16..4_096 ->
        if String.valid?(value),
          do: value,
          else: raise(ArgumentError, "environment variable #{name} for #{path} is invalid")

      {:ok, _invalid} ->
        raise ArgumentError, "environment variable #{name} for #{path} is invalid"

      :error ->
        raise ArgumentError, "environment variable #{name} for #{path} is missing"

      other ->
        raise ArgumentError,
              "environment provider returned #{inspect(other)} for #{name} at #{path}"
    end
  end

  defp environment_name!(value, path) do
    if is_binary(value) and Regex.match?(~r/\A[A-Z][A-Z0-9_]{0,127}\z/, value),
      do: value,
      else: raise(ArgumentError, "#{path} must name a bounded environment variable")
  end

  defp object!(value, required, optional, path) when is_map(value) do
    keys = Map.keys(value)
    allowed = required ++ optional

    unless Enum.all?(keys, &is_binary/1),
      do: raise(ArgumentError, "#{path} keys must be strings")

    unknown = keys -- allowed
    missing = required -- keys

    cond do
      unknown != [] ->
        raise ArgumentError, "#{path} contains unknown fields: #{Enum.join(unknown, ", ")}"

      missing != [] ->
        raise ArgumentError, "#{path} is missing fields: #{Enum.join(missing, ", ")}"

      true ->
        value
    end
  end

  defp object!(_value, _required, _optional, path),
    do: raise(ArgumentError, "#{path} must be a map")

  defp optional(root, key, callback) do
    case Map.get(root, key) do
      nil -> nil
      value -> callback.(value)
    end
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp policy!(value, path) do
    object = object!(value, ~w(name digest), ~w(authority_digest), path)
    name = reference!(object["name"], "#{path}.name")
    digest = object["digest"]

    unless is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
      do: raise(ArgumentError, "#{path}.digest must be a lowercase SHA-256 digest")

    authority_digest = object["authority_digest"]

    unless is_nil(authority_digest) or
             (is_binary(authority_digest) and
                Regex.match?(~r/\A[0-9a-f]{64}\z/, authority_digest)),
           do: raise(ArgumentError, "#{path}.authority_digest must be a lowercase SHA-256 digest")

    %{digest: digest, name: name}
    |> maybe_put_policy_authority(authority_digest)
  end

  defp fetch_repository!(repositories, name, path) do
    case Map.fetch(repositories, name) do
      {:ok, repository} -> repository
      :error -> raise ArgumentError, "#{path} references unknown repository #{inspect(name)}"
    end
  end

  defp fetch_binding!(bindings, name, path) do
    case Map.fetch(bindings, name) do
      {:ok, binding} -> binding
      :error -> raise ArgumentError, "#{path} references unknown GitHub binding #{inspect(name)}"
    end
  end

  defp map_nonempty!(value, _path) when is_map(value) and map_size(value) > 0, do: value
  defp map_nonempty!(_value, path), do: raise(ArgumentError, "#{path} must be a nonempty map")

  defp references!(values, path) when is_list(values) do
    prepared = Enum.map(values, &reference!(&1, path))

    if Enum.uniq(prepared) == prepared,
      do: prepared,
      else: raise(ArgumentError, "#{path} must not contain duplicates")
  end

  defp references!(_values, path), do: raise(ArgumentError, "#{path} must be a list")

  defp source_and_action_tools!(nil), do: nil

  defp source_and_action_tools!(values) do
    tools = references!(values, "work.source_and_action_tools")

    if length(tools) <= 256,
      do: tools,
      else: raise(ArgumentError, "work.source_and_action_tools must contain at most 256 names")
  end

  defp positive_ids!(values, path) when is_list(values) and values != [] do
    prepared = Enum.map(values, &positive_integer!(&1, path))

    if Enum.uniq(prepared) == prepared,
      do: prepared,
      else: raise(ArgumentError, "#{path} must not contain duplicates")
  end

  defp positive_ids!(_values, path),
    do: raise(ArgumentError, "#{path} must be a nonempty list")

  defp reference!(value, path) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: value,
       else: raise(ArgumentError, "#{path} must be a bounded nonblank string")
  end

  defp optional_reference!(nil, _path), do: nil
  defp optional_reference!(value, path), do: reference!(value, path)

  defp adapter_name!(value, path) do
    if is_binary(value) and Regex.match?(~r/\A[a-z][a-z0-9_-]{0,63}\z/, value),
      do: value,
      else: raise(ArgumentError, "#{path} must be a platform adapter name")
  end

  defp absolute_path!(value, path) do
    value = reference!(value, path)

    if Path.type(value) == :absolute,
      do: value,
      else: raise(ArgumentError, "#{path} must be absolute")
  end

  defp github_repository!(value, path) do
    if is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, value),
      do: value,
      else: raise(ArgumentError, "#{path} must be owner/repository")
  end

  defp git_ref!(value, path) do
    value = reference!(value, path)

    invalid =
      byte_size(value) > 240 or String.starts_with?(value, ["-", "/"]) or
        String.ends_with?(value, ["/", "."]) or
        String.contains?(value, ["..", "@{", " ", "~", "^", ":", "?", "*", "[", "\\"])

    if invalid, do: raise(ArgumentError, "#{path} must be a safe Git ref"), else: value
  end

  defp email!(value, path) do
    value = reference!(value, path)

    if byte_size(value) <= 320 and Regex.match?(~r/\A[^\s@]+@[^\s@]+\z/, value),
      do: value,
      else: raise(ArgumentError, "#{path} must be an email address")
  end

  defp positive_integer!(value, _path) when is_integer(value) and value > 0, do: value
  defp positive_integer!(_value, path), do: raise(ArgumentError, "#{path} must be positive")

  defp positive_port!(value, path) do
    if is_integer(value) and value in 1..65_535,
      do: value,
      else: raise(ArgumentError, "#{path} must be between 1 and 65535")
  end

  defp integer!(object, key, default, minimum, maximum, path) do
    value = Map.get(object, key, default)

    if is_integer(value) and value >= minimum and value <= maximum,
      do: value,
      else: raise(ArgumentError, "#{path}.#{key} is outside its safe bound")
  end

  defp boolean!(value, _path) when is_boolean(value), do: value
  defp boolean!(_value, path), do: raise(ArgumentError, "#{path} must be boolean")

  defp ip!(value, path) do
    with value when is_binary(value) <- value,
         {:ok, address} <- :inet.parse_address(String.to_charlist(value)) do
      address
    else
      _invalid -> raise ArgumentError, "#{path} must be an IPv4 or IPv6 address"
    end
  end
end
