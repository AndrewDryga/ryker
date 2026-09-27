defmodule Ryker.ControlPlane.CandidateResponseProjectionTest do
  use Ryker.DataCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Ryker.ControlPlane.{EpisodePage, ModelRequests, Projection, RequestPage}
  alias Ryker.Work.{CandidateResponse, Custody, Submission, Turn}

  @fixture "test/ryker/work/fixtures/airflow_candidate_responses.json"

  test "the timeline and inspector pair every check with its exact recorded response" do
    {episode, turn, bodies} = recorded_turn!(3)
    {:ok, view} = ModelRequests.project(episode.key, %{})
    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})
    {:ok, snapshot} = Projection.episode(episode.key)

    inspector = render_inspector(view)

    timeline_html =
      render_component(&EpisodePage.render/1,
        snapshot: snapshot,
        timeline: timeline,
        requests: nil,
        params: %{}
      )

    for html <- [inspector, timeline_html] do
      document = LazyHTML.from_document(html)
      assert Enum.count(LazyHTML.query(document, ".candidate-response")) == 3
      assert Enum.empty?(LazyHTML.query(document, ".candidate-response[open]"))

      for body <- Enum.uniq(bodies) do
        message = Jason.decode!(body)["message"]
        assert LazyHTML.text(document) =~ message
      end

      ids = LazyHTML.query(document, "[id]") |> LazyHTML.attribute("id")
      assert ids == Enum.uniq(ids)
    end

    refute inspector =~ "artifact-candidate"
    refute timeline_html =~ "Raw model response"
    assert inspector =~ "selected-#{turn.id}-response-1-body"
    assert timeline_html =~ "turn-#{turn.id}-response-1-body"
    assert Repo.get!(Turn, turn.id).candidate == List.last(bodies)
  end

  test "an older response link selects its own bounded check page without borrowing the latest body" do
    {episode, turn, _bodies} = recorded_turn!(12)
    {:ok, stable} = ModelRequests.project(episode.key, %{})
    assert validation(stable).response_page.page == 1
    assert Map.keys(validation(stable).responses) |> Enum.sort() == Enum.to_list(1..10)

    {:ok, latest} = ModelRequests.project(episode.key, %{"responses_page" => "2"})
    latest_checks = validation(latest)
    assert latest_checks.response_page.page == 2
    assert Map.keys(latest_checks.responses) |> Enum.sort() == [11, 12]

    href = latest_checks.response_links["turn-#{turn.id}-validation-1"].href
    uri = URI.parse(href)
    params = URI.decode_query(uri.query)
    assert params["responses_page"] == "1"
    assert params["attempt"] == turn.id
    assert uri.path == "/timeline/#{URI.encode_www_form(episode.key)}"
    assert uri.fragment == "turn-#{turn.id}-response-1-body"

    {:ok, older} = ModelRequests.timeline(episode.key, params)
    {:ok, snapshot} = Projection.episode(episode.key)

    html =
      render_component(&EpisodePage.render/1,
        snapshot: snapshot,
        timeline: older,
        params: params
      )

    assert html =~ uri.fragment

    assert html
           |> LazyHTML.from_document()
           |> LazyHTML.query(".candidate-response")
           |> LazyHTML.attribute("id") ==
             Enum.map(1..10, &"turn-#{turn.id}-response-#{&1}")

    {other, _turn, _bodies} = recorded_turn!(1)
    assert :not_found == ModelRequests.project(other.key, params)
  end

  test "timeline response bodies and omitted-body links share one full-width evidence row" do
    # Real phone screenshots squeezed the reason to a few characters per line
    # because response controls occupied the event grid's right-hand column.
    {episode, _turn, _bodies} = recorded_turn!(12)
    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})
    {:ok, snapshot} = Projection.episode(episode.key)

    document =
      render_component(&EpisodePage.render/1,
        snapshot: snapshot,
        timeline: timeline,
        requests: nil,
        params: %{}
      )
      |> LazyHTML.from_document()

    evidence = LazyHTML.query(document, ".case-event-content > .candidate-evidence")
    assert Enum.count(evidence) == 12
    assert Enum.count(LazyHTML.query(evidence, ".candidate-response")) == 10

    assert evidence
           |> LazyHTML.query("p > a")
           |> Enum.count(&(LazyHTML.text(&1) =~ "Inspect response for attempt")) == 2
  end

  test "one bulk response query serves the bounded timeline and never loads a different episode" do
    {episode, turn, _bodies} = recorded_turn!(12)
    another_turn = copy_turn!(turn)
    {_other, other_turn, _} = recorded_turn!(1)
    handler = "candidate-query:#{Ecto.UUID.generate()}"

    :ok =
      :telemetry.attach(handler, [:ryker, :repo, :query], &__MODULE__.record_query/4, self())

    try do
      assert {:ok, timeline} = ModelRequests.timeline(episode.key, %{})
      assert_receive {:response_query, query, 10}
      refute_receive {:response_query, _, _}, 0
      assert query =~ "candidate_attempt"

      response_turns =
        for request <- timeline.items,
            section <- request.sections,
            {id, _response} <- section[:response_links] || %{},
            do: id

      assert length(response_turns) == 24
      assert Enum.all?(response_turns, &String.contains?(&1, [turn.id, another_turn.id]))
      refute Enum.any?(response_turns, &String.contains?(&1, other_turn.id))

      response_links =
        for request <- timeline.items,
            section <- request.sections,
            {_id, response} <- section[:response_links] || %{},
            do: response

      assert Enum.count(response_links, &(&1.artifact && &1.artifact.state == :retained)) == 10
      omitted = Enum.filter(response_links, &is_nil(&1.artifact))
      assert length(omitted) == 14
      assert Enum.all?(omitted, &String.contains?(&1.href, "responses_page="))
    after
      :telemetry.detach(handler)
    end
  end

  test "a new eleventh attempt leaves the inspector on its existing first page" do
    {episode, turn, _bodies} = recorded_turn!(10)
    {:ok, before} = ModelRequests.project(episode.key, %{})

    before_ids =
      render_inspector(before)
      |> LazyHTML.from_document()
      |> LazyHTML.query(".candidate-response")
      |> LazyHTML.attribute("id")

    response = hd(fixture_responses())
    last = List.last(turn.validation_history)

    next = %{
      last
      | "candidate_attempt" => 11,
        "candidate_sha256" => response["sha256"],
        "response_bytes" => response["bytes"]
    }

    Repo.insert!(%CandidateResponse{
      turn_id: turn.id,
      candidate_attempt: 11,
      body: response["body"],
      sha256: response["sha256"],
      byte_size: response["bytes"],
      recorded_at: DateTime.utc_now()
    })

    turn
    |> Ecto.Changeset.change(
      validation_history: turn.validation_history ++ [next],
      candidate: response["body"],
      candidate_sha256: response["sha256"],
      candidate_attempt: 11
    )
    |> Repo.update!()

    {:ok, after_update} = ModelRequests.project(episode.key, %{})

    after_ids =
      render_inspector(after_update)
      |> LazyHTML.from_document()
      |> LazyHTML.query(".candidate-response")
      |> LazyHTML.attribute("id")

    assert validation(after_update).response_page.page == 1
    assert after_ids == before_ids
    assert render_inspector(after_update) =~ "Later attempts"
  end

  test "the owner expiry marker hides bodies even before an old response row is pruned" do
    {episode, turn, _bodies} = recorded_turn!(3)
    turn |> Ecto.Changeset.change(operational_pruned_at: DateTime.utc_now()) |> Repo.update!()
    {:ok, view} = ModelRequests.project(episode.key, %{})
    html = render_inspector(view)
    assert html =~ "This artifact has expired"
    refute html =~ "Verification is scheduled"
    refute html =~ "Verification remains inconclusive"
    refute html =~ "candidate-response"
  end

  test "a historical latest response links to its actual retained body without inventing an archive" do
    {episode, turn, _bodies} = recorded_turn!(2)
    # Historical custody has the latest exact body but no per-attempt archive.
    Repo.delete_all(from(r in CandidateResponse, where: r.turn_id == ^turn.id))
    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})
    {:ok, snapshot} = Projection.episode(episode.key)

    html =
      render_component(&EpisodePage.render/1,
        snapshot: snapshot,
        timeline: timeline,
        requests: nil,
        params: %{}
      )

    document = LazyHTML.from_document(html)
    first = LazyHTML.query(document, "#event-turn-#{turn.id}-validation-1")
    latest = LazyHTML.query(document, "#event-turn-#{turn.id}-validation-2")

    assert LazyHTML.text(first) =~ "Response body not retained"
    refute LazyHTML.text(latest) =~ "Response body not retained"
    [href] = LazyHTML.query(latest, "p a") |> LazyHTML.attribute("href")
    uri = URI.parse(href)
    params = URI.decode_query(uri.query)
    assert params["section"] == "candidate"
    assert uri.fragment == "turn-#{turn.id}-response-2-body"
    {:ok, selected} = ModelRequests.timeline(episode.key, params)

    selected_html =
      render_component(&EpisodePage.render/1,
        snapshot: snapshot,
        timeline: selected,
        params: params
      )

    assert selected_html =~ uri.fragment
    assert Repo.aggregate(CandidateResponse, :count) == 0
  end

  test "a mismatched archived identity cannot hide the retained latest response" do
    {episode, turn, _bodies} = recorded_turn!(2)

    turn
    |> Ecto.Changeset.change(candidate_sha256: String.duplicate("d", 64))
    |> Repo.update!()

    {:ok, view} = ModelRequests.project(episode.key, %{})
    # The display's candidate digest is calculated from actual bytes, not the
    # damaged execution cursor metadata; it still matches the exact check.
    assert RequestPage.latest_archived_response(view.selected.sections)

    Repo.get_by!(CandidateResponse, turn_id: turn.id, candidate_attempt: 2)
    |> Ecto.Changeset.change(
      body: hd(fixture_responses())["body"],
      sha256: hd(fixture_responses())["sha256"],
      byte_size: hd(fixture_responses())["bytes"]
    )
    |> Repo.update!()

    {:ok, mismatched} = ModelRequests.project(episode.key, %{})
    assert RequestPage.latest_archived_response(mismatched.selected.sections) == nil
    assert render_inspector(mismatched) =~ "artifact-candidate"
  end

  # Andrew, 2026-09-27, of a card that read "Request title Hello": "what is
  # this? updating title of episode? maybe say that? ... or do not show it if
  # title stayed the same." Every answer carries a title, so every answer's
  # card showed one, the same one each time.
  test "only the answer that changed the request's title says so" do
    {episode, first, _bodies} = recorded_turn!(1)
    kept = copy_turn!(first)
    renamed = copy_turn!(kept)
    started = DateTime.utc_now()
    named = "Checkout restarts after the 08:00 deploy"

    first = accept!(first, titled(named), DateTime.add(started, 1))
    kept = accept!(kept, titled(named), DateTime.add(started, 2))

    renamed =
      accept!(
        renamed,
        titled("Checkout 502s traced to the readiness probe"),
        DateTime.add(started, 3)
      )

    document = timeline_document(episode)

    assert title_update(document, first) == "Title updated to: #{named}"
    assert title_update(document, kept) == nil

    assert title_update(document, renamed) ==
             "Title updated to: Checkout 502s traced to the readiness probe"

    refute LazyHTML.text(document) =~ "Request title"
  end

  # Where an answer changed the title is read from the answers themselves,
  # and an accepted answer saved before answers were checked as JSON is not
  # one; it must not take the page down with it.
  test "an accepted answer that is not JSON changes no title and leaves the timeline readable" do
    {episode, turn, _bodies} = recorded_turn!(1)
    accept!(turn, "not-json", DateTime.utc_now())

    document = timeline_document(episode)

    assert title_update(document, turn) == nil
    assert document |> LazyHTML.query("#request-#{turn.id}-result") |> Enum.count() == 1
  end

  # The checks line of a call that needed corrections leads to each answer
  # Ryker sent back; the link has to land on that answer's card.
  test "a corrected call's checks line leads to the card of the answer sent back" do
    {episode, turn, [rejected_body, accepted_body]} = recorded_turn!(2)
    [rejected, accepted] = turn.validation_history

    turn
    |> Ecto.Changeset.change(
      [validation_history: [rejected, %{accepted | "verdict" => "accept", "violations" => []}]] ++
        acceptance(turn, DateTime.utc_now())
    )
    |> Repo.update!()

    assert rejected_body != accepted_body
    document = timeline_document(episode)
    model_call = LazyHTML.query(document, "#request-#{turn.id}-result")

    assert model_call |> LazyHTML.query(".call-run dd") |> LazyHTML.text() =~
             "Passed on attempt 2 · 1 correction"

    [href] = model_call |> LazyHTML.query(".call-run-corrections a") |> LazyHTML.attribute("href")
    assert href == "#event-turn-#{turn.id}-validation-1"

    target = LazyHTML.query_by_id(document, String.trim_leading(href, "#"))

    assert target |> LazyHTML.query(".case-card-heading h3") |> LazyHTML.text() ==
             "Answer rejected"
  end

  def record_query(_event, _measurements, %{query: query, result: {:ok, result}}, owner) do
    if self() == owner && String.contains?(query, "work_candidate_responses"),
      do: send(owner, {:response_query, query, result.num_rows})
  end

  # Rejected writes in the surrounding constraint tests are expected. They
  # must not detach this telemetry handler before the read it measures.
  def record_query(_event, _measurements, %{result: {:error, _reason}}, _owner), do: :ok

  defp copy_turn!(turn) do
    fields =
      turn
      |> Map.from_struct()
      |> Map.take(Turn.__schema__(:fields))
      |> Map.merge(%{
        id: Ecto.UUID.generate(),
        turn_ref: turn.turn_ref <> ":later",
        lease_ref: nil,
        lease_owner: nil,
        lease_expires_at: nil
      })

    copy = Repo.insert!(struct(Turn, fields))

    for response <- Repo.all(from(r in CandidateResponse, where: r.turn_id == ^turn.id)) do
      fields = response |> Map.from_struct() |> Map.take(CandidateResponse.__schema__(:fields))
      Repo.insert!(struct(CandidateResponse, Map.put(fields, :turn_id, copy.id)))
    end

    copy
  end

  # The harvested answer with the title field Work answers carry now; the
  # rest of the answer is exactly as it was recorded.
  defp titled(title) do
    fixture_responses()
    |> hd()
    |> Map.fetch!("body")
    |> Jason.decode!()
    |> Map.put("title", title)
    |> Jason.encode!()
  end

  # A turn whose only answer was accepted first time, with that answer's
  # retained response.
  defp accept!(turn, body, accepted_at) do
    sha256 = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    Repo.delete_all(from(r in CandidateResponse, where: r.turn_id == ^turn.id))

    Repo.insert!(%CandidateResponse{
      turn_id: turn.id,
      candidate_attempt: 1,
      body: body,
      sha256: sha256,
      byte_size: byte_size(body),
      recorded_at: accepted_at
    })

    turn
    |> Ecto.Changeset.change(
      [
        candidate: body,
        candidate_attempt: 1,
        candidate_sha256: sha256,
        validation_history: [
          %{
            "candidate_attempt" => 1,
            "candidate_sha256" => sha256,
            "recorded_at" => DateTime.to_iso8601(accepted_at),
            "response_bytes" => byte_size(body),
            "verdict" => "accept",
            "violations" => []
          }
        ]
      ] ++ acceptance(turn, accepted_at)
    )
    |> Repo.update!()
  end

  # What Ryker saves with an answer it accepts, as an accepted turn must
  # carry it.
  defp acceptance(turn, accepted_at) do
    [
      accepted_at: accepted_at,
      continuation: %{},
      result_ref: "result:#{turn.id}",
      validation_intent: %{},
      validation_intent_fingerprint: String.duplicate("e", 64),
      validation_receipt: "receipt:#{turn.id}"
    ]
  end

  defp timeline_document(episode) do
    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})
    {:ok, snapshot} = Projection.episode(episode.key)

    render_component(&EpisodePage.render/1,
      snapshot: snapshot,
      timeline: timeline,
      requests: nil,
      params: %{}
    )
    |> LazyHTML.from_document()
  end

  defp title_update(document, turn) do
    case document
         |> LazyHTML.query_by_id("event-turn-#{turn.id}-validation-1")
         |> LazyHTML.query(".title-update")
         |> Enum.to_list() do
      [] -> nil
      [line] -> line |> LazyHTML.text() |> String.split() |> Enum.join(" ")
    end
  end

  defp validation(view), do: Enum.find(view.selected.sections, &(&1.id == "validation"))

  defp render_inspector(view, params \\ %{}) do
    render_component(&RequestPage.render/1,
      view: view,
      params: params,
      path: "/timeline/#{URI.encode_www_form(view.episode_ref)}"
    )
  end

  defp fixture_responses do
    @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("responses")
  end

  defp recorded_turn!(count) do
    id = Ecto.UUID.generate()

    {:ok, %{episode: episode}} =
      Ryker.Episodes.apply(
        Ryker.Fixtures.Episodes.admit_input(%{
          episode_id: id,
          episode_key: "candidate-inspection:#{id}",
          native_input_id: "input:#{id}",
          turn_ref: "turn:#{id}"
        })
      )

    {:ok, _session} = Custody.pin_episode(id, "policy:inspection", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("inspection:#{id}", 60, :work)
    assert claim.episode.id == id
    {:ok, submission} = Submission.new(%{}, "Retained host test prompt.", %{}, "inspection-test")
    {:ok, turn} = Custody.freeze_submission(id, claim.turn.turn_ref, claim.lease_ref, submission)
    responses = fixture_responses()
    now = DateTime.utc_now()

    # Repetition and timestamps are deterministic host setup, not additional
    # model judgments or a reconstruction of the lost first trial candidate.
    receipts =
      for attempt <- 1..count do
        response = Enum.at(responses, rem(attempt - 1, 2))
        at = DateTime.add(now, attempt, :microsecond)

        Repo.insert!(%CandidateResponse{
          turn_id: turn.id,
          candidate_attempt: attempt,
          body: response["body"],
          sha256: response["sha256"],
          byte_size: response["bytes"],
          recorded_at: at
        })

        %{
          "candidate_attempt" => attempt,
          "candidate_sha256" => response["sha256"],
          "recorded_at" => DateTime.to_iso8601(at),
          "response_bytes" => response["bytes"],
          "verdict" => "reject",
          "violations" => [
            "Call validate_final with this exact candidate after completing all state-tool writes, then return the accepted candidate unchanged."
          ]
        }
      end

    bodies = for attempt <- 1..count, do: Enum.at(responses, rem(attempt - 1, 2))["body"]
    latest = List.last(receipts)

    turn =
      turn
      |> Ecto.Changeset.change(
        candidate: List.last(bodies),
        candidate_attempt: count,
        candidate_sha256: latest["candidate_sha256"],
        validation_history: receipts
      )
      |> Repo.update!()

    {episode, turn, bodies}
  end
end
