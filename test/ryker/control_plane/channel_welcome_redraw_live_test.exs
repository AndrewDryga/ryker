defmodule Ryker.ControlPlane.ChannelWelcomeRedrawLiveTest do
  @moduledoc """
  A channel's environment can be chosen in Slack (the welcome's Customize)
  or on the channel's page in Ryker. Until 2026-09-26 only the Slack-side
  save redrew the welcome message in the channel, so after a change on the
  web the card still said the channel worked in the old environment, with
  the old repositories, while the page and the work used the new one.

  The Slack API here is a recording double; the documents it receives are
  rendered with the real Slack renderer, so the test reads what the channel
  would show.
  """
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Actions, Endpoint, Projection}
  alias Ryker.Fixtures.ChannelEnvironments

  alias Ryker.Slack.{
    ChannelConfigurations,
    ChannelSettings,
    ChannelSetup,
    MembershipTransition,
    Renderer
  }

  @endpoint Endpoint
  @workspace "TD65C7CD93124"

  defmodule API do
    @moduledoc false
    def find_message(agent, channel, thread, delivery_ref) do
      Agent.get(agent, fn state ->
        case Map.get(state.deliveries, {channel, thread, delivery_ref}) do
          nil -> :not_found
          message_ref -> {:ok, message_ref}
        end
      end)
    end

    def post_message(agent, channel, thread, _document, delivery_ref) do
      Agent.get_and_update(agent, fn state ->
        message_ref = "#{map_size(state.deliveries) + 1}.000001"

        {{:ok, message_ref},
         %{
           state
           | deliveries: Map.put(state.deliveries, {channel, thread, delivery_ref}, message_ref)
         }}
      end)
    end

    def update_message(agent, channel, message_ref, document, _delivery_ref) do
      Agent.update(agent, fn state ->
        %{state | updates: state.updates ++ [{channel, message_ref, document}]}
      end)
    end
  end

  defmodule Directory do
    @moduledoc false
    def user_allowed(_client, _user_ref, _workspace_ref), do: {:ok, true}
  end

  setup do
    agent = start_supervised!({Agent, fn -> %{deliveries: %{}, updates: []} end})
    running = start_supervised!({Agent, fn -> true end}, id: :slack_running)
    production = ChannelEnvironments.environment!("production", %{repositories: ["payments"]})
    staging = ChannelEnvironments.environment!("staging")

    # What the running Slack runtime hands the welcome.
    slack = %{
      api: API,
      bot_user_ref: "UBOT",
      catalog: %{
        default_environment: "production",
        environments: [
          ChannelEnvironments.choice(production),
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

    # Slack switched off has no running runtime to redraw the card with.
    actions =
      Map.put(Actions.callbacks(), :redraw_channel_welcome, fn workspace_ref, channel_ref ->
        if Agent.get(running, & &1),
          do: ChannelSetup.redraw_welcome(workspace_ref, channel_ref, slack),
          else: {:error, :slack_not_running}
      end)

    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.ControlPlane.PubSub,
       live_view: [signing_salt: "channel-welcome-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: actions,
         csrf_secret: String.duplicate("s", 32),
         observability: %{},
         projection: Projection.callbacks()
       }}
    )

    # Ryker joins the channel and posts its welcome, in the default environment.
    {:ok, _joined} =
      ChannelSetup.handle_membership(
        %MembershipTransition{
          actor_ref: "U123",
          channel_ref: "C456",
          event_ref: "event:join",
          kind: :joined,
          occurred_at: DateTime.utc_now(),
          workspace_ref: @workspace
        },
        slack
      )

    %{agent: agent, running: running}
  end

  test "an environment chosen on the channel's page redraws its welcome in Slack", %{agent: agent} do
    {:ok, view, _html} =
      live(build_conn() |> Map.put(:host, "localhost"), "/channels/#{@workspace}/C456")

    view |> form("#channel-environment", environment: "staging") |> render_submit()

    assert [{"C456", message_ref, document}] = Agent.get(agent, & &1.updates),
           "the welcome in the channel was not redrawn"

    assert message_ref ==
             ChannelConfigurations.configuration(@workspace, "C456").welcome_message_ref

    {:ok, %{"text" => fallback, "blocks" => blocks}} = Renderer.render(document)
    shown = Enum.map_join(blocks, "\n", &get_in(&1, ["text", "text"]))

    assert shown =~ "I work in the *Staging* environment here."
    refute shown =~ "Production"

    # Nobody in Slack pressed anything, so the card says where it changed.
    assert shown =~ ~r/\*Settings changed on this channel's page in Ryker at \d\d:\d\d UTC\*/
    assert fallback =~ "Settings changed on this channel's page in Ryker"

    assert has_element?(
             view,
             "#channel-environment-notice",
             "Saved. This channel works in Staging now."
           )
  end

  test "a change the Slack card cannot show yet says so beside the saved choice", context do
    Agent.update(context.running, fn _running -> false end)

    {:ok, view, _html} =
      live(build_conn() |> Map.put(:host, "localhost"), "/channels/#{@workspace}/C456")

    view |> form("#channel-environment", environment: "staging") |> render_submit()

    assert ChannelConfigurations.configuration(@workspace, "C456").environment_ref == "staging"

    assert has_element?(
             view,
             "#channel-environment-notice",
             "Saved. This channel works in Staging now. Slack is not connected, so Ryker's " <>
               "welcome message in the channel still shows the old environment."
           )

    # Choosing what the channel already uses changes nothing to redraw.
    Agent.update(context.running, fn _running -> true end)
    view |> form("#channel-environment", environment: "staging") |> render_submit()
    assert Agent.get(context.agent, & &1.updates) == []
  end
end
