defmodule Responder.State.LearningThreadContextTest do
  use Responder.DataCase, async: false

  alias Responder.CanonicalJSON
  alias Responder.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Responder.Fixtures.Learning, as: Fixtures
  alias Responder.Ingress.Inbox.Entry
  alias Responder.State.{Knowledge, KnowledgeAnchors, Learning, Observations}

  @policy %{policy: "recorded-read-only-policy", policy_digest: String.duplicate("a", 64)}

  for root_without_thread <- [false, true] do
    test "an elliptical reply receives its existing topic with root thread missing: #{root_without_thread}" do
      # Real draft_c replay froze knowledge=[] for 'I think Apinat set it up...'
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
      assert length(Knowledge.history(topic["source_ref"])) == 2
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

  test "thread matching cannot cross a conversation or repository or revive a withdrawn source" do
    # Structural boundary variants of the captured thread, not new model answers.
    {first, second, topic} = learned_thread!(false)
    selector = {:threads, [second.destination_thread_ref]}
    assert [^topic] = Knowledge.context(second, second.repository_ref, selector, 8, "writable")

    other_channel = %{second | destination_conversation_ref: "slack:T01J1LW4DF1:C-not-the-source"}
    assert Knowledge.context(other_channel, second.repository_ref, selector, 8, "writable") == []
    assert Knowledge.context(second, "another-repository", selector, 8, "writable") == []

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

  defp recorded_proposal do
    "testdata/learning/recorded-draft-retention-create.json"
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["result", "updates"])
    |> hd()
  end
end
