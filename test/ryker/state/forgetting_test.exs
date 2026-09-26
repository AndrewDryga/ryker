defmodule Ryker.State.ForgettingTest do
  # QA re-test, 2026-09-26: after Forget on a fact ("Ryker stops using this
  # fact and erases what it saved"), Learned still held the same knowledge,
  # learned by background learning from the same message and kept until
  # December, and a learned topic had no way to be forgotten at all.
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Repo

  alias Ryker.State.{
    ConversationKnowledge,
    ConversationObservation,
    Forgetting,
    Knowledge,
    KnowledgeRevision,
    LearningSources,
    Memories,
    MemoryEntry,
    Observations
  }

  setup do
    [first, second] = LearningFixtures.inputs!(isolate: true)
    %{first: first, second: second}
  end

  test "a forgotten topic is erased, listed as forgotten, and never learned again", %{
    first: first
  } do
    topic = topic!(first, "checkout-readiness", "Checkout readiness")

    assert {:ok, %{forgotten: [id], relearn: []}} = Forgetting.forget_topic(topic.id)
    assert id == topic.id

    forgotten = Repo.get!(ConversationKnowledge, topic.id)
    assert forgotten.forgotten_at
    assert forgotten.state == %{"retention" => "pruned"}

    assert Repo.all(
             from(r in KnowledgeRevision, where: r.knowledge_id == ^topic.id, select: r.state)
           )
           |> Enum.all?(&(&1 == %{"retention" => "pruned"}))

    # Work no longer reads it.
    refute Enum.any?(Knowledge.context(first, first.repository_ref), &(&1["title"] =~ "Checkout"))

    # Learning never takes its message again, even after the message is edited.
    observation = observation!(first)
    assert observation.forgotten_at
    assert is_nil(observation.note)
    assert LearningSources.for_entry(first) == nil

    {:ok, _} =
      Repo.transaction(fn ->
        Observations.receive_in_transaction(%{
          first
          | id: Ecto.UUID.generate(),
            revision: first.revision + 1,
            event_kind: :edit,
            event_fingerprint: String.duplicate("e", 64)
        })
      end)

    edited = observation!(first)
    assert edited.forgotten_at
    assert edited.revision == observation.revision
    assert is_nil(edited.note)

    # Forgetting it again changes nothing.
    assert {:ok, %{forgotten: [], relearn: []}} = Forgetting.forget_topic(topic.id)
  end

  test "what else learning took from the same messages goes with them, or waits to be relearned",
       %{first: first, second: second} do
    target = topic!(first, "checkout-readiness", "Checkout readiness")
    sibling = topic!(first, "deploy-timing", "Deploy timing")
    other = topic!(second, "probe-history", "Probe history")

    # A topic learned from both messages keeps the second one.
    mixed = topic!(second, "incident-timeline", "Incident timeline")
    mixed = update!(first, mixed, "Incident timeline, with the earlier alert")

    assert %{forgotten: forgotten, relearn: relearn} = Forgetting.preview_topic(target.id)
    assert forgotten == [sibling.id]
    assert relearn == [mixed.id]

    assert {:ok, %{forgotten: [_ | _] = gone, relearn: [mixed_id]}} =
             Forgetting.forget_topic(target.id)

    assert Enum.sort(gone) == Enum.sort([target.id, sibling.id])
    assert mixed_id == mixed.id
    assert Repo.get!(ConversationKnowledge, sibling.id).forgotten_at
    assert is_nil(Repo.get!(ConversationKnowledge, mixed.id).forgotten_at)
    assert is_nil(Repo.get!(ConversationKnowledge, other.id).forgotten_at)

    # The mixed topic is no longer used until it is relearned.
    refute mixed.id in available(second)
    assert other.id in available(second)
  end

  test "forgetting a fact forgets what learning kept from the message it came from", %{
    first: first
  } do
    topic = topic!(first, "staging-account", "Staging account")
    fact = answer_fact!(first, "Staging account", "The staging account is acme-staging.")

    assert %{forgotten: [id], relearn: []} = Forgetting.preview_fact(fact)
    assert id == topic.id

    assert {:ok, %MemoryEntry{status: :deleted}} = Memories.forget(fact.ref)
    assert Repo.get!(ConversationKnowledge, topic.id).forgotten_at
    assert observation!(first).forgotten_at
  end

  defp topic!(entry, key, title) do
    proposal = %{
      "topic_key" => key,
      "title" => title,
      "summary" => "#{title}, as the message reported it.",
      "topics" => [key],
      "anchors" => [],
      "target_ref" => nil,
      "expected_version" => 0
    }

    assert {:ok, :ok} =
             Repo.transaction(fn -> KnowledgeFixtures.record_topic(entry, proposal, []) end)

    Repo.one!(from(k in ConversationKnowledge, where: k.topic_key == ^key))
  end

  # The topic learns from another message too: an update offered its current
  # document, as learning offers it.
  defp update!(entry, topic, summary) do
    offered =
      Enum.find(
        Knowledge.context(entry, entry.repository_ref),
        &(&1["source_ref"] == "knowledge:" <> topic.id)
      )

    proposal = %{
      "topic_key" => topic.topic_key,
      "title" => topic.state["title"],
      "summary" => summary,
      "topics" => topic.state["topics"],
      "anchors" => [],
      "target_ref" => offered["source_ref"],
      "expected_version" => topic.version
    }

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               KnowledgeFixtures.record_topic(entry, proposal, [offered])
             end)

    Repo.get!(ConversationKnowledge, topic.id)
  end

  defp observation!(entry),
    do:
      Repo.one!(
        from(o in ConversationObservation,
          where: o.identity_key == ^Observations.source_identity(entry)
        )
      )

  defp available(entry) do
    Knowledge.context(entry, entry.repository_ref)
    |> Enum.map(fn %{"source_ref" => "knowledge:" <> id} -> id end)
  end

  defp answer_fact!(entry, subject, value) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    payload = %{
      "kind" => "entity_relationship",
      "scope" => "global",
      "subject" => subject,
      "value" => value,
      "visibility" => "global"
    }

    Repo.insert!(%MemoryEntry{
      id: id,
      ref: "memory:#{id}",
      kind: :entity_relationship,
      status: :active,
      workspace_ref: "installation",
      scope_ref: "installation:" <> Ryker.CanonicalJSON.digest(subject),
      scope_kind: :global,
      visibility: :global,
      subject: subject,
      payload: payload,
      payload_fingerprint: Ryker.CanonicalJSON.digest(payload),
      answer_provenance: %{"input_ref" => "ingress-input:" <> entry.id},
      confirmed_by_actor_ref: "slack:user:U123",
      confirmation_ref: "answer:#{id}",
      confirmed_at: now,
      source_transport: entry.destination_transport,
      source_conversation_ref: entry.destination_conversation_ref,
      source_thread_ref: entry.destination_thread_ref,
      source_message_ref: entry.native_input_id,
      expires_at: nil,
      inserted_at: now,
      updated_at: now
    })
  end
end
