defmodule Ryker.ControlPlane.SettingsLiveTest do
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Actions, Endpoint, Projection, SettingsPage, SettingsView, SetupPage}
  alias Ryker.{Credentials, IntegrationSetup}
  alias Ryker.Fixtures.Answers
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
       pubsub_server: Ryker.PubSub.Server,
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
    refute has_element?(view, ".settings-block form")

    view |> element("button[phx-click=initialize-settings]") |> render_click()

    assert has_element?(view, "ol.setup-steps li[aria-current=step] h3", "Connect Slack")

    assert has_element?(
             view,
             "li[aria-current=step] a[href='/integrations/slack']",
             "Connect Slack"
           )

    assert {:ok, %{installation: %{revision: 1}}} = Settings.fetch()
  end

  test "each settings page is titled with its sidebar name and what is running folds nothing away",
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
          {fn -> :ok end, "/settings/report", "Weekly report"},
          {fn -> :ok end, "/settings/advanced", "Advanced"}
        ] do
      prepare.()
      {:ok, _view, html} = open(path)
      document = LazyHTML.from_document(html)
      headings = LazyHTML.query(document, "main h1")
      assert Enum.count(headings) == 1, title
      assert LazyHTML.text(headings) == title
      assert LazyHTML.query(document, "title") |> LazyHTML.text() == "#{title} · Ryker"

      assert LazyHTML.query(
               document,
               "main header.page-header > .page-heading > .page-title-line > h1"
             )
             |> Enum.count() == 1

      matching_headings =
        document
        |> LazyHTML.query("main h1, main h2")
        |> Enum.count(&(LazyHTML.text(&1) == title))

      assert matching_headings == 1, "#{path} repeats the page title inside its content"
    end

    document = open("/settings/advanced") |> elem(2) |> LazyHTML.from_document()
    # What is running is one plain card: no collapsibles, nothing to change.
    assert Enum.count(LazyHTML.query(document, "main #running-now")) == 1

    assert Enum.empty?(
             LazyHTML.query(
               document,
               "main #running-now details, main #running-now form, main #running-now button"
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

    # Emisar with no account leads to the page where one is connected, and
    # that page asks only for the token and the address.
    {:ok, emisar, _html} = open("/integrations/emisar")
    assert has_element?(emisar, "a[href='/integrations/emisar/new']", "Connect an account")
    refute has_element?(emisar, "form[phx-submit=connect-emisar]")

    {:ok, emisar, _html} = open("/integrations/emisar/new")
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
    # /settings is now the Settings overview, a page of its own, not an alias
    # for the old one.
    initialize!()

    for path <- ~w(/settings/slack /settings/github /settings/emisar /settings/webhooks) do
      assert get(build_conn() |> Map.put(:host, "localhost"), path).status == 404, path
    end

    for path <-
          ~w(/setup /integrations /integrations/slack /settings /settings/models /settings/advanced) do
      assert {:ok, _view, _html} = open(path)
    end
  end

  test "Settings has an overview of its pages, the way Integrations has one" do
    # QA 2026-09-26: /settings answered 404 while /integrations opened an
    # overview. Settings was the one group in the sidebar whose own address
    # found nothing, so a remembered or typed /settings read as a broken page.
    prices = length(initialize!().pricing_rates)
    assert prices > 1

    conn = build_conn() |> Map.put(:host, "localhost") |> get("/settings")
    assert conn.status == 200

    {:ok, _view, html} = open("/settings")
    document = LazyHTML.from_document(html)

    assert LazyHTML.query(document, "main h1") |> LazyHTML.text() == "Settings"
    assert LazyHTML.query(document, "title") |> LazyHTML.text() == "Settings · Ryker"

    rows = LazyHTML.query(document, "main .settings-list .entity-row")

    assert rows |> LazyHTML.query(".entity-name a") |> LazyHTML.attribute("href") ==
             ~w(/settings/models /settings/retention /settings/prices /settings/report /settings/advanced)

    assert rows |> LazyHTML.query(".entity-name a") |> texts() ==
             ["Models", "Data retention", "Model prices", "Weekly report", "Advanced"]

    # Each row says what its page sets, and where it is now.
    assert rows |> LazyHTML.query(".entity-text") |> Enum.count() == 5
    assert LazyHTML.query(document, "#setting-report .entity-meta") |> LazyHTML.text() =~ "Off"
    models = LazyHTML.query(document, "#setting-model .entity-meta") |> LazyHTML.text()
    assert models =~ "gpt-5.6-sol"
    assert models =~ "gpt-5.6-terra"

    assert LazyHTML.query(document, "#setting-pricing .entity-meta") |> LazyHTML.text() =~
             "#{prices} prices"

    # The sidebar's Settings group opens on its overview, as Integrations does,
    # and the overview alone is selected on its own address.
    settings_links = LazyHTML.query(document, "details#nav-settings a")

    assert LazyHTML.attribute(settings_links, "href") ==
             ~w(/settings /settings/models /settings/retention /settings/prices /settings/report /settings/advanced)

    assert LazyHTML.query(document, "details#nav-settings a[aria-current=page]")
           |> LazyHTML.attribute("href") == ["/settings"]
  end

  # Andrew, 2026-09-27: the Weekly report setting saved and posted nothing.
  # The page is where he sees what it would say before he turns it on, so the
  # preview has to be the report's own words, and asking for it must neither
  # post nor record a week as sent.
  test "the Weekly report page previews this week's report in the page and posts nothing" do
    initialize!()

    asked =
      Answers.slack_message!(
        workspace: "TPREVIEW",
        channel: "CPREVIEW",
        text: "Is staging healthy?",
        ts: "1790700001.000100"
      )

    Answers.quick_reply!(asked, "Yes, it is.", "1790700001.000200", DateTime.utc_now())

    {:ok, view, html} = open("/settings/report")
    document = LazyHTML.from_document(html)
    assert LazyHTML.query(document, "main h1") |> LazyHTML.text() == "Weekly report"
    assert has_element?(view, "#settings-report form input[name='weekly_self_report_enabled']")
    assert has_element?(view, "#settings-report form select[name='channel_ref']")
    refute has_element?(view, "#weekly-report-text")

    view |> element("#preview-weekly-report") |> render_click()
    assert_patch(view, "/settings/report?preview=week")

    text = view |> element("#weekly-report-text") |> render() |> LazyHTML.from_fragment()
    words = LazyHTML.text(text)

    assert words =~ "Hey everyone 👋 Here's my weekly report for"
    assert words =~ "This past week I handled 1 message"
    assert words =~ "It was a quick answer."

    # With no channel chosen there is nowhere to send it yet.
    refute has_element?(view, "#send-weekly-report-preview")
    assert has_element?(view, "#weekly-report-preview", "Choose the report's channel above")

    # Nothing was posted, queued or recorded as sent.
    assert Repo.aggregate(Ryker.WeeklyReport.Report, :count) == 0

    # The preview is a link, so a reload shows it again.
    {:ok, reloaded, _html} = open("/settings/report?preview=week")
    assert has_element?(reloaded, "#weekly-report-text", "handled 1 message")

    reloaded |> element("#weekly-report-preview a", "Hide the preview") |> render_click()
    refute has_element?(reloaded, "#weekly-report-text")
  end

  # Andrew, 2026-09-28: "why not to send real report to configured channel
  # as a preview?" Reading the words in the console is not seeing what the
  # channel gets.
  test "the preview can be sent to the report's channel now, marked as a preview, without turning the report on" do
    snapshot = initialize!()

    {:ok, snapshot} =
      Settings.save_slack(
        %{
          enabled: true,
          workspace_ref: "T0123456789",
          bot_ref: "A0123456789",
          bot_user_ref: "U0123456789",
          operators: ["U1111111111"]
        },
        snapshot.installation.revision,
        @actor
      )

    joined!("CREPORT", nil)

    {:ok, _snapshot} =
      Settings.save_report(%{channel_ref: "CREPORT"}, snapshot.installation.revision, @actor)

    {:ok, view, _html} = open("/settings/report?preview=week")
    assert has_element?(view, "#send-weekly-report-preview", "Send to")

    view |> element("#send-weekly-report-preview") |> render_click()
    assert has_element?(view, "#weekly-report-sent", "Sent.")

    assert [report] = Repo.all(Ryker.WeeklyReport.Report)
    assert report.preview
    assert report.conversation_ref == "slack:T0123456789:CREPORT"
    assert report.document["message"] =~ "Here's a preview of my weekly report"
    refute Settings.fetch!().report.weekly_self_report_enabled
  end

  # The report asked for "the channel's ID from Slack, under its name's
  # details" (2026-09-28), an ID nobody has to hand. It is chosen by name from
  # the channels Ryker is in, as a webhook source's channel is, and one saved
  # before Ryker left it stays on offer.
  test "the weekly report's channel is chosen from the channels Ryker is in" do
    initialize!()
    joined!("CREPORT", nil)

    {:ok, view, _html} = open("/settings/report")

    refute has_element?(view, "#settings-report form input[name='channel_ref']")

    assert has_element?(
             view,
             "#settings-report form select[name='channel_ref'] option[value='CREPORT']"
           )
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

    assert {:ok, %{status: :saved}} =
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
        readiness: %{view.readiness | slack: %{state: :ready}}
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

    # The line above the repositories says what the GitHub page says, and its
    # one button goes straight to the repair form.
    assert has_element?(repositories, "#github-status .state-word[data-tone=bad]", "Needs repair")

    assert has_element?(
             repositories,
             "#github-status a[href='/integrations/github#github-app']",
             "Repair GitHub"
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

    {:ok, _snapshot} =
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
    refute has_element?(view, "form[phx-submit=rename-emisar]")

    # Andrew, 2026-09-28: the whole row opens the account, as on Activity,
    # and everything that changes it, pausing included, is on its page.
    assert has_element?(view, "#emisar-account-production.entity-row-link")
    refute has_element?(view, "#emisar-account-production button")
    refute has_element?(view, "#emisar-account-production .entity-actions")

    {:ok, view, _html} =
      view
      |> element("#emisar-account-production .entity-name a", "Production approvals")
      |> render_click()
      |> follow_redirect(
        build_conn() |> Map.put(:host, "localhost"),
        "/integrations/emisar/production/edit"
      )

    assert has_element?(view, "#emisar-new-work", "Paused, so Ryker sends it no new work.")

    view
    |> element("#emisar-new-work button[phx-click=enable-emisar]", "Resume")
    |> render_click()

    assert [%{enabled_for_new_work: true}] = Settings.fetch!().emisar_connections
    assert has_element?(view, "#emisar-new-work button[phx-click=disable-emisar]", "Pause")

    # Its address, a support detail, is one of its facts.
    assert has_element?(view, "main h1", "Edit Production approvals")
    assert has_element?(view, "nav.kit-back a[href='/integrations/emisar']", "Emisar")
    assert has_element?(view, ".kit-facts dd", "https://emisar.example/api/mcp/rpc")
    assert has_element?(view, "form[phx-submit=rename-emisar]", "Save name")
    assert has_element?(view, "form[phx-submit=rotate-emisar]", "Replace key")

    assert has_element?(
             view,
             "button[phx-click=disable-emisar-monitoring]",
             "Turn off"
           )
  end

  test "connecting an Emisar account happens on a page of its own, apart from the accounts" do
    # Andrew, 2026-09-27, of every add form opened above its list: "it blends
    # into the content ... we need a much better way to do forms like this,
    # properly designed". Connecting an account is its own page now, with its
    # form in one card and a way back, and the list never holds a form.
    snapshot = initialize!()
    {:ok, view, _html} = open("/integrations/emisar")

    # With no account yet, the list says so and leads to the form.
    assert has_element?(view, "section[aria-label=Accounts] .kit-empty", "No Emisar account yet")

    assert has_element?(
             view,
             "section[aria-label=Accounts] .kit-empty a[href='/integrations/emisar/new']",
             "Connect an account"
           )

    {:ok, _snapshot} =
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

    {:ok, view, _html} = open("/integrations/emisar")
    refute has_element?(view, "form[phx-submit=connect-emisar]")

    view
    |> element("section[aria-label=Accounts] .section-head a", "Add account")
    |> render_click()

    assert_patch(view, "/integrations/emisar/new")

    assert has_element?(view, "main h1", "Connect an Emisar account")
    assert has_element?(view, "nav.kit-back a[href='/integrations/emisar']", "Emisar")
    assert has_element?(view, ".kit-form-card form[phx-submit=connect-emisar]")
    refute has_element?(view, ".entity-list")

    view |> element(".kit-form-card a", "Cancel") |> render_click()
    assert_patch(view, "/integrations/emisar")
    refute has_element?(view, "form[phx-submit=connect-emisar]")
  end

  # Andrew, 2026-09-27, of the empty Emisar key box: "for inputs where format
  # is known we should show placeholder showing it, eg `emk-...` here". An
  # empty box leaves the format to be learned from a refusal.
  test "a box whose format is known shows that format while it is empty" do
    initialize!()

    # Every form that asks for one, on the page each has of its own.
    for {path, placeholders} <- [
          {"/integrations/emisar/new",
           [
             {"#emisar-connect-token", "emk-…"},
             {"#emisar-connect-url", "https://emisar.dev/api/mcp/rpc"}
           ]},
          {"/integrations/slack",
           [
             {"input[name='connection[app_token]']", "xapp-…"},
             {"input[name='connection[bot_token]']", "xoxb-…"}
           ]},
          {"/integrations/github",
           [
             {"input[name='connection[app_id]']", "123456"},
             {"input[name='connection[webhook_secret]']", "32 characters or more"}
           ]},
          {"/integrations/webhooks/credentials/new",
           [
             {"#webhook-credential-name", "grafana"},
             {"#webhook-credential-secret", "32 characters or more"}
           ]},
          {"/settings/prices/new", [{"#settings-pricing-execution_target", "codex:gpt-5.6-sol"}]},
          {"/environments/new", [{"input[name='environment[display_name]']", "Production"}]}
        ] do
      {:ok, view, _html} = open(path)

      for {input, placeholder} <- placeholders do
        assert has_element?(view, "#{input}[placeholder='#{placeholder}']"),
               "#{path}: #{input} does not show #{placeholder}"
      end
    end

    # The key is what Emisar checks; Emisar never names an account for it.
    {:ok, view, _html} = open("/integrations/emisar/new")

    assert has_element?(
             view,
             "form[phx-submit=connect-emisar] .settings-help",
             "Ryker checks the key with Emisar, then stores it encrypted."
           )
  end

  # Andrew, 2026-09-27: an account connected with its default name read
  # "emisar.dev" as its name and again first in the line under it.
  test "an Emisar account named after its address says the address once" do
    snapshot = initialize!()

    {:ok, _snapshot} =
      Settings.put_emisar_connection(
        %{
          ref: "emisar-dev",
          display_name: "emisar.dev",
          rpc_url: "https://emisar.dev/api/mcp/rpc",
          account_ref: "key-" <> String.duplicate("a", 32),
          account_label: "emisar.dev",
          enabled_for_new_work: true,
          monitoring_enabled: true,
          verified_at: ~U[2026-09-27 09:00:00.000000Z]
        },
        snapshot.installation.revision,
        @actor
      )

    {:ok, view, _html} = open("/integrations/emisar")
    assert has_element?(view, ".entity-row .entity-name", "emisar.dev")
    refute has_element?(view, ".entity-row .entity-meta", "emisar.dev")

    # Given a name of its own, the account still says where it is.
    {:ok, _snapshot} = IntegrationSetup.rename_emisar("emisar-dev", "Production approvals")
    {:ok, view, _html} = open("/integrations/emisar")
    assert has_element?(view, ".entity-row .entity-name", "Production approvals")
    assert has_element?(view, ".entity-row .entity-meta", "emisar.dev")
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

    {:ok, view, _html} = open("/integrations/emisar/production/edit")

    view |> element("button[phx-value-action=delete-emisar]") |> render_click()
    assert has_element?(view, "#confirm-delete-emisar", "Remove Production approvals?")

    assert has_element?(
             view,
             "#confirm-delete-emisar",
             "the environments that use it are left without an Emisar account"
           )

    assert [_account] = Settings.fetch!().emisar_connections

    view |> element("#confirm-delete-emisar button", "Cancel") |> render_click()
    refute has_element?(view, "#confirm-delete-emisar")
    assert [_account] = Settings.fetch!().emisar_connections

    view |> element("button[phx-value-action=delete-emisar]") |> render_click()
    view |> element("#confirm-delete-emisar button", "Remove account") |> render_click()

    # The account's page is gone with it, so the list says what happened.
    assert_patch(view, "/integrations/emisar")
    assert has_element?(view, ".form-feedback-success", "The Emisar account was removed.")
    assert Settings.fetch!().emisar_connections == []
    assert [%{ref: "production", emisar_connection_ref: nil}] = Settings.fetch!().environments
  end

  test "disconnecting Slack asks what it will do and acts only on the answer" do
    # Disconnect Slack and Disconnect GitHub deleted the saved tokens on one
    # click, with nothing between the button and the loss.
    initialize!()
    connect_slack!()

    # Slack that was never switched on only has tokens to remove, and says so
    # (QA, 2026-09-25: "Finish connecting" sat beside a Disconnect button).
    {:ok, view, _html} = open("/integrations/slack")

    view
    |> element("button[phx-value-action=disconnect-slack]", "Remove the tokens")
    |> render_click()

    assert has_element?(view, "#confirm-disconnect-slack", "Remove the Slack tokens?")
    refute has_element?(view, "#confirm-disconnect-slack", "stops reading and replying")
    render_click(view, "cancel-settings-action", %{})

    {:ok, _snapshot} =
      Settings.save_slack(
        %{enabled: true, operators: ["U0123456789"]},
        Settings.fetch!().installation.revision,
        @actor
      )

    {:ok, view, _html} = open("/integrations/slack")

    view |> element("button[phx-value-action=disconnect-slack]", "Disconnect") |> render_click()

    assert has_element?(view, "#confirm-disconnect-slack", "Disconnect Slack?")
    assert has_element?(view, "#confirm-disconnect-slack", "the saved tokens are deleted")
    assert {:ok, _token} = Credentials.fetch(:slack_bot, "primary")

    # A disconnect that was never asked about only asks.
    render_click(view, "cancel-settings-action", %{})
    render_click(view, "disconnect-integration", %{"kind" => "slack"})
    assert has_element?(view, "#confirm-disconnect-slack", "Disconnect Slack?")
    assert {:ok, _token} = Credentials.fetch(:slack_bot, "primary")

    view |> element("#confirm-disconnect-slack button", "Disconnect Slack") |> render_click()

    assert {:error, :credential_missing} = Credentials.fetch(:slack_bot, "primary")
    refute Settings.fetch!().slack.enabled
    assert has_element?(view, ".form-feedback-success", "Slack is disconnected.")
  end

  test "the Slack tokens section shows its fields under its heading, not behind a fold" do
    # Andrew, 2026-09-25: the one section whose job is replacing the tokens
    # showed nothing to fill in. Both fields sat inside a closed "Replace the
    # tokens" disclosure that nobody thought to open.
    initialize!()
    connect_slack!()
    {:ok, view, _html} = open("/integrations/slack")

    section = "section[aria-label='Slack tokens']"
    refute has_element?(view, "#{section} details")
    assert has_element?(view, "#{section} > .section-head + form[phx-submit=connect-slack]")
    assert has_element?(view, "#{section} input[type=password][name='connection[app_token]']")
    assert has_element?(view, "#{section} input[type=password][name='connection[bot_token]']")
    assert has_element?(view, "#{section} form button[type=submit]", "Replace tokens")
  end

  test "the GitHub App credentials section shows its fields under its heading, not behind a fold" do
    # The same fold as the Slack tokens (Andrew, 2026-09-25: "remove
    # collapsible, just show inputs"): replacing the App's credentials is the
    # section's only job, and its fields sat in a closed disclosure.
    initialize!()
    connect_github!()
    {:ok, view, _html} = open("/integrations/github")

    section = "section[aria-label='App credentials']"
    refute has_element?(view, "#{section} > details")
    assert has_element?(view, "#{section} > .section-head + form[phx-submit=connect-github]")
    assert has_element?(view, "#{section} input[name='connection[app_id]']")
    assert has_element?(view, "#{section} form button[type=submit]", "Replace credentials")
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

    assert has_element?(view, ".section-head a[href='/repositories/new']", "Add repositories")
    assert has_element?(view, ".copy-block pre", "http")
    assert has_element?(view, "a[href='https://github.com/apps/ryker-acme/installations/new']")
    assert has_element?(view, "#settings-publication .section-head h2", "Pull requests")
    assert has_element?(view, "#settings-publication-form input[name=branch_prefix]")

    view |> element("button[phx-value-action=disconnect-github]", "Disconnect") |> render_click()
    assert has_element?(view, "#confirm-disconnect-github", "Disconnect GitHub?")
    assert {:ok, _key} = Credentials.fetch(:github_private_key, "primary")

    view |> element("#confirm-disconnect-github button", "Disconnect GitHub") |> render_click()

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

    refute has_element?(view, "#settings-new-channels-form input[name=enabled]")

    # Andrew, 2026-09-27: "you can save on change no need to add button, and
    # edit confirmation can be way more subtle". What new channels do is one
    # choice: it saves as it changes, and a small Saved beside it says so.
    refute has_element?(view, "#settings-new-channels-form button")

    view
    |> form("#settings-new-channels-form", %{"default_participation" => "shadow"})
    |> render_change()

    assert Settings.fetch!().slack.default_participation == :shadow
    assert has_element?(view, "#settings-new-channels-saved .kit-saved-mark", "Saved")

    view
    |> form("#settings-incident-rooms-form", %{
      "channel_prefix" => "inc",
      "incident_private" => "false"
    })
    |> render_submit()

    slack = Settings.fetch!().slack
    assert slack.default_participation == :shadow
    assert slack.channel_prefix == "inc"
    refute slack.incident_private
    assert has_element?(view, "#settings-incident-rooms [role=status]", "Saved.")
  end

  # Andrew, 2026-09-26, on Integrations › Slack: "we need some vertical rhythm
  # and better design so long multi-section pages like that do not look like
  # a huge blob of text". Each part of a long page is its own card, with its
  # controls and the button that saves them, as on the Emisar portal's
  # settings. New channels and Incident rooms shared one Save under both;
  # each card saves its own now. The Channels page links to New channels by
  # its anchor.
  #
  # Andrew, 2026-09-27: "why some pages like this have islands while others
  # dont". Data retention and Advanced were cards while Models, Model prices
  # and both overviews sat bare on the page, and Instructions was bare while
  # a channel's page showed the same editor in a card. Every page here now
  # keeps every part, form and list in a card.
  test "each part of a long settings page is its own card with its own actions" do
    initialize!()
    connect_slack!()
    connect_github!()

    {:ok, _view, html} = open("/integrations/slack")
    slack = LazyHTML.from_document(html)

    assert LazyHTML.query(slack, "main section.kit-card > header.section-head h2") |> texts() ==
             [
               "Connection",
               "Who can manage Ryker",
               "New channels",
               "Incident rooms",
               "Slack tokens"
             ]

    assert LazyHTML.query(slack, "section.kit-card > header.section-head#new-channels h2")
           |> LazyHTML.text() == "New channels"

    # A card of one choice saves as it changes, so it has no button; the
    # switch under Who can manage Ryker is such a choice.
    for {card, action} <- [
          {"Who can manage Ryker", []},
          {"New channels", []},
          {"Incident rooms", ["Save changes"]},
          {"Slack tokens", ["Replace tokens"]}
        ] do
      assert slack
             |> LazyHTML.query("section.kit-card[aria-label='#{card}'] form button[type=submit]")
             |> texts() == action,
             card
    end

    for path <-
          ~w(/integrations /integrations/slack /integrations/github /integrations/emisar /integrations/webhooks /settings /settings/models /settings/retention /settings/prices /settings/advanced /instructions) do
      {:ok, _view, html} = open(path)
      document = LazyHTML.from_document(html)

      assert LazyHTML.query(document, "main .kit-card") |> Enum.count() > 0,
             "#{path} has no card"

      assert LazyHTML.query(document, "main .section-head") |> Enum.count() ==
               LazyHTML.query(document, "main .kit-card > .section-head") |> Enum.count(),
             "#{path} has a part outside a card"

      assert LazyHTML.query(document, "main form") |> Enum.count() ==
               LazyHTML.query(document, "main .kit-card form") |> Enum.count(),
             "#{path} has a form outside a card"

      assert LazyHTML.query(document, "main .entity-list") |> Enum.count() ==
               LazyHTML.query(document, "main .kit-card .entity-list") |> Enum.count(),
             "#{path} has a list outside a card"
    end

    # Models saves each of its cards on its own.
    {:ok, _view, html} = open("/settings/models")
    models = LazyHTML.from_document(html)

    cards = ["Requests", "Other work", "Model accounts", "Local routing model"]

    assert LazyHTML.query(models, "main section.kit-card > header.section-head h2") |> texts() ==
             cards

    for card <- cards do
      assert models
             |> LazyHTML.query("section.kit-card[aria-label='#{card}'] form button[type=submit]")
             |> texts() == ["Save changes"],
             card
    end
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

  test "each kind of work has its own models, chosen by model, effort and account" do
    # One model for every kind of work meant a quick chat reply and a deep
    # investigation paid for the same reasoning.
    initialize!()
    {:ok, view, _html} = open("/settings/models")

    # Ryker supplies these models to every worker, including separate VMs.
    refute has_element?(view, ".settings-notice", "separately managed workers")

    bundled_worker!()
    {:ok, view, _html} = open("/settings/models")
    refute has_element?(view, ".settings-notice")

    for {form, names} <- [
          {"#settings-request_models-form",
           ~w(routing_models conversation_models standard_models deep_models)},
          {"#settings-other_models-form",
           ~w(contributor_models schedule_models incident_models learning_models)}
        ],
        name <- names,
        part <- ~w(model effort account) do
      assert has_element?(view, "#{form} select[name='#{name}[0][#{part}]']")
    end

    deep = "#settings-request_models-form select[name='deep_models[0]"
    assert has_element?(view, deep <> "[model]'] option[value='codex:gpt-5.6-sol'][selected]")
    assert has_element?(view, deep <> "[effort]'] option[value=xhigh][selected]", "Extra high")
    assert has_element?(view, deep <> "[account]'] option[value=default][selected]", "default")

    view
    |> form("#settings-request_models-form", %{
      "deep_models" => %{"0" => %{"model" => "codex:gpt-5.6-luna", "effort" => "high"}}
    })
    |> render_submit()

    work = Settings.fetch!().work
    assert work.deep_models == ["codex:gpt-5.6-luna/high@default"]
    assert work.standard_models == ["codex:gpt-5.6-sol/medium@default"]

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
             deep <> "[model]'] option[value='codex:gpt-5.6-luna'][selected]",
             "gpt-5.6-luna (no price)"
           )
  end

  # Andrew, 2026-09-27: a small self-hosted routing model, tried in shadow
  # first. The card says in plain words what it does and how to run one on
  # the Mac that runs Ryker, and turning it on without somewhere to
  # send the prompt, or across the internet in plain http, is refused in
  # words that say what to type.
  test "the local routing model is set on the Models page in plain words and off until it has somewhere to ask" do
    initialize!()
    {:ok, view, _html} = open("/settings/models")

    card = "#settings-local_routing"
    assert has_element?(view, "#{card} header#local-routing h2", "Local routing model")

    assert has_element?(
             view,
             "#{card} .settings-form-help",
             "scripts/routing-model-service.sh install"
           )

    assert has_element?(
             view,
             "#{card} .settings-form-help",
             "http://host.docker.internal:8181/v1"
           )

    assert has_element?(view, "#{card} input[name=local_routing_mode][value=off][checked]")
    assert has_element?(view, "#{card} .settings-option", "Compare in the background")

    assert has_element?(
             view,
             "#{card} input[name=local_routing_endpoint][placeholder='http://host.docker.internal:8181/v1']"
           )

    assert has_element?(view, "#{card} input[name=local_routing_model][placeholder='qwen2.5:3b']")

    view
    |> form("#settings-local_routing-form", %{"local_routing_mode" => "shadow"})
    |> render_submit()

    assert has_element?(
             view,
             "#{card} .settings-error",
             "Enter the local model's endpoint, such as http://host.docker.internal:8181/v1."
           )

    assert has_element?(
             view,
             "#{card} .settings-error",
             "Enter the model's name as the server lists it, such as qwen2.5:3b."
           )

    view
    |> form("#settings-local_routing-form", %{
      "local_routing_mode" => "shadow",
      "local_routing_endpoint" => "http://llm.example.com/v1",
      "local_routing_model" => "qwen2.5:3b"
    })
    |> render_submit()

    assert has_element?(
             view,
             "#{card} .settings-error",
             "Use https for a server on another network."
           )

    assert Settings.fetch!().work.local_routing_mode == :off

    view
    |> form("#settings-local_routing-form", %{
      "local_routing_mode" => "shadow",
      "local_routing_endpoint" => "http://host.docker.internal:8181/v1",
      "local_routing_model" => "qwen2.5:3b"
    })
    |> render_submit()

    work = Settings.fetch!().work
    assert work.local_routing_mode == :shadow
    assert work.local_routing_endpoint == "http://host.docker.internal:8181/v1"
    assert work.local_routing_model == "qwen2.5:3b"
    refute has_element?(view, "#{card} .settings-error")
  end

  test "each kind of work says under its title where Ryker uses its models" do
    # Andrew, 2026-09-25: eight choices with a few words each ("Investigations
    # and tool-backed work.") left nobody able to tell which one moves which
    # cost. Each sentence was checked against the code that picks the model:
    # routing and the work class it chooses (a reply is Conversation, new or
    # continued work Standard or Deep), the confirmed task, the schedule,
    # incident-room and learning lanes, and the policies the bundled worker
    # writes (work with no repository runs every class on the installation's
    # conversation policy).
    #
    # Andrew, 2026-09-27: the sentences sat under the list of models, where
    # they read as a footnote to the last one: "move texts like: > Runs first
    # on every message ... to be under title not below table".
    initialize!()
    {:ok, view, _html} = open("/settings/models")

    for {name, used} <- [
          {"routing_models",
           "Runs first on every message and event Ryker picks up, from Slack, Chat, GitHub and " <>
             "webhooks. It decides whether to answer, start work, add it to earlier work or " <>
             "stay quiet, and picks Conversation, Standard or Deep work for it. It runs more " <>
             "often than anything else, so speed and price matter most here."},
          {"conversation_models",
           "Writes the replies Ryker can give straight away, without a longer investigation: " <>
             "answers from what it already knows, quick questions and small lookups. Where " <>
             "there is no repository to work in, it does the standard and deep work too."},
          {"standard_models",
           "Investigations that use tools: reading code, checking logs, running read-only " <>
             "commands and asking Emisar to run something. Routing picks it for most work " <>
             "that needs more than a quick answer. It also reads each repository to write " <>
             "its RYKER.md."},
          {"deep_models",
           "The same kind of work, when routing judges the request hard, ambiguous or risky."},
          {"contributor_models",
           "Tasks that change code, once a person confirms them. When pull requests are on, " <>
             "Ryker opens one for the change."},
          {"schedule_models",
           "Work that starts on its own when a schedule is due: the reminders and recurring " <>
             "checks people set up by asking Ryker."},
          {"incident_models",
           "Everything Ryker does in an incident room, the Slack channel it opens for an " <>
             "incident: the investigation and every reply there. It also runs an incident " <>
             "investigated in its own thread instead of a room."},
          {"learning_models",
           "Reads the messages Ryker picks up in the background, including ones it did not " <>
             "answer, and notes what is worth remembering about each conversation. It never " <>
             "replies, and runs only while learning is on."}
        ] do
      card =
        if name in ~w(routing_models conversation_models standard_models deep_models),
          do: "request_models",
          else: "other_models"

      fieldset = "settings-#{card}-#{name}"
      id = fieldset <> "-help"

      # Straight under its title, above the models it explains, and read out
      # with them.
      assert has_element?(
               view,
               "fieldset##{fieldset}[aria-describedby='#{id}'] > legend + p##{id}.settings-help"
             ),
             name

      assert has_element?(view, "fieldset##{fieldset} > p##{id} + .settings-ladder-box"), name

      assert view
             |> element("##{id}")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.text()
             |> String.split()
             |> Enum.join(" ") == used
    end
  end

  test "every model choice lists the same models in one order, under their provider" do
    # QA, 2026-09-25: each select put its saved model first, so the same list
    # came in eight different orders and nothing said which one was in use.
    initialize!()
    snapshot = Settings.fetch!()

    {:ok, _snapshot} =
      Settings.save_work(
        %{deep_models: ["codex:gpt-5.6-luna/high@default"]},
        snapshot.installation.revision,
        @actor
      )

    {:ok, _view, html} = open("/settings/models")
    document = LazyHTML.from_document(html)
    selects = LazyHTML.query(document, ".settings-ladder select[name$='[model]']")
    assert Enum.count(selects) == 8

    orders =
      for select <- selects,
          do: select |> LazyHTML.query("option") |> LazyHTML.attribute("value")

    assert orders |> Enum.uniq() |> length() == 1
    assert hd(orders) == ~w(codex:gpt-5.6-luna codex:gpt-5.6-sol codex:gpt-5.6-terra)

    deep =
      LazyHTML.query(
        document,
        "#settings-request_models-form select[name='deep_models[0][model]']"
      )

    assert deep |> LazyHTML.query("optgroup") |> LazyHTML.attribute("label") == ["Codex"]

    assert deep |> LazyHTML.query("option[selected]") |> LazyHTML.attribute("value") == [
             "codex:gpt-5.6-luna"
           ]

    efforts =
      LazyHTML.query(
        document,
        "#settings-request_models-form select[name='deep_models[0][effort]'] option"
      )

    assert LazyHTML.attribute(efforts, "value") == ~w(low medium high xhigh)
    assert texts(efforts) == ["Low", "Medium", "High", "Extra high"]
  end

  # Andrew, 2026-09-26: "Can I have fallbacks between models/providers like
  # coop allows?" Each kind of work named one model, so a usage limit on its
  # account stopped that work until the limit reset, although Coop can move
  # down a list of models on its own.
  test "fallbacks are added, reordered and removed, and saved in the order shown" do
    initialize!()
    snapshot = Settings.fetch!()

    {:ok, _snapshot} =
      Settings.save_work(
        %{model_accounts: ["codex@default", "codex@personal"]},
        snapshot.installation.revision,
        @actor
      )

    {:ok, view, html} = open("/settings/models")

    # The rows no longer name the first choice and each fallback (Andrew,
    # 2026-09-27: "no need to say "First choice" and "Fallback 1""), so the
    # page says how a list is used, and each row shows its place in it.
    assert page_description(html) =~
             "Ryker uses the first model on each list, and the next only when the one above it " <>
               "hits a usage limit or its sign-in stops working."

    ladder = "button[phx-click=ladder][phx-value-field=routing_models]"
    routing = "#settings-request_models-routing_models"
    requests = "#settings-request_models-form"

    click = fn action, index ->
      view |> element(button(ladder, action, index)) |> render_click()
    end

    places = fn ->
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#{routing} li.settings-ladder-entry .settings-ladder-order")
      |> texts()
    end

    refute has_element?(view, button(ladder, "remove", 0))
    assert places.() == ["1"]

    # A fallback starts as the same model on the next account, as the row
    # under the first, where Add fallback was.
    click.("add", nil)
    assert places.() == ["1", "2"]
    refute render(view) =~ "First choice"
    refute render(view) =~ "Fallback 1"

    assert has_element?(
             view,
             "select[name='routing_models[1][account]'] option[value=personal][selected]"
           )

    view
    |> form(requests, %{
      "routing_models" => %{"1" => %{"model" => "codex:gpt-5.6-terra", "effort" => "low"}}
    })
    |> render_change()

    click.("up", 1)

    assert has_element?(
             view,
             "select[name='routing_models[0][model]'] option[value='codex:gpt-5.6-terra'][selected]"
           )

    view |> form(requests) |> render_submit()

    assert Settings.fetch!().work.routing_models == [
             "codex:gpt-5.6-terra/low@personal",
             "codex:gpt-5.6-sol/medium@default"
           ]

    # One model and at most three fallbacks. Both accounts are in use, so a
    # new fallback waits for its model to be chosen, and saving says so.
    click.("add", nil)
    click.("add", nil)
    assert places.() == ["1", "2", "3", "4"]
    refute has_element?(view, button(ladder, "add", nil))
    view |> form(requests) |> render_submit()

    assert has_element?(
             view,
             "#{routing} .settings-error",
             "Choose a model, a reasoning effort and an account for each one."
           )

    # The same model, effort and account twice is refused in words. Each
    # account choice lists its model's accounts once the model is chosen.
    luna = %{"model" => "codex:gpt-5.6-luna", "effort" => "low"}

    view
    |> form(requests, %{"routing_models" => %{"2" => luna, "3" => luna}})
    |> render_change()

    default = %{"account" => "default"}

    view
    |> form(requests, %{"routing_models" => %{"2" => default, "3" => default}})
    |> render_submit()

    assert has_element?(
             view,
             "#{routing} .settings-error",
             "The same model, effort and account is listed twice. Change one or remove it."
           )

    click.("remove", 3)
    click.("remove", 0)
    view |> form(requests) |> render_submit()

    assert Settings.fetch!().work.routing_models == [
             "codex:gpt-5.6-sol/medium@default",
             "codex:gpt-5.6-luna/low@default"
           ]
  end

  # QA, 2026-09-26: Add fallback copied the entry above it, account and all,
  # and Save refused the copy, so every new fallback had to be noticed and
  # changed before anything could be saved.
  test "a new fallback is never a copy of the one above it" do
    initialize!()
    snapshot = Settings.fetch!()

    {:ok, snapshot} =
      Settings.save_work(
        %{model_accounts: ["codex@default", "codex@personal", "codex@ops"]},
        snapshot.installation.revision,
        @actor
      )

    {:ok, _snapshot} =
      Settings.save_work(
        %{routing_models: ["codex:gpt-5.6-sol/medium@personal"]},
        snapshot.installation.revision,
        @actor
      )

    {:ok, view, _html} = open("/settings/models")
    add = "button[phx-click=ladder][phx-value-field=routing_models][phx-value-action=add]"
    entry = &"select[name='routing_models[#{&1}][#{&2}]'] option[selected]"

    chosen = fn index ->
      Enum.map(~w(model effort account), &selected(view, entry.(index, &1)))
    end

    # The same model on the next listed account the list does not use yet,
    # after the last one and then from the top.
    view |> element(add) |> render_click()
    assert chosen.(1) == ["codex:gpt-5.6-sol", "medium", "ops"]
    view |> element(add) |> render_click()
    assert chosen.(2) == ["codex:gpt-5.6-sol", "medium", "default"]

    # Every account is in use: the model waits to be chosen.
    view |> element(add) |> render_click()
    assert has_element?(view, entry.(3, "model"), "Choose a model")
    assert chosen.(3) == ["", "medium", ""]
  end

  test "a Claude model is offered once its price is saved, on a Claude account" do
    initialize!()
    {:ok, view, _html} = open("/settings/models")
    model = "select[name='routing_models[0][model]']"
    requests = "#settings-request_models-form"
    refute has_element?(view, model <> " optgroup[label=Claude]")

    assert has_element?(
             view,
             "#page-help",
             "a Claude model appears once its price is saved there"
           )

    snapshot = Settings.fetch!()

    {:ok, _snapshot} =
      Settings.put_pricing_rate(
        %{
          execution_target: "claude:claude-opus-4-6",
          input_usd_per_million: "5",
          cached_input_usd_per_million: "0.5",
          output_usd_per_million: "25",
          effective_from: ~D[2026-09-26],
          provenance: "https://www.anthropic.com/pricing"
        },
        snapshot.installation.revision,
        @actor
      )

    {:ok, view, _html} = open("/settings/models")

    assert has_element?(
             view,
             model <> " optgroup[label=Claude] option[value='claude:claude-opus-4-6']",
             "claude-opus-4-6"
           )

    view
    |> element("button[phx-click=ladder][phx-value-field=routing_models][phx-value-action=add]")
    |> render_click()

    view
    |> form(requests, %{
      "routing_models" => %{"1" => %{"model" => "claude:claude-opus-4-6"}}
    })
    |> render_change()

    # No Claude account is listed yet, and the choice says so.
    assert has_element?(
             view,
             "select[name='routing_models[1][account]'] option[value=''][selected]",
             "No Claude account yet"
           )

    view |> form(requests) |> render_submit()

    assert has_element?(
             view,
             "#settings-request_models-routing_models .settings-error",
             "Choose a model, a reasoning effort and an account for each one."
           )

    # Listing the account keeps the unsaved models above and offers it there.
    view |> element("button[phx-click=accounts][phx-value-action=add]") |> render_click()

    view
    |> form("#settings-model_accounts-form", %{"model_accounts" => %{"1" => "claude@work"}})
    |> render_submit()

    view
    |> form(requests, %{"routing_models" => %{"1" => %{"account" => "work"}}})
    |> render_submit()

    assert Settings.fetch!().work.routing_models == [
             "codex:gpt-5.6-sol/medium@default",
             "claude:claude-opus-4-6/medium@work"
           ]

    # A fallback no price covers is warned about like a first choice.
    bundled_worker!()
    snapshot = Settings.fetch!()
    rate = Enum.find(snapshot.pricing_rates, &(&1.execution_target == "claude:claude-opus-4-6"))

    {:ok, _snapshot} =
      Settings.delete_pricing_rate(rate.id, snapshot.installation.revision, @actor)

    {:ok, view, _html} = open("/settings/models")

    assert has_element?(
             view,
             ".settings-notice",
             "No price covers a fallback for Routing, so its cost will show as not priced."
           )

    assert has_element?(
             view,
             "select[name='routing_models[1][model]'] option[value='claude:claude-opus-4-6'][selected]",
             "claude-opus-4-6 (no price)"
           )
  end

  # Ryker cannot see which accounts the worker has signed in, and Coop refuses
  # the whole policy file while one of its models names an account that is
  # not signed in: the change would never run, and until the worker kept its
  # last loaded policies every kind of work stopped, not only the one changed.
  test "an account not listed under Model accounts is refused in plain words" do
    initialize!()
    {:ok, view, _html} = open("/settings/models")

    assert has_element?(
             view,
             "#settings-model_accounts-model_accounts-help",
             "scripts/compose.sh model-login claude@work"
           )

    # A form sent from a page that still offered an account since removed.
    view
    |> element("#settings-request_models-form")
    |> render_submit(%{"routing_models" => %{"0" => %{"account" => "personal"}}})

    assert has_element?(
             view,
             "#settings-request_models-routing_models .settings-error",
             "Choose an account listed under Model accounts. To use another account, sign it " <>
               "in on the worker, then add it there."
           )

    assert Settings.fetch!().work.routing_models == ["codex:gpt-5.6-sol/medium@default"]

    # An account a saved model still uses cannot be renamed out of the list.
    view
    |> form("#settings-model_accounts-form", %{"model_accounts" => %{"0" => "codex@personal"}})
    |> render_submit()

    assert has_element?(
             view,
             "#settings-model_accounts .settings-error",
             "codex@default still runs gpt-5.6-sol for Routing, Standard work, Deep work, " <>
               "Contributor work, Scheduled work, Incident rooms and Learning, and gpt-5.6-terra " <>
               "for Conversation. Choose another account for those models above first, then " <>
               "remove codex@default."
           )

    assert Settings.fetch!().work.model_accounts == ["codex@default"]
  end

  # Andrew, 2026-09-27: a removal that answers inside its row "extends and
  # design breaks". Removing an account a saved model still runs on is refused
  # over the page, naming those models, and the row stays as it was.
  test "removing an account a saved model runs on is refused over the page, naming the models" do
    initialize!()
    {:ok, view, _html} = open("/settings/models")
    accounts = "#settings-model_accounts-model_accounts"

    view |> element("button[phx-click=accounts][phx-value-action=add]") |> render_click()

    view
    |> element("#{accounts}-0 button[phx-click=accounts][phx-value-action=remove]")
    |> render_click()

    question = "#{accounts}-refused[role=alertdialog]"
    assert has_element?(view, question, "codex@default cannot be removed yet")

    assert has_element?(
             view,
             question,
             "codex@default still runs gpt-5.6-sol for Routing"
           )

    # The row is as it was: still there, and saying nothing.
    assert has_element?(view, "#{accounts}-0-account[value='codex@default']")
    refute has_element?(view, "#{accounts}-0 .form-feedback")

    view |> element("#{accounts}-refused button", "OK") |> render_click()
    refute has_element?(view, question)
    assert Settings.fetch!().work.model_accounts == ["codex@default"]
  end

  # The value of the option a select shows as chosen; "" for its prompt.
  defp selected(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  defp button(selector, action, nil), do: "#{selector}[phx-value-action=#{action}]"

  defp button(selector, action, index),
    do: "#{selector}[phx-value-action=#{action}][phx-value-index='#{index}']"

  test "a refused price says what to fill in and which price already has that day" do
    # QA, 2026-09-25: an empty source read as filled in behind its example,
    # "Where this price came from is required" did not say what to write, and
    # a second price for the same day said "Effective from is already taken
    # by another entry."
    initialize!()
    {:ok, view, _html} = open("/settings/prices")

    # A saved source that is a link opens it.
    assert has_element?(
             view,
             "#settings-pricing .entity-meta a[href='https://developers.openai.com/api/docs/pricing']"
           )

    view |> element(".page-action a", "Add price") |> render_click()
    assert_patch(view, "/settings/prices/new")
    refute has_element?(view, "#settings-pricing-provenance[placeholder]")

    view
    |> form("#settings-pricing-form", %{
      "execution_target" => "codex:gpt-5.6-sol",
      "input_usd_per_million" => "1",
      "cached_input_usd_per_million" => "0.1",
      "output_usd_per_million" => "2",
      "effective_from" => "2026-09-05",
      "provenance" => ""
    })
    |> render_submit()

    assert has_element?(
             view,
             "#settings-pricing .settings-error",
             "Add where this price came from, such as a link to the provider's price list."
           )

    assert has_element?(
             view,
             "#settings-pricing .settings-error",
             "gpt-5.6-sol already has a price from 5 Sep 2026. Choose another day, or edit that price."
           )
  end

  # Found in manual testing on 2026-09-26: a price saved as "claude-haiku",
  # without its provider, was accepted. No execution is named that way, so it
  # could never price anything, although the field asked for the provider and
  # model joined by a colon.
  test "a price without its provider is refused with how to write it" do
    initialize!()
    {:ok, view, _html} = open("/settings/prices/new")

    # The rates stay one even row; when to leave Reasoning empty is in the help panel.
    refute has_element?(view, "#settings-pricing-reasoning_usd_per_million-help")

    view
    |> form("#settings-pricing-form", %{
      "execution_target" => "claude-haiku",
      "input_usd_per_million" => "1",
      "cached_input_usd_per_million" => "0.1",
      "output_usd_per_million" => "5",
      "effective_from" => "2026-09-26",
      "provenance" => "https://www.anthropic.com/pricing"
    })
    |> render_submit()

    assert has_element?(
             view,
             "#settings-pricing .settings-field:has(#settings-pricing-execution_target) .settings-error",
             "Write the provider and model joined by a colon, like codex:gpt-5.6-sol."
           )

    refute Enum.any?(Settings.fetch!().pricing_rates, &(&1.execution_target == "claude-haiku"))
  end

  test "an incident room prefix that is refused says what a prefix may hold" do
    # QA, 2026-09-25: "Name starts with is not in the expected format."
    initialize!()
    connect_slack!()
    {:ok, view, _html} = open("/integrations/slack")

    view
    |> form("#settings-incident-rooms-form", %{"channel_prefix" => "Inc Rooms"})
    |> render_submit()

    assert has_element?(
             view,
             "#settings-incident-rooms .settings-error",
             "Use 1 to 20 lowercase letters, numbers, dashes or underscores, such as inc."
           )
  end

  test "new installations name incident rooms inc-, the way the demo room reads" do
    # QA, 2026-09-25: the default prefix was "ems" while every example room
    # read "#inc-…".
    initialize!()
    assert Settings.fetch!().slack.channel_prefix == "inc"
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

    # It asks over the page, so the form never grows a second step inside it
    # (Andrew, 2026-09-27: removal confirmations are modals).
    question = "#settings-retention-impact[role=alertdialog]"
    assert has_element?(view, question, "Apply shorter limits?")
    assert has_element?(view, question, "Shorter limits delete older data")
    refute has_element?(view, "#settings-retention-form #settings-retention-impact")
    assert Settings.fetch!().retention.operational_data_seconds == 30 * @day

    # Cancel keeps what was typed, and saves nothing.
    view |> element("#settings-retention-impact button", "Cancel") |> render_click()
    refute has_element?(view, question)
    assert has_element?(view, "#settings-retention-operational_data_seconds[value='7']")
    assert Settings.fetch!().retention.operational_data_seconds == 30 * @day

    view |> form("#settings-retention-form") |> render_submit()
    view |> element("#settings-retention-impact button", "Apply shorter limits") |> render_click()

    assert Settings.fetch!().retention.operational_data_seconds == 7 * @day
    assert has_element?(view, "#settings-retention [role=status]", "Saved.")
  end

  # Andrew, 2026-09-27: "Do we have ... data collection to build/fine-tune our
  # own super-efficient self hosted model later?" Keeping routing examples is
  # the consent for that, off until someone turns it on, and the page offers
  # the file while they are kept.
  test "Data retention keeps routing examples for training only once turned on, and offers them" do
    initialize!()
    {:ok, view, _html} = open("/settings/retention")

    assert has_element?(
             view,
             "label[for=settings-retention-routing_examples_enabled]",
             "Keep routing examples for training"
           )

    assert has_element?(view, "#settings-retention-routing_examples_enabled:not([checked])")
    assert has_element?(view, "#settings-retention-routing_examples_seconds[value='365']")
    refute has_element?(view, "#download-routing-examples")

    view
    |> form("#settings-retention-form", %{"routing_examples_enabled" => "true"})
    |> render_submit()

    assert Settings.fetch!().retention.routing_examples_enabled

    assert has_element?(
             view,
             "a#download-routing-examples[href='/settings/retention/routing-examples.jsonl'][download]",
             "Download routing examples"
           )

    # Turning it off deletes what was kept, so it asks first, in its own words.
    view
    |> form("#settings-retention-form", %{"routing_examples_enabled" => "false"})
    |> render_submit()

    question = "#settings-retention-impact[role=alertdialog]"
    assert has_element?(view, question, "Stop keeping routing examples?")
    assert Settings.fetch!().retention.routing_examples_enabled

    view |> element("#settings-retention-impact button", "Stop keeping them") |> render_click()

    refute Settings.fetch!().retention.routing_examples_enabled
    refute has_element?(view, "#download-routing-examples")
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
    # Andrew, 2026-09-28 (T11): Prices reads as every list page does, its
    # count above the list and Add in the page's header; the list stays in
    # the page's one card, as every settings page keeps its parts.
    assert has_element?(view, ".page-action a[href='/settings/prices/new']", "Add price")
    assert has_element?(view, "#settings-pricing > .kit-counts .kit-count", ~r/\d+ prices/)
    assert has_element?(view, "#settings-pricing > .kit-card .entity-row .entity-icon")
    refute has_element?(view, "#settings-pricing .settings-editor-add")

    view |> element(".page-action a", "Add price") |> render_click()
    assert_patch(view, "/settings/prices/new")

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

    # A saved price returns to the list, which names it, as its removal does.
    assert_patch(view, "/settings/prices")
    assert has_element?(view, ".form-feedback-success", "test-model was added.")

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

    # The whole row opens the price's own page.
    assert has_element?(view, "#settings-pricing .entity-row-link", "test-model")
    refute has_element?(view, "#settings-pricing .entity-row button")

    {:ok, view, _html} =
      view
      |> element(~s{#settings-pricing .entity-name a[href="/settings/prices/#{rate.id}/edit"]})
      |> render_click()
      |> follow_redirect(conn(), "/settings/prices/#{rate.id}/edit")

    assert has_element?(view, "main h1", "Edit test-model")

    view
    |> form("#settings-pricing-form", %{"output_usd_per_million" => "12"})
    |> render_submit()

    assert_patch(view, "/settings/prices")
    assert has_element?(view, ".form-feedback-success", "test-model was saved.")

    corrected = Enum.find(Settings.fetch!().pricing_rates, &(&1.id == rate.id))
    assert Decimal.equal?(corrected.output_usd_per_million, Decimal.new("12"))
    assert corrected.id == rate.id
    assert corrected.revision == 2

    # Remove is the price page's last card. It asks first and says what it
    # does; only its own button removes, and the list then says so.
    {:ok, view, _html} = open("/settings/prices/#{rate.id}/edit")

    view
    |> element(
      ~s{#settings-pricing-remove-card button[phx-click=ask-remove][phx-value-item="#{rate.id}"]},
      "Remove price"
    )
    |> render_click()

    assert has_element?(view, "#settings-pricing-remove", "Remove test-model?")
    assert has_element?(view, "#settings-pricing-remove", "not priced")
    assert Enum.any?(Settings.fetch!().pricing_rates, &(&1.id == rate.id))

    view
    |> element(~s{#settings-pricing-remove button[phx-click=delete-item]})
    |> render_click()

    refute Enum.any?(Settings.fetch!().pricing_rates, &(&1.id == rate.id))
    assert length(Settings.fetch!().pricing_rates) == 3
    assert Settings.fetch!().installation.revision == 4
    assert_patch(view, "/settings/prices")
    assert has_element?(view, ".form-feedback-success", "test-model was removed.")
    refute has_element?(view, "#settings-pricing-remove")
  end

  test "a remove that was never asked about only asks" do
    initialize!()
    [rate | _rates] = Settings.fetch!().pricing_rates
    {:ok, view, _html} = open("/settings/prices/#{rate.id}/edit")

    view
    |> with_target("#settings-pricing")
    |> render_click("delete-item", %{"item" => rate.id})

    assert has_element?(view, "#settings-pricing-remove")
    assert Enum.any?(Settings.fetch!().pricing_rates, &(&1.id == rate.id))
  end

  # Andrew, 2026-09-27, of Settings › Model prices: "this is another add form
  # that is fully broken and looks horrible, it doesn't even have visual
  # separation from rest of the page". Adding a price and editing one each
  # open a page of their own, with the form in one card under a title that
  # says what it does and a way back; the list itself never holds a form.
  test "Add price and a row's Edit open the form on a page of its own, apart from the list" do
    initialize!()
    [rate | _rates] = Settings.fetch!().pricing_rates
    {:ok, view, _html} = open("/settings/prices")

    refute has_element?(view, "#settings-pricing-form")
    view |> element(".page-action a", "Add price") |> render_click()
    assert_patch(view, "/settings/prices/new")

    assert has_element?(view, "main h1", "Add a price")
    assert has_element?(view, "nav.kit-back a[href='/settings/prices']", "All model prices")
    assert has_element?(view, ".kit-form-card #settings-pricing-form")
    refute has_element?(view, ".entity-list")
    refute has_element?(view, ".settings-collection-bar")

    view |> element("#settings-pricing-form a", "Cancel") |> render_click()
    assert_patch(view, "/settings/prices")
    refute has_element?(view, "#settings-pricing-form")

    {:ok, view, _html} =
      view
      |> element(~s{#settings-pricing .entity-name a[href="/settings/prices/#{rate.id}/edit"]})
      |> render_click()
      |> follow_redirect(conn(), "/settings/prices/#{rate.id}/edit")

    assert has_element?(view, ".kit-form-card #settings-pricing-form input[name=item_key]")
    refute has_element?(view, ".entity-list")

    # An address for a price that is gone says so instead of an empty form.
    {:ok, view, _html} = open("/settings/prices/#{Ecto.UUID.generate()}/edit")
    assert has_element?(view, "#form-not-found", "That price was not found")
    refute has_element?(view, "#settings-pricing-form")
  end

  test "the Advanced page explains workers without a policy configuration step" do
    # Andrew, 2026-09-25: "even I don't know what a workspace or an execution
    # policy is; the page doesn't explain that in simple language, so users
    # will never understand any of it." The words changed, not the data: the
    # same install choice and policy rows, named for what they do.
    initialize!()

    worker =
      "Ryker runs its work on a worker: a machine with your code checked out that runs the " <>
        "model and its tools."

    {:ok, _view, html} = open("/settings/advanced")

    # Without the bundled worker, the page never claims one is set up.
    assert page_description(html) ==
             worker <>
               " This installation uses workers you run yourself; choose their install below. " <>
               "Ryker supplies the code and settings for each job."

    bundled_worker!()
    {:ok, view, html} = open("/settings/advanced")

    assert page_description(html) ==
             worker <>
               " The bundled worker on this host is set up for you; change these only if you " <>
               "run your own workers."

    assert html |> LazyHTML.from_document() |> LazyHTML.query("main .section-head h2") |> texts() ==
             [
               "Where work runs",
               "Tasks that change code",
               "Running now"
             ]

    assert has_element?(view, "label[for=settings-work-workspace_ref]", "Worker install")

    assert has_element?(
             view,
             "#settings-work-workspace_ref-help",
             "Which worker install runs Ryker's work. A worker reports its install name when it connects."
           )

    refute has_element?(view, "#settings-policies")

    # Where the page speaks, it uses none of the worker's own terms.
    for selector <- ["header.page-header", "#settings-work"],
        term <- ["workspace", "Workspace", "execution polic", "Execution polic"] do
      refute view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text() =~
               term,
             "#{selector} says #{term}"
    end
  end

  test "routing sessions kept ready are set from 0 to 5 and anything else is refused in words" do
    # Andrew, 2026-09-26: routing a plain "hi" spent 5.6 s of its 28.6 s
    # creating a session, so Ryker keeps some started. How many is his to
    # choose, 0 turns it off, and a number the pool cannot keep must be
    # refused in words rather than saved or shown as a field error code.
    initialize!()
    {:ok, view, _html} = open("/settings/advanced")

    assert has_element?(
             view,
             "label[for=settings-work-ready_routing_sessions]",
             "Routing sessions kept ready"
           )

    assert has_element?(
             view,
             "#settings-work-ready_routing_sessions-help",
             "Ryker starts this many routing sessions ahead of time so a new message is " <>
               "answered sooner. Each is used for one message only. 0 turns this off."
           )

    assert has_element?(view, "input[name=ready_routing_sessions][min='0'][max='5'][value='1']")

    view |> form("#settings-work-form", %{"ready_routing_sessions" => "0"}) |> render_submit()
    assert Settings.fetch!().work.ready_routing_sessions == 0

    for refused <- ["6", "-1", ""] do
      view
      |> form("#settings-work-form", %{"ready_routing_sessions" => refused})
      |> render_submit()

      assert has_element?(
               view,
               "#settings-work .settings-error",
               "Choose a whole number from 0 to 5."
             )

      assert Settings.fetch!().work.ready_routing_sessions == 0
    end
  end

  test "an unreadable settings database is not an installation without settings", context do
    initialize!()
    Agent.update(context.unavailable, fn _ -> true end)

    {:ok, view, html} = open()

    assert html =~ "Settings unavailable"
    refute has_element?(view, ".settings-block form")
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
             Actions.callbacks().save_settings.(
               :incident_rooms,
               %{"channel_prefix" => %{"a" => "b"}},
               1
             )

    assert {:error, {:invalid_settings, [{:section, :unknown}]}} =
             Actions.callbacks().save_settings.(:not_a_section, %{}, 1)

    assert Settings.fetch!().slack.channel_prefix == "inc"
    assert Settings.fetch!().installation.revision == 1
  end

  defp open(path \\ "/setup"), do: live(conn(), path)

  defp conn, do: build_conn() |> Map.put(:host, "localhost")

  defp page_description(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("main .page-description")
    |> LazyHTML.text()
  end

  defp texts(nodes), do: Enum.map(nodes, &(&1 |> LazyHTML.text() |> String.trim()))

  # The Compose distribution names its bundled worker's root; the rest of the
  # test runs as that installation.
  # Returns the directory the worker shares with Ryker, empty at first.
  defp bundled_worker! do
    shared = Path.join(System.tmp_dir!(), "ryker-shared-#{System.unique_integer([:positive])}")
    File.mkdir_p!(shared)

    previous =
      for name <- ~w(RYKER_BUNDLED_COOP_ROOT RYKER_BUNDLED_COOP_SHARED),
          do: {name, System.get_env(name)}

    System.put_env("RYKER_BUNDLED_COOP_ROOT", System.tmp_dir!())
    System.put_env("RYKER_BUNDLED_COOP_SHARED", shared)

    on_exit(fn ->
      Enum.each(previous, &restore_env/1)
      File.rm_rf!(shared)
    end)

    shared
  end

  defp restore_env({name, nil}), do: System.delete_env(name)
  defp restore_env({name, value}), do: System.put_env(name, value)

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
