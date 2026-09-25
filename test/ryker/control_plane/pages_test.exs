defmodule Ryker.ControlPlane.PagesTest do
  @moduledoc """
  The secondary pages the live shell renders from `Pages.page/3`: every bounded
  read-only operator view against the projection doubles, the links between
  them, and the answer for a missing or unavailable record.

  These assertions used to run against static GET routes the HTTP router kept
  for the same pages. Those routes were unreachable in production because the
  live routes won, so the page body prepared here is the whole contract now.
  """
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.{HTML, Pages, RunningSystem}
  alias Ryker.Fixtures.ControlPlaneOptions

  test "operator actions are buttons while inspection remains navigation" do
    # Text links made recovery actions look like more inspection pages.
    for path <- [
          "/failures",
          "/failures/delivery/delivery%3Aone",
          "/working-copies",
          "/memory",
          "/schedules/schedule%3Aone"
        ] do
      # A record's own controls may sit opposite its title, in the page action.
      page = page(path)
      document = LazyHTML.from_fragment(page.body <> Map.get(page, :action, ""))
      assert LazyHTML.query(document, "a[href^='/actions/']") |> LazyHTML.to_tree() == []

      buttons =
        LazyHTML.query(document, "form[method='get'][action^='/actions/'] button[type='submit']")

      assert LazyHTML.to_tree(buttons) != [], "#{path} must expose native action buttons"
      refute LazyHTML.text(buttons) =~ "…"
    end

    # A failure's name is the way into its own page; its button is an action.
    names = body("/failures") |> LazyHTML.query("article .entity-name a[href^='/failures/']")
    assert Enum.count(names) == Enum.count(body("/failures") |> LazyHTML.query("article"))
  end

  test "renders every bounded read-only operator view without external assets" do
    # The kind still leads, so a heading never reads as a bare reference — but
    # the reference stays visible, because a page of rows all titled
    # "Slack channel" tells an operator nothing about which channel they are on.
    channel = page("/channels/T123/C456")
    assert channel.title == "Slack channel C456"
    document = HTML.page(channel.title, channel.description, channel.body)
    assert document =~ "<h1>Slack channel C456</h1>"
    refute document =~ "<h1>C456</h1>"

    for {path, marker} <- [
          {"/memory", "Needs review"},
          {"/memory/learned", "Deploys happen after 15:00 UTC on weekdays."},
          {"/memory/learning", "2 messages waiting"},
          {"/incident-rooms", "Slack channels Ryker opens to work on an incident"},
          {"/incident-rooms/incident%3Aone", "Timeline of the room"},
          {"/schedules", "To add a schedule"},
          {"/schedules/schedule%3Aone", "What it asks for"},
          {"/follow-ups", "Follow-ups"},
          {"/channels", "Slack channels Ryker is in"},
          {"/channels/T123/C456", "What Ryker knows"},
          {"/repositories", "Code Ryker can read and work in."},
          {"/working-copies", "Working copies"},
          {"/memory/findings", "Findings"}
        ] do
      page = page(path)
      assert page.status == 200, path
      rendered = HTML.page(page.title, page.description, page.body)
      assert rendered =~ marker, path
      refute rendered =~ "<script", path
    end

    # The running system's evidence is part of Settings › Advanced now.
    evidence =
      options().projection.operator_configuration.()
      |> RunningSystem.html()

    assert evidence =~ "Work execution"
    refute evidence =~ "<script"

    usage = page("/usage", %{"window" => "24h"})
    assert usage.title == "Usage & cost"
    assert usage.body =~ "Total tokens"
    assert usage.body =~ "claude:opus/high@work"

    memory = page("/memory")
    assert memory.title == "Facts"
    assert memory.description =~ "never as permission"
    assert memory.body =~ "Across the workspace"
    refute memory.body =~ "slack:T123"
    assert memory.body =~ "Keep separate"
  end

  test "incident rooms have one canonical page with their actual room-only scope" do
    page = page("/incident-rooms")
    assert page.title == "Incident rooms"

    assert page.description == "Slack channels Ryker opens to work on an incident with your team."

    assert page.body =~ "href=\"/incident-rooms/incident%3Aone\""
    refute page.body =~ "Incident rooms and local incidents"
    assert page("/incident-rooms/incident%3Aone").status == 200
    assert page("/incident-rooms", %{"q" => "room", "status" => "blocked"}).status == 200

    for path <- ["/incidents", "/incidents/incident%3Aone", "/audit"] do
      assert page(path).status == 404, path
    end
  end

  test "failures names the work that needs attention" do
    failure_page = page("/failures")

    assert failure_page.title == "Failures"

    assert failure_page.description ==
             "Work Ryker could not finish on its own. Each one says what happened, what it affects and what you can do."
  end

  # The page found a failure by listing a hundred and searching them, so the
  # hundred-and-first could be listed nowhere and opened by no link.
  test "a failure opens by its reference, not by being among the listed hundred" do
    options = put_in(options(), [:projection, :failures], fn _params -> {:ok, []} end)
    delivery = page("/failures/delivery/delivery%3Aone", %{}, options)
    assert delivery.status == 200
    assert delivery.title == "Posting a reply stopped"
    assert delivery.description =~ "The reply is written, but the person has not received it."
  end

  # Incident rooms were the last list outside the Kit (2026-09-24): a framed
  # table with a tinted header, the room's reference under its title and a
  # filled status pill, beside Channels and Schedules saying the same kinds of
  # things as rows. Andrew: "Look how different all those pages are." A list of
  # rooms is the same kind of thing as a list of channels, so it looks the same.
  test "incident rooms are Kit rows under the shared toolbar, in words and short times" do
    document = body("/incident-rooms")

    assert LazyHTML.query(document, ".incident-rooms-view > .kit-toolbar > form.filter-toolbar")
           |> Enum.count() == 1

    assert LazyHTML.query(document, ".kit-toolbar select[name=status] option[value=ready]")
           |> LazyHTML.text() == "Open"

    assert document |> LazyHTML.query(".kit-toolbar-count") |> LazyHTML.text() |> String.trim() ==
             "1 incident room"

    [row] = LazyHTML.query(document, ".entity-list > article.entity-row") |> Enum.to_list()

    assert LazyHTML.query(row, ".entity-name a[href='/incident-rooms/incident%3Aone']")
           |> LazyHTML.text() == "Investigate latency"

    assert LazyHTML.query(row, ".entity-side .state-word[data-tone=on]") |> LazyHTML.text() ==
             "Open"

    assert LazyHTML.query(row, ".entity-meta a[href='/timeline/episode%3Aincident']")
           |> LazyHTML.text() == "investigation"

    # When it opened is the row's edge, under the heading of its day.
    assert LazyHTML.query(row, ".entity-side time[datetime='2026-08-28T11:55:00Z']")
           |> LazyHTML.text() == "11:55"

    assert LazyHTML.query(row, ".entity-group") |> LazyHTML.text() != ""

    # No table, no filled pill, no raw reference or ISO stamp in the list.
    assert LazyHTML.query(document, "table, .ui-status, code") |> LazyHTML.to_tree() == []
    refute LazyHTML.text(document) =~ "incident:one"
    refute LazyHTML.text(document) =~ "2026-08-28T"

    # An empty page first says which it is: nothing matches, or nothing exists,
    # and how a room gets opened, since only asking Ryker opens one.
    none = put_in(options(), [:projection, :incidents], fn _params -> [] end)

    empty = page("/incident-rooms", %{}, none).body |> LazyHTML.from_fragment()

    assert LazyHTML.query(empty, ".entity-empty .entity-empty-title") |> LazyHTML.text() ==
             "No incident rooms yet"

    assert LazyHTML.query(empty, ".entity-empty") |> LazyHTML.text() =~ "Create incident room"

    assert LazyHTML.query(empty, ".ask-hint q") |> LazyHTML.text() ==
             "Open an incident room for this."

    assert page("/incident-rooms", %{"status" => "closed"}, none).body =~
             "No incident rooms match"
  end

  test "record views are the Kit's facts, rows and states, never tables" do
    # A room's page: its state a dot and a word under the title, its facts as
    # label and value, what Ryker recorded and the channel's history as rows,
    # and every time short with its exact value kept.
    incident = body("/incident-rooms/incident%3Aone")
    assert LazyHTML.query(incident, "table, .table-wrap, .ui-status") |> LazyHTML.to_tree() == []
    assert LazyHTML.query(incident, ".kit-status-line .state-word") |> LazyHTML.text() == "Open"

    assert LazyHTML.query(incident, "#room dl.kit-facts a[href='/channels/T123/CINCIDENT']")
           |> Enum.count() == 1

    assert LazyHTML.query(incident, "#code-change .state-word[data-tone=warn]")
           |> LazyHTML.text() == "Code change needs attention"

    assert LazyHTML.query(incident, "#investigation .entity-empty-title") |> LazyHTML.text() ==
             "Nothing recorded yet"

    assert LazyHTML.query(incident, "#room-timeline .entity-name")
           |> Enum.map(&String.trim(LazyHTML.text(&1))) == [
             "Room requested",
             "Ryker joined the channel"
           ]

    refute LazyHTML.text(incident) =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/
    assert LazyHTML.query(incident, "time[datetime]") |> LazyHTML.to_tree() != []
    # References stay in the closed Details disclosure.
    assert LazyHTML.query(incident, "details#incident-room-details:not([open])") |> Enum.count() ==
             1

    # A schedule's page is the Kit's rows, not a table: its state and each run's
    # are a dot and a word, and every time is short with its exact value kept.
    schedule = body("/schedules/schedule%3Aone")
    assert LazyHTML.query(schedule, "table, .table-wrap, .ui-status") |> LazyHTML.to_tree() == []
    assert LazyHTML.query(schedule, ".kit-status-line .state-word") |> LazyHTML.text() == "On"
    assert LazyHTML.query(schedule, ".entity-row .state-word") |> LazyHTML.text() == "Completed"
    refute LazyHTML.text(schedule) =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/
    assert LazyHTML.query(schedule, "time[datetime]") |> LazyHTML.to_tree() != []

    # Facts are rows on the page, never a table: one fact and two reviews.
    memory = body("/memory")
    assert Enum.empty?(LazyHTML.query(memory, "table"))
    assert LazyHTML.query(memory, ".entity-list > article.entity-row") |> Enum.count() == 3
  end

  test "channel detail pagers reach the projection through the page's own query, bounded" do
    # The channel route never fetched its query string, so a `?summary_page=2`
    # link could only ever render page one.
    assert page("/channels/T123/C456", %{
             "summary_page" => "2",
             "episode_page" => "3",
             "q" => "x",
             "page" => "9"
           }).status == 200

    assert_received {:channel_params, params}
    assert params == %{"summary_page" => "2", "episode_page" => "3"}

    assert page("/channels/T123/C456", %{
             "usage_window" => "24h",
             "mode" => "live",
             "window" => "all"
           }).status == 200

    assert_received {:channel_params, %{"usage_window" => "24h", "mode" => "live"} = usage_params}
    refute Map.has_key?(usage_params, "window")

    assert page("/channels/T123/C456", %{"schedule_page" => "4", "unknown" => "1"}).status == 200
    assert_received {:channel_params, %{"schedule_page" => "4"} = snapshot_params}
    refute Map.has_key?(snapshot_params, "unknown")
  end

  # The failures page listed publication failures and linked each one, and the
  # router then answered 404 because its allowlist of failure kinds had never
  # learned about publications. Three real ones were unreachable in production.
  test "every failure kind the page links is a kind the page will open" do
    links =
      body("/failures")
      |> LazyHTML.query("a[href^='/failures/']")
      |> LazyHTML.attribute("href")
      |> Enum.uniq()

    assert Enum.any?(links, &String.starts_with?(&1, "/failures/publication/"))

    for href <- links do
      assert page(href).status == 200, "#{href} is linked but does not open"
    end
  end

  test "the failures page names each blocked custody, its cause and its exact recovery action" do
    failures = page("/failures")
    assert failures.status == 200
    assert failures.body =~ "/timeline/episode%3Aone"
    assert failures.body =~ "/failures/admission/ingress-input%3Aone"
    assert failures.body =~ "3 attempts"
    assert failures.body =~ "/actions/delivery/delivery%3Aone/rearm"
    # References and raw destinations belong to a failure's Technical details.
    refute failures.body =~ "delivery:one"
    refute failures.body =~ "slack:T123:C456"

    # Every failure a retry could help offers it on the list; one a retry
    # cannot help (an invite list with a person Slack will not add) offers it
    # only on its own page, beside the reason it will fail.
    for {kind, ref, action} <- [
          {"admission", "ingress-input:one", "rearm"},
          {"work", "episode:blocked", "retry"},
          {"emisar", "approval:one", "rearm"},
          {"slack_interaction", "interaction:one", "rearm"}
        ] do
      encoded_ref = URI.encode(ref, &URI.char_unreserved?/1)
      assert failures.body =~ "/actions/#{kind}/#{encoded_ref}/#{action}"
    end

    refute failures.body =~ "/actions/slack_incident/"
    incident = page("/failures/slack_incident/incident-room%3Aone")
    assert incident.body =~ "/actions/slack_incident/incident-room%3Aone/rearm"
    assert incident.body =~ "Will fail"

    admission = page("/failures/admission/ingress-input%3Aone")
    assert admission.status == 200
    assert admission.body =~ "github:github-main"
    assert admission.body =~ "github-delivery-one"
    assert admission.body =~ "github:github-main:repository:99"
    assert admission.body =~ "3 attempts"
    assert admission.body =~ "stored diagnostic sha256:"
    refute admission.body =~ "Frozen validation result was uncertain"

    delivery = page("/failures/delivery/delivery%3Aone")
    assert delivery.status == 200
    assert delivery.body =~ "stored diagnostic sha256:"
    refute delivery.body =~ "Slack returned HTTP 503"
  end

  test "the working copies page offers recovery from the exact current cleanup state" do
    workspaces = page("/working-copies")
    assert workspaces.status == 200
    assert workspaces.body =~ "workspace:blocked"
    assert workspaces.body =~ "/actions/retention/workspace%3Ablocked/rearm"
    assert workspaces.body =~ "/actions/retention/workspace%3Aunmerged/discard"
    refute workspaces.body =~ "/actions/retention/workspace%3Adirty/discard"
  end

  test "failure collection errors remain unavailable instead of appearing empty" do
    unavailable =
      options()
      |> put_in([:projection, :failures], fn _params -> {:error, :database_unavailable} end)
      |> put_in([:projection, :failure], fn _kind, _ref -> {:error, :database_unavailable} end)

    assert page("/failures", %{}, unavailable).status == 503
    assert page("/failures/delivery/delivery%3Aone", %{}, unavailable).status == 503
  end

  test "an unavailable record page is reported, never rendered as a page" do
    for {path, projection, unavailable} <- [
          {"/incident-rooms/incident%3Aone", :incident,
           fn _ref -> {:error, :database_unavailable} end},
          {"/schedules/schedule%3Aone", :schedule,
           fn _ref -> {:error, :database_unavailable} end},
          {"/channels/T123/C456", :channel,
           fn _workspace, _channel, _params -> {:error, :database_unavailable} end}
        ] do
      options = put_in(options(), [:projection, projection], unavailable)
      assert %{status: 503, title: "Unavailable"} = page(path, %{}, options), path
    end
  end

  test "a missing page or record is one not-found body under the shell's title" do
    # Before 2026-09-13 a missing channel said "No durable records in this
    # view" under a heading that was just the word "Channel", and an unknown
    # URL said the same under "Page".
    for path <- [
          "/never-a-page",
          "/",
          "/activity",
          "/configuration",
          "/instructions",
          "/conversations",
          "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
          "/timeline/episode%3Aone",
          "/timeline/episode%3Aone/model-calls",
          "/card-lab",
          "/lab",
          "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
          "/decisions",
          "/calibration",
          "/schedules/missing",
          "/incident-rooms/missing",
          "/channels/T999/C999",
          "/channels/T123",
          "/failures/delivery/missing",
          "/failures/unknown-kind/delivery%3Aone",
          "/failures/delivery/%FF"
        ] do
      page = page(path)
      assert page.status == 404, path
      assert page.title == "Not found", path
      assert page.description == nil, path
      document = LazyHTML.from_fragment(page.body)

      assert LazyHTML.query(document, "section.document-unavailable p") |> LazyHTML.text() =~
               "does not exist or is no longer available"

      assert LazyHTML.query(document, "a.ui-button[href='/']") |> LazyHTML.text() ==
               "Back to activity"

      assert Enum.empty?(LazyHTML.query(document, "h1, h2")), path
    end

    assert page("/channels/T999/C999").body =~ "This channel does not exist"
    assert page("/schedules/missing").body =~ "This schedule does not exist"
    assert page("/never-a-page").body =~ "This page does not exist"
  end

  test "a page carries its projection's query untouched and takes only the keys it lists" do
    # Search and filter state is the URL; a page that dropped or invented a key
    # would render a list the address did not ask for.
    assert page("/schedules", %{"q" => "health", "status" => "paused", "page" => "2"}).status ==
             200

    assert page("/usage", %{"window" => "7d", "mode" => "shadow", "page" => "2"}).status == 200

    parent = self()

    memory =
      put_in(options(), [:projection, :memory], fn params ->
        send(parent, {:memory, params})
        %{memories: [], reviews: []}
      end)

    assert page("/memory", %{"kind" => "context", "q" => "deploy"}, memory).status == 200
    assert_received {:memory, params}
    assert params == %{"q" => "deploy"}
  end

  defp page(path, params \\ %{}, options \\ options()) do
    Pages.page(String.split(path, "/", trim: true), params, options)
  end

  defp body(path) do
    page = page(path)
    assert page.status == 200, "#{path} answered #{page.status}"
    LazyHTML.from_fragment(page.body)
  end

  defp options, do: ControlPlaneOptions.options(self())
end
