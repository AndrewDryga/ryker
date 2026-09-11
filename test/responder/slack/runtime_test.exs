defmodule Responder.Slack.RuntimeTest do
  use ExUnit.Case, async: true

  alias Responder.Delivery.{BinaryClient, JSONClient}

  alias Responder.Slack.{
    ActionTokens,
    AttachmentIngestor,
    Client,
    FileClient,
    MintSocketTransport,
    Runtime,
    Supervisor
  }

  test "the Slack supervisor rejects an incomplete child configuration" do
    Process.flag(:trap_exit, true)

    assert {:error, {:function_clause, _stacktrace}} = Supervisor.start_link(%{})
    refute Process.whereis(Supervisor)
  end

  test "builds one trusted Socket Mode gateway from host configuration" do
    app_http = json_client("xapp-test")
    bot_http = json_client("xoxb-test")
    {:ok, bot_client} = Client.new(http: bot_http, requester: JSONClient)

    options =
      Runtime.options!(%{
        app_http: app_http,
        bot_client: bot_client,
        default_repository: "responder",
        identity: %{bot_ref: "B123", bot_user_ref: "U999", workspace_ref: "T123"},
        incident_policy: %{digest: String.duplicate("c", 64), name: "incident-observe"},
        operators: ["U123"],
        repositories: %{
          "responder" => %{
            contributor_policy: %{
              digest: String.duplicate("b", 64),
              name: "responder-contributor"
            }
          }
        },
        default_participation: :proactive
      })

    assert options.transport == MintSocketTransport
    assert options.transport_options.http == app_http
    assert options.handler_settings.client == bot_client
    assert options.handler_settings.attachment_ingestor == AttachmentIngestor
    assert is_function(options.handler_settings.action_tokens, 2)

    assert %FileClient{binary_http: %BinaryClient{}} =
             options.handler_settings.attachment_options.client

    assert is_function(options.handler_settings.effective_settings, 2)
    assert options.handler_settings.home_handler == Responder.Slack.AppHome
    assert options.handler_settings.home_options.api == Client
    assert options.handler_settings.home_options.client == bot_client
    assert options.handler_settings.home_options.operators == MapSet.new(["U123"])
    assert is_function(options.handler_settings.home_options.projection, 3)
    assert is_function(options.handler_settings.home_options.shared_conversations, 3)
    assert options.handler_settings.home_interaction_handler == Responder.Slack.AppHomeControls
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
    assert options.handler_settings.setup_options.catalog.default_repository == "responder"

    assert %{
             binding: %{
               destination_allowed: destination_allowed,
               workspaces: %{"T123" => %{api: Client, client: ^bot_client}}
             },
             message_publisher: Responder.Slack.Publisher,
             reaction_publisher: Responder.Slack.Publisher
           } =
             Runtime.delivery_adapter!(%{
               app_http: app_http,
               bot_client: bot_client,
               default_repository: "responder",
               identity: %{bot_ref: "B123", bot_user_ref: "U999", workspace_ref: "T123"},
               incident_policy: %{digest: String.duplicate("c", 64), name: "incident-observe"},
               operators: ["U123"],
               repositories: %{
                 "responder" => %{
                   contributor_policy: %{
                     digest: String.duplicate("b", 64),
                     name: "responder-contributor"
                   }
                 }
               },
               default_participation: :proactive
             })

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
           } =
             Runtime.child_spec(%{
               app_http: app_http,
               bot_client: bot_client,
               default_repository: "responder",
               identity: %{bot_ref: "B123", bot_user_ref: "U999", workspace_ref: "T123"},
               incident_policy: %{
                 digest: String.duplicate("c", 64),
                 name: "incident-observe"
               },
               operators: ["U123"],
               repositories: %{
                 "responder" => %{
                   contributor_policy: %{
                     digest: String.duplicate("b", 64),
                     name: "responder-contributor"
                   }
                 }
               },
               default_participation: :mentions
             })

    assert incident_worker.worker_ref == "slack-incident-room:T123"
    assert incident_worker.lease_seconds == 300
    assert thread_status_worker.workspace_ref == "T123"
    assert thread_status_worker.api == Client
  end

  test "refuses untrusted identity, authority, and transport configuration" do
    app_http = json_client("xapp-test")
    bot_http = json_client("xoxb-test")
    {:ok, bot_client} = Client.new(http: bot_http, requester: JSONClient)

    base = %{
      app_http: app_http,
      bot_client: bot_client,
      default_repository: "responder",
      identity: %{bot_ref: "B123", bot_user_ref: "U999", workspace_ref: "T123"},
      incident_policy: %{digest: String.duplicate("c", 64), name: "incident-observe"},
      operators: ["U123"],
      repositories: %{
        "responder" => %{
          contributor_policy: %{
            digest: String.duplicate("b", 64),
            name: "responder-contributor"
          }
        }
      },
      default_participation: :proactive
    }

    assert_raise ArgumentError, fn -> Runtime.options!(%{base | app_http: :raw_token}) end
    assert_raise ArgumentError, fn -> Runtime.options!(%{base | bot_client: :raw_token}) end
    assert_raise ArgumentError, fn -> Runtime.options!(%{base | identity: %{}}) end
    assert_raise ArgumentError, fn -> Runtime.options!(%{base | identity: :invalid}) end
    assert_raise ArgumentError, fn -> Runtime.options!(%{base | operators: ["guest"]}) end
    assert_raise ArgumentError, fn -> Runtime.options!(%{base | operators: :invalid}) end
    assert_raise ArgumentError, fn -> Runtime.options!(%{base | repositories: :invalid}) end

    assert_raise ArgumentError, fn ->
      Runtime.options!(%{base | default_repository: "missing"})
    end

    assert_raise ArgumentError, fn ->
      Runtime.options!(%{base | repositories: %{"responder" => %{}}})
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

    assert_raise ArgumentError, fn ->
      Runtime.options!(Map.put(base, :incident_invite_users, ["guest"]))
    end

    assert_raise ArgumentError, fn -> Runtime.options!(Map.put(base, :unknown, true)) end
    assert_raise ArgumentError, fn -> Runtime.options!(:invalid) end

    duplicate = Map.to_list(base) ++ [operators: []]
    assert_raise ArgumentError, fn -> Runtime.options!(duplicate) end
  end

  defp json_client(token) do
    {:ok, client} =
      JSONClient.new(%{
        base_url: "https://slack.com/api",
        finch: Responder.CoopFinch,
        receive_timeout: 1_000,
        token_provider: fn -> {:ok, token} end
      })

    client
  end
end
