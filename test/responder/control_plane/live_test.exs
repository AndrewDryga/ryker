defmodule Responder.ControlPlane.LiveTest do
  use Responder.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Responder.ControlPlane.{CardLab, ConversationLab, LiveSocket, Projection}
  alias Responder.ControlPlane.LabPage
  alias Responder.ControlPlane.WorkbenchLive
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.WorkProfile

  alias Responder.ControlPlane.Endpoint

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
          schedules: fn _params -> [] end
        })
    }

    start_supervised!(
      {Endpoint,
       [
         server: false,
         secret_key_base: String.duplicate("s", 64),
         pubsub_server: Responder.ControlPlane.PubSub,
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
    assert html =~ "Requests"
    assert html =~ "No requests yet"
    refute html =~ "class=\"metric\""
    assert has_element?(view, "[data-connection-state=connected]")
    assert has_element?(view, "[data-active-count]", "1")

    Agent.update(counters, &Map.put(&1, :active, 7))

    Phoenix.PubSub.broadcast(
      Responder.ControlPlane.PubSub,
      "control-plane",
      :control_plane_changed
    )

    assert_receive {:overview_projected, 7}
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

  test "malformed usage filters cannot crash navigation or search links" do
    # Nested URL values reached URI.encode_query as maps instead of scalars.
    for query <- [
          "usage_profile[x]=a",
          "usage_profile=x&usage_window[x]=a",
          "usage_profile=" <> String.duplicate("x", 513)
        ] do
      conn = build_conn() |> Map.put(:host, "localhost")
      assert {:ok, view, _html} = live(conn, "/episodes?" <> query)
      assert render(view) =~ "Requests"
      view |> element("#activity-filters") |> render_change(%{"q" => "hello", "mode" => "live"})
      assert render(view) =~ "Requests"
    end
  end

  test "every searchable operator list keeps the search and exposes its supported status filter" do
    # Query-string status filters were invisible, and every refresh emptied search.
    for {path, status} <- [
          {"/incidents", "blocked"},
          {"/schedules", "paused"},
          {"/subscriptions", "timed_out"},
          {"/channels", nil},
          {"/repositories", nil}
        ] do
      query = URI.encode_query(%{"q" => "emisar", "status" => status || ""})
      {:ok, view, _} = live(build_conn() |> Map.put(:host, "localhost"), path <> "?" <> query)
      assert has_element?(view, "form.search-form input[name=q][value=emisar]")
      assert has_element?(view, "form.search-form a[href='#{path}']", "Clear filters")

      if status,
        do: assert(has_element?(view, "select[name=status] option[value='#{status}'][selected]"))

      send(view.pid, :reconcile)
      assert has_element?(view, "form.search-form input[name=q][value=emisar]")
    end
  end

  test "usage drilldowns expose editable criteria and clearing one keeps the other filters" do
    # The old banner hid the selected profile, model and scope behind generic text.
    path = "/episodes?mode=all&q=health&usage_profile=emisar&usage_model=&usage_window=30d"
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
  end

  test "editing search preserves pending criteria but clearing all resets them" do
    {:ok, view, _} = live(build_conn() |> Map.put(:host, "localhost"), "/episodes?q=old")
    render_change(view, "edit-request-filters", %{"add_filter" => "usage_profile"})

    render_change(view, "edit-request-filters", %{
      "criteria" => %{
        "usage_profile" => %{"match" => "equals", "value" => "emisar"}
      }
    })

    render_change(view, "search-activity", %{"q" => "new", "mode" => "all"})
    assert_patch(view, "/episodes?mode=all&q=new")
    assert has_element?(view, "#criterion-usage_profile[value=emisar]")
    view |> element("a", "Clear all filters") |> render_click()
    assert_patch(view, "/episodes")
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
    refute html =~ "Test your responder"
    assert has_element?(view, "h1", "Requests")
    refute has_element?(view, ".app-topbar")
    refute has_element?(view, "button[phx-click=toggle-live]")
    refute has_element?(view, "#live-controls")
    assert has_element?(view, ".connection-offline", "Reconnecting")
    assert has_element?(view, "#activity-filters")
  end

  test "native directory entry points and missing records remain usable across live navigation" do
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _} = live(conn, "/lab")
    assert has_element?(view, ".lab-start", "Test a conversation")
    assert has_element?(view, ".lab-start-notes", "Real tools, local replies")
    assert has_element?(view, ".lab-start-notes", "Repository and Emisar actions")
    assert has_element?(view, ".lab-start-notes a[href='/configuration']")
    assert has_element?(view, ".lab-start a[href='/lab/new']")
    refute has_element?(view, ".lab-directory a[href='/lab/new']")
    view |> element(".app-sidebar a", "Slack Card Lab") |> render_click()
    assert_redirect(view, "/card-lab")
    {:ok, cards, _} = live(conn, "/card-lab")
    assert has_element?(cards, ".specimen-workbench")

    for path <- [
          "/episodes/missing",
          "/card-lab/missing/state",
          "/episodes/ingress-input%3A#{Ecto.UUID.generate()}"
        ] do
      {:ok, missing, _} = live(conn, path)
      assert has_element?(missing, "a", "Back to activity")
    end

    {:ok, secondary, _} = live(conn, "/manual-tests")
    assert has_element?(secondary, ".secondary-page", "Manual")
    send(secondary.pid, :reconcile)
    assert render(secondary) =~ "secondary-page"
  end

  test "native card previews explain which material is retained and which state is simulated" do
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _} = live(conn, "/card-lab/task-card/working")
    assert has_element?(view, "[aria-label='Example provenance']", "Retained progress")
    assert has_element?(view, ".specimen-provenance", "not an archived Slack payload")
    view |> element("button[phx-value-id=next-recorded]") |> render_click()
    assert_patch(view, "/card-lab/task-card/working-validation")
    assert has_element?(view, ".specimen-provenance", "2026-08-14T05:51:23.132457Z")

    {:ok, simulated, _} = live(conn, "/card-lab/task-card/waiting-for-input")
    assert has_element?(simulated, ".specimen-provenance", "State simulation")

    {:ok, goals, _} = live(conn, "/card-lab/task-card/recorded-goals")
    assert has_element?(goals, ".specimen-provenance", "not a captured engineering task")
  end

  test "populated usage connects and refreshes without rendering the execution ledger" do
    # The production Usage page entered a rapid reconnect loop: the UNION
    # projection returned UUID bytes, which could not be JSON-encoded by LiveView.
    source = "099bf049-b7c2-4ead-969d-225ec7a3c6d2"

    Repo.insert!(%Responder.Accounting.Execution{
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

  test "card families stay in the side rail with compact navigation for small screens" do
    # A desktop dropdown hid all 18 families; the old expanded catalog also
    # buried the preview on phones. Both layouts must retain every destination.
    {:ok, view, _} =
      live(
        build_conn() |> Map.put(:host, "localhost"),
        "/card-lab/task-card/working?width=compact"
      )

    for card <- CardLab.catalog() do
      assert has_element?(view, "#card-family option[value='#{card.id}']", card.title)

      assert has_element?(
               view,
               ".specimen-catalog nav a[href='/card-lab/#{card.id}/#{hd(card.states).id}?width=compact']",
               card.title
             )
    end

    assert has_element?(view, ".specimen-catalog a[aria-current=page]", "Task card")
    assert has_element?(view, ".specimen-family-mobile #card-family-form")

    {:ok, snapshot} = CardLab.fetch("task-card", "working")

    for state <- snapshot.card.states do
      assert has_element?(view, "#card-state-picker a[data-state='#{state.id}']", state.label)
    end

    view |> element("#card-state-picker a[data-state='recorded-goals']") |> render_click()
    assert_patch(view, "/card-lab/task-card/recorded-goals?width=compact")
    assert has_element?(view, ".specimen-canvas.compact", "Subtasks")

    render_change(view, "card-state", %{"state" => "missing"})
    refute_patched(view)

    assert has_element?(
             view,
             "#card-state-picker a[aria-current=page]",
             "Real goals · layout study"
           )

    view |> element(".specimen-catalog a", "Incident room") |> render_click()
    assert_patch(view, "/card-lab/incident-room/provisioning?width=compact")
    assert has_element?(view, ".specimen-catalog a[aria-current=page]", "Incident room")
    assert has_element?(view, "#card-state-picker a[aria-current=page]", "Provisioning")

    view |> form("#card-family-form", %{card: "task-card"}) |> render_change()
    assert_patch(view, "/card-lab/task-card/working?width=compact")
    assert has_element?(view, ".specimen-catalog a[aria-current=page]", "Task card")
    render_change(view, "card-family", %{"card" => "https://attacker.example"})
    refute_patched(view)
  end

  test "an episode has one continuous execution document and preserves exact request links" do
    {:ok, %{episode: episode}} =
      Responder.Episodes.apply(Responder.Fixtures.Episodes.admit_input())

    path = "/episodes/" <> URI.encode_www_form(episode.key)
    {:ok, view, _html} = live(build_conn() |> Map.put(:host, "localhost"), path)
    assert has_element?(view, "#execution-timeline", "Execution timeline")
    assert has_element?(view, ".case-event", "Input admitted")
    refute has_element?(view, "button.execution-event")
    refute has_element?(view, "nav[aria-label='Episode view']")
    view |> element("a", "All model requests") |> render_click()
    assert_patch(view, path <> "/requests")
    assert has_element?(view, ".model-inspector", "What the model received")
    assert has_element?(view, ".document-unavailable", "No requests recorded")
    assert has_element?(view, "#execution-timeline", "Input admitted")
  end

  test "the native Lab never claims admission before a message exists and streams committed messages" do
    id = Ecto.UUID.generate()
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _html} = live(conn, "/lab/#{id}")
    assert has_element?(view, ".lab-chat", "Ready for your message")
    assert has_element?(view, ".lab-runtime", "No request yet")
    assert has_element?(view, ".lab-native-composer[phx-update=ignore]")

    refute has_element?(view, ".lab-runtime", "Awaiting admission")

    {:ok, profile} =
      WorkProfile.new(%{
        policy: "lab-live-test",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    assert {:ok, _receipt} =
             ConversationLab.send_message(id, "Inspect the request behind this answer", profile)

    Phoenix.PubSub.broadcast(
      Responder.ControlPlane.PubSub,
      "control-plane",
      :control_plane_changed
    )

    assert_receive {:lab_projected, 1}

    assert has_element?(
             view,
             "#lab-messages .chat-message-text",
             "Inspect the request behind this answer"
           )

    assert has_element?(view, ".native-admission-progress", "Queued")
    assert has_element?(view, ".lab-directory-list a", "Inspect the request behind this answer")
    assert has_element?(view, ".lab-message-controls", "Edit")
    assert has_element?(view, ".lab-native-composer[phx-update=ignore]")

    {:ok, _} =
      ConversationLab.send_message(id, "**Evidence** [Run](https://example.invalid/run)", profile)

    render_hook(view, "refresh", %{})
    assert has_element?(view, ".chat-message-text strong", "Evidence")
    assert has_element?(view, ".chat-message-text a[href='https://example.invalid/run']", "Run")
    refute has_element?(view, ".story-byline", "Decided")

    assert has_element?(
             view,
             "a[href*='conversation=control-plane%3Alab%3A#{id}']",
             "All requests"
           )
  end

  test "presentation always follows durable updates and remounts with current data", %{
    counters: counters
  } do
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _html} = live(conn, "/")
    Agent.update(counters, &Map.put(&1, :active, 9))

    Phoenix.PubSub.broadcast(
      Responder.ControlPlane.PubSub,
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
    {:ok, view, _} = live(conn, "/episodes/ingress-input%3A#{entry.id}")
    assert has_element?(view, ".request-reader-heading", "Admission · execution 1")
    entry |> Ecto.Changeset.change(execution_generation: 2) |> Repo.update!()
    render_hook(view, "refresh", %{})
    assert has_element?(view, ".request-reader-heading", "Admission · execution 1")
    assert has_element?(view, ".request-reader[data-generation='1']")
    assert has_element?(view, ".artifact-instructions", "Responder admission instructions")
    assert has_element?(view, ".artifact-context", "Frozen admission context")

    assert has_element?(view, ".request-reader .ui-pagination", "1 / 2")

    # Assignment used to erase the reader's pinned routing attempt mid-inspection.
    {:ok, %{episode: episode}} =
      Responder.Episodes.apply(Responder.Fixtures.Episodes.admit_input())

    Repo.get!(Responder.Ingress.Inbox.Entry, entry.id)
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
      live(conn, "/episodes/ingress-input%3A#{entry.id}?generation=1")

    assert has_element?(reopened, ".request-reader[data-generation='1']")
  end

  test "a blocked admission shows its recovery reason and a correctly bound confirmation" do
    {entry, _id} = lab_input!()

    entry
    |> Ecto.Changeset.change(status: :blocked, last_error_code: "provider_unavailable")
    |> Repo.update!()

    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _} = live(conn, "/episodes/ingress-input%3A#{entry.id}")
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
    {:ok, view, _} = live(conn, "/episodes?target=sol%2Fmedium&repository=emisar&state=active")
    view |> element("a", "Needs you") |> render_click()

    assert_patch(
      view,
      "/episodes?filter=attention&repository=emisar&state=active&target=sol%2Fmedium"
    )

    view |> form("#activity-filters", %{q: "investigate", mode: "live"}) |> render_change()

    assert_patch(
      view,
      "/episodes?filter=attention&mode=live&q=investigate&repository=emisar&state=active&target=sol%2Fmedium"
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

  test "mobile workspace navigation preserves every secondary destination" do
    {:ok, view, _} = live(build_conn() |> Map.put(:host, "localhost"), "/")
    assert has_element?(view, "details.mobile-manage summary", "More")

    for path <-
          ~w(memory findings calibration repositories channels subscriptions lab card-lab manual-tests) do
      assert has_element?(view, ".mobile-manage a[href='/#{path}']")
    end

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
      | messages: [%{actor: :responder, ref: "reply:one"}],
        admission_progress: []
    }

    assert LabPage.announcement(before, after_reply) =~ "1 new reply"
    assert LabPage.announcement(after_reply, after_reply) == nil

    {:ok, view, _} =
      live(build_conn() |> Map.put(:host, "localhost"), "/lab/#{Ecto.UUID.generate()}")

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

  test "the native Card Lab navigates specimens and transitions without external actions" do
    {:ok, view, _} =
      live(build_conn() |> Map.put(:host, "localhost"), "/card-lab/incident-room/provisioning")

    assert has_element?(view, ".specimen-workbench .slack-canvas.surface-message")
    assert has_element?(view, ".specimen-review", "Post to Slack")
    assert has_element?(view, ".specimen-feedback form[phx-update=ignore]")
    view |> element(".preview-width a", "Compact") |> render_click()
    assert has_element?(view, ".specimen-canvas.compact")
    view |> element(".specimen-preview-toolbar a", "Block Kit payload") |> render_click()
    assert has_element?(view, ".specimen-payload", "blocks")

    transition =
      hd(
        CardLab.fetch("incident-room", "provisioning")
        |> elem(1)
        |> Map.fetch!(:state)
        |> Map.fetch!(:transitions)
      )

    view |> element("button[phx-value-id='#{transition.id}']") |> render_click()
    assert_patch(view, "/card-lab/incident-room/#{transition.to}")
    assert has_element?(view, ".specimen-canvas")
    refute has_element?(view, ".legacy-surface")
  end
end
