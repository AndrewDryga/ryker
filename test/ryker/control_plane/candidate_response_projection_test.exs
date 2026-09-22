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
