defmodule Ryker.ControlPlane.LiveTest do
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Ryker.Admission.Attempts
  alias Ryker.ControlPlane.{Actions, BehaviorLibrary, ConversationLab, LiveSocket, Projection}
  alias Ryker.ControlPlane.LabPage
  alias Ryker.ControlPlane.PubSub
  alias Ryker.ControlPlane.WorkbenchLive
  alias Ryker.Fixtures.SavedEntities
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.EntryChangeset
  alias Ryker.Ingress.WorkProfile

  alias Ryker.ControlPlane.Endpoint
  alias Ryker.Episodes.Reactions

  # Activity's "active" count: the number in the count that opens In progress.
  @active_count ".kit-count[href$='?filter=running'] b"

  @endpoint Endpoint

  setup do
    observer = self()
    {:ok, counters} = Agent.start_link(fn -> %{active: 1, chat_readiness: :ready} end)

    {:ok, lab_profile} =
      WorkProfile.new(%{
        policy: "lab-live-test",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    options = %{
      actions: Actions.callbacks(lab_profile),
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
          readiness: fn ->
            case Agent.get(counters, & &1.chat_readiness) do
              :ready ->
                %{
                  chat: %{
                    state: :ready,
                    title: "Chat is ready",
                    detail: "Messages can be accepted and processed."
                  },
                  slack: %{state: :not_connected}
                }

              :worker_unavailable ->
                %{
                  chat: %{
                    state: :worker_unavailable,
                    title: "Chat is waiting for its worker",
                    detail: "The bundled worker is offline or still starting."
                  },
                  slack: %{state: :worker_unavailable}
                }
            end
          end,
          activity: fn params ->
            %{
              items: [],
              total: 0,
              page: 1,
              pages: 1,
              mode: params["mode"] || "live",
              searchable: true
            }
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
    assert has_element?(view, @active_count, "1")

    Agent.update(counters, &Map.put(&1, :active, 7))

    Phoenix.PubSub.broadcast(
      Ryker.ControlPlane.PubSub,
      "control-plane",
      :control_plane_changed
    )

    # Same debounce-plus-projection wait as the Lab stream below; same guard.
    assert_receive {:overview_projected, 7}, 2_000
    assert has_element?(view, @active_count, "7")
  end

  test "rules and saved entries are live navigable and keep their filters after reconciliation" do
    for {path, selected} <- [
          {"/rules?q=emisar&status=past", ["Past"]},
          {"/instructions?show=guidance&status=past", ["Guidance", "Past"]}
        ] do
      {:ok, view, html} = live(build_conn() |> Map.put(:host, "localhost"), path)
      assert current_segments(html) == selected, path
      send(view.pid, :reconcile)
      assert current_segments(render(view)) == selected, path
    end

    {:ok, view, _} = live(build_conn() |> Map.put(:host, "localhost"), "/rules?q=emisar")
    assert has_element?(view, ".kit-toolbar form.filter-toolbar input[name=q][value=emisar]")
    send(view.pid, :reconcile)
    assert has_element?(view, ".kit-toolbar form.filter-toolbar input[name=q][value=emisar]")

    {:ok, view, _} = live(build_conn() |> Map.put(:host, "localhost"), "/rules?q[x]=1&page[x]=2")
    assert has_element?(view, ".behavior-page")
    refute has_element?(view, ".document-unavailable")
  end

  test "the live shell shows Rules once with its sentence beneath, then one column" do
    # The approved page (2026-09-24): the title, one plain sentence, one row of
    # search and Current/Past, the rules, how to add one, then recent
    # matches, down one left edge. A routine reconcile must not disturb it.
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
    assert LazyHTML.text(headings) == "Rules"

    assert LazyHTML.query(
             document,
             "main header.page-header > .page-heading + p.page-description"
           )
           |> LazyHTML.text() ==
             "Rules tell Ryker to act when something happens, like a new alert or a merged pull request."

    assert outline(document, "main .secondary-page > *") == [
             "header.page-header",
             "div.behavior-page"
           ]

    assert outline(document, "main .behavior-page > *") == [
             "div.kit-toolbar",
             "div.entity-list",
             "p.ask-hint",
             "section.behavior-matches"
           ]

    assert has_element?(view, "main .behavior-page > .entity-list h3", "Triage alerts")
    assert has_element?(view, "main .behavior-page > .entity-list", "Watch Terraform applies")
    refute has_element?(view, "details.page-help, p.result-count, .behavior-counts")

    send(view.pid, :reconcile)
    assert has_element?(view, "main header.page-header h1", "Rules")
    assert has_element?(view, "main p.ask-hint", "To add a rule, tell Ryker in the channel:")
  end

  test "filters live in the URL, so a shared or back-navigated address reproduces the list and changes nothing" do
    # The search is a GET form and Current/Past are links: the address is the
    # only filter state, so Back, a pasted link and a reconcile all show the
    # same rows. Changing a view, opening the action menu and opening the
    # Delete confirmation are reads; the row they describe must be
    # byte-for-byte the row that was there before.
    source = SavedEntities.source!("slack:T123:C456")
    active = rule!(source, "Watch Terraform applies and report readiness.")
    archived = rule!(source, "Retired: page the old rota.", status: :deleted)
    before = Repo.get!(Ryker.State.Behavior, active.id)
    rows = "main .behavior-page > .entity-list article.entity-row"

    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _} = live(conn, "/rules?status=past")
    assert has_element?(view, "nav.segmented a[aria-current=page]", "Past")
    assert has_element?(view, rows, "Retired: page the old rota.")
    refute has_element?(view, rows, "Watch Terraform applies")

    assert has_element?(
             view,
             ".kit-toolbar form.filter-toolbar input[type=hidden][name=status][value=past]"
           )

    # Back: the previous address, nothing else, brings the previous list back.
    render_patch(view, "/rules")
    assert has_element?(view, "nav.segmented a[aria-current=page]", "Current")
    assert has_element?(view, rows, "Watch Terraform applies")
    refute has_element?(view, rows, "Retired: page the old rota.")
    refute has_element?(view, ".kit-toolbar a.filter-clear")
    refute has_element?(view, ".kit-toolbar form.filter-toolbar input[name=status]")

    render_patch(view, "/rules?q=Terraform&page=7")
    assert has_element?(view, "input[name=q][value=Terraform]")
    assert has_element?(view, ".kit-toolbar a.filter-clear[href='/rules']")
    send(view.pid, :reconcile)
    assert has_element?(view, rows, "Watch Terraform applies")

    # Opening the menu is a disclosure; opening Delete is its confirmation page.
    assert has_element?(view, rows <> " details.behavior-menu:not([open])")
    ref = URI.encode_www_form(active.ref)
    confirmation = get(conn, "/actions/behavior/#{ref}/deleted")
    assert confirmation.status == 200
    assert confirmation.resp_body =~ "Delete"
    assert Repo.get!(Ryker.State.Behavior, active.id) == before
    assert Repo.get!(Ryker.State.Behavior, archived.id).status == :deleted
  end

  test "current and past select the rows they name, and search stays inside the chosen view" do
    # Current is what can still act (on or paused); Past is what expired, was
    # deleted or was replaced. An unknown view is Current, never everything.
    source = SavedEntities.source!("slack:T123:C456")
    rule!(source, "Active rule one.")
    rule!(source, "Active rule two.")
    rule!(source, "Paused rule.", status: :disabled)
    rule!(source, "Deleted rule.", status: :deleted)
    rule!(source, "Superseded rule.", status: :superseded)
    rule!(source, "Expired rule.", expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
    conn = build_conn() |> Map.put(:host, "localhost")

    for {query, states} <- [
          {"", ["On", "On", "Paused"]},
          {"?status=current", ["On", "On", "Paused"]},
          {"?status=past", ["Deleted", "Expired", "Replaced"]},
          {"?status=all", ["On", "On", "Paused"]}
        ] do
      {:ok, _view, html} = live(conn, "/rules" <> query)

      assert html
             |> LazyHTML.from_document()
             |> LazyHTML.query(
               "main .behavior-page > .entity-list article .entity-side .state-word"
             )
             |> Enum.map(&LazyHTML.text/1)
             |> Enum.sort() == Enum.sort(states),
             query
    end

    {:ok, _view, html} = live(conn, "/rules?status=past&q=Deleted")
    document = LazyHTML.from_document(html)

    assert LazyHTML.query(document, "main .behavior-page > .entity-list article")
           |> Enum.map(&(LazyHTML.query(&1, ".entity-text") |> LazyHTML.text())) == [
             "Deleted rule."
           ]
  end

  test "an empty search is not a failed page, and a failed page is not empty", %{
    counters: counters
  } do
    # "No rules match" invites the reader to change the search; a projection
    # that could not run must not be presented as that, or the reader
    # concludes the rule they are looking for does not exist.
    source = SavedEntities.source!("slack:T123:C456")
    rule!(source, "Watch Terraform applies and report readiness.")
    conn = build_conn() |> Map.put(:host, "localhost")

    {:ok, empty, _} = live(conn, "/rules?q=nothing-here")
    assert has_element?(empty, "main .behavior-page > .entity-empty", "No rules match")
    assert has_element?(empty, "main .entity-empty a[href='/rules']", "Clear the search")
    refute has_element?(empty, ".document-unavailable")
    refute has_element?(empty, ".app-warning", "could not refresh")

    Agent.update(counters, &Map.put(&1, :behaviors_fail, true))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for path <- ["/rules?q=nothing-here", "/instructions"] do
          {:ok, failed, _} = live(conn, path)
          assert has_element?(failed, ".document-unavailable", "temporarily unavailable"), path
          assert has_element?(failed, ".app-warning", "could not refresh"), path
          refute has_element?(failed, ".entity-empty"), path
          refute has_element?(failed, "main", "No rules match"), path
          refute has_element?(failed, "main", "Nothing saved yet"), path
        end
      end)

    assert log =~ "category=RuntimeError"
    refute log =~ "sensitive provider exception body"
  end

  test "the twenty-sixth saved entry starts a second page and paging keeps the kind shown" do
    # Twenty-five rows per page is the projection's contract. The section has
    # to show all twenty-five, say how many there are in total, and reach the
    # twenty-sixth through a link that keeps the kind and lands on the section.
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

    rows = "section.instructions-saved article.entity-row"
    pager = "section.instructions-saved nav.pagination"
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, html} = live(conn, "/instructions?show=guidance")
    document = LazyHTML.from_document(html)
    assert Enum.count(LazyHTML.query(document, rows)) == 25
    assert has_element?(view, pager, "Page 1 of 2")
    assert has_element?(view, pager, "26 entries")

    assert LazyHTML.query(document, pager <> " a") |> LazyHTML.attribute("href") ==
             ["/instructions?page=2&show=guidance#saved"]

    render_patch(view, "/instructions?show=guidance&page=2")
    document = LazyHTML.from_document(render(view))
    assert Enum.count(LazyHTML.query(document, rows)) == 1
    assert has_element?(view, pager, "Page 2 of 2")
    assert has_element?(view, pager <> " a[href='/instructions?show=guidance#saved']", "Previous")

    render_patch(view, "/instructions?show=guidance&page=99")
    assert has_element?(view, pager, "Page 2 of 2")
    render_patch(view, "/instructions?show=guidance&page=abc")
    assert has_element?(view, pager, "Page 1 of 2")
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
    assert LazyHTML.query(full, "p.behavior-full-text") |> LazyHTML.text() == long
    assert LazyHTML.query(document, "main article p.entity-text") |> LazyHTML.text() =~ "Step 1:"

    send(view.pid, :reconcile)
    document = LazyHTML.from_document(render(view))

    assert LazyHTML.query(document, "main details.behavior-full") |> LazyHTML.attribute("id") == [
             "behavior-#{rule.ref}-full"
           ]

    assert LazyHTML.query(document, "main details.behavior-menu") |> LazyHTML.attribute("id") == [
             "behavior-#{rule.ref}-menu"
           ]

    assert LazyHTML.query(document, "main details.behavior-full p.behavior-full-text")
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
          {"/schedules", nil},
          {"/follow-ups", nil},
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

    # Schedules and Follow-ups narrow by Current and Past instead, and a
    # refresh keeps the view as well as the search.
    for path <- ["/schedules", "/follow-ups"] do
      {:ok, view, _} =
        live(build_conn() |> Map.put(:host, "localhost"), path <> "?q=emisar&view=past")

      assert has_element?(view, "nav.segmented a[aria-current=page]", "Past")
      send(view.pid, :reconcile)
      assert has_element?(view, "nav.segmented a[aria-current=page]", "Past")
      assert has_element?(view, "form.filter-toolbar input[name=view][value=past]")
      assert has_element?(view, "form.filter-toolbar input[name=q][value=emisar]")
    end
  end

  test "usage drilldowns show each filter as a chip and removing one keeps the others" do
    # The old banner hid the selected profile, model and scope behind generic text.
    path = "/activity?mode=all&q=health&usage_profile=emisar&usage_window=30d"
    {:ok, view, _} = live(build_conn() |> Map.put(:host, "localhost"), path)

    assert has_element?(
             view,
             ".filter-chip[data-filter=usage_profile] .filter-chip-value",
             "emisar"
           )

    assert has_element?(
             view,
             ".filter-chip[data-filter=usage_window] .filter-chip-value",
             "Last 30 days"
           )

    assert has_element?(view, ".filter-toolbar-controls a", "Back to Usage")

    view |> element("#filter-add") |> render_click()
    assert has_element?(view, "#filter-popover .filter-field[data-field=state]", "Request state")
    assert has_element?(view, "#filter-popover .filter-field[data-field=usage_actor]", "User")
    refute has_element?(view, "#filter-popover .filter-field[data-field=usage_profile]")

    view
    |> element(".filter-chip[data-filter=usage_profile] .filter-chip-remove")
    |> render_click()

    next = assert_patch(view)

    assert URI.decode_query(URI.parse(next).query) ==
             %{"mode" => "all", "q" => "health", "usage_window" => "30d"}
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

  test "choosing a value in a field's submenu applies the filter at once, and search keeps it" do
    # Andrew, 2026-09-19: the add dropdown sat first and reset as it added, and
    # nothing applied until a separate button. + Filter now comes last, each
    # field opens its values beside the list, and a value applies immediately.
    {:ok, view, _} = live(build_conn() |> Map.put(:host, "localhost"), "/activity?q=old")
    view |> element("#filter-add") |> render_click()
    view |> element("#filter-values-transport button[phx-value-choice=slack]") |> render_click()
    assert_patch(view, "/activity?q=old&transport=slack")
    assert has_element?(view, ".filter-chip[data-filter=transport] .filter-chip-value", "Slack")
    refute has_element?(view, "#filter-popover")

    render_change(view, "search-activity", %{"q" => "new", "mode" => "all"})
    assert_patch(view, "/activity?mode=all&q=new&transport=slack")
    assert has_element?(view, ".filter-chip[data-filter=transport]")

    view |> element(".filter-toolbar-controls a", "Clear") |> render_click()
    assert_patch(view, "/activity")
    refute has_element?(view, ".filter-chip")
  end

  test "a free-text filter applies when its value is submitted and Escape closes the menu" do
    {:ok, view, _} = live(build_conn() |> Map.put(:host, "localhost"), "/activity")
    view |> element("#filter-add") |> render_click()
    view |> form("#filter-values-repository form", %{"choice" => "emisar"}) |> render_submit()
    assert_patch(view, "/activity?repository=emisar")
    assert has_element?(view, ".filter-chip[data-filter=repository] .filter-chip-value", "emisar")

    view |> element("#filter-add") |> render_click()
    assert has_element?(view, "#filter-popover")
    render_keydown(view, "filter-menu-close", %{"key" => "Escape"})
    refute has_element?(view, "#filter-popover")
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

  test "Chat is the primary navigation item and carries no Lab or test phrasing" do
    # The navigation, browser title, accessible labels and action labels said
    # Conversation Lab / Test a message / Send a test message; the surface is
    # an ordinary way to talk to the agent, not a test bench.
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, html} = live(conn, "/conversations")
    assert page_title(view) == "Conversations · Ryker"

    assert has_element?(
             view,
             ".app-sidebar nav[aria-label='Main navigation'] a[href='/conversations'][aria-current=page]",
             "Chat"
           )

    [conversations, home | _rest] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(".app-sidebar nav[aria-label='Main navigation'] a")
      |> LazyHTML.attribute("href")

    assert conversations == "/conversations"
    assert home == "/"
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
          "Ready for your message",
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

    refute has_element?(view, ".lab-chat", "Send a message")
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

  test "Chat replaces the composer with its actual worker readiness", %{counters: counters} do
    Agent.update(counters, &Map.put(&1, :chat_readiness, :worker_unavailable))

    {:ok, view, _html} =
      live(build_conn() |> Map.put(:host, "localhost"), "/conversations")

    assert has_element?(view, ".lab-readiness", "Chat is waiting for its worker")

    assert has_element?(
             view,
             ".lab-readiness",
             "The bundled worker is offline or still starting."
           )

    refute has_element?(view, "form.lab-native-composer")

    Agent.update(counters, &Map.put(&1, :chat_readiness, :ready))
    render_hook(view, "refresh", %{})

    refute has_element?(view, ".lab-readiness")
    assert has_element?(view, "form.lab-native-composer")
  end

  test "the composer placeholder is one of ten authored examples and holds still through patches" do
    # A placeholder that re-rolled on every refresh flickered under the
    # operator's eyes every five seconds. It is chosen once per opened view
    # and is never the field's value.
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
  end

  test "a new conversation lists the ten examples above its composer and an open one does not" do
    # Andrew, 2026-09-19: the examples hid behind an Examples dropdown in a top
    # bar while a new conversation's page stood empty. They now fill that empty
    # space, between the transcript and the composer, so the composer keeps the
    # place it has in an open conversation. Each one only fills the composer.
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, draft, _} = live(conn, "/conversations")
    html = render(draft)

    examples =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(".lab-column > #lab-examples li > button.lab-example[type=button]")

    assert LazyHTML.attribute(examples, "data-example") == LabPage.examples()
    assert Enum.map(examples, &(LazyHTML.text(&1) |> String.trim())) == LabPage.examples()
    refute has_element?(draft, "#lab-examples form, #lab-examples a, #lab-examples details")
    refute has_element?(draft, "#lab-examples button[type=submit]")

    [history, list, dock] =
      Enum.map(
        [~s(id="lab-history"), ~s(id="lab-examples"), ~s(class="lab-composer-dock")],
        &(:binary.match(html, &1) |> elem(0))
      )

    assert history < list and list < dock

    {:ok, open, _} = live(conn, "/conversations/#{Ecto.UUID.generate()}")
    refute has_element?(open, "#lab-examples")
    refute has_element?(open, ".lab-example")
  end

  test "the examples read as what Ryker does: three headed groups holding each example once" do
    # Andrew, 2026-09-19: a plain black list of ten sentences was loud and dull.
    # He chose, from rendered alternatives, quiet columns headed by what Ryker
    # does, so the empty state also says what the agent is for.
    {:ok, draft, _} = live(build_conn() |> Map.put(:host, "localhost"), "/conversations")

    groups =
      render(draft)
      |> LazyHTML.from_document()
      |> LazyHTML.query("#lab-examples .lab-example-group")

    assert Enum.map(groups, &(LazyHTML.query(&1, "h2") |> LazyHTML.text() |> String.trim())) ==
             ["Investigate", "Build", "Remember"]

    assert Enum.all?(groups, &(Enum.count(LazyHTML.query(&1, "h2 svg")) == 1))

    grouped =
      Enum.flat_map(
        groups,
        &LazyHTML.attribute(LazyHTML.query(&1, "button.lab-example"), "data-example")
      )

    assert Enum.sort(grouped) == Enum.sort(LabPage.examples())
    assert length(Enum.uniq(grouped)) == 10
  end

  test "a conversation keeps no chrome around its composer: no top-bar links, limit hint or authority note" do
    # Andrew, 2026-09-19: an Examples dropdown and a Settings link in a top
    # bar, a permanent "Up to 2 files · 8 MiB" hint, "Saved on acceptance" and
    # the "Local replies · real tools" note sat on every conversation and said
    # nothing he needed. The bar remains only to open the directory on phones;
    # the file limits are explained beside the composer when a choice breaks
    # them, and the only hint left is how to send.
    conn = build_conn() |> Map.put(:host, "localhost")

    for path <- ["/conversations", "/conversations/#{Ecto.UUID.generate()}"] do
      {:ok, view, _} = live(conn, path)
      html = render(view)
      document = LazyHTML.from_document(html)

      toolbar = LazyHTML.query(document, ".lab-chat-toolbar")
      assert Enum.count(LazyHTML.query(toolbar, "button[data-lab-directory-toggle]")) == 1
      assert Enum.empty?(LazyHTML.query(toolbar, "a, details, summary"))
      refute has_element?(view, ".lab-chat a[href='/configuration']")

      refute html =~ "Local replies"
      refute html =~ "configured authority"
      refute html =~ "Up to 2 files"
      refute html =~ "Saved on acceptance"

      assert LazyHTML.query(document, ".lab-composer-dock > .lab-chat-footer")
             |> LazyHTML.text()
             |> String.trim() == "⌘ / Ctrl + Enter to send"

      assert has_element?(
               view,
               "form.lab-native-composer input#lab-attachments[type=file][aria-describedby=lab-attachments-error]"
             )

      assert has_element?(
               view,
               "form.lab-native-composer #lab-attachments-error.composer-error[role=alert][hidden]"
             )
    end
  end

  test "the directory reads as grouped titles and says when it is empty" do
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, empty, _} = live(conn, "/conversations")
    assert has_element?(empty, ".lab-directory-empty", "No conversations yet")
    assert has_element?(empty, ".lab-directory-empty", "Send a message and it will appear here.")
    refute has_element?(empty, ".lab-directory-empty .ui-icon")
    refute has_element?(empty, ".lab-directory-empty a, .lab-directory-empty button")
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

    # The list is scanned: a short time on the row, the full UTC time on hover.
    times = LazyHTML.query(document, ".lab-directory-list time")
    assert LazyHTML.text(times) =~ ~r/\d\d:\d\d|\d\d [A-Z][a-z]{2}/
    assert Enum.all?(LazyHTML.attribute(times, "title"), &(&1 =~ "UTC"))
    refute html =~ "inputs ·"
    refute html =~ "RECENT CONVERSATIONS"
  end

  test "the directory says what each conversation needs and names it after its work" do
    # Andrew, 2026-09-24: a conversation whose reply never arrived looked the
    # same as one that was answered, and every row was titled by its opening
    # line. Each row now carries one status from its inputs and their work, so
    # stopped work reads as needing attention and never as still working, and
    # the title Ryker gave the work replaces the opening line once it exists.
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "lab-live-test",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    routing = Ecto.UUID.generate()
    stopped = Ecto.UUID.generate()
    answered = Ecto.UUID.generate()

    {:ok, _} = ConversationLab.send_message(routing, "Still routing", profile)

    {:ok, %{entry: stopped_entry}} =
      ConversationLab.send_message(stopped, "Stops midway", profile)

    {_episode, turn} = claimed_turn!(stopped, stopped_entry, profile)

    Repo.get!(Ryker.Work.Turn, turn.id)
    |> Ecto.Changeset.change(
      status: :blocked,
      lease_ref: nil,
      lease_owner: nil,
      lease_expires_at: nil,
      next_attempt_at: nil
    )
    |> Repo.update!()

    {:ok, %{entry: answered_entry}} = ConversationLab.send_message(answered, "hey there", profile)
    {episode, reply} = accepted_reply!(answered, answered_entry, "Hello.", profile)

    Repo.get_by!(Ryker.Episodes.RoutingDigest, episode_id: episode.id)
    |> Ecto.Changeset.change(
      title: "Greeting",
      title_turn_id: reply.id,
      title_updated_at: DateTime.utc_now()
    )
    |> Repo.update!()

    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _} = live(conn, "/conversations")
    row = fn id -> ".lab-directory-list a[href='/conversations/#{id}']" end

    assert has_element?(view, row.(routing) <> " [data-status=working]", "Working")
    assert has_element?(view, row.(stopped) <> " [data-status=attention]", "Needs attention")
    assert has_element?(view, row.(answered) <> " [data-status=replied]", "Replied")

    assert has_element?(view, row.(answered) <> " .lab-directory-title", "Greeting")
    refute has_element?(view, row.(answered), "hey there")
    assert has_element?(view, row.(routing) <> " .lab-directory-title", "Still routing")
  end

  test "an inspection link opens beside the conversation instead of replacing it" do
    # Andrew, 2026-09-19: "View request ↗" navigated away from the conversation
    # being read. Every per-message inspection link now opens a new tab, and
    # says so to assistive technology as well as with the arrow.
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "lab-live-test",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    id = Ecto.UUID.generate()
    {:ok, %{entry: first}} = ConversationLab.send_message(id, "First question", profile)
    accepted_reply!(id, first, "The first answer.", profile)
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _} = live(conn, "/conversations/#{id}")

    links =
      render(view)
      |> LazyHTML.from_document()
      |> LazyHTML.query("#lab-messages a.lab-message-inspect")

    assert Enum.count(links) == 2
    assert LazyHTML.attribute(links, "target") == ["_blank", "_blank"]
    assert LazyHTML.attribute(links, "rel") == ["noopener", "noopener"]
    assert LazyHTML.attribute(links, "data-phx-link") == []
    assert Enum.all?(links, &(LazyHTML.text(&1) =~ "opens in a new tab"))
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
             "Timeline"
           )

    assert has_element?(
             view,
             "#lab-messages .lab-message-progress[data-phase=Queued]",
             "Waiting to route your message"
           )

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
      "/timeline/#{URI.encode_www_form(episode.key)}?attempt=#{turn.id}#request-#{turn.id}"

    assert has_element?(
             view,
             "#lab-messages a.lab-message-inspect[href='#{reply_href}']",
             "Timeline"
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
    assert has_element?(admission, "[id^='admission-#{first.id}-']")
    {:ok, work, _} = live(conn, reply_href |> String.split("#", parts: 2) |> hd())
    assert has_element?(work, "#request-#{turn.id}")

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
             "Timeline"
           )

    refute has_element?(view, "#lab-messages a[href*='#{episode.key}'][href*='#{second.id}']")
    assert find_all(view, ".lab-message-progress") == []
  end

  test "a conversation patches an unchanged message when its work phase advances" do
    # A queued message stayed on "0.0s" until navigation because the transcript
    # stream keyed updates only to message data. Admission progress changes must
    # replace that existing row as soon as the conversations domain is invalidated.
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "lab-live-test",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    id = Ecto.UUID.generate()
    {:ok, %{entry: entry}} = ConversationLab.send_message(id, "Track this work", profile)
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _html} = live(conn, "/conversations/#{id}")

    assert has_element?(
             view,
             ".lab-message-progress[data-phase=Queued]",
             "Waiting to route your message"
           )

    assert has_element?(view, ".lab-progress-elapsed[phx-hook=ElapsedTime]", "now")
    refute render(view) =~ "waiting for a slot"
    assert_receive {:lab_projected, 1}
    flush_lab_projections()

    now = DateTime.utc_now()
    lease_ref = "ingress-lease:#{Ecto.UUID.generate()}"

    claimed =
      entry
      |> EntryChangeset.claim(%{
        attempt_count: entry.attempt_count + 1,
        last_error_code: nil,
        last_error_detail: nil,
        lease_expires_at: DateTime.add(now, 60, :second),
        lease_owner: "live-progress-test",
        lease_ref: lease_ref,
        next_attempt_at: nil
      })
      |> Repo.update!()

    settings = %{
      lease_ref: lease_ref,
      now: fn -> now end,
      policy: "admission",
      policy_digest: String.duplicate("a", 64)
    }

    {:ok, _attempt} = Attempts.prepare(claimed, settings)

    :ok =
      Attempts.observe(
        claimed,
        "provider_running",
        %{execution_target: "recorded-target"},
        settings
      )

    assert {:ok, %{admission_progress: [%{phase: "Working"}]}} =
             Projection.lab_conversation(id)

    Phoenix.PubSub.broadcast(
      PubSub,
      "control-plane:conversations",
      :control_plane_changed
    )

    assert_receive {:lab_projected, 1}, 2_000
    assert has_element?(view, ".lab-message-progress[data-phase=Working]", "Routing your message")
    refute render(view) =~ "Provider running"
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

    # Once the turn is working again the failure line is gone and the transcript
    # shows one quiet typing indicator until the reply arrives.
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
    refute has_element?(view, "#lab-messages .lab-message-state", "Working")
    assert has_element?(view, "#lab-messages .lab-typing-indicator", "working on a reply")
    assert length(find_all(view, ".lab-typing-indicator")) == 1
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
             "form.lab-edit-form[phx-submit='edit-lab-message'] input[name=item_id][value='#{item_id}']"
           )

    assert has_element?(
             view,
             ".lab-message-actions form.lab-delete-form[phx-submit='delete-lab-message'] input[name=item_id][value='#{item_id}']"
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

    pills = LazyHTML.query(reply, ".lab-reaction-pills form.lab-reaction-pill")
    assert Enum.count(pills) == 2

    assert LazyHTML.attribute(pills, "phx-submit") == [
             "react-to-lab-message",
             "react-to-lab-message"
           ]

    assert LazyHTML.attribute(pills, "action") == []

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
    # Andrew, 2026-09-19: as in Slack, the control ends the reactions row
    # under the reply, right after the pills, and it is an icon, not a word.
    [picker_id] =
      LazyHTML.query(
        reply,
        ".lab-reactions > .lab-reaction-pills + button.lab-reaction-toggle[type=button][aria-expanded=false]"
      )
      |> LazyHTML.attribute("aria-controls")

    toggle = LazyHTML.query(reply, ".lab-reaction-toggle")
    assert LazyHTML.attribute(toggle, "aria-label") == ["Add reaction"]
    assert LazyHTML.attribute(toggle, "title") == ["Add reaction"]
    assert LazyHTML.text(toggle) |> String.trim() == ""
    assert Enum.count(LazyHTML.query(toggle, "svg")) == 1
    refute has_element?(view, ".lab-message-actions .lab-reaction-toggle")

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

    # With nothing recorded yet, the control alone starts the row.
    assert Enum.count(
             LazyHTML.query(bare, ".lab-reactions > button.lab-reaction-toggle:first-child")
           ) ==
             1

    # Removing the operator's heart travels through the LiveView event and the
    # returned stream patch owns the new reaction count.
    heart_form =
      reply
      |> LazyHTML.query("form.lab-reaction-pill")
      |> Enum.find(fn form ->
        LazyHTML.query(form, "input[name=emoji]") |> LazyHTML.attribute("value") == ["heart"]
      end)

    [heart_form_id] = LazyHTML.attribute(heart_form, "id")
    view |> form("##{heart_form_id}") |> render_submit()
    refute has_element?(view, "##{heart_form_id}")
  end

  test "an operator message edits in place through one hidden editor bound to that message" do
    # The Edit disclosure opened a second textarea under the message with an
    # "Edit message" heading and a full-width bar. The editor is now one hidden
    # LiveView form per editable message, bound to that message's exact durable
    # identifiers and token, holding the stored body, with Cancel and Save at
    # its lower edge.
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

    assert LazyHTML.attribute(editor, "phx-submit") == ["edit-lab-message"]
    assert LazyHTML.attribute(editor, "action") == []

    assert LazyHTML.attribute(editor, "data-lab-edit") == [item_id]

    assert LazyHTML.query(editor, "input[name=conversation_id]") |> LazyHTML.attribute("value") ==
             [id]

    assert LazyHTML.query(editor, "input[name=item_id]") |> LazyHTML.attribute("value") == [
             item_id
           ]

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

    # Delete stays beside Edit as its own authenticated LiveView form.
    assert has_element?(
             view,
             ".lab-message-actions form.lab-delete-form[phx-submit='delete-lab-message'] button.lab-message-delete",
             "Delete"
           )

    assert has_element?(
             view,
             ".lab-message-actions form.lab-delete-form input[name=conversation_id][value='#{id}']"
           )

    # The mutation stays on the LiveView connection and immediately refreshes
    # the retained projection; no document navigation or parallel fetch owns it.
    view
    |> form("#lab-edit-#{item_id}", %{message: "Updated in place"})
    |> render_submit()

    assert has_element?(view, ".chat-message-text", "Updated in place")
    refute has_element?(view, ".chat-message-text", "Stored body with **markdown**")

    view |> form("#lab-delete-#{item_id}") |> render_submit()
    assert has_element?(view, ".chat-message-text", "Message deleted")
    refute has_element?(view, "#lab-edit-#{item_id}")
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

  test "an episode has one continuous execution document without a duplicate request page" do
    {:ok, %{episode: episode}} =
      Ryker.Episodes.apply(Ryker.Fixtures.Episodes.admit_input())

    path = "/timeline/" <> URI.encode_www_form(episode.key)
    {:ok, view, _html} = live(build_conn() |> Map.put(:host, "localhost"), path)
    assert has_element?(view, "#execution-timeline", "Execution timeline")
    assert has_element?(view, ".case-event", "Input admitted")
    refute has_element?(view, "button.execution-event")
    refute has_element?(view, "nav[aria-label='Episode view']")
    refute has_element?(view, "a", "Model calls")
    refute render(view) =~ "/model-calls"
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

    assert has_element?(
             view,
             ".lab-message-progress[data-phase=Queued]",
             "Waiting to route your message"
           )

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
    assert has_element?(view, @active_count, "9")
    Agent.update(counters, &Map.put(&1, :active, 12))
    {:ok, remounted, _html} = live(conn, "/")
    assert has_element?(remounted, @active_count, "12")
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

  test "an input keeps one canonical timeline while routing adds evidence and becomes work" do
    {entry, _id} = lab_input!()
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _} = live(conn, "/timeline/ingress-input%3A#{entry.id}")

    assert has_element?(view, "#execution-timeline")
    # A routing call that has not started has no card yet; its queue card says
    # what the input is waiting for.
    refute has_element?(view, "#admission-#{entry.id}-1")
    assert has_element?(view, ".input-queue")
    refute has_element?(view, ".model-inspector")

    Repo.insert!(%Ryker.Admission.Attempt{
      input_id: entry.id,
      generation: 1,
      policy: "admission",
      policy_digest: String.duplicate("b", 64),
      phase: "response_received",
      milestones: %{
        "context_prepared" => DateTime.to_iso8601(entry.inserted_at),
        "response_received" => DateTime.to_iso8601(DateTime.add(entry.inserted_at, 2, :second))
      },
      response: %{"state" => "completed"}
    })

    render_hook(view, "refresh", %{})
    assert has_element?(view, "#admission-#{entry.id}-1", "Routing briefing")
    assert has_element?(view, "#admission-#{entry.id}-1-result", "Routing result")
    refute has_element?(view, ".model-inspector")

    # Assignment adds the work stages without changing the page into another
    # product or replacing the routing history with a separate inspector.
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
    assert has_element?(view, "#execution-timeline")

    admission_ids =
      render(view)
      |> LazyHTML.from_document()
      |> LazyHTML.query("[id^='admission-#{entry.id}-']")
      |> LazyHTML.attribute("id")

    assert "admission-#{entry.id}-1" in admission_ids
    refute has_element?(view, ".model-inspector")

    {:ok, reopened, _} =
      live(conn, "/timeline/ingress-input%3A#{entry.id}?generation=1")

    assert has_element?(reopened, "#execution-timeline")
    assert has_element?(reopened, "#admission-#{entry.id}-1")
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
    assert html_response(confirmation, 200) =~ "Read this message again?"
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

    for path <- ~w(memory memory/findings repositories channels follow-ups working-copies) do
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

  test "no memory page hides settings in a drawer; learning is switched from its own page" do
    # Until 2026-09-24 the only learning control was a closed "Learning
    # settings" drawer at the foot of /memory, below every learned topic.
    assert {:ok, _snapshot} = Ryker.Settings.initialize("control-plane:local")
    conn = build_conn() |> Map.put(:host, "localhost")

    for path <- ~w(/memory /memory/learned /memory/findings /memory/learning) do
      {:ok, view, _html} = live(conn, path)
      refute has_element?(view, "details.area-settings"), path
      assert has_element?(view, "#learning-switch") == (path == "/memory/learning"), path
    end

    {:ok, view, _html} = live(conn, "/memory/learning")

    assert has_element?(
             view,
             "header.page-header .page-action #learning-switch button",
             "Turn off learning"
           )

    view |> element("#learning-switch button") |> render_click()
    refute Ryker.Settings.fetch!().learning.enabled
    assert has_element?(view, "#learning-switch button", "Turn on learning")

    view |> element("#learning-switch button") |> render_click()
    assert Ryker.Settings.fetch!().learning.enabled
    assert has_element?(view, "#learning-switch button", "Turn off learning")
  end

  test "the learning switch shows a change made elsewhere instead of overwriting it" do
    assert {:ok, snapshot} = Ryker.Settings.initialize("control-plane:local")
    {:ok, view, _html} = live(build_conn() |> Map.put(:host, "localhost"), "/memory/learning")

    # Someone else turns learning off after this page was read.
    assert {:ok, _changed} =
             Ryker.Settings.save_learning(
               %{enabled: false},
               snapshot.installation.revision,
               "control-plane:local"
             )

    view |> element("#learning-switch button", "Turn off learning") |> render_click()
    assert has_element?(view, "#learning-switch [role=alert]", "Settings changed somewhere else")
    assert has_element?(view, "#learning-switch button", "Turn on learning")
    refute Ryker.Settings.fetch!().learning.enabled
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
    assert has_element?(view, @active_count, "1")
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

  defp flush_lab_projections do
    receive do
      {:lab_projected, _count} -> flush_lab_projections()
    after
      0 -> :ok
    end
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
  defp current_segments(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("main nav.segmented a[aria-current=page]")
    |> Enum.map(&LazyHTML.text/1)
  end

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
