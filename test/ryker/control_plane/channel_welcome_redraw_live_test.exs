defmodule Ryker.ControlPlane.ChannelWelcomeRedrawLiveTest do
  @moduledoc """
  A channel's settings can be chosen in Slack (the welcome's Customize) or
  on the channel's page in Ryker. Until 2026-09-26 only the Slack-side save
  redrew the welcome message in the channel, so after a change on the web
  the card still said the channel worked in the old environment, with the
  old repositories, while the page and the work used the new one. Since
  2026-09-27 the page changes how Ryker takes part and what it does with
  alerts too, and each change redraws the welcome the same way.

  Slack here is the shared test workspace; the documents it receives are
  rendered with the real Slack renderer, so the test reads what the channel
  would show.
  """
  use Ryker.DataCase, async: false
  import Ryker.TestHelpers, only: [eventually: 1, eventually: 2]
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{Actions, Endpoint, Projection}
  alias Ryker.Fixtures.ChannelEnvironments
  alias Ryker.Slack.{ChannelConfigurations, ChannelSettings, ChannelSetup, MembershipTransition}
  alias Ryker.Slack.{Operators, Renderer}
  alias Ryker.Slack.Runtime, as: SlackRuntime
  alias Ryker.TestSupport.FakeSlackAPI

  @endpoint Endpoint
  @workspace "TD65C7CD93124"

  defmodule SlowAPI do
    @moduledoc false
    # Slack taking longer to answer than anyone should wait for.
    def update_message(agent, _channel, _message_ref, _document, _delivery_ref) do
      Agent.update(agent, &Map.put(&1, :asked, true))
      # credo:disable-for-next-line Ryker.Checks.TestNoProcessSleep
      Process.sleep(3_000)
      :ok
    end
  end

  defmodule Directory do
    @moduledoc false
    def user_allowed(_client, _user_ref, _workspace_ref), do: {:ok, true}
  end

  setup do
    agent = start_supervised!(FakeSlackAPI)
    running = start_supervised!({Agent, fn -> true end}, id: :slack_running)
    slow = start_supervised!({Agent, fn -> false end}, id: :slow_slack)
    tasks = start_supervised!(Task.Supervisor)
    production = ChannelEnvironments.environment!("production", %{repositories: ["payments"]})
    staging = ChannelEnvironments.environment!("staging")

    # What the running Slack runtime hands the welcome.
    slack = %{
      api: FakeSlackAPI,
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
      operators: chosen_operators(["U123"]),
      settings_overrides: fn workspace_ref, channel_ref ->
        ChannelSettings.effective(
          workspace_ref,
          "slack:#{workspace_ref}:#{channel_ref}",
          :mentions
        )
      end
    }

    # What the running Slack runtime does when the page asks for a redraw
    # (`Ryker.Slack.Runtime.redraw_welcome/3`): start it on a task of its own
    # and answer the page later, giving up on a Slack that takes too long.
    # Slack switched off has no running runtime to redraw the card with.
    actions =
      Map.put(Actions.callbacks(), :redraw_channel_welcome, fn workspace_ref, channel_ref ->
        slack = if Agent.get(slow, & &1), do: %{slack | api: SlowAPI}, else: slack

        if Agent.get(running, & &1) do
          ChannelSetup.redraw_welcome_async(
            workspace_ref,
            channel_ref,
            slack,
            self(),
            tasks,
            300
          )
        else
          {:error, :slack_not_running}
        end
      end)
      # What the running Slack runtime does when the page removes Ryker
      # (`Ryker.Slack.Runtime.leave_channel/2`).
      |> Map.put(:leave_channel, fn workspace_ref, channel_ref ->
        if Agent.get(running, & &1),
          do: ChannelSetup.leave(workspace_ref, channel_ref, slack),
          else: {:error, :slack_not_running}
      end)

    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.PubSub.Server,
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

    %{agent: agent, running: running, slow: slow}
  end

  # Andrew, 2026-09-28: "no way to remove a channel". Leave channel is the
  # last card on the channel's page; it asks first, Slack takes Ryker out,
  # and the page reads Disconnected at once.
  test "Ryker is removed from a channel on its page, after the question", %{agent: agent} do
    {:ok, view, _html} =
      live(build_conn() |> Map.put(:host, "localhost"), "/channels/#{@workspace}/C456")

    assert has_element?(view, "#leave-channel.kit-remove-card", "Leave channel")
    view |> element("#leave-channel button", "Leave channel") |> render_click()
    assert has_element?(view, "#confirm-leave-channel[role=alertdialog]", "Remove Ryker from")
    assert FakeSlackAPI.state(agent).left == []

    view |> element("#confirm-leave-channel button", "Leave channel") |> render_click()

    assert FakeSlackAPI.state(agent).left == ["C456"]
    assert has_element?(view, ".form-feedback-success", "Ryker left the channel.")
    assert has_element?(view, "header.page-header .state-word", "Disconnected")
    refute has_element?(view, "#leave-channel")
    refute has_element?(view, "#confirm-leave-channel")
  end

  test "with Slack switched off, removing Ryker says so and changes nothing", %{
    agent: agent,
    running: running
  } do
    Agent.update(running, fn _running -> false end)

    {:ok, view, _html} =
      live(build_conn() |> Map.put(:host, "localhost"), "/channels/#{@workspace}/C456")

    view |> element("#leave-channel button", "Leave channel") |> render_click()
    view |> element("#confirm-leave-channel button", "Leave channel") |> render_click()

    assert has_element?(view, ".form-feedback-error", "Slack is not connected")
    assert FakeSlackAPI.state(agent).left == []
    assert %{status: :joined} = ChannelConfigurations.membership(@workspace, "C456")
  end

  test "an environment chosen on the channel's page redraws its welcome in Slack", %{agent: agent} do
    {:ok, view, _html} =
      live(build_conn() |> Map.put(:host, "localhost"), "/channels/#{@workspace}/C456")

    view |> form("#channel-environment", environment: "staging") |> render_change()

    assert eventually(fn -> FakeSlackAPI.state(agent).updates != [] end),
           "the welcome in the channel was not redrawn"

    assert [%{channel: "C456", message_ref: message_ref, document: document}] =
             FakeSlackAPI.state(agent).updates

    assert message_ref ==
             ChannelConfigurations.configuration(@workspace, "C456").welcome_message_ref

    {:ok, %{"text" => fallback, "blocks" => blocks}} = Renderer.render(document)
    shown = Enum.map_join(blocks, "\n", &get_in(&1, ["text", "text"]))

    assert shown =~ "I work in the *Staging* environment here."
    refute shown =~ "Production"

    # Nobody in Slack pressed anything, so the card says where it changed.
    assert shown =~ ~r/\*Settings changed on this channel's page in Ryker at \d\d:\d\d UTC\*/
    assert fallback =~ "Settings changed on this channel's page in Ryker"

    assert has_element?(view, "#channel-environment-saved .kit-saved-mark", "Saved")
    refute has_element?(view, "#channel-environment-saved .kit-saved-note")
  end

  # The welcome says how Ryker takes part and what it does with alerts, so a
  # change to either on the page redraws it as an environment change does.
  test "how Ryker takes part and what it does with alerts, chosen on the page, reach the welcome",
       %{agent: agent} do
    {:ok, view, _html} =
      live(build_conn() |> Map.put(:host, "localhost"), "/channels/#{@workspace}/C456")

    view |> form("#channel-participation", participation: "proactive") |> render_change()
    assert eventually(fn -> length(FakeSlackAPI.state(agent).updates) == 1 end)

    view |> form("#channel-alerts", alert_policy: "automatic") |> render_change()
    assert eventually(fn -> length(FakeSlackAPI.state(agent).updates) == 2 end)

    shown =
      agent
      |> FakeSlackAPI.state()
      |> Map.fetch!(:updates)
      |> List.last()
      |> Map.fetch!(:document)
      |> Renderer.render()
      |> then(fn {:ok, %{"blocks" => blocks}} ->
        Enum.map_join(blocks, "\n", &get_in(&1, ["text", "text"]))
      end)

    assert shown =~ "join conversations when I can help"
    assert shown =~ "I'll automatically create an incident room"
  end

  test "a slow Slack never holds up the save, and the page says the card may be stale", context do
    Agent.update(context.slow, fn _fast -> true end)

    {:ok, view, _html} =
      live(build_conn() |> Map.put(:host, "localhost"), "/channels/#{@workspace}/C456")

    {elapsed, _html} =
      :timer.tc(
        fn -> view |> form("#channel-environment", environment: "staging") |> render_change() end,
        :millisecond
      )

    # The page waited for Slack's answer before it said anything (3 seconds
    # here, and as long as Slack took in production).
    assert elapsed < 1_000, "the save waited #{elapsed} ms for Slack"
    assert ChannelConfigurations.configuration(@workspace, "C456").environment_ref == "staging"

    assert has_element?(view, "#channel-environment-saved .kit-saved-mark", "Saved")

    # Ryker stops waiting on its own timeout, and the page says what that means.
    assert eventually(fn ->
             has_element?(
               view,
               "#channel-environment-saved .kit-saved-note",
               "Slack did not answer in time, so the welcome message may still show the old setting."
             )
           end)
  end

  test "a change the Slack card cannot show yet says so beside the saved choice", context do
    # The runtime answers at once when Slack has not started: there is no
    # runtime or task supervisor to redraw anything with.
    assert Application.get_env(:ryker, :slack) == nil

    assert SlackRuntime.redraw_welcome(@workspace, "C456", self()) ==
             {:error, :slack_not_running}

    Agent.update(context.running, fn _running -> false end)

    {:ok, view, _html} =
      live(build_conn() |> Map.put(:host, "localhost"), "/channels/#{@workspace}/C456")

    view |> form("#channel-environment", environment: "staging") |> render_change()

    assert ChannelConfigurations.configuration(@workspace, "C456").environment_ref == "staging"

    assert has_element?(
             view,
             "#channel-environment-saved .kit-saved-note",
             "Slack is not connected, so the welcome message in the channel still shows the old setting."
           )

    # Choosing what the channel already uses changes nothing to redraw.
    Agent.update(context.running, fn _running -> true end)
    view |> form("#channel-environment", environment: "staging") |> render_change()
    refute eventually(fn -> FakeSlackAPI.state(context.agent).updates != [] end, 100)
  end

  # The people chosen to manage Ryker, with the workspace's admins left out.
  defp chosen_operators(people) do
    Operators.new(
      chosen: people,
      workspace_admins: false,
      workspace_ref: @workspace
    )
  end
end
