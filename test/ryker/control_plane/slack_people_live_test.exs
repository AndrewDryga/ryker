defmodule Ryker.ControlPlane.SlackPeopleLiveTest do
  @moduledoc """
  How a Slack person reads in the control plane: their name, linked to their
  Slack profile, never a raw ID, and the name arrives without a reload.

  On 2026-09-26, right after Andrew chose himself on Integrations › Slack,
  "Who can manage Ryker" read "Slack user U0BHTNFCW6S"; only a later reload
  read "@Andrew". The page asked the name cache while it was drawn, the cache
  had not asked Slack yet, and nothing drew the page again once it had.
  """
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Ryker.TestHelpers, only: [eventually: 1]

  alias Ryker.ControlPlane.{Actions, Endpoint, Projection}
  alias Ryker.Credentials
  alias Ryker.Settings
  alias Ryker.Slack.Names

  @endpoint Endpoint
  @actor "control-plane:local"
  @workspace "T0123456789"
  @andrew "U0BHTNFCW6S"
  @profile "https://acme.slack.com/team/U0BHTNFCW6S"
  @managers "section[aria-label='Who can manage Ryker']"
  @listed "#{@managers} [role=listitem]"

  setup do
    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.PubSub,
       live_view: [signing_salt: "slack-people-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: Actions.callbacks(),
         projection: Projection.callbacks(),
         observability: %{},
         csrf_secret: String.duplicate("s", 32)
       }}
    )

    {:ok, _snapshot} = Settings.initialize(@actor)
    :ok
  end

  test "who can manage Ryker names each person, linked to Slack, and the name arrives without a reload" do
    names!(%{@andrew => "Andrew"})
    slack_on!([@andrew])

    {:ok, view, _html} = open("/integrations/slack")

    # Before Slack has answered: a person, linked, never the raw ID.
    assert has_element?(view, "#{@managers} a[href='#{@profile}']", "Slack user")
    refute managers_text(view) =~ @andrew

    # Slack answers in the background, one name at a time, and the open page
    # shows the name.
    assert eventually(fn ->
             :ok = GenServer.call(Names, :refresh)
             has_element?(view, "#{@managers} a[href='#{@profile}']", "@Andrew")
           end)

    refute managers_text(view) =~ @andrew
  end

  test "who can manage Ryker says workspace admins and owners can, and the switch turns that off" do
    names!(%{@andrew => "Andrew"})
    slack_on!([@andrew])
    Names.name(@workspace, @andrew)
    :ok = GenServer.call(Names, :refresh)

    {:ok, view, _html} = open("/integrations/slack")

    assert has_element?(view, @listed, "Workspace admins and owners")
    assert has_element?(view, "#{@listed} a[href='#{@profile}']", "@Andrew")

    switch = "#{@managers} input[type=checkbox][name=workspace_admins_manage]"
    assert has_element?(view, "#{switch}[checked]")

    view
    |> form("#{@managers} form#settings-slack-admins-form", %{
      "workspace_admins_manage" => "false"
    })
    |> render_submit()

    refute Settings.fetch!().slack.workspace_admins_manage
    assert eventually(fn -> not has_element?(view, @listed, "Workspace admins and owners") end)
    assert has_element?(view, "#{@listed} a[href='#{@profile}']", "@Andrew")
    refute has_element?(view, "#{switch}[checked]")
  end

  test "with nobody chosen, workspace admins and owners are who can manage Ryker" do
    names!(%{})
    slack_on!([])

    {:ok, view, _html} = open("/integrations/slack")

    assert has_element?(view, @listed, "Workspace admins and owners")
    refute managers_text(view) =~ "Nobody yet"
  end

  # The name cache is handed the workspace, its address and a lookup; here the
  # lookup is the directory a test names.
  defp names!(directory) do
    start_supervised!(
      {Names,
       workspace: @workspace,
       workspace_url: "https://acme.slack.com",
       fetch: fn ref -> {:ok, Map.get(directory, ref)} end}
    )
  end

  defp slack_on!(operators) do
    {:ok, _snapshot} =
      Settings.save_slack(
        %{
          enabled: true,
          workspace_ref: @workspace,
          workspace_url: "https://acme.slack.com",
          workspace_name: "Acme",
          bot_ref: "A0123456789",
          bot_user_ref: "U0123456789",
          bot_name: "ryker",
          operators: operators
        },
        Settings.fetch!().installation.revision,
        @actor
      )

    for kind <- [:slack_app, :slack_bot] do
      {:ok, _} = Credentials.put(kind, "primary", "xoxb-test-token-long-enough", @actor)
      {:ok, _} = Credentials.verify(kind, "primary", :verified, @actor)
    end
  end

  defp managers_text(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(@managers)
    |> LazyHTML.text()
  end

  defp open(path), do: live(build_conn() |> Map.put(:host, "localhost"), path)
end
