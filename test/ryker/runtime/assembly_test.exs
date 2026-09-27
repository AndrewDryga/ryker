defmodule Ryker.Runtime.AssemblyTest do
  # Assembly is the only place a product setting becomes a runtime binding. Every
  # case here is about that boundary: what an installation's saved connections
  # turn on, what they may never turn on, and what a refusal has to name.
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.{Bootstrap, Credentials, Settings}
  alias Ryker.ControlPlane.CapabilityTools, as: ControlPlaneCapabilityTools
  alias Ryker.CoopFleet.JobTemplates
  alias Ryker.Ingress.WorkProfile
  alias Ryker.RoutingExamples.Worker, as: RoutingExampleWorker
  alias Ryker.Runtime.Assembly
  alias Ryker.Slack.Runtime, as: SlackRuntime

  @actor "control-plane:local"
  @lab "control-plane:lab:6f1a0f38-0b74-4f77-9f20-7a0c1e2d3b44"
  @workspace "T0123456789"
  @channel "slack:T0123456789:C0123456789"
  @alert_secret "alertmanager-signing-secret-long-enough"
  @custody_secret "checkpoint-scan-secret-long-enough"
  @certificate_fields ~w(cacertfile ca_keyfile certfile keyfile)a

  setup_all do
    # The gateway refuses a certificate path that is not an existing file, so
    # the fixture supplies real ones rather than plausible names.
    File.mkdir_p!(certificates())
    Enum.each(@certificate_fields, &File.write!(certificate(&1), "placeholder"))
    on_exit(fn -> File.rm_rf!(certificates()) end)

    key = :public_key.generate_key({:rsa, 2_048, 65_537})
    %{pem: :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])}
  end

  setup %{pem: pem} do
    Process.put(:github_private_key_fixture, pem)

    deployment = %{
      "RYKER_CHECKPOINT_KEY" => Base.encode64(:crypto.strong_rand_bytes(32)),
      "RYKER_STATE_TOOLS_TOKEN" => "state-tools-token-for-tests"
    }

    Enum.each(deployment, fn {name, value} -> put_variable(name, value) end)

    execution = Application.get_env(:ryker, :execution)
    Application.put_env(:ryker, :execution, :fleet)
    on_exit(fn -> Application.put_env(:ryker, :execution, execution) end)

    :ok
  end

  test "a clean installation gives Chat and Slack the bundled installation profile" do
    {:ok, settings} = Settings.initialize(@actor)

    for {kind, token} <- [
          {:slack_app, "xapp-clean-install-token-long-enough"},
          {:slack_bot, "xoxb-clean-install-token-long-enough"}
        ] do
      assert {:ok, _credential} = Credentials.put(kind, "primary", token, @actor)
    end

    saves = [
      &Settings.save_work(%{workspace_ref: "ryker-compose"}, &1, @actor),
      &Settings.save_slack(
        %{
          enabled: true,
          workspace_ref: @workspace,
          bot_ref: "A0123456789",
          bot_user_ref: "U0123456789"
        },
        &1,
        @actor
      )
    ]

    Enum.reduce(saves, settings.installation.revision, fn save, revision ->
      {:ok, saved} = save.(revision)
      saved.installation.revision
    end)

    assert {:ok, configuration} = Assembly.build(bootstrap(), Settings.fetch!())

    chat =
      Enum.find(JobTemplates.from_settings(Settings.fetch!()), &(&1.policy_name == "ryker-chat"))

    assert configuration.control_plane.fallback_work_profile == %{
             authority_digest: chat.authority_digest,
             class_policies: %{
               conversational: %{
                 authority_digest: chat.authority_digest,
                 policy: "ryker-chat",
                 policy_digest: chat.policy_digest
               },
               deep: %{
                 authority_digest: chat.authority_digest,
                 policy: "ryker-chat",
                 policy_digest: chat.policy_digest
               },
               standard: %{
                 authority_digest: chat.authority_digest,
                 policy: "ryker-chat",
                 policy_digest: chat.policy_digest
               }
             },
             policy: "ryker-chat",
             policy_digest: chat.policy_digest,
             repository_ref: nil
           }

    refute Map.has_key?(configuration, :fleet_profiles)

    slack = SlackRuntime.options!(configuration.slack)

    assert {:ok, profile} =
             slack.handler_settings.work_profile.(@workspace, "slack:#{@workspace}:C0123456789")

    assert profile.policy == "ryker-chat"
    assert profile.repository_ref == nil
  end

  test "a fully connected installation assembles one lane per saved connection" do
    settings = connected!()
    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)
    assert configuration.work.connected == %{github: true, slack: true}

    # Every lane an enabled setting asks for, and nothing the settings did not.
    assert Enum.sort(Map.keys(configuration)) ==
             Enum.sort([
               :admission,
               :admission_ready,
               :control_plane,
               :coop_worker_gateway,
               :delivery,
               :emisar,
               :event_waits,
               :execution_mode,
               :github,
               :improvement,
               :learning,
               :publication,
               :retention,
               :schedules,
               :slack,
               :slack_names,
               :state_tools,
               :webhooks,
               :work
             ])

    # Every lease owner is keyed to the installation identity, never generated:
    # a new host_ref here strands the work, delivery and publication custody the
    # previous deployment recorded.
    host = settings.installation.host_ref

    assert configuration[:work].worker_ref == "#{host}:work"
    assert configuration[:admission].worker_ref == "#{host}:admission"
    assert configuration[:learning].worker_ref == "#{host}:learning"
    assert configuration[:improvement].worker_ref == "#{host}:improvement"
    assert configuration[:delivery].worker_ref == "#{host}:delivery"
    assert configuration[:publication].worker_ref == "#{host}:publication"
    assert configuration[:retention].worker_ref == "#{host}:retention"
    assert configuration[:schedules].worker_ref == "#{host}:schedules"
    assert [emisar] = configuration[:emisar].connections
    assert emisar.worker_ref == "#{host}:emisar:production"

    # The reviewed bindings decide the policies; a form never names one.
    assert configuration[:admission].policy == "ryker-admission"

    # Sessions kept ready are started with exactly the policy routing uses,
    # as many as the saved setting asks (one on a new installation).
    assert Map.take(configuration[:admission_ready], [:api, :client, :policy, :policy_digest]) ==
             Map.take(configuration[:admission], [:api, :client, :policy, :policy_digest])

    assert configuration[:admission_ready].target == 1
    assert configuration[:learning].policy == "ryker-learning"

    # Self-analysis asks the learning models, on learning's own policy and
    # adapter, in a lane of its own.
    assert Map.take(configuration[:improvement], [:api, :client, :policy, :policy_digest]) ==
             Map.take(configuration[:learning], [:api, :client, :policy, :policy_digest])

    assert configuration[:schedules].read_only_policy.name == "ryker-schedule-read-only"
    assert configuration[:schedules].governed_operation_policy.name == "ryker-schedule-governed"
    assert configuration[:schedules].repositories["ryker"].name == "ryker-repo-ryker-schedule"

    # Retention horizons are the operator's saved numbers, not code defaults.
    assert configuration[:retention].audit_data_seconds == 60 * 86_400
    assert configuration[:retention].conversation_memory_seconds == 90 * 86_400
    assert configuration[:retention].learning_api == configuration[:learning].api

    # Delivery reaches exactly the transports that assembled.
    assert Enum.sort(Map.keys(configuration[:delivery].adapters)) ==
             ["control_plane", "github", "slack"]

    assert configuration[:slack].identity.workspace_ref == @workspace
    assert configuration[:slack].operators == ["U1111111111"]
    assert configuration[:slack].default_environment == "platform"
    assert emisar.presentation_timeout_ms > 0
    assert configuration[:github].server.bindings["ryker-app"].installation_id == 1001
    assert configuration[:publication].repositories["ryker"].base_branch == "main"
  end

  test "changing how many routing sessions are kept ready leaves routing's lane as it was" do
    # The owner restarts every runtime whose configuration changed, and a
    # routing slot stopped mid-message leaves that message waiting out its
    # five-minute lease. The count of sessions kept ready therefore lives in a
    # lane of its own: changing it restarts the pool and nothing that routes.
    settings = connected!()
    assert {:ok, before} = Assembly.build(bootstrap(), settings)

    {:ok, settings} =
      Settings.save_work(%{ready_routing_sessions: 3}, settings.installation.revision, @actor)

    assert {:ok, changed} = Assembly.build(bootstrap(), settings)
    assert changed.admission == before.admission
    assert {before.admission_ready.target, changed.admission_ready.target} == {1, 3}

    {:ok, settings} =
      Settings.save_work(%{ready_routing_sessions: 0}, settings.installation.revision, @actor)

    # At 0 the pool still runs, to close what an earlier setting kept ready.
    assert {:ok, off} = Assembly.build(bootstrap(), settings)
    assert off.admission_ready.target == 0
  end

  # The local routing model only measures (Andrew, 2026-09-27). Turning it on,
  # pointing it elsewhere or turning it off must restart its own lane and
  # nothing else: a routing slot stopped mid-message leaves that message
  # waiting out its lease, for a comparison nobody reads in time.
  test "the local routing model runs a lane of its own while it compares, and touches no other" do
    settings = connected!()
    assert {:ok, before} = Assembly.build(bootstrap(), settings)
    refute Map.has_key?(before, :local_routing)

    {:ok, settings} =
      Settings.save_work(
        %{
          local_routing_mode: :shadow,
          local_routing_endpoint: "http://host.docker.internal:11434/v1",
          local_routing_model: "qwen2.5:3b"
        },
        settings.installation.revision,
        @actor
      )

    assert {:ok, shadow} = Assembly.build(bootstrap(), settings)

    assert shadow.local_routing == %{
             endpoint: "http://host.docker.internal:11434/v1",
             model: "qwen2.5:3b",
             max_attempts: 4,
             poll_interval_ms: 1_000,
             retry_base_seconds: 30,
             retry_max_seconds: 600,
             timeout_ms: 120_000
           }

    for key <- Map.keys(before), Map.get(before, key) != Map.get(shadow, key) do
      flunk("#{key} changed when the local routing model started comparing")
    end

    {:ok, settings} =
      Settings.save_work(%{local_routing_mode: :off}, settings.installation.revision, @actor)

    assert {:ok, off} = Assembly.build(bootstrap(), settings)
    assert off == before
  end

  # Found live 2026-09-27: every step of a repository's setup saves its state
  # to settings, and any runtime whose configuration changed is restarted, so
  # the setup worker was stopped mid-run by its own progress and every added
  # repository cycled through "cloning" and "scanning" for an hour.
  test "a repository's setup progress restarts no runtime" do
    settings = connected!()
    assert {:ok, before} = Assembly.build(bootstrap(), settings)

    {:ok, settings} =
      Settings.put_repository(
        %{
          ref: "ryker",
          onboarding_state: :scanning,
          onboarding_error: nil,
          source_commit: String.duplicate("a", 40)
        },
        settings.installation.revision,
        @actor
      )

    assert {:ok, changed} = Assembly.build(bootstrap(), settings)

    for key <- Map.keys(before), Map.get(before, key) != Map.get(changed, key) do
      flunk("#{key} changed with setup progress")
    end
  end

  test "an integration is enabled by its saved connection, never by a credential present" do
    # Every credential below is in the environment for this whole test. If a
    # credential could turn a lane on, a deployment that merely holds a token
    # would start talking to a workspace nobody connected.
    settings = connected!()

    {:ok, settings} =
      Settings.save_slack(%{enabled: false}, settings.installation.revision, @actor)

    {:ok, settings} =
      Settings.save_publication(%{enabled: false}, settings.installation.revision, @actor)

    {:ok, settings} =
      Settings.save_github(%{enabled: false}, settings.installation.revision, @actor)

    {:ok, settings} =
      Settings.put_emisar_connection(
        %{ref: "production", enabled_for_new_work: false, monitoring_enabled: false},
        settings.installation.revision,
        @actor
      )

    {:ok, settings} =
      Settings.save_learning(%{enabled: false}, settings.installation.revision, @actor)

    assert Credentials.status(:slack_bot, "primary").status == :configured
    assert Credentials.status(:emisar, "production").status == :configured

    # A route that delivers into Slack cannot outlive the Slack connection. It
    # is left out and named with why, so it never quietly disappears, and the
    # rest of the configuration still applies; refusing all of it kept every
    # newer setting from applying (QA P1 #4, 2026-09-25).
    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)
    assert configuration.integrations_left_out == %{webhooks: %{"alerts" => :slack_not_running}}
    refute Map.has_key?(configuration.webhooks.routes, "alerts")

    assert {:ok, configuration} = Assembly.build(bootstrap(), disconnect_webhooks(settings))

    for absent <- [:slack, :github, :emisar, :learning, :webhooks] do
      assert configuration[absent] == nil, "#{absent} started from a credential, not a setting"
    end

    # Self-analysis stays only to finish what is already out at Coop, so no
    # session of it is left open with people's words; it starts nothing new.
    assert configuration[:improvement].enabled == false

    # The model is told what is connected from what actually runs.
    assert configuration[:work].connected == %{github: false, slack: false}

    # The lanes that need no integration still run, and publication follows
    # GitHub out rather than publishing through nothing.
    assert configuration[:work]
    assert configuration[:control_plane]
    assert configuration[:publication].repositories == %{}
    assert Map.keys(configuration[:delivery].adapters) == ["control_plane"]
    assert configuration[:retention].learning_api == configuration[:work].api
  end

  test "publishing a configuration deletes the keys the new one does not carry" do
    # Leaving a key behind runs a previous deployment's binding under the new
    # configuration's name, which is invisible in every readiness check.
    previous = Map.new(Assembly.managed_keys(), &{&1, Application.fetch_env(:ryker, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:ryker, key, value, persistent: true)
        {key, :error} -> Application.delete_env(:ryker, key, persistent: true)
      end)
    end)

    settings = connected!()
    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)
    Assembly.publish(configuration)

    assert Application.get_env(:ryker, :slack).identity.workspace_ref == @workspace
    assert Application.get_env(:ryker, :emisar)

    {:ok, settings} =
      Settings.save_slack(%{enabled: false}, settings.installation.revision, @actor)

    {:ok, settings} =
      Settings.put_emisar_connection(
        %{ref: "production", enabled_for_new_work: false, monitoring_enabled: false},
        settings.installation.revision,
        @actor
      )

    assert {:ok, reduced} = Assembly.build(bootstrap(), disconnect_webhooks(settings))
    Assembly.publish(reduced)

    assert Application.get_env(:ryker, :slack) == nil
    assert Application.get_env(:ryker, :emisar) == nil
    assert Application.get_env(:ryker, :work)
  end

  test "a clarification answer is authorized by the saved operator list, not by who asks" do
    settings = connected!()
    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)
    authorize = configuration[:state_tools].answer_authorizer

    assert authorize.(answer(%{source_ref: @workspace, actor_ref: "U1111111111"}))

    # A user of the connected workspace who is not an operator, and an operator
    # identity arriving from some other workspace, are both refused.
    refute authorize.(answer(%{source_ref: @workspace, actor_ref: "U2222222222"}))
    refute authorize.(answer(%{source_ref: "T9999999999", actor_ref: "U1111111111"}))
    refute authorize.(answer(%{actor_kind: :bot, source_ref: @workspace}))

    assert authorize.(%{
             source_kind: "control_plane",
             source_ref: "local",
             actor_kind: :user,
             actor_ref: "local-operator"
           })

    refute authorize.(%{
             source_kind: "control_plane",
             source_ref: "remote",
             actor_kind: :user,
             actor_ref: "local-operator"
           })
  end

  test "a platform tool is dispatched by the episode's own transport and nothing else" do
    # The tool catalog is shared across transports. Dispatching by name alone
    # would let a GitHub episode call a Slack tool against the workspace.
    settings = connected!()
    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)
    tools = configuration[:state_tools].additional_tools
    call = configuration[:state_tools].additional_call

    names = Enum.map(tools, & &1["name"])
    assert names == Enum.uniq(names)
    assert names != []

    assert call.("no_such_tool", %{}, episode("slack")) == {:error, "unknown_tool"}
    assert call.(hd(names), %{}, episode("github")) == {:error, "unknown_tool"}
    assert call.(hd(names), %{}, %{}) == {:error, "unknown_tool"}
    assert call.(hd(names), %{}, episode("carrier-pigeon")) == {:error, "unknown_tool"}

    # A Conversation Lab episode reaches the lab's own tools, and a name that is
    # not one of them is refused rather than tried against another transport.
    [%{"name" => lab_tool} | _rest] = ControlPlaneCapabilityTools.list()
    assert {:error, reason} = call.(lab_tool, %{}, episode("control_plane"))
    assert is_binary(reason)
    assert call.("no_such_tool", %{}, episode("control_plane")) == {:error, "unknown_tool"}
  end

  # Consent: the copy runs only while a person keeps routing examples on, and
  # every stored credential is among what it removes from a copy.
  # A weekly report that is off must cost nothing: no process, no poll, no
  # log line. It runs only where it could post.
  test "the weekly report has a schedule only while it is on, names a channel and Slack can post it" do
    settings = connected!()
    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)
    refute Map.has_key?(configuration, :weekly_report)

    assert {:ok, on} =
             Settings.save_report(
               %{weekly_self_report_enabled: true, channel_ref: "C0123456789"},
               settings.installation.revision,
               @actor
             )

    assert {:ok, configuration} = Assembly.build(bootstrap(), on)
    assert configuration.weekly_report == %{}

    # Its day and time are read when it checks, so moving them restarts nothing.
    assert {:ok, moved} =
             Settings.save_report(
               %{weekday: 5, local_time: ~T[16:30:00]},
               on.installation.revision,
               @actor
             )

    assert {:ok, %{weekly_report: %{}}} = Assembly.build(bootstrap(), moved)

    # With Slack off nothing could post it.
    assert {:ok, disconnected} =
             Settings.save_slack(%{enabled: false}, moved.installation.revision, @actor)

    assert {:ok, configuration} = Assembly.build(bootstrap(), disconnected)
    refute Map.has_key?(configuration, :weekly_report)
  end

  test "routing examples are copied only while kept, with every stored credential redacted" do
    settings = connected!()
    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)
    assert configuration[:routing_examples] == nil
    assert configuration[:retention].routing_examples_enabled == false

    {:ok, kept} =
      Settings.save_retention(
        %{routing_examples_enabled: true, routing_examples_seconds: 180 * 86_400},
        settings.installation.revision,
        @actor
      )

    assert {:ok, configuration} = Assembly.build(bootstrap(), kept)
    copy = configuration[:routing_examples]
    assert copy.window_seconds == 180 * 86_400
    assert @alert_secret in copy.redaction_secrets
    assert @custody_secret in copy.redaction_secrets
    assert configuration[:retention].routing_examples_enabled == true
    assert configuration[:retention].routing_examples_seconds == 180 * 86_400
    assert RoutingExampleWorker.options!(copy) == copy
  end

  test "the worker gateway carries the checkpoint custody the deployment registered" do
    settings = connected!()
    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)
    gateway = configuration[:coop_worker_gateway]

    assert byte_size(gateway.checkpoint_key) == 32
    assert @alert_secret in gateway.checkpoint_secrets
    assert @custody_secret in gateway.checkpoint_secrets

    # Work reaches the state tools through the gateway's own public URL, and
    # both sides agree on the same capability list and the same token.
    assert configuration[:work].state_tools_endpoint ==
             "https://worker.example/v1/state-tools/mcp"

    assert configuration[:work].state_tool_capabilities == gateway.state_tools.capabilities
    assert configuration[:work].state_tools_secret == gateway.state_tools.token_secret
    assert configuration[:work].platform_tools == configuration[:state_tools].additional_tools
  end

  # Every session in an environment mounts all of its repositories, the one
  # its work changes as the working copy and the others read-only, so an
  # environment with several repositories runs on its own reviewed policies
  # for each repository, never on one repository's; one with a single
  # repository runs on that repository's. Before, work in an environment could
  # only change the first repository, on one policy set mounting it writable,
  # so a task on any other repository ran against the wrong working copy.
  test "work in an environment may change any of its repositories, mounting the rest read-only" do
    settings = connected!()
    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)
    environments = configuration[:slack].environments

    platform = environments["platform"]
    assert platform.display_name == "Platform"
    profile = platform.work_profile
    assert profile.environment_ref == "platform"
    assert profile.repositories == ["ryker", "docs"]
    assert profile.parallel_goal_limit == 2
    assert profile.emisar_connection_ref == "production"
    assert Map.keys(profile.policies) |> Enum.sort() == ["docs", "ryker"]

    assert profile.policies["ryker"].conversational.policy ==
             "ryker-env-platform-ryker-conversation"

    assert profile.policies["docs"].conversational.policy ==
             "ryker-env-platform-docs-conversation"

    refute Map.has_key?(profile, :policy)
    assert platform.github_repositories == %{"docs" => "ryker/docs", "ryker" => "ryker/ryker"}

    # A task runs under the environment's policy for the repository it
    # changes, with the others mounted read-only.
    tasks = configuration[:control_plane].task_policies["platform"]
    assert Map.keys(tasks) |> Enum.sort() == ["docs", "ryker"]
    assert tasks["ryker"].name == "ryker-env-platform-ryker-contributor"
    assert tasks["ryker"].environment_ref == "platform"
    assert tasks["ryker"].repository_ref == "ryker"

    assert tasks["ryker"].repository_context == %{
             "context_ref" => "platform",
             "parallel_goal_limit" => 2,
             "primary_repository" => "ryker",
             "read_only_repositories" => ["docs"]
           }

    assert tasks["docs"].name == "ryker-env-platform-docs-contributor"
    assert tasks["docs"].repository_context["primary_repository"] == "docs"
    assert tasks["docs"].repository_context["read_only_repositories"] == ["ryker"]

    # One repository: that repository's own policies, mounted alone.
    docs = environments["docs"].work_profile
    assert docs.repositories == ["docs"]
    assert docs.policies["docs"].conversational.policy == "ryker-repo-docs-conversation"

    assert configuration[:control_plane].task_policies["docs"]["docs"].name ==
             "ryker-repo-docs-contributor"

    # Without repositories an environment answers on the installation's own
    # policy, keeps its Emisar account and has nothing a task could change.
    ops = environments["ops"]
    assert ops.work_profile.repository_ref == nil
    assert ops.work_profile.policy == "ryker-chat"
    assert ops.work_profile.emisar_connection_ref == "production"
    refute Map.has_key?(configuration[:control_plane].task_policies, "ops")

    route = configuration[:webhooks].routes["alerts"].work_profile
    assert route.environment_ref == "platform"
    assert route.repositories == ["ryker", "docs"]

    # A new environment gets templates from its authorized repository list.
    {:ok, changed} =
      Settings.put_environment(
        %{ref: "combined", display_name: "Combined", repositories: ["docs", "ryker"]},
        settings.installation.revision,
        @actor
      )

    assert {:ok, configuration} = Assembly.build(bootstrap(), changed)

    assert configuration.slack.environments["combined"].work_profile.repositories == [
             "docs",
             "ryker"
           ]

    assert Map.has_key?(configuration.control_plane.task_policies, "combined")
  end

  # Each Chat conversation picks its environment, so the console receives
  # every environment that can run work and the profile of work outside any;
  # a conversation whose environment cannot run work right now runs outside.
  # Before, Chat ran in the default environment only, whatever a conversation
  # was about.
  test "Chat receives every runnable environment and the profile outside any" do
    settings = connected!()
    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)

    assert Map.keys(configuration.control_plane.environments) |> Enum.sort() ==
             ["docs", "ops", "platform"]

    assert configuration.control_plane.environments["platform"] == %{
             display_name: "Platform",
             work_profile: configuration[:slack].environments["platform"].work_profile
           }

    assert configuration.control_plane.fallback_work_profile.policy == "ryker-chat"
    refute Map.has_key?(configuration.control_plane.fallback_work_profile, :environment_ref)
    assert configuration[:slack].default_environment == "platform"

    assert configuration[:slack].fallback_work_profile ==
             configuration.control_plane.fallback_work_profile

    {:ok, changed} =
      Settings.put_environment(
        %{
          ref: "unreviewed",
          display_name: "Unreviewed",
          repositories: ["docs", "ryker"],
          is_default: true
        },
        settings.installation.revision,
        @actor
      )

    assert {:ok, configuration} = Assembly.build(bootstrap(), changed)
    assert Map.has_key?(configuration.control_plane.environments, "unreviewed")
    # Losing source access makes every dependent environment unavailable.
    repository = Repo.get_by!(Settings.Repository, ref: "docs")
    repository |> Ecto.Changeset.change(github_access: :suspended) |> Repo.update!()
    assert {:ok, configuration} = Assembly.build(bootstrap(), Settings.fetch!())
    refute Map.has_key?(configuration.control_plane.environments, "unreviewed")
    assert configuration.control_plane.fallback_work_profile.policy == "ryker-chat"
    # Slack still seeds joined channels with the saved default, so they work
    # in it once it can run work; until then their work runs outside any.
    assert configuration[:slack].default_environment == "unreviewed"
    refute Map.has_key?(configuration[:slack].environments, "unreviewed")
  end

  # GitHub events for a repository run in the environment whose default
  # repository it is; a repository other environments hold runs in the first
  # of those, as the default choice of the work it starts; a repository in
  # none runs on its own, without an environment.
  test "a GitHub event runs where its repository is the default, else where it is held, else alone" do
    settings = connected!()

    saves = [
      &Settings.put_repository(%{ref: "tools", github_repository: "ryker/tools"}, &1, @actor),
      &github_binding("docs-app", "docs", 2002, &1),
      &github_binding("tools-app", "tools", 2003, &1)
    ]

    Enum.reduce(saves, settings.installation.revision, fn save, revision ->
      {:ok, saved} = save.(revision)
      saved.installation.revision
    end)

    assert {:ok, configuration} = Assembly.build(bootstrap(), Settings.fetch!())
    bindings = configuration.github.server.bindings

    assert bindings["ryker-app"].work_profile.environment_ref == "platform"
    assert bindings["docs-app"].work_profile.environment_ref == "docs"
    assert bindings["tools-app"].work_profile.environment_ref == nil
    assert bindings["tools-app"].work_profile.repository_ref == "tools"

    {:ok, without_docs} =
      Settings.delete_environment("docs", Settings.fetch!().installation.revision, @actor)

    assert {:ok, configuration} = Assembly.build(bootstrap(), without_docs)
    docs = configuration.github.server.bindings["docs-app"].work_profile
    assert docs.environment_ref == "platform"
    # An event is about its own repository, so that repository is the default
    # choice of the work it starts, with the rest of the environment beside it.
    assert docs.repositories == ["docs", "ryker"]

    assert {:ok, %WorkProfile{repository_ref: "docs"}} =
             WorkProfile.prepare(docs)
  end

  # Andrew, 2026-09-27: "can we here limit read or read/write access per
  # repo?" The access chosen on an environment has to reach the workspace
  # every session there mounts: a read-only repository is mounted beside the
  # one work changes and is never the working copy itself, so no task is
  # placed in it, routing is not offered it, and a GitHub event about it runs
  # with the environment's default as the working copy. Made read and write
  # again, it can be the working copy again.
  test "a repository's access reaches the workspace every session in its environment mounts" do
    settings = connected!()

    {:ok, bound} = github_binding("docs-app", "docs", 2002, settings.installation.revision)
    {:ok, alone} = Settings.delete_environment("docs", bound.installation.revision, @actor)

    {:ok, limited} =
      Settings.put_environment(
        %{ref: "platform", access: %{"docs" => :read_only}},
        alone.installation.revision,
        @actor
      )

    assert {:ok, configuration} = Assembly.build(bootstrap(), limited)
    platform = configuration[:slack].environments["platform"]
    assert {:ok, profile} = WorkProfile.prepare(platform.work_profile)

    # Both repositories are mounted, the default first; only one may change.
    assert profile.repositories == ["ryker", "docs"]
    assert WorkProfile.repository_refs(profile) == ["ryker"]
    assert WorkProfile.read_only_refs(profile) == ["docs"]
    assert WorkProfile.repository_choices(profile) == []

    assert {:error, {:invalid_work_profile, :repository_ref}} =
             WorkProfile.policy_for(profile, :standard, "docs")

    assert {:ok, placement} = WorkProfile.policy_for(profile, :standard, nil)
    assert placement.repository_ref == "ryker"

    assert placement.repository_context == %{
             "context_ref" => "platform",
             "parallel_goal_limit" => 2,
             "primary_repository" => "ryker",
             "read_only_repositories" => ["docs"]
           }

    # A task that changes code is placed only in the read and write one, from
    # Slack, Chat and GitHub alike; GitHub still names both.
    assert Map.keys(platform.contributor_policies) == ["ryker"]
    assert Map.keys(configuration[:control_plane].task_policies["platform"]) == ["ryker"]
    assert platform.github_repositories == %{"docs" => "ryker/docs", "ryker" => "ryker/ryker"}

    github = configuration.github.server
    refute Map.has_key?(github.confirmations.repositories, "docs")
    assert github.bindings["docs-app"].work_profile.repositories == ["ryker", "docs"]

    {:ok, opened} =
      Settings.put_environment(
        %{ref: "platform", access: %{"docs" => :read_write}},
        limited.installation.revision,
        @actor
      )

    assert {:ok, configuration} = Assembly.build(bootstrap(), opened)

    assert {:ok, profile} =
             WorkProfile.prepare(configuration[:slack].environments["platform"].work_profile)

    assert WorkProfile.repository_choices(profile) == ["ryker", "docs"]

    assert {:ok, %{repository_ref: "docs", repository_context: context}} =
             WorkProfile.policy_for(profile, :standard, "docs")

    assert context["primary_repository"] == "docs"
    assert context["read_only_repositories"] == ["ryker"]
    github = configuration.github.server
    assert Map.has_key?(github.confirmations.repositories, "docs")
    assert github.bindings["docs-app"].work_profile.repositories == ["docs", "ryker"]
  end

  test "a webhook source keeps the provider shape it was saved with" do
    settings = connected!()
    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)
    routes = configuration[:webhooks].routes

    assert routes["alerts"].adapter == %{kind: :grafana, group_by_labels: ["cluster", "service"]}
    assert routes["custom"].adapter.kind == :mapped_json

    assert routes["custom"].adapter.mapping == %{
             event_id: "id",
             status: "state",
             title: "subject"
           }

    assert routes["deploys"].publication_lifecycle == %{
             environments: ["production"],
             kinds: ["deployment"],
             repositories: ["ryker"],
             targets: ["ryker"]
           }
  end

  test "unreviewed repositories can receive metadata but cannot start work" do
    # Metadata alone is insufficient: source identity and GitHub access are required.
    # Settings accepts each of these because the repository exists, and every
    # runtime that would act under its authority refuses before anything starts.
    settings = connected!()

    {:ok, _saved} =
      Settings.put_repository(
        %{ref: "unreviewed", github_repository: "acme/unreviewed"},
        settings.installation.revision,
        @actor
      )

    {:ok, _saved} =
      Settings.put_environment(
        %{ref: "unreviewed", display_name: "Unreviewed", repositories: ["unreviewed"]},
        Settings.fetch!().installation.revision,
        @actor
      )

    refusals = [
      {&lifecycle_naming/1, "deploys", :lifecycle_repository_unreviewed},
      {&webhook_environment_naming/1, "custom", :environment_cannot_run_work}
    ]

    for {save, name, reason} <- refusals do
      {:ok, changed} = save.(Settings.fetch!().installation.revision)

      # The source that would act under an unreviewed repository is left out
      # and named with why; nothing else is refused because of it.
      assert {:ok, configuration} = Assembly.build(bootstrap(), changed)
      assert configuration.integrations_left_out.webhooks[name] == reason
      refute Map.has_key?(configuration.webhooks.routes, name)

      # The setting stays exactly as the operator wrote it; only the runtime refuses.
      assert Settings.fetch!().installation.revision == changed.installation.revision
    end

    for name <- ["custom", "deploys"] do
      {:ok, _settings} =
        Settings.delete_webhook_source(
          name,
          Settings.fetch!().installation.revision,
          @actor
        )
    end

    {:ok, changed} = github_binding_naming(Settings.fetch!().installation.revision)
    assert {:ok, configuration} = Assembly.build(bootstrap(), changed)
    assert configuration.github.server.bindings["unreviewed-app"].work_profile == nil
    refute Map.has_key?(configuration.control_plane.task_policies, "unreviewed")
  end

  defp lifecycle_naming(revision) do
    Settings.put_webhook_source(
      %{
        name: "deploys",
        publication_lifecycle: %{
          "environments" => ["production"],
          "kinds" => ["deployment"],
          "repositories" => ["unreviewed"],
          "targets" => ["ryker"]
        }
      },
      revision,
      @actor
    )
  end

  defp webhook_environment_naming(revision),
    do:
      Settings.put_webhook_source(
        %{name: "custom", environment_ref: "unreviewed"},
        revision,
        @actor
      )

  defp github_binding(name, repository_ref, repository_id, revision) do
    {:ok, _} =
      Settings.put_github_binding(
        %{
          name: name,
          repository_ref: repository_ref,
          installation_id: 1001,
          repository_id: repository_id,
          ryker_actor_id: 3001
        },
        revision,
        @actor
      )

    pin_repository!(repository_ref)
    {:ok, Settings.fetch!()}
  end

  defp pin_repository!(ref) do
    repository = Repo.get_by!(Settings.Repository, ref: ref)

    repository
    |> Ecto.Changeset.change(source_commit: String.duplicate("a", 40))
    |> Repo.update!()
  end

  defp github_binding_naming(revision) do
    Settings.put_github_binding(
      %{
        name: "unreviewed-app",
        repository_ref: "unreviewed",
        installation_id: 1002,
        repository_id: 2002,
        ryker_actor_id: 3002
      },
      revision,
      @actor
    )
  end

  test "a webhook destination that is not a configured delivery target is left out with why" do
    # A route whose destination cannot be delivered to would accept events into
    # a dead end, so it never starts; it is named with the reason instead of
    # refusing every other setting with it.
    connected!()

    for {conversation, thread, transport, reason} <- [
          {"slack:T9999999999:C0123456789", nil, "slack", :slack_workspace_not_served},
          {"github:unbound-app:repository:2001", "github:unbound-app:issue:1", "github",
           :github_repository_not_served},
          {"github:ryker-app:repository:9999", "github:ryker-app:issue:1", "github",
           :github_repository_not_served},
          {"control-plane:lab:not-a-conversation", "control-plane:lab:not-a-conversation",
           "control_plane", :conversation_not_found},
          {"control-plane:local", "control-plane:local", "control_plane", :destination_not_served}
        ] do
      {:ok, changed} =
        Settings.put_webhook_source(
          %{
            name: "alerts",
            destination_transport: transport,
            destination_conversation_ref: conversation,
            destination_thread_ref: thread
          },
          Settings.fetch!().installation.revision,
          @actor
        )

      assert {:ok, configuration} = Assembly.build(bootstrap(), changed)

      assert configuration.integrations_left_out == %{webhooks: %{"alerts" => reason}},
             "#{transport} destination was accepted"

      refute Map.has_key?(configuration.webhooks.routes, "alerts")
    end

    # Restoring the saved destination serves the source again.
    {:ok, restored} =
      Settings.put_webhook_source(
        %{
          name: "alerts",
          destination_transport: "slack",
          destination_conversation_ref: @channel,
          destination_thread_ref: nil
        },
        Settings.fetch!().installation.revision,
        @actor
      )

    assert {:ok, configuration} = Assembly.build(bootstrap(), restored)
    assert Map.has_key?(configuration.webhooks.routes, "alerts")
    refute Map.has_key?(configuration, :integrations_left_out)
  end

  test "a webhook source Ryker cannot serve is left out, and every other setting still applies" do
    # A route Ryker could not serve refused the whole configuration, so one
    # source posting into a Slack that was switched off, or one short signing
    # secret (QA P1 #4, 2026-09-25: one five-character secret stopped every
    # apply), kept every newer setting of every kind from applying. The source
    # is left out and named with its reason instead, and the Integrations
    # state reads that and says which source is not running and why.
    settings = connected!()
    unreviewed_environment!()
    {:ok, _} = Credentials.put(:webhook, "short", String.duplicate("s", 20), @actor)

    for {name, change, reason} <- [
          {"alerts", &Settings.save_slack(%{enabled: false}, &1, @actor), :slack_not_running},
          {"custom", &webhook_environment_naming/1, :environment_cannot_run_work},
          {"deploys", &lifecycle_naming/1, :lifecycle_repository_unreviewed},
          {"deploys", &source_secret("deploys", "gone", &1), :credential_missing},
          {"custom", &source_secret("custom", "short", &1), :secret_too_short}
        ] do
      {:ok, changed} = change.(Settings.fetch!().installation.revision)

      assert {:ok, configuration} = Assembly.build(bootstrap(), changed),
             "#{name} (#{reason}) refused the whole configuration"

      assert configuration.integrations_left_out == %{webhooks: %{name => reason}}
      refute Map.has_key?(configuration.webhooks.routes, name)

      assert Enum.sort(Map.keys(configuration.webhooks.routes)) ==
               Enum.sort(["alerts", "custom", "deploys"] -- [name])

      # Everything else a setting turns on is still there.
      assert configuration.work
      assert configuration.control_plane
      assert configuration.github

      restore!(settings)
    end

    # With no source Ryker can serve, nothing listens, and each says why.
    {:ok, changed} =
      Settings.save_slack(%{enabled: false}, Settings.fetch!().installation.revision, @actor)

    {:ok, changed} = webhook_environment_naming(changed.installation.revision)
    {:ok, changed} = source_secret("deploys", "gone", changed.installation.revision)

    assert {:ok, configuration} = Assembly.build(bootstrap(), changed)
    assert configuration[:webhooks] == nil

    assert configuration.integrations_left_out == %{
             webhooks: %{
               "alerts" => :slack_not_running,
               "custom" => :environment_cannot_run_work,
               "deploys" => :credential_missing
             }
           }

    # A clean installation publishes no such list, and publishing removes an old one.
    restore!(settings)
    assert {:ok, clean} = Assembly.build(bootstrap(), Settings.fetch!())
    refute Map.has_key?(clean, :integrations_left_out)
    assert :integrations_left_out in Assembly.managed_keys()
  end

  defp unreviewed_environment! do
    {:ok, _saved} =
      Settings.put_repository(
        %{ref: "unreviewed", github_repository: "acme/unreviewed"},
        Settings.fetch!().installation.revision,
        @actor
      )

    {:ok, _saved} =
      Settings.put_environment(
        %{ref: "unreviewed", display_name: "Unreviewed", repositories: ["unreviewed"]},
        Settings.fetch!().installation.revision,
        @actor
      )
  end

  defp source_secret(name, secret, revision),
    do: Settings.put_webhook_source(%{name: name, secret_name: secret}, revision, @actor)

  # Puts back the Slack connection and the three sources `connected!/0` saved.
  defp restore!(original) do
    {:ok, _} =
      Settings.save_slack(%{enabled: true}, Settings.fetch!().installation.revision, @actor)

    for source <- original.webhook_sources do
      {:ok, _} =
        Settings.put_webhook_source(
          Map.take(source, [
            :name,
            :environment_ref,
            :secret_name,
            :publication_lifecycle,
            :destination_transport,
            :destination_conversation_ref,
            :destination_thread_ref
          ]),
          Settings.fetch!().installation.revision,
          @actor
        )
    end
  end

  test "an enabled GitHub App whose key or secret is missing or broken is left out and named" do
    # A broken private key refused the whole configuration ("The saved GitHub
    # App private key is not usable"), so one bad credential kept every newer
    # setting of every kind from applying. GitHub is left out of the running
    # system, named with why for the Integrations state, and the rest runs.
    settings = connected!()
    key = Process.get(:github_private_key_fixture)

    for {break, reason} <- [
          {&Credentials.put(:github_private_key, "primary", "not-an-app-key-but-long-enough", &1),
           :private_key_unusable},
          {&Credentials.delete(:github_private_key, "primary", &1), :private_key_missing},
          {&Credentials.delete(:github_webhook, "primary", &1), :webhook_secret_missing}
        ] do
      {:ok, _} = break.(@actor)

      assert {:ok, configuration} = Assembly.build(bootstrap(), settings),
             "#{reason} refused the whole configuration"

      assert configuration.integrations_left_out == %{github: reason}
      assert configuration[:github] == nil
      refute Map.has_key?(configuration.delivery.adapters, "github")
      assert configuration.publication.repositories == %{}
      assert configuration.slack
      assert configuration.emisar

      {:ok, _} = Credentials.put(:github_private_key, "primary", key, @actor)

      {:ok, _} =
        Credentials.put(:github_webhook, "primary", "github-webhook-secret-long-enough", @actor)
    end
  end

  test "Slack switched on that cannot start is left out and named, never silently" do
    settings = connected!()

    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)
    assert configuration.slack

    # A saved value Slack's runtime refuses, such as an operator saved before
    # today's checks, refused every setting of every kind.
    Repo.update_all(from(slack in Settings.Slack), set: [operators: ["not-a-slack-id"]])

    assert {:ok, configuration} = Assembly.build(bootstrap(), Settings.fetch!()),
           "one refused Slack value refused the whole configuration"

    assert configuration[:slack] == nil
    assert configuration.integrations_left_out.slack == :settings_unusable
    assert configuration.github
    assert configuration.emisar
  end

  test "an Emisar account with an address Ryker cannot use is left out, and the others run" do
    # An address saved before today's checks, such as an origin without the
    # RPC path, refused the whole configuration ("The saved Emisar RPC
    # endpoint must be an exact HTTPS URL").
    connected!()
    {:ok, _} = Credentials.put(:emisar, "staging", "emisar-staging-token-long-enough", @actor)

    {:ok, _} =
      Settings.put_emisar_connection(
        %{
          ref: "staging",
          display_name: "Staging approvals",
          rpc_url: "https://staging.emisar.dev/api/mcp/rpc",
          account_ref: "account-staging",
          account_label: "Staging",
          verified_at: ~U[2026-09-19 12:00:00.000000Z]
        },
        Settings.fetch!().installation.revision,
        @actor
      )

    Repo.update_all(
      from(connection in Settings.EmisarConnection, where: connection.ref == "production"),
      set: [rpc_url: "https://emisar.dev"]
    )

    assert {:ok, configuration} = Assembly.build(bootstrap(), Settings.fetch!()),
           "one Emisar account refused the whole configuration"

    assert [staging] = configuration.emisar.connections
    assert staging.connection_ref == "staging"
    assert configuration.integrations_left_out == %{emisar: %{"production" => :address_invalid}}
    assert configuration.github
    assert configuration.slack
  end

  test "integrations that cannot start leave every other lane running" do
    # No single broken integration, or all of them at once, may take the
    # rest of Ryker's running system down with it.
    connected!()

    {:ok, _} =
      Credentials.put(:github_private_key, "primary", "not-an-app-key-but-long-enough", @actor)

    Repo.update_all(from(slack in Settings.Slack), set: [operators: ["not-a-slack-id"]])

    Repo.update_all(from(connection in Settings.EmisarConnection),
      set: [rpc_url: "https://emisar.dev"]
    )

    assert {:ok, configuration} = Assembly.build(bootstrap(), Settings.fetch!())

    for lane <- [
          :admission,
          :admission_ready,
          :control_plane,
          :coop_worker_gateway,
          :delivery,
          :event_waits,
          :learning,
          :publication,
          :retention,
          :schedules,
          :state_tools,
          :webhooks,
          :work
        ] do
      assert configuration[lane], "#{lane} stopped because an integration could not start"
    end

    for broken <- [:github, :slack, :emisar], do: assert(configuration[broken] == nil)

    assert configuration.integrations_left_out == %{
             emisar: %{"production" => :address_invalid},
             github: :private_key_unusable,
             slack: :settings_unusable,
             webhooks: %{"alerts" => :slack_not_running}
           }

    assert configuration.work.connected == %{github: false, slack: false}
  end

  test "a GitHub App key is accepted as PEM or base64 and a broken one is named" do
    settings = connected!()
    assert {:ok, _pem_configuration} = Assembly.build(bootstrap(), settings)

    {:ok, pem} = Credentials.fetch(:github_private_key, "primary")
    {:ok, _} = Credentials.put(:github_private_key, "primary", Base.encode64(pem), @actor)
    assert {:ok, _encoded_configuration} = Assembly.build(bootstrap(), settings)

    {:ok, _} =
      Credentials.put(
        :github_private_key,
        "primary",
        "not-an-app-key-but-long-enough",
        @actor
      )

    # A broken one leaves GitHub out and names it, never quoting the key.
    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)
    assert configuration.integrations_left_out == %{github: :private_key_unusable}
    refute inspect(configuration.integrations_left_out) =~ "not-an-app-key"
  end

  test "Emisar needs the exact HTTPS RPC endpoint, not an origin to guess from" do
    settings = connected!()

    for url <- ["https://emisar.dev", "http://emisar.dev/api/mcp/rpc"] do
      assert {:error, {:invalid_settings, errors}} =
               Settings.put_emisar_connection(
                 %{ref: "production", rpc_url: url},
                 settings.installation.revision,
                 @actor
               )

      assert {:rpc_url, :format} in errors
    end

    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)
    assert [emisar] = configuration[:emisar].connections
    assert emisar.client.rpc_path == "/api/mcp/rpc"
  end

  test "an unplaced Work lane leaves every lane that needs a worker unassembled" do
    # Work placement is an operator choice. Until it is made, admission,
    # learning, retention and publication have no authority to run under.
    settings = connected!()

    {:ok, unplaced} =
      Settings.save_work(%{workspace_ref: nil}, settings.installation.revision, @actor)

    assert {:ok, configuration} = Assembly.build(bootstrap(), unplaced)

    for absent <- [
          :work,
          :admission,
          :admission_ready,
          :learning,
          :improvement,
          :retention,
          :publication
        ] do
      assert configuration[absent] == nil, "#{absent} assembled without a Work placement"
    end

    assert configuration[:slack]
    assert configuration[:control_plane].coop_api == nil
    refute Map.has_key?(configuration[:coop_worker_gateway], :state_tools)
  end

  defp answer(overrides) do
    Map.merge(
      %{
        source_kind: "slack",
        source_ref: @workspace,
        actor_kind: :user,
        actor_ref: "U1111111111"
      },
      overrides
    )
  end

  defp episode(transport), do: %{episode: %{destination_transport: transport}}

  defp disconnect_webhooks(settings) do
    {:ok, settings} =
      Settings.put_webhook_source(
        %{name: "alerts", enabled: false},
        settings.installation.revision,
        @actor
      )

    {:ok, settings} =
      Settings.put_webhook_source(
        %{name: "custom", enabled: false},
        settings.installation.revision,
        @actor
      )

    {:ok, settings} =
      Settings.put_webhook_source(
        %{name: "deploys", enabled: false},
        settings.installation.revision,
        @actor
      )

    settings
  end

  # One installation with every product connection an operator can make, so the
  # assembled result is the whole boundary rather than one lane at a time.
  defp connected! do
    {:ok, _fresh} = Settings.initialize(@actor)

    credentials = [
      {:slack_app, "primary", "xapp-slack-app-token-long-enough"},
      {:slack_bot, "primary", "xoxb-slack-bot-token-long-enough"},
      {:github_private_key, "primary", Process.get(:github_private_key_fixture)},
      {:github_webhook, "primary", "github-webhook-secret-long-enough"},
      {:emisar, "production", "emisar-api-token-long-enough"},
      {:webhook, "alerts", @alert_secret},
      {:webhook, "custom", @custody_secret},
      {:webhook, "deploys", @alert_secret}
    ]

    Enum.each(credentials, fn {kind, name, value} ->
      assert {:ok, _} = Credentials.put(kind, name, value, @actor)
    end)

    saves = [
      &Settings.save_retention(%{audit_data_seconds: 60 * 86_400}, &1, @actor),
      &Settings.put_repository(
        %{
          ref: "ryker",
          github_repository: "ryker/ryker"
        },
        &1,
        @actor
      ),
      &Settings.put_repository(%{ref: "docs", github_repository: "ryker/docs"}, &1, @actor),
      &Settings.save_work(%{workspace_ref: "ryker-local-main"}, &1, @actor),
      &Settings.save_learning(%{enabled: true}, &1, @actor),
      &Settings.put_emisar_connection(
        %{
          ref: "production",
          display_name: "Production approvals",
          rpc_url: "https://emisar.dev/api/mcp/rpc",
          account_ref: "account-production",
          account_label: "Production",
          enabled_for_new_work: true,
          monitoring_enabled: true,
          verified_at: ~U[2026-09-19 12:00:00.000000Z]
        },
        &1,
        @actor
      ),
      &Settings.put_environment(
        %{
          ref: "platform",
          display_name: "Platform",
          repositories: ["ryker", "docs"],
          parallel_goal_limit: 2,
          emisar_connection_ref: "production",
          is_default: true
        },
        &1,
        @actor
      ),
      &Settings.put_environment(
        %{ref: "docs", display_name: "Docs", repositories: ["docs"]},
        &1,
        @actor
      ),
      &Settings.put_environment(
        %{ref: "ops", display_name: "Ops", emisar_connection_ref: "production"},
        &1,
        @actor
      ),
      &Settings.save_slack(
        %{
          enabled: true,
          workspace_ref: @workspace,
          bot_ref: "A0123456789",
          bot_user_ref: "U0123456789",
          operators: ["U1111111111"]
        },
        &1,
        @actor
      ),
      &Settings.save_github(
        %{enabled: true, app_id: 12_345, app_slug: "ryker-test"},
        &1,
        @actor
      ),
      &Settings.put_github_binding(
        %{
          name: "ryker-app",
          repository_ref: "ryker",
          installation_id: 1001,
          repository_id: 2001,
          ryker_actor_id: 3001
        },
        &1,
        @actor
      ),
      &github_binding("docs-app", "docs", 2002, &1),
      &Settings.save_publication(%{enabled: true}, &1, @actor),
      &Settings.put_webhook_source(
        source("alerts", %{
          adapter_kind: :grafana,
          auth_kind: :bearer,
          group_by_labels: ["cluster", "service"],
          destination_transport: "slack",
          destination_conversation_ref: @channel,
          destination_thread_ref: nil
        }),
        &1,
        @actor
      ),
      &Settings.put_webhook_source(
        source("custom", %{
          adapter_kind: :mapped_json,
          mapping: %{"event_id" => "id", "status" => "state", "title" => "subject"}
        }),
        &1,
        @actor
      ),
      &Settings.put_webhook_source(
        source("deploys", %{
          publication_lifecycle: %{
            "environments" => ["production"],
            "kinds" => ["deployment"],
            "repositories" => ["ryker"],
            "targets" => ["ryker"]
          }
        }),
        &1,
        @actor
      )
    ]

    revision =
      Enum.reduce(saves, 1, fn save, revision ->
        {:ok, saved} = save.(revision)
        saved.installation.revision
      end)

    Enum.each(["ryker", "docs"], &pin_repository!/1)
    settings = Settings.fetch!()
    assert settings.installation.revision == revision
    settings
  end

  defp source(name, overrides) do
    Map.merge(
      %{
        name: name,
        adapter_kind: :universal,
        auth_kind: :hmac_sha256,
        secret_name: "alerts",
        destination_transport: "control_plane",
        destination_conversation_ref: @lab,
        destination_thread_ref: @lab,
        environment_ref: "platform"
      },
      overrides
    )
  end

  defp bootstrap do
    %Bootstrap{
      repo: [url: "ecto://ryker@localhost/ryker", pool_size: 2],
      control_plane: %{ip: {127, 0, 0, 1}, port: 4321},
      state_tools: %{ip: {127, 0, 0, 1}, port: 4318},
      worker_gateway:
        Map.merge(Map.new(@certificate_fields, &{&1, certificate(&1)}), %{
          ip: {127, 0, 0, 1},
          port: 4322,
          public_url: "https://worker.example"
        }),
      github_listener: %{ip: {127, 0, 0, 1}, port: 4319},
      github_public_url: "http://127.0.0.1:4319/v1/github",
      webhook_listener: %{ip: {127, 0, 0, 1}, port: 4320},
      webhook_public_url: "http://127.0.0.1:4320",
      storage_root: "/tmp/ryker-assembly-test",
      credential_key: :binary.copy(<<73>>, 32),
      log_level: :warning
    }
  end

  defp certificate(field), do: Path.join(certificates(), "#{field}.pem")

  # One folder per test VM: a fixed name let two worktrees' runs delete each
  # other's certificates mid-test ("cacertfile must be an existing absolute
  # file", seventeen failures at once).
  defp certificates,
    do: Path.join(System.tmp_dir!(), "ryker-assembly-test-certificates-#{System.pid()}")

  defp put_variable(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)
    on_exit(fn -> restore_variable(name, previous) end)
  end

  defp restore_variable(name, nil), do: System.delete_env(name)
  defp restore_variable(name, previous), do: System.put_env(name, previous)
end
