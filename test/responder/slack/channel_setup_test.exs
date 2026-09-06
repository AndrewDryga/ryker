defmodule Responder.Slack.ChannelSetupTest do
  use Responder.DataCase, async: true

  alias Responder.Slack.{
    ChannelConfigurations,
    ChannelSetup,
    ConfigurationSession,
    Input,
    Interaction,
    MembershipTransition
  }

  @now ~U[2026-08-28 12:00:00.000000Z]

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
             posts: state.posts ++ [%{document: document, thread: thread}]
         }}
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
  end

  defmodule FailingAPI do
    def find_message(_client, _channel, _thread, _delivery_ref), do: {:error, :slack_down}
  end

  setup do
    agent = start_supervised!({Agent, fn -> %{deliveries: %{}, posts: []} end})

    options = %{
      api: API,
      bot_user_ref: "U-BOT",
      catalog: %{
        default_repository: "infrastructure",
        repository_refs: ["backend", "infrastructure"]
      },
      client: agent,
      configurations: ChannelConfigurations,
      directory: Directory,
      operators: MapSet.new(["U123"])
    }

    %{options: options}
  end

  test "a join posts one recoverable card and an exact retry finds it", %{options: options} do
    transition = membership()

    assert {:ok, first} = ChannelSetup.handle_membership(transition, options)
    assert first.status == :joined
    assert first.prompted == :posted
    assert first.session.current_message_ref == nil

    assert {:ok, stored} = ChannelConfigurations.fetch_session(first.session.id)
    assert stored.current_message_ref == "1.000001"
    assert stored.root_message_ref == "1.000001"

    assert {:ok, duplicate} = ChannelSetup.handle_membership(transition, options)
    assert duplicate.status == :duplicate
    assert duplicate.prompted == :existing

    assert [%{document: %{"channel_setup" => setup}, thread: nil}] = posts(options)
    assert setup["session_ref"] == first.session.id
  end

  test "button and natural answers advance one stored setup and follow its operator", %{
    options: options
  } do
    assert {:ok, joined} = ChannelSetup.handle_membership(membership(), options)
    {:ok, session} = ChannelConfigurations.fetch_session(joined.session.id)

    customize = interaction(session, "responder_setup_customize", "interaction:customize")
    assert {:ok, %{outcome: :advanced}} = ChannelSetup.handle_interaction(customize, options)

    {:ok, session} = ChannelConfigurations.fetch_session(session.id)
    assert session.draft["customizing"]
    assert session.current_message_ref == "2.000001"

    assert {:ok, input} =
             Input.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "shadow"},
               event_kind: :message,
               event_ref: "event:answer",
               message_ref: "3.000001",
               occurred_at: @now,
               revision: 1,
               thread_ref: session.root_message_ref,
               workspace_ref: "TD65C7CD93124"
             })

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(
               %{
                 audience: :ambient,
                 input: input,
                 platform_thread_ref: session.root_message_ref
               },
               options
             )

    {:ok, session} = ChannelConfigurations.fetch_session(session.id)
    assert session.step == :repository
    assert session.draft["participation"] == "shadow"
    assert session.response_thread_ref == session.root_message_ref
    assert session.current_message_ref == "3.000001"

    assert Enum.map(posts(options), & &1.thread) == [nil, nil, session.root_message_ref]
  end

  test "unknown users and unrelated messages remain on the ordinary ingress path", %{
    options: options
  } do
    assert {:ok, joined} = ChannelSetup.handle_membership(membership(), options)
    {:ok, session} = ChannelConfigurations.fetch_session(joined.session.id)

    normalized = normalized("U999", "proactive", nil)
    assert ChannelSetup.handle_message(normalized, options) == :not_setup

    ambiguous = normalized("U123", "talk about the incident", session.root_message_ref)

    assert ChannelSetup.handle_message(ambiguous, options) ==
             {:ok, %{outcome: :clarification, session_ref: session.id}}

    {:ok, unchanged} = ChannelConfigurations.fetch_session(session.id)
    assert unchanged.revision == session.revision
    assert List.last(posts(options)).document =~ "Please choose"
  end

  test "an addressed reconfiguration request opens a fresh setup in the same thread", %{
    options: options
  } do
    assert {:ok, joined} = ChannelSetup.handle_membership(membership(), options)
    {:ok, session} = ChannelConfigurations.fetch_session(joined.session.id)

    assert {:ok, _saved} =
             ChannelSetup.handle_interaction(
               interaction(session, "responder_setup_safe_defaults", "interaction:save"),
               options
             )

    normalized =
      normalized(
        "U123",
        "<@U-BOT> reconfigure this channel",
        "9000.000001",
        :mention
      )

    assert {:ok, %{outcome: :started, session_ref: reconfigured_ref}} =
             ChannelSetup.handle_message(normalized, options)

    refute reconfigured_ref == session.id
    {:ok, reconfigured} = ChannelConfigurations.fetch_session(reconfigured_ref)
    assert reconfigured.response_thread_ref == "9000.000001"
    assert reconfigured.root_message_ref == "9000.000001"
    assert List.last(posts(options)).thread == "9000.000001"
  end

  test "the durable setup card maps every control to one typed host action", %{options: options} do
    session = %ConfigurationSession{
      id: Ecto.UUID.generate(),
      workspace_ref: "TD65C7CD93124",
      channel_ref: "C456",
      step: :repository,
      status: :asking,
      draft: %{"repository_options" => ["backend", "infrastructure"]},
      revision: 7,
      response_thread_ref: "1.000001",
      current_message_ref: "2.000001",
      expires_at: DateTime.add(@now, 1_800, :second)
    }

    Process.put({MappingConfigurations, :session}, session)
    options = %{options | configurations: MappingConfigurations}

    actions = [
      {"responder_setup_safe_defaults", :safe_defaults, nil},
      {"responder_setup_be_proactive", :be_proactive, nil},
      {"responder_setup_customize", :customize, nil},
      {"responder_setup_participation_mentions", :participation, :mentions},
      {"responder_setup_participation_proactive", :participation, :proactive},
      {"responder_setup_participation_shadow", :participation, :shadow},
      {"responder_setup_repository_0", :repository, "backend"},
      {"responder_setup_repository_1", :repository, "infrastructure"},
      {"responder_setup_alerts_reply", :alerts, :reply},
      {"responder_setup_alerts_offer", :alerts, :offer},
      {"responder_setup_alerts_automatic", :alerts, :automatic},
      {"responder_setup_audience_none", :audience, :none},
      {"responder_setup_save", :save, nil},
      {"responder_setup_restart", :restart, nil},
      {"responder_setup_cancel", :cancel, nil}
    ]

    Enum.with_index(actions, fn {action_id, action, value}, index ->
      request = interaction(session, action_id, "interaction:mapping:#{index}")

      assert {:ok, %{outcome: :advanced, session_ref: session_ref}} =
               ChannelSetup.handle_interaction(request, options)

      assert session_ref == session.id
      assert_received {:configuration_action, ^action, ^value}
    end)

    assert ChannelSetup.handle_interaction(
             interaction(session, "responder_setup_repository_99", "interaction:bad-index"),
             options
           ) == {:error, :configuration_action_mismatch}

    assert ChannelSetup.handle_interaction(
             interaction(session, "responder_setup_repository_nope", "interaction:bad-action"),
             options
           ) == {:error, :configuration_action_mismatch}
  end

  test "natural setup answers save the exact Slack audience and configured repository", %{
    options: options
  } do
    assert {:ok, joined} = ChannelSetup.handle_membership(membership(), options)

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "customize", nil), options)

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "mentions only", nil), options)

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "backend", nil), options)

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "auto", nil), options)

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(
               normalized("U123", "<@U456> <!subteam^S123|operators> <@U456>", nil),
               options
             )

    assert {:ok, %{outcome: :saved, session_ref: session_ref}} =
             ChannelSetup.handle_message(normalized("U123", "save configuration", nil), options)

    assert session_ref == joined.session.id
    configuration = ChannelConfigurations.configuration("TD65C7CD93124", "C456")
    assert configuration.participation == :mentions
    assert configuration.repository_ref == "backend"
    assert configuration.alert_policy == :automatic
    assert configuration.invite_user_refs == ["U456"]
    assert configuration.invite_user_group_refs == ["S123"]
  end

  test "setup movement, clarification retries, and adapter failures preserve ordinary ingress", %{
    options: options
  } do
    assert {:ok, joined} = ChannelSetup.handle_membership(membership(), options)

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "customize", nil), options)

    assert {:ok, %{outcome: :moved}} =
             ChannelSetup.handle_message(
               normalized("U123", "continue in a thread", nil),
               options
             )

    {:ok, session} = ChannelConfigurations.fetch_session(joined.session.id)
    assert session.response_thread_ref == session.root_message_ref

    assert {:ok, %{outcome: :moved}} =
             ChannelSetup.handle_message(
               normalized("U123", "back to the channel", session.root_message_ref),
               options
             )

    assert {:ok, %{outcome: :clarification, session_ref: session_ref}} =
             ChannelSetup.handle_message(normalized("U123", "nonsense", nil), options)

    assert {:ok, %{outcome: :clarification, session_ref: ^session_ref}} =
             ChannelSetup.handle_message(normalized("U123", "nonsense", nil), options)

    assert ChannelSetup.handle_message(%{}, options) == :not_setup

    assert ChannelSetup.handle_message(normalized("U123", "configure this channel", nil), options) ==
             {:ok, %{outcome: :clarification, session_ref: session_ref}}

    assert ChannelSetup.ensure_prompt(session, %{options | api: FailingAPI}) ==
             {:error, :slack_down}
  end

  test "every conversational setup choice has a recoverable natural-language path", %{
    options: options
  } do
    assert {:ok, joined} = ChannelSetup.handle_membership(membership(), options)

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "customize", nil), options)

    assert {:ok, %{outcome: :clarification}} =
             ChannelSetup.handle_message(
               normalized("U123", "participation choice is unclear", nil),
               options
             )

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "proactive", nil), options)

    assert {:ok, %{outcome: :clarification}} =
             ChannelSetup.handle_message(
               normalized("U123", "repository choice is unclear", nil),
               options
             )

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "infrastructure", nil), options)

    assert {:ok, %{outcome: :clarification}} =
             ChannelSetup.handle_message(
               normalized("U123", "alert choice is unclear", nil),
               options
             )

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "reply in place", nil), options)

    assert {:ok, %{outcome: :clarification}} =
             ChannelSetup.handle_message(
               normalized("U123", "audience choice is unclear", nil),
               options
             )

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "operators only", nil), options)

    assert {:ok, %{outcome: :clarification}} =
             ChannelSetup.handle_message(
               normalized("U123", "confirmation choice is unclear", nil),
               options
             )

    assert {:ok, %{outcome: :restarted}} =
             ChannelSetup.handle_message(normalized("U123", "start over", nil), options)

    assert {:ok, %{outcome: :saved, session_ref: session_ref}} =
             ChannelSetup.handle_message(normalized("U123", "be proactive", nil), options)

    assert session_ref == joined.session.id
    configuration = ChannelConfigurations.configuration("TD65C7CD93124", "C456")
    assert configuration.participation == :proactive
    assert configuration.alert_policy == :reply
  end

  test "safe defaults and cancel remain explicit conversational outcomes", %{options: options} do
    assert {:ok, joined} = ChannelSetup.handle_membership(membership(), options)

    assert {:ok, %{outcome: :saved}} =
             ChannelSetup.handle_message(normalized("U123", "use safe defaults", nil), options)

    assert {:ok, reconfigured_ref} =
             ChannelConfigurations.start_reconfiguration(
               %{
                 actor_ref: "U123",
                 channel_ref: "C456",
                 event_ref: "event:restart-after-defaults",
                 occurred_at: @now,
                 thread_ref: joined.session.root_message_ref,
                 workspace_ref: "TD65C7CD93124"
               },
               options.catalog
             )

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "customize", nil), options)

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "mentions", nil), options)

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "backend", nil), options)

    assert {:ok, %{outcome: :advanced}} =
             ChannelSetup.handle_message(normalized("U123", "offer an incident", nil), options)

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

    assert {:ok, %{outcome: :cancelled, session_ref: session_ref}} =
             ChannelSetup.handle_message(normalized("U123", "cancel", nil), options)

    assert session_ref == reconfigured_ref.session.id
  end

  test "invalid setup destinations and audience members never mutate configuration", %{
    options: options
  } do
    assert {:ok, _joined} = ChannelSetup.handle_membership(membership(), options)

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
  end

  test "unaddressed, denied, and malformed setup messages remain recoverable", %{
    options: options
  } do
    assert ChannelSetup.handle_message(normalized("U123", "customize", nil), options) ==
             :not_setup

    assert {:ok, _joined} = ChannelSetup.handle_membership(membership(), options)

    assert ChannelSetup.handle_message(
             normalized("U123", "customize", nil),
             %{options | directory: DeniedDirectory}
           ) == :not_setup

    malformed =
      put_in(
        normalized("U123", "customize", nil),
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
      workspace_ref: "TD65C7CD93124"
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
      workspace_ref: "TD65C7CD93124"
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
        workspace_ref: "TD65C7CD93124"
      })

    %{audience: audience, input: input, platform_thread_ref: thread_ref}
  end

  defp posts(options), do: Agent.get(options.client, & &1.posts)
end
