defmodule Responder.ControlPlane.CandidateResponseHTTPTest do
  use Responder.DataCase, async: false

  import Phoenix.ConnTest

  alias Responder.ControlPlane.{Endpoint, Projection}
  alias Responder.Work.{CandidateResponse, Custody, Submission}

  @endpoint Endpoint
  @fixture "test/responder/work/fixtures/airflow_candidate_responses.json"

  setup do
    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Responder.ControlPlane.PubSub,
       live_view: [signing_salt: "candidate-response-http-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: %{},
         csrf_secret: String.duplicate("s", 32),
         observability: %{},
         projection: Projection.callbacks()
       }}
    )

    :ok
  end

  test "the initial HTTP response rejects a foreign turn without sending any candidate bytes" do
    # Real Chromium received ten default-turn responses in the raw HTML for a
    # foreign selector; only the connected LiveView subsequently denied it.
    {episode, _turn} = recorded_turn!(2)
    {_foreign_episode, foreign_turn} = recorded_turn!(1)
    html = raw_get(request_path(episode) <> "?attempt=#{foreign_turn.id}")

    assert html =~ "This record is unavailable"

    assert html
           |> LazyHTML.from_document()
           |> LazyHTML.query(".candidate-response")
           |> Enum.empty?()

    for response <- fixture_responses() do
      refute LazyHTML.text(LazyHTML.from_document(html)) =~
               Jason.decode!(response["body"])["message"]
    end
  end

  test "the initial HTTP response selects only the exact requested response page" do
    # Page two originally rendered page one until the WebSocket connected.
    {episode, turn} = recorded_turn!(11)

    html =
      raw_get(
        request_path(episode) <>
          "?attempt=#{turn.id}&responses_page=2&section=validation"
      )

    document = LazyHTML.from_document(html)

    assert LazyHTML.query(document, ".candidate-response") |> LazyHTML.attribute("id") ==
             ["selected-#{turn.id}-response-11"]

    assert html =~ "Checks 11–11 of 11"
    refute html =~ "response-1-body"

    assert document
           |> LazyHTML.query(".inspector-document")
           |> LazyHTML.attribute("id")
           |> hd() == "selected-#{turn.id}-validation"
  end

  test "the initial HTTP response honors activity query filters before connecting" do
    html = raw_get("/episodes?q=retained&usage_profile=emisar&mode=all")
    document = LazyHTML.from_document(html)

    assert Enum.count(LazyHTML.query(document, "#activity-filters input[name=q][value=retained]")) ==
             1

    assert Enum.count(LazyHTML.query(document, "#criterion-usage_profile[value=emisar]")) == 1
  end

  defp raw_get(path) do
    # Pass the URL, not a pre-decoded params map: the latter hides a missing
    # fetch_query_params plug in the real HTTP pipeline.
    conn = build_conn() |> Map.put(:host, "localhost") |> get(path)
    assert conn.status == 200
    assert conn.resp_body =~ "data-connection-state=\"connecting\""
    conn.resp_body
  end

  defp request_path(episode),
    do: "/episodes/#{URI.encode_www_form(episode.key)}/requests"

  defp fixture_responses,
    do: @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("responses")

  defp recorded_turn!(count) do
    id = Ecto.UUID.generate()

    {:ok, %{episode: episode}} =
      Responder.Episodes.apply(
        Responder.Fixtures.Episodes.admit_input(%{
          episode_id: id,
          episode_key: "candidate-http:#{id}",
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

    # Exact harvested bodies; repetition and timestamps are declared host-test
    # setup, not a reconstructed historical repair sequence or model judgments.
    history =
      for attempt <- 1..count do
        response = Enum.at(responses, rem(attempt - 1, length(responses)))
        at = DateTime.add(turn.inserted_at, attempt, :microsecond)

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

    latest = Enum.at(responses, rem(count - 1, length(responses)))

    turn =
      turn
      |> Ecto.Changeset.change(
        candidate: latest["body"],
        candidate_attempt: count,
        candidate_sha256: latest["sha256"],
        validation_history: history
      )
      |> Repo.update!()

    {episode, turn}
  end
end
