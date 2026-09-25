defmodule Ryker.ControlPlane.FindingsPageTest do
  use Ryker.DataCase, async: false
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{FindingsPage, Pages, Projection}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: Fixtures
  alias Ryker.Repo
  alias Ryker.State.Records
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
    view = Projection.findings(%{})
    assert view.total == 1
    assert [finding] = view.items
    assert finding.classification == "expected"
    assert finding.what == args["what"]
    assert [%{text: observation, path: path}] = finding.evidence
    assert observation =~ "deliberately disables"
    evidence = Repo.get_by!(Ryker.State.Record, ref: evidence_ref)
    record = Repo.get_by!(Ryker.State.Record, ref: ref)
    episode_path = "/timeline/" <> URI.encode_www_form(claim.episode.key)
    # Findings and evidence must land on actual timeline cards, not dead fragments.
    assert path == episode_path <> "#event-record-" <> evidence.id
    assert finding.path == episode_path <> "#event-record-" <> record.id
    html = render_component(&FindingsPage.render/1, view: view)
    # The populated page used to wrap every finding inside a second tall white
    # panel, shrinking the mobile reading column with redundant nested padding.
    refute html =~ "memory-card"
    assert html =~ "Zero instances are intentional"
    assert html =~ "Expected"
    assert html =~ observation
    assert html =~ "1 piece of evidence"
    assert html =~ "Open investigation"
    refute html =~ ">Open<"
    refute html =~ Repo.get_by!(Ryker.State.Record, ref: ref).payload_fingerprint
    assert FindingsPage.html(view) |> IO.iodata_to_binary() =~ "Zero instances are intentional"
  end

  test "an empty findings page says what puts a finding there and offers no way to make one" do
    html = render_component(&FindingsPage.render/1, view: Projection.findings(%{}))
    assert html =~ "No findings yet"
    assert html =~ "When Ryker investigates a problem, it saves what it concluded here"
    refute html =~ "Create finding"
    refute html =~ "does not currently expose a tool"
    refute html =~ "page-help"
  end

  test "a finding is a row on the page: the conclusion, its state, why, and the evidence one click away" do
    # Before 2026-09-24 each finding was a framed card headed by its
    # classification ("Explained by evidence"), under a "How findings work"
    # disclosure and a separate count; the conclusion itself was body text.
    empty = render_stub(%{items: [], total: 0, page: 1, pages: 1})
    assert outline(empty, "div.memory-view > *") == ["div.entity-empty"]

    assert Enum.empty?(
             LazyHTML.query(empty, "h1, h2, details.page-help, p.result-count, a[href='/lab']")
           )

    populated =
      render_stub(%{
        total: 1,
        page: 1,
        pages: 1,
        items: [
          %{
            id: "finding-1",
            classification: "explained",
            what: "Latency came from the retry storm",
            reason: "Every timeout retried three times",
            scope: "Portal API",
            at: ~U[2026-09-10 09:00:00Z],
            path: "/timeline/episode%3Aone#event-record-1",
            evidence: [
              %{
                text: "Retry counter climbed to 3",
                label: "Show on the timeline",
                path: "/timeline/episode%3Aone#event-record-2"
              }
            ]
          }
        ]
      })

    assert outline(populated, "div.memory-view > *") == ["div.entity-list"]
    row = LazyHTML.query(populated, "article.entity-row#finding-finding-1")

    assert LazyHTML.query(row, "h3.entity-name") |> LazyHTML.text() =~
             "Latency came from the retry storm"

    assert LazyHTML.query(row, ".state-word[data-tone=on]") |> LazyHTML.text() == "Explained"

    assert LazyHTML.query(row, ".entity-text") |> LazyHTML.text() ==
             "Every timeout retried three times"

    meta = LazyHTML.query(row, ".entity-meta")
    assert LazyHTML.text(meta) =~ "Portal API"

    assert LazyHTML.query(meta, "a[href='/timeline/episode%3Aone#event-record-1']")
           |> LazyHTML.text() == "Open investigation"

    evidence = LazyHTML.query(row, "details.memory-evidence:not([open])")
    assert LazyHTML.query(evidence, "summary") |> LazyHTML.text() =~ "1 piece of evidence"
    assert LazyHTML.text(evidence) =~ "Retry counter climbed to 3"

    assert LazyHTML.query(evidence, "a[href='/timeline/episode%3Aone#event-record-2']")
           |> LazyHTML.text() == "Show on the timeline"

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
              what: "A conclusion",
              reason: nil,
              scope: nil,
              at: ~U[2026-09-10 09:00:00Z],
              path: "/timeline/episode%3Aone",
              evidence: []
            }
          ]
        })

      assert LazyHTML.query(document, ".state-word[data-tone=#{tone}]") |> LazyHTML.text() == word
      assert Enum.empty?(LazyHTML.query(document, ".entity-text, details"))
    end

    paged = render_stub(%{items: [], total: 60, page: 2, pages: 2})
    assert outline(paged, "div.memory-view > *") |> List.last() == "nav.pagination"

    assert LazyHTML.query(paged, "nav.pagination a[href='/memory/findings?page=1']")
           |> LazyHTML.text() =~
             "Previous"
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
    original = Repo.get_by!(Ryker.State.Record, ref: ref)
    template = Map.take(original, Ryker.State.Record.__schema__(:fields) -- [:sequence])

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

    Repo.insert_all(Ryker.State.Record, newer)
    assert {:ok, detail} = Projection.episode(claim.episode.key)
    refute Enum.any?(detail.trace.steps, &(&1.id == "record-#{original.id}"))
    assert [finding] = Projection.findings(%{}).items
    assert finding.what == "An older useful conclusion"
    assert finding.path == "/timeline/" <> URI.encode_www_form(claim.episode.key)
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

    view = Projection.findings(%{})
    refute inspect(view) =~ "findings-hidden-secret"
    html = render_component(&FindingsPage.render/1, view: view)
    refute html =~ "<script>"
    refute html =~ "findings-hidden-secret"
    assert html =~ "Not explained yet"
    assert {:ok, episode} = Projection.episode(claim.episode.key)
    refute inspect(episode.trace.steps) =~ "findings-hidden-secret"
  end

  defp render_stub(view) do
    render_component(&FindingsPage.render/1, view: view) |> LazyHTML.from_fragment()
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
             Custody.pin_episode(
               transition.episode.id,
               "test-policy",
               String.duplicate("a", 64),
               "ryker"
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
