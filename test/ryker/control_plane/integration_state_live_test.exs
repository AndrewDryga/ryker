defmodule Ryker.ControlPlane.IntegrationStateLiveTest do
  @moduledoc """
  QA, 2026-09-25, on one installation with verified Slack tokens and nobody
  chosen to manage Ryker: Integrations said "Finish connecting" beside a
  Disconnect button, Channels said "Slack is not connected. Connect it",
  Setup counted nothing done while its first step said "Slack is verified"
  and still asked for a Slack app, and Settings › Advanced said "Not
  configured" for Slack, GitHub and webhooks while the webhooks page listed a
  signing credential. Each page worked the state out on its own, so each told
  the operator something different about the same settings.

  These tests open every page that names an integration's state, for the same
  saved settings, and hold them to one word and one reason.
  """
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{
    Actions,
    ChannelsPage,
    Endpoint,
    Integrations,
    Projection,
    RunningSystem,
    SettingsPage,
    SettingsView
  }

  alias Ryker.Credentials
  alias Ryker.Settings

  @endpoint Endpoint
  @actor "control-plane:local"

  setup do
    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.ControlPlane.PubSub,
       live_view: [signing_salt: "integration-state-test"],
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

  test "Slack's tokens verified but Slack switched off read the same on every page" do
    verified_slack!()

    assert_same(
      :slack,
      "Finish connecting",
      "The tokens are verified, but Slack stays off until you choose who can manage Ryker."
    )

    # The step says what is left, not what is already done.
    {:ok, _view, html} = open("/setup")
    step = html |> LazyHTML.from_document() |> LazyHTML.query("ol.setup-steps > li:first-child")
    assert LazyHTML.query(step, "h3") |> text() == "Finish connecting Slack"
    refute text(step) =~ "A Slack app for Ryker"
    assert has_element?(elem(open("/setup"), 1), "#setup-progress-text", "0 of 6")
  end

  test "Slack switched on says the same thing on every page, running or not" do
    # A connection that is on but not running used to read "Setting up" or
    # "Not running" beside a reason written for Chat ("This page will update
    # when it is ready"), and nowhere but the Slack page said which.
    verified_slack!()

    {:ok, _snapshot} =
      Settings.save_slack(
        %{enabled: true, operators: ["U0123456789"]},
        Settings.fetch!().installation.revision,
        @actor
      )

    {:ok, view} = SettingsView.fetch()

    for {running, application, word, reason} <- [
          {:ready, :applied, "Connected", "Acme · @ryker · 1 person can manage Ryker"},
          {:connecting, :applied, "Connecting", "Ryker is opening its connection to Slack."},
          {:runtime_unavailable, :pending, "Starting", "Ryker is applying the saved settings."},
          {:runtime_unavailable, {:failed, :settings_not_applicable}, "Not running",
           "The newest settings could not be applied, so Slack is not running."},
          {:runtime_unavailable, :applied, "Not running",
           "because no worker policy for incident rooms is ready"},
          {:worker_unavailable, :applied, "Waiting for the worker",
           "the worker that runs Ryker's work is not ready"}
        ] do
      view = %{view | readiness: %{view.readiness | slack: %{state: running}}}
      view = %{view | application: application}

      for {surface, shown} <- slack_surfaces(view) do
        # A working connection is simply a done step on Setup; a stopped one
        # says why there too.
        if running == :ready and surface == :setup do
          assert shown =~ "Done: Slack · Acme as @ryker"
        else
          assert shown =~ word, "#{surface} says #{inspect(shown)}, not #{inspect(word)}"
          assert shown =~ reason, "#{surface} says #{inspect(shown)}, without #{reason}"
        end
      end
    end
  end

  test "an integration nothing was set up for reads the same on every page" do
    assert_same(
      :slack,
      "Not connected",
      "Ryker cannot read or reply in Slack until you connect it."
    )

    # Setup leads with Slack, so GitHub's step waits quietly, and Emisar's
    # panel is its own call to connect it; neither names a state there.
    assert_same(
      :github,
      "Not connected",
      "Ryker cannot read your code or open pull requests until you connect it.",
      except: "/setup"
    )

    assert_same(
      :emisar,
      "Not connected",
      "Without it, Ryker cannot act on anything that is running.",
      except: "/setup"
    )
  end

  test "a GitHub App whose saved key no longer works reads as needing repair on every page" do
    for kind <- [:github_private_key, :github_webhook] do
      {:ok, _} = Credentials.put(kind, "primary", "not-a-working-key-long-enough", @actor)
    end

    assert_same(:github, "Needs repair", "The saved App ID or private key no longer works.")
  end

  test "a signing credential without a webhook source reads as not set up, never not configured" do
    {:ok, _} = Credentials.put(:webhook, "grafana", String.duplicate("s", 32), @actor)
    {:ok, _} = Credentials.verify(:webhook, "grafana", :verified, @actor)

    assert_same(
      :webhooks,
      "Not set up",
      "A signing credential is ready. Add a webhook source so a sender can use it."
    )
  end

  test "a webhook source Ryker left out says which and why on every page" do
    # Until 2026-09-26 a source Ryker could not serve refused the whole
    # configuration, and nothing said which. Now it is left out of the running
    # routes and named with its reason (AssemblyTest); these pages must say
    # so, or the route would silently vanish.
    {:ok, _} =
      Settings.put_environment(
        %{ref: "production", display_name: "Production"},
        Settings.fetch!().installation.revision,
        @actor
      )

    {:ok, _} = Credentials.put(:webhook, "grafana", String.duplicate("s", 32), @actor)
    {:ok, _} = Credentials.verify(:webhook, "grafana", :verified, @actor)

    {:ok, _} =
      Settings.put_webhook_source(
        %{
          name: "grafana",
          adapter_kind: :grafana,
          auth_kind: :bearer,
          secret_name: "grafana",
          destination_transport: "slack",
          destination_conversation_ref: "slack:T0123456789:C0123456789",
          environment_ref: "production"
        },
        Settings.fetch!().installation.revision,
        @actor
      )

    # What the runtime published when it applied these settings.
    previous = Application.fetch_env(:ryker, :webhook_sources_left_out)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ryker, :webhook_sources_left_out, value)
        :error -> Application.delete_env(:ryker, :webhook_sources_left_out)
      end
    end)

    Application.put_env(:ryker, :webhook_sources_left_out, %{"grafana" => :slack_not_running})

    assert_same(
      :webhooks,
      "Not running",
      "grafana is not taking events: it posts to Slack, and Slack is not running."
    )

    # The source's own row says it too.
    {:ok, view, _html} = open("/integrations/webhooks")

    assert has_element?(
             view,
             "#settings-webhooks .entity-row .state-word[data-tone=bad]",
             "Not running"
           )

    assert has_element?(
             view,
             "#settings-webhooks .entity-row .entity-text",
             "Not taking events: it posts to Slack, and Slack is not running."
           )
  end

  # Every page that names this integration's state, each read where that page
  # shows it: the word, and the reason beside it.
  defp assert_same(key, word, reason, options \\ []) do
    for {path, selector} <- surfaces(key), path != options[:except] do
      {:ok, _view, html} = open(path)
      found = html |> LazyHTML.from_document() |> LazyHTML.query(selector)
      refute Enum.empty?(found), "#{path} shows nothing for #{key} at #{selector}"

      shown = text(found)
      assert shown =~ word, "#{path} says #{inspect(shown)}, not #{inspect(word)}"
      assert shown =~ reason, "#{path} says #{inspect(shown)}, without #{inspect(reason)}"
    end

    # The page's help explains the same word.
    {:ok, _view, html} = open(page(key))
    help = html |> LazyHTML.from_document() |> LazyHTML.query("aside.page-help") |> text()
    assert help =~ word <> ":", "The help for #{page(key)} does not explain #{inspect(word)}"
  end

  defp surfaces(:slack),
    do: [
      {"/integrations", "#integration-slack"},
      {"/integrations/slack", ".settings-connection"},
      {"/channels", "#slack-status"},
      {"/setup", "ol.setup-steps > li:first-child"},
      {"/settings/advanced", "#running-slack"}
    ]

  defp surfaces(:github),
    do: [
      {"/integrations", "#integration-github"},
      {"/integrations/github", ".settings-connection"},
      {"/repositories", "#github-status"},
      {"/setup", "ol.setup-steps > li:nth-child(2)"},
      {"/settings/advanced", "#running-github"}
    ]

  defp surfaces(:emisar),
    do: [
      {"/integrations", "#integration-emisar"},
      {"/integrations/emisar", ".settings-connection"},
      {"/setup", ".setup-emisar"},
      {"/settings/advanced", "#running-emisar"}
    ]

  defp surfaces(:webhooks),
    do: [
      {"/integrations", "#integration-webhooks"},
      {"/integrations/webhooks", ".settings-connection"},
      {"/settings/advanced", "#running-webhooks"}
    ]

  defp page(key), do: "/integrations/#{key}"

  # Slack's state on each page, rendered from one settings view.
  defp slack_surfaces(view) do
    page = fn section ->
      render_component(&SettingsPage.render/1,
        view: {:ok, view},
        commands: %{},
        section: section
      )
      |> LazyHTML.from_fragment()
    end

    channels =
      render_component(&ChannelsPage.slack_status/1, settings: {:ok, view})
      |> LazyHTML.from_fragment()

    running =
      %{rows: [], grants: [], source: "durable settings", integrations: Integrations.all(view)}
      |> RunningSystem.html()
      |> LazyHTML.from_fragment()

    [
      overview: page.(:integrations) |> LazyHTML.query("#integration-slack"),
      slack: page.(:slack) |> LazyHTML.query(".settings-connection"),
      channels: LazyHTML.query(channels, "#slack-status"),
      setup: page.(:setup) |> LazyHTML.query("ol.setup-steps > li:first-child"),
      advanced: LazyHTML.query(running, "#running-slack")
    ]
    |> Enum.map(fn {surface, nodes} -> {surface, text(nodes)} end)
  end

  defp open(path), do: live(build_conn() |> Map.put(:host, "localhost"), path)

  # Text as a reader sees it: HTML collapses the line breaks of the template.
  defp text(nodes), do: nodes |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  # Verified Slack tokens and identity, as Connect leaves them before anyone
  # has chosen who manages Ryker: Slack is saved as switched off.
  defp verified_slack! do
    snapshot = Settings.fetch!()

    {:ok, _snapshot} =
      Settings.save_slack(
        %{
          enabled: false,
          workspace_ref: "T0123456789",
          workspace_name: "Acme",
          bot_ref: "A0123456789",
          bot_user_ref: "U0123456789",
          bot_name: "ryker"
        },
        snapshot.installation.revision,
        @actor
      )

    for kind <- [:slack_app, :slack_bot] do
      {:ok, _} = Credentials.put(kind, "primary", "xoxb-test-token-long-enough", @actor)
      {:ok, _} = Credentials.verify(kind, "primary", :verified, @actor)
    end
  end
end
