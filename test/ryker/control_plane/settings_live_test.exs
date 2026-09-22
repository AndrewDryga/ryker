defmodule Ryker.ControlPlane.SettingsLiveTest do
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Actions, Endpoint, Projection}
  alias Ryker.Credentials
  alias Ryker.Settings
  alias Ryker.Settings.{Installation, PricingRate}

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
    assert html =~ "Create this installation"
    refute has_element?(view, "#settings-slack-form")

    view |> element("button[phx-click=initialize-settings]") |> render_click()

    assert has_element?(view, ".setup-checklist", "Finish setup")
    assert has_element?(view, "a[href='/settings/slack']", "Continue")
    assert {:ok, %{installation: %{revision: 1}}} = Settings.fetch()
  end

  test "each focused settings page has one title and system evidence stays collapsed",
       context do
    for {prepare, path, title} <- [
          {fn -> :ok end, "/settings", "Finish setup"},
          {fn -> initialize!() end, "/settings", "Settings"},
          {fn -> :ok end, "/settings/slack", "Slack"},
          {fn -> :ok end, "/settings/github", "GitHub"},
          {fn -> :ok end, "/settings/emisar", "Emisar"},
          {fn -> :ok end, "/settings/retention", "Retention"},
          {fn -> :ok end, "/settings/token-rates", "Token rates"},
          {fn -> :ok end, "/settings/system", "System"}
        ] do
      prepare.()
      {:ok, _view, html} = open(path)
      document = LazyHTML.from_document(html)
      headings = LazyHTML.query(document, "main h1")
      assert Enum.count(headings) == 1, title
      assert LazyHTML.text(headings) == title

      assert LazyHTML.query(document, "main header.page-header > .page-heading > h1")
             |> Enum.count() == 1

      matching_headings =
        document
        |> LazyHTML.query("main h1, main h2")
        |> Enum.count(&(LazyHTML.text(&1) == title))

      assert matching_headings == 1, "#{path} repeats the page title inside its content"
    end

    document = open("/settings/system") |> elem(2) |> LazyHTML.from_document()
    assert Enum.count(LazyHTML.query(document, "main details.system-evidence")) == 1
    assert Enum.count(LazyHTML.query(document, "main .configuration-evidence")) == 1

    assert Enum.empty?(
             LazyHTML.query(
               document,
               "main .settings-effective form, main .settings-effective button"
             )
           )

    Agent.update(context.unavailable, fn _ -> true end)
    {:ok, _view, html} = open()
    assert html =~ "Settings unavailable"
    unavailable = LazyHTML.from_document(html)
    assert LazyHTML.query(unavailable, "main h1") |> LazyHTML.text() == "Settings unavailable"
  end

  test "setup keeps optional integrations quiet and GitHub access is derived from the repository" do
    initialize!()
    {:ok, settings, _html} = open("/settings")

    assert has_element?(settings, ".setup-optional-link", "Connect Emisar")
    refute has_element?(settings, ".setup-checklist .setup-optional")
    refute has_element?(settings, ".setup-optional-link .ui-button")

    {:ok, connections, html} = open("/settings/github")
    refute has_element?(connections, "input[name='connection[operator_login]']")
    assert has_element?(connections, ".github-connection-form fieldset", "GitHub App")
    refute html =~ "GitHub operator"

    for {path, title} <- [
          {"/settings/slack", "Slack"},
          {"/settings/github", "GitHub"},
          {"/settings/emisar", "Emisar"}
        ] do
      {:ok, page, _html} = open(path)
      assert has_element?(page, "main h1", title)
    end

    {:ok, emisar, _html} = open("/settings/emisar")
    assert has_element?(emisar, "form[phx-submit=connect-emisar]", "Connect account")
    refute has_element?(emisar, ".integration-panel details form[phx-submit=connect-emisar]")
    refute has_element?(emisar, "input[name='connection[ref]']")
    refute has_element?(emisar, "input[name='connection[display_name]']")

    assert get(build_conn() |> Map.put(:host, "localhost"), "/settings/connections").status == 404

    {:ok, repositories, _html} = open("/repositories")
    assert has_element?(repositories, ".repository-import", "Add repositories")

    assert has_element?(
             repositories,
             ".repository-import a[href='/settings/github']",
             "Connect GitHub"
           )
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

    refute has_element?(
             repositories,
             ".repository-import button[phx-click=discover-github-repositories]"
           )

    assert has_element?(
             repositories,
             ".repository-import a[href='/settings/github']",
             "Repair GitHub connection"
           )

    {:ok, github, _html} = open("/settings/github")
    assert has_element?(github, "h2", "Repair GitHub connection")
    refute has_element?(github, "h2", "GitHub App verified")
  end

  test "Emisar routing uses named scopes and supports stopping and resuming new work" do
    initialize!()
    snapshot = Settings.fetch!()

    {:ok, snapshot} =
      Settings.put_repository(
        %{ref: "payments", display_name: "Payments"},
        snapshot.installation.revision,
        @actor
      )

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

    {:ok, view, _html} = open("/settings/emisar")

    assert has_element?(
             view,
             "select[name='binding[scope]'] option[value='repository:payments']",
             "Payments"
           )

    refute has_element?(view, "input[name='binding[scope_ref]']")
    assert has_element?(view, "button[phx-click=enable-emisar]", "Resume")

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

    refute has_element?(view, ".integration-account-list form")
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

  test "shortening a retention horizon names what it would expose before it is applied" do
    initialize!()
    {:ok, view, _html} = open("/settings/retention")

    view
    |> form("#settings-retention-form", %{"operational_data_seconds" => "7"})
    |> render_submit()

    assert has_element?(view, ".settings-impact", "Shortening a horizon")
    assert Settings.fetch!().retention.operational_data_seconds == 30 * @day

    view |> element("#settings-retention button[phx-click=confirm]") |> render_click()

    assert Settings.fetch!().retention.operational_data_seconds == 7 * @day
    assert has_element?(view, "[role=status]", "Saved. Revision 2.")
  end

  test "a token rate is added, corrected and removed at the revision it was read at" do
    initialize!()
    {:ok, view, _html} = open("/settings/token-rates")

    assert has_element?(view, ".settings-rows td[data-label='Execution target'] .cell-value")

    assert has_element?(
             view,
             ".settings-rows td[data-label='Where this rate came from'] .cell-value"
           )

    assert has_element?(
             view,
             "#settings-pricing > button.settings-editor-add",
             "+ Add token rate"
           )

    view |> element("#settings-pricing > button.settings-editor-add") |> render_click()

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

    view
    |> element(~s{tr[data-item="#{rate.id}"] button[phx-click=select-item]})
    |> render_click()

    assert has_element?(
             view,
             "#settings-pricing .settings-editor-heading",
             "Edit token rate"
           )

    view
    |> form("#settings-pricing-form", %{"output_usd_per_million" => "12"})
    |> render_submit()

    corrected = Enum.find(Settings.fetch!().pricing_rates, &(&1.id == rate.id))
    assert Decimal.equal?(corrected.output_usd_per_million, Decimal.new("12"))
    assert corrected.id == rate.id
    assert corrected.revision == 2

    view
    |> element(~s{tr[data-item="#{rate.id}"] button[phx-click=delete-item]})
    |> render_click()

    refute Enum.any?(Settings.fetch!().pricing_rates, &(&1.id == rate.id))
    assert length(Settings.fetch!().pricing_rates) == 3
    assert Settings.fetch!().installation.revision == 4
  end

  test "an unreadable settings database is not an installation without settings", context do
    initialize!()
    Agent.update(context.unavailable, fn _ -> true end)

    {:ok, view, html} = open()

    assert html =~ "Settings unavailable"
    refute has_element?(view, "#settings-slack-form")
    refute html =~ "Set up this installation"
    assert Repo.aggregate(Installation, :count) == 1
  end

  test "a half-migrated settings database reads as unavailable, not as a fresh install" do
    initialize!()
    Repo.delete_all(Ryker.Settings.Slack)

    {:ok, view, html} = open()

    assert html =~ "Settings unavailable"
    refute html =~ "Create this installation"
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

  defp open(path \\ "/settings"),
    do: live(build_conn() |> Map.put(:host, "localhost"), path)

  defp initialize! do
    {:ok, snapshot} = Settings.initialize(@actor)
    snapshot
  end
end
