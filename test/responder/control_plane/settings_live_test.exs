defmodule Responder.ControlPlane.SettingsLiveTest do
  use Responder.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Responder.ControlPlane.{Actions, Endpoint, Projection}
  alias Responder.Settings
  alias Responder.Settings.{Installation, PricingRate}

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
       pubsub_server: Responder.ControlPlane.PubSub,
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

  test "an installation that already holds product history is told to import, not re-keyed" do
    # Creating a second identity here would re-key worker, delivery and
    # publication custody that the existing history belongs to.
    assert {:ok, _} = Responder.Instructions.save(:global, "Existing guidance", 0, @actor)

    {:ok, view, _html} = open()
    view |> element("button[phx-click=initialize-settings]") |> render_click()

    assert has_element?(view, "[role=alert]", "already holds product history")
    assert Repo.aggregate(Installation, :count) == 0
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

  defp open, do: live(build_conn() |> Map.put(:host, "localhost"), "/configuration")

  defp initialize! do
    {:ok, snapshot} = Settings.initialize(@actor)
    snapshot
  end
end
