defmodule Ryker.State.KnowledgeRebuildConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.{CanonicalJSON, Episodes, Repo}
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Ingress.Inbox.Entry

  alias Ryker.State.{
    ConversationKnowledge,
    ConversationObservation,
    ConversationSummary,
    Knowledge,
    KnowledgeSnapshot,
    LearningSources
  }

  alias Ryker.Work.{Custody, Session, Turn}

  test "a compact summary cannot cross a concurrent generation replacement without current custody" do
    # A retained summary can mention only clean v1 while v2 loses another source.
    # Its raw roots still validate; the current head is the generation fence.
    Sandbox.unboxed_run(Repo, fn ->
      {entry, head, summary, claim, document} = fixture!()
      parent = self()

      writer =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            current =
              Repo.one!(
                from(k in ConversationKnowledge, where: k.id == ^head.id, lock: "FOR UPDATE")
              )

            send(parent, {:generation_locked, self()})
            receive do: (:replace_generation -> :ok)

            # Structural generation boundary, not a fabricated model answer.
            Repo.update!(
              Ecto.Changeset.change(current, source_generation: current.source_generation + 1)
            )
          end)
        end)

      try do
        assert_receive {:generation_locked, pid} when pid == writer.pid, 5_000

        assert {:error, :work_derived_context_busy} = KnowledgeSnapshot.expose(claim, [document])
        assert Repo.get!(Session, claim.session.id).knowledge_exposure_count == 0
        assert Repo.get!(Session, claim.session.id).source_exposure_count == 0

        send(writer.pid, :replace_generation)
        assert {:ok, _} = Task.await(writer)

        assert {:error, :work_knowledge_context_stale} =
                 KnowledgeSnapshot.expose(claim, [document])

        assert Repo.get!(Session, claim.session.id).knowledge_exposure_count == 0
        assert Repo.get!(Session, claim.session.id).source_exposure_count == 0
      after
        stop_tasks([writer])
        cleanup(entry, head, summary, claim)
      end
    end)
  end

  defp fixture! do
    raw =
      "testdata/learning/retained-draft-keep-thread.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("inputs")
      |> hd()

    entry =
      LearningFixtures.retained_input!(raw, %{
        policy: "fixture",
        policy_digest: String.duplicate("a", 64)
      })

    proposal =
      "testdata/learning/recorded-draft-retention-create.json"
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["result", "updates"])
      |> hd()
      |> Map.drop(~w(action source_input_ids))

    assert {:ok, :ok} =
             Repo.transaction(fn -> KnowledgeFixtures.record_topic(entry, proposal, []) end)

    [topic] = Knowledge.context(entry, entry.repository_ref)
    head = Repo.one!(ConversationKnowledge)
    id = Ecto.UUID.generate()
    state = Map.take(topic, ~w(summary topics))

    summary =
      Repo.insert!(%ConversationSummary{
        id: id,
        ref: "continuity:#{id}",
        identity_key: CanonicalJSON.digest(id),
        transport: head.transport,
        workspace_ref: head.workspace_ref,
        conversation_ref: head.conversation_ref,
        repository_ref: head.repository_ref,
        visibility: head.visibility,
        state: state,
        state_fingerprint: CanonicalJSON.digest(state),
        source_dependencies: LearningSources.document_sources(topic),
        source_result_ref: "host-generation-race:#{id}"
      })

    {entry, head, summary, claim!(entry),
     %{
       "repository_ref" => summary.repository_ref,
       "source_ref" => summary.ref,
       "state" => summary.state,
       "updated_at" => DateTime.to_iso8601(summary.updated_at)
     }}
  end

  defp claim!(entry) do
    id = Ecto.UUID.generate()

    {:ok, _} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: id,
          episode_key: "generation-race:#{id}",
          native_input_id: "generation-race-input:#{id}",
          turn_ref: "generation-race-turn:#{id}",
          destination: %{
            transport: entry.destination_transport,
            conversation_ref: entry.destination_conversation_ref,
            thread_ref: nil
          }
        })
      )

    {:ok, _} =
      Custody.pin_episode(id, "fixture", String.duplicate("a", 64), nil, entry.repository_ref)

    {:ok, claim} = Custody.claim_next("generation-race-worker:#{id}", 60)
    assert claim.episode.id == id
    assert :ok = KnowledgeSnapshot.expose(claim, [])
    claim
  end

  defp cleanup(entry, head, summary, claim) do
    Repo.delete_all(from(t in Turn, where: t.episode_id == ^claim.episode.id))
    Repo.delete_all(from(s in Session, where: s.episode_id == ^claim.episode.id))
    Repo.delete_all(from(e in Event, where: e.episode_id == ^claim.episode.id))
    Repo.delete_all(from(e in Episode, where: e.id == ^claim.episode.id))
    Repo.delete_all(from(s in ConversationSummary, where: s.id == ^summary.id))
    Repo.delete_all(from(k in ConversationKnowledge, where: k.id == ^head.id))
    Repo.delete_all(from(o in ConversationObservation, where: o.source_input_id == ^entry.id))
    Repo.delete_all(from(e in Entry, where: e.id == ^entry.id))
  end
end
