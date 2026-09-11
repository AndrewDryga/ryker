defmodule Responder.State.LearningSourcesTest do
  use Responder.DataCase, async: true
  import Ecto.Query
  alias Responder.{CanonicalJSON, Repo}
  alias Responder.Episodes.Episode
  alias Responder.Fixtures.Knowledge, as: KnowledgeFixtures

  alias Responder.State.{
    Continuity,
    ConversationObservation,
    ConversationSummary,
    LearningSources,
    Observations
  }

  test "observation custody binds original content independently of optional navigation metadata" do
    # Reader availability can change between a frozen submission and recall.
    # It must not invalidate unchanged original text or admit altered prose.
    {entry, _} =
      KnowledgeFixtures.learn!(%Episode{
        destination_transport: "control_plane",
        destination_conversation_ref: "control-plane:lab:#{Ecto.UUID.generate()}"
      })

    note = Repo.get_by!(ConversationObservation, source_input_id: entry.id)
    document = Observations.document(note)
    sources = LearningSources.document_sources(document)
    assert is_list(sources) and sources != []
    without_navigation = Map.drop(document, ["source_read", "thread_ref"])
    assert LearningSources.document_sources(without_navigation) == sources

    assert LearningSources.document_sources(
             Map.put(without_navigation, "summary", "altered original")
           ) == nil

    assert LearningSources.document_sources(Map.put(document, "thread_ref", "another-thread")) ==
             nil
  end

  test "validating normalized knowledge resolves its terminal roots once" do
    {entry, document} =
      KnowledgeFixtures.learn!(%Episode{
        destination_transport: "control_plane",
        destination_conversation_ref: "control-plane:lab:#{Ecto.UUID.generate()}"
      })

    sources = LearningSources.document_sources(document)
    assert {:ok, scope} = Continuity.destination_context(entry, nil)
    handler = {__MODULE__, make_ref()}
    reference = make_ref()

    :ok =
      :telemetry.attach(
        handler,
        [:responder, :repo, :query],
        &__MODULE__.record_expansion/4,
        {self(), reference}
      )

    try do
      # This global handler once counted another async test's query and failed
      # an otherwise green repository gate. Observe only this caller's lookup.
      Task.async(fn -> LearningSources.expand(sources) end) |> Task.await()
      refute_receive {^reference, :expanded}, 0
      assert LearningSources.valid?(sources, scope)
      assert_receive {^reference, :expanded}
      refute_receive {^reference, :expanded}, 0
    after
      :telemetry.detach(handler)
    end
  end

  def record_expansion(_event, _measurements, %{query: query}, {owner, reference}) do
    if self() == owner and String.contains?(query, "FROM responder_learning_roots($1)"),
      do: send(owner, {reference, :expanded})
  end

  test "pruned topic roots remain available to retention but cannot authorize new disclosure" do
    {entry, document} =
      KnowledgeFixtures.learn!(%Episode{
        destination_transport: "control_plane",
        destination_conversation_ref: "control-plane:lab:#{Ecto.UUID.generate()}"
      })

    sources = LearningSources.document_sources(document)
    assert {:ok, scope} = Continuity.destination_context(entry, nil)
    assert LearningSources.valid?(sources, scope)
    "knowledge:" <> id = document["source_ref"]

    Repo.update_all(from(r in Responder.State.KnowledgeRevision, where: r.knowledge_id == ^id),
      set: [state: %{"retention" => "pruned"}]
    )

    assert [_] = LearningSources.expand(sources)
    refute LearningSources.valid?(sources, scope)
    query = from(k in Responder.State.ConversationKnowledge, where: k.id == ^id)
    assert query |> LearningSources.eligible(scope) |> Repo.all() == []
  end

  test "missing and malformed knowledge references cannot turn into source-free context" do
    reference = LearningSources.knowledge_reference(Ecto.UUID.generate(), 1, 1)

    for invalid <- [
          reference,
          Map.put(reference, "generation", 0),
          Map.put(reference, "generation", "1"),
          Map.put(reference, "through_version", 9_223_372_036_854_775_808),
          Map.put(reference, "knowledge_id", "invalid"),
          Map.put(reference, "unexpected", true)
        ] do
      assert LearningSources.merge([[invalid]]) == nil
      refute LearningSources.valid?([invalid], %{})
    end
  end

  test "generic source eligibility rejects non-array history without rejecting source-free host data" do
    scope = %{
      workspace_ref: "slack:T123",
      conversation_ref: "slack:T123:C123",
      visibility: :public,
      transport: "slack"
    }

    rows =
      for sources <- [[], %{}, "unavailable", nil] do
        id = Ecto.UUID.generate()

        summary =
          Repo.insert!(%ConversationSummary{
            id: id,
            ref: "continuity:#{id}",
            identity_key: CanonicalJSON.digest(id),
            transport: scope.transport,
            workspace_ref: scope.workspace_ref,
            conversation_ref: scope.conversation_ref,
            visibility: scope.visibility,
            state: %{},
            state_fingerprint: CanonicalJSON.digest(%{}),
            source_dependencies: sources || [],
            source_result_ref: "result:#{id}"
          })

        if is_nil(sources),
          do: Repo.update!(Ecto.Changeset.change(summary, source_dependencies: nil)),
          else: summary
      end

    [source_free | _] = rows
    ids = Enum.map(rows, & &1.id)
    query = from(item in ConversationSummary, where: item.id in ^ids)
    assert [eligible] = query |> LearningSources.eligible(scope) |> Repo.all()
    assert eligible.id == source_free.id
    assert LearningSources.valid?([], scope)
  end

  test "multiple paths to one source retain its earliest expiry without spending two receipts" do
    {entry, _} =
      KnowledgeFixtures.learn!(%Episode{
        destination_transport: "control_plane",
        destination_conversation_ref: "control-plane:lab:#{Ecto.UUID.generate()}"
      })

    [receipt] = LearningSources.for_entry(entry)

    older =
      Map.put(receipt, "retained_at", DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -600)))

    assert LearningSources.merge([[receipt], [older]]) == [older]
  end

  test "invalid source receipts fail closed before UUID queries or timestamp parsing can raise" do
    {entry, _} =
      KnowledgeFixtures.learn!(%Episode{
        destination_transport: "control_plane",
        destination_conversation_ref: "control-plane:lab:#{Ecto.UUID.generate()}"
      })

    [receipt] = LearningSources.for_entry(entry)

    for invalid <- [
          nil,
          "source",
          Map.put(receipt, "observation_id", "not-a-uuid"),
          Map.put(receipt, "revision", -1),
          Map.put(receipt, "retained_at", 3),
          Map.put(receipt, "untrusted_extra", "value")
        ] do
      assert LearningSources.merge([[invalid]]) == nil
      assert LearningSources.valid?([invalid], %{}) == false
    end

    assert LearningSources.document_sources(%{"source_ref" => "observation:invalid"}) == nil
  end

  test "source expiry ordering compares instants rather than ISO timestamp spellings" do
    # Fractional seconds sort before Z as text; that used to extend copied-source TTL.
    {entry, _} =
      KnowledgeFixtures.learn!(%Episode{
        destination_transport: "control_plane",
        destination_conversation_ref: "control-plane:lab:#{Ecto.UUID.generate()}"
      })

    [receipt] = LearningSources.for_entry(entry)
    earlier = Map.put(receipt, "retained_at", "2026-09-06T12:00:00Z")
    later = Map.put(receipt, "retained_at", "2026-09-06T12:00:00.100000Z")
    assert LearningSources.merge([[later], [earlier]]) == [earlier]
  end
end
