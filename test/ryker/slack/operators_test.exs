defmodule Ryker.Slack.OperatorsTest do
  # The admin answers are cached in one named process, and the settings check
  # reads the saved Slack row, so these run alone.
  use Ryker.DataCase, async: false
  alias Ryker.Settings
  alias Ryker.Slack.{Client, Command, CommandHandler, Operators, WorkspaceAdmins}

  @workspace "T0123456789"
  @chosen "U1111111111"
  @admin "U2222222222"
  @owner "U3333333333"
  @member "U4444444444"
  @unanswered "U5555555555"
  @actor "control-plane:local"

  # Answers users.info the way Slack does, from the profiles a test names, and
  # keeps who it was asked about. A person it has no profile for is a Slack
  # that did not answer.
  defmodule SlackPeople do
    def start(profiles), do: Agent.start_link(fn -> %{asked: [], profiles: profiles} end)

    def request(agent, :get, "/users.info?user=" <> user_ref, nil, _headers) do
      Agent.get_and_update(agent, fn state ->
        {reply(Map.get(state.profiles, user_ref)), %{state | asked: state.asked ++ [user_ref]}}
      end)
    end

    def asked(agent), do: Agent.get(agent, & &1.asked)

    defp reply(nil), do: {:error, :timeout}

    defp reply(profile),
      do: {:ok, %{body: %{"ok" => true, "user" => profile}, headers: [], status: 200}}
  end

  # Until 2026-09-26 only the people chosen on Integrations › Slack could
  # manage Ryker from Slack. Everyone else, the workspace's own admins
  # included, got "Only a configured Ryker operator can use /ryker". Andrew
  # asked that admins and owners manage Ryker by default, with a switch to turn
  # that off. Who is an admin is Slack's answer about that person, asked when
  # it matters and never assumed: a lookup that fails lets nobody in.
  setup do
    {:ok, slack} =
      SlackPeople.start(%{
        @chosen => person(@chosen),
        @admin => person(@admin, %{"is_admin" => true}),
        @owner => person(@owner, %{"is_owner" => true, "is_primary_owner" => true}),
        @member => person(@member)
      })

    {:ok, client} = Client.new(http: slack, requester: SlackPeople)

    start_supervised!(
      {WorkspaceAdmins,
       workspace: @workspace, lookup: &Client.workspace_admin(client, &1, @workspace)}
    )

    %{client: client, slack: slack}
  end

  test "a workspace admin who was not chosen can manage Ryker from Slack", %{client: client} do
    assert changed?(@admin, client, true)
  end

  test "a workspace owner who was not chosen can manage Ryker from Slack", %{client: client} do
    assert changed?(@owner, client, true)
  end

  test "a member who is neither chosen nor an admin cannot manage Ryker from Slack",
       %{client: client} do
    refute changed?(@member, client, true)
  end

  test "a person Slack gives no answer about cannot manage Ryker from Slack",
       %{client: client, slack: slack} do
    refute changed?(@unanswered, client, true)
    assert @unanswered in SlackPeople.asked(slack)

    # A failure is not remembered as an answer: the next attempt asks again.
    refute changed?(@unanswered, client, true)
    assert Enum.count(SlackPeople.asked(slack), &(&1 == @unanswered)) == 2
  end

  test "with admins turned off only the chosen people can manage Ryker from Slack",
       %{client: client, slack: slack} do
    refute changed?(@admin, client, false)
    refute changed?(@owner, client, false)
    assert changed?(@chosen, client, false)

    # Nobody was asked whether they are an admin; only whether each is a member.
    assert SlackPeople.asked(slack) == [@chosen]
  end

  test "an admin's answer is remembered briefly instead of asked for every check",
       %{client: client, slack: slack} do
    assert changed?(@admin, client, true)
    assert changed?(@admin, client, true)

    # One lookup for being an admin, then one membership check per command.
    assert Enum.count(SlackPeople.asked(slack), &(&1 == @admin)) == 3
  end

  # The installation-wide default is written through the saved settings,
  # which check the Slack person again against what is saved there, not
  # against what the command handler was told.
  test "an admin moves the installation default from Slack only while admins can manage Ryker" do
    {:ok, saved} = Settings.initialize(@actor)

    {:ok, saved} =
      Settings.save_slack(
        %{
          enabled: true,
          workspace_ref: @workspace,
          bot_ref: "A0123456789",
          bot_user_ref: "U0123456789",
          operators: [@chosen]
        },
        saved.installation.revision,
        @actor
      )

    assert saved.slack.workspace_admins_manage

    assert {:ok, moved} = Settings.save_default_participation(:proactive, "slack:user:#{@admin}")
    assert moved.slack.default_participation == :proactive

    assert Settings.save_default_participation(:shadow, "slack:user:#{@member}") ==
             {:error, :settings_forbidden}

    assert Settings.save_default_participation(:shadow, "slack:user:#{@unanswered}") ==
             {:error, :settings_forbidden}

    {:ok, off} =
      Settings.save_slack(%{workspace_admins_manage: false}, moved.installation.revision, @actor)

    assert Settings.save_default_participation(:shadow, "slack:user:#{@admin}") ==
             {:error, :settings_forbidden}

    assert {:ok, chosen} = Settings.save_default_participation(:shadow, "slack:user:#{@chosen}")
    assert chosen.slack.default_participation == :shadow
    assert chosen.installation.revision > off.installation.revision
  end

  # Whether `/ryker proactive on` from this person changed the channel.
  defp changed?(actor_ref, client, workspace_admins) do
    operators =
      Operators.new(
        chosen: [@chosen],
        workspace_admins: workspace_admins,
        workspace_ref: @workspace
      )

    observer = self()

    options = %{
      change_setting: fn change ->
        send(observer, {:setting_changed, change.actor_ref})
        {:ok, %{status: :updated}}
      end,
      client: client,
      directory: Client,
      effective_settings: fn _workspace_ref, _conversation_ref ->
        %{
          proactive: %{source: :channel, value: true},
          shadow: %{source: :installation, value: false}
        }
      end,
      operators: operators
    }

    command = %Command{
      actor_ref: actor_ref,
      channel_ref: "C0123456789",
      event_ref: "event:#{System.unique_integer([:positive])}",
      occurred_at: ~U[2026-09-26 12:00:00.000000Z],
      text: "proactive on",
      workspace_ref: @workspace
    }

    assert {:ok, response} = CommandHandler.handle(command, options)

    receive do
      {:setting_changed, ^actor_ref} ->
        assert response["text"] =~ "Proactive: on"
        true
    after
      0 ->
        assert response["text"] =~ "configured Ryker operator"
        false
    end
  end

  defp person(user_ref, flags \\ %{}) do
    Map.merge(
      %{
        "deleted" => false,
        "id" => user_ref,
        "is_admin" => false,
        "is_bot" => false,
        "is_owner" => false,
        "is_restricted" => false,
        "is_ultra_restricted" => false,
        "team_id" => @workspace
      },
      flags
    )
  end
end
