defmodule Ryker.Slack.ChannelSetupTest do
  use Ryker.DataCase, async: true

  alias Ryker.Fixtures.ChannelEnvironments

  alias Ryker.Slack.{
    ChannelConfiguration,
    ChannelConfigurations,
    ChannelSettings,
    ChannelSetup,
    ConfigurationSession,
    Input,
    Interaction,
    MembershipTransition,
    Renderer
  }

  @now ~U[2026-08-28 12:00:00.000000Z]
  @workspace "TD65C7CD93124"

  defmodule API do
    def find_message(agent, channel, thread, delivery_ref) do
      Agent.get(agent, fn state ->
        case Map.get(state.deliveries, {channel, thread, delivery_ref}) do
          nil -> :not_found
          message_ref -> {:ok, message_ref}
        end
      end)
    end

    def post_message(agent, channel, thread, document, delivery_ref) do
      Agent.get_and_update(agent, fn state ->
        message_ref = "#{map_size(state.deliveries) + 1}.000001"
        key = {channel, thread, delivery_ref}

        {{:ok, message_ref},
         %{
           state
           | deliveries: Map.put(state.deliveries, key, message_ref),
             posts:
               state.posts ++ [%{document: document, message_ref: message_ref, thread: thread}]
         }}
      end)
    end

    def update_message(agent, channel, message_ref, document, delivery_ref) do
      Agent.update(agent, fn state ->
        %{
          state
          | updates:
              state.updates ++
                [
                  %{
                    channel: channel,
                    delivery_ref: delivery_ref,
                    document: document,
                    message_ref: message_ref
                  }
                ]
        }
      end)
    end
  end

  defmodule Directory do
    def user_allowed(_client, "U123", "TD65C7CD93124"), do: {:ok, true}
    def user_allowed(_client, "U456", "TD65C7CD93124"), do: {:ok, true}
    def user_allowed(_client, _user_ref, _workspace_ref), do: {:ok, false}

    def user_group_members(_client, "S123", "TD65C7CD93124"), do: {:ok, ["U123", "U456"]}
    def user_group_members(_client, _group_ref, _workspace_ref), do: {:error, :unknown_group}
  end

  defmodule UserOnlyDirectory do
    def user_allowed(_client, _user_ref, _workspace_ref), do: {:ok, true}
  end

  defmodule DeniedDirectory do
    def user_allowed(_client, _user_ref, _workspace_ref), do: {:ok, false}
  end

  defmodule MappingConfigurations do
    def fetch_session(_session_ref), do: {:ok, Process.get({__MODULE__, :session})}

    def apply_action(request) do
      send(self(), {:configuration_action, request.action, request.value})
      {:ok, %{session: Process.get({__MODULE__, :session}), status: :advanced}}
    end

    def bind_prompt(_session_ref, _revision, _message_ref, _thread_ref) do
      {:ok, Process.get({__MODULE__, :session})}
    end

    def configuration(_workspace_ref, _channel_ref), do: Process.get({__MODULE__, :configuration})
    def membership(_workspace_ref, _channel_ref), do: %{generation: 1}

    def change_participation(request) do
      send(self(), {:participation_change, request.participation, request.expected_revision})
      {:ok, %{configuration: Process.get({__MODULE__, :configuration}), status: :saved}}
    end

    def start_reconfiguration(request, _catalog) do
      send(self(), {:reconfiguration_started, request.thread_ref})
      {:ok, %{session: Process.get({__MODULE__, :session}), status: :started}}
    end

    def effective_settings(_workspace_ref, _channel_ref, catalog, overrides) do
      ChannelConfigurations.settings_document(
        Process.get({__MODULE__, :configuration}),
        catalog,
        overrides
      )
      |> then(&{:ok, &1})
    end
  end

  defmodule FailingAPI do
    def find_message(_client, _channel, _thread, _delivery_ref), do: {:error, :slack_down}

    def update_message(_client, _channel, _message_ref, _document, _delivery_ref),
      do: {:error, :slack_down}
  end

  setup do
    agent = start_supervised!({Agent, fn -> %{deliveries: %{}, posts: [], updates: []} end})

    production =
      ChannelEnvironments.environment!("production", %{repositories: ["payments", "ledger"]})

    staging = ChannelEnvironments.environment!("staging")

    options = %{
      api: API,
      bot_user_ref: "UBOT",
      catalog: %{
        default_environment: "production",
        environments: [
          ChannelEnvironments.choice(production, %{
            "payments" => "https://github.com/acme/payments"
          }),
          ChannelEnvironments.choice(staging)
        ]
      },
      client: agent,
      configurations: ChannelConfigurations,
      directory: Directory,
      operators: MapSet.new(["U123"]),
      settings_overrides: fn workspace_ref, channel_ref ->
        ChannelSettings.effective(
          workspace_ref,
          "slack:#{workspace_ref}:#{channel_ref}",
          :mentions
        )
      end
    }

    %{options: options}
  end

  # The Q&A's second question asked which repository to use when nobody named
  # one. A channel selects an environment now, so the question offers every
  # environment, says what work here could use in each, and offers No
  # environment, which saves as none rather than as the default.
  test "the wizard offers environments and No environment", %{options: options} do
    assert {:ok, _joined} = ChannelSetup.handle_membership(membership(), options)
    configuration = ChannelConfigurations.configuration(@workspace, "C456")
    assert configuration.environment_ref == "production"

    customize =
      welcome_interaction(configuration, "ryker_welcome_configure", "interaction:customize")

    assert {:ok, %{session_ref: session_ref}} =
             ChannelSetup.handle_interaction(customize, options)

    {:ok, session} = ChannelConfigurations.fetch_session(session_ref)

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_interaction(
               interaction(session, "ryker_setup_participation_mentions", "interaction:mentions"),
               options
             )

    assert %{document: %{"channel_setup" => %{"step" => "environment"} = step}} =
             List.last(updates(options))

    assert {:ok, %{"blocks" => [explanation | controls]}} =
             Renderer.render(%{"channel_setup" => step})

    text = explanation["text"]["text"]
    assert text =~ "*2 · Environment*"
    assert text =~ "*Production* — I'll make changes in `payments` and read `ledger`."
    assert text =~ "*Staging* — It has no repos or Emisar, so I'll answer without them."
    assert text =~ "*No environment* — I'll still answer here, but without any repos or Emisar."

    assert Enum.flat_map(controls, & &1["elements"])
           |> Enum.map(&{&1["action_id"], &1["text"]["text"], &1["value"]}) == [
             {"ryker_setup_environment_0", "Production", session_ref},
             {"ryker_setup_environment_1", "Staging", session_ref},
             {"ryker_setup_environment_none", "No environment", session_ref}
           ]

    # The wizard replaces itself in one message, so every step's control names
    # the same session and message.
    for action_id <- [
          "ryker_setup_environment_none",
          "ryker_setup_alerts_reply",
          "ryker_setup_audience_none"
        ] do
      assert {:ok, %{outcome: :advanced}} =
               ChannelSetup.handle_interaction(
                 interaction(session, action_id, "interaction:#{action_id}"),
                 options
               )
    end

    assert %{document: %{"channel_setup" => %{"step" => "confirm"} = confirm}} =
             List.last(updates(options))

    assert {:ok, %{"blocks" => [summary | _controls]}} =
             Renderer.render(%{"channel_setup" => confirm})

    assert summary["text"]["text"] =~
             "I won't use an environment, so I'll answer without any repos or Emisar."

    assert {:ok, %{outcome: :saved}} =
             ChannelSetup.handle_interaction(
               interaction(session, "ryker_setup_save", "interaction:save"),
               options
             )

    saved = ChannelConfigurations.configuration(@workspace, "C456")
    assert saved.environment_ref == nil
    assert saved.revision == 2

    assert %{message_ref: "1.000001", document: %{"channel_welcome" => welcome}} =
             List.last(updates(options))

    assert welcome["settings"]["environment"] == nil
  end

  # The 30-minute setup card used to be the only path to a saved configuration;
  # a channel whose card expired unanswered had no welcome and no defaults.
  test "a join posts one welcome generated from the default settings and an exact retry finds it",
       %{options: options} do
    transition = membership()

    assert {:ok, first} = ChannelSetup.handle_membership(transition, options)
    assert first.status == :joined
    assert first.prompted == :posted

    configuration = ChannelConfigurations.configuration(@workspace, "C456")
    assert configuration.welcome_message_ref == "1.000001"

    assert [%{document: %{"channel_welcome" => welcome}, thread: nil}] = posts(options)
    assert welcome["configuration_ref"] == configuration.id
    assert welcome["revision"] == 1
    assert welcome["notice"] == nil

    assert welcome["settings"]["participation"] == %{
             "source" => "installation",
             "value" => "mentions"
           }

    assert welcome["settings"]["environment"]["ref"] == "production"
    assert welcome["settings"]["alert_policy"] == "reply"

    assert {:ok, duplicate} = ChannelSetup.handle_membership(transition, options)
    assert duplicate.status == :duplicate
    assert duplicate.prompted == :updated
    assert length(posts(options)) == 1
    assert [%{message_ref: "1.000001"}] = updates(options)
  end

  test "the welcome's own controls change participation in place and never post a second introduction",
       %{options: options} do
    assert {:ok, _joined} = ChannelSetup.handle_membership(membership(), options)
    configuration = ChannelConfigurations.configuration(@workspace, "C456")

    proactive =
      welcome_interaction(
        configuration,
        "ryker_welcome_be_proactive",
        "interaction:proactive"
      )

    assert {:ok, %{outcome: :saved}} = ChannelSetup.handle_interaction(proactive, options)

    saved = ChannelConfigurations.configuration(@workspace, "C456")
    assert saved.participation == :proactive
    assert saved.revision == 2
    assert saved.actor_ref == "U123"
    assert saved.welcome_message_ref == "1.000001"

    assert [%{message_ref: "1.000001", document: %{"channel_welcome" => welcome}}] =
             updates(options)

    assert welcome["revision"] == 2
    assert welcome["notice"] == "Update: proactive mode is on."
    assert welcome["settings"]["participation"]["value"] == "proactive"
    assert length(posts(options)) == 1

    stale =
      welcome_interaction(configuration, "ryker_welcome_mentions_only", "interaction:stale")

    assert ChannelSetup.handle_interaction(stale, options) ==
             {:error, :configuration_revision_stale}

    assert ChannelConfigurations.configuration(@workspace, "C456").revision == 2
    assert length(updates(options)) == 1
  end

  test "customizing opens one wizard in the welcome thread that replaces itself", %{
    options: options
  } do
    assert {:ok, _joined} = ChannelSetup.handle_membership(membership(), options)
    configuration = ChannelConfigurations.configuration(@workspace, "C456")

    customize =
      welcome_interaction(configuration, "ryker_welcome_configure", "interaction:customize")

    assert {:ok, %{outcome: :started, session_ref: session_ref}} =
             ChannelSetup.handle_interaction(customize, options)

    {:ok, session} = ChannelConfigurations.fetch_session(session_ref)
    assert session.response_thread_ref == "1.000001"
    assert session.current_message_ref == "2.000001"

    assert [_welcome, %{document: %{"channel_setup" => step}, thread: "1.000001"}] =
             posts(options)

    assert step["step"] == "participation"
    assert step["bot_user_ref"] == "UBOT"

    mentions =
      interaction(session, "ryker_setup_participation_mentions", "interaction:mentions")

    assert {:ok, %{outcome: :advanced}} = ChannelSetup.handle_interaction(mentions, options)

    {:ok, session} = ChannelConfigurations.fetch_session(session.id)
    assert session.step == :environment
    assert session.current_message_ref == "2.000001"
    assert length(posts(options)) == 2

    assert [%{message_ref: "2.000001", document: %{"channel_setup" => environment_step}}] =
             updates(options)

    assert environment_step["step"] == "environment"
    assert environment_step["revision"] == session.revision

    assert {:ok, %{outcome: :duplicate}} = ChannelSetup.handle_interaction(customize, options)

    again = welcome_interaction(configuration, "ryker_welcome_configure", "interaction:again")

    assert {:ok, %{outcome: :existing, session_ref: ^session_ref}} =
             ChannelSetup.handle_interaction(again, options)

    assert length(posts(options)) == 2
  end

  test "completing the optional setup re-renders the original welcome instead of posting a second one",
       %{options: options} do
    assert {:ok, _joined} = ChannelSetup.handle_membership(membership(), options)
    configuration = ChannelConfigurations.configuration(@workspace, "C456")

    customize =
      welcome_interaction(configuration, "ryker_welcome_configure", "interaction:customize")

    assert {:ok, %{session_ref: session_ref}} =
             ChannelSetup.handle_interaction(customize, options)

    steps = [
      "ryker_setup_participation_proactive",
      "ryker_setup_environment_1",
      "ryker_setup_alerts_offer",
      "ryker_setup_audience_none",
      "ryker_setup_save"
    ]

    Enum.each(steps, fn action_id ->
      {:ok, session} = ChannelConfigurations.fetch_session(session_ref)
      request = interaction(session, action_id, "interaction:#{action_id}")
      assert {:ok, %{outcome: outcome}} = ChannelSetup.handle_interaction(request, options)
      assert outcome in [:advanced, :saved]
    end)

    saved = ChannelConfigurations.configuration(@workspace, "C456")
    assert saved.id == configuration.id
    assert saved.revision == 2
    assert saved.participation == :proactive
    assert saved.environment_ref == "staging"
    assert saved.alert_policy == :offer
    assert saved.welcome_message_ref == "1.000001"

    assert length(posts(options)) == 2
    last_updates = updates(options) |> Enum.take(-2)

    assert [
             %{message_ref: "2.000001", document: %{"channel_setup" => %{"status" => "saved"}}},
             %{message_ref: "1.000001", document: %{"channel_welcome" => welcome}}
           ] = last_updates

    # The channel should read who changed it and when, not a system notice. It
    # travels as a host fact so the renderer can build a real mention from it.
    assert %{"actor_ref" => "U123", "at" => at} = welcome["notice"]
    assert {:ok, _at, 0} = DateTime.from_iso8601(at)
    assert welcome["revision"] == 2
    assert welcome["settings"]["participation"]["value"] == "proactive"
    assert welcome["settings"]["alert_policy"] == "offer"
    assert welcome["settings"]["environment"]["ref"] == "staging"
  end

  test "a stale or replayed setup click leaves the welcome and configuration untouched",
       %{options: options} do
    assert {:ok, _joined} = ChannelSetup.handle_membership(membership(), options)
    configuration = ChannelConfigurations.configuration(@workspace, "C456")

    customize =
      welcome_interaction(configuration, "ryker_welcome_configure", "interaction:customize")

    assert {:ok, %{session_ref: session_ref}} =
             ChannelSetup.handle_interaction(customize, options)

    {:ok, session} = ChannelConfigurations.fetch_session(session_ref)

    # A save control from a step the wizard has not reached is a mismatch, not a save.
    early_save = interaction(session, "ryker_setup_save", "interaction:early-save")

    assert ChannelSetup.handle_interaction(early_save, options) ==
             {:error, :configuration_action_mismatch}

    copied = %{
      interaction(session, "ryker_setup_participation_shadow", "interaction:copied")
      | message_ref: "9.000009"
    }

    assert ChannelSetup.handle_interaction(copied, options) ==
             {:error, :configuration_message_mismatch}

    updates_before = updates(options)
    assert ChannelConfigurations.configuration(@workspace, "C456").revision == 1
    assert ChannelConfigurations.configuration(@workspace, "C456").participation == nil

    shadow = interaction(session, "ryker_setup_participation_shadow", "interaction:shadow")
    assert {:ok, %{outcome: :advanced}} = ChannelSetup.handle_interaction(shadow, options)
    assert {:ok, %{outcome: :duplicate}} = ChannelSetup.handle_interaction(shadow, options)

    assert ChannelConfigurations.configuration(@workspace, "C456").revision == 1
    assert length(posts(options)) == 2
    assert length(updates(options)) == length(updates_before) + 2
  end

  test "a settings question is answered in its thread from the same projection without changing anything",
       %{options: options} do
    assert {:ok, _joined} = ChannelSetup.handle_membership(membership(), options)

    question = normalized("U456", "<@UBOT> what are your settings?", "77.000001", :mention)
    assert {:ok, %{outcome: :settings_shown}} = ChannelSetup.handle_message(question, options)

    assert %{document: %{"channel_settings" => view}, thread: "77.000001"} =
             List.last(posts(options))

    assert view["audience"] == "thread"
    assert view["settings"]["participation"]["value"] == "mentions"

    assert view["settings"]["environment"]["repositories"] == [
             %{"ref" => "payments", "url" => "https://github.com/acme/payments"},
             %{"ref" => "ledger", "url" => nil}
           ]

    assert ChannelConfigurations.configuration(@workspace, "C456").revision == 1

    assert {:ok, %{outcome: :settings_shown}} = ChannelSetup.handle_message(question, options)
    assert length(posts(options)) == 2

    assert ChannelSetup.handle_message(
             normalized("U999", "<@UBOT> settings", nil, :mention),
             options
           ) ==
             :not_setup

    assert ChannelSetup.handle_message(
             normalized("U456", "what are your settings?", nil),
             options
           ) ==
             :not_setup
  end

  test "collections asked for in conversation or from the settings view arrive as item cards in that thread",
       %{options: options} do
    assert {:ok, _joined} = ChannelSetup.handle_membership(membership(), options)
    configuration = ChannelConfigurations.configuration(@workspace, "C456")

    question = normalized("U456", "<@UBOT> what schedules are active?", "88.000001", :mention)

    assert {:ok, %{outcome: :collection_shown, collection: :schedules, shown: 0, total: 0}} =
             ChannelSetup.handle_message(question, options)

    assert %{
             document: %{"message" => "No active schedules are set up in this channel."},
             thread: "88.000001"
           } =
             List.last(posts(options))

    view = %{
      welcome_interaction(configuration, "ryker_welcome_view_rules", "interaction:view-rules")
      | message_ref: "99.000001",
        thread_ref: "77.000001"
    }

    assert {:ok, %{outcome: :collection_shown, collection: :standing_rules, shown: 0, total: 0}} =
             ChannelSetup.handle_interaction(view, options)

    assert %{
             document: %{"message" => "No standing rules are set up in this channel."},
             thread: "77.000001"
           } =
             List.last(posts(options))

    stale = %{view | action_value: "#{configuration.id}|9"}

    assert ChannelSetup.handle_interaction(stale, options) ==
             {:error, :configuration_revision_stale}

    assert ChannelSetup.handle_message(
             normalized("U999", "<@UBOT> show schedules", nil, :mention),
             options
           ) ==
             :not_setup

    assert ChannelConfigurations.configuration(@workspace, "C456").revision == 1
  end

  test "unknown users and unrelated messages remain on the ordinary ingress path", %{
    options: options
  } do
    assert {:ok, _joined} = ChannelSetup.handle_membership(membership(), options)
    configuration = ChannelConfigurations.configuration(@workspace, "C456")

    customize =
      welcome_interaction(configuration, "ryker_welcome_configure", "interaction:customize")

    assert {:ok, %{session_ref: session_ref}} =
             ChannelSetup.handle_interaction(customize, options)

    {:ok, session} = ChannelConfigurations.fetch_session(session_ref)

    normalized = normalized("U999", "proactive", nil)
    assert ChannelSetup.handle_message(normalized, options) == :not_setup

    ambiguous = normalized("U123", "talk about the incident", session.response_thread_ref)

    assert ChannelSetup.handle_message(ambiguous, options) ==
             {:ok, %{outcome: :clarification, session_ref: session.id}}

    {:ok, unchanged} = ChannelConfigurations.fetch_session(session.id)
    assert unchanged.revision == session.revision
    assert List.last(posts(options)).document =~ "Please choose"
  end

  test "an addressed reconfiguration request opens a fresh setup in the same thread", %{
    options: options
  } do
    assert {:ok, _joined} = ChannelSetup.handle_membership(membership(), options)

    normalized =
      normalized(
        "U123",
        "<@UBOT> reconfigure this channel",
        "9000.000001",
        :mention
      )

    assert {:ok, %{outcome: :started, session_ref: reconfigured_ref}} =
             ChannelSetup.handle_message(normalized, options)

    {:ok, reconfigured} = ChannelConfigurations.fetch_session(reconfigured_ref)
    assert reconfigured.response_thread_ref == "9000.000001"
    assert reconfigured.root_message_ref == "9000.000001"
    assert List.last(posts(options)).thread == "9000.000001"
  end

  test "the durable setup card maps every control to one typed host action", %{options: options} do
    session = %ConfigurationSession{
      id: Ecto.UUID.generate(),
      workspace_ref: @workspace,
      channel_ref: "C456",
      step: :environment,
      status: :asking,
      draft: %{
        "environment_options" => [
          %{
            "emisar" => false,
            "name" => "Production",
            "ref" => "production",
            "repositories" => []
          },
          %{"emisar" => false, "name" => "Staging", "ref" => "staging", "repositories" => []}
        ]
      },
      revision: 7,
      response_thread_ref: "1.000001",
      current_message_ref: "2.000001",
      expires_at: DateTime.add(@now, 1_800, :second)
    }

    configuration = %ChannelConfiguration{
      id: Ecto.UUID.generate(),
      workspace_ref: @workspace,
      channel_ref: "C456",
      participation: :mentions,
      environment_ref: "production",
      alert_policy: :reply,
      invite_user_refs: [],
      invite_user_group_refs: [],
      actor_ref: nil,
      revision: 3,
      welcome_message_ref: "1.000001"
    }

    Process.put({MappingConfigurations, :session}, session)
    Process.put({MappingConfigurations, :configuration}, configuration)
    options = %{options | configurations: MappingConfigurations}

    actions = [
      {"ryker_setup_participation_mentions", :participation, :mentions},
      {"ryker_setup_participation_proactive", :participation, :proactive},
      {"ryker_setup_participation_shadow", :participation, :shadow},
      {"ryker_setup_environment_0", :environment, "production"},
      {"ryker_setup_environment_1", :environment, "staging"},
      {"ryker_setup_environment_none", :environment, nil},
      {"ryker_setup_alerts_reply", :alerts, :reply},
      {"ryker_setup_alerts_offer", :alerts, :offer},
      {"ryker_setup_alerts_automatic", :alerts, :automatic},
      {"ryker_setup_audience_none", :audience, :none},
      {"ryker_setup_save", :save, nil},
      {"ryker_setup_restart", :restart, nil},
      {"ryker_setup_cancel", :cancel, nil}
    ]

    Enum.with_index(actions, fn {action_id, action, value}, index ->
      request = interaction(session, action_id, "interaction:mapping:#{index}")

      assert {:ok, %{outcome: :advanced, session_ref: session_ref}} =
               ChannelSetup.handle_interaction(request, options)

      assert session_ref == session.id
      assert_received {:configuration_action, ^action, ^value}
    end)

    for retired <-
          ~w(ryker_setup_safe_defaults ryker_setup_be_proactive ryker_setup_customize) do
      assert ChannelSetup.handle_interaction(
               interaction(session, retired, "interaction:#{retired}"),
               options
             ) ==
               {:error, :configuration_action_mismatch}
    end

    assert ChannelSetup.handle_interaction(
             interaction(session, "ryker_setup_environment_99", "interaction:bad-index"),
             options
           ) == {:error, :configuration_action_mismatch}

    assert ChannelSetup.handle_interaction(
             interaction(session, "ryker_setup_environment_nope", "interaction:bad-action"),
             options
           ) == {:error, :configuration_action_mismatch}

    for {action_id, participation} <- [
          {"ryker_welcome_be_proactive", :proactive},
          {"ryker_welcome_mentions_only", :mentions}
        ] do
      request = welcome_interaction(configuration, action_id, "interaction:#{action_id}")
      assert {:ok, %{outcome: :saved}} = ChannelSetup.handle_interaction(request, options)
      assert_received {:participation_change, ^participation, 3}
    end

    configure =
      welcome_interaction(configuration, "ryker_welcome_configure", "interaction:configure")

    assert {:ok, %{outcome: :started}} = ChannelSetup.handle_interaction(configure, options)
    assert_received {:reconfiguration_started, "1.000001"}

    forged = %{configure | action_value: "#{configuration.id}|2"}

    assert ChannelSetup.handle_interaction(forged, options) ==
             {:error, :configuration_revision_stale}

    malformed = %{configure | action_value: "not-a-configuration"}

    assert ChannelSetup.handle_interaction(malformed, options) ==
             {:error, :configuration_action_mismatch}
  end

  test "natural setup answers save the exact Slack audience and the named environment", %{
    options: options
  } do
    assert {:ok, _joined} = ChannelSetup.handle_membership(membership(), options)

    assert {:ok, %{outcome: :started}} =
             ChannelSetup.handle_message(
               normalized("U123", "<@UBOT> configure this channel", "55.000001", :mention),
               options
             )

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(
               normalized("U123", "mentions only", "55.000001"),
               options
             )

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "Staging", "55.000001"), options)

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(
               normalized("U123", "create automatically", "55.000001"),
               options
             )

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(
               normalized("U123", "<@U456> <!subteam^S123|operators> <@U456>", "55.000001"),
               options
             )

    assert {:ok, %{outcome: :saved}} =
             ChannelSetup.handle_message(
               normalized("U123", "save settings", "55.000001"),
               options
             )

    configuration = ChannelConfigurations.configuration(@workspace, "C456")
    assert configuration.participation == :mentions
    assert configuration.environment_ref == "staging"
    assert configuration.alert_policy == :automatic
    assert configuration.invite_user_refs == ["U456"]
    assert configuration.invite_user_group_refs == ["S123"]

    assert %{message_ref: "1.000001", document: %{"channel_welcome" => welcome}} =
             List.last(updates(options))

    assert welcome["settings"]["invitations"] == %{
             "user_group_refs" => ["S123"],
             "user_refs" => ["U456"]
           }
  end

  test "clarification retries and adapter failures preserve ordinary ingress", %{options: options} do
    assert {:ok, _joined} = ChannelSetup.handle_membership(membership(), options)

    assert {:ok, %{outcome: :started, session_ref: session_ref}} =
             ChannelSetup.handle_message(
               normalized("U123", "<@UBOT> configure this channel", nil, :mention),
               options
             )

    assert {:ok, %{outcome: :clarification, session_ref: ^session_ref}} =
             ChannelSetup.handle_message(normalized("U123", "nonsense", nil), options)

    assert {:ok, %{outcome: :clarification, session_ref: ^session_ref}} =
             ChannelSetup.handle_message(normalized("U123", "nonsense", nil), options)

    assert ChannelSetup.handle_message(%{}, options) == :not_setup

    assert ChannelSetup.handle_message(normalized("U123", "configure this channel", nil), options) ==
             {:ok, %{outcome: :clarification, session_ref: session_ref}}

    {:ok, session} = ChannelConfigurations.fetch_session(session_ref)

    assert ChannelSetup.ensure_prompt(session, %{options | api: FailingAPI}) ==
             {:error, :slack_down}

    configuration = ChannelConfigurations.configuration(@workspace, "C456")

    assert ChannelSetup.ensure_welcome(configuration, nil, %{options | api: FailingAPI}) ==
             {:error, :slack_down}
  end

  test "every conversational setup choice has a recoverable natural-language path", %{
    options: options
  } do
    assert {:ok, _joined} = ChannelSetup.handle_membership(membership(), options)

    assert {:ok, %{outcome: :started}} =
             ChannelSetup.handle_message(
               normalized("U123", "<@UBOT> configure this channel", nil, :mention),
               options
             )

    assert {:ok, %{outcome: :clarification}} =
             ChannelSetup.handle_message(
               normalized("U123", "participation choice is unclear", nil),
               options
             )

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "be proactive", nil), options)

    assert {:ok, %{outcome: :clarification}} =
             ChannelSetup.handle_message(
               normalized("U123", "environment choice is unclear", nil),
               options
             )

    assert List.last(posts(options)).document ==
             "Please choose Production, Staging or No environment."

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "production", nil), options)

    assert {:ok, %{outcome: :clarification}} =
             ChannelSetup.handle_message(
               normalized("U123", "alert choice is unclear", nil),
               options
             )

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "investigate", nil), options)

    assert {:ok, %{outcome: :clarification}} =
             ChannelSetup.handle_message(
               normalized("U123", "audience choice is unclear", nil),
               options
             )

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(
               normalized("U123", "on-call responders only", nil),
               options
             )

    assert {:ok, %{outcome: :clarification}} =
             ChannelSetup.handle_message(
               normalized("U123", "confirmation choice is unclear", nil),
               options
             )

    assert {:ok, %{outcome: :restarted}} =
             ChannelSetup.handle_message(normalized("U123", "start over", nil), options)

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "observe only", nil), options)

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "No environment", nil), options)

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "offer a choice", nil), options)

    assert ChannelSetup.handle_message(
             normalized("U123", "<!subteam^S999|unknown>", nil),
             options
           ) == {:error, :unknown_group}

    assert ChannelSetup.handle_message(
             normalized("U123", "<!subteam^S123|operators>", nil),
             %{options | directory: UserOnlyDirectory}
           ) == {:error, :configuration_user_group_directory_unavailable}

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "none", nil), options)

    assert {:ok, %{outcome: :cancelled}} =
             ChannelSetup.handle_message(normalized("U123", "cancel", nil), options)

    configuration = ChannelConfigurations.configuration(@workspace, "C456")
    assert configuration.participation == nil
    assert configuration.revision == 1
  end

  test "invalid setup destinations and audience members never mutate configuration", %{
    options: options
  } do
    assert {:ok, _joined} = ChannelSetup.handle_membership(membership(), options)

    assert {:ok, %{outcome: :started}} =
             ChannelSetup.handle_message(
               normalized("U123", "<@UBOT> configure this channel", nil, :mention),
               options
             )

    for text <- ["proactive", "Staging", "offer"] do
      assert {:ok, %{outcome: :advanced}} =
               ChannelSetup.handle_message(normalized("U123", text, nil), options)
    end

    unknown_user = normalized("U123", "<@U999>", nil)

    assert {:ok, %{outcome: :clarification, session_ref: active_ref}} =
             ChannelSetup.handle_message(unknown_user, options)

    assert is_binary(active_ref)

    malformed_destination =
      put_in(
        unknown_user,
        [:input, Access.key(:destination), Access.key(:conversation_ref)],
        "slack:TD65C7CD93124"
      )

    assert ChannelSetup.handle_message(malformed_destination, options) == :not_setup

    foreign_destination =
      put_in(
        unknown_user,
        [:input, Access.key(:destination), Access.key(:conversation_ref)],
        "github:binding:repository:1"
      )

    assert ChannelSetup.handle_message(foreign_destination, options) == :not_setup
    assert ChannelConfigurations.configuration(@workspace, "C456").revision == 1
  end

  test "unaddressed, denied, and malformed setup messages remain recoverable", %{
    options: options
  } do
    assert ChannelSetup.handle_message(normalized("U123", "proactive", nil), options) ==
             :not_setup

    assert {:ok, _joined} = ChannelSetup.handle_membership(membership(), options)

    assert ChannelSetup.handle_message(
             normalized("U123", "<@UBOT> configure this channel", nil, :mention),
             %{options | directory: DeniedDirectory}
           ) == :not_setup

    assert {:ok, %{outcome: :started}} =
             ChannelSetup.handle_message(
               normalized("U123", "<@UBOT> configure this channel", nil, :mention),
               options
             )

    malformed =
      put_in(
        normalized("U123", "proactive", nil),
        [:input, Access.key(:content), "text"],
        42
      )

    assert {:ok, %{outcome: :clarification}} =
             ChannelSetup.handle_message(malformed, options)
  end

  defp membership do
    %MembershipTransition{
      actor_ref: "U123",
      channel_ref: "C456",
      event_ref: "event:join",
      kind: :joined,
      occurred_at: @now,
      workspace_ref: @workspace
    }
  end

  defp interaction(session, action_id, event_ref) do
    %Interaction{
      action_id: action_id,
      action_value: session.id,
      actor_ref: "U123",
      channel_ref: "C456",
      event_ref: event_ref,
      message_ref: session.current_message_ref,
      occurred_at: @now,
      thread_ref: session.response_thread_ref,
      workspace_ref: @workspace
    }
  end

  defp welcome_interaction(configuration, action_id, event_ref) do
    %Interaction{
      action_id: action_id,
      action_value: "#{configuration.id}|#{configuration.revision}",
      actor_ref: "U123",
      channel_ref: "C456",
      event_ref: event_ref,
      message_ref: configuration.welcome_message_ref,
      occurred_at: @now,
      thread_ref: nil,
      workspace_ref: @workspace
    }
  end

  defp normalized(actor_ref, text, thread_ref, audience \\ :ambient) do
    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: actor_ref},
        channel_ref: "C456",
        content: %{"text" => text},
        event_kind: :message,
        event_ref: "event:#{actor_ref}:#{text}",
        message_ref: "4.000001",
        occurred_at: @now,
        revision: 1,
        thread_ref: thread_ref,
        workspace_ref: @workspace
      })

    %{audience: audience, input: input, platform_thread_ref: thread_ref}
  end

  defp posts(options), do: Agent.get(options.client, & &1.posts)
  defp updates(options), do: Agent.get(options.client, & &1.updates)
end
