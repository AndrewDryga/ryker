defmodule Ryker.Memories.ForgettingTest do
  # QA re-test, 2026-09-26: after Forget on a fact ("Ryker stops using this
  # fact and erases what it saved"), Learned still held the same knowledge,
  # learned by background learning from the same message and kept until
  # December, and a learned topic had no way to be forgotten at all.
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Repo

  alias Ryker.Knowledge
  alias Ryker.Knowledge.ConversationKnowledge
  alias Ryker.Knowledge.KnowledgeRevision
  alias Ryker.Knowledge.KnowledgeSnapshot
  alias Ryker.Learning
  alias Ryker.Learning.ConversationObservation
  alias Ryker.Learning.LearningRun
  alias Ryker.Learning.LearningSources
  alias Ryker.Learning.Observations
  alias Ryker.Memories
  alias Ryker.Memories.Forgetting
  alias Ryker.Memories.MemoryEntry
  alias Ryker.Memories.Reviews

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

  # A forgotten or expired topic kept its key and anchors, matched every later topic on the
  # same subject, and refused it as unavailable: the batch was set aside and its messages
  # never learned, so a recurring subject stopped being learned 90 days after it first was
  # (2026-10-04 review). A topic that is gone gives its subject to the next one.
  test "a forgotten topic's subject is learned again from a new message", %{
    first: first,
    second: second
  } do
    forgotten = topic!(first, "checkout-readiness", "Checkout readiness")
    assert {:ok, _} = Forgetting.forget_topic(forgotten.id)

    relearned = topic!(second, "checkout-readiness", "Checkout readiness, again")
    assert relearned.id != forgotten.id
    assert relearned.id in available(second)
  end

  test "an expired topic's subject is learned again from a new message", %{
    first: first,
    second: second
  } do
    expired = topic!(first, "probe-history", "Probe history")

    Repo.update_all(from(k in ConversationKnowledge, where: k.id == ^expired.id),
      set: [state: %{"retention" => "pruned"}]
    )

    renewed = topic!(second, "probe-history", "Probe history, renewed")
    assert renewed.id != expired.id
    assert renewed.id in available(second)
  end

  # Only the pre-lock filter read `forgotten_at`. The locked recheck Work runs on a topic
  # before each turn compared its messages' revisions and fingerprints, which forgetting
  # keeps: an open session kept answering from a topic one of whose messages was forgotten
  # (2026-10-04 review).
  test "a topic resting on a forgotten message is refused before Work uses it again",
       %{first: first, second: second} do
    target = topic!(first, "checkout-readiness", "Checkout readiness")
    mixed = topic!(second, "incident-timeline", "Incident timeline")
    mixed = update!(first, mixed, "Incident timeline, with the earlier alert")

    [document] =
      Enum.filter(
        Knowledge.context(second, second.repository_ref),
        &(&1["source_ref"] == "knowledge:" <> mixed.id)
      )

    assert :ok =
             KnowledgeSnapshot.reauthorize(second, second.repository_ref, [
               document
             ])

    assert {:ok, _forgotten} = Forgetting.forget_topic(target.id)

    # The message stays a valid input Ryker answers (its own receipt still
    # holds); only the topic that rests on what learning took from it goes.
    assert {:error, _stale} =
             KnowledgeSnapshot.reauthorize(second, second.repository_ref, [
               document
             ])
  end

  # A learning run keeps the prompt it sent, which quotes the messages it
  # read, and the answer it got. Forgetting a message left both on the
  # Timeline for 30 or 90 days, against "a forgotten fact keeps no words"
  # (2026-10-04 review).
  test "forgetting a topic erases the words learning runs read of its messages", %{
    first: first,
    second: second
  } do
    settings = %{policy: "recorded-read-only-policy", policy_digest: String.duplicate("a", 64)}
    assert {:ok, read_it} = Learning.prepare([first.id], settings)
    assert {:ok, other} = Learning.prepare([second.id], settings)
    assert is_binary(read_it.prompt)

    topic = topic!(first, "checkout-readiness", "Checkout readiness")
    assert {:ok, _forgotten} = Forgetting.forget_topic(topic.id)

    erased = Repo.get!(LearningRun, read_it.id)
    assert erased.prompt == nil
    assert erased.result == nil
    assert erased.pruned_at
    assert Repo.get!(LearningRun, other.id).prompt == other.prompt
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

  # Forget from the review queue, App Home's Forget all and the console's
  # review Forget among them, only redacted the fact, and learning kept what it
  # took from the fact's message (2026-10-04 review).
  test "forgetting a fact from the review queue forgets what learning kept too", %{first: first} do
    topic = topic!(first, "staging-account", "Staging account")
    fact = answer_fact!(first, "Staging account", "The staging account is acme-staging.")

    Repo.update_all(from(m in MemoryEntry, where: m.id == ^fact.id),
      set: [updated_at: DateTime.add(DateTime.utc_now(), -3_600, :second)]
    )

    assert {:ok, _created} = Reviews.refresh_reviews(fact.workspace_ref, 60)

    assert [review] =
             fact.workspace_ref
             |> Reviews.list_reviews(limit: 5)
             |> Enum.filter(&(get_in(&1, ["entries", Access.at(0), "memory_ref"]) == fact.ref))

    assert {:ok, _resolved} =
             Memories.resolve_review(
               review["review_ref"],
               :forget,
               "slack:user:U123",
               fact.workspace_ref
             )

    assert Repo.get!(MemoryEntry, fact.id).status == :deleted
    assert Repo.get!(ConversationKnowledge, topic.id).forgotten_at
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
