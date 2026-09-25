defmodule Ryker.Runtime.Assembly do
  @moduledoc """
  Builds the running child configuration from bootstrap, code defaults and
  durable settings.

  This is the only place product settings become runtime bindings. It performs
  no database writes and no network calls: credentials stay behind lazy
  providers, policy digests come from reviewed bindings rather than from a form,
  and a domain whose required settings are absent is simply not started. An
  integration is enabled by its saved connection, never by the presence of a
  credential in the environment.
  """

  alias Ryker.Bootstrap
  alias Ryker.ControlPlane.CapabilityTools, as: ControlPlaneCapabilityTools
  alias Ryker.ControlPlane.ConversationLab
  alias Ryker.Credentials
  alias Ryker.Defaults
  alias Ryker.Delivery.{JSONClient, Request}

  alias Ryker.GitHub.{
    AppJWT,
    Binding,
    Client,
    Confirmations,
    InstallationTokens,
    Publisher,
    RepositoryAccess,
    Target
  }

  alias Ryker.GitHub.CapabilityTools, as: GitHubCapabilityTools
  alias Ryker.Ingress.WorkProfile
  alias Ryker.Publication.{Git, GitCommand, GitHubPublisher}
  alias Ryker.Settings.Environment
  alias Ryker.Slack.ActionTokens
  alias Ryker.Slack.CapabilityTools, as: SlackCapabilityTools
  alias Ryker.Slack.Client, as: SlackClient
  alias Ryker.Slack.Target, as: SlackTarget
  alias Ryker.Work.RepositoryContext

  # Every runtime the owner starts, in dependency order, with the module that
  # validates its configuration here and runs it there. One list, so a runtime
  # cannot be assembled without being started or started without being checked.
  @runtimes [
    {:coop_worker_gateway, Ryker.CoopFleet.Server},
    {:state_tools, Ryker.StateTools.Server},
    {:admission, Ryker.Admission.Runtime},
    {:work, Ryker.Work.Runtime},
    {:learning, Ryker.Learning.Runtime},
    {:retention, Ryker.Retention.Runtime},
    {:github, Ryker.GitHub.Runtime},
    {:publication, Ryker.Publication.Runtime},
    {:delivery, Ryker.Delivery.Runtime},
    {:emisar, Ryker.Emisar.Runtime},
    {:event_waits, Ryker.State.EventWaitWorker},
    {:schedules, Ryker.State.ScheduleRuntime},
    {:slack, Ryker.Slack.Runtime},
    {:webhooks, Ryker.Webhooks.Server},
    {:control_plane, Ryker.ControlPlane.Server}
  ]
  # Published beside the runtimes: read by whoever asks, started by nobody.
  @published_facts [:execution_mode, :fleet_profiles]
  @managed_keys Enum.sort(Keyword.keys(@runtimes) ++ @published_facts)

  @spec runtimes() :: [{atom(), module()}]
  def runtimes, do: @runtimes

  @spec managed_keys() :: [atom()]
  def managed_keys, do: @managed_keys

  @doc """
  Publishes an assembled configuration as the process-wide applied snapshot.

  Readers resolve behaviour from here, so this is the last step of a successful
  apply and never of a failed one. A key absent from the configuration is
  deleted rather than left holding a previous deployment's value.
  """
  @spec publish(map()) :: :ok
  def publish(configuration) do
    Enum.each(@managed_keys, fn key ->
      case Map.fetch(configuration, key) do
        {:ok, value} -> Application.put_env(:ryker, key, value, persistent: true)
        :error -> Application.delete_env(:ryker, key, persistent: true)
      end
    end)
  end

  @doc """
  Assembles every configured runtime, or reports the first refusal.

  A refusal names the setting that is wrong, never its value.
  """
  @spec build(Bootstrap.t(), map()) :: {:ok, map()} | {:error, term()}
  def build(%Bootstrap{} = bootstrap, settings) do
    {:ok, assemble(bootstrap, settings)}
  rescue
    error in ArgumentError -> {:error, {:settings_not_applicable, error.message}}
  end

  defp assemble(bootstrap, settings) do
    policies = index_policies(settings.policy_bindings)
    repositories = repositories(settings, policies)
    outside = outside_profile(policies)
    environments = environments(settings, repositories, policies, outside)
    chat = chat_profile(settings, environments, outside)
    work = work(settings)
    admission = admission(settings, policies, work)
    learning = learning(settings, policies, work)
    schedules = schedules(settings, repositories, policies)
    gateway = worker_gateway(bootstrap)
    github = github(bootstrap, settings, repositories, environments)
    slack = slack(bootstrap, settings, environments, schedules, policies, outside)
    control_plane = control_plane(bootstrap, settings, environments, work, schedules, chat)
    adapters = adapters(slack, github, control_plane)
    delivery = delivery(settings, adapters)
    publication = publication(bootstrap, settings, work, repositories, github, adapters)
    emisar = emisar(bootstrap, settings, adapters, slack, github)
    webhooks = webhooks(bootstrap, settings, adapters, repositories, environments)
    retention = retention(settings, work, learning)

    state_tools =
      state_tools(bootstrap, settings, emisar, slack, github, control_plane, %{
        emisar_approvals: not is_nil(emisar),
        event_waits: true,
        publication: not is_nil(publication),
        schedules: not is_nil(schedules)
      })

    {work, gateway} = bind_state_tools(work, gateway, state_tools)

    %{
      execution_mode: Defaults.execution(),
      fleet_profiles: fleet_profiles(repositories, environments, admission, outside)
    }
    |> put_optional(:work, work)
    |> put_optional(:admission, admission)
    |> put_optional(:control_plane, control_plane)
    |> put_optional(:coop_worker_gateway, gateway)
    |> put_optional(:delivery, delivery)
    |> put_optional(:emisar, emisar)
    |> put_optional(:event_waits, Defaults.fetch!(:event_waits))
    |> put_optional(:github, github && github.runtime)
    |> put_optional(:learning, learning)
    |> put_optional(:publication, publication)
    |> put_optional(:retention, retention)
    |> put_optional(:schedules, schedules)
    |> put_optional(:slack, slack && slack.runtime)
    |> put_optional(:state_tools, state_tools)
    |> put_optional(:webhooks, webhooks)
    |> validate_runtimes!()
  end

  # Policies ------------------------------------------------------------------

  defp index_policies(bindings) do
    Map.new(bindings, fn binding ->
      {{binding.purpose, binding.scope_kind, binding.scope_ref},
       %{name: binding.policy_name, digest: binding.policy_digest}
       |> put_optional(:authority_digest, binding.authority_digest)}
    end)
  end

  defp policy(policies, purpose, scope_kind, scope_ref),
    do: Map.get(policies, {purpose, scope_kind, scope_ref})

  defp installation_policy(policies, purpose), do: policy(policies, purpose, :installation, "")

  # Repositories and environments ---------------------------------------------

  # A repository is usable when reviewed bindings name at least its
  # conversation and contributor policies; its other classes fall back to them.
  defp repositories(settings, policies) do
    bindings = Map.new(settings.github_bindings, &{&1.repository_ref, &1})

    settings.repositories
    |> Enum.flat_map(fn repository ->
      conversation = policy(policies, :conversational, :repository, repository.ref)
      contributor = policy(policies, :contributor, :repository, repository.ref)

      if conversation && contributor do
        standard = policy(policies, :standard, :repository, repository.ref) || conversation
        deep = policy(policies, :deep, :repository, repository.ref) || standard

        [
          {repository.ref,
           %{
             base_branch: repository.base_branch,
             contributor_policy: contributor,
             conversation_policy: conversation,
             deep_policy: deep,
             github_binding: bindings[repository.ref] && bindings[repository.ref].name,
             github_repository: repository.github_repository,
             path: repository.publication_checkout_path,
             schedule_policy: policy(policies, :schedule, :repository, repository.ref),
             standard_policy: standard
           }}
        ]
      else
        []
      end
    end)
    |> Map.new()
  end

  # Every environment that can run work, by ref. Work in one changes its first
  # repository and reads the others; an environment without repositories runs
  # on the installation's own policy and mounts nothing. An environment whose
  # writable repository is not usable, or which lacks the policies it needs,
  # runs nothing and is left out.
  defp environments(settings, repositories, policies, outside) do
    settings.environments
    |> Enum.flat_map(fn environment ->
      case environment_entry(environment, repositories, policies, outside) do
        nil -> []
        entry -> [{environment.ref, entry}]
      end
    end)
    |> Map.new()
  end

  defp environment_entry(environment, repositories, policies, outside) do
    case Environment.repository_refs(environment) do
      [] ->
        outside && workspace_free_entry(environment, outside)

      [writable | read_only] ->
        with %{} = repository <- Map.get(repositories, writable),
             %{} = classes <- environment_policies(environment, read_only, repository, policies) do
          repository_entry(environment, writable, read_only, repository, classes)
        end
    end
  end

  # An environment's own reviewed bindings decide its policies: Coop mounts the
  # read-only repositories only for a policy that declares them. One with a
  # single repository and no bindings of its own runs on that repository's.
  defp environment_policies(environment, read_only, repository, policies) do
    conversation = policy(policies, :conversational, :environment, environment.ref)
    contributor = policy(policies, :contributor, :environment, environment.ref)

    cond do
      conversation && contributor ->
        standard = policy(policies, :standard, :environment, environment.ref) || conversation
        deep = policy(policies, :deep, :environment, environment.ref) || standard

        %{contributor: contributor, conversation: conversation, deep: deep, standard: standard}

      read_only == [] ->
        %{
          contributor: repository.contributor_policy,
          conversation: repository.conversation_policy,
          deep: repository.deep_policy,
          standard: repository.standard_policy
        }

      true ->
        nil
    end
  end

  defp repository_entry(environment, writable, read_only, repository, classes) do
    context =
      RepositoryContext.document(%{
        context_ref: environment.ref,
        parallel_goal_limit: environment.parallel_goal_limit,
        primary_repository: writable,
        read_only_repositories: read_only
      })

    %{
      contributor_policy:
        Map.merge(classes.contributor, %{
          environment_ref: environment.ref,
          repository_context: context,
          repository_ref: writable
        }),
      display_name: environment.display_name,
      github_repository: repository.github_repository,
      work_profile:
        classes.conversation
        |> class_profile(classes.standard, classes.deep)
        |> Map.merge(%{
          emisar_connection_ref: environment.emisar_connection_ref,
          environment_ref: environment.ref,
          parallel_goal_limit: environment.parallel_goal_limit,
          read_only_repository_refs: read_only,
          repository_ref: writable
        })
    }
  end

  defp workspace_free_entry(environment, outside) do
    %{
      contributor_policy: nil,
      display_name: environment.display_name,
      github_repository: nil,
      work_profile:
        Map.merge(outside, %{
          emisar_connection_ref: environment.emisar_connection_ref,
          environment_ref: environment.ref,
          parallel_goal_limit: environment.parallel_goal_limit
        })
    }
  end

  # A repository run on its own, outside any environment: GitHub events for a
  # repository no usable environment contains, and tasks that change it.
  defp repository_alone(ref, repository) do
    %{
      contributor_policy: Map.put(repository.contributor_policy, :repository_ref, ref),
      display_name: ref,
      github_repository: repository.github_repository,
      work_profile:
        repository.conversation_policy
        |> class_profile(repository.standard_policy, repository.deep_policy)
        |> Map.put(:repository_ref, ref)
    }
  end

  defp class_profile(conversation, standard, deep) do
    %{
      authority_digest: Map.get(conversation, :authority_digest),
      class_policies: %{
        conversational: class_policy(conversation),
        deep: class_policy(deep),
        standard: class_policy(standard)
      },
      policy: conversation.name,
      policy_digest: conversation.digest
    }
  end

  # Work outside any environment: the installation's own conversation policy,
  # no repository, no Emisar account.
  defp outside_profile(policies) do
    case installation_policy(policies, :conversational) do
      nil ->
        nil

      policy ->
        class = class_policy(policy)

        %{
          authority_digest: Map.get(policy, :authority_digest),
          class_policies: %{conversational: class, deep: class, standard: class},
          policy: policy.name,
          policy_digest: policy.digest,
          repository_ref: nil
        }
    end
  end

  # Chat runs in the default environment, and outside any when none is chosen
  # or the chosen one cannot run work.
  defp chat_profile(settings, environments, outside) do
    case default_environment(settings, environments) do
      nil -> outside
      ref -> Map.fetch!(environments, ref).work_profile
    end
  end

  defp default_environment(settings, environments) do
    case Environment.default(settings) do
      %Environment{ref: ref} when is_map_key(environments, ref) -> ref
      _none_or_unusable -> nil
    end
  end

  defp saved_default_environment(settings) do
    case Environment.default(settings) do
      %Environment{ref: ref} -> ref
      nil -> nil
    end
  end

  # GitHub events for a repository run in the environment
  # `Environment.for_repository/2` names among those that can run work, else
  # on the repository alone.
  defp github_entry(repository_ref, settings, repositories, environments) do
    usable = Enum.filter(settings.environments, &Map.has_key?(environments, &1.ref))

    case Environment.for_repository(usable, repository_ref) do
      %Environment{ref: ref} ->
        Map.fetch!(environments, ref)

      nil ->
        case Map.fetch(repositories, repository_ref) do
          {:ok, repository} -> repository_alone(repository_ref, repository)
          :error -> nil
        end
    end
  end

  # A confirmed task changes the repository it names, so it runs where that
  # repository is writable: the first environment (by ref) whose writable
  # repository it is, else on the repository alone.
  defp task_entries(settings, repositories, environments) do
    Map.new(repositories, fn {ref, repository} ->
      writable_in =
        settings.environments
        |> Enum.sort_by(& &1.ref)
        |> Enum.find(fn environment ->
          Map.has_key?(environments, environment.ref) and
            Environment.writable_repository(environment) == ref
        end)

      entry =
        if writable_in,
          do: Map.fetch!(environments, writable_in.ref),
          else: repository_alone(ref, repository)

      {ref, entry}
    end)
  end

  defp fleet_profiles(repositories, environments, admission, outside) do
    repository_profiles =
      Enum.flat_map(repositories, fn {ref, repository} ->
        [
          {{"read_only", ref}, profile_entry(repository.conversation_policy, ref)},
          {{"repository_write", ref}, profile_entry(repository.contributor_policy, ref)}
        ]
      end)

    environment_profiles =
      Enum.flat_map(environments, fn
        {ref, %{contributor_policy: %{} = contributor, work_profile: profile}} ->
          [
            {{"environment_read_only", ref},
             Map.take(profile, [:authority_digest, :policy, :policy_digest, :repository_ref])},
            {{"environment_write", ref}, profile_entry(contributor, contributor.repository_ref)}
          ]

        {_ref, _workspace_free} ->
          []
      end)

    base =
      []
      |> maybe_profile("admission", admission)
      |> maybe_profile("conversation", outside)

    Map.new(base ++ repository_profiles ++ environment_profiles)
  end

  defp maybe_profile(profiles, _kind, nil), do: profiles

  defp maybe_profile(profiles, kind, profile) do
    [
      {kind, Map.take(profile, [:authority_digest, :policy, :policy_digest, :repository_ref])}
      | profiles
    ]
  end

  # A reviewed binding names the policy; a Work profile pins it per work class.
  defp class_policy(policy) do
    %{policy: policy.name, policy_digest: policy.digest}
    |> put_optional(:authority_digest, Map.get(policy, :authority_digest))
  end

  defp profile_entry(policy, ref) do
    %{policy: policy.name, policy_digest: policy.digest, repository_ref: ref}
    |> put_optional(:authority_digest, Map.get(policy, :authority_digest))
  end

  # Execution lanes ------------------------------------------------------------

  # Work is placeable only when the build uses the fleet and an operator has
  # selected an enrolled workspace. An isolated topology has no Work lane to
  # assemble, and an unselected workspace is unconfigured, not a failure.
  defp work(settings) do
    if Defaults.execution() == :fleet and is_binary(settings.work.workspace_ref) do
      defaults = Defaults.fetch!(:work)
      coop = Defaults.fetch!(:coop)

      {api, client} =
        fleet_client!(
          settings.work.workspace_ref,
          defaults.capability_names,
          coop.receive_timeout_ms,
          defaults.poll_interval_ms
        )

      %{
        api: api,
        client: client,
        concurrency: defaults.concurrency,
        poll_interval_ms: defaults.poll_interval_ms,
        receive_timeout_ms: coop.receive_timeout_ms,
        worker_ref: "#{settings.installation.host_ref}:work"
      }
    end
  end

  defp admission(settings, policies, work) do
    with %{} = policy <- installation_policy(policies, :admission),
         %{api: _api} <- work do
      defaults = Defaults.fetch!(:admission)

      %{
        api: work.api,
        client: work.client,
        concurrency: defaults.concurrency,
        decision_timeout_ms: defaults.decision_timeout_ms,
        policy: policy.name,
        policy_digest: policy.digest,
        poll_interval_ms: defaults.poll_interval_ms,
        receive_timeout_ms: Defaults.fetch!(:coop).receive_timeout_ms,
        worker_ref: "#{settings.installation.host_ref}:admission"
      }
    else
      _unconfigured -> nil
    end
  end

  defp learning(settings, policies, work) do
    with true <- settings.learning.enabled,
         %{} = policy <- installation_policy(policies, :learning),
         %{api: _api} <- work do
      defaults = Defaults.fetch!(:learning)

      defaults
      |> Map.merge(%{
        api: work.api,
        client: work.client,
        policy: policy.name,
        policy_digest: policy.digest,
        receive_timeout_ms: min(Defaults.fetch!(:coop).receive_timeout_ms, 30_000),
        worker_ref: "#{settings.installation.host_ref}:learning"
      })
    else
      _disabled -> nil
    end
  end

  defp schedules(settings, repositories, policies) do
    with %{} = read_only <- installation_policy(policies, :schedule_read_only),
         %{} = governed <- installation_policy(policies, :schedule_governed) do
      schedule_repositories =
        repositories
        |> Enum.flat_map(fn
          {ref, %{schedule_policy: %{} = policy}} -> [{ref, policy}]
          _missing -> []
        end)
        |> Map.new()

      Defaults.fetch!(:schedules)
      |> Map.merge(%{
        governed_operation_policy: governed,
        read_only_policy: read_only,
        repositories: schedule_repositories,
        worker_ref: "#{settings.installation.host_ref}:schedules"
      })
    else
      _unconfigured -> nil
    end
  end

  defp retention(_settings, nil, _learning), do: nil

  defp retention(settings, work, learning) do
    learning_adapter = learning || work

    Defaults.fetch!(:retention)
    |> Map.merge(
      Map.take(settings.retention, [
        :audit_data_seconds,
        :closed_work_seconds,
        :conversation_memory_seconds,
        :episode_history_seconds,
        :operational_data_seconds
      ])
    )
    |> Map.merge(%{
      api: work.api,
      client: work.client,
      learning_api: learning_adapter[:api],
      learning_client: learning_adapter[:client],
      worker_ref: "#{settings.installation.host_ref}:retention"
    })
  end

  # Transports -----------------------------------------------------------------

  defp worker_gateway(%Bootstrap{worker_gateway: nil}), do: nil

  defp worker_gateway(%Bootstrap{worker_gateway: gateway}) do
    gateway
    |> Map.take([:cacertfile, :ca_keyfile, :certfile, :keyfile, :ip, :port, :public_url])
    |> Map.merge(Defaults.fetch!(:coop_worker_gateway))
    |> Map.put(:checkpoint_key, Bootstrap.checkpoint_key!())
    |> Map.put(:checkpoint_secrets, credential_redaction_values())
  end

  defp github(_bootstrap, %{github: %{enabled: false}}, _repositories, _environments), do: nil

  # Credentials do not enable an integration and must not silently rebind one.
  # A connection saved for one app with the deployment holding another's key is
  # a mismatch an operator has to resolve, not a component that quietly does
  # not start.
  defp github(bootstrap, settings, repositories, environments),
    do: github_runtime(bootstrap, settings, repositories, environments)

  defp github_runtime(bootstrap, settings, repositories, environments) do
    app_id = settings.github.app_id

    defaults = Defaults.fetch!(:github)
    api_url = settings.github.api_url
    signer = app_signer!(app_id)

    app_http =
      json_client!(api_url, defaults.receive_timeout_ms, fn -> AppJWT.token(signer) end)

    prepared =
      Map.new(settings.github_bindings, fn binding ->
        entry = github_entry(binding.repository_ref, settings, repositories, environments)

        {binding.name, github_binding(binding, api_url, defaults, settings.repositories, entry)}
      end)

    confirmations =
      case task_entries(settings, repositories, environments) do
        entries when map_size(entries) == 0 ->
          nil

        entries ->
          Confirmations.options!(%{
            repositories:
              Map.new(entries, fn {ref, entry} ->
                {ref, %{contributor_policy: entry.contributor_policy}}
              end)
          })
      end

    capability_binding = %{
      bindings:
        Map.new(prepared, fn {name, item} ->
          {name,
           %{
             api: Client,
             client: item.client,
             ci_cancel_client: item.ci_cancel_client,
             ci_client: item.ci_client,
             ci_rerun_client: item.ci_rerun_client,
             grants: item.trusted_binding.action_grants,
             repository_ref: item.repository_alias,
             review_client: item.review_client,
             repository_full_name: item.repository.github_repository,
             repository_id: item.trusted_binding.repository_id
           }}
        end)
    }

    delivery_binding = %{
      bindings:
        Map.new(prepared, fn {name, item} ->
          {name,
           %{
             api: Client,
             client: item.delivery_client,
             repository_full_name: item.repository.github_repository,
             repository_id: item.trusted_binding.repository_id
           }}
        end)
    }

    %{
      bindings: prepared,
      capability_tools: GitHubCapabilityTools.options!(capability_binding),
      delivery_binding: delivery_binding,
      receive_timeout_ms: defaults.receive_timeout_ms,
      runtime: %{
        onboarding: %{},
        server: %{
          bindings: Map.new(prepared, fn {name, item} -> {name, item.trusted_binding} end),
          bot_login: settings.github.app_slug,
          confirmations: confirmations,
          ip: bootstrap.github_listener.ip,
          port: bootstrap.github_listener.port,
          repository_access: fn binding, payload ->
            item = Map.fetch!(prepared, binding.name)
            RepositoryAccess.authorize(binding, payload, item.access_http)
          end,
          secret: credential!(:github_webhook, "primary")
        },
        tokens: %{
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
      }
    }
  end

  defp app_signer!(app_id) do
    private_key = :github_private_key |> credential!("primary") |> decode_private_key()

    case AppJWT.new(app_id, private_key) do
      {:ok, signer} -> signer
      {:error, _reason} -> raise ArgumentError, "The saved GitHub App private key is not usable"
    end
  end

  defp decode_private_key("-----BEGIN " <> _rest = key), do: key

  defp decode_private_key(encoded) do
    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) in 16..4_096 -> key
      _invalid -> encoded
    end
  end

  defp github_binding(binding, api_url, defaults, repositories, entry) do
    repository =
      Enum.find(repositories, &(&1.ref == binding.repository_ref)) ||
        raise ArgumentError, "github binding names an unknown repository"

    delivery_http =
      json_client!(api_url, defaults.receive_timeout_ms, fn ->
        InstallationTokens.token(binding.name, :delivery)
      end)

    access_http =
      json_client!(api_url, defaults.receive_timeout_ms, fn ->
        InstallationTokens.token(binding.name, :authorization)
      end)

    context_http =
      json_client!(api_url, defaults.receive_timeout_ms, fn ->
        InstallationTokens.token(binding.name, :context)
      end)

    review_http =
      json_client!(api_url, defaults.receive_timeout_ms, fn ->
        InstallationTokens.token(binding.name, :review)
      end)

    ci_rerun_http =
      json_client!(api_url, defaults.receive_timeout_ms, fn ->
        InstallationTokens.token(binding.name, :ci_rerun)
      end)

    ci_cancel_http =
      json_client!(api_url, defaults.receive_timeout_ms, fn ->
        InstallationTokens.token(binding.name, :ci_cancel)
      end)

    publication_http =
      json_client!(api_url, defaults.receive_timeout_ms, fn ->
        InstallationTokens.token(binding.name, :publication)
      end)

    {:ok, trusted_binding} =
      Binding.new(%{
        installation_id: binding.installation_id,
        max_body_bytes: defaults.max_body_bytes,
        name: binding.name,
        action_grants: binding.action_grants,
        repository_full_name: repository.github_repository,
        repository_id: binding.repository_id,
        ryker_actor_id: binding.ryker_actor_id,
        secret: credential!(:github_webhook, "primary"),
        work_profile: entry && entry.work_profile
      })

    %{
      access_http: access_http,
      client: github_client!(context_http),
      ci_client: github_client!(context_http),
      ci_rerun_client: github_client!(ci_rerun_http),
      ci_cancel_client: github_client!(ci_cancel_http),
      delivery_client: github_client!(delivery_http),
      review_client: github_client!(review_http),
      publication_client: github_client!(publication_http),
      repository: repository,
      repository_alias: binding.repository_ref,
      repository_write_token_provider: fn ->
        InstallationTokens.token(binding.name, :repository_write)
      end,
      trusted_binding: trusted_binding
    }
  end

  defp slack(_bootstrap, settings, environments, schedules, policies, outside) do
    with true <- settings.slack.enabled,
         %{} = incident_policy <- installation_policy(policies, :incident) do
      defaults = Defaults.fetch!(:slack)

      app_http =
        json_client!(
          defaults.api_url,
          defaults.receive_timeout_ms,
          Credentials.provider(:slack_app, "primary")
        )

      bot_http =
        json_client!(
          defaults.api_url,
          defaults.receive_timeout_ms,
          Credentials.provider(:slack_bot, "primary")
        )

      {:ok, bot_client} = SlackClient.new(http: bot_http, requester: JSONClient)

      runtime =
        defaults
        |> Map.drop([:api_url])
        |> Map.merge(%{
          app_http: app_http,
          bot_client: bot_client,
          channel_prefix: settings.slack.channel_prefix,
          # The saved default, even while it cannot run work yet: a channel
          # joined then is still set to it, and works in it once it can.
          default_environment: saved_default_environment(settings),
          default_participation: settings.slack.default_participation,
          environments: environments,
          fallback_work_profile: outside,
          identity: %{
            bot_ref: settings.slack.bot_ref,
            bot_user_ref: settings.slack.bot_user_ref,
            workspace_ref: settings.slack.workspace_ref
          },
          incident_policy: incident_policy,
          incident_private: settings.slack.incident_private,
          operators: settings.slack.operators,
          schedule_policies: schedules
        })

      %{
        capability_tools:
          SlackCapabilityTools.options!(%{
            action_tokens: {ActionTokens, ActionTokens},
            api: SlackClient,
            client: bot_client,
            workspace_ref: settings.slack.workspace_ref
          }),
        delivery_adapter: Ryker.Slack.Runtime.delivery_adapter!(runtime),
        runtime: runtime
      }
    else
      _disconnected -> nil
    end
  end

  defp control_plane(bootstrap, _settings, environments, work, schedules, chat) do
    %{
      access: Map.get(bootstrap.control_plane, :access, :loopback),
      coop_api: work && work.api,
      coop_client: work && work.client,
      ip: bootstrap.control_plane.ip,
      port: bootstrap.control_plane.port,
      schedule_policies: schedules,
      task_policies:
        for(
          {ref, %{contributor_policy: %{} = policy}} <- environments,
          into: %{},
          do: {ref, policy}
        ),
      work_profile: chat
    }
  end

  defp adapters(slack, github, control_plane) do
    %{}
    |> put_optional(
      "control_plane",
      control_plane &&
        %{
          binding: nil,
          message_publisher: Ryker.ControlPlane.Publisher,
          reaction_publisher: Ryker.ControlPlane.Publisher
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

  defp delivery(_settings, adapters) when map_size(adapters) == 0, do: nil

  defp delivery(settings, adapters) do
    Defaults.fetch!(:delivery)
    |> Map.merge(%{
      adapters: adapters,
      worker_ref: "#{settings.installation.host_ref}:delivery"
    })
  end

  # Publication runs authorized readiness reviews through the same Coop
  # authority Work uses; without a Work lane there is nothing to review with.
  defp publication(_bootstrap, _settings, nil, _repositories, _github, _adapters), do: nil

  defp publication(_bootstrap, _settings, _work, _repositories, _github, adapters)
       when map_size(adapters) == 0,
       do: nil

  defp publication(bootstrap, settings, work, repositories, github, adapters) do
    repositories =
      if settings.publication.enabled and github,
        do: publication_repositories(bootstrap, settings, repositories, github),
        else: %{}

    status_client = %{repositories: repositories}

    Defaults.fetch!(:publication)
    |> Map.merge(%{
      coop_api: work.api,
      coop_client: work.client,
      delivery_adapters: adapters,
      publisher: GitHubPublisher,
      publisher_binding: %{
        api: GitHubPublisher,
        client: status_client,
        git: Git,
        repositories: repositories
      },
      receive_timeout_ms: Defaults.fetch!(:coop).receive_timeout_ms,
      worker_ref: "#{settings.installation.host_ref}:publication"
    })
  end

  defp publication_repositories(bootstrap, settings, repositories, github) do
    common = %{
      branch_prefix: settings.publication.branch_prefix,
      command: GitCommand,
      commit_email: settings.publication.commit_email,
      commit_name: settings.publication.commit_name,
      secrets: [],
      state_dir: Path.join(bootstrap.storage_root, "publications")
    }

    repositories
    |> Enum.flat_map(fn {ref, repository} ->
      binding = repository.github_binding && Map.get(github.bindings, repository.github_binding)

      if binding && repository.path && repository.github_repository do
        [
          {ref,
           %{
             api: Client,
             base_branch: repository.base_branch,
             client: binding.publication_client,
             git_binding:
               Map.put(common, :token_provider, binding.repository_write_token_provider),
             github_repository: repository.github_repository,
             path: repository.path,
             ryker_actor_id: binding.trusted_binding.ryker_actor_id
           }}
        ]
      else
        []
      end
    end)
    |> Map.new()
  end

  defp emisar(_bootstrap, settings, adapters, slack, github) do
    connections =
      settings.emisar_connections
      |> Enum.filter(& &1.monitoring_enabled)
      |> Enum.map(fn connection ->
        defaults = Defaults.fetch!(:emisar)
        endpoint = rpc_endpoint!(connection.rpc_url)

        http =
          json_client!(
            endpoint.origin,
            defaults.receive_timeout_ms,
            Credentials.provider(:emisar, connection.ref)
          )

        {:ok, client} =
          Ryker.Emisar.Client.new(%{
            http: http,
            requester: JSONClient,
            rpc_origin: endpoint.origin,
            rpc_path: endpoint.path
          })

        defaults
        |> Map.delete(:receive_timeout_ms)
        |> Map.merge(%{
          api: Ryker.Emisar.Client,
          client: client,
          connection_ref: connection.ref,
          presentation: adapters,
          presentation_timeout_ms: presentation_timeout(slack, github),
          presenter: Ryker.Emisar.ApprovalPresenter,
          worker_ref: "#{settings.installation.host_ref}:emisar:#{connection.ref}"
        })
      end)

    if connections == [], do: nil, else: %{connections: connections}
  end

  defp presentation_timeout(slack, github) do
    [slack && slack.runtime.receive_timeout_ms, github && github.receive_timeout_ms]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> 0 end)
  end

  defp webhooks(bootstrap, settings, adapters, repositories, environments) do
    sources = Enum.filter(settings.webhook_sources, & &1.enabled)

    if sources == [] do
      nil
    else
      %{
        ip: bootstrap.webhook_listener.ip,
        port: bootstrap.webhook_listener.port,
        routes:
          Map.new(sources, fn source ->
            {source.name, webhook_route!(source, adapters, repositories, environments)}
          end)
      }
    end
  end

  defp webhook_route!(source, adapters, repositories, environments) do
    defaults = Defaults.fetch!(:webhooks)
    secret = credential!(:webhook, source.secret_name)

    environment =
      Map.get(environments, source.environment_ref) ||
        raise ArgumentError, "webhook source names an environment that cannot run work"

    destination = %{
      conversation_ref: source.destination_conversation_ref,
      thread_ref: source.destination_thread_ref,
      transport: source.destination_transport
    }

    route = %{
      adapter: webhook_adapter(source),
      auth: {source.auth_kind, secret},
      destination: destination,
      max_body_bytes: defaults.max_body_bytes,
      max_clock_skew_seconds: defaults.max_clock_skew_seconds,
      publication_lifecycle: webhook_lifecycle(source, repositories),
      work_profile: work_profile!(environment.work_profile)
    }

    validate_destination!(destination, adapters)
    route
  end

  defp webhook_adapter(%{adapter_kind: :universal}), do: %{kind: :universal}

  defp webhook_adapter(%{adapter_kind: :grafana} = source),
    do: %{kind: :grafana, group_by_labels: source.group_by_labels}

  defp webhook_adapter(%{adapter_kind: :mapped_json} = source) do
    %{
      kind: :mapped_json,
      group_by_labels: source.group_by_labels,
      mapping: Map.new(source.mapping, fn {field, path} -> {mapping_field!(field), path} end)
    }
  end

  @mapping_fields ~w(annotations ends_at event_id incident_id item_id labels revision severity source_url starts_at status summary title)

  defp mapping_field!(field) when field in @mapping_fields, do: String.to_existing_atom(field)

  defp mapping_field!(_field), do: raise(ArgumentError, "webhook mapping names an unknown field")

  defp webhook_lifecycle(%{publication_lifecycle: nil}, _repositories), do: nil

  defp webhook_lifecycle(%{publication_lifecycle: scope}, repositories) do
    unless Enum.all?(scope["repositories"], &Map.has_key?(repositories, &1)),
      do: raise(ArgumentError, "webhook lifecycle names a repository without reviewed policies")

    Map.new(~w(environments kinds repositories targets), fn field ->
      {String.to_existing_atom(field), Enum.sort(scope[field])}
    end)
  end

  defp validate_destination!(destination, adapters) do
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
         :ok <- validate_target(request, adapter.binding) do
      :ok
    else
      _invalid -> raise ArgumentError, "webhook destination is not a configured delivery target"
    end
  end

  defp validate_target(%Request{transport: "slack"} = request, binding) do
    with {:ok, target} <- SlackTarget.parse(request),
         true <-
           is_map(binding[:workspaces]) and
             Map.has_key?(binding.workspaces, target.workspace_ref) do
      :ok
    else
      _invalid -> {:error, :slack_workspace_not_configured}
    end
  end

  defp validate_target(%Request{transport: "github"} = request, binding) do
    with {:ok, target} <- Target.parse(request),
         {:ok, configured} <- Map.fetch(binding[:bindings] || %{}, target.binding),
         true <- configured.repository_id == target.repository_id do
      :ok
    else
      _invalid -> {:error, :github_binding_not_configured}
    end
  end

  defp validate_target(
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

  defp validate_target(%Request{transport: transport}, _binding),
    do: {:error, {:delivery_adapter_not_supported, transport}}

  defp state_tools(bootstrap, _settings, _emisar, slack, github, control_plane, capabilities) do
    %{
      capabilities:
        capabilities
        |> Enum.filter(fn {_capability, enabled} -> enabled end)
        |> Enum.map(fn {capability, true} -> capability end)
        |> Enum.sort(),
      ip: bootstrap.state_tools.ip,
      port: bootstrap.state_tools.port,
      token: Bootstrap.secret!(:state_tools)
    }
    |> Map.put(:answer_authorizer, answer_authorizer(slack, control_plane))
    |> add_platform_capability_tools(slack, github, control_plane)
  end

  # Clarification answers are authorized by the current operator membership.
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

      _other ->
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
    cond do
      not is_nil(github) and
          Enum.any?(GitHubCapabilityTools.list(github.capability_tools), &(&1["name"] == name)) ->
        call_platform_package(
          GitHubCapabilityTools,
          github.capability_tools,
          name,
          arguments,
          binding
        )

      binding_transport(binding) == "slack" and not is_nil(slack) ->
        call_platform_package(
          SlackCapabilityTools,
          slack.capability_tools,
          name,
          arguments,
          binding
        )

      binding_transport(binding) == "control_plane" and not is_nil(control_plane) ->
        if Enum.any?(ControlPlaneCapabilityTools.list(), &(&1["name"] == name)),
          do: ControlPlaneCapabilityTools.call(name, arguments, binding),
          else: {:error, "unknown_tool"}

      true ->
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

  defp bind_state_tools(nil, gateway, _state_tools), do: {nil, gateway}

  defp bind_state_tools(work, nil, state_tools),
    do: {bind_platform_tools(work, state_tools), nil}

  defp bind_state_tools(work, gateway, nil), do: {bind_platform_tools(work, nil), gateway}

  defp bind_state_tools(work, gateway, state_tools) do
    work = bind_platform_tools(work, state_tools)

    {work
     |> Map.put(:state_tool_capabilities, state_tools.capabilities)
     |> Map.put(:state_tools_endpoint, gateway.public_url <> "/v1/state-tools/mcp")
     |> Map.put(:state_tools_secret, state_tools.token),
     Map.put(gateway, :state_tools, %{
       capabilities: state_tools.capabilities,
       additional_tools: Map.get(state_tools, :additional_tools),
       additional_call: Map.get(state_tools, :additional_call),
       answer_authorizer: Map.get(state_tools, :answer_authorizer),
       token_secret: state_tools.token
     })}
  end

  defp bind_platform_tools(work, state_tools) do
    tools =
      case state_tools do
        %{additional_tools: tools} when is_list(tools) -> tools
        _other -> []
      end

    if tools == [], do: work, else: Map.put(work, :platform_tools, tools)
  end

  # Validation and helpers ------------------------------------------------------

  defp validate_runtimes!(configuration) do
    Enum.each(@runtimes, fn {key, module} ->
      if configuration[key], do: validate_runtime!(module, configuration[key])
    end)

    configuration
  end

  # The event-wait worker takes one interval and checks it in start_link; it
  # has no options!/1 to ask.
  defp validate_runtime!(Ryker.State.EventWaitWorker, _configuration), do: :ok
  defp validate_runtime!(module, configuration), do: module.options!(configuration)

  defp work_profile!(attributes) do
    case WorkProfile.new(attributes) do
      {:ok, profile} -> profile
      {:error, _reason} -> raise ArgumentError, "reviewed policy binding is not a usable profile"
    end
  end

  defp json_client!(base_url, receive_timeout, token_provider) do
    {:ok, client} =
      JSONClient.new(%{
        base_url: base_url,
        finch: Ryker.CoopFinch,
        receive_timeout: receive_timeout,
        token_provider: token_provider
      })

    client
  end

  defp github_client!(http) do
    {:ok, client} = Client.new(http: http, requester: JSONClient)
    client
  end

  defp fleet_client!(workspace_ref, capabilities, receive_timeout_ms, poll_interval_ms) do
    unless is_binary(workspace_ref),
      do: raise(ArgumentError, "no worker workspace is selected for Work placement")

    max_waits = max(div(receive_timeout_ms + poll_interval_ms - 1, poll_interval_ms), 1)

    {:ok, client} =
      Ryker.CoopFleet.Client.new(
        capability_names: capabilities,
        capability_versions: %{
          "repository-freshness" => "2",
          "repository-source-selector" => "1"
        },
        max_waits: max_waits,
        poll_interval_ms: poll_interval_ms,
        workspace_ref: workspace_ref
      )

    {Ryker.CoopFleet.Client, client}
  end

  defp rpc_endpoint!(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, path: path} = uri
      when is_binary(host) and host != "" and is_binary(path) and path != "" ->
        origin =
          uri |> Map.merge(%{path: nil, query: nil, fragment: nil}) |> URI.to_string()

        %{origin: String.trim_trailing(origin, "/"), path: path, url: URI.to_string(uri)}

      _invalid ->
        raise ArgumentError, "The saved Emisar RPC endpoint must be an exact HTTPS URL"
    end
  end

  defp credential!(kind, name) do
    case Credentials.fetch(kind, name) do
      {:ok, value} ->
        value

      {:error, :credential_missing} ->
        raise ArgumentError, "#{kind} credential #{name} is not configured"

      {:error, _reason} ->
        raise ArgumentError, "#{kind} credential #{name} cannot be decrypted"
    end
  end

  # The gateway scans worker output for every integration secret currently in
  # custody. Only runtime assembly turns status records back into redaction
  # material; the control plane never receives these values.
  defp credential_redaction_values do
    Credentials.statuses()
    |> Enum.flat_map(fn credential ->
      case Credentials.fetch(credential.kind, credential.name) do
        {:ok, value} -> [value]
        {:error, _reason} -> []
      end
    end)
    |> Enum.uniq()
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
