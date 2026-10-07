defmodule Ryker.Learning.LearningThreadContextTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  alias Ryker.CanonicalJSON
  alias Ryker.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Ryker.Fixtures.Learning, as: Fixtures
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Inspectors
  alias Ryker.Knowledge
  alias Ryker.Knowledge.{ConversationKnowledge, KnowledgeAnchors, KnowledgeSource}
  alias Ryker.Learning
  alias Ryker.Learning.{ConversationObservation, LearningRun, LearningSources, Observations}
  alias Ryker.Memories.Forgetting

  @policy %{policy: "recorded-read-only-policy", policy_digest: String.duplicate("a", 64)}

  for root_without_thread <- [false, true] do
    test "an elliptical reply receives its existing topic with root thread missing: #{root_without_thread}" do
      # Real draft_c replay froze knowledge=[] for 'I think Dana set it up...'
      # despite a maintained topic from the same thread. The model deferred;
      # lexical retrieval cannot recover an identity omitted by the host.
      {_first, second, expected} = learned_thread!(unquote(root_without_thread))
      search = KnowledgeAnchors.source_texts([second])

      assert Knowledge.context(second, second.repository_ref, {:related, search}, 8, "writable") ==
               []

      assert {:ok, run} = Learning.prepare([second.id], @policy)
      assert [topic] = Jason.decode!(run.prompt)["knowledge"]
      assert topic["source_ref"] == expected["source_ref"]
      assert topic["version"] == expected["version"]
      assert topic["can_update"]
      assert {:ok, ^run} = Learning.authorize(run.id)

      # A host-contract projection of the captured create, not a new recorded
      # model judgment: the offered reference/version must actually be writable.
      update =
        recorded_proposal()
        |> Map.merge(%{
          "action" => "update",
          "target_ref" => topic["source_ref"],
          "expected_version" => topic["version"],
          "source_input_ids" => [second.id]
        })

      result = Jason.encode!(%{"updates" => [update], "reason" => "Exercise the offered update."})
      assert {:ok, %{status: :applied}} = Fixtures.accept(run.id, result, %{})
      assert length(Inspectors.knowledge_history(topic["source_ref"])) == 2
    end
  end

  test "eight retry topic keys cannot hide an existing same-thread topic" do
    # The draft_c learner lost its reply target once already. On retry, eight
    # named subjects must not crowd that target out again. Cardinality setup
    # repeats retained source prose; it does not invent captured model judgments.
    {first, second, topic} = learned_thread!(false)
    unrelated = clone_source!(first, "structural-unrelated-thread", first.occurred_at)
    priorities = seed_topics!(unrelated, 8)
    assert {:ok, initial} = Learning.prepare([second.id], @policy)
    assert topic["source_ref"] in Enum.map(initial.knowledge, & &1["source_ref"])

    updates =
      Enum.map(priorities, fn priority ->
        recorded_proposal()
        |> Map.merge(%{
          "action" => "update",
          "topic_key" => priority["topic_key"],
          "target_ref" => priority["source_ref"],
          "expected_version" => priority["version"],
          "source_input_ids" => [second.id],
          "anchors" => ["structural-unsourced-anchor"]
        })
      end)

    result =
      Jason.encode!(%{"updates" => updates, "reason" => "Host-contract invalid-anchor retry."})

    assert {:error, :knowledge_anchor_not_sourced} = Fixtures.accept(initial.id, result, %{})
    assert {:ok, retried} = Learning.prepare([second.id], @policy)
    assert retried.generation == initial.generation + 1
    assert length(retried.knowledge) == 8
    assert topic["source_ref"] in Enum.map(retried.knowledge, & &1["source_ref"])
  end

  test "a busy thread cannot consume every candidate slot in a multi-thread batch" do
    # Structural multiplicity over retained messages: nine newer heads from one
    # thread previously hid the only head for another input in the same batch.
    {first, second, topic} = learned_thread!(false)

    busy =
      clone_source!(
        first,
        "structural-busy-thread",
        DateTime.add(second.occurred_at, 60, :second)
      )

    seed_topics!(busy, 9)

    candidates =
      Knowledge.context(
        second,
        second.repository_ref,
        {:threads, [busy.destination_thread_ref, second.destination_thread_ref]},
        8,
        "writable"
      )

    assert length(candidates) == 8
    assert topic["source_ref"] in Enum.map(candidates, & &1["source_ref"])
    assert {:ok, run} = Learning.prepare([busy.id, second.id], @policy)
    assert length(run.knowledge) == 8
    assert topic["source_ref"] in Enum.map(run.knowledge, & &1["source_ref"])
  end

  test "thread matching cannot cross a conversation or revive a withdrawn source" do
    # Structural boundary variants of the captured thread, not new model answers.
    {first, second, topic} = learned_thread!(false)
    selector = {:threads, [second.destination_thread_ref]}
    assert [^topic] = Knowledge.context(second, second.repository_ref, selector, 8, "writable")

    other_channel = %{second | destination_conversation_ref: "slack:T0TENANT001:C-not-the-source"}
    assert Knowledge.context(other_channel, second.repository_ref, selector, 8, "writable") == []

    # The conversation's own topic stays its own when its work moves to another
    # repository (V10, 2026-09-28); only the repository it names differs.
    assert [moved] = Knowledge.context(second, "another-repository", selector, 8, "writable")
    assert moved["source_ref"] == topic["source_ref"] and moved["can_update"]

    assert Knowledge.context(
             second,
             second.repository_ref,
             {:threads, ["another-thread"]},
             8,
             "writable"
           ) == []

    KnowledgeFixtures.revoke!(first)
    assert Knowledge.context(second, second.repository_ref, selector, 8, "writable") == []
  end

  # 2026-09-30, the recorded starfall-correction case: "Nothing is stuck, this
  # is done manually. Just woke up" replies in a thread whose release notice
  # and "It looks like this got stuck" had taught nothing on their own.
  # Learning saw only the reply, deferred it because it "does not identify the
  # process", and that Starfall releases are done by hand was never kept.
  test "a reply is read beside the thread it answers, and what is learned rests on that thread" do
    [notice, worry, correction] = starfall_thread!()

    assert {:ok, run} = Learning.prepare([correction.id], @policy)
    prompt = Jason.decode!(run.prompt)

    assert Enum.map(prompt["thread_context"], & &1["source_input_id"]) == [notice.id, worry.id]
    assert Enum.at(prompt["thread_context"], 1)["text"] =~ "It looks like this got stuck"
    assert prompt["instructions"] =~ "thread_context holds earlier messages of the thread"
    assert Enum.map(prompt["inputs"], & &1["source_input_id"]) == [correction.id]
    assert Enum.map(run.context_inputs, & &1["source_input_id"]) == [notice.id, worry.id]

    # The thread can be named as a source; only the reply's own author can
    # tell learning about themselves.
    named = get_in(run.output_schema, ["properties", "updates", "items", "oneOf"])
    assert Enum.all?(named, &(worry.id in &1["properties"]["source_input_ids"]["items"]["enum"]))
    assert {:ok, ^run} = Learning.authorize(run.id)

    # A host-contract projection of a recorded create, citing the reply and
    # the worry it answers, not a new model judgment.
    create =
      recorded_proposal()
      |> Map.merge(%{
        "topic_key" => "starfall-release-process",
        "anchors" => [],
        "source_input_ids" => [correction.id, worry.id]
      })

    result = Jason.encode!(%{"updates" => [create], "reason" => "Keep the release process."})
    assert {:ok, %{status: :applied}} = Fixtures.accept(run.id, result, %{})
    assert [topic] = Knowledge.context(correction, correction.repository_ref)
    %{id: topic_id} = Repo.get_by!(ConversationKnowledge, topic_key: "starfall-release-process")

    # Every thread message read beside the reply is a source, named or not.
    sourced =
      from(source in KnowledgeSource, where: source.knowledge_id == ^topic_id)
      |> Repo.all()
      |> Enum.map(& &1.receipt["source_input_id"])

    assert Enum.sort(sourced) == Enum.sort([notice.id, worry.id, correction.id])
    assert topic["source_ref"]

    # So forgetting what was learned forgets the whole thread it came from,
    # and none of it is learned from again.
    assert {:ok, %{forgotten: [^topic_id | _]}} = Forgetting.forget_topic(topic_id)

    for entry <- [notice, worry, correction],
        do: assert(LearningSources.for_entry(entry) == nil)
  end

  # The context is the thread's opening message and its latest replies, but
  # the query took the latest messages only, so a thread with more than five
  # earlier replies lost the message the replies were about (2026-10-04
  # review).
  # A run's prompt quotes the thread around its messages too. Retention erased
  # a run whose own messages had gone, and kept one whose thread had
  # (2026-10-04 review).
  test "a run whose thread has left the retention window keeps none of its words" do
    [notice, worry, correction] = starfall_thread!()
    assert {:ok, run} = Learning.prepare([correction.id], @policy)

    Repo.update_all(
      from(entry in Entry, where: entry.id == ^notice.id),
      set: [operational_pruned_at: DateTime.utc_now()]
    )

    assert {:ok, 1} = Repo.transaction(fn -> Learning.prune_in_transaction(86_400 * 365) end)

    erased = Repo.get!(LearningRun, run.id)
    assert erased.prompt == nil
    assert erased.pruned_at
    assert worry.id in Enum.map(run.context_inputs, & &1["source_input_id"])
  end

  test "a long thread is read with its opening message and its latest replies" do
    [notice, worry, correction] = starfall_thread!()

    replies =
      for minute <- 1..8 do
        clone_source!(
          worry,
          worry.destination_thread_ref,
          DateTime.add(worry.occurred_at, minute, :second)
        )
      end

    assert {:ok, run} = Learning.prepare([correction.id], @policy)
    context = Enum.map(Jason.decode!(run.prompt)["thread_context"], & &1["source_input_id"])

    assert context == [notice.id | Enum.map(Enum.take(replies, -5), & &1.id)]
  end

  test "a run whose thread changed before its result is applied is not applied" do
    [_notice, worry, correction] = starfall_thread!()
    assert {:ok, run} = Learning.prepare([correction.id], @policy)

    # The worry is forgotten while the model is still answering.
    Repo.update_all(
      from(o in ConversationObservation, where: o.source_input_id == ^worry.id),
      set: [forgotten_at: Repo.now!()]
    )

    assert {:error, :learning_source_stale} = Learning.authorize(run.id)
  end

  test "a message outside any thread is prepared as it always was" do
    {first, _second, _topic} = learned_thread!(true)
    alone = clone_source!(first, nil, DateTime.add(first.occurred_at, 60))
    assert {:ok, run} = Learning.prepare([alone.id], @policy)
    prompt = Jason.decode!(run.prompt)

    refute Map.has_key?(prompt, "thread_context")
    refute prompt["instructions"] =~ "thread_context"
    assert run.context_inputs == []
  end

  defp learned_thread!(root_without_thread) do
    [first, second | _] =
      "testdata/learning/retained-draft-keep-thread.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("inputs")

    # Some source adapters represent the root itself without thread_ref;
    # source_item_ref is still the authoritative parent identity of its replies.
    first = if root_without_thread, do: Map.put(first, "destination_thread_ref", nil), else: first
    first = Fixtures.retained_input!(first, @policy)
    assert {:ok, run} = Learning.prepare([first.id], @policy)

    result =
      "testdata/learning/recorded-draft-retention-create.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("result")
      |> Jason.encode!()

    assert {:ok, %{status: :applied}} = Fixtures.accept(run.id, result, %{})
    second = Fixtures.retained_input!(second, @policy)
    assert [topic] = Knowledge.context(second, second.repository_ref)
    {first, second, topic}
  end

  defp seed_topics!(source, count) do
    Enum.map(1..count, fn number ->
      key = "structural-cardinality-topic-#{number}"

      proposal =
        recorded_proposal()
        |> Map.drop(~w(action source_input_ids))
        |> Map.merge(%{"topic_key" => key, "anchors" => []})

      assert {:ok, :ok} =
               Repo.transaction(fn -> KnowledgeFixtures.record_topic(source, proposal, []) end)

      [topic] =
        Knowledge.context(source, source.repository_ref, {:topic_keys, [key]}, 1, "writable")

      topic
    end)
  end

  defp clone_source!(source, thread, occurred_at) do
    id = Ecto.UUID.generate()

    entry =
      source
      |> Map.from_struct()
      |> Map.take(Entry.__schema__(:fields))
      |> Map.merge(%{
        id: id,
        dedupe_key: id,
        native_input_id: id,
        source_item_ref: id,
        event_ref: "structural-source:#{id}",
        event_fingerprint:
          CanonicalJSON.digest(%{"source" => source.event_fingerprint, "id" => id}),
        decision_ref: "structural-decision:#{id}",
        destination_thread_ref: thread,
        occurred_at: occurred_at
      })
      |> then(&Repo.insert!(struct!(Entry, &1)))

    assert {:ok, :ok} = Repo.transaction(fn -> Observations.receive_in_transaction(entry) end)
    entry
  end

  # The recorded starfall thread: the release notice, the worry and the
  # correction, each observed as it was.
  defp starfall_thread! do
    "testdata/learning/retained-starfall-manual-correction.json"
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("inputs")
    |> Enum.map(&Fixtures.retained_input!(&1, @policy))
  end

  defp recorded_proposal do
    "testdata/learning/recorded-draft-retention-create.json"
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["result", "updates"])
    |> hd()
  end
end
