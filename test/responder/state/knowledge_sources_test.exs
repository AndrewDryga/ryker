defmodule Responder.State.KnowledgeSourcesTest do
  use Responder.DataCase, async: false
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Repo

  alias Responder.State.{
    ConversationKnowledge,
    ConversationObservation,
    Knowledge,
    KnowledgeRetention,
    KnowledgeRevision,
    KnowledgeSnapshot,
    KnowledgeSource,
    LearningSources,
    Observations
  }

  # 103 of the 1,034 retained replay inputs have no old observation note. Raw
  # learning must not require inventing a note or rewrite the original admission.
  test "raw learning includes inputs without old notes and records its own result reference" do
    entries = sources!()
    before = Repo.all(ConversationObservation)
    dependencies = entries |> Enum.map(&LearningSources.for_entry/1) |> LearningSources.merge()

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Knowledge.record_sources_in_transaction(entries, proposal(), [], %{
                 result_ref: "learning-result:host-contract-test",
                 source_dependencies: dependencies,
                 omissions: []
               })
             end)

    assert Repo.all(ConversationObservation) == before
    assert [item] = Knowledge.context(hd(entries), "blitz-infra")
    assert item["source_count"] == 2
    assert item["version"] == 1
    assert [revision] = Repo.all(KnowledgeRevision)
    assert revision.source_result_ref == "learning-result:host-contract-test"
    assert revision.source_dependencies == dependencies
    assert revision.source_input_id == List.last(entries).id
    assert :ok = KnowledgeSnapshot.reauthorize(hd(entries), "blitz-infra", [item])

    # Filling a derived observation later does not change the raw source.
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Observations.record_in_transaction(
                 hd(entries),
                 Map.take(proposal(), ~w(summary topics)),
                 "later-observation"
               )
             end)

    assert [^item] = Knowledge.context(hd(entries), "blitz-infra")
    assert :ok = KnowledgeSnapshot.reauthorize(hd(entries), "blitz-infra", [item])
  end

  test "raw learning cannot reduce disclosed lineage to the claimed supporting sources" do
    entries = sources!()

    assert {:ok, {:error, _}} =
             Repo.transaction(fn ->
               Knowledge.record_sources_in_transaction(entries, proposal(), [], %{
                 result_ref: "learning-result:missing-root",
                 source_dependencies: LearningSources.for_entry(hd(entries)),
                 omissions: []
               })
             end)

    assert Repo.aggregate(ConversationKnowledge, :count) == 0
  end

  test "raw learning carries every offered topic source even when creating a different topic" do
    entries = sources!()
    {old_source, offered} = Responder.Fixtures.Knowledge.learn!(hd(entries), "blitz-infra")
    raw = entries |> Enum.map(&LearningSources.for_entry/1) |> LearningSources.merge()

    assert {:ok, {:error, _}} =
             Repo.transaction(fn ->
               Knowledge.record_sources_in_transaction(entries, proposal(), [offered], %{
                 result_ref: "learning-result:omitted-offered-topic",
                 source_dependencies: raw,
                 omissions: []
               })
             end)

    assert Repo.aggregate(ConversationKnowledge, :count) == 1
    dependencies = LearningSources.merge([raw, LearningSources.document_sources(offered)])

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Knowledge.record_sources_in_transaction(entries, proposal(), [offered], %{
                 result_ref: "learning-result:complete-offered-topic",
                 source_dependencies: dependencies,
                 omissions: []
               })
             end)

    assert length(Knowledge.context(hd(entries), "blitz-infra")) == 2
    Responder.Fixtures.Knowledge.revoke!(old_source)
    assert Knowledge.context(hd(entries), "blitz-infra") == []
  end

  test "raw learning does not copy an old derived observation it never disclosed" do
    entries = sources!()
    {_old_source, offered} = Responder.Fixtures.Knowledge.learn!(hd(entries), "blitz-infra")
    older_at = DateTime.add(DateTime.utc_now(), -3601)

    older_roots =
      LearningSources.document_sources(offered)
      |> Enum.map(&Map.put(&1, "retained_at", DateTime.to_iso8601(older_at)))

    inherited = LearningSources.merge([LearningSources.for_entry(hd(entries)), older_roots])

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Observations.record_in_transaction(
                 hd(entries),
                 Map.take(offered, ~w(summary topics)),
                 "old-derived-note",
                 inherited
               )
             end)

    before = Repo.all(ConversationObservation)
    raw = entries |> Enum.map(&LearningSources.for_entry/1) |> LearningSources.merge()

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Knowledge.record_sources_in_transaction(entries, proposal(), [], %{
                 result_ref: "learning-result:raw-only",
                 source_dependencies: raw,
                 omissions: []
               })
             end)

    assert Repo.all(ConversationObservation) == before

    raw_item =
      Enum.find(Repo.all(ConversationKnowledge), &(&1.topic_key == proposal()["topic_key"]))

    copies = Repo.all(KnowledgeSource) |> Enum.filter(&(&1.knowledge_id == raw_item.id))
    assert Enum.all?(copies, &is_nil(&1.source_note))

    assert {:ok, _} =
             Repo.transaction(fn ->
               KnowledgeRetention.prune_in_transaction(3600)
             end)

    assert is_nil(Repo.get!(ConversationObservation, hd(entries).id).note)
    assert Repo.get!(ConversationKnowledge, raw_item.id).state["summary"] == proposal()["summary"]
  end

  test "pruned knowledge cannot reappear when source retention is extended" do
    entries = sources!()
    dependencies = entries |> Enum.map(&LearningSources.for_entry/1) |> LearningSources.merge()

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Knowledge.record_sources_in_transaction(entries, proposal(), [], %{
                 result_ref: "learning-result:pruning",
                 source_dependencies: dependencies,
                 omissions: []
               })
             end)

    [item] = Knowledge.context(hd(entries), "blitz-infra")
    Repo.update_all(ConversationKnowledge, set: [state: %{"retention" => "pruned"}])
    Repo.update_all(KnowledgeRevision, set: [state: %{"retention" => "pruned"}])
    assert Knowledge.context(hd(entries), "blitz-infra") == []

    assert {:error, :work_knowledge_context_stale} =
             KnowledgeSnapshot.reauthorize(hd(entries), "blitz-infra", [item])
  end

  test "an edit to a raw supporting input invalidates both recall and frozen Work" do
    entries = sources!()
    dependencies = entries |> Enum.map(&LearningSources.for_entry/1) |> LearningSources.merge()

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Knowledge.record_sources_in_transaction(entries, proposal(), [], %{
                 result_ref: "learning-result:before-edit",
                 source_dependencies: dependencies,
                 omissions: []
               })
             end)

    [item] = Knowledge.context(hd(entries), "blitz-infra")
    first = hd(entries)

    edited = %{
      first
      | id: Ecto.UUID.generate(),
        revision: first.revision + 1,
        event_kind: :edit,
        event_fingerprint: String.duplicate("c", 64)
    }

    assert {:ok, :ok} = Repo.transaction(fn -> Observations.receive_in_transaction(edited) end)
    assert Knowledge.context(List.last(entries), "blitz-infra") == []

    assert {:error, :work_knowledge_context_stale} =
             KnowledgeSnapshot.reauthorize(List.last(entries), "blitz-infra", [item])
  end

  defp sources! do
    path = Path.expand("../../../testdata/learning/retained-haproxy-lifecycle.json", __DIR__)
    inputs = path |> File.read!() |> Jason.decode!() |> Map.fetch!("inputs")

    Enum.map(inputs, fn raw ->
      # The harvested PostgreSQL utc_datetime_usec column has no textual offset.
      at = raw["occurred_at"] |> NaiveDateTime.from_iso8601!() |> DateTime.from_naive!("Etc/UTC")

      entry =
        struct!(Entry, %{
          id: raw["source_input_id"],
          status: :decided,
          source_kind: raw["source_kind"],
          source_ref: raw["source_ref"],
          native_input_id: raw["native_input_id"],
          source_item_ref: raw["source_item_ref"],
          event_fingerprint: raw["event_fingerprint"],
          revision: raw["revision"],
          event_kind: :message,
          actor_kind: :bot,
          actor_ref: raw["actor_ref"],
          occurred_at: at,
          content: raw["content"],
          execution_mode: :shadow,
          destination_transport: raw["destination_transport"],
          destination_conversation_ref: raw["destination_conversation_ref"],
          destination_thread_ref: raw["destination_thread_ref"],
          repository_ref: raw["repository_ref"],
          dedupe_key: raw["source_input_id"],
          source_capabilities: %{}
        })

      # Source custody only; no admission, model, work, or publisher runs in this test.
      assert {:ok, :ok} = Repo.transaction(fn -> Observations.receive_in_transaction(entry) end)
      entry
    end)
  end

  defp proposal do
    %{
      "topic_key" => "website-haproxy-edge-oom",
      "title" => "Website HAProxy memory limit",
      "summary" =>
        "Grafana reported the website/haproxy-edge OOM warning resolved. CONSTRAINT_MEMCG describes a workload memory-limit breach, not host RAM exhaustion. Application recovery remains unverified.",
      "topics" => ["website", "haproxy-edge", "OOM"],
      "target_ref" => nil,
      "expected_version" => 0
    }
  end
end
