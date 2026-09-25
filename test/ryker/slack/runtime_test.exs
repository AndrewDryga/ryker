defmodule Ryker.Slack.RuntimeTest do
  use Ryker.DataCase, async: true

  alias Ryker.Delivery.{BinaryClient, JSONClient}
  alias Ryker.Fixtures.ChannelEnvironments
  alias Ryker.Ingress.WorkProfile

  alias Ryker.Slack.{
    ActionTokens,
    AttachmentIngestor,
    ChannelConfigurationChangeset,
    Client,
    FileClient,
    MintSocketTransport,
    Runtime,
    Supervisor
  }

  # No environment is a choice: work in the channel uses no repository and no
  # Emisar account. Reading it as "use the default" put a channel someone had
  # taken out of every environment back into the default's repositories and
  # Emisar account without anyone noticing, since nothing in Slack says which
  # environment a reply ran in.
  test "a channel without an environment runs outside any environment, never in the default" do
    ChannelEnvironments.environment!("production", %{repositories: ["payments", "ledger"]})
    configure!("C0NONE", nil)
    configure!("C0PROD", "production")

    work_profile = Runtime.options!(configuration()).handler_settings.work_profile

    assert {:ok, %WorkProfile{} = outside} = work_profile.("T123", "slack:T123:C0NONE")
    assert outside.policy == "ryker-chat"
    assert outside.environment_ref == nil
    assert outside.repository_ref == nil
    assert outside.read_only_repository_refs == []

    assert {:ok, %WorkProfile{} = production} = work_profile.("T123", "slack:T123:C0PROD")
    assert production.environment_ref == "production"
    assert production.repository_ref == "payments"
    assert production.read_only_repository_refs == ["ledger"]

    # A conversation with no setting of its own, like a direct message, runs in
    # the default environment.
    assert {:ok, ^production} = work_profile.("T123", "slack:T123:D0DIRECT")

    # With nothing to run outside an environment on, such a channel has no
    # profile rather than borrowing the default's.
    without_fallback =
      configuration() |> Map.delete(:fallback_work_profile) |> Runtime.options!()

    assert without_fallback.handler_settings.work_profile.("T123", "slack:T123:C0NONE") ==
             {:error, :work_profile_unavailable}
  end

  test "the Slack supervisor rejects an incomplete child configuration" do
    Process.flag(:trap_exit, true)

    assert {:error, {:function_clause, _stacktrace}} = Supervisor.start_link(%{})
    refute Process.whereis(Supervisor)
  end

  test "builds one trusted Socket Mode gateway from host configuration" do
    %{app_http: app_http, bot_client: bot_client} = configuration()
    options = Runtime.options!(%{configuration() | default_participation: :proactive})

    assert options.transport == MintSocketTransport
    assert options.transport_options.http == app_http
    assert options.handler_settings.client == bot_client
    assert options.handler_settings.attachment_ingestor == AttachmentIngestor
    assert is_function(options.handler_settings.action_tokens, 2)

    assert %FileClient{binary_http: %BinaryClient{}} =
             options.handler_settings.attachment_options.client

    assert is_function(options.handler_settings.effective_settings, 2)
    assert options.handler_settings.home_handler == Ryker.Slack.AppHome
    assert options.handler_settings.home_options.api == Client
    assert options.handler_settings.home_options.client == bot_client
    assert options.handler_settings.home_options.operators == MapSet.new(["U123"])
    assert is_function(options.handler_settings.home_options.collection, 4)
    assert is_function(options.handler_settings.home_options.projection, 3)
    assert is_function(options.handler_settings.home_options.shared_conversations, 3)
    assert options.handler_settings.home_interaction_handler == Ryker.Slack.AppHomeControls
    assert is_function(options.handler_settings.home_interaction_options.authorize_resource, 1)
    assert is_function(options.handler_settings.home_interaction_options.discard_workspace, 5)
    assert is_function(options.handler_settings.home_interaction_options.forget_memory, 3)

    assert is_function(
             options.handler_settings.home_interaction_options.open_memory_review_editor,
             4
           )

    assert is_function(options.handler_settings.home_interaction_options.recover_publication, 6)
    assert is_function(options.handler_settings.home_interaction_options.refresh_home, 1)
    assert is_function(options.handler_settings.home_interaction_options.resolve_memory_review, 5)
    assert is_function(options.handler_settings.home_interaction_options.run_schedule, 4)
    assert is_function(options.handler_settings.home_interaction_options.set_behavior_status, 6)
    assert is_function(options.handler_settings.home_interaction_options.set_schedule_status, 6)
    assert is_function(options.handler_settings.home_interaction_options.show_collection, 3)
    assert options.handler_settings.interaction_options.operators == MapSet.new(["U123"])
    assert is_function(options.handler_settings.interaction_audit, 2)
    assert is_function(options.handler_settings.reaction_feedback, 1)
    assert is_function(options.handler_settings.continuation, 1)
    assert is_function(options.handler_settings.standing_matcher, 1)
    assert is_function(options.handler_settings.work_profile, 2)
    assert is_function(options.handler_settings.interaction_options.confirm_behavior, 1)
    assert is_function(options.handler_settings.interaction_options.confirm_memory, 1)
    assert is_function(options.handler_settings.interaction_options.configure_channel, 1)
    assert is_function(options.handler_settings.interaction_options.request_incident_room, 1)
    assert is_function(options.handler_settings.interaction_options.stop_work, 1)
    assert is_function(options.handler_settings.interaction_options.close_work, 1)
    assert is_function(options.handler_settings.interaction_options.show_work_record, 1)
    assert is_function(options.handler_settings.interaction_options.approve_task_publication, 1)
    assert is_function(options.handler_settings.interaction_options.check_task_publication, 1)
    assert is_function(options.handler_settings.interaction_options.recover_task_publication, 2)

    # A channel may select the environment by name; only the repository work
    # changes has a known GitHub page.
    assert options.handler_settings.setup_options.catalog == %{
             default_environment: "production",
             environments: [
               %{
                 emisar: false,
                 name: "Production",
                 ref: "production",
                 repositories: [
                   %{ref: "payments", url: "https://github.com/acme/payments"},
                   %{ref: "ledger", url: nil}
                 ]
               }
             ]
           }

    # A task confirmed in Slack runs under its environment's own policy.
    assert %{"production" => %{contributor_policy: task_policy}} =
             options.handler_settings.interaction_options.environments

    assert task_policy.environment_ref == "production"
    assert task_policy.repository_ref == "payments"
    assert task_policy.repository_context["read_only_repositories"] == ["ledger"]

    assert %{
             binding: %{
               destination_allowed: destination_allowed,
               workspaces: %{"T123" => %{api: Client, client: ^bot_client}}
             },
             message_publisher: Ryker.Slack.Publisher,
             reaction_publisher: Ryker.Slack.Publisher
           } = Runtime.delivery_adapter!(configuration())

    assert is_function(destination_allowed, 2)

    assert %{
             start:
               {Supervisor, :start_link,
                [
                  %{
                    action_tokens: %{name: ActionTokens},
                    gateway: _gateway,
                    incident_worker: incident_worker,
                    reconciler: _reconciler,
                    thread_status_worker: thread_status_worker
                  }
                ]}
           } = Runtime.child_spec(configuration())

    assert incident_worker.worker_ref == "slack-incident-room:T123"
    assert incident_worker.lease_seconds == 300
    assert thread_status_worker.workspace_ref == "T123"
    assert thread_status_worker.api == Client
  end

  test "refuses untrusted identity, authority, and transport configuration" do
    base = configuration()

    # The base is trusted, so each refusal below is the one change it makes.
    assert %{} = Runtime.options!(base)

    # No default environment is a valid installation: nothing is chosen yet.
    assert %{} = Runtime.options!(%{base | default_environment: nil})

    # An environment with no repository answers on the installation's policy
    # and has nothing a confirmed task could change.
    chat_only = %{
      contributor_policy: nil,
      display_name: "Chat",
      github_repository: nil,
      work_profile: %{
        environment_ref: "chat",
        parallel_goal_limit: 3,
        policy: "ryker-chat",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      }
    }

    assert %{} = Runtime.options!(put_in(base, [:environments, "chat"], chat_only))

    assert_raise ArgumentError, fn -> Runtime.options!(%{base | app_http: :raw_token}) end
    assert_raise ArgumentError, fn -> Runtime.options!(%{base | bot_client: :raw_token}) end
    assert_raise ArgumentError, fn -> Runtime.options!(%{base | identity: %{}}) end
    assert_raise ArgumentError, fn -> Runtime.options!(%{base | identity: :invalid}) end
    assert_raise ArgumentError, fn -> Runtime.options!(%{base | operators: ["guest"]}) end
    assert_raise ArgumentError, fn -> Runtime.options!(%{base | operators: :invalid}) end
    assert_raise ArgumentError, fn -> Runtime.options!(%{base | environments: :invalid}) end

    # A default that cannot run work yet is not among the choices, but a
    # channel joined meanwhile is still set to it.
    assert %{} = Runtime.options!(%{base | default_environment: "missing"})

    assert_raise ArgumentError, fn ->
      Runtime.options!(%{base | default_environment: "not a ref!"})
    end

    assert_raise ArgumentError, fn ->
      Runtime.options!(%{base | environments: %{"production" => %{}}})
    end

    # A Work profile placed in another environment is not this one's.
    assert_raise ArgumentError, fn ->
      Runtime.options!(
        put_in(base, [:environments, "production", :work_profile, :environment_ref], "staging")
      )
    end

    assert_raise ArgumentError, fn ->
      Runtime.options!(put_in(base, [:environments, "production", :display_name], ""))
    end

    assert_raise ArgumentError, fn ->
      Runtime.options!(%{base | incident_policy: %{name: "invalid", digest: "short"}})
    end

    assert_raise ArgumentError, fn -> Runtime.options!(%{base | incident_policy: :invalid}) end

    assert_raise ArgumentError, fn ->
      Runtime.options!(Map.put(base, :channel_prefix, "No spaces"))
    end

    assert_raise ArgumentError, fn ->
      Runtime.options!(Map.put(base, :maximum_open_incidents, 0))
    end

    assert_raise ArgumentError, fn -> Runtime.options!(Map.put(base, :unknown, true)) end
    assert_raise ArgumentError, fn -> Runtime.options!(:invalid) end

    duplicate = Map.to_list(base) ++ [operators: []]
    assert_raise ArgumentError, fn -> Runtime.options!(duplicate) end
  end

  # The Slack runtime configuration Assembly builds for an installation with a
  # default environment "production": it changes payments and reads ledger.
  defp configuration do
    app_http = json_client("xapp-test")
    {:ok, bot_client} = Client.new(http: json_client("xoxb-test"), requester: JSONClient)

    %{
      app_http: app_http,
      bot_client: bot_client,
      default_environment: "production",
      default_participation: :mentions,
      environments: %{"production" => production_environment()},
      fallback_work_profile: %{
        policy: "ryker-chat",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      },
      identity: %{bot_ref: "B123", bot_user_ref: "U999", workspace_ref: "T123"},
      incident_policy: %{digest: String.duplicate("c", 64), name: "incident-observe"},
      operators: ["U123"]
    }
  end

  defp production_environment do
    context = %{
      "context_ref" => "production",
      "parallel_goal_limit" => 3,
      "primary_repository" => "payments",
      "read_only_repositories" => ["ledger"]
    }

    %{
      contributor_policy: %{
        digest: String.duplicate("b", 64),
        environment_ref: "production",
        name: "production-contributor",
        repository_context: context,
        repository_ref: "payments"
      },
      display_name: "Production",
      github_repository: "acme/payments",
      work_profile: %{
        emisar_connection_ref: nil,
        environment_ref: "production",
        parallel_goal_limit: 3,
        policy: "production-conversation",
        policy_digest: String.duplicate("d", 64),
        read_only_repository_refs: ["ledger"],
        repository_ref: "payments"
      }
    }
  end

  defp configure!(channel_ref, environment_ref) do
    %{
      alert_policy: :reply,
      channel_ref: channel_ref,
      environment_ref: environment_ref,
      id: Ecto.UUID.generate(),
      invite_user_group_refs: [],
      invite_user_refs: [],
      revision: 1,
      saved_at: ~U[2026-09-25 12:00:00.000000Z],
      workspace_ref: "T123"
    }
    |> ChannelConfigurationChangeset.configuration()
    |> Repo.insert!()
  end

  defp json_client(token) do
    {:ok, client} =
      JSONClient.new(%{
        base_url: "https://slack.com/api",
        finch: Ryker.CoopFinch,
        receive_timeout: 1_000,
        token_provider: fn -> {:ok, token} end
      })

    client
  end
end
