defmodule Ryker.State.DerivedContextTest do
  use Ryker.DataCase, async: true
  import Ecto.Query

  alias Ryker.{Episodes, Repo}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Ryker.Fixtures.Learning, as: LearningFixtures

  alias Ryker.State.{
    ConversationKnowledge,
    ConversationObservation,
    DerivedContext,
    KnowledgeSnapshot,
    Observations,
    Outcomes,
    Records,
    SourceExposure
  }

  alias Ryker.StateTools.FixedTools
  alias Ryker.Work.{Custody, Final, Result, Session, Submission, SubmissionBuilder, Turn}

  @captured "testdata/learning/recorded-private-source-citation.json"
  @source "testdata/learning/retained-haproxy-lifecycle.json"

  test "captured source fixtures isolate lock identities without changing the retained evidence" do
    # Async security tests shared the captured Inbox primary key with retention
    # tests but acquired the conversation lock in the opposite order. Both the
    # unique row and its Slack lock scope must be local to this replay fixture.
    raw = @source |> File.read!() |> Jason.decode!() |> Map.fetch!("inputs") |> hd()
    {producer, source, record} = cited_source!()

    refute source.id == raw["id"]
    refute source.dedupe_key == raw["dedupe_key"]
    refute source.native_input_id == raw["native_input_id"]
    refute source.source_ref == raw["source_ref"]
    refute source.destination_conversation_ref == raw["destination_conversation_ref"]
    assert producer.episode.destination_conversation_ref == source.destination_conversation_ref
    assert source.content == raw["content"]

    assert DateTime.to_naive(source.occurred_at) ==
             NaiveDateTime.from_iso8601!(raw["occurred_at"])

    assert record.payload["source_id"] == "observation:#{source.id}"
    assert record.payload["source_name"] == "observation:#{source.id}"
    assert record.payload["claim"] == captured()["arguments"]["subject"]
    assert record.payload["target"] == captured()["arguments"]["subject"]

    assert Map.take(record.payload, ~w(observation relation supersedes)) ==
             Map.take(captured()["arguments"], ~w(observation relation supersedes))
  end

  test "a retained real citation cannot launder a withdrawn source into replacement context" do
    # The actual privacy qualification rejected acceptance but retained this
    # citation. Its replacement briefing had never been tested past creation.
    {producer, source, record} = cited_source!()
    recipient = replacement!(producer)
    KnowledgeFixtures.revoke!(source)

    assert {:ok, state} = work_state(recipient)
    refute Enum.any?(state["records"], &(&1["ref"] == record.ref))
    assert {:ok, submission} = SubmissionBuilder.build(recipient)
    refute submission["prompt"] =~ captured()["arguments"]["observation"]

    assert Repo.get!(Ryker.State.Record, record.id).payload["observation"] ==
             captured()["arguments"]["observation"]
  end

  test "an accepted historical answer cannot reintroduce its withdrawn source through outcomes" do
    {producer, source, _record} = cited_source!()

    settled_turn!(producer)

    producer.episode
    |> Ecto.Changeset.change(
      state: :complete,
      owner_kind: nil,
      owner_ref: nil,
      active_input_refs: []
    )
    |> Repo.update!()

    recipient = claim!("outcome-recipient", producer.episode.destination_conversation_ref)
    assert [_] = Outcomes.recall(recipient.episode)
    KnowledgeFixtures.revoke!(source)

    assert Outcomes.recall(recipient.episode) == []
    assert {:ok, submission} = SubmissionBuilder.build(recipient)
    refute submission["prompt"] =~ captured()["candidate"]["message"]
  end

  test "a valid citation disclosed to another session inherits the later revocation fence" do
    {producer, source, record} = cited_source!()
    recipient = replacement!(producer)
    assert {:ok, state} = work_state(recipient)
    assert Enum.any?(state["records"], &(&1["ref"] == record.ref))
    assert :ok = KnowledgeSnapshot.authorize_session(recipient.episode, recipient.session)

    KnowledgeFixtures.revoke!(source)

    assert {:error, :work_knowledge_context_stale} =
             KnowledgeSnapshot.authorize_session(recipient.episode, recipient.session)
  end

  test "later revocation rejects acceptance even when the citation was only read through the tool" do
    {producer, source, record} = cited_source!()
    recipient = producer |> replacement!() |> prepared!(record)
    assert recipient.turn.submission["context"] == %{}
    assert {:ok, %{"records" => [_]}} = work_state(recipient)
    KnowledgeFixtures.revoke!(source)

    assert {:error, :work_knowledge_context_stale} =
             Custody.accept_result(
               recipient.episode.id,
               recipient.episode.key,
               recipient.turn.turn_ref,
               recipient.lease_ref,
               recipient.turn.candidate_sha256,
               recipient.turn.candidate_attempt,
               "validation:derived-source"
             )

    assert Repo.get!(Turn, recipient.turn.id).result_ref == nil
    assert Repo.get!(Turn, recipient.turn.id).delivery_ref == nil
  end

  test "an unchanged citation survives a fresh briefing with its exact source custody" do
    {producer, _source, record} = cited_source!()
    recipient = replacement!(producer)
    assert {:ok, submission} = SubmissionBuilder.build(recipient)
    assert Enum.any?(submission["context"]["records"], &(&1["ref"] == record.ref))

    assert :ok =
             KnowledgeSnapshot.authorize_submission(recipient.episode, "blitz-infra", submission)

    assert :ok =
             KnowledgeSnapshot.expose_submission(%{
               recipient
               | turn: %{recipient.turn | submission: submission}
             })

    assert KnowledgeSnapshot.session_sources(recipient.session.id) ==
             KnowledgeSnapshot.session_sources(producer.session.id)
  end

  test "an owned record reference cannot authorize changed projection text or another episode" do
    {producer, _source, _record} = cited_source!()
    recipient = replacement!(producer)
    assert {:ok, submission} = SubmissionBuilder.build(recipient)

    forged =
      put_in(
        submission,
        ["context", "records", Access.at(0), "payload", "observation"],
        "forged model text"
      )

    assert {:error, :work_knowledge_context_stale} =
             KnowledgeSnapshot.authorize_submission(recipient.episode, "blitz-infra", forged)

    other = claim!("another-episode", producer.episode.destination_conversation_ref)

    assert {:error, :work_knowledge_context_stale} =
             KnowledgeSnapshot.authorize_submission(other.episode, "blitz-infra", submission)
  end

  test "physically removed source roots fail closed without deleting retained record history" do
    {producer, source, record} = cited_source!()
    recipient = replacement!(producer)
    assert {:ok, %{"records" => [_]}} = work_state(recipient)

    Repo.delete!(Repo.get!(ConversationObservation, source.id))
    assert Records.model_records(recipient.episode, "blitz-infra") == []
    assert Enum.any?(Records.retained_records(recipient.episode.id), &(&1["ref"] == record.ref))
  end

  test "erased exposure rows do not make an existing producer source-free" do
    {producer, _source, _record} = cited_source!()
    recipient = replacement!(producer)
    Repo.delete_all(from(e in SourceExposure, where: e.session_id == ^producer.session.id))
    assert Records.model_records(recipient.episode, "blitz-infra") == []
  end

  test "partial exposure pruning cannot be healed by another otherwise valid disclosure" do
    {producer, source, _record} = cited_source!()
    {_extra_source, knowledge} = KnowledgeFixtures.learn!(producer.episode, "blitz-infra")
    assert :ok = KnowledgeSnapshot.expose(producer, [knowledge])
    session = Repo.get!(Session, producer.session.id)
    assert session.source_exposure_count == 2
    assert session.knowledge_exposure_count == 1

    Repo.delete_all(
      from(e in SourceExposure,
        where: e.session_id == ^session.id and e.observation_id == ^source.id
      )
    )

    assert {:error, :work_knowledge_context_stale} =
             KnowledgeSnapshot.expose(producer, [knowledge])

    assert Repo.get!(Session, session.id).source_exposure_count == 2
    assert Records.model_records(producer.episode, "blitz-infra") == []
  end

  test "tracked zero is valid but a legacy record cannot be retrospectively certified" do
    producer = claim!("legacy-zero")

    assert {:ok, _record} =
             FixedTools.call("cite_source", captured()["arguments"], %{
               binding: tool_binding(producer)
             })

    assert :ok = KnowledgeSnapshot.expose(producer, [])
    assert Repo.get!(Session, producer.session.id).source_exposure_count == nil
    assert Records.model_records(producer.episode, "blitz-infra") == []

    # This separate fresh session explicitly accounts for its source-free host
    # input before producing any model record; absence alone is not the proof.
    fresh = claim!("tracked-zero")
    assert :ok = KnowledgeSnapshot.expose(fresh, [])
    assert Repo.get!(Session, fresh.session.id).source_exposure_count == 0
    assert Repo.get!(Session, fresh.session.id).knowledge_exposure_count == 0

    assert {:ok, _record} =
             FixedTools.call("cite_source", captured()["arguments"], %{
               binding: tool_binding(fresh)
             })

    assert [_] = Records.model_records(fresh.episode, "blitz-infra")
  end

  test "failed exposure does not initialize custody and repeated exposure is idempotent" do
    fresh = claim!("failed-first-disclosure")

    missing = %{
      "kind" => "conversation_observation",
      "source_ref" => "observation:#{Ecto.UUID.generate()}"
    }

    assert {:error, :work_knowledge_context_stale} = KnowledgeSnapshot.expose(fresh, [missing])
    assert Repo.get!(Session, fresh.session.id).source_exposure_count == nil
    assert :ok = KnowledgeSnapshot.expose(fresh, [])
    assert :ok = KnowledgeSnapshot.expose(fresh, [])
    assert Repo.get!(Session, fresh.session.id).source_exposure_count == 0
  end

  test "later producer disclosures are inherited conservatively including knowledge withdrawal" do
    {producer, _source, _record} = cited_source!()
    {_additional_source, knowledge} = KnowledgeFixtures.learn!(producer.episode, "blitz-infra")
    assert :ok = KnowledgeSnapshot.expose(producer, [knowledge])
    recipient = replacement!(producer)
    assert {:ok, %{"records" => [_]}} = work_state(recipient)

    # Raw observations still exist; withdrawing the learned topic independently
    # must invalidate the inherited knowledge exposure as well.
    Repo.delete_all(ConversationKnowledge)

    assert {:error, :work_knowledge_context_stale} =
             KnowledgeSnapshot.authorize_session(recipient.episode, recipient.session)
  end

  test "previous deliveries in both briefing modes retain their producer source identity" do
    {producer, source, _record} = cited_source!()
    turn = settled_turn!(producer)
    document = DerivedContext.delivery_document(turn)

    contexts = [
      %{"prior_outcome" => document},
      %{
        "parent_submission_ref" => document["submission_ref"],
        "continuity" => %{
          "previous_delivery" => document["delivery"],
          "previous_turn_ref" => document["source_turn_ref"]
        }
      }
    ]

    for context <- contexts do
      assert :ok =
               KnowledgeSnapshot.authorize_submission(producer.episode, "blitz-infra", %{
                 "context" => context
               })
    end

    KnowledgeFixtures.revoke!(source)

    for context <- contexts do
      assert {:error, :work_knowledge_context_stale} =
               KnowledgeSnapshot.authorize_submission(producer.episode, "blitz-infra", %{
                 "context" => context
               })
    end
  end

  test "missing producer identity or pruned delivery prose is never accepted as historical context" do
    {producer, _source, _record} = cited_source!()
    turn = settled_turn!(producer)
    document = DerivedContext.delivery_document(turn)

    assert {:error, :work_knowledge_context_stale} =
             KnowledgeSnapshot.authorize_submission(producer.episode, "blitz-infra", %{
               "context" => %{
                 "prior_outcome" => %{document | "source_turn_ref" => Ecto.UUID.generate()}
               }
             })

    Repo.update!(
      Ecto.Changeset.change(turn,
        delivery_document: %{"retention" => "pruned"},
        operational_pruned_at: DateTime.utc_now()
      )
    )

    assert {:error, :work_knowledge_context_stale} =
             KnowledgeSnapshot.authorize_submission(producer.episode, "blitz-infra", %{
               "context" => %{"prior_outcome" => document}
             })
  end

  test "records sharing one producer do not repeat its source-lineage database work" do
    {producer, _source, record} = cited_source!()

    {[_], baseline_queries} =
      source_queries(fn -> Records.model_records(producer.episode, "blitz-infra") end)

    # Structural repetition of the captured record, not invented model output.
    # Source roots can reach 10,000; resolving that lineage per row is quadratic.
    for index <- 1..31 do
      record
      |> Map.from_struct()
      |> Map.take(Ryker.State.Record.__schema__(:fields))
      |> Map.merge(%{
        id: Ecto.UUID.generate(),
        ref: "record:evidence:#{Ecto.UUID.generate()}",
        operation_id: "structural-copy-#{index}",
        sequence: nil
      })
      |> then(&struct!(Ryker.State.Record, &1))
      |> Repo.insert!()
    end

    {records, expanded_queries} =
      source_queries(fn -> Records.model_records(producer.episode, "blitz-infra") end)

    assert length(records) == 32
    assert expanded_queries <= baseline_queries + 2
  end

  test "source-lineage query measurement ignores unrelated concurrent callers" do
    # The full gate counted another async test's exposure queries (13 vs 7),
    # making a constant-work implementation look quadratic. Telemetry handlers
    # execute in the calling process; this event is structural test interference.
    assert {:ok, 0} =
             source_queries(fn ->
               Task.async(fn ->
                 :telemetry.execute(
                   [:ryker, :repo, :query],
                   %{},
                   %{query: "SELECT 1 FROM episode_work_source_exposures"}
                 )
               end)
               |> Task.await()
             end)

    assert {0, 1} = source_queries(fn -> Repo.aggregate(SourceExposure, :count) end)
  end

  defp source_queries(fun) do
    reference = make_ref()

    :ok =
      :telemetry.attach(
        reference,
        [:ryker, :repo, :query],
        &__MODULE__.count_source_query/4,
        {self(), reference}
      )

    try do
      {fun.(), drain_source_queries(reference, 0)}
    after
      :telemetry.detach(reference)
    end
  end

  def count_source_query(_event, _measurements, %{query: query}, {owner, reference}) do
    if self() == owner and String.contains?(query, "episode_work_source_exposures"),
      do: send(owner, reference)
  end

  defp drain_source_queries(reference, count) do
    receive do
      ^reference -> drain_source_queries(reference, count + 1)
    after
      0 -> count
    end
  end

  defp settled_turn!(producer) do
    # Structural settled lifecycle, using the actual public candidate unchanged;
    # this tests host history, not a claim that the revoked live run was accepted.
    producer.turn
    |> Ecto.Changeset.change(
      status: :settled,
      candidate: Jason.encode!(captured()["candidate"]),
      candidate_sha256: Ryker.CanonicalJSON.digest(captured()["candidate"]),
      candidate_attempt: 1,
      validation_intent: %{"verdict" => "accept"},
      validation_intent_fingerprint: String.duplicate("a", 64),
      validation_receipt: "captured-validation",
      continuation: %{"kind" => "complete"},
      lease_ref: nil,
      lease_owner: nil,
      lease_expires_at: nil,
      next_attempt_at: nil,
      result_ref: "captured-result:#{producer.turn.id}",
      delivery_ref: "captured-delivery:#{producer.turn.id}",
      delivery_document: captured()["candidate"],
      delivery_fingerprint: Ryker.CanonicalJSON.digest(captured()["candidate"]),
      external_receipt: %{"message_ref" => "captured-message"},
      external_receipt_fingerprint: String.duplicate("b", 64),
      delivered_at: DateTime.utc_now(),
      accepted_at: DateTime.utc_now()
    )
    |> Repo.update!()
  end

  defp prepared!(claim, record) do
    # A valid host-contract submission without optional history isolates the
    # get_work_state disclosure fence. Only ephemeral record identity is rebound;
    # the captured model's answer text and decision remain unchanged.
    {:ok, submission} =
      Submission.new(
        %{},
        "Host-contract source-custody fixture.",
        Final.json_schema(),
        "work-final-live-v3"
      )

    {:ok, turn} =
      Custody.freeze_submission(
        claim.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        submission
      )

    {:ok, session} =
      Custody.bind_session(
        claim.episode.id,
        turn.turn_ref,
        claim.lease_ref,
        claim.session.generation,
        claim.session.create_generation,
        "remote:#{claim.session.id}"
      )

    {:ok, turn} =
      Custody.bind_turn(
        claim.episode.id,
        turn.turn_ref,
        claim.lease_ref,
        session.generation,
        turn.submit_generation,
        "remote-turn:#{turn.id}"
      )

    candidate =
      put_in(captured(), ["candidate", "outcome", "record_refs"], [record.ref])["candidate"]

    body = Jason.encode!(candidate)
    sha = Ryker.CanonicalJSON.digest(candidate)

    {:ok, _} =
      Custody.stage_candidate(
        claim.episode.id,
        turn.turn_ref,
        claim.lease_ref,
        nil,
        nil,
        body,
        sha,
        1
      )

    {:ok, result} = Result.new(:reply, candidate)

    {:ok, turn} =
      Custody.prepare_validation(
        claim.episode.id,
        turn.turn_ref,
        claim.lease_ref,
        sha,
        1,
        :accept,
        result
      )

    %{claim | session: session, turn: turn}
  end

  defp cited_source! do
    raw =
      @source
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("inputs")
      |> hd()
      |> LearningFixtures.isolate_retained_input()

    source =
      LearningFixtures.retained_input!(raw, %{
        policy: "fixture",
        policy_digest: String.duplicate("a", 64)
      })

    {:ok, :ok} = Repo.transaction(fn -> Observations.record_excerpt_in_transaction(source) end)
    producer = claim!("source-producer", source.destination_conversation_ref)

    document =
      source.id |> then(&Repo.get!(ConversationObservation, &1)) |> Observations.document()

    assert :ok = KnowledgeSnapshot.expose(producer, [document])

    # Only the host-issued observation reference changes with this fixture's
    # custody identity; the recorded model's citation prose remains verbatim.
    arguments = Map.put(captured()["arguments"], "source_ref", "observation:#{source.id}")

    assert {:ok, %{"record_ref" => ref}} =
             FixedTools.call("cite_source", arguments, %{
               binding: tool_binding(producer)
             })

    {:ok, [record]} = Records.fetch_for_episode(producer.episode.id, [ref])
    {producer, source, record}
  end

  defp claim!(suffix, conversation \\ nil) do
    id = Ecto.UUID.generate()
    conversation = conversation || "slack:T#{String.replace(id, "-", "")}:C08MMETA3U3"

    {:ok, _} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: id,
          episode_key: "derived-context:#{id}",
          native_input_id: "source:#{id}",
          turn_ref: "turn:#{id}",
          payload: %{"text" => "Continue the investigation."},
          destination: %{
            transport: "slack",
            conversation_ref: conversation,
            thread_ref: suffix
          }
        })
      )

    {:ok, _} = Custody.pin_episode(id, "fixture", String.duplicate("a", 64), nil, "blitz-infra")
    {:ok, claim} = Custody.claim_next("worker:#{id}", 60, :work)
    claim
  end

  defp replacement!(producer) do
    # Structural new native session/new owner; keep the producing turn and
    # receipts intact exactly as normal supersession does.
    producer.turn
    |> Ecto.Changeset.change(
      status: :superseded,
      lease_ref: nil,
      lease_owner: nil,
      lease_expires_at: nil,
      next_attempt_at: nil
    )
    |> Repo.update!()

    session =
      Repo.insert!(%Session{
        id: Ecto.UUID.generate(),
        episode_id: producer.episode.id,
        generation: 2,
        policy: producer.session.policy,
        policy_digest: producer.session.policy_digest,
        repository_ref: producer.session.repository_ref,
        external_ref: "replacement:#{producer.session.id}"
      })

    turn = producer.turn |> Map.from_struct() |> Map.drop([:__meta__, :id, :episode, :session])

    turn =
      struct!(
        Turn,
        Map.merge(turn, %{
          id: Ecto.UUID.generate(),
          turn_ref: "replacement:#{producer.turn.id}",
          session_id: session.id
        })
      )
      |> Repo.insert!()

    episode =
      producer.episode |> Ecto.Changeset.change(owner_ref: turn.turn_ref) |> Repo.update!()

    %{producer | episode: episode, session: session, turn: turn}
  end

  defp work_state(claim),
    do:
      FixedTools.call(
        "get_work_state",
        %{"history" => "current", "limit" => 64, "types" => ["citation"]},
        %{binding: tool_binding(claim)}
      )

  defp tool_binding(claim), do: Map.put(claim, :state_token, Records.token(claim.turn))
  defp captured, do: @captured |> File.read!() |> Jason.decode!()
end
