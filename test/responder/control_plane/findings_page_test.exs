defmodule Responder.ControlPlane.FindingsPageTest do
  use Responder.DataCase, async: false
  import Phoenix.LiveViewTest
  alias Responder.ControlPlane.{FindingsPage, HTML, Projection}
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: Fixtures
  alias Responder.Repo
  alias Responder.State.Records
  alias Responder.StateTools.Tools
  alias Responder.Work.Custody

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
    evidence = Repo.get_by!(Responder.State.Record, ref: evidence_ref)
    record = Repo.get_by!(Responder.State.Record, ref: ref)
    episode_path = "/episodes/" <> URI.encode_www_form(claim.episode.key)
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
    refute html =~ Repo.get_by!(Responder.State.Record, ref: ref).payload_fingerprint
    assert HTML.findings(view) |> IO.iodata_to_binary() =~ "Zero instances are intentional"
  end

  test "findings explain creation and follow-up without pretending to be incidents" do
    html = render_component(&FindingsPage.render/1, view: Projection.findings(%{}))
    assert html =~ "Ask Responder to investigate"
    assert html =~ "follow up in the source conversation"
    assert String.replace(html, ~r/\s+/, " ") =~ "does not create an incident or send a message"
    assert html =~ "No findings yet"
    refute html =~ "does not currently expose a tool"
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
    original = Repo.get_by!(Responder.State.Record, ref: ref)
    template = Map.take(original, Responder.State.Record.__schema__(:fields) -- [:sequence])

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

    Repo.insert_all(Responder.State.Record, newer)
    assert {:ok, detail} = Projection.episode(claim.episode.key)
    refute Enum.any?(detail.trace.steps, &(&1.id == "record-#{original.id}"))
    assert [finding] = Projection.findings(%{}).items
    assert finding.what == "An older useful conclusion"
    assert finding.path == "/episodes/" <> URI.encode_www_form(claim.episode.key)
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
               "responder"
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
