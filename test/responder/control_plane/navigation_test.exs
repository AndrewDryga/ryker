defmodule Responder.ControlPlane.NavigationTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Responder.ControlPlane.{Layouts, Navigation}

  test "standing rules preferences and guidance have named desktop and mobile destinations" do
    # These working capabilities were only discoverable in a generic Behaviors table.
    for live <- [true, false], component <- [&Navigation.sidebar/1, &Navigation.mobile/1] do
      html = render_component(component, path: "/rules", live: live)
      document = LazyHTML.from_fragment(html)

      for {path, title} <- [
            {"/rules", "Standing rules"},
            {"/preferences", "Preferences"},
            {"/guidance", "Guidance"}
          ] do
        assert document |> LazyHTML.query("a[href='#{path}']") |> LazyHTML.text() == title
      end
    end
  end

  test "the removed audit page is absent from live and HTTP navigation" do
    # The standalone audit feed duplicated request history without useful actions.
    for live <- [true, false], component <- [&Navigation.sidebar/1, &Navigation.mobile/1] do
      html = render_component(component, path: "/", live: live)
      refute html =~ "href=\"/audit\""
      refute html =~ "Audit trail"
    end
  end

  test "navigation contains real operator destinations without invented accounts or workspaces" do
    # The template's fake profile and connected workspace looked like features
    # despite having no account, tenancy or presence contract behind them.
    for live <- [true, false] do
      html = render_component(&Navigation.sidebar/1, path: "/failures", live: live)
      refute html =~ "Local operator"
      refute html =~ "Local workspace"
      refute html =~ "Connected to your runtime"
      refute html =~ "Loopback access only"
      refute html =~ "operator-identity"
      assert html =~ "Execution"
      assert html =~ "Testing"
      assert html =~ "Requests"

      document = LazyHTML.from_document(html)

      assert document |> LazyHTML.query("a[aria-current=page]") |> LazyHTML.attribute("href") == [
               "/failures"
             ]

      for path <-
            ~w(/ /incidents /failures /usage /lab /card-lab /manual-tests /schedules /subscriptions /memory /decisions /findings /calibration /configuration /channels /repositories /workspaces) do
        assert path in (document |> LazyHTML.query("a") |> LazyHTML.attribute("href"))
      end
    end
  end

  test "mobile navigation retains testing and setup tools without profile controls" do
    html = render_component(&Navigation.mobile/1, path: "/card-lab", live: true)
    links = html |> LazyHTML.from_document() |> LazyHTML.query("a") |> LazyHTML.attribute("href")

    for path <-
          ~w(/lab /card-lab /manual-tests /configuration /channels /repositories /memory /schedules /subscriptions /workspaces) do
      assert path in links
    end

    refute html =~ "operator-identity"
  end

  test "confirmed HTTP actions have one title and no fabricated account chrome" do
    html =
      render_component(&Layouts.static/1, title: "Retry delivery", body: "Retained action review")

    refute html =~ "app-breadcrumb"
    refute html =~ "app-topbar"
    refute html =~ "Local operator"
    assert html =~ "Retained action review"

    assert html |> LazyHTML.from_document() |> LazyHTML.query("h1") |> LazyHTML.text() ==
             "Retry delivery"
  end
end
