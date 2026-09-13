defmodule Ryker.ControlPlane.FindingsPageTest do
  use Ryker.DataCase, async: false
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{FindingsPage, HTML, Projection, Router}
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
    assert html =~ "<div class=\"findings-view\""
    refute html =~ "<section class=\"findings-view\""
    assert html =~ "Zero instances are intentional"
    assert html =~ "Expected behavior"
    assert html =~ observation
    assert html =~ "Supporting evidence"
    assert html =~ "Open investigation"
    refute html =~ ">Open<"
    refute html =~ Repo.get_by!(Ryker.State.Record, ref: ref).payload_fingerprint
    assert HTML.findings(view) |> IO.iodata_to_binary() =~ "Zero instances are intentional"
  end

  test "findings explain creation and follow-up without pretending to be incidents" do
    html = render_component(&FindingsPage.render/1, view: Projection.findings(%{}))
    assert html =~ "Ask Ryker to investigate"
    assert html =~ "follow up in the source conversation"
    assert String.replace(html, ~r/\s+/, " ") =~ "does not create an incident or send a message"
    assert html =~ "No findings yet"
    refute html =~ "does not currently expose a tool"
  end

  test "the findings page is a closed help disclosure, a quiet count and the entries down one column" do
    # Before 2026-09-13 the body opened with its own "What was found" h2 inside
    # a bare page-help div — a second heading under the shell's "Findings" with
    # two paragraphs of always-visible prose — and the count was a bespoke
    # element the other pages did not share.
    document = render_stub(%{items: [], total: 0, page: 1, pages: 1})

    assert outline(document, "div.findings-view > *") == [
             "details.page-help",
             "p.empty-state",
             "div.memory-cards"
           ]

    assert Enum.empty?(
             LazyHTML.query(document, "h1, h2, div.page-help, .findings-count, a[href='/lab']")
           )

    help = LazyHTML.query(document, "details.page-help#findings-help:not([open])")

    assert LazyHTML.query(help, "summary") |> LazyHTML.text() ==
             "How findings are saved and followed up"

    assert LazyHTML.text(help) =~ "not a second list of episodes"
    assert LazyHTML.text(help) =~ "Ask Ryker to investigate"

    assert String.replace(LazyHTML.text(help), ~r/\s+/, " ") =~
             "does not create an incident or send a message"

    # An empty list states itself once; the shared count renders nothing at zero.
    assert Enum.empty?(LazyHTML.query(document, "p.result-count"))
    assert LazyHTML.query(document, "p.empty-state") |> LazyHTML.text() =~ "No findings yet"

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
                label: "Open evidence",
                path: "/timeline/episode%3Aone#event-record-2"
              }
            ]
          }
        ]
      })

    assert LazyHTML.query(populated, "p.result-count") |> LazyHTML.text() == "1 finding"
    assert Enum.empty?(LazyHTML.query(populated, "p.empty-state"))
    card = LazyHTML.query(populated, "article.finding-card#finding-finding-1")
    assert LazyHTML.query(card, "header h2") |> LazyHTML.text() == "Explained by evidence"
    assert LazyHTML.text(card) =~ "Latency came from the retry storm"
    assert LazyHTML.text(card) =~ "Scope: Portal API"

    assert LazyHTML.query(
             card,
             ".finding-evidence a[href='/timeline/episode%3Aone#event-record-2']"
           )
           |> LazyHTML.text() =~ "Open evidence"

    assert LazyHTML.query(card, "footer a[href='/timeline/episode%3Aone#event-record-1']")
           |> LazyHTML.text() =~ "Open investigation"

    paged = render_stub(%{items: [], total: 60, page: 2, pages: 2})
    assert LazyHTML.query(paged, "p.result-count") |> LazyHTML.text() == "60 findings"
    assert outline(paged, "div.findings-view > *") |> List.last() == "nav.pagination"

    assert LazyHTML.query(paged, "nav.pagination a[href='/findings?page=1']") |> LazyHTML.text() =~
             "Previous"
  end

  test "the findings route carries the shell's title and description" do
    page =
      Router.snapshot("/findings", "", %{
        projection: %{findings: fn _params -> %{items: [], total: 0, page: 1, pages: 1} end}
      })

    assert page.title == "Findings"
    assert page.description =~ "Saved investigation conclusions"

    assert LazyHTML.from_fragment(page.body)
           |> LazyHTML.query("div.findings-view details.page-help")
           |> Enum.count() == 1
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
