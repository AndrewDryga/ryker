defmodule Responder.Work.SubmissionBuilderTest do
  use Responder.DataCase, async: true

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Work.{Custody, DeliveryReceipt, Final, Result, Submission, SubmissionBuilder}

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "the first turn is a self-contained universal briefing with one attached final schema" do
    initial = String.duplicate("a", 1_500) <> " ORIGINAL_REQUEST_MARKER"
    claim = claim_episode!("full-briefing", initial)

    assert {:ok, submission} = SubmissionBuilder.build(claim)
    assert submission["context"]["mode"] == "full"
    assert submission["context"]["inputs"]["omitted_count"] == 0
    assert [current] = submission["context"]["inputs"]["items"]
    assert current["content"] == %{"text" => initial}
    assert submission["output_schema"] == Final.json_schema()
    assert submission["contract_version"] == "work-final-v1"
    assert submission["prompt"] =~ "ORIGINAL_REQUEST_MARKER"
    refute submission["prompt"] =~ ~s("response_schema")
    refute submission["prompt"] =~ ~s("$schema")
  end

  test "a continuation in the same Coop session sends a delta instead of the briefing again" do
    initial = String.duplicate("a", 1_500) <> " ORIGINAL_REQUEST_MARKER"
    first = claim_episode!("delta-continuation", initial)
    assert {:ok, first_submission} = SubmissionBuilder.build(first)
    bind_remote_turn!(first, first_submission)

    assert {:ok, _queued} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: destination(first),
                 episode_id: first.episode.id,
                 episode_key: first.episode.key,
                 native_input_id: "source:delta-answer",
                 occurred_at: DateTime.add(@now, 1, :second),
                 payload: %{"text" => "NEW_INPUT_MARKER: continue with the safer option"},
                 turn_ref: "unused:queued"
               })
             )

    candidate = ~s({"delivery":"none","message":null})
    candidate_sha256 = digest(candidate)

    assert {:ok, _staged} =
             Custody.stage_candidate(
               first.episode.id,
               first.turn.turn_ref,
               first.lease_ref,
               nil,
               nil,
               candidate,
               candidate_sha256,
               1
             )

    assert {:ok, result} =
             Result.new(:none, nil, "The first turn is superseded by queued feedback.")

    assert {:ok, _intent} =
             Custody.prepare_validation(
               first.episode.id,
               first.turn.turn_ref,
               first.lease_ref,
               candidate_sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               first.episode.id,
               first.episode.key,
               first.turn.turn_ref,
               first.lease_ref,
               candidate_sha256,
               1,
               "validation:delta-first"
             )

    assert accepted.episode.owner_kind == :turn
    assert {:ok, second} = Custody.claim_next("worker:delta-second", 60)
    assert second.session.id == first.session.id

    assert {:ok, delta} = SubmissionBuilder.build(second)
    assert delta["context"]["mode"] == "continuation"
    assert delta["context"]["parent_submission_ref"] == Submission.fingerprint(first_submission)
    assert delta["prompt"] =~ "NEW_INPUT_MARKER"
    refute delta["prompt"] =~ String.duplicate("a", 500)
    assert delta["context"]["continuity"]["first_input"]["content"]["truncated"]
    assert byte_size(delta["prompt"]) < byte_size(first_submission["prompt"])

    assert {:ok, rotated} =
             Custody.rotate_session(
               second.episode.id,
               second.turn.turn_ref,
               second.lease_ref,
               second.session.generation
             )

    replacement = %{second | session: rotated.session, turn: rotated.turn}
    assert {:ok, replacement_submission} = SubmissionBuilder.build(replacement)
    assert replacement_submission["context"]["mode"] == "full"
    assert replacement_submission["prompt"] =~ "ORIGINAL_REQUEST_MARKER"
    assert replacement_submission["prompt"] =~ "NEW_INPUT_MARKER"

    assert replacement_submission["context"]["prior_outcome"]["submission_ref"] ==
             Submission.fingerprint(first_submission)
  end

  test "the builder rejects a value that is not a complete leased claim" do
    assert SubmissionBuilder.build(%{}) ==
             {:error, {:invalid_work_submission_builder, :claim}}
  end

  test "a frozen claim cannot see input admitted for the following logical turn" do
    claim = claim_episode!("claim-snapshot", "FIRST_TURN_ONLY")

    assert {:ok, _queued} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: destination(claim),
                 episode_id: claim.episode.id,
                 episode_key: claim.episode.key,
                 native_input_id: "source:claim-snapshot:later",
                 occurred_at: DateTime.add(@now, 1, :second),
                 payload: %{"text" => "NEXT_TURN_ONLY"},
                 turn_ref: "unused:claim-snapshot"
               })
             )

    assert {:ok, submission} = SubmissionBuilder.build(claim)
    assert submission["prompt"] =~ "FIRST_TURN_ONLY"
    refute submission["prompt"] =~ "NEXT_TURN_ONLY"
  end

  test "queued future inputs never appear as truncated history in the current turn" do
    active_text = String.duplicate("CURRENT_REQUEST_MUST_REMAIN_EXACT ", 1_300)
    first = claim_episode!("bounded-history", active_text)

    Enum.each(1..45, fn index ->
      assert {:ok, _queued} =
               Episodes.apply(
                 EpisodeFixtures.admit_input(%{
                   destination: destination(first),
                   episode_id: first.episode.id,
                   episode_key: first.episode.key,
                   native_input_id: "source:history:#{index}",
                   occurred_at: DateTime.add(@now, index, :second),
                   payload: %{
                     "text" => "FUTURE_INPUT_#{index}:" <> String.duplicate("x", 5_000)
                   },
                   turn_ref: "unused:#{index}"
                 })
               )
    end)

    reloaded = Responder.Repo.get!(Responder.Episodes.Episode, first.episode.id)
    assert {:ok, submission} = SubmissionBuilder.build(%{first | episode: reloaded})

    items = submission["context"]["inputs"]["items"]
    assert [current] = items
    assert current["content"] == %{"text" => active_text}
    assert current["current"]
    assert current["occurred_at"] == DateTime.to_iso8601(@now)
    assert current["revision"] == 1
    assert submission["context"]["inputs"]["omitted_count"] == 0
    Enum.each(1..45, &refute(submission["prompt"] =~ "FUTURE_INPUT_#{&1}:"))
  end

  test "a continuation advances a large exact pair without losing the remainder" do
    first = claim_episode!("active-input-overflow", "initial")
    assert {:ok, first_submission} = SubmissionBuilder.build(first)
    bind_remote_turn!(first, first_submission)

    Enum.each(1..41, fn index ->
      text = String.duplicate("CURRENT_INSTRUCTION_#{index}_", 180)

      assert {:ok, _queued} =
               Episodes.apply(
                 EpisodeFixtures.admit_input(%{
                   destination: destination(first),
                   episode_id: first.episode.id,
                   episode_key: first.episode.key,
                   native_input_id: "source:active:#{index}",
                   occurred_at: DateTime.add(@now, index, :second),
                   payload: %{"text" => text},
                   turn_ref: "unused:active:#{index}"
                 })
               )
    end)

    before_delivery = Responder.Repo.get!(Responder.Episodes.Episode, first.episode.id)
    assert {:ok, still_first} = SubmissionBuilder.build(%{first | episode: before_delivery})
    assert still_first["context"]["inputs"]["omitted_count"] == 0
    refute still_first["prompt"] =~ "CURRENT_INSTRUCTION_1_"

    candidate = ~s({"delivery":"reply","message":"First result."})
    candidate_sha256 = digest(candidate)

    assert {:ok, _staged} =
             Custody.stage_candidate(
               first.episode.id,
               first.turn.turn_ref,
               first.lease_ref,
               nil,
               nil,
               candidate,
               candidate_sha256,
               1
             )

    assert {:ok, result} = Result.new(:reply, %{"message" => "First result."})

    assert {:ok, _intent} =
             Custody.prepare_validation(
               first.episode.id,
               first.turn.turn_ref,
               first.lease_ref,
               candidate_sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               first.episode.id,
               first.episode.key,
               first.turn.turn_ref,
               first.lease_ref,
               candidate_sha256,
               1,
               "validation:active-overflow"
             )

    assert {:ok, delivery} = Custody.claim_next("worker:active-overflow-delivery", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               first.episode.destination_transport,
               first.episode.destination_conversation_ref,
               first.episode.destination_thread_ref,
               "1787932807.004100"
             )

    assert {:ok, delivered} =
             Custody.confirm_delivery(
               first.episode.id,
               first.episode.key,
               first.turn.turn_ref,
               delivery.lease_ref,
               receipt
             )

    assert length(delivered.episode.active_input_refs) == 2
    assert length(delivered.episode.queued_input_refs) == 39
    assert {:ok, continuation} = Custody.claim_next("worker:active-overflow-next", 60, :work)

    assert {:ok, submission} = SubmissionBuilder.build(continuation)
    items = submission["context"]["current_inputs"]["items"]
    assert length(items) == 2
    assert Enum.all?(items, & &1["current"])

    assert Enum.map(items, & &1["content"]["text"]) ==
             Enum.map(1..2, &String.duplicate("CURRENT_INSTRUCTION_#{&1}_", 180))

    assert submission["context"]["current_inputs"]["omitted_count"] == 0
  end

  defp claim_episode!(suffix, text) do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: id,
        episode_key: "work-submission:#{suffix}:#{id}",
        native_input_id: "source:#{suffix}:#{id}",
        occurred_at: @now,
        payload: %{"text" => text},
        turn_ref: "turn:#{suffix}:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(command.episode_id, "work-read-only", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 60)
    claim
  end

  defp bind_remote_turn!(claim, submission) do
    assert {:ok, frozen} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:#{claim.episode.id}"
             )

    assert {:ok, _turn} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               frozen.submit_generation,
               "coop-turn:#{claim.turn.id}"
             )
  end

  defp destination(claim) do
    %{
      conversation_ref: claim.episode.destination_conversation_ref,
      thread_ref: claim.episode.destination_thread_ref,
      transport: claim.episode.destination_transport
    }
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
