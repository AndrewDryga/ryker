defmodule Ryker.ControlPlane.SettingsLiveTest do
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Actions, Endpoint, Projection, SettingsPage, SettingsView, SetupPage}
  alias Ryker.Credentials
  alias Ryker.Settings
  alias Ryker.Settings.{Installation, PricingRate}
  alias Ryker.Slack.{ChannelConfigurationChangeset, ChannelConfigurations}

  @endpoint Endpoint
  @actor "control-plane:local"
  @day 86_400

  setup do
    unavailable = start_supervised!({Agent, fn -> false end})

    projection =
      Map.update!(Projection.callbacks(), :settings, fn read ->
        fn ->
          if Agent.get(unavailable, & &1), do: {:error, :settings_unavailable}, else: read.()
        end
      end)

    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.ControlPlane.PubSub,
       live_view: [signing_salt: "settings-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: Actions.callbacks(),
         projection: projection,
         observability: %{},
         csrf_secret: String.duplicate("s", 32)
       }}
    )

    %{unavailable: unavailable}
  end

  test "a database with no product settings offers setup instead of editors" do
    {:ok, view, html} = open()
    assert html =~ "Start setup"
    assert html =~ "Ryker has no settings yet"
    refute has_element?(view, "#settings-slack-form")

    view |> element("button[phx-click=initialize-settings]") |> render_click()

    assert has_element?(view, "ol.setup-steps li[aria-current=step] h3", "Connect Slack")

    assert has_element?(
             view,
             "li[aria-current=step] a[href='/integrations/slack']",
             "Connect Slack"
           )

    assert {:ok, %{installation: %{revision: 1}}} = Settings.fetch()
  end

  test "each settings page is titled with its sidebar name and the running system stays folded",
       context do
    for {prepare, path, title} <- [
          {fn -> :ok end, "/setup", "Set up Ryker"},
          {fn -> initialize!() end, "/setup", "Set up Ryker"},
          {fn -> :ok end, "/integrations", "Integrations"},
          {fn -> :ok end, "/integrations/slack", "Slack"},
          {fn -> :ok end, "/integrations/github", "GitHub"},
          {fn -> :ok end, "/integrations/emisar", "Emisar"},
          {fn -> :ok end, "/integrations/webhooks", "Webhooks"},
          {fn -> :ok end, "/settings/models", "Models"},
          {fn -> :ok end, "/settings/retention", "Data retention"},
          {fn -> :ok end, "/settings/prices", "Model prices"},
          {fn -> :ok end, "/settings/advanced", "Advanced"}
        ] do
      prepare.()
      {:ok, _view, html} = open(path)
      document = LazyHTML.from_document(html)
      headings = LazyHTML.query(document, "main h1")
      assert Enum.count(headings) == 1, title
      assert LazyHTML.text(headings) == title
      assert LazyHTML.query(document, "title") |> LazyHTML.text() == "#{title} · Ryker"

      assert LazyHTML.query(document, "main header.page-header > .page-heading > h1")
             |> Enum.count() == 1

      matching_headings =
        document
        |> LazyHTML.query("main h1, main h2")
        |> Enum.count(&(LazyHTML.text(&1) == title))

      assert matching_headings == 1, "#{path} repeats the page title inside its content"
    end

    document = open("/settings/advanced") |> elem(2) |> LazyHTML.from_document()
    evidence = LazyHTML.query(document, "main details.system-evidence")
    assert Enum.count(evidence) == 1
    assert LazyHTML.attribute(evidence, "open") == []
    assert Enum.count(LazyHTML.query(document, "main .configuration-evidence")) == 1

    assert Enum.empty?(
             LazyHTML.query(
               document,
               "main .configuration-evidence form, main .configuration-evidence button"
             )
           )

    Agent.update(context.unavailable, fn _ -> true end)
    {:ok, _view, html} = open()
    assert html =~ "Settings unavailable"
    unavailable = LazyHTML.from_document(html)
    assert LazyHTML.query(unavailable, "main h1") |> LazyHTML.text() == "Settings unavailable"
  end

  test "an unconnected integration says so, and GitHub access is derived from the repository" do
    initialize!()

    {:ok, connections, html} = open("/integrations/github")
    refute has_element?(connections, "input[name='connection[operator_login]']")
    assert has_element?(connections, ".github-connection-form fieldset", "GitHub App")
    refute html =~ "GitHub operator"

    for {path, title} <- [
          {"/integrations/slack", "Slack"},
          {"/integrations/github", "GitHub"},
          {"/integrations/emisar", "Emisar"}
        ] do
      {:ok, page, _html} = open(path)
      assert has_element?(page, "main h1", title)

      assert has_element?(
               page,
               ".settings-connection .state-word[data-tone=off]",
               "Not connected"
             )
    end

    {:ok, emisar, _html} = open("/integrations/emisar")
    assert has_element?(emisar, "form[phx-submit=connect-emisar]", "Connect account")
    refute has_element?(emisar, "details form[phx-submit=connect-emisar]")
    refute has_element?(emisar, "input[name='connection[ref]']")
    refute has_element?(emisar, "input[name='connection[display_name]']")

    assert get(build_conn() |> Map.put(:host, "localhost"), "/settings/connections").status == 404

    {:ok, repositories, _html} = open("/repositories")
    assert has_element?(repositories, "a[href='/integrations/github']", "Connect GitHub")
  end

  test "the old settings addresses are gone, not redirected" do
    # Integrations moved out of Settings on 2026-09-24 and the old overview
    # became /setup. A pre-v1 move is a clean cut: no alias answers the old
    # addresses, so a stale link fails loudly instead of landing somewhere else.
    initialize!()

    for path <- ~w(/settings /settings/slack /settings/github /settings/emisar /settings/webhooks) do
      assert get(build_conn() |> Map.put(:host, "localhost"), path).status == 404, path
    end

    for path <- ~w(/setup /integrations /integrations/slack /settings/models /settings/advanced) do
      assert {:ok, _view, _html} = open(path)
    end
  end

  test "the sidebar leads back into setup until every required step is done" do
    {:ok, view, _html} = open("/integrations")
    assert has_element?(view, "a.setup-shortcut[href='/setup']", "0 of 6 steps done")
    assert has_element?(view, "a.mobile-setup-shortcut[href='/setup']", "Finish setup")

    initialize!()
    {:ok, view, _html} = open("/setup")

    assert has_element?(
             view,
             "a.setup-shortcut[href='/setup'][aria-current=page]",
             "Finish setup"
           )

    assert SettingsView.setup_progress() == %{done: 0, total: 6}
  end

  test "setup opens one step at a time and counts what is done" do
    initialize!()
    {:ok, view, _html} = open("/setup")

    assert has_element?(view, "#setup-progress-text", "0 of 6")

    assert has_element?(
             view,
             "ol.setup-steps > li:first-child[aria-current=step]",
             "Connect Slack"
           )

    # One step at a time: only the open step has a button.
    actions =
      render(view) |> LazyHTML.from_fragment() |> LazyHTML.query("ol.setup-steps .ui-button")

    assert Enum.count(actions) == 1
    assert has_element?(view, "ol.setup-steps > li[data-state=later]", "Connect GitHub")
    assert has_element?(view, "#connect-emisar a.ui-button.primary", "Connect Emisar")
  end

  test "Setup's channel step is done once a joined channel has an environment" do
    # Channels choose an environment now, not a repository. A channel Ryker
    # joined before any environment existed has none, and its work runs
    # without code or Emisar; the step stays open until one is chosen, and a
    # channel Ryker has left proves nothing about where its work runs.
    snapshot = initialize!()

    {:ok, _snapshot} =
      Settings.put_environment(
        %{ref: "production", display_name: "Production", repositories: []},
        snapshot.installation.revision,
        @actor
      )

    joined!("CINFRA", nil)
    left!("CGONE", "production")

    {:ok, view} = SettingsView.fetch()
    assert view.setup.steps.invited
    refute view.setup.steps.channel_environment
    assert view.setup.channel.channel_ref == "CINFRA"

    # The step leads to the channel's page, where the environment is chosen.
    step = Enum.find(SetupPage.steps(view), &(&1.key == :channel_environment))
    assert step.title == "Choose the channel's environment"
    assert step.action == %{label: "Choose an environment", href: "/channels/T0123456789/CINFRA"}

    {:ok, live, _html} = open("/setup")
    assert has_element?(live, "li[data-state=later] h3", "Choose the channel's environment")

    assert {:ok, _configuration} =
             ChannelConfigurations.select_environment(
               "T0123456789",
               "CINFRA",
               "production",
               @actor
             )

    {:ok, view} = SettingsView.fetch()
    assert view.setup.steps.channel_environment
    assert view.setup.configured_channels == 1

    {:ok, live, _html} = open("/setup")

    assert has_element?(
             live,
             "li[data-state=done] .setup-step-line",
             "Channel environment"
           )

    assert has_element?(live, "li[data-state=done] .setup-step-line", "works in Production")
  end

  test "the integrations overview reads as the state of each connection, not a grid of cards" do
    # The complete overview used to replace the checklist with eight framed
    # cards that said nothing about whether anything was working.
    snapshot = initialize!()

    {:ok, _snapshot} =
      Settings.put_repository(
        %{ref: "payments", display_name: "Payments"},
        snapshot.installation.revision,
        @actor
      )

    {:ok, view} = SettingsView.fetch()

    slack = %{view.snapshot.slack | enabled: true, workspace_name: "Acme", bot_name: "ryker"}

    view = %{
      view
      | github_connection: :ready,
        snapshot: %{view.snapshot | slack: slack},
        credentials:
          for(kind <- [:slack_app, :slack_bot], do: %{kind: kind, verification_status: :verified}),
        readiness: %{view.readiness | slack: %{state: :ready, title: "", detail: ""}}
    }

    document =
      render_component(&SettingsPage.render/1,
        view: {:ok, view},
        commands: %{},
        section: :integrations
      )
      |> LazyHTML.from_fragment()

    assert Enum.empty?(LazyHTML.query(document, ".settings-directory, .setup-steps"))

    connections = LazyHTML.query(document, ".integrations-list .entity-row")

    assert connections |> LazyHTML.query(".entity-name a") |> LazyHTML.attribute("href") ==
             ~w(/integrations/slack /integrations/github /integrations/emisar /integrations/webhooks)

    slack_row = LazyHTML.query(document, "#integration-slack")

    assert LazyHTML.query(slack_row, ".state-word[data-tone=on]") |> LazyHTML.text() ==
             "Connected"

    assert LazyHTML.text(slack_row) =~ "Acme"
  end

  test "an unreadable stored GitHub key blocks discovery and offers repair" do
    snapshot = initialize!()

    assert {:ok, _snapshot} =
             Settings.save_github(
               %{enabled: true, app_id: 1_234},
               snapshot.installation.revision,
               @actor
             )

    assert {:ok, _} =
             Credentials.put(
               :github_private_key,
               "primary",
               "not-a-private-key-long-enough",
               @actor
             )

    assert {:ok, _} =
             Credentials.verify(:github_private_key, "primary", :verified, @actor)

    assert {:ok, _} =
             Credentials.put(
               :github_webhook,
               "primary",
               "test-webhook-secret-long-enough",
               @actor
             )

    assert {:ok, _} = Credentials.verify(:github_webhook, "primary", :verified, @actor)

    {:ok, repositories, _html} = open("/repositories")
    refute has_element?(repositories, "button[phx-click=discover-github-repositories]")

    assert has_element?(
             repositories,
             "a[href='/integrations/github']",
             "Repair GitHub connection"
           )

    {:ok, github, _html} = open("/integrations/github")
    assert has_element?(github, "h2", "Repair GitHub connection")
    assert has_element?(github, ".settings-connection .state-word[data-tone=bad]", "Needs repair")
    assert has_element?(github, ".settings-connection a[href='#github-app']", "Repair")
    refute has_element?(github, "button[phx-value-action=disconnect-github]")
  end

  test "each Emisar account says which environments use it, and pauses and resumes new work" do
    # Accounts used to be bound to repositories and work types through routes
    # set up on this page. An environment names its account now, so the
    # account's row says which environments send it their approvals, and the
    # environments that send none are counted with the way to fix them.
    snapshot = initialize!()

    {:ok, snapshot} =
      Settings.put_emisar_connection(
        %{
          ref: "production",
          display_name: "Production approvals",
          rpc_url: "https://emisar.example/api/mcp/rpc",
          account_ref: "account-production",
          account_label: "Production",
          enabled_for_new_work: false,
          monitoring_enabled: true,
          verified_at: ~U[2026-09-19 12:00:00.000000Z]
        },
        snapshot.installation.revision,
        @actor
      )

    for {ref, name, account} <- [
          {"production", "Production", "production"},
          {"staging", "Staging", "production"},
          {"ops", "Ops chat", nil}
        ] do
      {:ok, _snapshot} =
        Settings.put_environment(
          %{ref: ref, display_name: name, repositories: [], emisar_connection_ref: account},
          Settings.fetch!().installation.revision,
          @actor
        )
    end

    {:ok, view, _html} = open("/integrations/emisar")

    refute has_element?(view, "select[name='binding[scope]']")
    refute render(view) =~ "approval route"
    assert has_element?(view, ".entity-row .entity-meta", "Used by Production and Staging")

    assert has_element?(
             view,
             ".settings-connection a[href='/environments']",
             "1 environment without an Emisar account"
           )

    assert has_element?(view, ".entity-row .state-word[data-tone=off]", "Paused")
    assert has_element?(view, "button[phx-click=enable-emisar]", "Resume")
    # The account's identifiers are support details, folded away from its row.
    assert has_element?(view, ".entity-row details.settings-row-details dd", "account-production")
    refute has_element?(view, "form[phx-submit=rename-emisar]")

    view |> element("button[phx-click=enable-emisar]", "Resume") |> render_click()
    assert [%{enabled_for_new_work: true}] = Settings.fetch!().emisar_connections

    view
    |> element("button[phx-click=show-emisar-form][phx-value-ref=production]", "Manage")
    |> render_click()

    assert has_element?(view, "form[phx-submit=rename-emisar]", "Save name")
    assert has_element?(view, "form[phx-submit=rotate-emisar]", "Replace token")

    assert has_element?(
             view,
             "button[phx-click=disable-emisar-monitoring]",
             "Turn off"
           )
  end

  test "an Emisar account is removed only after the question is answered, and its environments lose it" do
    snapshot = initialize!()

    {:ok, snapshot} =
      Settings.put_emisar_connection(
        %{
          ref: "production",
          display_name: "Production approvals",
          rpc_url: "https://emisar.example/api/mcp/rpc",
          account_ref: "account-production",
          enabled_for_new_work: true,
          monitoring_enabled: true,
          verified_at: ~U[2026-09-19 12:00:00.000000Z]
        },
        snapshot.installation.revision,
        @actor
      )

    {:ok, _snapshot} =
      Settings.put_environment(
        %{
          ref: "production",
          display_name: "Production",
          repositories: [],
          emisar_connection_ref: "production"
        },
        snapshot.installation.revision,
        @actor
      )

    {:ok, view, _html} = open("/integrations/emisar")

    view
    |> element("button[phx-click=show-emisar-form][phx-value-ref=production]")
    |> render_click()

    view |> element("button[phx-value-action=delete-emisar]") |> render_click()
    assert has_element?(view, ".settings-confirm", "Remove Production approvals?")

    assert has_element?(
             view,
             ".settings-confirm",
             "the environments that use it are left without an Emisar account"
           )

    assert [_account] = Settings.fetch!().emisar_connections

    view |> element(".settings-confirm button", "Cancel") |> render_click()
    refute has_element?(view, ".settings-confirm")
    assert [_account] = Settings.fetch!().emisar_connections

    view |> element("button[phx-value-action=delete-emisar]") |> render_click()
    view |> element(".settings-confirm button", "Remove account") |> render_click()

    assert has_element?(view, ".form-feedback-success", "The Emisar account was removed.")
    assert Settings.fetch!().emisar_connections == []
    assert [%{ref: "production", emisar_connection_ref: nil}] = Settings.fetch!().environments
  end

  test "disconnecting Slack asks what it will do and acts only on the answer" do
    # Disconnect Slack and Disconnect GitHub deleted the saved tokens on one
    # click, with nothing between the button and the loss.
    initialize!()
    connect_slack!()
    {:ok, view, _html} = open("/integrations/slack")

    view |> element("button[phx-value-action=disconnect-slack]", "Disconnect") |> render_click()

    assert has_element?(view, ".settings-confirm", "Disconnect Slack?")
    assert has_element?(view, ".settings-confirm", "the saved tokens are deleted")
    assert {:ok, _token} = Credentials.fetch(:slack_bot, "primary")

    # A disconnect that was never asked about only asks.
    render_click(view, "cancel-settings-action", %{})
    render_click(view, "disconnect-integration", %{"kind" => "slack"})
    assert has_element?(view, ".settings-confirm", "Disconnect Slack?")
    assert {:ok, _token} = Credentials.fetch(:slack_bot, "primary")

    view |> element(".settings-confirm button", "Disconnect Slack") |> render_click()

    assert {:error, :credential_missing} = Credentials.fetch(:slack_bot, "primary")
    refute Settings.fetch!().slack.enabled
    assert has_element?(view, ".form-feedback-success", "Slack is disconnected.")
  end

  test "a connected GitHub App shows where its webhook points and disconnects only when asked" do
    initialize!()
    connect_github!()
    {:ok, view, _html} = open("/integrations/github")

    assert has_element?(
             view,
             ".settings-connection .state-word[data-tone=warn]",
             "Add a repository to start"
           )

    assert has_element?(view, ".section-head a[href='/repositories']", "Add repositories")
    assert has_element?(view, ".copy-block pre", "http")
    assert has_element?(view, "a[href='https://github.com/apps/ryker-acme/installations/new']")
    assert has_element?(view, "#settings-publication .section-head h2", "Pull requests")
    assert has_element?(view, "#settings-publication-form input[name=branch_prefix]")

    view |> element("button[phx-value-action=disconnect-github]", "Disconnect") |> render_click()
    assert has_element?(view, ".settings-confirm", "Disconnect GitHub?")
    assert {:ok, _key} = Credentials.fetch(:github_private_key, "primary")

    view |> element(".settings-confirm button", "Disconnect GitHub") |> render_click()

    assert {:error, :credential_missing} = Credentials.fetch(:github_private_key, "primary")
    assert has_element?(view, ".form-feedback-success", "GitHub is disconnected.")
    assert has_element?(view, ".settings-connection .state-word[data-tone=off]", "Not connected")
  end

  test "choosing who manages Ryker never changes how Ryker takes part in channels" do
    # Until 2026-09-24 saving the operators also wrote "only when mentioned" as
    # every channel's default, silently undoing the choice made under New
    # channels.
    initialize!()
    connect_slack!(:proactive)
    {:ok, view, _html} = open("/integrations/slack")

    render_submit(view, "save-slack-choices", %{})

    slack = Settings.fetch!().slack
    assert slack.enabled
    assert slack.default_participation == :proactive
    assert has_element?(view, ".form-feedback-success", "Saved who can manage Ryker.")
  end

  test "new channels and incident rooms are set on the Slack page, in the words people choose" do
    initialize!()
    connect_slack!()
    {:ok, view, _html} = open("/integrations/slack")

    # The Channels page links here for its defaults.
    assert has_element?(view, "#new-channels h2", "New channels")
    assert has_element?(view, ".section-head h2", "Incident rooms")

    for {value, label, description} <- [
          {"mentions", "Only when mentioned", "Ryker replies when someone writes @Ryker."},
          {"proactive", "Join relevant conversations",
           "Ryker also replies when it can clearly help."},
          {"shadow", "Watch quietly", "Ryker reads and learns, but never replies."}
        ] do
      assert has_element?(
               view,
               ".settings-option input[type=radio][name=default_participation][value=#{value}]"
             )

      assert has_element?(view, ".settings-option strong", label)
      assert has_element?(view, ".settings-option small", description)
    end

    refute has_element?(view, "#settings-slack-form input[name=enabled]")

    view
    |> form("#settings-slack-form", %{
      "default_participation" => "shadow",
      "channel_prefix" => "inc",
      "incident_private" => "false"
    })
    |> render_submit()

    slack = Settings.fetch!().slack
    assert slack.default_participation == :shadow
    assert slack.channel_prefix == "inc"
    refute slack.incident_private
    assert has_element?(view, "#settings-slack [role=status]", "Saved.")
  end

  test "instructions typed before setup do not stop the console from creating settings" do
    # The instructions page is reachable before setup. Until the YAML importer
    # was retired, a sentence saved there made this button refuse and point at
    # an import that had nothing to import.
    assert {:ok, _} = Ryker.Instructions.save(:global, "Existing guidance", 0, @actor)

    {:ok, view, _html} = open()
    view |> element("button[phx-click=initialize-settings]") |> render_click()

    refute has_element?(view, "[role=alert]")
    assert Repo.aggregate(Installation, :count) == 1
    assert Ryker.Instructions.get(:global).text == "Existing guidance"
  end

  test "each kind of work has its own model, chosen by name and effort" do
    # One model for every kind of work meant a quick chat reply and a deep
    # investigation paid for the same reasoning.
    initialize!()
    {:ok, view, _html} = open("/settings/models")

    # Outside the Compose distribution, workers' own policies choose models.
    assert has_element?(view, ".settings-notice", "separately managed workers")

    previous = System.get_env("RYKER_BUNDLED_COOP_ROOT")
    System.put_env("RYKER_BUNDLED_COOP_ROOT", System.tmp_dir!())

    on_exit(fn ->
      if previous,
        do: System.put_env("RYKER_BUNDLED_COOP_ROOT", previous),
        else: System.delete_env("RYKER_BUNDLED_COOP_ROOT")
    end)

    {:ok, view, _html} = open("/settings/models")
    refute has_element?(view, ".settings-notice")
    refute has_element?(view, "#settings-model-form option[value='']")

    for group <- ["Routing and replies", "Work", "Other work"] do
      assert has_element?(view, "#settings-model-form .section-head h2", group)
    end

    for name <-
          ~w(routing_model conversation_model standard_model deep_model contributor_model schedule_model incident_model learning_model) do
      assert has_element?(view, "#settings-model-form select[name=#{name}]")
    end

    assert has_element?(
             view,
             "#settings-model-form select[name=deep_model] option[value='codex:gpt-5.6-sol/xhigh@default'][selected]",
             "gpt-5.6-sol · Extra high reasoning"
           )

    view
    |> form("#settings-model-form", %{"deep_model" => "codex:gpt-5.6-luna/high@default"})
    |> render_submit()

    work = Settings.fetch!().work
    assert work.deep_model == "codex:gpt-5.6-luna/high@default"
    assert work.standard_model == "codex:gpt-5.6-sol/medium@default"

    # A model no price covers is still runnable, but its cost is not priced.
    snapshot = Settings.fetch!()
    rate = Enum.find(snapshot.pricing_rates, &(&1.execution_target == "codex:gpt-5.6-luna"))

    {:ok, _snapshot} =
      Settings.delete_pricing_rate(rate.id, snapshot.installation.revision, @actor)

    {:ok, view, _html} = open("/settings/models")
    assert has_element?(view, ".settings-notice", "No price covers the model for Deep work")
    assert has_element?(view, ".settings-notice a[href='/settings/prices']", "Add a price")

    assert has_element?(
             view,
             "#settings-model-form select[name=deep_model] option[value='codex:gpt-5.6-luna/high@default'][selected]"
           )
  end

  test "shortening a retention limit names what it would expose before it is applied" do
    initialize!()
    {:ok, view, _html} = open("/settings/retention")

    assert has_element?(
             view,
             "label[for=settings-retention-operational_data_seconds]",
             "Prompts, replies and tool activity"
           )

    assert has_element?(view, ".settings-days", "Kept for")
    assert has_element?(view, ".settings-form-help", "at least as long as the one above it")

    view
    |> form("#settings-retention-form", %{"operational_data_seconds" => "7"})
    |> render_submit()

    assert has_element?(view, ".settings-impact", "Shorter limits delete older data")
    assert Settings.fetch!().retention.operational_data_seconds == 30 * @day

    view |> element("#settings-retention button[phx-click=confirm]") |> render_click()

    assert Settings.fetch!().retention.operational_data_seconds == 7 * @day
    assert has_element?(view, "#settings-retention [role=status]", "Saved.")
  end

  test "a retention limit out of order or out of range is refused with a reason to act on" do
    # An ordering refusal named no field of the form, so the page showed
    # nothing at all; a limit past ten years said only "was refused."
    initialize!()
    {:ok, view, _html} = open("/settings/retention")

    view
    |> form("#settings-retention-form", %{"audit_data_seconds" => "10"})
    |> render_submit()

    assert has_element?(view, "#settings-retention [role=alert]", "out of order")
    assert Settings.fetch!().retention.audit_data_seconds == 30 * @day

    view
    |> form("#settings-retention-form", %{
      "audit_data_seconds" => "4000",
      "episode_history_seconds" => "30"
    })
    |> render_submit()

    assert has_element?(
             view,
             "#settings-retention [role=alert]",
             "Audit trail must be between 1 and 3,650 days."
           )

    assert Settings.fetch!().retention.audit_data_seconds == 30 * @day
  end

  test "a model price is added, corrected and removed at the revision it was read at" do
    initialize!()
    {:ok, view, _html} = open("/settings/prices")

    assert has_element?(view, "#settings-pricing .entity-row .entity-name", "gpt-5.6-sol")
    assert has_element?(view, "#settings-pricing .entity-meta", "per million tokens")
    assert has_element?(view, "#settings-pricing button.settings-editor-add", "Add price")

    view |> element("#settings-pricing button.settings-editor-add") |> render_click()

    view
    |> form("#settings-pricing-form", %{
      "execution_target" => "codex:test-model",
      "input_usd_per_million" => "1.25",
      "cached_input_usd_per_million" => "0.13",
      "output_usd_per_million" => "10",
      "effective_from" => "2026-09-01",
      "provenance" => "provider price list"
    })
    |> render_submit()

    rate =
      Enum.find(Settings.fetch!().pricing_rates, &(&1.execution_target == "codex:test-model"))

    assert %PricingRate{} = rate
    assert Decimal.equal?(rate.input_usd_per_million, Decimal.new("1.25"))
    assert rate.revision == 2

    assert has_element?(
             view,
             "#settings-pricing .entity-meta",
             ~r/\$1\.25 in\s*·\s*\$0\.13 cached\s*·\s*\$10\.00 out per million tokens/
           )

    view
    |> element(~s{button[phx-click=select-item][phx-value-item="#{rate.id}"]})
    |> render_click()

    assert has_element?(view, "#settings-pricing .settings-editor-heading", "Edit price")

    view
    |> form("#settings-pricing-form", %{"output_usd_per_million" => "12"})
    |> render_submit()

    corrected = Enum.find(Settings.fetch!().pricing_rates, &(&1.id == rate.id))
    assert Decimal.equal?(corrected.output_usd_per_million, Decimal.new("12"))
    assert corrected.id == rate.id
    assert corrected.revision == 2

    view |> element("#settings-pricing button", "Cancel") |> render_click()

    # Remove asks first and says what it does; only its own button removes.
    view
    |> element(~s{button[phx-click=ask-remove][phx-value-item="#{rate.id}"]})
    |> render_click()

    assert has_element?(view, "#settings-pricing .settings-confirm", "Remove test-model?")
    assert has_element?(view, "#settings-pricing .settings-confirm", "not priced")
    assert Enum.any?(Settings.fetch!().pricing_rates, &(&1.id == rate.id))

    view
    |> element(~s{#settings-pricing .settings-confirm button[phx-click=delete-item]})
    |> render_click()

    refute Enum.any?(Settings.fetch!().pricing_rates, &(&1.id == rate.id))
    assert length(Settings.fetch!().pricing_rates) == 3
    assert Settings.fetch!().installation.revision == 4
  end

  test "a remove that was never asked about only asks" do
    initialize!()
    [rate | _rates] = Settings.fetch!().pricing_rates
    {:ok, view, _html} = open("/settings/prices")

    view
    |> with_target("#settings-pricing")
    |> render_click("delete-item", %{"item" => rate.id})

    assert has_element?(view, "#settings-pricing .settings-confirm")
    assert Enum.any?(Settings.fetch!().pricing_rates, &(&1.id == rate.id))
  end

  test "an unreadable settings database is not an installation without settings", context do
    initialize!()
    Agent.update(context.unavailable, fn _ -> true end)

    {:ok, view, html} = open()

    assert html =~ "Settings unavailable"
    refute has_element?(view, "#settings-slack-form")
    refute html =~ "Start setup"
    assert Repo.aggregate(Installation, :count) == 1
  end

  test "a half-migrated settings database reads as unavailable, not as a fresh install" do
    initialize!()
    Repo.delete_all(Ryker.Settings.Slack)

    {:ok, view, html} = open()

    assert html =~ "Settings unavailable"
    refute html =~ "Start setup"
    refute has_element?(view, "button[phx-click=initialize-settings]")
    assert Repo.aggregate(Installation, :count) == 1
  end

  test "a value whose shape does not fit its control is refused, not matched by accident" do
    # The socket accepts whatever a client sends. A map where a prefix belongs
    # must be a refusal, not a FunctionClauseError that takes the page down.
    initialize!()

    assert {:error, {:invalid_settings, [{:channel_prefix, :invalid}]}} =
             Actions.callbacks().save_settings.(:slack, %{"channel_prefix" => %{"a" => "b"}}, 1)

    assert {:error, {:invalid_settings, [{:section, :unknown}]}} =
             Actions.callbacks().save_settings.(:not_a_section, %{}, 1)

    assert Settings.fetch!().slack.channel_prefix == "ems"
    assert Settings.fetch!().installation.revision == 1
  end

  defp open(path \\ "/setup"),
    do: live(build_conn() |> Map.put(:host, "localhost"), path)

  defp initialize! do
    {:ok, snapshot} = Settings.initialize(@actor)
    snapshot
  end

  defp joined!(channel, environment), do: channel!(channel, environment, :joined)
  defp left!(channel, environment), do: channel!(channel, environment, :left)

  defp channel!(channel, environment, status) do
    now = DateTime.utc_now()

    %{
      channel_ref: channel,
      generation: 1,
      id: Ecto.UUID.generate(),
      joined_at: now,
      left_at: if(status == :left, do: now),
      private: false,
      external_shared: false,
      status: status,
      workspace_ref: "T0123456789"
    }
    |> ChannelConfigurationChangeset.membership()
    |> Repo.insert!()

    %{
      alert_policy: :reply,
      channel_ref: channel,
      environment_ref: environment,
      id: Ecto.UUID.generate(),
      revision: 1,
      saved_at: now,
      workspace_ref: "T0123456789"
    }
    |> ChannelConfigurationChangeset.configuration()
    |> Repo.insert!()
  end

  # A verified GitHub App as Connect leaves it before any repository is added.
  defp connect_github! do
    key = :public_key.generate_key({:rsa, 2_048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
    snapshot = Settings.fetch!()

    {:ok, _snapshot} =
      Settings.save_github(
        %{app_id: 1_234, app_slug: "ryker-acme", bot_actor_id: 99, bot_login: "ryker-acme[bot]"},
        snapshot.installation.revision,
        @actor
      )

    {:ok, _} = Credentials.put(:github_private_key, "primary", pem, @actor)
    {:ok, _} = Credentials.verify(:github_private_key, "primary", :verified, @actor)

    {:ok, _} =
      Credentials.put(:github_webhook, "primary", "test-webhook-secret-long-enough", @actor)

    {:ok, _} = Credentials.verify(:github_webhook, "primary", :verified, @actor)
    :ok
  end

  # A verified Slack identity and tokens, as Connect leaves them before anyone
  # has chosen who manages Ryker.
  defp connect_slack!(participation \\ :mentions) do
    snapshot = Settings.fetch!()

    {:ok, _snapshot} =
      Settings.save_slack(
        %{
          workspace_ref: "T0123456789",
          workspace_name: "Acme",
          bot_ref: "A0123456789",
          bot_user_ref: "U0123456789",
          bot_name: "ryker",
          default_participation: participation
        },
        snapshot.installation.revision,
        @actor
      )

    for kind <- [:slack_app, :slack_bot] do
      {:ok, _} = Credentials.put(kind, "primary", "xoxb-test-token-long-enough", @actor)
      {:ok, _} = Credentials.verify(kind, "primary", :verified, @actor)
    end

    :ok
  end
end
