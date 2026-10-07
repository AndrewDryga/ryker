defmodule Ryker.ControlPlane.FindingsPageTest do
  use Ryker.DataCase, async: false
  import Ryker.TestHelpers, only: [outline: 2]
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2]
  import Phoenix.LiveViewTest

  @endpoint Ryker.ControlPlane.Endpoint

  alias Ryker.ControlPlane.{Actions, Endpoint, EpisodeProjection, FindingsPage}
  alias Ryker.ControlPlane.{FindingsProjection, Pages, Projection, Router}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: Fixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Records
  alias Ryker.Records.Findings
  alias Ryker.Repo
  alias Ryker.StateTools.Tools
  alias Ryker.Work.Custody

  # Host-contract fixture: the page used to display a payload hash and OPEN
  # instead of the saved conclusion, its classification and supporting evidence.
  test "findings show conclusions and their evidence rather than storage hashes" do
    {claim, options} = claim!()

    assert {:ok, %{"record_ref" => evidence_ref}} =
             Tools.call(
               "cite_source",
               %{
                 "subject" => "Declared configuration",
                 "observation" =>
                   "The checked-out configuration deliberately disables this service.",
                 "source_ref" => "source:configuration",
                 "relation" => "supports",
                 "supersedes" => []
               },
               options
             )

    args = %{
      "what" => "Zero instances are intentional",
      "status" => "expected",
      "reason" => "The service is disabled in configuration; live deployment is unverified.",
      "scope" => "Repository intent",
      "cause_evidence" => [evidence_ref]
    }

    assert {:ok, %{"record_ref" => ref}} = Tools.call("record_finding", args, options)
    view = FindingsProjection.list(%{})
    assert view.total == 1
    assert [finding] = view.items
    assert finding.classification == "expected"
    assert finding.what == args["what"]
    evidence = Repo.get_by!(Ryker.Records.Record, ref: evidence_ref)
    record = Repo.get_by!(Ryker.Records.Record, ref: ref)
    assert {:ok, detail} = FindingsProjection.fetch(record.id)
    assert [%{text: observation, path: path}] = detail.evidence
    assert observation =~ "deliberately disables"
    episode_path = "/timeline/" <> claim.episode.id
    # Findings and evidence must land on actual timeline cards, not dead fragments.
    assert path == episode_path <> "#event-record-" <> evidence.id
    assert detail.path == episode_path <> "#event-record-" <> record.id
    html = render_component(&FindingsPage.render/1, view: view)
    # The populated page used to wrap every finding inside a second tall white
    # panel, shrinking the mobile reading column with redundant nested padding.
    refute html =~ "memory-card"
    assert html =~ "Zero instances are intentional"
    assert html =~ "Expected"
    refute html =~ ">Open<"
    refute html =~ record.payload_fingerprint
    assert FindingsPage.html(view) |> IO.iodata_to_binary() =~ "Zero instances are intentional"

    page = detail |> FindingsPage.finding_html() |> IO.iodata_to_binary()
    assert page =~ observation
    assert page =~ "Open the investigation"
    assert page =~ "Show on the timeline"
    refute page =~ record.payload_fingerprint
  end

  test "findings lead with how many there are and how many are unexplained, and can be searched" do
    # QA, 2026-09-25: Findings had no counts row and no search, unlike every
    # other list, so the only way to find one was to scroll.
    {_claim, options} = claim!()

    assert {:ok, %{"record_ref" => evidence}} =
             Tools.call(
               "cite_source",
               %{
                 "subject" => "Declared configuration",
                 "observation" => "The configuration deliberately disables this service.",
                 "source_ref" => "source:configuration",
                 "relation" => "supports",
                 "supersedes" => []
               },
               options
             )

    for {what, status, cause} <- [
          {"Checkout readiness failed after the deploy", "unexplained", []},
          {"Zero instances are intentional", "expected", [evidence]}
        ] do
      assert {:ok, _} =
               Tools.call(
                 "record_finding",
                 %{
                   "what" => what,
                   "status" => status,
                   "reason" => "Recorded for the Findings list.",
                   "scope" => nil,
                   "cause_evidence" => cause
                 },
                 options
               )
    end

    counts = fn params ->
      render_component(&FindingsPage.render/1, view: FindingsProjection.list(params))
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".kit-counts .kit-count")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
    end

    assert counts.(%{}) == ["2 findings", "1 not explained yet"]
    assert counts.(%{"q" => "checkout"}) == ["1 matching", "1 not explained yet"]
    assert counts.(%{"q" => "intentional"}) == ["1 matching"]

    document =
      render_component(&FindingsPage.render/1, view: FindingsProjection.list(%{"q" => "absent"}))
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(
             document,
             ".kit-toolbar form.filter-toolbar input[name=q][value=absent]"
           )
           |> Enum.count() == 1

    assert LazyHTML.query(document, ".kit-empty-title") |> LazyHTML.text() ==
             ~s(No findings match "absent")
  end

  test "an empty findings page says what puts a finding there and offers no way to make one" do
    html = render_component(&FindingsPage.render/1, view: FindingsProjection.list(%{}))
    assert html =~ "No findings yet"
    assert html =~ "When Ryker investigates a problem, it saves what it concluded here"
    refute html =~ "Create finding"
    refute html =~ "does not currently expose a tool"
    refute html =~ "page-help"
  end

  test "a finding is one line in the list and opens its own page with why and the evidence" do
    # Before 2026-09-24 each finding was a framed card headed by its
    # classification ("Explained by evidence"), under a "How findings work"
    # disclosure and a separate count; the conclusion itself was body text.
    # Andrew, 2026-09-28: the rows that followed, each with its reason, a
    # collapsible of evidence and buttons, were "REALLY heavy, too much text
    # and nobody will be able to use it". A row is one line now; the rest is
    # on the finding's own page.
    empty = render_stub(%{items: [], total: 0, page: 1, pages: 1})
    assert outline(empty, "div.memory-view > *") == ["p.kit-counts", "div.kit-empty"]

    assert Enum.empty?(
             LazyHTML.query(empty, "h1, h2, details.page-help, p.result-count, a[href='/lab']")
           )

    long = String.duplicate("Latency came from the retry storm ", 8)

    populated =
      render_stub(%{
        total: 1,
        page: 1,
        pages: 1,
        views: %{"explained" => 1},
        items: [
          %{
            id: "finding-1",
            classification: "explained",
            status: :open,
            what: long,
            scope: "Portal API",
            at: ~U[2026-09-10 09:00:00Z]
          }
        ]
      })

    assert outline(populated, "div.memory-view > *") == [
             "p.kit-counts",
             "div.kit-toolbar",
             "div.entity-list"
           ]

    row = LazyHTML.query(populated, "article.entity-row#finding-finding-1")
    name = row |> LazyHTML.query("h3.entity-name") |> LazyHTML.text() |> String.trim()
    assert String.starts_with?(name, "Latency came from the retry storm")
    assert String.ends_with?(name, "…")
    assert String.length(name) < String.length(long)

    assert LazyHTML.query(row, "h3.entity-name a") |> LazyHTML.attribute("href") ==
             ["/memory/findings?finding=finding-1"]

    assert LazyHTML.query(row, ".state-word[data-tone=on]") |> LazyHTML.text() == "Explained"
    assert LazyHTML.query(row, ".entity-meta") |> LazyHTML.text() =~ "Portal API"
    assert Enum.empty?(LazyHTML.query(row, ".entity-text, details, form, button"))

    page =
      %{
        id: "finding-1",
        classification: "unexplained",
        status: :open,
        what: "Latency came from the retry storm",
        reason: "Every timeout retried three times",
        scope: "Portal API",
        at: ~U[2026-09-10 09:00:00Z],
        path: "/timeline/0193a5d2-7c1e-7b8a-9f00-00000000e01e#event-record-1",
        evidence: [
          %{
            text: "Retry counter climbed to 3",
            label: "Show on the timeline",
            path: "/timeline/0193a5d2-7c1e-7b8a-9f00-00000000e01e#event-record-2"
          }
        ]
      }
      |> FindingsPage.finding_html()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert page |> LazyHTML.query("#finding-status .state-word") |> LazyHTML.text() ==
             "Not explained yet"

    facts = page |> LazyHTML.query("#finding-facts") |> LazyHTML.text()
    assert facts =~ "Every timeout retried three times"
    assert facts =~ "Portal API"

    assert page
           |> LazyHTML.query(
             "#finding-facts a[href='/timeline/0193a5d2-7c1e-7b8a-9f00-00000000e01e#event-record-1']"
           )
           |> LazyHTML.text() == "Open the investigation"

    # Evidence reads in the page's flow, not boxed with 52px of empty space
    # above it, as a section straight under the page was (2026-09-28).
    assert page |> LazyHTML.query("div.memory-view > section#evidence") |> Enum.count() == 1

    assert page |> LazyHTML.query("#evidence .entity-row") |> LazyHTML.text() =~
             "Retry counter climbed to 3"

    assert page
           |> LazyHTML.query(
             "#evidence a[href='/timeline/0193a5d2-7c1e-7b8a-9f00-00000000e01e#event-record-2']"
           )
           |> LazyHTML.text() == "Show on the timeline"

    assert Enum.empty?(LazyHTML.query(page, "details"))

    # What a person can do comes last, forgetting at the very end.
    assert outline(page, "section.kit-card") == ["section.kit-card", "section.kit-card"]

    assert page |> LazyHTML.query("section.kit-card") |> LazyHTML.attribute("id") ==
             ["mark-explained", "forget-finding"]

    for {classification, tone, word} <- [
          {"unexplained", "warn", "Not explained yet"},
          {"expected", "off", "Expected"},
          {"out_of_scope", "off", "Out of scope"}
        ] do
      document =
        render_stub(%{
          total: 1,
          page: 1,
          pages: 1,
          items: [
            %{
              id: "finding-1",
              classification: classification,
              status: :open,
              what: "A conclusion",
              scope: nil,
              at: ~U[2026-09-10 09:00:00Z]
            }
          ]
        })

      assert LazyHTML.query(document, ".state-word[data-tone=#{tone}]") |> LazyHTML.text() == word
    end

    paged = render_stub(%{items: [], total: 60, page: 2, pages: 2})
    assert outline(paged, "div.memory-view > *") |> List.last() == "nav.pagination"

    assert LazyHTML.query(paged, "nav.pagination a[href='/memory/findings']")
           |> LazyHTML.text() =~
             "Previous"
  end

  # Andrew, 2026-09-28: Findings "need a toggle filter to see only explained,
  # unexplained, etc".
  test "the toggle shows only the findings in one view, and a search keeps it" do
    {_claim, options} = claim!()
    open = finding!(options, "Checkout pods restart after every deploy", "unexplained")
    _elsewhere = finding!(options, "The probe timeout is shorter than warm-up", "out_of_scope")
    _expected = finding!(options, "Zero replicas in staging are intentional", "expected")

    all = findings()

    assert all |> LazyHTML.query("nav.segmented a") |> Enum.map(&LazyHTML.text/1) ==
             ["All", "Not explained yet", "Expected", "Out of scope"]

    assert all |> LazyHTML.query("nav.segmented a") |> LazyHTML.attribute("href") == [
             "/memory/findings",
             "/memory/findings?view=unexplained",
             "/memory/findings?view=expected",
             "/memory/findings?view=out_of_scope"
           ]

    unexplained = findings(%{"view" => "unexplained"})
    assert counts(unexplained) == ["1 matching"]

    assert unexplained |> LazyHTML.query("article.entity-row") |> LazyHTML.attribute("id") ==
             ["finding-#{open.id}"]

    assert unexplained
           |> LazyHTML.query("form.filter-toolbar input[type=hidden][name=view]")
           |> LazyHTML.attribute("value") == ["unexplained"]

    # Marked explained, it moves to Explained.
    assert {:ok, _} = Findings.mark_explained(open.id)

    assert findings(%{"view" => "unexplained"})
           |> LazyHTML.query("article.entity-row")
           |> Enum.count() == 0

    explained = findings(%{"view" => "explained"})

    assert explained |> LazyHTML.query("article.entity-row") |> LazyHTML.attribute("id") ==
             ["finding-#{open.id}"]
  end

  test "the findings route carries its title and plain description, and no help" do
    page =
      Pages.page(["memory", "findings"], %{}, %{
        projection: %{findings: fn _params -> %{items: [], total: 0, page: 1, pages: 1} end}
      })

    assert page.title == "Findings"

    assert page.description ==
             "Conclusions Ryker reached in investigations, with the evidence behind them."

    assert LazyHTML.from_fragment(page.body)
           |> LazyHTML.query("details.page-help")
           |> Enum.empty?()
  end

  test "older findings stay readable without dead jumps beyond the episode record window" do
    {claim, options} = claim!()

    args = %{
      "what" => "An older useful conclusion",
      "status" => "unexplained",
      "reason" => nil,
      "scope" => nil,
      "cause_evidence" => []
    }

    assert {:ok, %{"record_ref" => ref}} = Tools.call("record_finding", args, options)
    original = Repo.get_by!(Ryker.Records.Record, ref: ref)
    template = Map.take(original, Ryker.Records.Record.__schema__(:fields) -- [:sequence])

    newer =
      Enum.map(1..500, fn index ->
        id = Ecto.UUID.generate()

        Map.merge(template, %{
          id: id,
          kind: "progress",
          ref: "record:progress:#{id}",
          operation_id: "newer-#{index}",
          payload: %{"phase" => "checking", "summary" => "Later work"}
        })
      end)

    Repo.insert_all(Ryker.Records.Record, newer)
    assert {:ok, detail} = EpisodeProjection.fetch(claim.episode.key)
    refute Enum.any?(detail.trace.steps, &(&1.id == "record-#{original.id}"))
    assert [finding] = FindingsProjection.list(%{}).items
    assert finding.what == "An older useful conclusion"
    assert {:ok, detail} = FindingsProjection.fetch(original.id)
    assert detail.path == "/timeline/" <> claim.episode.id
  end

  test "finding prose and linked evidence cross the redaction and escaping boundary" do
    {claim, options} = claim!()

    assert {:ok, _} =
             Tools.call(
               "record_finding",
               %{
                 "what" => "<script>alert(1)</script> password=findings-hidden-secret",
                 "status" => "unexplained",
                 "reason" => nil,
                 "scope" => nil,
                 "cause_evidence" => []
               },
               options
             )

    view = FindingsProjection.list(%{})
    refute inspect(view) =~ "findings-hidden-secret"
    html = render_component(&FindingsPage.render/1, view: view)
    refute html =~ "<script>"
    refute html =~ "findings-hidden-secret"
    assert html =~ "Not explained yet"
    assert {:ok, episode} = EpisodeProjection.fetch(claim.episode.key)
    refute inspect(episode.trace.steps) =~ "findings-hidden-secret"
  end

  test "a finding can be marked explained or forgotten, each asking first, and Ryker stops using it" do
    # Andrew, 2026-09-27, of Findings: "any actions I should be able to do on
    # those?" A finding could only be opened; one Ryker could not explain
    # counted as not explained yet for good, and a wrong one kept feeding the
    # investigation and later requests.
    {claim, options} = claim!()
    open = finding!(options, "Checkout pods restart after every deploy", "unexplained")
    wrong = finding!(options, "Zero replicas in staging are intentional", "expected")

    rows = findings()
    assert counts(rows) == ["2 findings", "1 not explained yet"]
    assert actions(open.id) == ["Mark explained", "Forget finding"]
    assert actions(wrong.id) == ["Forget finding"]

    # Each opens its confirmation first, and confirming comes back to the
    # finding's own page.
    marked = confirm("/actions/finding/#{open.id}/mark-explained")
    assert marked.status == 303

    assert Plug.Conn.get_resp_header(marked, "location") == [
             "/memory/findings?finding=#{open.id}"
           ]

    assert confirm("/actions/finding/#{wrong.id}/forget").status == 303

    rows = findings()
    assert counts(rows) == ["2 findings"]
    assert state(rows, open.id) == "Marked explained"
    assert state(rows, wrong.id) == "Forgotten"
    assert actions(open.id) == []
    assert actions(wrong.id) == []

    # Ryker no longer reads either: the investigation's own next turns and
    # the related outcomes of later requests read only what it stands by.
    refute Enum.any?(Records.retained_records(claim.episode.id), &(&1["kind"] == "finding"))

    # A settled finding is settled once; only one Ryker could not explain can
    # be marked explained; and its confirmation is gone.
    assert Findings.forget(open.id) == {:error, :finding_settled}
    assert confirmation("/actions/finding/#{open.id}/forget").status == 404

    explained = finding!(options, "The probe timeout is shorter than warm-up", "out_of_scope")
    assert Findings.mark_explained(explained.id) == {:error, :finding_not_unexplained}
    assert confirmation("/actions/finding/#{explained.id}/mark-explained").status == 404
  end

  # The heading's title was the conclusion as safe HTML, a {:safe, iodata} tuple.
  # LiveView sends the page title to the browser as JSON, Jason cannot encode a
  # tuple, and so a finding's own page rendered once and never connected
  # (2026-10-04 review). The title is the conclusion's opening words as text.
  test "a finding's own page connects, titled with its conclusion as plain text" do
    {_claim, options} = claim!()
    finding = finding!(options, "**Checkout** pods restart after `every` deploy", "unexplained")

    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.PubSub.Server,
       live_view: [signing_salt: "findings-page-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: Actions.callbacks(),
         projection: Projection.callbacks(),
         observability: %{},
         csrf_secret: String.duplicate("s", 32)
       }}
    )

    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _html} = live(conn, "/memory/findings?finding=#{finding.id}")

    assert page_title(view) == "Checkout pods restart after every deploy · Ryker"
    assert has_element?(view, ".memory-topic-text strong", "Checkout")
  end

  defp finding!(options, what, status) do
    assert {:ok, %{"record_ref" => ref}} =
             Tools.call(
               "record_finding",
               %{
                 "what" => what,
                 "status" => status,
                 "reason" => "Recorded for the Findings actions.",
                 "scope" => nil,
                 "cause_evidence" => []
               },
               options
             )

    Repo.get_by!(Ryker.Records.Record, ref: ref)
  end

  defp findings(params \\ %{}) do
    render_component(&FindingsPage.render/1, view: FindingsProjection.list(params))
    |> LazyHTML.from_fragment()
  end

  defp counts(document) do
    document
    |> LazyHTML.query(".kit-counts .kit-count")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  defp state(document, id),
    do: document |> LazyHTML.query("#finding-#{id} .state-word") |> LazyHTML.text()

  # The buttons on the finding's own page.
  defp actions(id) do
    {:ok, finding} = FindingsProjection.fetch(id)

    finding
    |> FindingsPage.finding_html()
    |> IO.iodata_to_binary()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("form[method=get] button")
    |> Enum.map(&LazyHTML.text/1)
  end

  defp confirmation(path) do
    Plug.Test.conn(:get, path)
    |> Map.put(:host, "localhost")
    |> Router.call(router())
  end

  defp confirm(path) do
    page = confirmation(path)
    assert page.status == 200, page.resp_body
    [_, token] = Regex.run(~r/name="_token" value="([^"]+)"/, page.resp_body)

    Plug.Test.conn(:post, path, URI.encode_query(%{"_token" => token}))
    |> Map.put(:host, "localhost")
    |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Router.call(router())
  end

  defp router do
    Router.init(%{
      csrf_secret: String.duplicate("s", 32),
      actions: Actions.callbacks(),
      observability: %{},
      projection: Projection.callbacks()
    })
  end

  defp render_stub(view) do
    render_component(&FindingsPage.render/1, view: view) |> LazyHTML.from_fragment()
  end

  defp claim! do
    suffix = Ecto.UUID.generate()

    assert {:ok, transition} =
             Episodes.apply(
               Fixtures.admit_input(%{
                 episode_id: Ecto.UUID.generate(),
                 episode_key: "finding-ui:#{suffix}",
                 native_input_id: "source:#{suffix}",
                 turn_ref: "turn:#{suffix}",
                 execution_mode: :shadow
               })
             )

    assert {:ok, _} =
             WorkSessions.pin_episode(
               transition.episode.id,
               "test-policy",
               String.duplicate("a", 64),
               repository_ref: "ryker"
             )

    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 60)

    {claim,
     %{
       binding: %{
         episode: claim.episode,
         session: claim.session,
         turn: claim.turn,
         state_token: Records.token(claim.turn)
       }
     }}
  end
end
