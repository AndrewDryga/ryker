defmodule Ryker.ControlPlane.LiveTest do
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{BehaviorLibrary, ConversationLab, LiveSocket, Projection}
  alias Ryker.ControlPlane.LabPage
  alias Ryker.ControlPlane.WorkbenchLive
  alias Ryker.Fixtures.SavedEntities
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.WorkProfile

  alias Ryker.ControlPlane.Endpoint
  alias Ryker.Episodes.Reactions

  @endpoint Endpoint

  setup do
    observer = self()
    {:ok, counters} = Agent.start_link(fn -> %{active: 1} end)

    options = %{
      actions: %{},
      csrf_secret: String.duplicate("s", 32),
      observability: %{},
      projection:
        Map.merge(Projection.callbacks(), %{
          overview: fn ->
            counts = Agent.get(counters, & &1)
            if counts[:fail], do: raise("sensitive provider exception body")
            send(observer, {:overview_projected, counts.active})
            %{counts: counts, needs_attention: []}
          end,
          lab_index: fn ->
            items = Projection.lab_index()
            send(observer, {:lab_projected, Enum.sum(Enum.map(items, & &1.message_count))})
            items
          end,
          activity: fn params ->
            %{items: [], total: 0, page: 1, pages: 1, mode: params["mode"] || "live"}
          end,
          episode: fn ref, params ->
            if Agent.get(counters, & &1[:episode_fail]),
              do: {:error, :database_unavailable},
              else: Projection.episode(ref, params)
          end,
          schedules: fn _params -> [] end,
          behaviors: fn kind, params ->
            if Agent.get(counters, & &1[:behaviors_fail]),
              do: raise("sensitive provider exception body"),
              else: BehaviorLibrary.list(kind, params)
          end
        })
    }

    start_supervised!(
      {Endpoint,
       [
         server: false,
         secret_key_base: String.duplicate("s", 64),
         pubsub_server: Ryker.ControlPlane.PubSub,
         live_view: [signing_salt: "control-plane-test"],
         check_origin: ["//localhost:4321"],
         url: [host: "localhost", port: 4321],
         control_plane: options
       ]}
    )

    %{counters: counters}
  end

  test "a connected control plane reflects committed-state notifications without navigation", %{
    counters: counters
  } do
    conn = build_conn() |> Map.put(:host, "localhost")
    assert {:ok, view, html} = live(conn, "/")
    assert html =~ "Activity"
    assert html =~ "No activity yet"
    refute html =~ "class=\"metric\""
    assert has_element?(view, "[data-connection-state=connected]")
    assert has_element?(view, "[data-active-count]", "1")

    Agent.update(counters, &Map.put(&1, :active, 7))

    Phoenix.PubSub.broadcast(
      Ryker.ControlPlane.PubSub,
      "control-plane",
      :control_plane_changed
    )

    # Same debounce-plus-projection wait as the Lab stream below; same guard.
    assert_receive {:overview_projected, 7}, 2_000
    assert has_element?(view, "[data-active-count]", "7")
  end

  test "instruction libraries are live navigable and keep visible filters after reconciliation" do
    for {path, title} <- [
          {"/rules", "Standing rules"},
          {"/preferences", "Preferences"},
          {"/guidance", "Guidance"}
        ] do
      {:ok, view, html} =
        live(
          build_conn() |> Map.put(:host, "localhost"),
          path <> "?q=emisar&status=all&scope=repository"
        )

      assert html =~ title
      assert has_element?(view, "input[name=q][value=emisar]")
      assert has_element?(view, "select[name=status] option[value=all][selected]")
      send(view.pid, :reconcile)
      assert has_element?(view, "input[name=q][value=emisar]")
      assert has_element?(view, "select[name=scope] option[value=repository][selected]")
    end

    {:ok, view, _} = live(build_conn() |> Map.put(:host, "localhost"), "/rules?q[x]=1&page[x]=2")
    assert has_element?(view, ".behavior-library")
    refute has_element?(view, ".document-unavailable")
  end

  test "the live shell shows a configuration page's title once, its description beneath, then one column" do
    # The Standing rules screenshot Andrew sent on 2026-09-09: three 30px
    # status counts in a flex row with the creation help pushed to the right
    # by margin-left:auto, an Apply button, and the total buried inside the
    # pagination line. The approved order is title, description, help
    # disclosure, toolbar, quiet count, entries, history — down one left
    # edge — and a routine reconcile must not disturb it.
    source = SavedEntities.source!("slack:T123:C456")

    SavedEntities.behavior!(
      source,
      :standing_assignment,
      %{
        "action" => "triage_alert",
        "expires_in" => "30d",
        "repository" => nil,
        "source_filter" => "human",
        "task" => "Watch Terraform applies and report readiness.",
        "trigger" => "operational_alert"
      },
      scope_ref: "slack:T123:C456"
    )

    {:ok, view, html} = live(build_conn() |> Map.put(:host, "localhost"), "/rules")
    document = LazyHTML.from_document(html)
    headings = LazyHTML.query(document, "main h1")
    assert Enum.count(headings) == 1
    assert LazyHTML.text(headings) == "Standing rules"

    assert Enum.count(LazyHTML.query(document, "main header.page-header > .page-heading > h1")) ==
             1

    assert LazyHTML.query(
             document,
             "main header.page-header > .page-heading + p.page-description"
           )
           |> LazyHTML.text() =~ "Instructions that run"

    assert outline(document, "main .secondary-page > *") == [
             "header.page-header",
             "div.behavior-library"
           ]

    assert outline(document, "main .behavior-library > *") == [
             "details.page-help",
             "form.filter-toolbar",
             "p.result-count",
             "div.behavior-entries",
             "section.behavior-history"
           ]

    assert has_element?(view, "main p.result-count", "1 rule")
    assert has_element?(view, "main .behavior-entry h2", "Operational alert")
    assert has_element?(view, "main .behavior-entry", "Watch Terraform applies")
    refute has_element?(view, ".behavior-counts, .behavior-overview, .secondary-page-title")
    refute has_element?(view, "form.filter-toolbar button:not(noscript button)")

    send(view.pid, :reconcile)
    assert has_element?(view, "main header.page-header h1", "Standing rules")
    assert has_element?(view, "main details.page-help summary", "How to add and manage rules")
  end

  test "filters live in the URL, so a shared or back-navigated address reproduces the list and changes nothing" do
    # The toolbar is a GET form: the address is the only filter state, so the
    # browser's Back button, a pasted link and a reconcile all show the same
    # rows. Changing a filter, opening the action menu and opening the Delete
    # confirmation are reads; the row they describe must be byte-for-byte the
    # row that was there before.
    source = SavedEntities.source!("slack:T123:C456")
    active = rule!(source, "Watch Terraform applies and report readiness.")
    archived = rule!(source, "Retired: page the old rota.", status: :deleted)
    before = Repo.get!(Ryker.State.Behavior, active.id)

    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _} = live(conn, "/rules?status=archived")
    assert has_element?(view, "select[name=status] option[value=archived][selected]")
    assert has_element?(view, "main .behavior-entry", "Retired: page the old rota.")
    refute has_element?(view, "main .behavior-entry", "Watch Terraform applies")
    assert has_element?(view, "main p.result-count", "1 rule")
    assert has_element?(view, "form.filter-toolbar a.filter-clear[href='/rules']")

    # Back: the previous address, nothing else, brings the previous list back.
    render_patch(view, "/rules")
    assert has_element?(view, "select[name=status] option[value=current][selected]")
    assert has_element?(view, "main .behavior-entry", "Watch Terraform applies")
    refute has_element?(view, "main .behavior-entry", "Retired: page the old rota.")
    refute has_element?(view, "form.filter-toolbar a.filter-clear")
    refute has_element?(view, "form.filter-toolbar input[name=page]")

    render_patch(view, "/rules?q=Terraform&status=all&scope=conversation&page=7")
    assert has_element?(view, "input[name=q][value=Terraform]")
    assert has_element?(view, "select[name=scope] option[value=conversation][selected]")
    assert has_element?(view, "main p.result-count", "1 rule")
    send(view.pid, :reconcile)
    assert has_element?(view, "main .behavior-entry", "Watch Terraform applies")

    # Opening the menu is a disclosure; opening Delete is its confirmation page.
    assert has_element?(view, "main .behavior-entry details.behavior-menu:not([open])")
    ref = URI.encode_www_form(active.ref)
    confirmation = get(conn, "/actions/behavior/#{ref}/deleted")
    assert confirmation.status == 200
    assert confirmation.resp_body =~ "Delete"
    assert Repo.get!(Ryker.State.Behavior, active.id) == before
    assert Repo.get!(Ryker.State.Behavior, archived.id).status == :deleted
  end

  test "current, all and archived statuses select the rows they name and count only what they show" do
    # BehaviorLibrary computes per-status counts before search and scope
    # filtering. The old page printed those as Active/Paused/Expired numbers
    # above a list they did not describe; the count under the toolbar must be
    # the size of the list under it for every status choice.
    source = SavedEntities.source!("slack:T123:C456")
    rule!(source, "Active rule one.")
    rule!(source, "Active rule two.")
    rule!(source, "Paused rule.", status: :disabled)
    rule!(source, "Deleted rule.", status: :deleted)
    rule!(source, "Superseded rule.", status: :superseded)
    rule!(source, "Expired rule.", expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
    conn = build_conn() |> Map.put(:host, "localhost")

    for {query, count, statuses} <- [
          {"", "3 rules", ["Active", "Active", "Paused"]},
          {"?status=current", "3 rules", ["Active", "Active", "Paused"]},
          {"?status=active", "2 rules", ["Active", "Active"]},
          {"?status=disabled", "1 rule", ["Paused"]},
          {"?status=expired", "1 rule", ["Expired"]},
          {"?status=archived", "2 rules", ["Deleted", "Superseded"]},
          {"?status=all", "6 rules",
           ["Active", "Active", "Paused", "Deleted", "Superseded", "Expired"]}
        ] do
      {:ok, _view, html} = live(conn, "/rules" <> query)
      document = LazyHTML.from_document(html)
      assert LazyHTML.query(document, "main p.result-count") |> LazyHTML.text() == count, query

      assert LazyHTML.query(document, "main .behavior-entry .behavior-heading .ui-status")
             |> LazyHTML.text()
             |> String.split(~r/(?<=[a-z])(?=[A-Z])/)
             |> Enum.sort() == Enum.sort(statuses),
             query

      assert Enum.count(LazyHTML.query(document, "main article.behavior-entry")) ==
               length(statuses),
             query
    end

    {:ok, _view, html} = live(conn, "/rules?status=all&q=Paused")
    document = LazyHTML.from_document(html)
    assert LazyHTML.query(document, "main p.result-count") |> LazyHTML.text() == "1 rule"
    assert Enum.count(LazyHTML.query(document, "main article.behavior-entry")) == 1
  end

  test "an empty filtered library is not a failed one, and a failed one is not empty", %{
    counters: counters
  } do
    # "No matching entries" invites the reader to change the filters; a
    # projection that could not run must not be presented as that, or the
    # reader concludes the rule they are looking for does not exist.
    source = SavedEntities.source!("slack:T123:C456")
    rule!(source, "Watch Terraform applies and report readiness.")
    conn = build_conn() |> Map.put(:host, "localhost")

    {:ok, empty, _} = live(conn, "/rules?q=nothing-here")
    assert has_element?(empty, "main .behavior-empty", "No matching entries")
    assert has_element?(empty, "main .behavior-empty", "Change the filters")
    assert has_element?(empty, "form.filter-toolbar a.filter-clear[href='/rules']")
    refute has_element?(empty, "main p.result-count")
    refute has_element?(empty, ".document-unavailable")
    refute has_element?(empty, ".app-warning", "could not refresh")

    Agent.update(counters, &Map.put(&1, :behaviors_fail, true))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, failed, _} = live(conn, "/rules?q=nothing-here")
        assert has_element?(failed, ".document-unavailable", "temporarily unavailable")
        assert has_element?(failed, ".app-warning", "could not refresh")
        refute has_element?(failed, ".behavior-empty")
        refute has_element?(failed, "main", "No matching entries")
        refute has_element?(failed, "main", "No standing rules yet")
      end)

    assert log =~ "category=RuntimeError"
    refute log =~ "sensitive provider exception body"
  end

  test "the twenty-sixth entry starts a second page and the count stays the filtered total" do
    # Twenty-five rows per page is the projection's contract. The page has
    # to show all twenty-five, say how many there are in total, and reach the
    # twenty-sixth through a link that keeps the current filters.
    source = SavedEntities.source!("slack:T123:C456")

    for index <- 1..26 do
      SavedEntities.behavior!(
        source,
        :guidance,
        %{
          "expires_in" => "30d",
          "repository" => nil,
          "scope" => "conversation",
          "subject" => "Guidance #{index}",
          "summary" => "Entry #{index}.",
          "text" => "Entry #{index}: lead with availability risk.",
          "visibility" => "conversation"
        },
        scope_ref: "slack:T123:C456",
        expires_at: nil
      )
    end

    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, html} = live(conn, "/guidance?status=current")
    document = LazyHTML.from_document(html)
    assert Enum.count(LazyHTML.query(document, "main article.behavior-entry")) == 25
    assert has_element?(view, "main p.result-count", "26 guidance entries")
    assert has_element?(view, "main nav.pagination", "Page 1 of 2")

    assert LazyHTML.query(document, "main nav.pagination a")
           |> LazyHTML.attribute("href") ==
             ["/guidance?page=2&q=&scope=&status=current"]

    render_patch(view, "/guidance?status=current&page=2")
    document = LazyHTML.from_document(render(view))
    assert Enum.count(LazyHTML.query(document, "main article.behavior-entry")) == 1
    assert has_element?(view, "main p.result-count", "26 guidance entries")
    assert has_element?(view, "main nav.pagination", "Page 2 of 2")
    assert has_element?(view, "main nav.pagination a[href*='page=1']", "Previous")

    render_patch(view, "/guidance?page=99")
    assert has_element?(view, "main nav.pagination", "Page 2 of 2")
    render_patch(view, "/guidance?page=abc")
    assert has_element?(view, "main nav.pagination", "Page 1 of 2")
  end

  test "a two-thousand-character rule reaches the page whole, and its open disclosures keep their ids across a refresh" do
    # The rule is the stored task. Between the row and the screen sit the
    # projection's sanitizer and the preview; neither may cut the text, and
    # the disclosure that holds it must keep the id PreserveReadingState uses
    # to reopen it after a reconcile, or every refresh folds the reader's
    # place shut.
    long =
      1..40
      |> Enum.map_join(
        "\n",
        &"Step #{&1}: compare the posted plan against the last apply and say so."
      )
      |> String.slice(0, 2_000)
      |> String.pad_trailing(2_000, "x")

    source = SavedEntities.source!("slack:T123:C456")
    rule = rule!(source, long)
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, html} = live(conn, "/rules")
    document = LazyHTML.from_document(html)

    full = LazyHTML.query(document, "main details.behavior-full")
    assert LazyHTML.attribute(full, "id") == ["behavior-#{rule.ref}-full"]
    assert LazyHTML.query(full, "p.behavior-instruction") |> LazyHTML.text() == long
    assert LazyHTML.query(document, "main p.behavior-preview") |> LazyHTML.text() =~ "Step 1:"

    send(view.pid, :reconcile)
    document = LazyHTML.from_document(render(view))

    assert LazyHTML.query(document, "main details.behavior-full") |> LazyHTML.attribute("id") == [
             "behavior-#{rule.ref}-full"
           ]

    assert LazyHTML.query(document, "main details.behavior-menu") |> LazyHTML.attribute("id") == [
             "behavior-#{rule.ref}-menu"
           ]

    assert LazyHTML.query(document, "main details.behavior-full p.behavior-instruction")
           |> LazyHTML.text() == long
  end

  test "malformed usage filters cannot crash navigation or search links" do
    # Nested URL values reached URI.encode_query as maps instead of scalars.
    for query <- [
          "usage_profile[x]=a",
          "usage_profile=x&usage_window[x]=a",
          "usage_profile=" <> String.duplicate("x", 513)
        ] do
      conn = build_conn() |> Map.put(:host, "localhost")
      assert {:ok, view, _html} = live(conn, "/activity?" <> query)
      assert render(view) =~ "Activity"
      view |> element("#activity-filters") |> render_change(%{"q" => "hello", "mode" => "live"})
      assert render(view) =~ "Activity"
    end
  end

  test "every searchable operator list keeps the search and exposes its supported status filter" do
    # Query-string status filters were invisible, and every refresh emptied search.
    for {path, status} <- [
          {"/incident-rooms", "blocked"},
          {"/schedules", "paused"},
          {"/subscriptions", "timed_out"},
          {"/channels", nil},
          {"/repositories", nil}
        ] do
      query = URI.encode_query(%{"q" => "emisar", "status" => status || ""})
      {:ok, view, _} = live(build_conn() |> Map.put(:host, "localhost"), path <> "?" <> query)
      assert has_element?(view, "form.filter-toolbar input[name=q][value=emisar]")
      assert has_element?(view, "form.filter-toolbar a[href='#{path}']", "Clear filters")

      if status,
        do: assert(has_element?(view, "select[name=status] option[value='#{status}'][selected]"))

      send(view.pid, :reconcile)
      assert has_element?(view, "form.filter-toolbar input[name=q][value=emisar]")
    end
  end

  test "usage drilldowns expose editable criteria and clearing one keeps the other filters" do
    # The old banner hid the selected profile, model and scope behind generic text.
    path = "/activity?mode=all&q=health&usage_profile=emisar&usage_model=&usage_window=30d"
    {:ok, view, _} = live(build_conn() |> Map.put(:host, "localhost"), path)

    assert has_element?(
             view,
             "#request-criteria input[name='criteria[usage_profile][value]'][value=emisar]"
           )

    assert has_element?(
             view,
             "#request-criteria select[name='criteria[usage_model][match]'] option[value=missing][selected]"
           )

    assert has_element?(view, ".usage-drilldown a.ui-button", "Back to Usage")
    assert has_element?(view, "#request-filter-add option[value=state]", "Request state")
    assert has_element?(view, "#request-filter-add option[value=usage_actor]", "Person")

    view
    |> element("#request-criteria")
    |> render_change(%{
      "criteria" => %{"usage_profile" => %{"match" => "equals", "value" => "personal"}}
    })

    render_click(view, "refresh")
    assert has_element?(view, "#criterion-usage_profile[value=personal]")

    view
    |> element("#request-criteria")
    |> render_submit(%{
      "criteria" => %{
        "usage_profile" => %{"match" => "equals", "value" => "personal"},
        "usage_model" => %{"match" => "any", "value" => ""},
        "usage_window" => %{"match" => "equals", "value" => "30d"}
      }
    })

    next = assert_patch(view)
    params = URI.decode_query(URI.parse(next).query)
    assert params["usage_profile"] == "personal"
    assert params["mode"] == "all"
    assert params["q"] == "health"
    assert params["usage_window"] == "30d"
    refute Map.has_key?(params, "usage_model")
    refute Map.has_key?(params, "page")
  end

  test "the LiveView endpoint preserves the loopback and host boundary" do
    conn = build_conn() |> Map.put(:host, "attacker.example") |> get("/")
    assert conn.status == 421

    conn =
      build_conn()
      |> Map.put(:host, "localhost")
      |> Map.put(:remote_ip, {203, 0, 113, 1})
      |> get("/")

    assert conn.status == 403

    # One guard for both paths: a live page and an HTTP-router answer carry
    # the same boundary headers. Until 2026-09-13 the HTTP router added
    # cross-origin-resource-policy from a header list of its own and the live
    # pages went without it.
    live = build_conn() |> Map.put(:host, "localhost") |> get("/")
    http = build_conn() |> Map.put(:host, "localhost") |> get("/never-a-page")
    assert live.status == 200
    assert http.status == 404

    for header <-
          ~w(cache-control content-security-policy cross-origin-resource-policy referrer-policy x-content-type-options x-ryker-version) do
      assert Plug.Conn.get_resp_header(live, header) != [], header
      assert Plug.Conn.get_resp_header(live, header) == Plug.Conn.get_resp_header(http, header)
    end
  end

  test "editing search preserves pending criteria but clearing all resets them" do
    {:ok, view, _} = live(build_conn() |> Map.put(:host, "localhost"), "/activity?q=old")
    render_change(view, "edit-request-filters", %{"add_filter" => "usage_profile"})

    render_change(view, "edit-request-filters", %{
      "criteria" => %{
        "usage_profile" => %{"match" => "equals", "value" => "emisar"}
      }
    })

    render_change(view, "search-activity", %{"q" => "new", "mode" => "all"})
    assert_patch(view, "/activity?mode=all&q=new")
    assert has_element?(view, "#criterion-usage_profile[value=emisar]")
    view |> element("a", "Clear all filters") |> render_click()
    assert_patch(view, "/activity")
    refute has_element?(view, "#criterion-usage_profile")
  end

  test "the execution console refreshes without a standing live toolbar" do
    {:ok, view, html} = live(build_conn() |> Map.put(:host, "localhost"), "/")
    refute html =~ "Local operator"
    refute html =~ "Local workspace"
    refute html =~ "app-breadcrumb"
    refute html =~ "Local, durable, yours"
    refute html =~ "empty-orbit"
    refute html =~ "empty-capabilities"
    refute html =~ "Test your ryker"
    assert has_element?(view, "h1", "Activity")
    refute has_element?(view, ".app-topbar")
    refute has_element?(view, "button[phx-click=toggle-live]")
    refute has_element?(view, "#live-controls")
    assert has_element?(view, ".connection-offline", "Reconnecting")
    assert has_element?(view, "#activity-filters")
  end

  test "native directory entry points and missing records remain usable across live navigation" do
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _} = live(conn, "/conversations")
    assert has_element?(view, ".lab-authority-note", "Local replies · real tools")
    assert has_element?(view, ".lab-authority-note", "repository and Emisar actions")
    assert has_element?(view, ".lab-authority-note a[href='/configuration']")

    for path <- [
          "/timeline/missing",
          "/timeline/ingress-input%3A#{Ecto.UUID.generate()}"
        ] do
      {:ok, missing, _} = live(conn, path)
      assert has_element?(missing, "a", "Back to activity")
    end
  end

  test "retired Card Lab and Test journeys routes cannot mount a live page or redirect" do
    # Retired 2026-09-13 as a clean cut. The live router used to own
    # /card-lab, /card-lab/:card/:state and /manual-tests; a compatibility
    # route here would quietly keep the specimen workbench and the
    # qualification checklist alive behind their old links.
    for path <- ["/card-lab", "/card-lab/task-card/working", "/manual-tests"] do
      conn = build_conn() |> Map.put(:host, "localhost") |> get(path)
      assert conn.status == 404, path
      assert Plug.Conn.get_resp_header(conn, "location") == []
      refute conn.resp_body =~ "data-phx-main"
      refute conn.resp_body =~ "specimen"
    end
  end

  test "the retired /lab routes cannot mount a live page or redirect" do
    # Renamed to /conversations on 2026-09-13 as a clean cut: an old /lab link
    # gets the ordinary 404, never a redirect that would keep two URL
    # families alive for the same retained conversation.
    id = Ecto.UUID.generate()

    for path <- ["/lab", "/lab/new", "/lab/#{id}"] do
      conn = build_conn() |> Map.put(:host, "localhost") |> get(path)
      assert conn.status == 404, path
      assert Plug.Conn.get_resp_header(conn, "location") == []
      refute conn.resp_body =~ "data-phx-main"
    end
  end

  test "Conversations is the primary navigation item and carries no Lab or test phrasing" do
    # The navigation, browser title, accessible labels and action labels said
    # Conversation Lab / Test a message / Send a test message; the surface is
    # an ordinary way to talk to the agent, not a test bench.
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, html} = live(conn, "/conversations")
    assert page_title(view) == "Conversations · Ryker"

    assert has_element?(
             view,
             ".app-sidebar nav[aria-label='Main navigation'] a[href='/conversations'][aria-current=page]",
             "Conversations"
           )

    [home, conversations | _rest] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(".app-sidebar nav[aria-label='Main navigation'] a")
      |> LazyHTML.attribute("href")

    assert home == "/"
    assert conversations == "/conversations"
    assert has_element?(view, ".lab-directory-heading h1", "Conversations")
    refute html =~ ~r/\bLab\b/
    refute html =~ "Test a "
    refute html =~ "test message"

    {:ok, home_view, home_html} = live(conn, "/")
    assert has_element?(home_view, "a[href='/conversations']", "New conversation")
    refute home_html =~ "Test a message"

    id = Ecto.UUID.generate()
    {:ok, open, open_html} = live(conn, "/conversations/#{id}")
    assert page_title(open) == "Conversations · Ryker"
    assert has_element?(open, ".app-sidebar a[href='/conversations'][aria-current=page]")
    assert has_element?(open, "form[action='/conversations/#{id}/messages']")
    assert has_element?(open, ".lab-directory-heading a[href='/conversations']", "New")
    refute open_html =~ ~r/\bLab\b/
    refute open_html =~ "test message"
  end

  test "the index is an empty draft that writes nothing until the first send, then follows it" do
    # The welcome page led to a second empty page before anyone could type.
    # /conversations now is the draft: a composer bound to a fresh identity,
    # no record behind it, and once the first message is durable the view moves
    # to that conversation instead of quietly posting the next message into it
    # from a page whose directory still says nothing is selected.
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, html} = live(conn, "/conversations")
    draft_id = composer_conversation(render(view))
    assert {:ok, ^draft_id} = Ecto.UUID.cast(draft_id)
    assert Projection.lab_conversation(draft_id) == :not_found
    assert Repo.aggregate(Ryker.Ingress.Inbox.Entry, :count) == 0

    # Nothing of the rejected chrome, and no replacement hero.
    for rejected <- [
          "Start a conversation",
          "Ready for your message",
          "Send a message",
          "Ask a question, investigate an issue",
          "CONVERSATION",
          "Behind this conversation",
          "All requests in this conversation",
          "Conversation identity",
          "No request yet",
          "RECENT CONVERSATIONS",
          "inputs ·"
        ] do
      refute html =~ rejected, "the index still renders #{inspect(rejected)}"
    end

    refute has_element?(view, ".lab-start")
    refute has_element?(view, ".lab-runtime")
    refute has_element?(view, ".lab-chat-header")
    assert has_element?(view, "label.sr-only[for=lab-message]", "Message Ryker")
    assert has_element?(view, "#lab-messages[phx-update=stream]")
    assert has_element?(view, ".lab-directory-heading h1", "Conversations")
    assert has_element?(view, ".lab-directory-heading a[href='/conversations']", "New")
    refute has_element?(view, ".lab-directory-heading form, .lab-directory-heading [phx-click]")
    refute html =~ "/conversations/new"

    {:ok, profile} =
      WorkProfile.new(%{
        policy: "lab-live-test",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    # The browser keeps the composer it first rendered (phx-update=ignore), so
    # the identity it posts to is the form's, not whatever the server assigned
    # on reconnect. After the 202 receipt the client asks to open exactly that
    # conversation; the server validates the identity and navigates.
    assert {:ok, _receipt} = ConversationLab.send_message(draft_id, "First message", profile)
    render_hook(view, "open-conversation", %{"id" => draft_id})
    assert_patch(view, "/conversations/#{draft_id}")
    assert has_element?(view, "#lab-messages .chat-message-text", "First message")

    assert has_element?(
             view,
             ".lab-directory-list a[href='/conversations/#{draft_id}'][aria-current=page]"
           )

    assert has_element?(
             view,
             "form.lab-native-composer[action='/conversations/#{draft_id}/messages']"
           )

    # A malformed identity is not navigation.
    render_hook(view, "open-conversation", %{"id" => "../etc"})
    refute_receive {_, {:patch, _, _}}, 50

    # Coming back to the index is a new draft, not the conversation just sent.
    {:ok, again, _} = live(conn, "/conversations")
    assert composer_conversation(render(again)) != draft_id
    refute has_element?(again, ".lab-directory-list a[aria-current=page]")

    assert has_element?(
             again,
             ".lab-directory-list a[href='/conversations/#{draft_id}']",
             "First message"
           )
  end

  test "the composer placeholder is one of ten authored examples and holds still through patches" do
    # A placeholder that re-rolled on every refresh flickered under the
    # operator's eyes every five seconds. It is chosen once per opened view,
    # is never the field's value, and the Examples list and New action are
    # buttons and navigation that cannot submit anything.
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _} = live(conn, "/conversations")
    placeholder = composer_placeholder(render(view))
    assert placeholder in LabPage.examples()
    assert composer_value(render(view)) == ""

    render_hook(view, "refresh", %{})
    assert composer_placeholder(render(view)) == placeholder

    Phoenix.PubSub.broadcast(
      Ryker.ControlPlane.PubSub,
      "control-plane",
      :control_plane_changed
    )

    assert_receive {:lab_projected, _}, 2_000
    assert composer_placeholder(render(view)) == placeholder

    id = Ecto.UUID.generate()
    {:ok, open, open_html} = live(conn, "/conversations/#{id}")
    opened = composer_placeholder(open_html)
    assert opened in LabPage.examples()
    assert composer_placeholder(render(open)) == opened
    render_hook(open, "refresh", %{})
    assert composer_placeholder(render(open)) == opened

    examples =
      render(open)
      |> LazyHTML.from_document()
      |> LazyHTML.query("#lab-examples button[type=button][data-example]")

    assert LazyHTML.attribute(examples, "data-example") == LabPage.examples()
    refute has_element?(open, "#lab-examples form, #lab-examples button[type=submit]")
    refute has_element?(open, "#lab-examples a")
    assert has_element?(open, ".lab-chat-toolbar a[href='/configuration']", "Settings")
  end

  test "the directory reads as grouped two-line titles and says when it is empty" do
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, empty, _} = live(conn, "/conversations")
    assert has_element?(empty, ".lab-directory-empty")
    refute has_element?(empty, ".lab-directory-group")

    {:ok, profile} =
      WorkProfile.new(%{
        policy: "lab-live-test",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    long =
      "Check why the deployment that started after the incident review keeps restarting " <>
        "its workers even though the queue has been idle since this morning"

    earlier = Ecto.UUID.generate()
    today = Ecto.UUID.generate()
    repeated = Ecto.UUID.generate()

    # Acceptance uses the database clock, so an older conversation is one whose
    # retained entry was accepted eight days ago.
    {:ok, %{entry: old_entry}} = ConversationLab.send_message(earlier, long, profile)

    old_entry
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -8, :day))
    |> Repo.update!()

    {:ok, _} = ConversationLab.send_message(today, "Read the automations", profile)
    {:ok, _} = ConversationLab.send_message(repeated, "Read the automations", profile)

    {:ok, view, html} = live(conn, "/conversations/#{today}")
    document = LazyHTML.from_document(html)
    assert LazyHTML.query(document, ".lab-directory-group h2") |> LazyHTML.text() =~ "Today"
    assert LazyHTML.query(document, ".lab-directory-group h2") |> LazyHTML.text() =~ "Earlier"
    refute has_element?(view, ".lab-directory-empty")

    # Two conversations opened with the same first message are two rows with
    # the same title; nothing invents a summary to tell them apart.
    titles =
      LazyHTML.query(document, ".lab-directory-list .lab-directory-title") |> LazyHTML.text()

    assert length(Regex.scan(~r/Read the automations/, titles)) == 2

    assert has_element?(
             view,
             ".lab-directory-list a[href='/conversations/#{today}'][aria-current=page]"
           )

    # A long title stays fully available to assistive technology and hover.
    [title] =
      LazyHTML.query(document, ".lab-directory-list a[href='/conversations/#{earlier}']")
      |> LazyHTML.attribute("title")

    assert title == long
    assert has_element?(view, ".lab-directory-list a[href='/conversations/#{earlier}']", long)

    times = LazyHTML.query(document, ".lab-directory-list time") |> LazyHTML.text()
    assert times =~ "UTC"
    refute html =~ "inputs ·"
    refute html =~ "RECENT CONVERSATIONS"
  end

  test "each message links its own retained execution and shows progress once beside it" do
    # The rail linked "All requests" and the newest episode. A message that
    # was routed into an earlier episode, or is still waiting on admission,
    # pointed nowhere it could be inspected. Links now carry the message's exact
    # input id or producing turn, and the progress an operator is waiting on sits
    # beside the message that caused it instead of in a column that is gone.
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "lab-live-test",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    id = Ecto.UUID.generate()
    {:ok, %{entry: first}} = ConversationLab.send_message(id, "First question", profile)
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _} = live(conn, "/conversations/#{id}")

    assert has_element?(
             view,
             "#lab-messages a.lab-message-inspect[href='/timeline/ingress-input%3A#{first.id}']",
             "View request"
           )

    assert has_element?(view, "#lab-messages .lab-message-progress", "Queued")
    assert length(find_all(view, ".lab-message-progress")) == 1
    refute has_element?(view, ".lab-runtime")
    refute has_element?(view, "a", "All requests in this conversation")

    {episode, turn} = accepted_reply!(id, first, "The first answer.", profile)

    {:ok, %{entry: second}} = ConversationLab.send_message(id, "Second question", profile)
    render_hook(view, "refresh", %{})

    # The admitted message still links its own input, which now resolves to
    # its own admission request on its episode.
    input_href = "/timeline/ingress-input%3A#{first.id}"
    assert has_element?(view, "#lab-messages a.lab-message-inspect[href='#{input_href}']")

    # The reply links the work request of the turn that produced it.
    reply_href =
      "/timeline/#{URI.encode_www_form(episode.key)}/model-calls?attempt=#{turn.id}&section=delivery"

    assert has_element?(
             view,
             "#lab-messages a.lab-message-inspect[href='#{reply_href}']",
             "View request"
           )

    # The second, still-pending message links only itself and owns the only progress row.
    assert has_element?(
             view,
             "#lab-messages a.lab-message-inspect[href='/timeline/ingress-input%3A#{second.id}']"
           )

    assert length(find_all(view, ".lab-message-progress")) == 1
    refute has_element?(view, "#lab-messages .lab-message-progress", "First question")

    # Both targets open the exact retained request they name.
    {:ok, admission, _} = live(conn, input_href)
    assert has_element?(admission, ".request-reader[data-request-id='#{first.id}']")
    assert has_element?(admission, ".request-reader-heading", "Admission")
    {:ok, work, _} = live(conn, reply_href)
    assert has_element?(work, ".request-reader[data-request-id='#{turn.id}']")

    # An ignored input has a recorded decision and no episode; it must not borrow one.
    Repo.get!(Ryker.Ingress.Inbox.Entry, second.id)
    |> Ecto.Changeset.change(
      status: :decided,
      decision_action: :ignore,
      decision_ref: "decision:ignored",
      decision_fingerprint: String.duplicate("b", 64),
      decision_document: %{"action" => "ignore"}
    )
    |> Repo.update!()

    render_hook(view, "refresh", %{})

    assert has_element?(
             view,
             "#lab-messages a.lab-message-inspect[href='/timeline/ingress-input%3A#{second.id}']",
             "View decision"
           )

    refute has_element?(view, "#lab-messages a[href*='#{episode.key}'][href*='#{second.id}']")
    assert find_all(view, ".lab-message-progress") == []
  end

  test "a message whose model work stopped says so beside the message, with the retry" do
    # On 2026-09-13 a Conversations message sent during a database outage had
    # its work turn blocked ("Model work stopped" on /failures) and the
    # conversation showed nothing at all beside it: no state, no failure, no
    # way back. A material failure lives beside the message that caused it.
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "lab-live-test",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    id = Ecto.UUID.generate()
    {:ok, %{entry: first}} = ConversationLab.send_message(id, "Stopped question", profile)
    {episode, turn} = claimed_turn!(id, first, profile)

    # A blocked turn holds no lease and no retry time; this is the row
    # shape block_completion/6 leaves behind.
    Repo.get!(Ryker.Work.Turn, turn.id)
    |> Ecto.Changeset.change(
      status: :blocked,
      lease_ref: nil,
      lease_owner: nil,
      lease_expires_at: nil,
      next_attempt_at: nil
    )
    |> Repo.update!()

    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _} = live(conn, "/conversations/#{id}")

    assert has_element?(view, "#lab-messages .lab-message-state", "Needs attention")
    assert has_element?(view, "#lab-messages .lab-message-failure", "Model work stopped")

    retry = "/actions/work/#{URI.encode_www_form(episode.key)}/retry"
    assert has_element?(view, "#lab-messages .lab-message-failure a[href='#{retry}']", "Retry")
    assert length(find_all(view, ".lab-message-failure")) == 1

    # The confirmation is an HTTP page, not a live route: a live redirect to it
    # fails the socket join and only then falls back to a page request, with a
    # console error for every click. It is an ordinary link.
    refute has_element?(
             view,
             "#lab-messages .lab-message-failure a[href='#{retry}'][data-phx-link]"
           )

    # Once the turn is working again the failure line is gone and the message
    # says it is working, once.
    Repo.get!(Ryker.Work.Turn, turn.id)
    |> Ecto.Changeset.change(
      status: :pending,
      lease_ref: "lease:retry",
      lease_owner: "live-test",
      lease_expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
    )
    |> Repo.update!()

    render_hook(view, "refresh", %{})
    refute has_element?(view, "#lab-messages .lab-message-failure")
    assert has_element?(view, "#lab-messages .lab-message-state", "Working")
  end

  test "a conversation keeps its identity, history and links across the URL rename" do
    # Stored conversations are keyed by control-plane:lab:<uuid>; the rename
    # changes only the URL. Every retained message must open at
    # /conversations/<id>, and no empty record may appear for a page visit.
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "lab-live-test",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    conn = build_conn() |> Map.put(:host, "localhost")
    unsent = Ecto.UUID.generate()
    {:ok, unsent_view, _html} = live(conn, "/conversations/#{unsent}")
    assert page_title(unsent_view) == "Conversations · Ryker"

    assert has_element?(
             unsent_view,
             "form.lab-native-composer[action='/conversations/#{unsent}/messages']"
           )

    assert Projection.lab_conversation(unsent) == :not_found
    refute Enum.any?(Projection.lab_index(), &(&1.id == unsent))

    id = Ecto.UUID.generate()

    assert {:ok, %{entry: entry}} =
             ConversationLab.send_message(id, "Keep this history across the rename", profile)

    assert entry.destination_conversation_ref == "control-plane:lab:#{id}"
    "control-plane-item:" <> item_id = entry.source_item_ref
    {:ok, view, _html} = live(conn, "/conversations/#{id}")

    assert has_element?(
             view,
             "#lab-messages .chat-message-text",
             "Keep this history across the rename"
           )

    assert has_element?(
             view,
             ".lab-directory-list a[href='/conversations/#{id}'][aria-current=page]"
           )

    assert has_element?(
             view,
             "form.lab-edit-form[action='/conversations/#{id}/messages/#{item_id}/edit']"
           )

    assert has_element?(
             view,
             ".lab-message-actions form[action='/conversations/#{id}/messages/#{item_id}/delete']"
           )

    refute has_element?(view, "[href^='/lab/'], [action^='/lab/']")
  end

  test "a reply's reactions are compact pills with real counts and one anchored picker" do
    # The reply carried a "React to this reply" heading, five permanent emoji
    # buttons and a Custom emoji disclosure whose Add button sat detached
    # under its input. Recorded reactions now render as small pills with the
    # count the contract actually provides and a pressed state for the
    # operator's own; adding opens a picker from one labelled control; a reply
    # with no reactions reserves nothing; operator messages get no reactions.
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "lab-live-test",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    id = Ecto.UUID.generate()
    {:ok, %{entry: first}} = ConversationLab.send_message(id, "Question", profile)
    {episode, _turn} = accepted_reply!(id, first, "Answer with reactions.", profile)
    message_ref = "control-plane-message:#{episode.id}"
    {:ok, _} = ConversationLab.react_to_message(id, message_ref, :add, "heart")

    {:ok, _} =
      Reactions.record(%{
        action: :add,
        actor_ref: "slack:user:U-other",
        emoji_name: "+1",
        event_ref: "slack-reaction:other-one",
        occurred_at: DateTime.utc_now(),
        source: %{kind: "control_plane", ref: "local"},
        target: %{
          conversation_ref: "control-plane:lab:#{id}",
          message_ref: message_ref,
          transport: "control_plane"
        }
      })

    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, html} = live(conn, "/conversations/#{id}")
    document = LazyHTML.from_document(html)
    reply = LazyHTML.query(document, ".lab-chat-message.actor-ryker")

    path =
      "/conversations/#{id}/replies/#{URI.encode(message_ref, &URI.char_unreserved?/1)}/reactions"

    pills = LazyHTML.query(reply, ".lab-reaction-pills form.lab-reaction-pill")
    assert Enum.count(pills) == 2
    assert LazyHTML.attribute(pills, "action") == [path, path]

    # Each pill posts the real add/remove contract for its emoji: remove for
    # the operator's own reaction, add for one they have not made.
    facts =
      Enum.map(pills, fn pill ->
        {LazyHTML.query(pill, "input[name=emoji]") |> LazyHTML.attribute("value"),
         LazyHTML.query(pill, "input[name=action]") |> LazyHTML.attribute("value"),
         LazyHTML.query(pill, "button[type=submit]") |> LazyHTML.attribute("aria-pressed"),
         LazyHTML.query(pill, "button[type=submit]") |> LazyHTML.text()}
      end)

    assert {["heart"], ["remove"], ["true"], heart} =
             Enum.find(facts, &match?({["heart"], _, _, _}, &1))

    assert heart =~ "❤️" and heart =~ "1"
    assert {["+1"], ["add"], ["false"], thumbs} = Enum.find(facts, &match?({["+1"], _, _, _}, &1))
    assert thumbs =~ "👍" and thumbs =~ "1"

    # One labelled control opens one anchored picker holding the five quick
    # choices and the custom-name form with its label, aligned Add and error slot.
    [picker_id] =
      LazyHTML.query(
        reply,
        ".lab-message-actions button.lab-reaction-toggle[type=button][aria-expanded=false]"
      )
      |> LazyHTML.attribute("aria-controls")

    assert LazyHTML.query(reply, ".lab-reaction-toggle") |> LazyHTML.attribute("aria-label") == [
             "Add reaction"
           ]

    picker = LazyHTML.query(reply, "##{picker_id}.lab-reaction-picker[hidden][phx-update=ignore]")
    assert Enum.count(picker) == 1

    assert LazyHTML.query(picker, "form.lab-reaction-quick input[name=emoji]")
           |> LazyHTML.attribute("value") == ["+1", "heart", "eyes", "tada", "rocket"]

    assert LazyHTML.query(picker, "form.lab-reaction-quick input[name=action]")
           |> LazyHTML.attribute("value")
           |> Enum.uniq() == ["add"]

    assert LazyHTML.query(picker, "form.lab-reaction-custom label[for='#{picker_id}-name']")
           |> LazyHTML.text() =~ "Emoji name"

    assert LazyHTML.query(
             picker,
             "form.lab-reaction-custom input#" <>
               picker_id <> "-name[name=emoji][maxlength='100']"
           )
           |> Enum.count() == 1

    assert LazyHTML.query(
             picker,
             "form.lab-reaction-custom .lab-reaction-custom-row button.lab-reaction-add[type=submit]"
           )
           |> LazyHTML.text() =~ "Add"

    assert LazyHTML.query(
             picker,
             "form.lab-reaction-custom p.lab-reaction-error[role=alert][hidden]"
           )
           |> Enum.count() == 1

    assert LazyHTML.query(picker, "form.lab-reaction-custom input[name=emoji]")
           |> LazyHTML.attribute("aria-describedby") == ["#{picker_id}-error"]

    refute html =~ "React to this reply"
    refute has_element?(view, "#lab-messages details summary", "Custom emoji")
    refute has_element?(view, "#lab-messages .quick-reactions")
    refute has_element?(view, ".lab-chat-message.actor-operator .lab-reaction-toggle")
    refute has_element?(view, ".lab-chat-message.actor-operator .lab-reaction-pills")

    # A reply without reactions reserves no pills panel.
    {:ok, %{entry: second}} = ConversationLab.send_message(id, "Second question", profile)
    {_episode2, _turn2} = accepted_reply!(id, second, "Answer without reactions.", profile)
    render_hook(view, "refresh", %{})

    bare =
      render(view)
      |> LazyHTML.from_document()
      |> LazyHTML.query(".lab-chat-message.actor-ryker")

    assert Enum.count(bare) == 2
    assert Enum.count(LazyHTML.query(bare, ".lab-reaction-pills")) == 1
    assert Enum.count(LazyHTML.query(bare, ".lab-reaction-toggle")) == 2
  end

  test "an operator message edits in place through one hidden editor bound to that message" do
    # The Edit disclosure opened a second textarea under the message with an
    # "Edit message" heading and a full-width bar. The editor is now one hidden
    # form per editable message, bound to that message's exact edit route and
    # token, holding the stored body, with Cancel and Save at its lower edge.
    # Replies and deleted messages get no editor; nothing else on the page is a
    # textarea besides the composer.
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "lab-live-test",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    id = Ecto.UUID.generate()

    {:ok, %{entry: first}} =
      ConversationLab.send_message(id, "Stored body with **markdown**", profile)

    "control-plane-item:" <> item_id = first.source_item_ref
    {:ok, %{entry: second}} = ConversationLab.send_message(id, "To be deleted", profile)
    "control-plane-item:" <> deleted_id = second.source_item_ref
    {:ok, _} = ConversationLab.delete_message(id, deleted_id, profile)
    {_episode, _turn} = accepted_reply!(id, first, "A reply nobody can edit.", profile)

    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, html} = live(conn, "/conversations/#{id}")
    document = LazyHTML.from_document(html)

    assert has_element?(
             view,
             ".lab-message-actions button.lab-edit-toggle[type=button][aria-controls='lab-edit-#{item_id}'][aria-expanded=false]",
             "Edit"
           )

    editor = LazyHTML.query(document, "form#lab-edit-#{item_id}.lab-edit-form")
    assert LazyHTML.attribute(editor, "hidden") == [""]

    assert LazyHTML.attribute(editor, "action") == [
             "/conversations/#{id}/messages/#{item_id}/edit"
           ]

    assert LazyHTML.attribute(editor, "data-lab-edit") == [item_id]
    assert LazyHTML.query(editor, "input[name=_token]") |> LazyHTML.attribute("value") != [""]

    assert LazyHTML.query(editor, "textarea[name=message]") |> LazyHTML.text() ==
             "Stored body with **markdown**"

    assert LazyHTML.query(editor, "label.sr-only[for='lab-edit-#{item_id}-text']")
           |> LazyHTML.text() =~ "Edit message"

    assert LazyHTML.query(editor, ".lab-edit-actions button.lab-edit-cancel[type=button]")
           |> LazyHTML.text() =~ "Cancel"

    assert LazyHTML.query(editor, ".lab-edit-actions button.lab-edit-save[type=submit]")
           |> LazyHTML.text() =~ "Save"

    assert LazyHTML.query(editor, "p.lab-edit-error[role=alert][hidden]") |> Enum.count() == 1

    # No disclosure, no repeated heading, no duplicate body, no visible second textarea.
    refute has_element?(view, "#lab-messages details summary", "Edit")
    refute has_element?(view, "#lab-messages label:not(.sr-only)", "Edit message")
    refute has_element?(view, "#lab-messages h3, #lab-messages h4, #lab-messages summary", "Edit")
    assert length(find_all(view, "#lab-messages textarea")) == 1
    assert length(find_all(view, "#lab-messages .lab-edit-toggle")) == 1
    refute has_element?(view, ".lab-chat-message.actor-ryker .lab-edit-form")
    refute has_element?(view, "form#lab-edit-#{deleted_id}")
    assert has_element?(view, "#lab-notices[phx-update=ignore]")

    # Delete stays beside Edit as its own exact form.
    assert has_element?(
             view,
             ".lab-message-actions form[action='/conversations/#{id}/messages/#{item_id}/delete'] button.lab-message-delete",
             "Delete"
           )
  end

  test "the workspace offers no card catalog, previews or specimen events" do
    # WorkflowGuide's ten workflows linked eighteen /card-lab previews and the
    # workbench answered card-family/card-state/card-transition events. None of
    # that may survive as a hidden catalog behind the surviving conversation page.
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, html} = live(conn, "/conversations")
    refute html =~ "/card-lab"
    refute html =~ "What you can do"
    refute html =~ "Card previews"
    refute has_element?(view, "[phx-click=card-transition]")
    refute has_element?(view, "[phx-change=card-family]")
    refute has_element?(view, "#card-state-picker")
    refute has_element?(view, ".app-sidebar a[href='/card-lab']")
    refute has_element?(view, ".app-sidebar a[href='/manual-tests']")
    refute has_element?(view, ".app-sidebar .nav-caption", "Testing")
  end

  test "populated usage connects and refreshes without rendering the execution ledger" do
    # The production Usage page entered a rapid reconnect loop: the UNION
    # projection returned UUID bytes, which could not be JSON-encoded by LiveView.
    source = "099bf049-b7c2-4ead-969d-225ec7a3c6d2"

    Repo.insert!(%Ryker.Accounting.Execution{
      kind: "admission",
      source_id: source,
      generation: "1",
      execution_mode: "live",
      transport: "control_plane",
      conversation_ref: "control-plane:lab:925c519e-edf4-4e26-951f-b22d60392f10",
      status: "completed",
      recorded_at: DateTime.utc_now()
    })

    assert Projection.usage(%{}).totals.attempts == 1
    {:ok, view, html} = live(build_conn() |> Map.put(:host, "localhost"), "/usage")
    assert String.valid?(html)
    assert {:ok, _json} = Jason.encode(html)
    assert has_element?(view, "[data-connection-state=connected]")
    refute has_element?(view, "#execution-ledger")
    send(view.pid, :reconcile)
    refute render(view) =~ source
  end

  test "an episode has one continuous execution document and preserves exact request links" do
    {:ok, %{episode: episode}} =
      Ryker.Episodes.apply(Ryker.Fixtures.Episodes.admit_input())

    path = "/timeline/" <> URI.encode_www_form(episode.key)
    {:ok, view, _html} = live(build_conn() |> Map.put(:host, "localhost"), path)
    assert has_element?(view, "#execution-timeline", "Execution timeline")
    assert has_element?(view, ".case-event", "Input admitted")
    refute has_element?(view, "button.execution-event")
    refute has_element?(view, "nav[aria-label='Episode view']")
    view |> element("a", "Model calls") |> render_click()
    assert_patch(view, path <> "/model-calls")
    assert has_element?(view, ".model-inspector", "What the model received")
    assert has_element?(view, ".document-unavailable", "No model calls recorded")
    refute has_element?(view, "#execution-timeline")
    view |> element("a", "Back to the timeline") |> render_click()
    assert_patch(view, path)
    assert has_element?(view, "#execution-timeline", "Input admitted")

    # Direct inspector entry must use the same native reader as in-page navigation.
    {:ok, direct, _} = live(build_conn() |> Map.put(:host, "localhost"), path <> "/model-calls")
    assert has_element?(direct, ".model-inspector", "What the model received")
    refute has_element?(direct, ".request-workbench")
    refute has_element?(direct, "#execution-timeline")
  end

  test "native episode details distinguish missing records from unavailable projections", %{
    counters: counters
  } do
    conn = build_conn() |> Map.put(:host, "localhost")

    for ref <- ["missing", String.duplicate("a", 3_073)] do
      {:ok, missing, _} = live(conn, "/timeline/" <> ref)
      assert has_element?(missing, ".document-unavailable", "This record is unavailable")
      refute has_element?(missing, ".app-warning", "This view could not refresh")
    end

    Agent.update(counters, &Map.put(&1, :episode_fail, true))
    {:ok, unavailable, _} = live(conn, "/timeline/unavailable")

    assert has_element?(
             unavailable,
             ".document-unavailable",
             "This view is temporarily unavailable"
           )

    assert has_element?(unavailable, ".app-warning", "This view could not refresh")
  end

  test "the native Lab never claims admission before a message exists and streams committed messages" do
    id = Ecto.UUID.generate()
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, html} = live(conn, "/conversations/#{id}")
    refute html =~ "Ready for your message"
    refute html =~ "Awaiting admission"
    refute has_element?(view, ".lab-message-progress")
    assert has_element?(view, ".lab-native-composer[phx-update=ignore]")

    {:ok, profile} =
      WorkProfile.new(%{
        policy: "lab-live-test",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    assert {:ok, _receipt} =
             ConversationLab.send_message(id, "Inspect the request behind this answer", profile)

    Phoenix.PubSub.broadcast(
      Ryker.ControlPlane.PubSub,
      "control-plane",
      :control_plane_changed
    )

    # A fixture guard, not a latency measurement: nothing here is timing the
    # projection, it is waiting for one that must happen. The path is a 25ms
    # refresh debounce plus a full page projection, and ExUnit's 100ms default
    # does not cover that on a loaded host -- this line failed 5 runs in 6 on
    # an untouched 3290c455 and passed 6 in 6 once the deadline was widened.
    assert_receive {:lab_projected, 1}, 2_000

    assert has_element?(
             view,
             "#lab-messages .chat-message-text",
             "Inspect the request behind this answer"
           )

    assert has_element?(view, ".lab-message-progress", "Queued")
    assert has_element?(view, ".lab-directory-list a", "Inspect the request behind this answer")
    assert has_element?(view, ".lab-message-actions .lab-edit-toggle", "Edit")
    assert has_element?(view, ".lab-native-composer[phx-update=ignore]")

    {:ok, _} =
      ConversationLab.send_message(id, "**Evidence** [Run](https://example.invalid/run)", profile)

    render_hook(view, "refresh", %{})
    assert has_element?(view, ".chat-message-text strong", "Evidence")
    assert has_element?(view, ".chat-message-text a[href='https://example.invalid/run']", "Run")
    refute has_element?(view, ".lab-message-byline", "Decided")
    refute has_element?(view, ".lab-message-byline", "Sent")
    refute has_element?(view, "a", "All requests")
  end

  test "presentation always follows durable updates and remounts with current data", %{
    counters: counters
  } do
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _html} = live(conn, "/")
    Agent.update(counters, &Map.put(&1, :active, 9))

    Phoenix.PubSub.broadcast(
      Ryker.ControlPlane.PubSub,
      "control-plane",
      :control_plane_changed
    )

    view |> render_hook("refresh", %{})
    assert has_element?(view, "[data-active-count]", "9")
    Agent.update(counters, &Map.put(&1, :active, 12))
    {:ok, remounted, _html} = live(conn, "/")
    assert has_element?(remounted, "[data-active-count]", "12")
  end

  test "socket connect rejects remote peers and missing peer information" do
    socket = %Phoenix.Socket{}

    local = %{
      peer_data: %{address: {127, 0, 0, 1}},
      uri: URI.parse("http://localhost:4321/live"),
      session: %{}
    }

    assert {:ok, connected} = LiveSocket.connect(%{}, socket, local)
    assert connected.private.connect_info == local

    assert :error =
             LiveSocket.connect(%{}, socket, %{
               local
               | peer_data: %{address: {203, 0, 113, 5}}
             })

    assert :error =
             LiveSocket.connect(%{}, socket, %{
               local
               | uri: URI.parse("http://attacker.example/live")
             })

    assert :error = LiveSocket.connect(%{}, socket, %{})
  end

  test "refreshing admission never changes the execution the operator is reading" do
    {entry, _id} = lab_input!()
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _} = live(conn, "/timeline/ingress-input%3A#{entry.id}")
    assert has_element?(view, ".request-reader-heading", "Admission · execution 1")
    entry |> Ecto.Changeset.change(execution_generation: 2) |> Repo.update!()
    render_hook(view, "refresh", %{})
    assert has_element?(view, ".request-reader-heading", "Admission · execution 1")
    assert has_element?(view, ".request-reader[data-generation='1']")
    assert has_element?(view, ".artifact-instructions", "Ryker admission instructions")
    assert has_element?(view, ".artifact-context", "Frozen admission context")

    assert has_element?(view, ".request-reader .ui-pagination", "1 / 2")

    # Assignment used to erase the reader's pinned routing attempt mid-inspection.
    {:ok, %{episode: episode}} =
      Ryker.Episodes.apply(Ryker.Fixtures.Episodes.admit_input())

    Repo.get!(Ryker.Ingress.Inbox.Entry, entry.id)
    |> Ecto.Changeset.change(
      episode_id: episode.id,
      status: :decided,
      decision_action: :start_episode,
      decision_ref: "decision:reader-assignment",
      decision_fingerprint: String.duplicate("a", 64),
      decision_document: %{"action" => "start_episode", "episode_ref" => episode.key}
    )
    |> Repo.update!()

    render_hook(view, "refresh", %{})
    assert has_element?(view, ".request-reader[data-generation='1']")
    assert has_element?(view, ".request-reader .ui-pagination", "1 / 2")

    {:ok, reopened, _} =
      live(conn, "/timeline/ingress-input%3A#{entry.id}?generation=1")

    assert has_element?(reopened, ".request-reader[data-generation='1']")
  end

  test "a blocked admission shows its recovery reason and a correctly bound confirmation" do
    {entry, _id} = lab_input!()

    entry
    |> Ecto.Changeset.change(status: :blocked, last_error_code: "provider_unavailable")
    |> Repo.update!()

    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _} = live(conn, "/timeline/ingress-input%3A#{entry.id}")
    assert has_element?(view, ".admission-recovery", "Provider unavailable")
    href = "/actions/admission/#{URI.encode_www_form(Inbox.ref(entry))}/rearm"
    refute has_element?(view, "a[href='#{href}']")

    assert has_element?(
             view,
             "form[method='get'][action='#{href}'] button[type='submit']",
             "Review recovery"
           )

    confirmation = get(conn, href)
    assert html_response(confirmation, 200) =~ "Retry routing this message?"
  end

  test "activity search and status links preserve existing Usage drill-down filters" do
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _} = live(conn, "/activity?target=sol%2Fmedium&repository=emisar&state=active")
    view |> element("a", "Needs you") |> render_click()

    assert_patch(
      view,
      "/activity?filter=attention&repository=emisar&state=active&target=sol%2Fmedium"
    )

    view |> form("#activity-filters", %{q: "investigate", mode: "live"}) |> render_change()

    assert_patch(
      view,
      "/activity?filter=attention&mode=live&q=investigate&repository=emisar&state=active&target=sol%2Fmedium"
    )
  end

  test "pending invalidations are coalesced before running another projection" do
    # A slow database used to queue repeated full projections ahead of Pause and navigation.
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, refresh_token: nil, refresh_failures: 0}
    }

    {:noreply, first} =
      WorkbenchLive.handle_info(:control_plane_changed, socket)

    token = first.assigns.refresh_token
    assert is_reference(token)

    {:noreply, second} =
      WorkbenchLive.handle_info(:control_plane_changed, first)

    assert second.assigns.refresh_token == token
    assert_receive {:refresh_projection, ^token}
    refute_receive {:refresh_projection, _}, 20
  end

  test "the removed audit route does not mount a live page" do
    conn = build_conn() |> Map.put(:host, "localhost") |> get("/audit")
    assert conn.status == 404
    refute conn.resp_body =~ "audit-feed"
  end

  test "removed incident routes cannot mount a live page or redirect" do
    for path <- ["/incidents", "/incidents/incident%3Aone"] do
      conn = build_conn() |> Map.put(:host, "localhost") |> get(path)
      assert conn.status == 404
      assert Plug.Conn.get_resp_header(conn, "location") == []
      refute conn.resp_body =~ "data-phx-main"
    end
  end

  test "mobile workspace navigation preserves every secondary destination" do
    {:ok, view, _} = live(build_conn() |> Map.put(:host, "localhost"), "/")
    assert has_element?(view, "details.mobile-manage summary", "More")

    for path <- ~w(memory findings repositories channels subscriptions) do
      assert has_element?(view, ".mobile-manage a[href='/#{path}']")
    end

    for retired <- ~w(card-lab manual-tests) do
      refute has_element?(view, "a[href='/#{retired}']")
    end

    refute has_element?(view, ".mobile-manage strong", "Testing")

    assert has_element?(
             view,
             ".app-sidebar nav[aria-label='Main navigation'] a[href='/failures']"
           )

    refute has_element?(view, "a[href='/audit']")
  end

  test "projection failures preserve stale state but log only a safe diagnostic category", %{
    counters: counters
  } do
    {:ok, view, _} = live(build_conn() |> Map.put(:host, "localhost"), "/")
    Agent.update(counters, &Map.put(&1, :fail, true))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        render_hook(view, "refresh", %{})
      end)

    assert log =~ "category=RuntimeError"
    refute log =~ "sensitive provider exception body"
    assert has_element?(view, ".app-warning", "could not refresh")
    assert has_element?(view, "[data-active-count]", "1")
  end

  test "Lab announces new replies and phase changes without repeating them on reconciliation" do
    before = %{messages: [], admission_progress: [%{phase: "Queued"}]}

    after_reply = %{
      before
      | messages: [%{actor: :ryker, ref: "reply:one"}],
        admission_progress: []
    }

    assert LabPage.announcement(before, after_reply) =~ "1 new reply"
    assert LabPage.announcement(after_reply, after_reply) == nil

    {:ok, view, _} =
      live(build_conn() |> Map.put(:host, "localhost"), "/conversations/#{Ecto.UUID.generate()}")

    assert has_element?(view, "#lab-announcement[role=status][aria-live=polite]")
    assert has_element?(view, "#lab-messages[role=log][aria-live=off]")
  end

  defp lab_input! do
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "lab-live-test",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    id = Ecto.UUID.generate()
    {:ok, %{entry: entry}} = ConversationLab.send_message(id, "Investigate admission", profile)
    {entry, id}
  end

  # A confirmed trigger rule in #C456 with the given task and lifecycle
  # status. It never expires, so "current" keeps meaning what it says here
  # after the fixture's fixed clock has passed.
  defp rule!(source, task, overrides \\ []) do
    SavedEntities.behavior!(
      source,
      :standing_assignment,
      %{
        "action" => "triage_alert",
        "expires_in" => "30d",
        "repository" => nil,
        "source_filter" => "human",
        "task" => task,
        "trigger" => "operational_alert"
      },
      Keyword.merge(
        [scope_ref: "slack:T123:C456", expires_at: nil, identity_key: String.slice(task, 0, 120)],
        overrides
      )
    )
  end

  defp composer_conversation(html) do
    [action] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("form.lab-native-composer")
      |> LazyHTML.attribute("action")

    "/conversations/" <> rest = action
    String.replace_suffix(rest, "/messages", "")
  end

  defp composer_placeholder(html) do
    [placeholder] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("form.lab-native-composer textarea#lab-message")
      |> LazyHTML.attribute("placeholder")

    placeholder
  end

  defp composer_value(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("form.lab-native-composer textarea#lab-message")
    |> LazyHTML.text()
  end

  defp find_all(view, selector) do
    render(view)
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.to_tree()
  end

  # An admitted conversation input, its episode, and one accepted, delivered
  # reply turn, through the same custody path the runtime uses.
  # An admitted input with its episode claimed and its turn bound to a Coop
  # turn, stopped short of any result: the state a turn is in when work stops.
  defp claimed_turn!(conversation_id, %Ryker.Ingress.Inbox.Entry{} = entry, profile) do
    alias Ryker.Work.{Custody, SubmissionBuilder}
    conversation_ref = "control-plane:lab:#{conversation_id}"
    episode_id = Ecto.UUID.generate()
    turn_ref = "turn:conversation-lab:#{episode_id}"

    {:ok, transition} =
      Ryker.Episodes.apply(
        Ryker.Fixtures.Episodes.admit_input(%{
          destination: %{
            conversation_ref: conversation_ref,
            thread_ref: conversation_ref,
            transport: "control_plane"
          },
          episode_id: episode_id,
          episode_key: "conversation-lab:#{episode_id}",
          native_input_id: entry.native_input_id,
          occurred_at: entry.occurred_at,
          payload: %{"text" => entry.content["text"]},
          turn_ref: turn_ref
        })
      )

    episode = transition.episode

    entry
    |> Ecto.Changeset.change(
      episode_id: episode.id,
      status: :decided,
      decision_action: :start_episode,
      decision_ref: "decision:#{episode_id}",
      decision_fingerprint: String.duplicate("a", 64),
      decision_document: %{"action" => "start_episode", "episode_ref" => episode.key}
    )
    |> Repo.update!()

    {:ok, _session} = Custody.pin_episode(episode.id, profile.policy, profile.policy_digest)
    {:ok, claim} = Custody.claim_next("live-test:#{episode_id}", 60, :work)
    {:ok, submission} = SubmissionBuilder.build(claim)

    {:ok, _turn} =
      Custody.freeze_submission(episode.id, claim.turn.turn_ref, claim.lease_ref, submission)

    {:ok, session} =
      Custody.bind_session(
        episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        claim.session.generation,
        claim.session.create_generation,
        "coop-session:#{episode_id}"
      )

    {:ok, turn} =
      Custody.bind_turn(
        episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        session.generation,
        claim.turn.submit_generation,
        "coop-turn:#{episode_id}"
      )

    {episode, turn}
  end

  defp accepted_reply!(conversation_id, %Ryker.Ingress.Inbox.Entry{} = entry, text, profile) do
    alias Ryker.Work.{Custody, DeliveryReceipt, Result, SubmissionBuilder}
    conversation_ref = "control-plane:lab:#{conversation_id}"
    episode_id = Ecto.UUID.generate()
    turn_ref = "turn:conversation-lab:#{episode_id}"

    {:ok, transition} =
      Ryker.Episodes.apply(
        Ryker.Fixtures.Episodes.admit_input(%{
          destination: %{
            conversation_ref: conversation_ref,
            thread_ref: conversation_ref,
            transport: "control_plane"
          },
          episode_id: episode_id,
          episode_key: "conversation-lab:#{episode_id}",
          native_input_id: entry.native_input_id,
          occurred_at: entry.occurred_at,
          payload: %{"text" => entry.content["text"]},
          turn_ref: turn_ref
        })
      )

    episode = transition.episode

    entry
    |> Ecto.Changeset.change(
      episode_id: episode.id,
      status: :decided,
      decision_action: :start_episode,
      decision_ref: "decision:#{episode_id}",
      decision_fingerprint: String.duplicate("a", 64),
      decision_document: %{"action" => "start_episode", "episode_ref" => episode.key}
    )
    |> Repo.update!()

    {:ok, _session} = Custody.pin_episode(episode.id, profile.policy, profile.policy_digest)
    {:ok, claim} = Custody.claim_next("live-test:#{episode_id}", 60, :work)
    {:ok, submission} = SubmissionBuilder.build(claim)

    {:ok, _turn} =
      Custody.freeze_submission(episode.id, claim.turn.turn_ref, claim.lease_ref, submission)

    {:ok, session} =
      Custody.bind_session(
        episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        claim.session.generation,
        claim.session.create_generation,
        "coop-session:#{episode_id}"
      )

    {:ok, _turn} =
      Custody.bind_turn(
        episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        session.generation,
        claim.turn.submit_generation,
        "coop-turn:#{episode_id}"
      )

    document = %{
      "message" => text,
      "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
    }

    candidate = Jason.encode!(document)
    sha256 = :crypto.hash(:sha256, candidate) |> Base.encode16(case: :lower)

    {:ok, _turn} =
      Custody.stage_candidate(
        episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        nil,
        nil,
        candidate,
        sha256,
        1
      )

    {:ok, result} = Result.new(:reply, document)

    {:ok, _turn} =
      Custody.prepare_validation(
        episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        sha256,
        1,
        :accept,
        result
      )

    {:ok, accepted} =
      Custody.accept_result(
        episode.id,
        episode.key,
        claim.turn.turn_ref,
        claim.lease_ref,
        sha256,
        1,
        "validation-receipt:#{episode_id}"
      )

    {:ok, delivery} = Custody.claim_next("live-test-delivery:#{episode_id}", 60, :delivery)

    {:ok, receipt} =
      DeliveryReceipt.new(
        accepted.turn.delivery_ref,
        "control_plane",
        conversation_ref,
        conversation_ref,
        "control-plane-message:#{episode_id}"
      )

    {:ok, _settled} =
      Custody.confirm_delivery(
        episode.id,
        episode.key,
        claim.turn.turn_ref,
        delivery.lease_ref,
        receipt
      )

    {episode, accepted.turn}
  end

  # "tag.first-class" for each matched element, in document order.
  defp outline(document, selector) do
    nodes = LazyHTML.query(document, selector)

    nodes
    |> LazyHTML.tag()
    |> Enum.zip(LazyHTML.attributes(nodes))
    |> Enum.map(fn {tag, attributes} ->
      case List.keyfind(attributes, "class", 0) do
        {"class", class} -> tag <> "." <> hd(String.split(class))
        nil -> tag
      end
    end)
  end
end
