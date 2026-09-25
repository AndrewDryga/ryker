defmodule Ryker.Work.CandidateResponseTest do
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Retention.Data

  alias Ryker.Work.{
    CandidateResponse,
    Custody,
    Result,
    Session,
    Submission,
    Turn,
    TurnChangeset
  }

  @old ~U[2020-01-01 00:00:00.000000Z]
  @fixture __DIR__ <> "/fixtures/airflow_candidate_responses.json"
  @external_resource @fixture
  @responses @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("responses")

  test "replacing the candidate keeps every exact response available for inspection" do
    # The real Airflow repair overwrote attempt 1: validation kept its hash but
    # inspection could not recover its body. These are two independently retained
    # real responses, not a reconstruction of that missing historical attempt.
    work = bound_turn!()
    [first, second] = @responses
    assert {:ok, staged} = stage(work, nil, first, 1)
    assert {:ok, replaced} = stage(work, staged, second, 2)

    assert Enum.map(responses(work), & &1.body) == [first["body"], second["body"]]
    assert replaced.candidate == second["body"]
    assert replaced.candidate_attempt == 2

    assert Enum.map(responses(work), &{&1.sha256, &1.byte_size}) ==
             Enum.map(@responses, &{&1["sha256"], &1["bytes"]})
  end

  test "replacing a pre-upgrade cursor does not invent an older response receipt" do
    work = bound_turn!()
    [first, second] = @responses

    # Structural pre-upgrade setup: the old writer stored only the execution
    # cursor. The body is a retained fixture, not the lost Airflow attempt.
    previous =
      work.turn
      |> TurnChangeset.stage_candidate(first["body"], first["sha256"], 1)
      |> Repo.update!()

    assert responses(work) == []
    assert {:ok, replaced} = stage(work, previous, second, 2)

    assert Enum.map(responses(work), &{&1.candidate_attempt, &1.body}) == [{2, second["body"]}]
    assert replaced.candidate_attempt == 2
    assert replaced.candidate == second["body"]
  end

  test "exact retries preserve the first receipt and repeated bytes in another attempt stay distinct" do
    work = bound_turn!()
    first = hd(@responses)
    assert {:ok, staged} = stage(work, nil, first, 1)
    [original] = responses(work)

    assert {:ok, _retry} = stage(work, nil, first, 1)
    assert responses(work) == [original]
    assert {:ok, _replaced} = stage(work, staged, first, 2)
    assert [^original, next] = responses(work)
    assert next.candidate_attempt == 2
    assert next.body == original.body
    assert next.sha256 == original.sha256
  end

  test "a stale lease cannot create an attempt or replace its execution cursor" do
    work = bound_turn!()
    [first, second] = @responses
    assert {:ok, staged} = stage(work, nil, first, 1)
    original = responses(work)

    assert {:error, :work_lease_lost} =
             stage(%{work | lease_ref: "stale-lease"}, staged, second, 2)

    assert responses(work) == original
    assert Repo.get!(Turn, work.turn.id).candidate == first["body"]
  end

  test "a conflicting attempt identity rolls back both the receipt and cursor" do
    work = bound_turn!()
    [first, second] = @responses
    assert {:ok, staged} = stage(work, nil, first, 1)

    # Host-state fault injection: an existing immutable slot must never be
    # overwritten even if the caller holds the current turn lease and CAS.
    conflict =
      Repo.insert!(%CandidateResponse{
        turn_id: work.turn.id,
        candidate_attempt: 2,
        body: first["body"],
        sha256: first["sha256"],
        byte_size: first["bytes"],
        recorded_at: @old
      })

    assert {:error, {:work_candidate_response_conflict, 2}} = stage(work, staged, second, 2)
    assert Repo.get!(Turn, work.turn.id).candidate == first["body"]
    assert List.last(responses(work)) == conflict
  end

  test "an obsolete cursor cannot add a newer candidate response" do
    work = bound_turn!()
    [first, second] = @responses
    assert {:ok, staged} = stage(work, nil, first, 1)
    assert {:ok, replaced} = stage(work, staged, second, 2)
    original = responses(work)

    assert {:error, {:work_candidate_conflict, hash}} = stage(work, staged, first, 3)
    assert hash == replaced.candidate_sha256
    assert responses(work) == original
  end

  test "full size candidates do not share a cumulative validation history body limit" do
    work = bound_turn!()

    # Whitespace padding is deterministic host boundary setup; the retained
    # model JSON remains unchanged and valid. Three receipts exceed 256 KiB.
    full = Enum.map(@responses, &padded/1)
    [first, second] = full
    assert {:ok, staged} = stage(work, nil, first, 1)
    assert {:ok, replaced} = stage(work, staged, second, 2)
    assert {:ok, latest} = stage(work, replaced, first, 3)
    assert Enum.map(responses(work), & &1.byte_size) == List.duplicate(262_144, 3)
    assert Enum.map(responses(work), & &1.body) == [first["body"], second["body"], first["body"]]

    too_large = response(first["body"] <> " ")
    assert {:error, {:invalid_work_custody, :candidate}} = stage(work, latest, too_large, 4)
    assert length(responses(work)) == 3
  end

  test "candidate bodies expire with their discarded owner while immutable identities remain" do
    discarded = settled_turn!() |> discard_session!()
    active = settled_turn!()
    old = responses(discarded)
    kept = responses(active)

    assert {:ok, %{operational_turns: 1}} = Data.prune(retention_settings())
    marker = Repo.get!(Turn, discarded.turn.id).operational_pruned_at
    assert %DateTime{} = marker

    assert responses(discarded) ==
             Enum.map(old, &%{&1 | body: nil, operational_pruned_at: marker})

    assert responses(active) == kept
    assert Repo.get!(Turn, active.turn.id).operational_pruned_at == nil
    assert {:ok, _} = Data.prune(retention_settings())
    assert Enum.all?(responses(discarded), &is_nil(&1.body))
  end

  test "an expired receipt cannot be repopulated by an exact candidate retry" do
    work = bound_turn!()
    first = hd(@responses)
    assert {:ok, staged} = stage(work, nil, first, 1)

    # Delayed replay may still carry exact bytes after operational custody has
    # withdrawn them. Fault-inject markers to exercise the writer's own fence.
    Repo.update_all(from(t in Turn, where: t.id == ^work.turn.id),
      set: [operational_pruned_at: @old]
    )

    Repo.update_all(from(r in CandidateResponse, where: r.turn_id == ^work.turn.id),
      set: [body: nil, operational_pruned_at: @old]
    )

    original = responses(work)
    assert {:error, :work_candidate_response_pruned} = stage(work, staged, first, 1)
    assert responses(work) == original
  end

  test "normal owning turn deletion removes only its candidate response history" do
    removed = settled_turn!() |> discard_session!()
    kept = settled_turn!() |> discard_session!()
    remaining = responses(kept)

    # Simulate the existing history-pruning owner's exact turn deletion, not
    # a separate candidate cleanup path with an independent lifetime.
    assert {1, _} = Repo.delete_all(from(t in Turn, where: t.id == ^removed.turn.id))
    assert responses(removed) == []
    assert responses(kept) == remaining
  end

  defp responses(work) do
    Repo.all(
      from(r in CandidateResponse,
        where: r.turn_id == ^work.turn.id,
        order_by: r.candidate_attempt
      )
    )
  end

  defp stage(work, previous, response, attempt) do
    Custody.stage_candidate(
      work.episode.id,
      work.turn.turn_ref,
      work.lease_ref,
      if(previous, do: previous.candidate_sha256),
      if(previous, do: previous.candidate_attempt),
      response["body"],
      response["sha256"],
      attempt
    )
  end

  defp padded(response) do
    response(response["body"] <> String.duplicate(" ", 262_144 - response["bytes"]))
  end

  defp response(body) do
    %{"body" => body, "sha256" => digest(body), "bytes" => byte_size(body)}
  end

  defp bound_turn! do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: id,
        episode_key: "candidate-response:#{id}",
        native_input_id: "candidate-source:#{id}",
        turn_ref: "candidate-turn:#{id}"
      })

    assert {:ok, _} = Episodes.apply(command)
    assert {:ok, _} = Custody.pin_episode(id, "work-read-only", String.duplicate("a", 64))
    assert {:ok, claim} = Custody.claim_next("candidate-worker:#{id}", 120)
    assert claim.episode.id == id

    assert {:ok, submission} =
             Submission.new(%{}, "Handle the retained input.", %{}, "work-final-live-v3")

    assert {:ok, _} =
             Custody.freeze_submission(id, claim.turn.turn_ref, claim.lease_ref, submission)

    assert {:ok, session} =
             Custody.bind_session(
               id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "candidate-session:#{id}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "candidate-coop-turn:#{id}"
             )

    %{episode: claim.episode, session: session, turn: turn, lease_ref: claim.lease_ref}
  end

  defp settled_turn! do
    work = bound_turn!()
    [first, second] = @responses
    assert {:ok, staged} = stage(work, nil, first, 1)
    assert {:ok, latest} = stage(work, staged, second, 2)
    assert {:ok, result} = Result.new(:none, nil, "Completed.", %{"kind" => "complete"})

    assert {:ok, _} =
             Custody.prepare_validation(
               work.episode.id,
               work.turn.turn_ref,
               work.lease_ref,
               latest.candidate_sha256,
               latest.candidate_attempt,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               work.lease_ref,
               latest.candidate_sha256,
               latest.candidate_attempt,
               "validation:#{work.turn.id}"
             )

    Repo.update_all(from(t in Turn, where: t.id == ^work.turn.id), set: [updated_at: @old])
    %{work | episode: accepted.episode, turn: accepted.turn}
  end

  defp discard_session!(work) do
    receipt = %{"kind" => "discarded", "remote_session_id" => work.session.coop_session_id}

    Repo.update_all(from(s in Session, where: s.id == ^work.session.id),
      set: [
        cleanup_status: :discarded,
        cleanup_receipt: receipt,
        cleanup_receipt_fingerprint: CanonicalJSON.digest(receipt),
        discarded_at: @old
      ]
    )

    work
  end

  defp retention_settings do
    %{
      audit_data_seconds: 60,
      closed_work_seconds: 60,
      conversation_memory_seconds: 60,
      episode_history_seconds: 60,
      operational_data_seconds: 60
    }
  end

  defp digest(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end
