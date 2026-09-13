defmodule Ryker.State.KnowledgeRebuildTest do
  use Ryker.DataCase, async: true
  import Ecto.Query

  alias Ryker.{CanonicalJSON, Episodes, Repo}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Ryker.Fixtures.Learning, as: LearningFixtures

  alias Ryker.State.{
    ConversationKnowledge,
    ConversationSummary,
    Knowledge,
    KnowledgeRevision,
    KnowledgeSnapshot,
    KnowledgeSource,
    LearningSources,
    Observations,
    SourceExposure
  }

  alias Ryker.Work.{Custody, Session}

  @capture "testdata/learning/recorded-draft-retention-create.json"

  test "relearning preserves topic identity and history but uses only newly selected raw roots" do
    {entries, head, _first_document} = history!()
    [first, second | _] = entries
    KnowledgeFixtures.revoke!(second)
    context = context(head, [first])
    before = {Repo.all(KnowledgeRevision), Repo.all(KnowledgeSource)}

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Knowledge.check_rebuild_sources_in_transaction([first], proposal(), [], context)
             end)

    assert Repo.get!(ConversationKnowledge, head.id) == head
    assert {Repo.all(KnowledgeRevision), Repo.all(KnowledgeSource)} == before

    # The model's create-shaped name is not a new durable identity in this path.
    renamed = Map.put(proposal(), "topic_key", "different-create-shaped-key")

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Knowledge.rebuild_sources_in_transaction([first], renamed, [], context)
             end)

    rebuilt = Repo.get!(ConversationKnowledge, head.id)
    assert rebuilt.topic_key == head.topic_key
    assert rebuilt.version == head.version + 1
    assert rebuilt.source_generation == head.source_generation + 1
    assert rebuilt.latest_source_at == first.occurred_at
    assert Repo.aggregate(ConversationKnowledge, :count) == 1
    assert Repo.aggregate(KnowledgeRevision, :count) == 3
    assert LearningSources.expand(rebuilt.source_dependencies) == LearningSources.for_entry(first)
    assert length(LearningSources.expand(head.source_dependencies)) == 2
    assert [document] = Knowledge.context(first, first.repository_ref)
    assert document["source_ref"] == "knowledge:#{head.id}"
    assert document["source_count"] == 1

    assert {:ok, {:error, :knowledge_rebuild_conflict}} =
             Repo.transaction(fn ->
               Knowledge.rebuild_sources_in_transaction([first], renamed, [], context)
             end)
  end

  test "relearning rejects available targets and changed version or generation without a write" do
    {entries, head, _document} = history!()
    [first, second | _] = entries
    valid = context(head, [first])

    assert {:ok, {:error, :knowledge_rebuild_conflict}} =
             Repo.transaction(fn ->
               Knowledge.check_rebuild_sources_in_transaction([first], proposal(), [], valid)
             end)

    KnowledgeFixtures.revoke!(second)

    for target <- [
          %{valid.rebuild | version: head.version - 1},
          %{valid.rebuild | generation: head.source_generation + 1}
        ] do
      assert {:ok, {:error, :knowledge_rebuild_conflict}} =
               Repo.transaction(fn ->
                 Knowledge.rebuild_sources_in_transaction([first], proposal(), [], %{
                   valid
                   | rebuild: target
                 })
               end)
    end

    assert Repo.get!(ConversationKnowledge, head.id) == head
    assert Repo.aggregate(KnowledgeRevision, :count) == 2

    # Structurally move the target to a different conversation while preserving
    # the source selection; an operator target id is not cross-scope authority.
    other_conversation = head.conversation_ref <> "-other"

    key =
      head
      |> Map.take([:transport, :workspace_ref, :conversation_ref, :repository_ref])
      |> Map.put(:conversation_ref, other_conversation)
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      |> CanonicalJSON.digest()

    other =
      Repo.update!(
        Ecto.Changeset.change(head, conversation_ref: other_conversation, scope_key: key)
      )

    assert {:ok, {:error, :knowledge_rebuild_conflict}} =
             Repo.transaction(fn ->
               Knowledge.rebuild_sources_in_transaction([first], proposal(), [], valid)
             end)

    assert Repo.get!(ConversationKnowledge, head.id) == other
  end

  test "relearning retains every disclosed original without claiming each one was directly cited" do
    {[first, second, third], head, _} = history!()
    [current] = Knowledge.context(first, first.repository_ref)

    update =
      Map.merge(proposal(), %{
        "target_ref" => current["source_ref"],
        "expected_version" => head.version
      })

    inherited =
      source_context([third])
      |> Map.update!(
        :source_dependencies,
        &LearningSources.merge([&1, LearningSources.document_sources(current)])
      )

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Knowledge.record_sources_in_transaction([third], update, [current], inherited)
             end)

    head = Repo.get!(ConversationKnowledge, head.id)
    KnowledgeFixtures.revoke!(second)

    # Both surviving originals were shown; the valid create names only the first
    # as direct support. The uncited disclosed original still contributes custody.
    context = context(head, [first, third])

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Knowledge.rebuild_sources_in_transaction([first], proposal(), [], context)
             end)

    rebuilt = Repo.get!(ConversationKnowledge, head.id)

    assert LearningSources.expand(rebuilt.source_dependencies) ==
             LearningSources.merge([
               LearningSources.for_entry(first),
               LearningSources.for_entry(third)
             ])

    assert [document] = Knowledge.context(first, first.repository_ref)
    assert document["source_count"] == 1
  end

  test "relearning cannot inherit old derived dependencies or accept a selected source withdrawn after checking" do
    {entries, head, first_document} = history!()
    [first, second | _] = entries
    KnowledgeFixtures.revoke!(second)
    context = context(head, [first])
    inherited = %{context | source_dependencies: LearningSources.document_sources(first_document)}

    assert {:ok, {:error, :learning_source_stale}} =
             Repo.transaction(fn ->
               Knowledge.check_rebuild_sources_in_transaction([first], proposal(), [], inherited)
             end)

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Knowledge.check_rebuild_sources_in_transaction([first], proposal(), [], context)
             end)

    KnowledgeFixtures.revoke!(first)

    assert {:ok, {:error, :learning_source_stale}} =
             Repo.transaction(fn ->
               Knowledge.rebuild_sources_in_transaction([first], proposal(), [], context)
             end)

    assert Repo.get!(ConversationKnowledge, head.id) == head
  end

  test "a generation change withdraws even an older clean revision from model context but not audit expansion" do
    {entries, head, first_document} = history!()
    [first, second | _] = entries
    KnowledgeFixtures.revoke!(second)

    {:ok, {:ok, scope}} =
      Repo.transaction(fn -> Observations.locked_scope(first, first.repository_ref) end)

    old_reference = LearningSources.document_sources(first_document)
    summary = retained_summary!(head, first_document, old_reference)
    query = from(s in ConversationSummary, where: s.id == ^summary.id)
    warm = warm_reader!(first, first_document)

    summary_reader =
      warm_reader!(first, %{
        "repository_ref" => summary.repository_ref,
        "source_ref" => summary.ref,
        "state" => summary.state,
        "updated_at" => DateTime.to_iso8601(summary.updated_at)
      })

    assert :ok = KnowledgeSnapshot.reauthorize(first, first.repository_ref, [first_document])
    assert :ok = KnowledgeSnapshot.authorize_session(warm.episode, warm.session)

    assert :ok =
             KnowledgeSnapshot.authorize_session(summary_reader.episode, summary_reader.session)

    assert LearningSources.valid?(old_reference, scope)
    assert Repo.exists?(LearningSources.eligible(query, scope))

    # Structural generation boundary isolates eligibility from the new rebuild
    # API: v1 used only A, v2 inherited B, and B is now withdrawn. A alone remains
    # a valid raw source, but the superseded understanding is no longer current.
    Repo.update!(Ecto.Changeset.change(head, source_generation: head.source_generation + 1))

    assert {:error, :work_knowledge_context_stale} =
             KnowledgeSnapshot.reauthorize(first, first.repository_ref, [first_document])

    assert {:error, :work_knowledge_context_stale} =
             KnowledgeSnapshot.authorize_session(warm.episode, warm.session)

    refute LearningSources.valid?(old_reference, scope)
    assert [_] = LearningSources.expand(old_reference)

    refute Repo.exists?(LearningSources.eligible(query, scope))

    # Expanding summary dependencies into raw roots alone loses the generation
    # boundary even though the old prose remains in the native transcript.
    assert {:error, :work_knowledge_context_stale} =
             KnowledgeSnapshot.authorize_session(summary_reader.episode, summary_reader.session)
  end

  test "handover dependencies keep compact generations and the earliest raw lifetime without double accounting" do
    {[first | _], _head, document} = history!()
    reader = warm_reader!(first, document)
    reference = LearningSources.document_sources(document)

    assert {:ok, {:ok, ^reference}} =
             Repo.transaction(fn -> KnowledgeSnapshot.summary_sources(reader.session.id) end)

    exposure = Repo.get_by!(SourceExposure, session_id: reader.session.id)
    {:ok, retained_at, 0} = DateTime.from_iso8601(exposure.receipt["retained_at"])

    earlier =
      Map.put(
        exposure.receipt,
        "retained_at",
        DateTime.to_iso8601(DateTime.add(retained_at, -60))
      )

    Repo.update!(Ecto.Changeset.change(exposure, receipt: earlier))

    assert {:ok, {:ok, dependencies}} =
             Repo.transaction(fn -> KnowledgeSnapshot.summary_sources(reader.session.id) end)

    assert length(dependencies) == 2
    assert hd(reference) in dependencies
    assert earlier in dependencies
    assert LearningSources.expand(dependencies) == [earlier]

    session = Repo.get!(Session, reader.session.id)

    Repo.update!(Ecto.Changeset.change(session, source_exposure_count: 0))

    assert {:ok, {:error, "source_unavailable"}} =
             Repo.transaction(fn -> KnowledgeSnapshot.summary_sources(reader.session.id) end)

    Repo.update!(Ecto.Changeset.change(Repo.get!(Session, session.id), source_exposure_count: 1))
    Repo.delete_all(from(r in KnowledgeRevision, where: r.version == ^document["version"]))

    assert {:ok, {:error, "source_unavailable"}} =
             Repo.transaction(fn -> KnowledgeSnapshot.summary_sources(reader.session.id) end)
  end

  defp warm_reader!(entry, document) do
    id = Ecto.UUID.generate()

    {:ok, _} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: id,
          episode_key: "generation-reader:#{id}",
          native_input_id: "generation-reader-input:#{id}",
          turn_ref: "generation-reader-turn:#{id}",
          destination: %{
            transport: entry.destination_transport,
            conversation_ref: entry.destination_conversation_ref,
            thread_ref: nil
          }
        })
      )

    {:ok, _} =
      Custody.pin_episode(id, "fixture", String.duplicate("a", 64), nil, entry.repository_ref)

    {:ok, claim} = Custody.claim_next("generation-reader:#{id}", 60)
    assert :ok = KnowledgeSnapshot.expose(claim, [document])
    claim
  end

  defp retained_summary!(head, document, sources) do
    id = Ecto.UUID.generate()
    state = Map.take(document, ~w(summary topics))

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
      source_dependencies: sources,
      source_result_ref: "host-generation-fixture:#{id}"
    })
  end

  defp history! do
    entries =
      "testdata/learning/retained-draft-keep-thread.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("inputs")
      |> Enum.map(
        &LearningFixtures.retained_input!(&1, %{
          policy: "fixture",
          policy_digest: String.duplicate("a", 64)
        })
      )

    [first, second | _] = entries

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Knowledge.record_sources_in_transaction(
                 [first],
                 proposal(),
                 [],
                 source_context([first])
               )
             end)

    [first_document] = Knowledge.context(first, first.repository_ref)

    # Host-contract membership expansion only. The captured text is unchanged;
    # this is not presented as a model answer to the second source.
    update =
      Map.merge(proposal(), %{
        "target_ref" => first_document["source_ref"],
        "expected_version" => 1
      })

    inherited =
      source_context([second])
      |> Map.update!(
        :source_dependencies,
        &LearningSources.merge([&1, LearningSources.document_sources(first_document)])
      )

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Knowledge.record_sources_in_transaction(
                 [second],
                 update,
                 [first_document],
                 inherited
               )
             end)

    {entries, Repo.one!(ConversationKnowledge), first_document}
  end

  defp context(head, entries),
    do:
      source_context(entries)
      |> Map.put(:rebuild_source_entries, entries)
      |> Map.put(:rebuild, %{
        topic_id: head.id,
        version: head.version,
        generation: head.source_generation
      })

  defp source_context(entries),
    do: %{
      result_ref: "host-rebuild-fixture:#{CanonicalJSON.digest(Enum.map(entries, & &1.id))}",
      source_dependencies:
        entries |> Enum.map(&LearningSources.for_entry/1) |> LearningSources.merge(),
      omissions: []
    }

  defp proposal do
    @capture
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["result", "updates"])
    |> hd()
    |> Map.drop(~w(action source_input_ids))
  end
end
