defmodule Ryker.Runtime.Assembly do
  @moduledoc """
  Builds the running child configuration from bootstrap, code defaults and
  durable settings.

  This is the only place product settings become runtime bindings. It performs
  no database writes and no network calls. It reads the saved credentials it
  must check before it starts what uses them (the GitHub App key and webhook
  secret, each webhook source's secret) and, once per build, the values every
  page and log redacts with; the Slack and Emisar tokens stay behind lazy
  providers. Execution templates come from the controller's saved settings,
  and a domain whose required settings are absent is simply not started. An
  integration is enabled by its saved connection, never by the presence of a
  credential in the environment.
  """
  alias Ryker.Bootstrap
  alias Ryker.Config
  alias Ryker.ControlPlane
  alias Ryker.CoopFleet
  alias Ryker.Credentials
  alias Ryker.Defaults
  alias Ryker.Delivery
  alias Ryker.Emisar
  alias Ryker.GitHub
  alias Ryker.Ingress
  alias Ryker.Maps
  alias Ryker.Publication
  alias Ryker.Secret
  alias Ryker.Settings
  alias Ryker.Slack
  alias Ryker.Webhooks
  alias Ryker.Work
  require Logger

  # Every runtime the owner starts, in dependency order, with the module that
  # validates its configuration here and runs it there. One list, so a runtime
  # cannot be assembled without being started or started without being checked.
  @runtimes [
    {:coop_worker_gateway, Ryker.CoopFleet.Server},
    {:admission, Ryker.Admission.Runtime},
    # Its own key, so changing how many routing sessions are kept ready
    # restarts only the pool, never the routing slots mid-message.
    {:admission_ready, Ryker.Admission.ReadyPool},
    # Its own key too: the local routing model's comparisons never touch the
    # routing slots, and turning them on or off restarts only their lane.
    {:local_routing, Ryker.LocalRouting.Worker},
    # Vectors of what each request is about, for routing's search by meaning;
    # only while RYKER_EMBEDDINGS_URL names a server and routing runs.
    {:embeddings, Ryker.Embeddings.Worker},
    {:work, Ryker.Work.Runtime},
    {:learning, Ryker.Learning.Runtime},
    # Self-analysis runs on learning's policy and models, only where learning
    # runs, in a pool of its own so its restarts never touch learning's.
    {:improvement, Ryker.Improvement.Runtime},
    {:retention, Ryker.Retention.Runtime},
    # Its own key, so turning keeping routing examples on or off, or a stored
    # credential changing, restarts only the copy, never cleanup.
    {:routing_examples, Ryker.RoutingExamples.Worker},
    # The same for keeping work examples, which copy settled Work turns.
    {:work_examples, Ryker.WorkExamples.Worker},
    {:github, Ryker.GitHub.Runtime},
    # RYKER.md for each repository: model turns through Work's adapter, and
    # GitHub through the App, so it starts after both.
    {:repository_knowledge, Ryker.RepositoryKnowledge.Runtime},
    {:publication, Ryker.Publication.Runtime},
    {:delivery, Ryker.Delivery.Runtime},
    # Its own key, so turning the weekly report on or off starts or stops
    # only its schedule; delivery posts what it queues.
    {:weekly_report, Ryker.WeeklyReport.Worker},
    {:emisar, Ryker.Emisar.Runtime},
    {:event_waits, Ryker.Waits.EventWaitWorker},
    {:schedules, Ryker.Schedules.ScheduleRuntime},
    {:slack, Ryker.Slack.Runtime},
    {:slack_names, Ryker.Slack.Names},
    {:webhooks, Ryker.Webhooks.Server},
    {:control_plane, Ryker.ControlPlane.Server}
  ]
  # Published beside the runtimes: read by whoever asks, started by nobody.
  # `integrations_left_out` names each enabled integration, Emisar account and
  # webhook source this configuration could not start, with why, for the
  # Integrations state. `github_web_url` is the web address links, remotes and
  # pull requests are on, `github_api_url` the API root a payload's API links
  # start with (`Ryker.GitHub`).
  @published_facts [:execution_mode, :github_api_url, :github_web_url, :integrations_left_out]
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
        {:ok, value} -> Config.publish(key, value)
        :error -> Config.withdraw(key)
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
    # What every page and log redacts with; saving or removing a credential
    # applies settings again, so this follows each change.
    _values = Credentials.remember_redaction_values()
    policies = index_policies(CoopFleet.JobTemplates.from_settings(settings))
    repositories = repositories(settings, policies)
    outside = outside_profile(policies)
    environments = environments(settings, repositories, policies, outside)
    work = work(settings, bootstrap.storage_root)
    admission = admission(settings, policies, work)
    admission_ready = admission_ready(settings, admission)
    local_routing = local_routing(settings)
    embeddings = embeddings(admission)
    learning = learning(settings, policies, work)
    improvement = improvement(settings, policies, work)
    schedules = schedules(settings, repositories, policies)
    gateway = worker_gateway(bootstrap)
    {github, github_left_out} = github(bootstrap, settings, repositories, environments)
    repository_knowledge = repository_knowledge(settings, work, github)

    {slack, slack_left_out} =
      slack(settings, environments, schedules, policies, outside)

    slack_names = slack_names(settings)

    control_plane = control_plane(bootstrap, environments, work, schedules, outside)
    adapters = adapters(slack, github, control_plane)
    delivery = delivery(settings, adapters)
    weekly_report = weekly_report(settings, slack, delivery)
    publication = publication(settings, work, repositories, github, adapters)
    {emisar, emisar_left_out} = emisar(settings, adapters, slack, github)

    {webhooks, webhooks_left_out} =
      webhooks(bootstrap, settings, adapters, repositories, environments)

    retention = retention(settings, work, learning)
    routing_examples = routing_examples(settings, admission)
    work_examples = work_examples(settings, work)

    state_tools =
      state_tools(slack, github, control_plane, %{
        emisar_approvals: not is_nil(emisar),
        event_waits: true,
        publication: not is_nil(publication),
        schedules: not is_nil(schedules)
      })

    {work, gateway} = bind_state_tools(work, gateway, state_tools)
    # What work may tell a person is connected: what actually runs, not what is saved.
    work =
      work && Map.put(work, :connected, %{github: not is_nil(github), slack: not is_nil(slack)})

    %{
      execution_mode: Defaults.execution(),
      github_api_url: GitHub.api_root(settings.github.api_url),
      github_web_url: GitHub.web_url(settings.github.api_url)
    }
    |> Maps.put_present(:work, work)
    |> Maps.put_present(:admission, admission)
    |> Maps.put_present(:admission_ready, admission_ready)
    |> Maps.put_present(:control_plane, control_plane)
    |> Maps.put_present(:coop_worker_gateway, gateway)
    |> Maps.put_present(:delivery, delivery)
    |> Maps.put_present(:emisar, emisar)
    |> Maps.put_present(:event_waits, Defaults.fetch!(:event_waits))
    |> Maps.put_present(:github, github && github.runtime)
    |> Maps.put_present(:improvement, improvement)
    |> Maps.put_present(:learning, learning)
    |> Maps.put_present(:local_routing, local_routing)
    |> Maps.put_present(:embeddings, embeddings)
    |> Maps.put_present(:publication, publication)
    |> Maps.put_present(:repository_knowledge, repository_knowledge)
    |> Maps.put_present(:retention, retention)
    |> Maps.put_present(:routing_examples, routing_examples)
    |> Maps.put_present(:work_examples, work_examples)
    |> Maps.put_present(:schedules, schedules)
    |> Maps.put_present(:slack, slack && slack.runtime)
    |> Maps.put_present(:slack_names, slack_names)
    |> Maps.put_present(:webhooks, webhooks)
    |> Maps.put_present(:weekly_report, weekly_report)
    |> Maps.put_present(
      :integrations_left_out,
      left_out(
        github: github_left_out,
        slack: slack_left_out,
        emisar: emisar_left_out,
        webhooks: webhooks_left_out
      )
    )
    |> validate_runtimes!()
  end

  # Policies ------------------------------------------------------------------

  # An environment's bindings are per repository; every other scope binds one
  # policy per purpose and carries no repository.
  defp index_policies(bindings) do
    Map.new(bindings, fn binding ->
      {{binding.purpose, binding.scope_kind, binding.scope_ref, binding.repository_ref},
       %{name: binding.policy_name, digest: binding.policy_digest}
       |> Maps.put_present(:authority_digest, binding.authority_digest)}
    end)
  end

  defp policy(policies, purpose, scope_kind, scope_ref, repository_ref \\ ""),
    do: Map.get(policies, {purpose, scope_kind, scope_ref, repository_ref})

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

  # Every environment that can run work, by ref. Work in one may change any of
  # its read and write repositories and mounts the others read-only, so each
  # read and write repository needs its own policies there; a read-only one is
  # only ever mounted beside it. An environment without repositories runs on
  # the installation's own policy and mounts nothing. One in which any read
  # and write repository lacks the policies it needs runs nothing and is left
  # out.
  defp environments(settings, repositories, policies, outside) do
    github_repositories = Map.new(settings.repositories, &{&1.ref, &1.github_repository})

    settings.environments
    |> Enum.flat_map(fn environment ->
      case environment_entry(environment, repositories, policies, outside, github_repositories) do
        nil -> []
        entry -> [{environment.ref, entry}]
      end
    end)
    |> Map.new()
  end

  defp environment_entry(environment, repositories, policies, outside, github_repositories) do
    case Settings.Environment.repository_refs(environment) do
      [] -> outside && workspace_free_entry(environment, outside)
      refs -> shared_entry(environment, refs, repositories, policies, github_repositories)
    end
  end

  # Every repository work may change needs its policies before any work runs
  # in the environment.
  defp shared_entry(environment, refs, repositories, policies, github_repositories) do
    classes =
      environment
      |> Settings.Environment.writable_refs()
      |> Map.new(&{&1, repository_policies(environment, &1, refs, repositories, policies)})

    if Enum.all?(classes, fn {_ref, found} -> found end),
      do: repository_entry(environment, refs, classes, github_repositories)
  end

  # An environment's own reviewed bindings for a repository decide its
  # policies there: Coop mounts the other repositories only for a policy that
  # declares them. An environment of one repository with no bindings of its own
  # runs on that repository's.
  defp repository_policies(environment, ref, refs, repositories, policies) do
    conversation = policy(policies, :conversational, :environment, environment.ref, ref)
    contributor = policy(policies, :contributor, :environment, environment.ref, ref)

    cond do
      conversation && contributor ->
        standard = policy(policies, :standard, :environment, environment.ref, ref) || conversation
        deep = policy(policies, :deep, :environment, environment.ref, ref) || standard
        %{contributor: contributor, conversation: conversation, deep: deep, standard: standard}

      refs == [ref] and is_map_key(repositories, ref) ->
        repository = Map.fetch!(repositories, ref)

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

  # A confirmed task changes the read and write repository it names, under
  # that repository's contributor policy in the environment, with every other
  # repository of the environment mounted read-only beside it. A read-only
  # repository has no policies here, so no work is ever placed in it.
  defp repository_entry(environment, refs, classes, github_repositories) do
    %{
      contributor_policies:
        Map.new(Map.keys(classes), fn ref ->
          {ref,
           Map.merge(Map.fetch!(classes, ref).contributor, %{
             environment_ref: environment.ref,
             repository_context: repository_context(environment, ref, refs),
             repository_ref: ref
           })}
        end),
      display_name: environment.display_name,
      github_repositories: Map.take(github_repositories, refs) |> reject_nil_values(),
      work_profile:
        %{
          environment_ref: environment.ref,
          parallel_goal_limit: environment.parallel_goal_limit,
          policies:
            Map.new(classes, fn {ref, found} ->
              {ref,
               %{
                 conversational: class_policy(found.conversation),
                 deep: class_policy(found.deep),
                 standard: class_policy(found.standard)
               }}
            end),
          repositories: refs
        }
        |> Maps.put_present(:emisar_connection_ref, environment.emisar_connection_ref)
    }
  end

  defp repository_context(environment, ref, refs) do
    Work.RepositoryContext.document(%{
      context_ref: environment.ref,
      parallel_goal_limit: environment.parallel_goal_limit,
      primary_repository: ref,
      read_only_repositories: List.delete(refs, ref)
    })
  end

  defp workspace_free_entry(environment, outside) do
    %{
      contributor_policies: %{},
      display_name: environment.display_name,
      github_repositories: %{},
      work_profile:
        Map.merge(outside, %{
          emisar_connection_ref: environment.emisar_connection_ref,
          environment_ref: environment.ref,
          parallel_goal_limit: environment.parallel_goal_limit
        })
    }
  end

  # A repository run on its own, outside any environment: GitHub events for a
  # repository no usable environment holds, and tasks that change it.
  defp repository_alone(ref, repository) do
    %{
      contributor_policies: %{ref => Map.put(repository.contributor_policy, :repository_ref, ref)},
      display_name: ref,
      github_repositories: reject_nil_values(%{ref => repository.github_repository}),
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

  # GitHub events for a repository run in the environment
  # `Ryker.Settings.environment_for_repository/2` names among those that can
  # run work, else on the repository alone. An event is about its own repository, so that
  # repository is the default choice of the work it starts there, unless the
  # environment only reads it: the environment's default then stays the one
  # work changes, and the event's repository is mounted read-only beside it.
  defp github_entry(repository_ref, settings, repositories, environments) do
    case repository_environment(repository_ref, settings, environments) do
      %{work_profile: %{repositories: refs, policies: policies} = profile} = entry
      when is_map_key(policies, repository_ref) ->
        %{
          entry
          | work_profile: %{
              profile
              | repositories: [repository_ref | List.delete(refs, repository_ref)]
            }
        }

      %{} = entry ->
        entry

      nil ->
        case Map.fetch(repositories, repository_ref) do
          {:ok, repository} -> repository_alone(repository_ref, repository)
          :error -> nil
        end
    end
  end

  defp repository_environment(repository_ref, settings, environments) do
    usable = Enum.filter(settings.environments, &Map.has_key?(environments, &1.ref))

    case Settings.environment_for_repository(usable, repository_ref) do
      %Settings.Environment{ref: ref} -> Map.fetch!(environments, ref)
      nil -> nil
    end
  end

  # A task confirmed on GitHub changes the repository it names, in the
  # environment that repository's events run in, else on the repository alone.
  # An environment that only reads the repository has no task to confirm in
  # it: nothing there may change it.
  defp task_entries(settings, repositories, environments) do
    held =
      Enum.flat_map(environments, fn {_ref, entry} -> Map.keys(entry.contributor_policies) end)

    (Map.keys(repositories) ++ held)
    |> Enum.uniq()
    |> Enum.flat_map(fn ref ->
      entry =
        case repository_environment(ref, settings, environments) do
          nil -> repository_alone(ref, Map.fetch!(repositories, ref))
          environment -> environment
        end

      case Map.fetch(entry.contributor_policies, ref) do
        {:ok, policy} -> [{ref, policy}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  # A reviewed binding names the policy; a Work profile pins it per work class.
  defp class_policy(policy) do
    %{policy: policy.name, policy_digest: policy.digest}
    |> Maps.put_present(:authority_digest, Map.get(policy, :authority_digest))
  end

  # Execution lanes ------------------------------------------------------------

  # Work is placeable only when the build uses the fleet and an operator has
  # selected an enrolled workspace. An isolated topology has no Work lane to
  # assemble, and an unselected workspace is unconfigured, not a failure.
  defp work(settings, storage_root) do
    if Defaults.execution() == :fleet and is_binary(settings.work.workspace_ref) do
      defaults = Defaults.fetch!(:work)
      coop = Defaults.fetch!(:coop)

      {api, client} =
        fleet_client!(
          settings.work.workspace_ref,
          defaults.capability_names,
          coop.receive_timeout_ms,
          coop.command_recheck_ms,
          Path.join(storage_root, "worker-bodies")
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
        worker_ref: "#{settings.installation.host_ref}:admission"
      }
    else
      _unconfigured -> nil
    end
  end

  # The pool starts sessions with exactly the policy routing uses, so it runs
  # wherever routing does, even at 0, to retire what an earlier setting kept.
  defp admission_ready(_settings, nil), do: nil

  defp admission_ready(settings, admission) do
    admission
    |> Map.take([:api, :client, :policy, :policy_digest])
    |> Map.put(:target, settings.work.ready_routing_sessions)
  end

  # The local routing model is asked only in shadow, only at the endpoint and
  # model saved for it; it needs no worker, policy or Coop at all.
  defp local_routing(%{work: %{local_routing_mode: :shadow} = work}) do
    Map.merge(Defaults.fetch!(:local_routing), %{
      endpoint: work.local_routing_endpoint,
      model: work.local_routing_model
    })
  end

  defp local_routing(_settings), do: nil

  # A host setting, like the whisper servers: where the embedding server runs
  # is the machine's, not the installation's saved settings.
  defp embeddings(nil), do: nil

  defp embeddings(_admission) do
    case Ryker.Embeddings.url() do
      nil -> nil
      url -> %{url: url, model: Ryker.Embeddings.model(), poll_interval_ms: 60_000}
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
        worker_ref: "#{settings.installation.host_ref}:learning"
      })
    else
      _disabled -> nil
    end
  end

  # Diagnosing what went wrong with a request people were unhappy with is
  # learning from feedback: it uses learning's policy and models, and starts
  # nothing while learning is off (`Ryker.Improvement`). It still runs then,
  # to finish the analyses already out at Coop, so none is left holding a
  # session and people's words past their horizon.
  defp improvement(settings, policies, work) do
    with %{} = policy <- installation_policy(policies, :learning),
         %{api: _api} <- work do
      Defaults.fetch!(:improvement)
      |> Map.merge(%{
        api: work.api,
        client: work.client,
        enabled: settings.learning.enabled,
        policy: policy.name,
        policy_digest: policy.digest,
        worker_ref: "#{settings.installation.host_ref}:improvement"
      })
    else
      _unavailable -> nil
    end
  end

  # RYKER.md is written by a model through Work's adapter and checked against
  # the repository through the GitHub App, so it runs only where both do.
  # Each repository's own read-only policy is found when a turn is prepared
  # (`Ryker.RepositoryKnowledge.Dispatcher`), so adding or setting up a
  # repository never restarts this lane.
  defp repository_knowledge(settings, %{api: api, client: client}, %{}) do
    Defaults.fetch!(:repository_knowledge)
    |> Map.merge(%{
      api: api,
      client: client,
      worker_ref: "#{settings.installation.host_ref}:repository-knowledge"
    })
  end

  defp repository_knowledge(_settings, _work, _github), do: nil

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
        :operational_data_seconds,
        :routing_examples_enabled,
        :routing_examples_seconds,
        :work_examples_enabled,
        :work_examples_seconds
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

  # Routing examples are copied only while a person keeps them on, and only
  # where routing runs.
  defp routing_examples(%{retention: %{routing_examples_enabled: true} = retention}, admission)
       when is_map(admission) do
    Map.put(
      Defaults.fetch!(:routing_examples),
      :window_seconds,
      retention.routing_examples_seconds
    )
  end

  defp routing_examples(_settings, _admission), do: nil

  # Work examples are copied only while a person keeps them on, and only where
  # Work runs.
  defp work_examples(%{retention: %{work_examples_enabled: true} = retention}, work)
       when is_map(work) do
    Map.put(Defaults.fetch!(:work_examples), :window_seconds, retention.work_examples_seconds)
  end

  defp work_examples(_settings, _work), do: nil

  # Transports -----------------------------------------------------------------

  defp worker_gateway(%Bootstrap{worker_gateway: nil}), do: nil

  defp worker_gateway(%Bootstrap{worker_gateway: gateway, storage_root: storage_root}) do
    gateway
    |> Map.take([:cacertfile, :ca_keyfile, :certfile, :keyfile, :ip, :port, :public_url])
    |> Map.merge(Defaults.fetch!(:coop_worker_gateway))
    |> Map.put(:body_root, Path.join(storage_root, "worker-bodies"))
    |> Map.put(:checkpoint_key, Secret.new(Bootstrap.checkpoint_key!()))
  end

  # Integrations ----------------------------------------------------------------

  # An enabled integration, Emisar account or webhook source this
  # configuration cannot start (its credential missing or unusable, a saved
  # value its runtime refuses, a policy it needs missing) is left out of the
  # running system and named with why, and every other lane and setting still
  # applies. Refusing the whole configuration for one of them (QA P1 #4,
  # 2026-09-25) kept every newer setting of every kind from applying, and a
  # Slack without its incident policy vanished with no word at all.
  # `Integrations` reads the reasons, so nothing disappears silently.
  defp isolated(integration, build) do
    {:ok, build.()}
  rescue
    # A refusal names the setting it refused, as a revision that cannot apply
    # does in the owner's log; a failed match could quote a credential, so
    # only its kind is logged.
    error in [ArgumentError, MatchError] ->
      detail = if is_struct(error, ArgumentError), do: error.message, else: "MatchError"
      Logger.warning("#{integration} left out of the running configuration: #{detail}")
      {:error, :settings_unusable}
  end

  defp left_out(integrations) do
    case Enum.reject(integrations, fn {_integration, reason} -> reason in [nil, %{}] end) do
      [] -> nil
      left_out -> Map.new(left_out)
    end
  end

  defp github(_bootstrap, %{github: %{enabled: false}}, _repositories, _environments),
    do: {nil, nil}

  # Credentials do not enable an integration and must not silently rebind one.
  # A connection saved for one app with the deployment holding another's key is
  # a mismatch an operator has to resolve, not a component that quietly does
  # not start: GitHub is left out, and says which credential.
  defp github(bootstrap, settings, repositories, environments) do
    with {:ok, private_key} <- github_credential(:github_private_key),
         {:ok, signer} <- app_signer(settings.github.app_id, private_key),
         {:ok, webhook_secret} <- github_credential(:github_webhook),
         {:ok, github} <-
           isolated(:github, fn ->
             github =
               github_runtime(bootstrap, settings, repositories, environments, %{
                 signer: signer,
                 webhook_secret: webhook_secret
               })

             validate_runtime!(Ryker.GitHub.Runtime, github.runtime)
             github
           end) do
      {github, nil}
    else
      {:error, reason} -> {nil, reason}
    end
  end

  defp github_credential(kind) do
    case {Credentials.fetch(kind, "primary"), kind} do
      {{:ok, value}, _kind} -> {:ok, value}
      {{:error, :credential_missing}, :github_private_key} -> {:error, :private_key_missing}
      {{:error, _unreadable}, :github_private_key} -> {:error, :private_key_unreadable}
      {{:error, :credential_missing}, :github_webhook} -> {:error, :webhook_secret_missing}
      {{:error, _unreadable}, :github_webhook} -> {:error, :webhook_secret_unreadable}
    end
  end

  defp app_signer(app_id, private_key) do
    case GitHub.AppJWT.new(app_id, decode_private_key(private_key)) do
      {:ok, signer} -> {:ok, signer}
      {:error, _reason} -> {:error, :private_key_unusable}
    end
  end

  defp github_runtime(bootstrap, settings, repositories, environments, credentials) do
    %{signer: signer, webhook_secret: webhook_secret} = credentials
    defaults = Defaults.fetch!(:github)
    api_url = settings.github.api_url

    app_http =
      json_client!(api_url, defaults.receive_timeout_ms, fn -> GitHub.AppJWT.token(signer) end)

    prepared =
      Map.new(settings.github_bindings, fn binding ->
        entry = github_entry(binding.repository_ref, settings, repositories, environments)

        {binding.name, github_binding(binding, api_url, defaults, settings.repositories, entry)}
      end)

    confirmations =
      case task_entries(settings, repositories, environments) do
        policies when map_size(policies) == 0 ->
          nil

        policies ->
          GitHub.Confirmations.options!(%{
            repositories:
              Map.new(policies, fn {ref, policy} -> {ref, %{contributor_policy: policy}} end)
          })
      end

    capability_binding = %{
      bindings:
        Map.new(prepared, fn {name, item} ->
          {name,
           %{
             api: GitHub.Client,
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
             api: GitHub.Client,
             client: item.delivery_client,
             repository_full_name: item.repository.github_repository,
             repository_id: item.trusted_binding.repository_id
           }}
        end)
    }

    %{
      bindings: prepared,
      capability_tools: GitHub.CapabilityTools.options!(capability_binding),
      delivery_binding: delivery_binding,
      receive_timeout_ms: defaults.receive_timeout_ms,
      runtime: %{
        app_id: settings.github.app_id,
        onboarding: %{},
        server: %{
          bindings: Map.new(prepared, fn {name, item} -> {name, item.trusted_binding} end),
          bot_login: settings.github.app_slug,
          confirmations: confirmations,
          ip: bootstrap.github_listener.ip,
          port: bootstrap.github_listener.port,
          repository_access: repository_access(prepared),
          secret: Secret.new(webhook_secret)
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
          requester: Delivery.JSONClient
        }
      }
    }
  end

  defp decode_private_key("-----BEGIN " <> _rest = key), do: key

  defp decode_private_key(encoded) do
    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) in 16..4_096 -> key
      _invalid -> encoded
    end
  end

  # Captures only each binding's access client. Capturing the prepared
  # bindings captured their repositories' setup progress too, so every setup
  # step changed this closure and the owner restarted GitHub mid-setup
  # (2026-09-27: every added repository cycled "cloning"/"scanning" for an hour).
  defp repository_access(prepared) do
    clients = Map.new(prepared, fn {name, item} -> {name, item.access_http} end)

    fn binding, payload ->
      GitHub.RepositoryAccess.authorize(binding, payload, Map.fetch!(clients, binding.name))
    end
  end

  defp github_binding(binding, api_url, defaults, repositories, entry) do
    repository =
      Enum.find(repositories, &(&1.ref == binding.repository_ref)) ||
        raise ArgumentError, "github binding names an unknown repository"

    delivery_http =
      json_client!(api_url, defaults.receive_timeout_ms, fn ->
        GitHub.InstallationTokens.token(binding.name, :delivery)
      end)

    access_http =
      json_client!(api_url, defaults.receive_timeout_ms, fn ->
        GitHub.InstallationTokens.token(binding.name, :authorization)
      end)

    context_http =
      json_client!(api_url, defaults.receive_timeout_ms, fn ->
        GitHub.InstallationTokens.token(binding.name, :context)
      end)

    review_http =
      json_client!(api_url, defaults.receive_timeout_ms, fn ->
        GitHub.InstallationTokens.token(binding.name, :review)
      end)

    ci_rerun_http =
      json_client!(api_url, defaults.receive_timeout_ms, fn ->
        GitHub.InstallationTokens.token(binding.name, :ci_rerun)
      end)

    ci_cancel_http =
      json_client!(api_url, defaults.receive_timeout_ms, fn ->
        GitHub.InstallationTokens.token(binding.name, :ci_cancel)
      end)

    publication_http =
      json_client!(api_url, defaults.receive_timeout_ms, fn ->
        GitHub.InstallationTokens.token(binding.name, :publication)
      end)

    {:ok, trusted_binding} =
      GitHub.Binding.new(%{
        installation_id: binding.installation_id,
        max_body_bytes: defaults.max_body_bytes,
        name: binding.name,
        action_grants: Settings.GitHubBinding.grants(binding),
        repository_full_name: repository.github_repository,
        repository_id: binding.repository_id,
        ryker_actor_id: binding.ryker_actor_id,
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
      trusted_binding: trusted_binding
    }
  end

  defp slack(
         %{slack: %{enabled: false}},
         _environments,
         _schedules,
         _policies,
         _outside
       ),
       do: {nil, nil}

  defp slack(settings, environments, schedules, policies, outside) do
    incident_policy = installation_policy(policies, :incident)

    case isolated(:slack, fn ->
           slack_runtime(settings, environments, schedules, outside, incident_policy)
         end) do
      {:ok, slack} -> {slack, nil}
      {:error, reason} -> {nil, reason}
    end
  end

  # The names of Slack people and channels on every page, for the workspace
  # whose bot token is saved, whether or not Slack is switched on: choosing who
  # can manage Ryker happens before it is, and the names Choose people loaded
  # must still be there after (2026-09-26). Only the workspace, its address
  # and the token belong here, so no other Slack setting restarts the cache.
  defp slack_names(%{slack: %{workspace_ref: workspace} = slack}) when is_binary(workspace) do
    case Credentials.fetch(:slack_bot, "primary") do
      {:ok, _token} ->
        %{
          workspace: workspace,
          workspace_url: slack.workspace_url,
          client: slack_bot_client(),
          known: own_name(slack)
        }

      {:error, _missing_or_unreadable} ->
        nil
    end
  end

  defp slack_names(_settings), do: nil

  # Ryker's own bot user reads by its name from the first page after a start.
  defp own_name(%{bot_user_ref: ref, bot_name: name}) when is_binary(ref) and is_binary(name),
    do: [{ref, name}]

  defp own_name(_slack), do: []

  defp slack_bot_client do
    defaults = Defaults.fetch!(:slack)

    bot_http =
      json_client!(
        defaults.api_url,
        defaults.receive_timeout_ms,
        Credentials.provider(:slack_bot, "primary")
      )

    {:ok, bot_client} = Slack.Client.new(http: bot_http, requester: Delivery.JSONClient)
    bot_client
  end

  # The delivery adapter builds the runtime's own options, so a value the
  # runtime would refuse is refused here, inside `isolated/2`.
  defp slack_runtime(settings, environments, schedules, outside, incident_policy) do
    defaults = Defaults.fetch!(:slack)

    app_http =
      json_client!(
        defaults.api_url,
        defaults.receive_timeout_ms,
        Credentials.provider(:slack_app, "primary")
      )

    bot_client = slack_bot_client()

    runtime =
      defaults
      |> Map.drop([:api_url])
      |> Map.merge(%{
        app_http: app_http,
        bot_client: bot_client,
        channel_prefix: settings.slack.channel_prefix,
        # The saved default, even while it cannot run work yet: a channel
        # joined then is still set to it, and works in it once it can.
        default_environment: Settings.default_environment_ref(settings),
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
        schedule_policies: schedules,
        workspace_admins_manage: settings.slack.workspace_admins_manage,
        workspace_url: settings.slack.workspace_url
      })

    %{
      capability_tools:
        Slack.CapabilityTools.options!(%{
          action_tokens: {Slack.ActionTokens, Slack.ActionTokens},
          api: Slack.Client,
          client: bot_client,
          workspace_ref: settings.slack.workspace_ref
        }),
      delivery_adapter: Slack.Runtime.delivery_adapter!(runtime),
      runtime: runtime
    }
  end

  # Each Chat conversation picks its environment, so the console receives
  # every environment that can run work and the profile of work outside any;
  # a conversation whose environment cannot run work right now runs outside.
  defp control_plane(bootstrap, environments, work, schedules, outside) do
    %{
      access: Map.get(bootstrap.control_plane, :access, :loopback),
      coop_api: work && work.api,
      coop_client: work && work.client,
      environments:
        Map.new(environments, fn {ref, entry} ->
          {ref, %{display_name: entry.display_name, work_profile: entry.work_profile}}
        end),
      fallback_work_profile: outside,
      ip: bootstrap.control_plane.ip,
      port: bootstrap.control_plane.port,
      public_url: bootstrap.control_public_url,
      cloudflare_access: bootstrap.cloudflare_access,
      schedule_policies: schedules,
      task_policies:
        for(
          {ref, %{contributor_policies: policies}} <- environments,
          map_size(policies) > 0,
          into: %{},
          do: {ref, policies}
        )
    }
  end

  defp adapters(slack, github, control_plane) do
    %{}
    |> Maps.put_present(
      "control_plane",
      control_plane &&
        %{
          binding: nil,
          message_publisher: Ryker.ControlPlane.Publisher,
          reaction_publisher: Ryker.ControlPlane.Publisher
        }
    )
    |> Maps.put_present("slack", slack && slack.delivery_adapter)
    |> Maps.put_present(
      "github",
      github &&
        %{
          binding: github.delivery_binding,
          message_publisher: GitHub.Publisher,
          reaction_publisher: GitHub.Publisher
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

  # The weekly report has a schedule only while it is on, names a channel, and
  # Slack and delivery run to post it; otherwise nothing of it runs, writes or
  # logs. Its day, time, zone and channel are read when it checks, and a save
  # wakes it (`Ryker.WeeklyReport.Worker`), so changing them restarts nothing.
  defp weekly_report(
         %{report: %{weekly_self_report_enabled: true, channel_ref: channel}},
         slack,
         delivery
       )
       when is_binary(channel) and is_map(slack) and is_map(delivery),
       do: %{}

  defp weekly_report(_settings, _slack, _delivery), do: nil

  # Publication runs authorized readiness reviews through the same Coop
  # authority Work uses; without a Work lane there is nothing to review with.
  defp publication(_settings, nil, _repositories, _github, _adapters), do: nil

  defp publication(_settings, _work, _repositories, _github, adapters)
       when map_size(adapters) == 0,
       do: nil

  defp publication(settings, work, repositories, github, adapters) do
    repositories =
      if settings.publication.enabled and github,
        do: publication_repositories(settings, repositories, github),
        else: %{}

    status_client = %{repositories: repositories}

    Defaults.fetch!(:publication)
    |> Map.merge(%{
      coop_api: work.api,
      coop_client: work.client,
      delivery_adapters: adapters,
      repositories: repositories,
      status_api: Publication.GitHubStatus,
      status_client: status_client,
      worker_ref: "#{settings.installation.host_ref}:publication"
    })
  end

  defp publication_repositories(settings, repositories, github) do
    repositories
    |> Enum.flat_map(fn {ref, repository} ->
      binding = repository.github_binding && Map.get(github.bindings, repository.github_binding)

      if binding && repository.github_repository do
        [
          {ref,
           %{
             api: GitHub.Client,
             base_branch: repository.base_branch,
             client: binding.publication_client,
             branch_prefix: settings.publication.branch_prefix,
             github_repository: repository.github_repository,
             ryker_actor_id: binding.trusted_binding.ryker_actor_id
           }}
        ]
      else
        []
      end
    end)
    |> Map.new()
  end

  # Each account Ryker watches for approval decisions is its own watcher: one
  # it cannot watch (an address saved before today's checks, a value its
  # runtime refuses) is left out and named, and the other accounts still run.
  defp emisar(settings, adapters, slack, github) do
    {connections, left_out} =
      settings.emisar_connections
      |> Enum.filter(& &1.monitoring_enabled)
      |> Enum.reduce({[], %{}}, fn connection, {connections, left_out} ->
        case emisar_connection(connection, settings, adapters, slack, github) do
          {:ok, watcher} -> {[watcher | connections], left_out}
          {:error, reason} -> {connections, Map.put(left_out, connection.ref, reason)}
        end
      end)

    {if(connections != [], do: %{connections: Enum.reverse(connections)}), left_out}
  end

  defp emisar_connection(connection, settings, adapters, slack, github) do
    with {:ok, endpoint} <- rpc_endpoint(connection.rpc_url) do
      isolated(:emisar, fn ->
        defaults = Defaults.fetch!(:emisar)

        http =
          json_client!(
            endpoint.origin,
            defaults.receive_timeout_ms,
            Credentials.provider(:emisar, connection.ref)
          )

        {:ok, client} =
          Ryker.Emisar.Client.new(%{
            http: http,
            requester: Delivery.JSONClient,
            rpc_origin: endpoint.origin,
            rpc_path: endpoint.path
          })

        watcher =
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

        # What the runtime checks of every watcher before it starts any.
        Emisar.ApprovalRuntime.options!(watcher)
        watcher
      end)
    end
  end

  defp presentation_timeout(slack, github) do
    [slack && slack.runtime.receive_timeout_ms, github && github.receive_timeout_ms]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> 0 end)
  end

  # Each enabled source is one sender's route. A source this configuration
  # cannot serve (its destination is not running, its environment cannot run
  # work, its credential is missing or too short, its deployment reports name
  # an unreviewed repository) is left out and named with its reason, and every
  # other source and setting still applies. Refusing the whole configuration
  # for one source (QA P1 #4, 2026-09-25) kept every newer setting of every
  # kind from applying; the reason is reported, so the route never silently
  # vanishes (`Integrations.webhooks/1`).
  defp webhooks(bootstrap, settings, adapters, repositories, environments) do
    {routes, left_out} =
      settings.webhook_sources
      |> Enum.filter(& &1.enabled)
      |> Enum.reduce({%{}, %{}}, fn source, {routes, left_out} ->
        case webhook_route(source, adapters, repositories, environments) do
          {:ok, route} -> {Map.put(routes, source.name, route), left_out}
          {:error, reason} -> {routes, Map.put(left_out, source.name, reason)}
        end
      end)

    listener =
      if routes != %{},
        do: %{
          ip: bootstrap.webhook_listener.ip,
          port: bootstrap.webhook_listener.port,
          routes: routes
        }

    {listener, left_out}
  end

  defp webhook_route(source, adapters, repositories, environments) do
    defaults = Defaults.fetch!(:webhooks)

    destination = %{
      conversation_ref: source.destination_conversation_ref,
      thread_ref: source.destination_thread_ref,
      transport: source.destination_transport
    }

    with {:ok, secret} <- webhook_secret(source.secret_name),
         {:ok, environment} <- webhook_environment(environments, source.environment_ref),
         {:ok, work_profile} <- webhook_work_profile(environment),
         {:ok, adapter} <- webhook_adapter(source),
         {:ok, lifecycle} <- webhook_lifecycle(source, repositories),
         :ok <- served_destination(destination, adapters),
         route = %{
           adapter: adapter,
           auth: {source.auth_kind, Secret.new(secret)},
           destination: destination,
           max_body_bytes: defaults.max_body_bytes,
           max_clock_skew_seconds: defaults.max_clock_skew_seconds,
           publication_lifecycle: lifecycle,
           work_profile: work_profile
         },
         :ok <- listener_accepts(source.name, route) do
      {:ok, route}
    end
  end

  defp webhook_secret(name) do
    case Credentials.fetch(:webhook, name) do
      {:ok, secret} -> {:ok, secret}
      {:error, :credential_missing} -> {:error, :credential_missing}
      {:error, _unreadable} -> {:error, :credential_unreadable}
    end
  end

  defp webhook_environment(environments, ref) do
    case Map.fetch(environments, ref) do
      {:ok, environment} -> {:ok, environment}
      :error -> {:error, :environment_cannot_run_work}
    end
  end

  defp webhook_work_profile(environment) do
    case Ingress.WorkProfile.new(environment.work_profile) do
      {:ok, profile} -> {:ok, profile}
      {:error, _reason} -> {:error, :environment_cannot_run_work}
    end
  end

  # The listener checks every route it is given before it starts, such as a
  # signing secret long enough for its kind, so a route it would refuse is
  # left out here rather than refusing the listener, and with it everything.
  defp listener_accepts(name, route) do
    route = Map.put(route, :name, name)

    case Webhooks.Route.new(route) do
      {:ok, _route} -> :ok
      {:error, {:invalid_webhook_route, :auth}} -> {:error, :secret_too_short}
      {:error, _refused} -> {:error, :route_invalid}
    end
  end

  # A saved mapping's field names, each with the name the route gives it.
  @mapping_fields Map.new(Webhooks.Route.mapping_fields(), &{Atom.to_string(&1), &1})

  defp webhook_adapter(%{adapter_kind: :universal}), do: {:ok, %{kind: :universal}}

  defp webhook_adapter(%{adapter_kind: :grafana} = source),
    do: {:ok, %{kind: :grafana, group_by_labels: source.group_by_labels}}

  defp webhook_adapter(%{adapter_kind: :mapped_json} = source) do
    if Enum.all?(Map.keys(source.mapping), &Map.has_key?(@mapping_fields, &1)) do
      {:ok,
       %{
         kind: :mapped_json,
         group_by_labels: source.group_by_labels,
         mapping:
           Map.new(source.mapping, fn {field, path} ->
             {Map.fetch!(@mapping_fields, field), path}
           end)
       }}
    else
      {:error, :mapping_unknown_field}
    end
  end

  defp webhook_lifecycle(%{publication_lifecycle: nil}, _repositories), do: {:ok, nil}

  # A stored scope is read as it was saved: a list it lacks is empty, which
  # the route refuses, so an older shape leaves this one source out.
  defp webhook_lifecycle(%{publication_lifecycle: scope}, repositories) do
    lifecycle =
      Map.new(Webhooks.Route.lifecycle_fields(), fn field ->
        {field, Enum.sort(scope[Atom.to_string(field)] || [])}
      end)

    if Enum.all?(lifecycle.repositories, &Map.has_key?(repositories, &1)),
      do: {:ok, lifecycle},
      else: {:error, :lifecycle_repository_unreviewed}
  end

  # Where a source posts must be a delivery target this configuration runs:
  # its transport assembled, and the exact channel, repository or Chat
  # conversation one of its bindings serves.
  defp served_destination(destination, adapters) do
    with {:ok, adapter} <- running_transport(adapters, destination.transport),
         {:ok, request} <- probe(destination) do
      served_target(request, adapter.binding)
    end
  end

  defp running_transport(adapters, transport) do
    case {Map.fetch(adapters, transport), transport} do
      {{:ok, adapter}, _transport} -> {:ok, adapter}
      {:error, "slack"} -> {:error, :slack_not_running}
      {:error, "github"} -> {:error, :github_not_running}
      {:error, _other} -> {:error, :destination_not_served}
    end
  end

  defp probe(destination) do
    case Delivery.Request.new(%{
           conversation_ref: destination.conversation_ref,
           document: %{"message" => "configuration probe"},
           kind: :message,
           ref: "configuration-probe",
           source_item_ref: nil,
           thread_ref: destination.thread_ref,
           transport: destination.transport
         }) do
      {:ok, request} -> {:ok, request}
      {:error, _invalid} -> {:error, :destination_not_served}
    end
  end

  defp served_target(%Delivery.Request{transport: "slack"} = request, binding) do
    with {:ok, target} <- Slack.Target.parse(request),
         true <-
           is_map(binding[:workspaces]) and
             Map.has_key?(binding.workspaces, target.workspace_ref) do
      :ok
    else
      _invalid -> {:error, :slack_workspace_not_served}
    end
  end

  defp served_target(%Delivery.Request{transport: "github"} = request, binding) do
    with {:ok, target} <- GitHub.Target.parse(request),
         {:ok, configured} <- Map.fetch(binding[:bindings] || %{}, target.binding),
         true <- configured.repository_id == target.repository_id do
      :ok
    else
      _invalid -> {:error, :github_repository_not_served}
    end
  end

  defp served_target(
         %Delivery.Request{
           transport: "control_plane",
           conversation_ref: "control-plane:lab:" <> conversation_id = conversation_ref,
           thread_ref: conversation_ref
         },
         _binding
       ) do
    case ControlPlane.ConversationLab.conversation_ref(conversation_id) do
      {:ok, ^conversation_ref} -> :ok
      {:error, _reason} -> {:error, :conversation_not_found}
    end
  end

  defp served_target(%Delivery.Request{}, _binding), do: {:error, :destination_not_served}

  # What a turn's tools are, served by the worker gateway at
  # `/v1/state-tools/mcp`. The machine secret signs each turn's token and
  # cursors; nothing listens for it on its own.
  defp state_tools(slack, github, control_plane, capabilities) do
    %{
      capabilities:
        capabilities
        |> Enum.filter(fn {_capability, enabled} -> enabled end)
        |> Enum.map(fn {capability, true} -> capability end)
        |> Enum.sort(),
      token: Secret.new(Bootstrap.secret!(:state_tools))
    }
    |> Map.put(:answer_authorizer, answer_authorizer(slack, control_plane))
    |> add_platform_capability_tools(slack, github, control_plane)
  end

  # Clarification answers are authorized by who can manage Ryker now, the
  # same check every Slack surface makes.
  defp answer_authorizer(slack, control_plane) do
    operators = slack && Slack.Runtime.operators(slack.runtime)

    fn
      %{source_kind: "slack", source_ref: workspace, actor_kind: :user, actor_ref: actor} ->
        not is_nil(slack) and workspace == slack.runtime.identity.workspace_ref and
          Slack.Operators.operator?(operators, actor)

      # Whoever reaches the console may manage Ryker: the local console's
      # operator, or a person Tailscale Serve or Cloudflare Access named.
      %{source_kind: "control_plane", source_ref: "local", actor_kind: :user, actor_ref: actor} ->
        not is_nil(control_plane) and
          (actor == "local-operator" or ControlPlane.Actor.chat_ref?(actor))

      _other ->
        false
    end
  end

  defp add_platform_capability_tools(configuration, slack, github, control_plane) do
    slack_tools =
      cond do
        slack -> Slack.CapabilityTools.list(slack.capability_tools)
        control_plane -> ControlPlane.CapabilityTools.list()
        true -> []
      end

    github_tools = if github, do: GitHub.CapabilityTools.list(github.capability_tools), else: []
    tools = slack_tools ++ github_tools
    names = Enum.map(tools, & &1["name"])

    if names != Enum.uniq(names),
      do: raise(ArgumentError, "platform capability-tool names must be unique")

    if tools == [] do
      configuration
    else
      # The closure keeps only the tools' own options. Capturing the whole
      # assembled GitHub and Slack parts captured repositories' setup progress
      # too, and the owner restarted every runtime holding it at each setup
      # step (2026-09-27).
      slack_tools = slack && slack.capability_tools
      github_tools = github && github.capability_tools
      control_plane? = not is_nil(control_plane)

      configuration
      |> Map.put(:additional_tools, tools)
      |> Map.put(
        :additional_call,
        &call_platform_tool(slack_tools, github_tools, control_plane?, &1, &2, &3)
      )
    end
  end

  defp call_platform_tool(slack_tools, github_tools, control_plane?, name, arguments, binding) do
    cond do
      not is_nil(github_tools) and
          Enum.any?(GitHub.CapabilityTools.list(github_tools), &(&1["name"] == name)) ->
        call_platform_package(GitHub.CapabilityTools, github_tools, name, arguments, binding)

      binding_transport(binding) == "slack" and not is_nil(slack_tools) ->
        call_platform_package(Slack.CapabilityTools, slack_tools, name, arguments, binding)

      binding_transport(binding) == "control_plane" and control_plane? ->
        if Enum.any?(ControlPlane.CapabilityTools.list(), &(&1["name"] == name)),
          do: ControlPlane.CapabilityTools.call(name, arguments, binding),
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
  defp validate_runtime!(Ryker.Waits.EventWaitWorker, _configuration), do: :ok
  defp validate_runtime!(module, configuration), do: module.options!(configuration)

  defp json_client!(base_url, receive_timeout, token_provider) do
    {:ok, client} =
      Delivery.JSONClient.new(%{
        base_url: base_url,
        finch: Ryker.CoopFinch,
        receive_timeout: receive_timeout,
        token_provider: token_provider
      })

    client
  end

  defp github_client!(http) do
    {:ok, client} = GitHub.Client.new(http: http, requester: Delivery.JSONClient)
    client
  end

  defp fleet_client!(workspace_ref, capabilities, receive_timeout_ms, poll_interval_ms, body_root) do
    max_waits = max(div(receive_timeout_ms + poll_interval_ms - 1, poll_interval_ms), 1)

    {:ok, client} =
      Ryker.CoopFleet.Client.new(
        body_root: body_root,
        source_root: Path.dirname(body_root),
        checkpoint_key: Secret.new(Bootstrap.checkpoint_key!()),
        capability_names: capabilities,
        capability_versions: Ryker.CoopFleet.Client.capability_versions(),
        max_waits: max_waits,
        poll_interval_ms: poll_interval_ms,
        workspace_ref: workspace_ref
      )

    {Ryker.CoopFleet.Client, client}
  end

  defp rpc_endpoint(url) do
    case Settings.EmisarConnection.endpoint(url) do
      {:ok, endpoint} -> {:ok, endpoint}
      :error -> {:error, :address_invalid}
    end
  end

  defp reject_nil_values(map),
    do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
end
