defmodule Responder.Runtime.AssemblyTest do
  # Assembly is the only place a product setting becomes a runtime binding. Every
  # case here is about that boundary: what an installation's saved connections
  # turn on, what they may never turn on, and what a refusal has to name.
  use Responder.DataCase, async: false

  alias Responder.{Bootstrap, Settings}
  alias Responder.ControlPlane.CapabilityTools, as: ControlPlaneCapabilityTools
  alias Responder.Runtime.Assembly

  @actor "control-plane:local"
  @lab "control-plane:lab:6f1a0f38-0b74-4f77-9f20-7a0c1e2d3b44"
  @workspace "T0123456789"
  @channel "slack:T0123456789:C0123456789"
  @alert_secret "alertmanager-signing-secret-long-enough"
  @custody_secret "checkpoint-scan-secret-long-enough"
  @certificates Path.join(System.tmp_dir!(), "responder-assembly-test-certificates")
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
    deployment = %{
      "EMISAR_API_TOKEN" => "emisar-api-token-long-enough",
      "GITHUB_APP_PRIVATE_KEY" => pem,
      "GITHUB_WEBHOOK_SECRET" => "github-webhook-secret-long-enough",
      "RESPONDER_CHECKPOINT_KEY" => Base.encode64(:crypto.strong_rand_bytes(32)),
      "RESPONDER_STATE_TOOLS_TOKEN" => "state-tools-token-for-tests",
      "SLACK_APP_TOKEN" => "xapp-slack-app-token-long-enough",
      "SLACK_BOT_TOKEN" => "xoxb-slack-bot-token-long-enough",
      "ALERTMANAGER_WEBHOOK_SECRET" => @alert_secret,
      "CHECKPOINT_SCAN_SECRET" => @custody_secret
    }

    Enum.each(deployment, fn {name, value} -> put_variable(name, value) end)

    execution = Application.get_env(:responder, :execution)
    Application.put_env(:responder, :execution, :fleet)
    on_exit(fn -> Application.put_env(:responder, :execution, execution) end)

    :ok
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
    assert configuration[:emisar].worker_ref == "#{host}:emisar-approval"

    # The reviewed bindings decide the policies; a form never names one.
    assert configuration[:admission].policy == "responder-admission-v1"
    assert configuration[:learning].policy == "responder-learning-v1"
    assert configuration[:schedules].read_only_policy.name == "responder-schedule-read-v1"
    assert configuration[:schedules].governed_operation_policy.name == "responder-schedule-gov-v1"
    assert configuration[:schedules].repositories["responder"].name == "responder-standard-v1"

    # Retention horizons are the operator's saved numbers, not code defaults.
    assert configuration[:retention].audit_data_seconds == 60 * 86_400
    assert configuration[:retention].conversation_memory_seconds == 90 * 86_400
    assert configuration[:retention].learning_api == configuration[:learning].api

    # Delivery reaches exactly the transports that assembled.
    assert Enum.sort(Map.keys(configuration[:delivery].adapters)) ==
             ["control_plane", "github", "slack"]

    assert configuration[:slack].identity.workspace_ref == @workspace
    assert configuration[:slack].operators == ["U1111111111"]
    assert configuration[:slack].default_repository == "responder"
    assert configuration[:emisar].presentation_timeout_ms > 0
    assert configuration[:github].server.bindings["responder-app"].installation_id == 1001
    assert configuration[:publication].publisher_binding.repositories["responder"].path == "/srv"
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
      Settings.save_emisar(%{enabled: false}, settings.installation.revision, @actor)

    {:ok, settings} =
      Settings.save_learning(%{enabled: false}, settings.installation.revision, @actor)

    assert System.fetch_env!("SLACK_BOT_TOKEN") != ""
    assert System.fetch_env!("EMISAR_API_TOKEN") != ""

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
    previous = Map.new(Assembly.managed_keys(), &{&1, Application.fetch_env(:responder, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:responder, key, value, persistent: true)
        {key, :error} -> Application.delete_env(:responder, key, persistent: true)
      end)
    end)

    settings = connected!()
    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)
    Assembly.publish(configuration)

    assert Application.get_env(:responder, :slack).identity.workspace_ref == @workspace
    assert Application.get_env(:responder, :emisar)

    {:ok, settings} =
      Settings.save_slack(%{enabled: false}, settings.installation.revision, @actor)

    {:ok, settings} =
      Settings.save_emisar(%{enabled: false}, settings.installation.revision, @actor)

    assert {:ok, reduced} = Assembly.build(bootstrap(), disconnect_webhooks(settings))
    Assembly.publish(reduced)

    assert Application.get_env(:responder, :slack) == nil
    assert Application.get_env(:responder, :emisar) == nil
    assert Application.get_env(:responder, :work)
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

  test "a repository context resolves its own reviewed policies, not the primary's" do
    settings = connected!()
    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)
    profile = configuration[:control_plane].task_policies["platform"]

    assert profile.name == "responder-context-contributor-v1"
    assert profile.repository_ref == "responder"
    assert profile.repository_context["context_ref"] == "platform"
    assert profile.repository_context["parallel_goal_limit"] == 2
    assert profile.repository_context["read_only_repositories"] == ["docs"]

    # A repository keeps its own reviewed policies; the context does not widen
    # them, and a repository without both required bindings has no context.
    assert configuration[:control_plane].task_policies["responder"].name ==
             "responder-contributor-v1"

    refute Map.has_key?(configuration[:control_plane].task_policies, "unreviewed")

    # The console resolves a reviewed context deterministically — the first by
    # name — and never a profile a browser named.
    assert configuration[:control_plane].work_profile.policy == "docs-conversation-v1"
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
             repositories: ["responder"],
             targets: ["responder"]
           }
  end

  test "nothing runs against a repository whose policies were never reviewed" do
    # A repository row is metadata; the reviewed policy bindings are the grant.
    # Settings accepts each of these because the repository exists, and every
    # runtime that would act under its authority refuses before anything starts.
    settings = connected!()

    {:ok, _saved} =
      Settings.put_repository(%{ref: "unreviewed"}, settings.installation.revision, @actor)

    refusals = [
      {&lifecycle_naming/1, "webhook lifecycle names a repository without reviewed policies"},
      {&webhook_context_naming/1, "webhook source names an unknown repository context"},
      {&github_binding_naming/1, "github binding names a repository without reviewed policies"}
    ]

    for {save, expected} <- refusals do
      {:ok, changed} = save.(Settings.fetch!().installation.revision)

      assert {:error, {:settings_not_applicable, ^expected}} =
               Assembly.build(bootstrap(), changed)

      # The setting stays exactly as the operator wrote it; only the runtime refuses.
      assert Settings.fetch!().installation.revision == changed.installation.revision
    end
  end

  test "a GitHub binding may not run under a context whose policies were never reviewed" do
    # The binding's context supplies the Work profile every inbound GitHub event
    # runs under. A context with no reviewed bindings has no profile to supply,
    # so the binding would otherwise run under whatever the repository had.
    settings = connected!()

    {:ok, settings} =
      Settings.put_repository_context(
        %{ref: "unreviewed-context", primary_repository_ref: "responder"},
        settings.installation.revision,
        @actor
      )

    {:ok, settings} =
      Settings.put_github_binding(
        %{name: "responder-app", repository_context_ref: "unreviewed-context"},
        settings.installation.revision,
        @actor
      )

    assert Assembly.build(bootstrap(), settings) ==
             {:error,
              {:settings_not_applicable, "github binding names an unknown repository context"}}
  end

  defp lifecycle_naming(revision) do
    Settings.put_webhook_source(
      %{
        name: "deploys",
        publication_lifecycle: %{
          "environments" => ["production"],
          "kinds" => ["deployment"],
          "repositories" => ["unreviewed"],
          "targets" => ["responder"]
        }
      },
      revision,
      @actor
    )
  end

  defp webhook_context_naming(revision),
    do:
      Settings.put_webhook_source(%{name: "custom", context_ref: "unreviewed"}, revision, @actor)

  defp github_binding_naming(revision) do
    Settings.put_github_binding(
      %{
        name: "unreviewed-app",
        repository_ref: "unreviewed",
        installation_id: 1002,
        repository_id: 2002,
        responder_actor_id: 3002,
        authorized_actor_ids: [4002]
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
          {"github:responder-app:repository:9999", "github:responder-app:issue:1", "github"},
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

    pem = System.fetch_env!("GITHUB_APP_PRIVATE_KEY")
    System.put_env("GITHUB_APP_PRIVATE_KEY", Base.encode64(pem))
    assert {:ok, _encoded_configuration} = Assembly.build(bootstrap(), settings)

    System.put_env("GITHUB_APP_PRIVATE_KEY", "not-an-app-key-but-long-enough")

    assert {:error, {:settings_not_applicable, reason}} = Assembly.build(bootstrap(), settings)
    assert reason == "GITHUB_APP_PRIVATE_KEY is not a usable App key"
    refute reason =~ "not-an-app-key"
  end

  test "Emisar needs the exact HTTPS RPC endpoint, not an origin to guess from" do
    settings = connected!()

    for url <- ["https://emisar.dev", "http://emisar.dev/api/mcp/rpc"] do
      assert {:error, {:settings_not_applicable, reason}} =
               Assembly.build(%{bootstrap() | emisar_rpc_url: url}, settings)

      assert reason == "EMISAR_RPC_URL must be an exact HTTPS RPC URL"
    end

    assert {:ok, configuration} = Assembly.build(bootstrap(), settings)
    assert configuration[:emisar].client.rpc_path == "/api/mcp/rpc"
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

    [
      &Settings.save_retention(%{audit_data_seconds: 60 * 86_400}, &1, @actor),
      &Settings.put_repository(
        %{
          ref: "responder",
          github_repository: "responder/responder",
          publication_checkout_path: "/srv"
        },
        &1,
        @actor
      ),
      &Settings.put_repository(%{ref: "docs", github_repository: "responder/docs"}, &1, @actor),
      &policy(:conversational, :repository, "responder", "responder-conversation-v1", &1),
      &policy(:contributor, :repository, "responder", "responder-contributor-v1", &1),
      &policy(:standard, :repository, "responder", "responder-standard-v1", &1),
      &policy(:deep, :repository, "responder", "responder-deep-v1", &1),
      &policy(:schedule, :repository, "responder", "responder-standard-v1", &1),
      &policy(:conversational, :repository, "docs", "docs-conversation-v1", &1),
      &policy(:contributor, :repository, "docs", "docs-contributor-v1", &1),
      &Settings.put_repository_context(
        %{
          ref: "platform",
          primary_repository_ref: "responder",
          read_only_repository_refs: ["docs"],
          parallel_goal_limit: 2
        },
        &1,
        @actor
      ),
      &policy(:conversational, :context, "platform", "responder-context-conversation-v1", &1),
      &policy(:contributor, :context, "platform", "responder-context-contributor-v1", &1),
      &policy(:admission, :installation, "", "responder-admission-v1", &1),
      &policy(:incident, :installation, "", "responder-incident-v1", &1),
      &policy(:learning, :installation, "", "responder-learning-v1", &1),
      &policy(:schedule_read_only, :installation, "", "responder-schedule-read-v1", &1),
      &policy(:schedule_governed, :installation, "", "responder-schedule-gov-v1", &1),
      &Settings.save_work(%{workspace_ref: "responder-local-main"}, &1, @actor),
      &Settings.save_learning(%{enabled: true}, &1, @actor),
      &Settings.save_emisar(%{enabled: true}, &1, @actor),
      &Settings.save_slack(
        %{
          enabled: true,
          workspace_ref: @workspace,
          bot_ref: "A0123456789",
          bot_user_ref: "U0123456789",
          default_repository_ref: "responder",
          operators: ["U1111111111"]
        },
        &1,
        @actor
      ),
      &Settings.save_github(%{enabled: true, app_id: 12_345}, &1, @actor),
      &Settings.put_github_binding(
        %{
          name: "responder-app",
          repository_ref: "responder",
          repository_context_ref: "platform",
          installation_id: 1001,
          repository_id: 2001,
          responder_actor_id: 3001,
          authorized_actor_ids: [4001]
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
            "repositories" => ["responder"],
            "targets" => ["responder"]
          }
        }),
        &1,
        @actor
      )
    ]
    |> Enum.reduce(1, fn save, revision ->
      {:ok, saved} = save.(revision)
      saved.installation.revision
    end)

    Settings.fetch!()
  end

  defp source(name, overrides) do
    Map.merge(
      %{
        name: name,
        adapter_kind: :universal,
        auth_kind: :hmac_sha256,
        secret_name: "ALERTMANAGER_WEBHOOK_SECRET",
        destination_transport: "control_plane",
        destination_conversation_ref: @lab,
        destination_thread_ref: @lab,
        context_ref: "responder"
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
      repo: [url: "ecto://responder@localhost/responder", pool_size: 2],
      control_plane: %{ip: {127, 0, 0, 1}, port: 4321},
      state_tools: %{ip: {127, 0, 0, 1}, port: 4318},
      worker_gateway:
        Map.merge(Map.new(@certificate_fields, &{&1, certificate(&1)}), %{
          ip: {127, 0, 0, 1},
          port: 4322,
          public_url: "https://worker.example"
        }),
      github_listener: %{ip: {127, 0, 0, 1}, port: 4319},
      webhook_listener: %{ip: {127, 0, 0, 1}, port: 4320},
      storage_root: "/tmp/responder-assembly-test",
      github_api_url: "https://api.github.com",
      github_app_id: 12_345,
      emisar_rpc_url: "https://emisar.dev/api/mcp/rpc",
      log_level: :warning,
      webhook_secret_names: ["ALERTMANAGER_WEBHOOK_SECRET", "CHECKPOINT_SCAN_SECRET"]
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
