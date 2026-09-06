defmodule Responder.State.LearningSourcesTest do
  use Responder.DataCase, async: true
  alias Responder.Episodes.Episode
  alias Responder.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Responder.State.LearningSources

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
