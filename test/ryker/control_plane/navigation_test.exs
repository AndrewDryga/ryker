defmodule Ryker.ControlPlane.NavigationTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{Layouts, Navigation}

  test "the sidebar names each place for what it holds" do
    # Andrew, 2026-09-24: twenty pages sat behind four folding groups whose
    # names (Work environment, Waits, Guidance beside Instructions beside
    # Preferences) made people learn Ryker's internals before finding
    # anything. There are six places now; the ones with several pages fold.
    for live <- [true, false], component <- [&Navigation.sidebar/1, &Navigation.mobile/1] do
      document =
        component |> render_component(path: "/rules", live: live) |> LazyHTML.from_fragment()

      for {path, title} <- [
            {"/environments", "Environments"},
            {"/channels", "Channels"},
            {"/repositories", "Repositories"},
            {"/working-copies", "Working copies"},
            {"/rules", "Rules"},
            {"/schedules", "Schedules"},
            {"/follow-ups", "Follow-ups"},
            {"/instructions", "Instructions"},
            {"/memory", "Facts"},
            {"/memory/learned", "Learned"},
            {"/memory/findings", "Findings"},
            {"/memory/learning", "Learning"}
          ] do
        assert document |> LazyHTML.query("a[href='#{path}']") |> LazyHTML.text() =~ title
      end
    end
  end

  test "the Work group holds where Ryker works, environments first" do
    # Andrew, 2026-09-25: channels choose an environment, not a repository,
    # so the place that says what an environment holds leads the pages about
    # where Ryker works, before the channels that choose one.
    for live <- [true, false] do
      document =
        render_component(&Navigation.sidebar/1, path: "/environments", live: live)
        |> LazyHTML.from_fragment()

      work = LazyHTML.query(document, "nav[aria-label='Manage Ryker'] details#nav-grid")
      assert LazyHTML.query(work, "summary") |> LazyHTML.text() |> String.trim() == "Work"
      assert LazyHTML.attribute(work, "open") == [""]

      assert LazyHTML.query(work, "a") |> LazyHTML.attribute("href") ==
               ~w(/environments /channels /repositories /working-copies)

      assert LazyHTML.query(work, "a[aria-current=page]") |> LazyHTML.text() == "Environments"

      mobile =
        render_component(&Navigation.mobile/1, path: "/", live: live)
        |> LazyHTML.from_fragment()

      assert mobile |> LazyHTML.query("section strong") |> Enum.map(&LazyHTML.text/1) |> hd() ==
               "Work"
    end
  end

  test "integrations and settings are two groups at the bottom of the sidebar" do
    # Andrew, 2026-09-24: "Split settings into settings and integrations."
    # One Settings group held nine pages, from the Slack connection to model
    # prices; connecting a service and tuning Ryker are different jobs.
    for live <- [true, false] do
      document =
        render_component(&Navigation.sidebar/1, path: "/", live: live)
        |> LazyHTML.from_fragment()

      navs = LazyHTML.query(document, "nav.app-nav")

      assert Enum.map(navs, &(LazyHTML.attribute(&1, "aria-label") |> hd())) == [
               "Main navigation",
               "Manage Ryker",
               "Integrations and settings"
             ]

      bottom = LazyHTML.query(document, "nav[aria-label='Integrations and settings']")

      assert LazyHTML.query(bottom, "summary") |> Enum.map(&String.trim(LazyHTML.text(&1))) ==
               ["Integrations", "Settings"]

      assert LazyHTML.query(bottom, "details#nav-plug a") |> LazyHTML.attribute("href") ==
               ~w(/integrations /integrations/slack /integrations/github /integrations/emisar /integrations/webhooks)

      assert LazyHTML.query(bottom, "details#nav-settings a") |> LazyHTML.attribute("href") ==
               ~w(/settings/models /settings/retention /settings/prices /settings/advanced)

      mobile =
        render_component(&Navigation.mobile/1, path: "/", live: live)
        |> LazyHTML.from_fragment()

      groups = LazyHTML.query(mobile, "section strong") |> Enum.map(&LazyHTML.text/1)
      assert Enum.take(groups, -2) == ["Integrations", "Settings"]

      for removed <-
            ~w(/settings /settings/slack /settings/github /settings/emisar /settings/webhooks) do
        for rendered <- [document, mobile] do
          refute removed in (LazyHTML.query(rendered, "a") |> LazyHTML.attribute("href"))
        end
      end
    end
  end

  test "the way back into setup leads to /setup only while required steps are open" do
    for live <- [true, false] do
      open = %{done: 2, total: 6}

      sidebar =
        render_component(&Navigation.sidebar/1, path: "/", live: live, setup: open)
        |> LazyHTML.from_fragment()

      shortcut = LazyHTML.query(sidebar, "a.setup-shortcut")
      assert LazyHTML.attribute(shortcut, "href") == ["/setup"]

      assert shortcut |> LazyHTML.text() |> String.split() |> Enum.join(" ") ==
               "Finish setup 2 of 6 steps done"

      unread =
        render_component(&Navigation.sidebar/1,
          path: "/",
          live: live,
          setup: %{done: nil, total: 6}
        )

      assert unread =~ "Continue the setup"

      mobile =
        render_component(&Navigation.mobile/1, path: "/", live: live, setup: open)
        |> LazyHTML.from_fragment()

      assert LazyHTML.query(mobile, "a.mobile-setup-shortcut") |> LazyHTML.attribute("href") ==
               ["/setup"]

      for component <- [&Navigation.sidebar/1, &Navigation.mobile/1] do
        done = render_component(component, path: "/", live: live, setup: nil)
        refute done =~ "Finish setup"
        refute done =~ ~s(href="/setup")
      end
    end
  end

  test "a place's own page is selected, not its siblings" do
    for {path, selected} <- [
          {"/memory", "/memory"},
          {"/memory/learned", "/memory/learned"},
          {"/integrations", "/integrations"},
          {"/integrations/slack", "/integrations/slack"},
          {"/settings/models", "/settings/models"},
          {"/environments", "/environments"},
          {"/channels/T1/C1", "/channels"},
          {"/schedules/schedule%3Aone", "/schedules"}
        ] do
      document =
        render_component(&Navigation.sidebar/1, path: path, live: true)
        |> LazyHTML.from_fragment()

      assert document |> LazyHTML.query("a[aria-current=page]") |> LazyHTML.attribute("href") ==
               [selected]
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

  test "incident rooms keep selected navigation on both their list and detail routes" do
    # The primary sidebar becomes the compact primary navigation on mobile;
    # mobile/1 supplies only the separate More menu.
    for path <- ["/incident-rooms", "/incident-rooms/incident%3Aone"], live <- [true, false] do
      document =
        render_component(&Navigation.sidebar/1, path: path, live: live)
        |> LazyHTML.from_fragment()

      link = LazyHTML.query(document, "a[href='/incident-rooms'][aria-current=page]")
      assert LazyHTML.text(link) == "Incident rooms"
      assert LazyHTML.query(document, "a[href='/incidents']") |> Enum.empty?()
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
      refute html =~ "Execution"
      assert html =~ "Activity"

      document = LazyHTML.from_document(html)

      assert document |> LazyHTML.query("a[aria-current=page]") |> LazyHTML.attribute("href") == [
               "/failures"
             ]

      for path <-
            ~w(/ /incident-rooms /failures /usage /conversations /schedules /follow-ups /memory /memory/findings /integrations /integrations/slack /integrations/github /integrations/emisar /integrations/webhooks /settings/models /settings/retention /settings/prices /settings/advanced /environments /channels /repositories /working-copies) do
        assert path in (document |> LazyHTML.query("a") |> LazyHTML.attribute("href"))
      end

      for removed <- ["/decisions", "/calibration", "/card-lab", "/manual-tests", "/lab"] do
        refute removed in (document |> LazyHTML.query("a") |> LazyHTML.attribute("href"))
      end
    end
  end

  test "Chat is the first primary destination without Lab phrasing" do
    for live <- [true, false],
        path <- ["/conversations", "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"] do
      html = render_component(&Navigation.sidebar/1, path: path, live: live)
      document = LazyHTML.from_document(html)
      links = LazyHTML.query(document, "nav[aria-label='Main navigation'] a")
      assert LazyHTML.attribute(links, "href") |> Enum.take(2) == ["/conversations", "/"]

      assert document
             |> LazyHTML.query(
               "nav[aria-label='Main navigation'] a[href='/conversations'][aria-current=page]"
             )
             |> LazyHTML.text() == "Chat"

      refute html =~ ~r/\bLab\b/
      refute html =~ "/lab"
      refute render_component(&Navigation.mobile/1, path: path, live: live) =~ ~r/\bLab\b/
    end
  end

  test "the Testing group is gone from desktop and mobile navigation" do
    # Slack Card Lab and Test journeys were retired on 2026-09-13; the group
    # that held them must not survive as an empty header or a replacement
    # catalog. The conversation page moves into the primary navigation so it
    # stays reachable on the compact mobile row as well as the desktop rail.
    for live <- [true, false] do
      sidebar = render_component(&Navigation.sidebar/1, path: "/conversations", live: live)
      document = LazyHTML.from_document(sidebar)
      refute LazyHTML.query(document, ".nav-caption") |> LazyHTML.text() =~ "Testing"
      refute LazyHTML.query(document, "nav[aria-label='Testing']") |> Enum.any?()
      refute sidebar =~ "testing-nav"

      assert document
             |> LazyHTML.query(
               "nav[aria-label='Main navigation'] a[href='/conversations'][aria-current=page]"
             )
             |> Enum.any?()

      mobile = render_component(&Navigation.mobile/1, path: "/conversations", live: live)
      mobile_document = LazyHTML.from_document(mobile)
      refute LazyHTML.query(mobile_document, "section strong") |> LazyHTML.text() =~ "Testing"

      for retired <- ["/card-lab", "/manual-tests"] do
        refute retired in (document |> LazyHTML.query("a") |> LazyHTML.attribute("href"))
        refute retired in (mobile_document |> LazyHTML.query("a") |> LazyHTML.attribute("href"))
      end
    end
  end

  test "mobile navigation retains setup tools without profile controls" do
    html = render_component(&Navigation.mobile/1, path: "/integrations", live: true)
    links = html |> LazyHTML.from_document() |> LazyHTML.query("a") |> LazyHTML.attribute("href")

    for path <-
          ~w(/integrations /integrations/slack /integrations/github /integrations/emisar /integrations/webhooks /settings/models /environments /channels /repositories /memory /schedules /follow-ups /working-copies) do
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
