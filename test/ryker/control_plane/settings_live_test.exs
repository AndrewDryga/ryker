defmodule Ryker.ControlPlane.SettingsLiveTest do
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Actions, Endpoint, Projection}
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
    assert html =~ "Set up this installation"
    refute has_element?(view, "#settings-slack-form")

    view |> element("button[phx-click=initialize-settings]") |> render_click()

    assert has_element?(view, "#settings-slack-form")
    assert has_element?(view, "[role=status]", "has not applied this revision yet")
    assert {:ok, %{installation: %{revision: 1}}} = Settings.fetch()
  end

  test "the settings page shows its title once with saved and running revisions beneath, and the effective configuration once",
       context do
    # Before 2026-09-13 the page drew its own 30px "Settings" h1 inside a
    # header the base stylesheet styles as a sticky dark bar, and the
    # effective-configuration section rendered an "Effective host
    # configuration" h2 with an intro immediately above a body that opened
    # with the same h2 and a second intro. Every state of the page — setup,
    # unavailable, editable — now has exactly one title.
    for {prepare, marker} <- [
          {fn -> :ok end, "Set up this installation"},
          {fn -> initialize!() end, "Saved revision"}
        ] do
      prepare.()
      {:ok, _view, html} = open()
      document = LazyHTML.from_document(html)
      headings = LazyHTML.query(document, "main h1")
      assert Enum.count(headings) == 1, marker
      assert LazyHTML.text(headings) == "Settings"

      assert LazyHTML.query(document, "main header.page-header > .page-heading > h1")
             |> Enum.count() ==
               1

      assert LazyHTML.query(document, "main header.page-header p.page-description")
             |> LazyHTML.text() =~
               "What this installation decided"

      assert html =~ marker
      refute html =~ "settings-status\"><h1"
    end

    document = open() |> elem(2) |> LazyHTML.from_document()
    status = LazyHTML.query(document, "main .settings-status dt") |> LazyHTML.text()
    assert status =~ "Saved revision"
    assert status =~ "Running revision"

    assert LazyHTML.query(document, "main h2")
           |> LazyHTML.text()
           |> String.split("Effective host configuration")
           |> length() == 2

    assert Enum.count(
             LazyHTML.query(document, "main .settings-effective .configuration-evidence")
           ) == 1

    assert Enum.empty?(
             LazyHTML.query(
               document,
               "main .settings-effective form, main .settings-effective button"
             )
           )

    Agent.update(context.unavailable, fn _ -> true end)
    {:ok, _view, html} = open()
    assert html =~ "Settings could not be read"
    unavailable = LazyHTML.from_document(html)
    assert LazyHTML.query(unavailable, "main h1") |> LazyHTML.text() == "Settings"

    assert LazyHTML.query(unavailable, "main .settings-unavailable h2") |> LazyHTML.text() ==
             "Settings could not be read"
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

  test "a refused save keeps every typed value and names the field that refused it" do
    initialize!()
    {:ok, view, _html} = open()

    view |> form("#settings-slack-form", %{"enabled" => "true"}) |> render_submit()

    assert has_element?(view, ".settings-error", "Workspace ID is required before this can be")
    assert has_element?(view, "#settings-slack-enabled[checked]")
    assert Settings.fetch!().slack.enabled == false
    assert Settings.fetch!().installation.revision == 1
  end

  test "a save that lost the race shows what is saved now and never overwrites it silently" do
    initialize!()
    {:ok, view, _html} = open()
    view |> form("#settings-slack-form", %{"channel_prefix" => "ops"}) |> render_change()

    assert {:ok, _} = Settings.save_slack(%{channel_prefix: "sec"}, 1, @actor)

    view |> form("#settings-slack-form", %{"channel_prefix" => "ops"}) |> render_submit()

    assert has_element?(view, "[role=alert]", "changed since you started editing")
    assert has_element?(view, ".settings-conflict dd", "sec")
    assert has_element?(view, "#settings-slack-channel_prefix[value=ops]")
    assert Settings.fetch!().slack.channel_prefix == "sec"

    view |> element("#settings-slack button[phx-click=review-current]") |> render_click()
    view |> form("#settings-slack-form", %{"channel_prefix" => "ops"}) |> render_submit()

    assert Settings.fetch!().slack.channel_prefix == "ops"
    assert Settings.fetch!().installation.revision == 3
  end

  test "shortening a retention horizon names what it would expose before it is applied" do
    initialize!()
    {:ok, view, _html} = open()

    view
    |> form("#settings-retention-form", %{"operational_data_seconds" => "7"})
    |> render_submit()

    assert has_element?(view, ".settings-impact", "Shortening a horizon")
    assert Settings.fetch!().retention.operational_data_seconds == 30 * @day

    view |> element("#settings-retention button[phx-click=confirm]") |> render_click()

    assert Settings.fetch!().retention.operational_data_seconds == 7 * @day
    assert has_element?(view, "[role=status]", "Saved. Revision 2.")
  end

  test "a save in another section does not turn this draft into a conflict" do
    # The installation has one revision, so every save moves it. A draft whose
    # own section did not change is not stale, and saying it is would make
    # editing two sections in one sitting a fight.
    initialize!()
    {:ok, view, _html} = open()
    view |> form("#settings-slack-form", %{"channel_prefix" => "ops"}) |> render_change()

    view |> form("#settings-learning-form", %{"enabled" => "true"}) |> render_submit()
    assert Settings.fetch!().learning.enabled

    view |> form("#settings-slack-form", %{"channel_prefix" => "ops"}) |> render_submit()

    refute has_element?(view, "[role=alert]")
    assert Settings.fetch!().slack.channel_prefix == "ops"
    assert Settings.fetch!().installation.revision == 3
  end

  test "a live refresh never overwrites an unsaved draft" do
    initialize!()
    {:ok, view, _html} = open()
    view |> form("#settings-slack-form", %{"channel_prefix" => "ops"}) |> render_change()

    render_click(view, "refresh")

    assert has_element?(view, "#settings-slack-channel_prefix[value=ops]")
    assert Settings.fetch!().slack.channel_prefix == "ems"
  end

  test "a token rate is added, corrected and removed at the revision it was read at" do
    initialize!()
    {:ok, view, _html} = open()

    view
    |> form("#settings-pricing-form", %{
      "execution_target" => "gpt-5.6-sol",
      "input_usd_per_million" => "1.25",
      "cached_input_usd_per_million" => "0.13",
      "output_usd_per_million" => "10",
      "effective_from" => "2026-09-01",
      "provenance" => "provider price list"
    })
    |> render_submit()

    assert [%PricingRate{} = rate] = Settings.fetch!().pricing_rates
    assert Decimal.equal?(rate.input_usd_per_million, Decimal.new("1.25"))
    assert rate.revision == 2

    view
    |> element(~s{tr[data-item="#{rate.id}"] button[phx-click=select-item]})
    |> render_click()

    view
    |> form("#settings-pricing-form", %{"output_usd_per_million" => "12"})
    |> render_submit()

    assert [corrected] = Settings.fetch!().pricing_rates
    assert Decimal.equal?(corrected.output_usd_per_million, Decimal.new("12"))
    assert corrected.id == rate.id
    assert corrected.revision == 2

    view
    |> element(~s{tr[data-item="#{rate.id}"] button[phx-click=delete-item]})
    |> render_click()

    assert Settings.fetch!().pricing_rates == []
    assert Settings.fetch!().installation.revision == 4
  end

  test "an unreadable settings database is not an installation without settings", context do
    initialize!()
    Agent.update(context.unavailable, fn _ -> true end)

    {:ok, view, html} = open()

    assert html =~ "Settings could not be read"
    refute has_element?(view, "#settings-slack-form")
    refute html =~ "Set up this installation"
    assert Repo.aggregate(Installation, :count) == 1
  end

  test "a half-migrated settings database reads as unavailable, not as a fresh install" do
    initialize!()
    Repo.delete_all(Ryker.Settings.Slack)

    {:ok, view, html} = open()

    assert html =~ "Settings could not be read"
    refute html =~ "Set up this installation"
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

  defp open, do: live(build_conn() |> Map.put(:host, "localhost"), "/configuration")

  defp initialize! do
    {:ok, snapshot} = Settings.initialize(@actor)
    snapshot
  end
end
