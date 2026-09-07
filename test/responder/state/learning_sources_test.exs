defmodule Responder.State.LearningSourcesTest do
  use Responder.DataCase, async: true
  import Ecto.Query
  alias Responder.{CanonicalJSON, Repo}
  alias Responder.Episodes.Episode
  alias Responder.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Responder.State.{ConversationSummary, LearningSources}

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
