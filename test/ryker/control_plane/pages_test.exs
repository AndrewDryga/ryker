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

  alias Ryker.ControlPlane.{HTML, Pages}
  alias Ryker.Fixtures.ControlPlaneOptions

  test "operator actions are buttons while inspection remains navigation" do
    # Text links made recovery actions look like more inspection pages.
    for path <- [
          "/failures",
          "/failures/delivery/delivery%3Aone",
          "/workspaces",
          "/memory",
          "/schedules/schedule%3Aone"
        ] do
      document = body(path)
      assert LazyHTML.query(document, "a[href^='/actions/']") |> LazyHTML.to_tree() == []

      buttons =
        LazyHTML.query(document, "form[method='get'][action^='/actions/'] button[type='submit']")

      assert LazyHTML.to_tree(buttons) != [], "#{path} must expose native action buttons"
      refute LazyHTML.text(buttons) =~ "…"
    end

    assert body("/failures") |> LazyHTML.query("a[href^='/failures/']") |> LazyHTML.text() =~
             "Inspect cause"
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
          {"/memory", "Operational memory"},
          {"/incident-rooms", "Track Slack incident rooms"},
          {"/incident-rooms/incident%3Aone", "Room lifecycle"},
          {"/schedules", "How to create a schedule"},
          {"/schedules/schedule%3Aone", "Execution history"},
          {"/subscriptions", "Waits"},
          {"/channels", "Slack channels Ryker knows about"},
          {"/channels/T123/C456", "Conversation summaries"},
          {"/repositories", "Connected repositories"},
          {"/workspaces", "Workspaces"},
          {"/findings", "Findings"}
        ] do
      page = page(path)
      assert page.status == 200, path
      rendered = HTML.page(page.title, page.description, page.body)
      assert rendered =~ marker, path
      refute rendered =~ "<script", path
    end

    # The effective configuration is native Settings content now; its evidence
    # body still opens with the heading the static page carried.
    evidence =
      options().projection.operator_configuration.()
      |> HTML.configuration()
      |> IO.iodata_to_binary()

    assert evidence =~ "Effective host configuration"
    refute evidence =~ "<script"

    usage = page("/usage", %{"window" => "24h"})
    assert usage.title == "Usage & cost"
    assert usage.body =~ "Total tokens"
    assert usage.body =~ "claude:opus/high@work"

    memory = page("/memory")
    assert memory.body =~ "Memory provides context; it does not grant permission"
    assert memory.body =~ "scope workspace (slack:T123); visibility workspace"
    assert memory.body =~ "Keep separate"
  end

  test "incident rooms have one canonical page with their actual room-only scope" do
    page = page("/incident-rooms")
    assert page.title == "Incident rooms"

    assert page.description ==
             "Track Slack incident rooms from setup through closure, with channel status and linked investigation work."

    assert page.body =~ "href=\"/incident-rooms/incident%3Aone\""
    refute page.body =~ "Incident rooms and local incidents"
    assert page("/incident-rooms/incident%3Aone").status == 200
    assert page("/incident-rooms", %{"q" => "room", "status" => "blocked"}).status == 200

    for path <- ["/incidents", "/incidents/incident%3Aone", "/audit"] do
      assert page(path).status == 404, path
    end
  end

  # Incident rooms and the record views were the last pages built before the
  # shared vocabulary: a framed table with a tinted header row, "ready" in
  # lower case where Schedules showed a dot and a word, and raw ISO stamps
  # where every other page said "28 Aug, 12:00 UTC". Two lists that disagree
  # about how a status and a time look are two designs, not one.
  test "incident rooms count, mark status and tell time the way every other list does" do
    document = body("/incident-rooms")

    assert LazyHTML.query(document, ".result-count") |> LazyHTML.text() == "1 incident room"
    assert LazyHTML.query(document, "table.data-table") |> LazyHTML.to_tree() != []
    assert LazyHTML.query(document, ".table-wrap") |> LazyHTML.to_tree() == []

    statuses = LazyHTML.query(document, ".ui-status") |> LazyHTML.text()
    assert statuses =~ "Ready"
    refute page("/incident-rooms").body =~ ">ready<"

    assert LazyHTML.query(document, "time[datetime='2026-08-28T12:00:00Z']") |> LazyHTML.text() =~
             "28 Aug, 12:00 UTC"

    refute LazyHTML.text(document) =~ "2026-08-28T12:00:00Z"

    # An empty page first says which it is: nothing matches, or nothing exists.
    none = put_in(options(), [:projection, :incidents], fn _params -> [] end)

    assert page("/incident-rooms", %{}, none).body =~ "No incident rooms yet"

    assert page("/incident-rooms", %{"status" => "closed"}, none).body =~
             "No incident rooms match these filters."
  end

  test "record views use the same unframed tables, statuses and times as the lists" do
    for path <- ["/incident-rooms/incident%3Aone", "/schedules/schedule%3Aone"] do
      document = body(path)
      assert LazyHTML.query(document, ".table-wrap") |> LazyHTML.to_tree() == [], path
      assert LazyHTML.query(document, "table.data-table") |> LazyHTML.to_tree() != [], path
      assert LazyHTML.query(document, "dl .ui-status") |> LazyHTML.to_tree() != [], path
      refute LazyHTML.text(document) =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/, path
      assert LazyHTML.query(document, "time[datetime]") |> LazyHTML.to_tree() != [], path
    end

    incident = body("/incident-rooms/incident%3Aone")
    assert LazyHTML.query(incident, "dl .ui-status") |> LazyHTML.text() =~ "Ready"
    assert LazyHTML.query(incident, "dl .ui-status") |> LazyHTML.text() =~ "Needs attention"

    assert LazyHTML.query(incident, ".empty-state") |> LazyHTML.text() =~
             "No evidence-backed records"

    memory = body("/memory")
    assert LazyHTML.query(memory, "table .ui-status") |> LazyHTML.text() =~ "Active"
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
    assert failures.body =~ "delivery:one"
    assert failures.body =~ "/timeline/episode%3Aone"
    assert failures.body =~ "/failures/admission/ingress-input%3Aone"
    assert failures.body =~ "slack:T123:C456"
    assert failures.body =~ ">3<"
    assert failures.body =~ "/actions/delivery/delivery%3Aone/rearm"

    for {kind, ref, action} <- [
          {"admission", "ingress-input:one", "rearm"},
          {"work", "episode:blocked", "retry"},
          {"emisar", "approval:one", "rearm"},
          {"slack_interaction", "interaction:one", "rearm"},
          {"slack_incident", "incident-room:one", "rearm"}
        ] do
      encoded_ref = URI.encode(ref, &URI.char_unreserved?/1)
      assert failures.body =~ "/actions/#{kind}/#{encoded_ref}/#{action}"
    end

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

  test "the workspaces page offers recovery from the exact current workspace state" do
    workspaces = page("/workspaces")
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

    assert page("/memory", %{"kind" => "notes", "q" => "deploy"}, memory).status == 200
    assert_received {:memory, %{"kind" => "notes", "q" => "deploy"}}
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
