defmodule Responder.RuntimeConfigurationTest do
  use ExUnit.Case, async: false

  alias Responder.Ingress.WorkProfile
  alias Responder.Learning.Runtime, as: LearningRuntime
  alias Responder.RuntimeConfiguration
  alias Responder.Webhooks.Server

  @example Path.expand("../../config/responder-elixir.example.yaml", __DIR__)

  test "the separate Elixir example prepares every product runtime without eagerly reading API tokens" do
    caller = self()
    private_key = private_key_pem()

    env_provider = fn name ->
      send(caller, {:environment_read, name})

      case name do
        "GITHUB_APP_PRIVATE_KEY" -> {:ok, Base.encode64(private_key)}
        "RESPONDER_CHECKPOINT_KEY" -> {:ok, Base.encode64(:binary.copy("k", 32))}
        _other -> {:ok, String.duplicate("#{name}-secret", 3)}
      end
    end

    configuration = RuntimeConfiguration.load!(@example, env_provider: env_provider)

    assert Map.keys(configuration) |> Enum.sort() ==
             ~w(admission control_plane coop_worker_gateway delivery emisar event_waits fleet_profiles github learning model_evals publication retention runtime_mode schedules slack state_tools webhooks work)a

    assert configuration.runtime_mode == :product
    assert configuration.webhooks.routes["universal"].adapter == %{kind: :universal}

    assert configuration.webhooks.routes["deployments"].publication_lifecycle == %{
             environments: ["production"],
             kinds: ["deployment", "terraform"],
             repositories: ["responder"],
             targets: ["responder"]
           }

    assert_received {:environment_read, "GITHUB_WEBHOOK_SECRET"}
    assert_received {:environment_read, "GITHUB_APP_PRIVATE_KEY"}
    assert_received {:environment_read, "RESPONDER_STATE_TOOLS_TOKEN"}
    assert_received {:environment_read, "RESPONDER_WEBHOOK_SECRET"}
    assert_received {:environment_read, "RESPONDER_DEPLOYMENT_WEBHOOK_SECRET"}
    assert_received {:environment_read, "RESPONDER_CHECKPOINT_KEY"}
    refute_received {:environment_read, "SLACK_APP_TOKEN"}
    refute_received {:environment_read, "SLACK_BOT_TOKEN"}
    refute_received {:environment_read, "EMISAR_API_TOKEN"}

    assert configuration.admission.worker_ref == "responder-a:admission"
    assert configuration.admission.api == Responder.CoopFleet.Client
    assert configuration.admission.client == configuration.work.client
    assert configuration.learning.api == Responder.CoopFleet.Client
    assert configuration.learning.client == configuration.work.client
    assert configuration.learning.worker_ref == "responder-a:learning"
    assert configuration.learning.concurrency == 1
    refute Map.has_key?(configuration.admission, :socket)
    assert configuration.model_evals.world_policy == "responder-eval-world-v1"

    assert configuration.model_evals.world_baseline_policy ==
             "responder-eval-world-baseline-v1"

    assert configuration.model_evals.no_tools_policy == "responder-eval-no-tools-v1"
    assert configuration.work.worker_ref == "responder-a:work"
    assert configuration.work.api == Responder.CoopFleet.Client

    assert Keyword.fetch!(configuration.work.client.bridge_options, :capability_versions) == %{
             "repository-freshness" => "2"
           }

    assert configuration.work.client == configuration.retention.client
    assert configuration.learning.client == configuration.retention.learning_client
    assert configuration.retention.learning_api == Responder.CoopFleet.Client
    assert configuration.work.client == configuration.publication.coop_client
    assert configuration.work.client == configuration.slack.coop_client
    assert configuration.retention.api == Responder.CoopFleet.Client
    assert configuration.publication.coop_api == Responder.CoopFleet.Client
    assert configuration.slack.coop_api == Responder.CoopFleet.Client
    assert configuration.delivery.worker_ref == "responder-a:delivery"
    assert configuration.delivery.action_concurrency == 2
    assert configuration.publication.worker_ref == "responder-a:publication"
    assert configuration.retention.worker_ref == "responder-a:retention"
    assert configuration.retention.closed_session_grace_seconds == 900
    # A September 3 request became an empty timeline the next day because its
    # content expired weeks before the episode listed in the console did.
    assert configuration.retention.operational_data_seconds ==
             configuration.retention.episode_history_seconds

    assert configuration.retention.closed_work_seconds ==
             configuration.retention.episode_history_seconds

    assert configuration.retention.episode_history_seconds == 2_592_000
    assert configuration.retention.audit_data_seconds == 2_592_000

    assert configuration.control_plane.schedule_policies == configuration.schedules

    assert Map.delete(configuration.control_plane, :schedule_policies) == %{
             coop_api: Responder.CoopFleet.Client,
             coop_client: configuration.work.client,
             ip: {127, 0, 0, 1},
             port: 4321,
             task_policies: %{
               "responder" => %{
                 digest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                 name: "responder-contributor-v1"
               }
             },
             work_profile: %WorkProfile{
               authority_digest:
                 "6666666666666666666666666666666666666666666666666666666666666666",
               class_policies: %{
                 conversational: %{
                   authority_digest:
                     "6666666666666666666666666666666666666666666666666666666666666666",
                   policy: "responder-conversation-v1",
                   policy_digest:
                     "9999999999999999999999999999999999999999999999999999999999999999"
                 },
                 deep: %{
                   authority_digest:
                     "6666666666666666666666666666666666666666666666666666666666666666",
                   policy: "responder-deep-v1",
                   policy_digest:
                     "7777777777777777777777777777777777777777777777777777777777777777"
                 },
                 standard: %{
                   authority_digest:
                     "6666666666666666666666666666666666666666666666666666666666666666",
                   policy: "responder-standard-v1",
                   policy_digest:
                     "8888888888888888888888888888888888888888888888888888888888888888"
                 }
               },
               policy: "responder-conversation-v1",
               policy_digest: "9999999999999999999999999999999999999999999999999999999999999999",
               repository_ref: "responder"
             }
           }

    assert configuration.delivery.adapters["control_plane"] == %{
             binding: nil,
             message_publisher: Responder.ControlPlane.Publisher,
             reaction_publisher: Responder.ControlPlane.Publisher
           }

    assert %{
             cacertfile: "/etc/responder/worker-ca.pem",
             ca_keyfile: "/etc/responder/worker-ca-key.pem",
             certificate_ttl_seconds: 86_400,
             certfile: "/etc/responder/worker-gateway.pem",
             checkpoint_key: checkpoint_key,
             checkpoint_secrets: [],
             ip: {0, 0, 0, 0},
             keyfile: "/etc/responder/worker-gateway-key.pem",
             port: 4322,
             public_url: "https://responder.example.com:4322",
             state_tools: %{
               additional_call: additional_call,
               additional_tools: additional_tools,
               capabilities: [:emisar_approvals, :event_waits, :publication, :schedules],
               emisar_rpc_url: "https://emisar.dev/api/mcp/rpc"
             }
           } = configuration.coop_worker_gateway

    assert byte_size(checkpoint_key) == 32

    assert is_function(additional_call, 3)

    assert Enum.map(additional_tools, & &1["name"]) == [
             "list_slack_channels",
             "search_slack",
             "read_slack_source",
             "set_slack_reaction",
             "post_slack_message",
             "read_github_conversation",
             "search_github",
             "set_github_reaction"
           ]

    assert configuration.work.state_tools_endpoint ==
             "https://responder.example.com:4322/v1/state-tools/mcp"

    assert configuration.work.state_tools_secret == configuration.state_tools.token

    assert configuration.work.state_tool_capabilities ==
             configuration.state_tools.capabilities

    assert configuration.slack.identity.workspace_ref == "T0123456789"
    assert configuration.emisar.worker_ref == "responder-a:emisar-approval"
    assert configuration.state_tools.emisar_rpc_url == "https://emisar.dev/api/mcp/rpc"

    assert configuration.state_tools.capabilities == [
             :emisar_approvals,
             :event_waits,
             :publication,
             :schedules
           ]

    assert {:ok, _token} = configuration.slack.app_http.token_provider.()
    assert_received {:environment_read, "SLACK_APP_TOKEN"}

    github_client =
      configuration.delivery.adapters["github"].binding.bindings["responder-app"].client

    assert is_function(github_client.http.token_provider, 0)

    publication_repository =
      configuration.publication.publisher_binding.repositories["responder"]

    publication_client = publication_repository.client

    repository_token_provider =
      publication_repository.git_binding.token_provider

    assert is_function(publication_client.http.token_provider, 0)
    assert is_function(repository_token_provider, 0)
    refute github_client.http.token_provider == publication_client.http.token_provider
    refute publication_client.http.token_provider == repository_token_provider
    refute github_client.http.token_provider == repository_token_provider

    assert configuration.github.tokens.bindings["responder-app"] == %{
             installation_id: 1001,
             repository_id: 2001
           }

    assert {:ok, _token} = configuration.emisar.client.http.token_provider.()
    assert_received {:environment_read, "EMISAR_API_TOKEN"}

    assert %{server: %{bindings: %{"responder-app" => binding}}} = configuration.github
    assert binding.repository_full_name == "emisar/responder"
    assert binding.work_profile.repository_ref == "responder"

    assert configuration.github.server.confirmations.repositories["responder"] == %{
             digest: String.duplicate("a", 64),
             name: "responder-contributor-v1"
           }

    assert {:ok, %{name: "responder-conversation-v1"}} =
             WorkProfile.policy_for(
               binding.work_profile,
               :conversational
             )

    assert {:ok, %{name: "responder-standard-v1"}} =
             WorkProfile.policy_for(binding.work_profile, :standard)

    assert {:ok, %{name: "responder-deep-v1"}} =
             WorkProfile.policy_for(binding.work_profile, :deep)

    assert configuration.fleet_profiles[{"read_only", "responder"}] == %{
             authority_digest: "6666666666666666666666666666666666666666666666666666666666666666",
             policy: "responder-conversation-v1",
             policy_digest: "9999999999999999999999999999999999999999999999999999999999999999",
             repository_ref: "responder"
           }

    assert configuration.fleet_profiles[{"repository_write", "responder"}].policy ==
             "responder-contributor-v1"
  end

  test "platform tools dispatch from the durable Ecto episode binding" do
    private_key = private_key_pem()

    env_provider = fn
      "GITHUB_APP_PRIVATE_KEY" -> {:ok, Base.encode64(private_key)}
      "RESPONDER_CHECKPOINT_KEY" -> {:ok, Base.encode64(:binary.copy("k", 32))}
      name -> {:ok, String.duplicate("#{name}-secret", 3)}
    end

    configuration = RuntimeConfiguration.load!(@example, env_provider: env_provider)
    additional_call = configuration.state_tools.additional_call

    # A live Lab turn exposed this boundary: direct module tests used maps, but
    # the runtime supplies an Ecto struct that deliberately has no Access API.
    assert additional_call.(
             "list_slack_channels",
             %{},
             %{
               episode: %Responder.Episodes.Episode{
                 destination_transport: "control_plane"
               }
             }
           ) == {:error, "unauthorized"}
  end

  test "publication retains the exact GitHub App authority for every configured repository" do
    document = """
    version: 1
    mode: component
    host_ref: responder-multi-repository
    coop:
      socket: /tmp/coop.sock
    repositories:
      repository-a:
        path: /srv/repository-a
        github_repository: acme/repository-a
        github_binding: binding-a
        base_branch: main
        conversation_policy:
          name: repository-a-read
          digest: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        contributor_policy:
          name: repository-a-write
          digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        schedule_policy:
          name: repository-a-schedule
          digest: ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
      repository-b:
        path: /srv/repository-b
        github_repository: acme/repository-b
        github_binding: binding-b
        base_branch: main
        conversation_policy:
          name: repository-b-read
          digest: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
        contributor_policy:
          name: repository-b-write
          digest: dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
        schedule_policy:
          name: repository-b-schedule
          digest: "1111111111111111111111111111111111111111111111111111111111111111"
    repository_sets:
      platform:
        primary_repository: repository-a
        read_only_repositories: [repository-b]
        parallel_goal_limit: 2
        conversation_policy:
          name: platform-read
          digest: "2222222222222222222222222222222222222222222222222222222222222222"
        contributor_policy:
          name: platform-write
          digest: "3333333333333333333333333333333333333333333333333333333333333333"
    admission:
      policy:
        name: admission-read
        digest: eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
    work: {}
    github:
      api_url: https://api.github.com
      app_id: 12345
      private_key_env: GITHUB_APP_PRIVATE_KEY
      webhook_secret_env: GITHUB_WEBHOOK_SECRET
      port: 4319
      bindings:
        binding-a:
          repository: repository-a
          repository_context: platform
          installation_id: 1001
          repository_id: 2001
          responder_actor_id: 3001
          authorized_actor_ids: [4001]
        binding-b:
          repository: repository-b
          installation_id: 1002
          repository_id: 2002
          responder_actor_id: 3002
          authorized_actor_ids: [4002]
    delivery: {}
    publication:
      branch_prefix: responder
      state_dir: /var/lib/responder/publications
      commit_name: Emisar Responder
      commit_email: responder@example.com
      secret_scan_env: []
    """

    configuration =
      RuntimeConfiguration.from_string!(document,
        env_provider: fn
          "GITHUB_APP_PRIVATE_KEY" -> {:ok, private_key_pem()}
          "GITHUB_WEBHOOK_SECRET" -> {:ok, String.duplicate("github-webhook-secret", 2)}
        end
      )

    repositories = configuration.publication.publisher_binding.repositories

    assert Map.keys(repositories) |> Enum.sort() == ["repository-a", "repository-b"]
    assert repositories["repository-a"].github_repository == "acme/repository-a"
    assert repositories["repository-b"].github_repository == "acme/repository-b"
    refute repositories["repository-a"].client == repositories["repository-b"].client

    refute repositories["repository-a"].git_binding.token_provider ==
             repositories["repository-b"].git_binding.token_provider

    assert configuration.github.server.bindings["binding-a"].work_profile.repository_context == %{
             context_ref: "platform",
             parallel_goal_limit: 2,
             primary_repository: "repository-a",
             read_only_repositories: ["repository-b"]
           }

    assert configuration.github.server.confirmations.repositories["platform"] == %{
             digest: String.duplicate("3", 64),
             name: "platform-write",
             repository_context: %{
               "context_ref" => "platform",
               "parallel_goal_limit" => 2,
               "primary_repository" => "repository-a",
               "read_only_repositories" => ["repository-b"]
             },
             repository_ref: "repository-a"
           }
  end

  test "repository sets freeze one primary, exact companions, policy classes, and parallel limit" do
    document = """
    version: 1
    mode: component
    host_ref: responder-repository-set
    coop:
      socket: /tmp/coop.sock
    repositories:
      service:
        path: /srv/service
        github_repository: acme/service
        github_binding: service
        base_branch: main
        conversation_policy:
          name: service-read
          digest: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        contributor_policy:
          name: service-write
          digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        schedule_policy:
          name: service-schedule
          digest: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
      infrastructure:
        path: /srv/infrastructure
        github_repository: acme/infrastructure
        github_binding: infrastructure
        base_branch: main
        conversation_policy:
          name: infrastructure-read
          digest: dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
        contributor_policy:
          name: infrastructure-write
          digest: eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
        schedule_policy:
          name: infrastructure-schedule
          digest: ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
    repository_sets:
      platform:
        primary_repository: service
        read_only_repositories: [infrastructure]
        parallel_goal_limit: 2
        conversation_policy:
          name: platform-conversation
          digest: "1111111111111111111111111111111111111111111111111111111111111111"
          authority_digest: "6666666666666666666666666666666666666666666666666666666666666666"
        standard_policy:
          name: platform-standard
          digest: "2222222222222222222222222222222222222222222222222222222222222222"
          authority_digest: "6666666666666666666666666666666666666666666666666666666666666666"
        deep_policy:
          name: platform-deep
          digest: "3333333333333333333333333333333333333333333333333333333333333333"
          authority_digest: "6666666666666666666666666666666666666666666666666666666666666666"
        contributor_policy:
          name: platform-write
          digest: "4444444444444444444444444444444444444444444444444444444444444444"
    admission:
      policy:
        name: admission-read
        digest: "5555555555555555555555555555555555555555555555555555555555555555"
    work: {}
    control_plane:
      port: 4321
      work_profile:
        authority_digest: "6666666666666666666666666666666666666666666666666666666666666666"
        policy: platform-conversation
        policy_digest: "1111111111111111111111111111111111111111111111111111111111111111"
        repository_ref: platform
        class_policies:
          conversational:
            authority_digest: "6666666666666666666666666666666666666666666666666666666666666666"
            policy: platform-conversation
            policy_digest: "1111111111111111111111111111111111111111111111111111111111111111"
          standard:
            authority_digest: "6666666666666666666666666666666666666666666666666666666666666666"
            policy: platform-standard
            policy_digest: "2222222222222222222222222222222222222222222222222222222222222222"
          deep:
            authority_digest: "6666666666666666666666666666666666666666666666666666666666666666"
            policy: platform-deep
            policy_digest: "3333333333333333333333333333333333333333333333333333333333333333"
    delivery: {}
    """

    configuration = RuntimeConfiguration.from_string!(document)
    profile = configuration.control_plane.work_profile

    assert profile.repository_ref == "service"

    assert profile.repository_context == %{
             context_ref: "platform",
             parallel_goal_limit: 2,
             primary_repository: "service",
             read_only_repositories: ["infrastructure"]
           }

    assert {:ok, %{name: "platform-standard"}} = WorkProfile.policy_for(profile, :standard)
    assert {:ok, %{name: "platform-deep"}} = WorkProfile.policy_for(profile, :deep)

    assert configuration.control_plane.task_policies["platform"] == %{
             digest: String.duplicate("4", 64),
             name: "platform-write",
             repository_context: %{
               "context_ref" => "platform",
               "parallel_goal_limit" => 2,
               "primary_repository" => "service",
               "read_only_repositories" => ["infrastructure"]
             },
             repository_ref: "service"
           }

    assert configuration.control_plane.task_policies["service"] == %{
             digest: String.duplicate("b", 64),
             name: "service-write"
           }
  end

  defp private_key_pem do
    private_key = :public_key.generate_key({:rsa, 1_024, 65_537})
    :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])
  end

  test "component configuration can enable background learning before startup" do
    # The real internal config failed its pre-deployment load while product/fleet
    # config passed; enabling learning must work with the existing local Coop.
    document =
      minimal_document() <>
        """

        learning:
          policy:
            name: learning-read
            digest: #{String.duplicate("d", 64)}
        retention:
          poll_interval_ms: 1000
          lease_seconds: 60
          max_attempts: 8
          retry_base_seconds: 1
          retry_max_seconds: 60
          closed_session_grace_seconds: 900
          operational_data_seconds: 3600
          conversation_memory_seconds: 7200
          closed_work_seconds: 10800
          episode_history_seconds: 14400
          audit_data_seconds: 18000
        """

    document =
      String.replace(
        document,
        "work: {}",
        "work:\n  execution: fleet\n  workspace_ref: responder-main"
      )

    configuration = RuntimeConfiguration.from_string!(document)
    settings = LearningRuntime.options!(configuration.learning)
    assert settings.api == Responder.Coop.Client
    assert settings.client.finch == Responder.CoopFinch
    assert configuration.work.api == Responder.CoopFleet.Client
    assert settings.client != configuration.work.client
    assert configuration.retention.client == configuration.work.client
    assert configuration.retention.learning_api == Responder.Coop.Client
    assert configuration.retention.learning_client == settings.client
  end

  test "unknown configuration fields fail closed without creating atoms" do
    document = """
    version: 1
    mode: component
    host_ref: responder-a
    coop:
      socket: /tmp/coop.sock
      receive_timeout_ms: 30000
      surprise: true
    repositories: {}
    admission:
      policy:
        name: admission
        digest: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    work: {}
    """

    assert_raise ArgumentError, ~r/coop.*unknown/, fn ->
      RuntimeConfiguration.from_string!(document)
    end

    unknown = "runtime_config_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "missing GitHub App secrets identify the exact configured environment variable" do
    assert_raise ArgumentError, ~r/GITHUB_APP_PRIVATE_KEY/, fn ->
      RuntimeConfiguration.load!(@example,
        env_provider: fn
          "RESPONDER_CHECKPOINT_KEY" -> {:ok, Base.encode64(:binary.copy("k", 32))}
          _name -> :error
        end
      )
    end

    assert_raise ArgumentError, ~r/GITHUB_WEBHOOK_SECRET/, fn ->
      RuntimeConfiguration.load!(@example,
        env_provider: fn
          "RESPONDER_CHECKPOINT_KEY" -> {:ok, Base.encode64(:binary.copy("k", 32))}
          "GITHUB_APP_PRIVATE_KEY" -> {:ok, private_key_pem()}
          _name -> :error
        end
      )
    end
  end

  test "the local control plane refuses a public bind address" do
    document = """
    version: 1
    mode: component
    host_ref: responder-a
    coop:
      socket: /tmp/coop.sock
    repositories: {}
    admission:
      policy:
        name: admission
        digest: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    work: {}
    control_plane:
      ip: 0.0.0.0
      port: 4321
      work_profile:
        policy: local-conversation
        policy_digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        repository_ref:
    """

    assert_raise ArgumentError, ~r/control_plane.ip.*loopback/, fn ->
      RuntimeConfiguration.from_string!(document)
    end
  end

  test "the minimal host starts only admission and Work while optional runtimes stay absent" do
    configuration = RuntimeConfiguration.from_string!(minimal_document())

    assert Map.keys(configuration) |> Enum.sort() == [
             :admission,
             :fleet_profiles,
             :runtime_mode,
             :work
           ]

    assert configuration.runtime_mode == :component
    assert configuration.admission.worker_ref == "responder-minimal:admission"
    assert configuration.work.worker_ref == "responder-minimal:work"
    assert configuration.work.concurrency == 4
    assert configuration.fleet_profiles[{"read_only", nil}].policy == "admission-read"
    refute Map.has_key?(configuration.work, :state_tool_capabilities)
  end

  test "model class policies require one model-independent authority digest" do
    document =
      minimal_document("""
      control_plane:
        ip: 127.0.0.1
        port: 4321
        work_profile:
          authority_digest: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          policy: conversation
          policy_digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
          repository_ref:
          class_policies:
            conversational:
              authority_digest: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
              policy: conversation
              policy_digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
            standard:
              authority_digest: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
              policy: standard
              policy_digest: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
            deep:
              authority_digest: dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
              policy: deep
              policy_digest: eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
      """)

    assert_raise ArgumentError, ~r/authority_equivalence/, fn ->
      RuntimeConfiguration.from_string!(document)
    end
  end

  test "model evals require dedicated authority distinct from every production policy" do
    configured =
      RuntimeConfiguration.from_string!(
        minimal_document("""
        model_evals:
          socket: /tmp/eval-coop.sock
          no_tools_policy:
            name: responder-eval-no-tools-v1
            digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
          world_policy:
            name: responder-eval-world-v1
            digest: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
          world_baseline_policy:
            name: responder-eval-world-baseline-v1
            digest: dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
        """)
      )

    assert configured.model_evals == %{
             receive_timeout_ms: 30_000,
             socket: "/tmp/eval-coop.sock",
             no_tools_policy: "responder-eval-no-tools-v1",
             no_tools_policy_digest:
               "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
             world_policy: "responder-eval-world-v1",
             world_policy_digest:
               "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
             world_baseline_policy: "responder-eval-world-baseline-v1",
             world_baseline_policy_digest:
               "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
           }

    assert_raise ArgumentError, ~r/model_evals.*must not reuse production policy authority/, fn ->
      RuntimeConfiguration.from_string!(
        minimal_document("""
        model_evals:
          socket: /tmp/eval-coop.sock
          no_tools_policy:
            name: responder-eval-no-tools-v1
            digest: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          world_policy:
            name: responder-eval-world-v1
            digest: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
          world_baseline_policy:
            name: responder-eval-world-baseline-v1
            digest: dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
        """)
      )
    end

    assert_raise ArgumentError, ~r/model_evals policies must have distinct authority/, fn ->
      RuntimeConfiguration.from_string!(
        minimal_document("""
        model_evals:
          socket: /tmp/eval-coop.sock
          no_tools_policy:
            name: responder-eval-no-tools-v1
            digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
          world_policy:
            name: responder-eval-world-v1
            digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
          world_baseline_policy:
            name: responder-eval-world-baseline-v1
            digest: dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
        """)
      )
    end

    assert_raise ArgumentError, ~r/model_evals policies must have distinct authority/, fn ->
      RuntimeConfiguration.from_string!(
        minimal_document("""
        model_evals:
          socket: /tmp/eval-coop.sock
          no_tools_policy:
            name: responder-eval-no-tools-v1
            digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
          world_policy:
            name: responder-eval-world-v1
            digest: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
          world_baseline_policy:
            name: responder-eval-world-baseline-v1
            digest: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
        """)
      )
    end

    assert_raise ArgumentError, ~r/model_evals.socket must be isolated from coop.socket/, fn ->
      RuntimeConfiguration.from_string!(
        minimal_document("""
        model_evals:
          socket: /tmp/coop.sock
          no_tools_policy:
            name: responder-eval-no-tools-v1
            digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
          world_policy:
            name: responder-eval-world-v1
            digest: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
        """)
      )
    end
  end

  test "retention horizons are explicit, ordered, and bounded" do
    configured =
      minimal_document("""
      retention:
        poll_interval_ms: 1000
        lease_seconds: 60
        max_attempts: 8
        retry_base_seconds: 1
        retry_max_seconds: 60
        closed_session_grace_seconds: 900
        operational_data_seconds: 3600
        conversation_memory_seconds: 7200
        closed_work_seconds: 10800
        episode_history_seconds: 14400
        audit_data_seconds: 18000
      """)

    retention = RuntimeConfiguration.from_string!(configured).retention
    assert retention.poll_interval_ms == 1_000
    assert retention.lease_seconds == 60
    assert retention.conversation_memory_seconds == 7_200

    assert_raise ArgumentError, ~r/retention horizons must be ordered/, fn ->
      configured
      |> String.replace("operational_data_seconds: 3600", "operational_data_seconds: 20000")
      |> RuntimeConfiguration.from_string!()
    end

    assert_raise ArgumentError, ~r/retention.*unknown/, fn ->
      configured
      |> String.replace(
        "audit_data_seconds: 18000",
        "audit_data_seconds: 18000\n  erase_everything: true"
      )
      |> RuntimeConfiguration.from_string!()
    end
  end

  test "product mode requires the Work cleanup and data-lifecycle owner" do
    document =
      minimal_document("""
      coop_worker_gateway:
        ip: 127.0.0.1
        port: 4322
        public_url: https://responder.example:4322
        cacertfile: /tmp/worker-ca.pem
        ca_keyfile: /tmp/worker-ca-key.pem
        certfile: /tmp/worker-gateway.pem
        checkpoint_key_env: RESPONDER_CHECKPOINT_KEY
        checkpoint_secret_scan_env: []
        keyfile: /tmp/worker-gateway-key.pem
      """)
      |> String.replace("mode: component", "mode: product")
      |> String.replace("  socket: /tmp/coop.sock", "  receive_timeout_ms: 30000")
      |> String.replace(
        "work: {}",
        "work:\n  execution: fleet\n  workspace_ref: responder-main"
      )

    assert_raise ArgumentError, ~r/product mode requires.*retention/, fn ->
      RuntimeConfiguration.from_string!(document,
        env_provider: fn "RESPONDER_CHECKPOINT_KEY" ->
          {:ok, Base.encode64(:binary.copy("k", 32))}
        end
      )
    end
  end

  test "product mode refuses a local Coop execution socket" do
    document =
      @example
      |> File.read!()
      |> String.replace(
        "coop:\n  receive_timeout_ms: 30000",
        "coop:\n  socket: /tmp/coop.sock\n  receive_timeout_ms: 30000"
      )

    assert_raise ArgumentError, ~r/product.*local Coop socket/, fn ->
      RuntimeConfiguration.from_string!(document,
        env_provider: fn
          "GITHUB_APP_PRIVATE_KEY" -> {:ok, private_key_pem()}
          "RESPONDER_CHECKPOINT_KEY" -> {:ok, Base.encode64(:binary.copy("k", 32))}
          name -> {:ok, String.duplicate("#{name}-secret", 3)}
        end
      )
    end
  end

  test "bounded local background runtimes prepare without platform adapters" do
    document =
      minimal_document("""
      control_plane:
        ip: ::1
        port: 4321
        work_profile:
          policy: local-conversation
          policy_digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
          repository_ref:
      delivery: {}
      state_tools:
        port: 4322
        token_env: STATE_TOKEN
      event_waits: {}
      schedules:
        read_only_policy:
          name: scheduled-read
          digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        governed_operation_policy:
          name: scheduled-governed
          digest: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
      """)

    env = fn
      "STATE_TOKEN" -> {:ok, "state-tools-secret"}
    end

    configuration = RuntimeConfiguration.from_string!(document, env_provider: env)
    assert configuration.control_plane.ip == {0, 0, 0, 0, 0, 0, 0, 1}
    assert configuration.state_tools.token == "state-tools-secret"
    assert configuration.event_waits.poll_interval_ms == 1_000
    assert configuration.schedules.worker_ref == "responder-minimal:schedules"

    refute Map.has_key?(configuration, :webhooks)
  end

  test "work names the exact configured MCP tools" do
    document =
      minimal_document("""
      work:
        source_and_action_tools:
          - list_runners
          - find_actions
      state_tools:
        port: 4322
        token_env: STATE_TOKEN
      event_waits: {}
      """)
      |> String.replace("work: {}\n", "")

    runtime =
      RuntimeConfiguration.from_string!(document,
        env_provider: fn "STATE_TOKEN" -> {:ok, "state-tools-secret"} end
      )

    assert runtime.work.platform_tools == ["list_runners", "find_actions"]

    duplicate = String.replace(document, "- find_actions", "- list_runners")

    assert_raise ArgumentError, ~r/source_and_action_tools must not contain duplicates/, fn ->
      RuntimeConfiguration.from_string!(duplicate,
        env_provider: fn "STATE_TOKEN" -> {:ok, "state-tools-secret"} end
      )
    end
  end

  test "a webhook route must target an exact configured delivery binding" do
    unbound =
      minimal_document("""
      webhooks:
        port: 4323
        routes:
          universal:
            auth:
              kind: bearer
              secret_env: UNIVERSAL_WEBHOOK_TOKEN
            destination:
              transport: webhook
              conversation_ref: webhook:universal
              thread_ref:
            work_profile:
              policy: webhook-read
              policy_digest: dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
              repository_ref:
      """)

    assert_raise ArgumentError, ~r/no configured delivery adapter/, fn ->
      RuntimeConfiguration.from_string!(unbound,
        env_provider: fn _ -> {:ok, "universal-webhook-secret"} end
      )
    end

    private_key = private_key_pem()

    env = fn
      "GITHUB_APP_PRIVATE_KEY" -> {:ok, private_key}
      "RESPONDER_CHECKPOINT_KEY" -> {:ok, Base.encode64(:binary.copy("k", 32))}
      name -> {:ok, String.duplicate("#{name}-secret", 3)}
    end

    assert_raise ArgumentError, ~r/slack_workspace_not_configured/, fn ->
      @example
      |> File.read!()
      |> String.replace(
        "conversation_ref: slack:T0123456789:C1111111111",
        "conversation_ref: slack:T9999999999:C1111111111"
      )
      |> RuntimeConfiguration.from_string!(env_provider: env)
    end

    assert_raise ArgumentError, ~r/github_repository_not_configured/, fn ->
      @example
      |> File.read!()
      |> String.replace(
        "transport: slack\n        conversation_ref: slack:T0123456789:C1111111111\n        thread_ref:",
        "transport: github\n        conversation_ref: github:responder-app:repository:9999\n        thread_ref: github:responder-app:issue:1"
      )
      |> RuntimeConfiguration.from_string!(env_provider: env)
    end

    conversation_id = "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"
    conversation_ref = "control-plane:lab:#{conversation_id}"

    local =
      minimal_document("""
      control_plane:
        ip: 127.0.0.1
        port: 4321
        work_profile:
          policy: local-conversation
          policy_digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
          repository_ref:
      delivery: {}
      webhooks:
        ip: 127.0.0.1
        port: 4323
        routes:
          universal:
            auth:
              kind: hmac_sha256
              secret_env: UNIVERSAL_WEBHOOK_SECRET
            destination:
              transport: control_plane
              conversation_ref: #{conversation_ref}
              thread_ref: #{conversation_ref}
            work_profile:
              policy: local-conversation
              policy_digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
              repository_ref:
      """)

    local_configuration =
      RuntimeConfiguration.from_string!(local,
        env_provider: fn "UNIVERSAL_WEBHOOK_SECRET" ->
          {:ok, String.duplicate("l", 32)}
        end
      )

    assert local_configuration.webhooks.routes["universal"].destination == %{
             conversation_ref: conversation_ref,
             thread_ref: conversation_ref,
             transport: "control_plane"
           }

    assert_raise ArgumentError, ~r/invalid.*destination/, fn ->
      local
      |> String.replace("thread_ref: #{conversation_ref}", "thread_ref: control-plane:lab:other")
      |> RuntimeConfiguration.from_string!(
        env_provider: fn "UNIVERSAL_WEBHOOK_SECRET" ->
          {:ok, String.duplicate("l", 32)}
        end
      )
    end
  end

  test "Grafana and mapped JSON webhook adapters use strict tagged configuration" do
    conversation_id = "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"
    conversation_ref = "control-plane:lab:#{conversation_id}"

    document =
      minimal_document("""
      control_plane:
        ip: 127.0.0.1
        port: 4321
        work_profile:
          policy: local-conversation
          policy_digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
          repository_ref:
      delivery: {}
      webhooks:
        ip: 127.0.0.1
        port: 4323
        routes:
          grafana:
            adapter:
              kind: grafana
              group_by_labels: [cluster, service]
            auth:
              kind: bearer
              secret_env: WEBHOOK_SECRET
            destination:
              transport: control_plane
              conversation_ref: #{conversation_ref}
              thread_ref: #{conversation_ref}
            work_profile:
              policy: local-conversation
              policy_digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
              repository_ref:
          monitoring:
            adapter:
              kind: mapped_json
              group_by_labels: [service]
              mapping:
                event_id: event.id
                incident_id: incident.id
                labels: labels
                status: incident.state
                title: incident.title
            auth:
              kind: bearer
              secret_env: WEBHOOK_SECRET
            destination:
              transport: control_plane
              conversation_ref: #{conversation_ref}
              thread_ref: #{conversation_ref}
            work_profile:
              policy: local-conversation
              policy_digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
              repository_ref:
      """)

    configuration =
      RuntimeConfiguration.from_string!(document,
        env_provider: fn "WEBHOOK_SECRET" -> {:ok, String.duplicate("s", 32)} end
      )

    routes = Server.options!(configuration.webhooks).routes

    assert routes["grafana"].adapter == %{
             kind: :grafana,
             group_by_labels: ["cluster", "service"]
           }

    assert routes["monitoring"].adapter == %{
             kind: :mapped_json,
             group_by_labels: ["service"],
             mapping: %{
               annotations: nil,
               ends_at: nil,
               event_id: "event.id",
               incident_id: "incident.id",
               item_id: nil,
               labels: "labels",
               revision: nil,
               severity: nil,
               source_url: nil,
               starts_at: nil,
               status: "incident.state",
               summary: nil,
               title: "incident.title"
             }
           }

    assert_raise ArgumentError, ~r/kind must be universal, grafana, or mapped_json/, fn ->
      document
      |> String.replace("kind: grafana", "kind: templated", global: false)
      |> RuntimeConfiguration.from_string!(
        env_provider: fn "WEBHOOK_SECRET" -> {:ok, String.duplicate("s", 32)} end
      )
    end

    assert_raise ArgumentError, ~r/invalid webhook route/, fn ->
      document
      |> String.replace("event.id", "events.0.id", global: false)
      |> RuntimeConfiguration.from_string!(
        env_provider: fn "WEBHOOK_SECRET" -> {:ok, String.duplicate("s", 32)} end
      )
    end
  end

  test "governed Emisar monitoring requires the state-tool handoff and an exact HTTPS RPC URL" do
    emisar = """
    emisar:
      rpc_url: https://emisar.example/api/mcp/rpc
      token_env: EMISAR_TOKEN
    """

    assert_raise ArgumentError, ~r/emisar requires state_tools/, fn ->
      RuntimeConfiguration.from_string!(minimal_document(emisar))
    end

    configured =
      minimal_document("""
      #{emisar}
      state_tools:
        port: 4322
        token_env: STATE_TOKEN
      """)

    env = fn
      "STATE_TOKEN" -> {:ok, "state-tools-secret"}
      "EMISAR_TOKEN" -> {:ok, "emisar-token"}
    end

    runtime = RuntimeConfiguration.from_string!(configured, env_provider: env)
    assert runtime.state_tools.emisar_rpc_url == "https://emisar.example/api/mcp/rpc"
    assert runtime.state_tools.capabilities == [:emisar_approvals]
    assert runtime.emisar.concurrency == 2
    assert runtime.emisar.presentation_timeout_ms == 0
    assert {:ok, "emisar-token"} = runtime.emisar.client.http.token_provider.()

    assert_raise ArgumentError, ~r/exact HTTPS RPC URL/, fn ->
      RuntimeConfiguration.from_string!(
        String.replace(configured, "https://emisar.example", "http://emisar.example"),
        env_provider: env
      )
    end
  end

  test "state tools expose only capabilities with a configured owner runtime" do
    env = fn "STATE_TOKEN" -> {:ok, "state-tools-secret"} end

    runtime =
      minimal_document("""
      state_tools:
        port: 4322
        token_env: STATE_TOKEN
      event_waits: {}
      """)
      |> RuntimeConfiguration.from_string!(env_provider: env)

    assert runtime.state_tools.capabilities == [:event_waits]
  end

  test "configuration shape, bounds, and dependencies fail at their exact boundary" do
    assert_raise ArgumentError, ~r/path must be absolute/, fn ->
      RuntimeConfiguration.load!("config/responder.yaml")
    end

    assert_raise ArgumentError, ~r/options are invalid/, fn ->
      RuntimeConfiguration.from_string!(minimal_document(),
        env_provider: &System.fetch_env/1,
        extra: true
      )
    end

    assert_raise ArgumentError, ~r/options are invalid/, fn ->
      RuntimeConfiguration.from_string!(minimal_document(),
        env_provider: &System.fetch_env/1,
        env_provider: &System.fetch_env/1
      )
    end

    assert_raise ArgumentError, ~r/bounded UTF-8 YAML/, fn ->
      RuntimeConfiguration.from_string!(String.duplicate("x", 512 * 1_024 + 1))
    end

    assert_raise ArgumentError, ~r/invalid Elixir runtime YAML/, fn ->
      RuntimeConfiguration.from_string!("[unterminated")
    end

    assert_raise ArgumentError, ~r/version must be 1/, fn ->
      RuntimeConfiguration.from_string!(
        String.replace(minimal_document(), "version: 1", "version: 2")
      )
    end

    assert_raise ArgumentError, ~r/repositories must be a map/, fn ->
      RuntimeConfiguration.from_string!(
        String.replace(minimal_document(), "repositories: {}", "repositories: []")
      )
    end

    assert_raise ArgumentError, ~r/delivery requires at least one/, fn ->
      RuntimeConfiguration.from_string!(minimal_document("delivery: {}"))
    end

    assert_raise ArgumentError, ~r/publication requires GitHub/, fn ->
      RuntimeConfiguration.from_string!(minimal_document("publication: {}"))
    end

    assert_raise ArgumentError, ~r/lowercase SHA-256 digest/, fn ->
      RuntimeConfiguration.from_string!(
        String.replace(
          minimal_document(),
          String.duplicate("a", 64),
          "NOT-A-DIGEST"
        )
      )
    end
  end

  test "environment installation is explicit, bounded, and restores no implicit defaults" do
    variable = "RESPONDER_ELIXIR_CONFIG"
    previous_variable = System.get_env(variable)
    previous_admission = Application.get_env(:responder, :admission)
    previous_control_plane = Application.get_env(:responder, :control_plane)
    previous_fleet_profiles = Application.get_env(:responder, :fleet_profiles)
    previous_runtime_mode = Application.get_env(:responder, :runtime_mode)
    previous_work = Application.get_env(:responder, :work)

    path =
      Path.join(System.tmp_dir!(), "responder-runtime-#{System.unique_integer([:positive])}.yaml")

    oversized = path <> ".oversized"

    on_exit(fn ->
      restore_environment(variable, previous_variable)
      restore_application(:admission, previous_admission)
      restore_application(:control_plane, previous_control_plane)
      restore_application(:fleet_profiles, previous_fleet_profiles)
      restore_application(:runtime_mode, previous_runtime_mode)
      restore_application(:work, previous_work)
      File.rm(path)
      File.rm(oversized)
    end)

    System.delete_env(variable)
    assert RuntimeConfiguration.install_from_env!() == :ok

    System.put_env(variable, "")

    assert_raise ArgumentError, ~r/must name a configuration file/, fn ->
      RuntimeConfiguration.install_from_env!()
    end

    File.write!(
      path,
      minimal_document("""
      control_plane:
        ip: 127.0.0.1
        port: 4321
        work_profile:
          policy: local-conversation
          policy_digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
          repository_ref:
      delivery: {}
      """)
    )

    System.put_env(variable, path)
    assert RuntimeConfiguration.install_from_env!() == :ok
    assert Application.fetch_env!(:responder, :work).worker_ref == "responder-minimal:work"
    assert Application.fetch_env!(:responder, :control_plane).port == 4321

    File.write!(path, minimal_document())
    assert RuntimeConfiguration.install_from_env!() == :ok
    assert Application.get_env(:responder, :control_plane) == nil

    File.write!(oversized, String.duplicate("x", 512 * 1_024 + 1))

    assert_raise ArgumentError, ~r/exceeds/, fn ->
      RuntimeConfiguration.load!(oversized)
    end
  end

  test "primitive configuration contracts reject every ambiguous value" do
    invalid_documents = [
      {~r/host_ref.*bounded nonblank/,
       String.replace(minimal_document(), "responder-minimal", " ")},
      {~r/coop.socket must be absolute/,
       String.replace(minimal_document(), "/tmp/coop.sock", "relative/coop.sock")},
      {~r/coop.receive_timeout_ms.*safe bound/,
       String.replace(
         minimal_document(),
         "socket: /tmp/coop.sock",
         "socket: /tmp/coop.sock\n  receive_timeout_ms: 1"
       )},
      {~r/work.concurrency.*safe bound/,
       String.replace(minimal_document(), "work: {}", "work:\n  concurrency: 0")},
      {~r/control_plane.port.*between 1 and 65535/,
       minimal_document("""
       control_plane:
         ip: 127.0.0.1
         port: 0
         work_profile:
           policy: local-conversation
           policy_digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
           repository_ref:
       """)},
      {~r/control_plane.ip.*IPv4 or IPv6/,
       minimal_document("""
       control_plane:
         ip: definitely-not-an-ip
         port: 4321
         work_profile:
           policy: local-conversation
           policy_digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
           repository_ref:
       """)},
      {~r/admission.policy must be a map/,
       String.replace(
         minimal_document(),
         "admission:\n  policy:\n    name: admission-read\n    digest: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
         "admission:\n  policy: invalid"
       )},
      {~r/admission is missing fields: policy/,
       String.replace(
         minimal_document(),
         "admission:\n  policy:\n    name: admission-read\n    digest: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
         "admission: {}"
       )}
    ]

    for {message, document} <- invalid_documents do
      assert_raise ArgumentError, message, fn -> RuntimeConfiguration.from_string!(document) end
    end
  end

  test "generic webhook configuration rejects weak secrets and malformed adapter authority" do
    webhook = fn auth, destination, work_profile ->
      minimal_document("""
      webhooks:
        port: 4323
        routes:
          universal:
            auth:
      #{indent(auth, 8)}
            destination:
      #{indent(destination, 8)}
            work_profile:
      #{indent(work_profile, 8)}
      """)
    end

    valid_auth = "kind: bearer\nsecret_env: UNIVERSAL_TOKEN"
    valid_destination = "transport: webhook\nconversation_ref: webhook:universal\nthread_ref:"

    valid_profile =
      "policy: webhook-read\npolicy_digest: #{String.duplicate("d", 64)}\nrepository_ref:"

    assert_raise ArgumentError, ~r/kind must be bearer or hmac_sha256/, fn ->
      RuntimeConfiguration.from_string!(
        webhook.("kind: basic\nsecret_env: UNIVERSAL_TOKEN", valid_destination, valid_profile),
        env_provider: fn _ -> {:ok, String.duplicate("s", 16)} end
      )
    end

    for {provider, message} <- [
          {fn _ -> {:ok, "short"} end, ~r/environment variable.*invalid/},
          {fn _ -> :error end, ~r/environment variable.*missing/},
          {fn _ -> :unexpected end, ~r/environment provider returned/}
        ] do
      assert_raise ArgumentError, message, fn ->
        RuntimeConfiguration.from_string!(
          webhook.(valid_auth, valid_destination, valid_profile),
          env_provider: provider
        )
      end
    end

    for {document, message} <- [
          {webhook.("kind: bearer\nsecret_env: lower-case", valid_destination, valid_profile),
           ~r/must name a bounded environment variable/},
          {webhook.(
             valid_auth,
             "transport: Custom.Transport\nconversation_ref: x\nthread_ref:",
             valid_profile
           ), ~r/must be a platform adapter name/},
          {webhook.(
             valid_auth,
             "transport: webhook\nconversation_ref: \" \"\nthread_ref:",
             valid_profile
           ), ~r/bounded nonblank string/},
          {webhook.(
             valid_auth,
             valid_destination,
             "policy: x\npolicy_digest: bad\nrepository_ref:"
           ), ~r/invalid webhooks.routes.universal.work_profile/},
          {minimal_document("webhooks:\n  port: 4323\n  routes: {}"),
           ~r/routes must be a nonempty map/}
        ] do
      assert_raise ArgumentError, message, fn ->
        RuntimeConfiguration.from_string!(document,
          env_provider: fn _ -> {:ok, String.duplicate("s", 16)} end
        )
      end
    end
  end

  test "lazy platform token providers report exact secret failures" do
    for {value, expected} <- [
          {{:ok, ""}, {:error, {:invalid_environment_secret, "SLACK_APP_TOKEN"}}},
          {:error, {:error, {:environment_variable_missing, "SLACK_APP_TOKEN"}}},
          {:unexpected, {:error, {:invalid_environment_provider, "SLACK_APP_TOKEN", :unexpected}}}
        ] do
      provider = fn
        "SLACK_APP_TOKEN" -> value
        "GITHUB_APP_PRIVATE_KEY" -> {:ok, private_key_pem()}
        "RESPONDER_CHECKPOINT_KEY" -> {:ok, Base.encode64(:binary.copy("k", 32))}
        name -> {:ok, String.duplicate("#{name}-secret", 3)}
      end

      configuration = RuntimeConfiguration.load!(@example, env_provider: provider)
      assert configuration.slack.app_http.token_provider.() == expected
    end
  end

  defp minimal_document(extra \\ "") do
    """
    version: 1
    mode: component
    host_ref: responder-minimal
    coop:
      socket: /tmp/coop.sock
    repositories: {}
    admission:
      policy:
        name: admission-read
        digest: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    work: {}
    #{extra}
    """
  end

  defp indent(value, spaces) do
    prefix = String.duplicate(" ", spaces)
    value |> String.split("\n") |> Enum.map_join("\n", &(prefix <> &1))
  end

  defp restore_environment(name, nil), do: System.delete_env(name)
  defp restore_environment(name, value), do: System.put_env(name, value)

  defp restore_application(key, nil), do: Application.delete_env(:responder, key)
  defp restore_application(key, value), do: Application.put_env(:responder, key, value)
end
