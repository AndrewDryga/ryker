defmodule Ryker.Runtime.AssemblyTest do
  # Assembly is the only place a product setting becomes a runtime binding. Every
  # case here is about that boundary: what an installation's saved connections
  # turn on, what they may never turn on, and what a refusal has to name.
  use Ryker.DataCase, async: false

  alias Ryker.{Bootstrap, Credentials, Settings}
  alias Ryker.ControlPlane.CapabilityTools, as: ControlPlaneCapabilityTools
  alias Ryker.Runtime.Assembly
  alias Ryker.Slack.Runtime, as: SlackRuntime

  @actor "control-plane:local"
  @lab "control-plane:lab:6f1a0f38-0b74-4f77-9f20-7a0c1e2d3b44"
  @workspace "T0123456789"
  @channel "slack:T0123456789:C0123456789"
  @alert_secret "alertmanager-signing-secret-long-enough"
  @custody_secret "checkpoint-scan-secret-long-enough"
  @certificates Path.join(System.tmp_dir!(), "ryker-assembly-test-certificates")
  @certificate_fields ~w(cacertfile ca_keyfile certfile keyfile)a

  setup_all do
    # The gateway refuses a certificate path that is not an existing file, so
    # the fixture supplies real ones rather than plausible names.
    File.mkdir_p!(@certificates)
    Enum.each(@certificate_fields, &File.write!(certificate(&1), "placeholder"))
    on_exit(fn -> File.rm_rf!(@certificates) end)

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
      &policy(:conversational, :installation, "", "ryker-chat", &1),
      &policy(:incident, :installation, "", "ryker-incident", &1),
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

    assert configuration.control_plane.work_profile == %{
             authority_digest: digest("authority"),
             class_policies: %{
               conversational: %{
                 authority_digest: digest("authority"),
                 policy: "ryker-chat",
                 policy_digest: digest("ryker-chat")
               },
               deep: %{
                 authority_digest: digest("authority"),
                 policy: "ryker-chat",
                 policy_digest: digest("ryker-chat")
               },
               standard: %{
                 authority_digest: digest("authority"),
                 policy: "ryker-chat",
                 policy_digest: digest("ryker-chat")
               }
             },
             policy: "ryker-chat",
             policy_digest: digest("ryker-chat"),
             repository_ref: nil
           }

    assert Enum.any?(configuration.fleet_profiles, fn {_key, profile} ->
             profile.policy == "ryker-chat" and profile.repository_ref == nil
           end)

    slack = SlackRuntime.options!(configuration.slack)

    assert {:ok, profile} =
             slack.handler_settings.work_profile.(@workspace, "slack:#{@workspace}:C0123456789")

    assert profile.policy == "ryker-chat"
    assert profile.repository_ref == nil
  end

  test "a fully connected installation assembles one lane per saved connection" do
    settings = connected!()
    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)

    # Every lane an enabled setting asks for, and nothing the settings did not.
    assert Enum.sort(Map.keys(configuration)) ==
             Enum.sort([
               :admission,
               :control_plane,
               :coop_worker_gateway,
               :delivery,
               :emisar,
               :event_waits,
               :execution_mode,
               :fleet_profiles,
               :github,
               :learning,
               :publication,
               :retention,
               :schedules,
               :slack,
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
    assert configuration[:delivery].worker_ref == "#{host}:delivery"
    assert configuration[:publication].worker_ref == "#{host}:publication"
    assert configuration[:retention].worker_ref == "#{host}:retention"
    assert configuration[:schedules].worker_ref == "#{host}:schedules"
    assert [emisar] = configuration[:emisar].connections
    assert emisar.worker_ref == "#{host}:emisar:production"

    # The reviewed bindings decide the policies; a form never names one.
    assert configuration[:admission].policy == "ryker-admission-v1"
    assert configuration[:learning].policy == "ryker-learning-v1"
    assert configuration[:schedules].read_only_policy.name == "ryker-schedule-read-v1"
    assert configuration[:schedules].governed_operation_policy.name == "ryker-schedule-gov-v1"
    assert configuration[:schedules].repositories["ryker"].name == "ryker-standard-v1"

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
    assert configuration[:publication].publisher_binding.repositories["ryker"].path == "/srv"
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

    # A route that delivers into Slack cannot outlive the Slack connection: the
    # whole configuration is refused rather than the route quietly disappearing.
    assert {:error, {:settings_not_applicable, reason}} = Assembly.build(bootstrap(), settings)
    assert reason =~ "webhook destination is not a configured delivery target"

    assert {:ok, configuration} = Assembly.build(bootstrap(), disconnect_webhooks(settings))

    for absent <- [:slack, :github, :emisar, :learning, :webhooks] do
      assert configuration[absent] == nil, "#{absent} started from a credential, not a setting"
    end

    # The lanes that need no integration still run, and publication follows
    # GitHub out rather than publishing through nothing.
    assert configuration[:work]
    assert configuration[:control_plane]
    assert configuration[:publication].publisher_binding.repositories == %{}
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

  # Work in an environment changes its first repository and only reads the
  # rest. Coop mounts read-only repositories only for a policy that declares
  # them, so an environment with several repositories runs on its own reviewed
  # policies, never on its first repository's; one with a single repository
  # runs on that repository's.
  test "work in an environment changes its first repository and reads the others" do
    settings = connected!()
    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)
    environments = configuration[:slack].environments

    platform = environments["platform"]
    assert platform.display_name == "Platform"
    assert platform.work_profile.environment_ref == "platform"
    assert platform.work_profile.repository_ref == "ryker"
    assert platform.work_profile.read_only_repository_refs == ["docs"]
    assert platform.work_profile.parallel_goal_limit == 2
    assert platform.work_profile.emisar_connection_ref == "production"
    assert platform.work_profile.policy == "platform-conversation-v1"

    task = configuration[:control_plane].task_policies["platform"]
    assert task.name == "platform-contributor-v1"
    assert task.environment_ref == "platform"
    assert task.repository_ref == "ryker"

    assert task.repository_context == %{
             "context_ref" => "platform",
             "parallel_goal_limit" => 2,
             "primary_repository" => "ryker",
             "read_only_repositories" => ["docs"]
           }

    assert environments["docs"].work_profile.policy == "docs-conversation-v1"
    assert environments["docs"].work_profile.read_only_repository_refs == []
    assert configuration[:control_plane].task_policies["docs"].name == "docs-contributor-v1"

    # Without repositories an environment answers on the installation's own
    # policy, keeps its Emisar account and has nothing a task could change.
    ops = environments["ops"]
    assert ops.work_profile.repository_ref == nil
    assert ops.work_profile.policy == "ryker-chat-v1"
    assert ops.work_profile.emisar_connection_ref == "production"
    refute Map.has_key?(configuration[:control_plane].task_policies, "ops")

    route = configuration[:webhooks].routes["alerts"].work_profile
    assert route.environment_ref == "platform"
    assert route.read_only_repository_refs == ["docs"]

    # Several repositories and no reviewed policies of its own: nothing runs.
    {:ok, changed} =
      Settings.put_environment(
        %{ref: "unreviewed", display_name: "Unreviewed", repositories: ["docs", "ryker"]},
        settings.installation.revision,
        @actor
      )

    assert {:ok, configuration} = Assembly.build(bootstrap(), changed)
    refute Map.has_key?(configuration[:slack].environments, "unreviewed")
    refute Map.has_key?(configuration[:control_plane].task_policies, "unreviewed")
  end

  # Chat and every conversation without its own setting work in the default
  # environment. With none chosen, or one that cannot run work, they answer
  # outside any environment rather than borrowing another's repositories.
  test "Chat works in the default environment, else outside any" do
    settings = connected!()
    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)

    assert configuration.control_plane.work_profile ==
             configuration[:slack].environments["platform"].work_profile

    assert configuration[:slack].default_environment == "platform"
    assert configuration[:slack].fallback_work_profile.policy == "ryker-chat-v1"
    refute Map.has_key?(configuration[:slack].fallback_work_profile, :environment_ref)

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
    assert configuration.control_plane.work_profile.policy == "ryker-chat-v1"
    refute Map.has_key?(configuration.control_plane.work_profile, :environment_ref)
    # Slack still seeds joined channels with the saved default, so they work
    # in it once it can run work; until then their work runs outside any.
    assert configuration[:slack].default_environment == "unreviewed"
    refute Map.has_key?(configuration[:slack].environments, "unreviewed")
  end

  # GitHub events for a repository run in the environment whose writable
  # repository it is; a repository environments only read runs in the first
  # of those; a repository in none runs on its own, without an environment.
  test "a GitHub event runs where its repository is writable, else where it is read, else alone" do
    settings = connected!()

    saves = [
      &Settings.put_repository(%{ref: "tools", github_repository: "ryker/tools"}, &1, @actor),
      &policy(:conversational, :repository, "tools", "tools-conversation-v1", &1),
      &policy(:contributor, :repository, "tools", "tools-contributor-v1", &1),
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
    assert docs.repository_ref == "ryker"
    assert docs.read_only_repository_refs == ["docs"]
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
    # A repository row is metadata; the reviewed policy bindings are the grant.
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
      {&lifecycle_naming/1, "webhook lifecycle names a repository without reviewed policies"},
      {&webhook_environment_naming/1, "webhook source names an environment that cannot run work"}
    ]

    for {save, expected} <- refusals do
      {:ok, changed} = save.(Settings.fetch!().installation.revision)

      assert {:error, {:settings_not_applicable, ^expected}} =
               Assembly.build(bootstrap(), changed)

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

  test "a webhook destination that is not a configured delivery target refuses the build" do
    # A route whose destination cannot be delivered to accepts events into a
    # dead end. The refusal happens before anything starts.
    connected!()

    for {conversation, thread, transport} <- [
          {"slack:T9999999999:C0123456789", nil, "slack"},
          {"github:unbound-app:repository:2001", "github:unbound-app:issue:1", "github"},
          {"github:ryker-app:repository:9999", "github:ryker-app:issue:1", "github"},
          {"control-plane:lab:not-a-conversation", "control-plane:lab:not-a-conversation",
           "control_plane"},
          {"control-plane:local", "control-plane:local", "control_plane"}
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

      assert {:error, {:settings_not_applicable, reason}} = Assembly.build(bootstrap(), changed)

      assert reason =~ "webhook destination is not a configured delivery target",
             "#{transport} destination was accepted"
    end

    # Restoring the saved destination makes the same installation assemble.
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

    assert {:ok, _configuration} = Assembly.build(bootstrap(), restored)
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

    assert {:error, {:settings_not_applicable, reason}} = Assembly.build(bootstrap(), settings)
    assert reason == "The saved GitHub App private key is not usable"
    refute reason =~ "not-an-app-key"
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

    for absent <- [:work, :admission, :learning, :retention, :publication] do
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
          github_repository: "ryker/ryker",
          publication_checkout_path: "/srv"
        },
        &1,
        @actor
      ),
      &Settings.put_repository(%{ref: "docs", github_repository: "ryker/docs"}, &1, @actor),
      &policy(:conversational, :repository, "ryker", "ryker-conversation-v1", &1),
      &policy(:contributor, :repository, "ryker", "ryker-contributor-v1", &1),
      &policy(:standard, :repository, "ryker", "ryker-standard-v1", &1),
      &policy(:deep, :repository, "ryker", "ryker-deep-v1", &1),
      &policy(:schedule, :repository, "ryker", "ryker-standard-v1", &1),
      &policy(:conversational, :repository, "docs", "docs-conversation-v1", &1),
      &policy(:contributor, :repository, "docs", "docs-contributor-v1", &1),
      &policy(:conversational, :installation, "", "ryker-chat-v1", &1),
      &policy(:admission, :installation, "", "ryker-admission-v1", &1),
      &policy(:incident, :installation, "", "ryker-incident-v1", &1),
      &policy(:learning, :installation, "", "ryker-learning-v1", &1),
      &policy(:schedule_read_only, :installation, "", "ryker-schedule-read-v1", &1),
      &policy(:schedule_governed, :installation, "", "ryker-schedule-gov-v1", &1),
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
      &policy(:conversational, :environment, "platform", "platform-conversation-v1", &1),
      &policy(:contributor, :environment, "platform", "platform-contributor-v1", &1),
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

  defp policy(purpose, scope_kind, scope_ref, name, revision) do
    Settings.put_policy_binding(
      %{
        purpose: purpose,
        scope_kind: scope_kind,
        scope_ref: scope_ref,
        policy_name: name,
        policy_digest: digest(name),
        authority_digest: digest("authority"),
        verified_by: :import
      },
      revision,
      @actor
    )
  end

  defp digest(seed), do: :sha256 |> :crypto.hash(seed) |> Base.encode16(case: :lower)

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

  defp certificate(field), do: Path.join(@certificates, "#{field}.pem")

  defp put_variable(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)
    on_exit(fn -> restore_variable(name, previous) end)
  end

  defp restore_variable(name, nil), do: System.delete_env(name)
  defp restore_variable(name, previous), do: System.put_env(name, previous)
end
