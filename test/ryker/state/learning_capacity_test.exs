defmodule Ryker.State.LearningCapacityTest do
  use Ryker.DataCase, async: false
  import Ecto.Query

  alias Ryker.{CanonicalJSON, Episodes}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox.Entry

  alias Ryker.State.{
    ConversationKnowledge,
    ConversationObservation,
    Knowledge,
    KnowledgeRevision,
    KnowledgeSource,
    Learning,
    LearningRun,
    LearningSources,
    Observations
  }

  @policy %{policy: "recorded-read-only-policy", policy_digest: String.duplicate("a", 64)}
  @fixture "testdata/learning/retained-draft-ai-suggestions-learning.json"

  test "the 129th root leaves the existing topic available for an explicit update" do
    # The replay rebased saturated topics from one new message, losing the
    # accumulated understanding. A source ceiling must not masquerade as novelty.
    %{entry: entry, head: head} = saturated_topic!()
    assert {:ok, run} = Learning.prepare([entry.id], @policy)
    assert [offered] = run.knowledge
    assert offered["source_ref"] == "knowledge:#{head.id}"
    assert offered["version"] == head.version
    assert run.omissions == []
  end

  test "a topic above the old ceiling updates in place with complete immutable source history" do
    # The real backfill reached 114 inherited receipts on a brand-new topic.
    # Learning must preserve history at the 129th-root boundary, not get stuck
    # retrying or retain old prose without the roots disclosed with that prose.
    %{entry: entry, head: before, candidate: candidate} = saturated_topic!()
    history = Knowledge.history("knowledge:#{before.id}")
    old_sources = source_rows(before)

    assert {:ok, run} = Learning.prepare([entry.id], @policy)
    assert [offered] = run.knowledge
    assert run.omissions == []
    assert Repo.get!(LearningRun, run.id).omissions == run.omissions
    assert length(LearningSources.expand(run.source_dependencies)) == 129

    prompt = Jason.decode!(run.prompt)
    assert prompt["knowledge"] == [offered]
    assert [input] = prompt["inputs"]
    assert input["source_input_id"] == entry.id
    assert input["content"] == entry.content
    assert run.prompt =~ before.state["summary"]
    assert {:ok, ^run} = Learning.authorize(run.id)

    # Host-contract adaptation: unchanged harvested prose, now explicitly
    # targeting the offered version. This is not labelled a fresh model capture.
    document = Jason.decode!(candidate)

    update =
      hd(document["updates"])
      |> Map.put("target_ref", offered["source_ref"])
      |> Map.put("action", "update")
      |> Map.put("expected_version", offered["version"])

    candidate = Jason.encode!(%{document | "updates" => [update]})

    assert {:ok, %{status: :applied} = applied} =
             Ryker.Fixtures.Learning.accept(run.id, candidate, %{})

    assert applied.result == candidate
    assert applied.prompt == run.prompt
    assert applied.omissions == run.omissions

    after_update = Repo.get!(ConversationKnowledge, before.id)
    assert after_update.id == before.id
    assert after_update.topic_key == before.topic_key
    assert after_update.version == before.version + 1
    assert after_update.source_generation == before.source_generation

    assert LearningSources.expand(after_update.source_dependencies) ==
             LearningSources.expand(run.source_dependencies)

    assert after_update.source_input_id == entry.id
    assert after_update.state == candidate_state(candidate)
    assert length(source_rows(before)) == length(old_sources) + 1
    assert Enum.all?(old_sources, &(&1 in source_rows(before)))

    assert [old, latest] = Knowledge.history("knowledge:#{before.id}")
    assert [old] == history
    assert length(old.source_dependencies) == 1
    assert length(latest.source_dependencies) == 1
    assert length(LearningSources.expand(old.source_dependencies)) == 128
    assert length(LearningSources.expand(latest.source_dependencies)) == 129
    assert latest.source_generation == after_update.source_generation

    assert latest.source_result_ref ==
             "learning:#{run.id}:#{CanonicalJSON.digest(candidate)}"

    assert [visible] = Knowledge.context(entry, entry.repository_ref)
    assert visible["source_ref"] == "knowledge:#{before.id}"
    assert visible["version"] == after_update.version
    assert visible["source_count"] == 2
  end

  # Capacity proof, not a per-commit check: sixteen seconds of the serial suite.
  @tag :slow
  @tag timeout: 240_000
  test "ten thousand revisions keep linear memberships and the next root is explicitly omitted" do
    # Structural scale qualification, not 10,000 invented model judgments. Seed
    # compact historical revisions with unchanged harvested prose, then execute
    # the real next update at the supported source boundary.
    stale_memory_statistics!()
    %{entry: entry, head: head, candidate: candidate} = saturated_topic!()

    old_revision = Repo.get_by!(KnowledgeRevision, knowledge_id: head.id, version: 1)
    original = Repo.get!(Ryker.State.ConversationObservation, head.source_input_id)
    [receipt] = LearningSources.for_source(original)
    {:ok, retained_at, 0} = DateTime.from_iso8601(receipt["retained_at"])

    pairs =
      for version <- 129..9999 do
        id = Ecto.UUID.generate()
        root = %{receipt | "observation_id" => id, "source_input_id" => id}

        source =
          original
          |> Map.from_struct()
          |> Map.take(ConversationObservation.__schema__(:fields))
          |> Map.merge(%{
            id: id,
            identity_key: CanonicalJSON.digest(id),
            source_input_id: id,
            source_dependencies: [root],
            note: nil
          })

        membership = %{
          knowledge_id: head.id,
          generation: head.source_generation,
          observation_id: id,
          receipt: root,
          receipt_fingerprint: CanonicalJSON.digest(root),
          source_revision: root["revision"],
          source_fingerprint: root["fingerprint"],
          retained_at: retained_at,
          introduced_version: version
        }

        {source, membership}
      end

    for {schema, index} <- [{Ryker.State.ConversationObservation, 0}, {KnowledgeSource, 1}] do
      pairs
      |> Enum.map(&elem(&1, index))
      |> Enum.chunk_every(500)
      |> Enum.each(&Repo.insert_all(schema, &1))
    end

    reference = &LearningSources.knowledge_reference(head.id, head.source_generation, &1)

    for version <- 2..9999 do
      old_revision
      |> Map.from_struct()
      |> Map.take(KnowledgeRevision.__schema__(:fields))
      |> Map.merge(%{version: version, source_dependencies: [reference.(version)]})
    end
    |> Enum.chunk_every(500)
    |> Enum.each(&Repo.insert_all(KnowledgeRevision, &1))

    Repo.update!(
      Ecto.Changeset.change(head, version: 9999, source_dependencies: [reference.(9999)])
    )

    # The full strict gate also exhausted the 15-second learning transaction in
    # the post-lock validity check, even after the direct-source join was fixed.
    # Bound both query plans under the observed stale statistics, not just the
    # first join. Do not make a quadratic validator pass with a longer timeout.
    validity_query =
      Repo.to_sql(:all, from(k in Knowledge.valid_query(), where: k.id == ^head.id, select: k.id))

    assert_bounded_source_scan(validity_query, 10_000)

    post_lock_query =
      Repo.to_sql(
        :all,
        from(k in Knowledge.valid_query(), where: k.id in ^[head.id], select: k.id)
      )

    assert_bounded_source_scan(post_lock_query, 10_000)

    {prepared, sources_query} =
      capture_source_query(fn -> Learning.prepare([entry.id], @policy) end)

    assert {:ok, run} = prepared
    assert [%{"version" => 9999} = offered] = run.knowledge
    assert length(LearningSources.expand(run.source_dependencies)) == 10_000
    assert_bounded_source_scan(sources_query, 10_000)
    document = Jason.decode!(candidate)

    update =
      hd(document["updates"])
      |> Map.merge(%{
        "action" => "update",
        "target_ref" => offered["source_ref"],
        "expected_version" => 9999
      })

    assert {:ok, %{status: :applied}} =
             Ryker.Fixtures.Learning.accept(
               run.id,
               Jason.encode!(%{document | "updates" => [update]}),
               %{}
             )

    assert %{version: 10_000} = Repo.get!(ConversationKnowledge, head.id)
    assert Repo.aggregate(KnowledgeSource, :count) == 10_000
    assert Repo.aggregate(KnowledgeRevision, :count) == 10_000
    assert Repo.get_by!(KnowledgeRevision, knowledge_id: head.id, version: 1) == old_revision
    latest = Repo.get_by!(KnowledgeRevision, knowledge_id: head.id, version: 10_000)
    assert [reference.(10_000)] == latest.source_dependencies
    assert length(LearningSources.expand(latest.source_dependencies)) == 10_000
    assert length(LearningSources.expand(old_revision.source_dependencies)) == 128

    overflow = historical_source!(entry, 10_000)
    overflow_roots = LearningSources.for_entry(overflow)
    assert length(overflow_roots) == 1
    assert LearningSources.merge([latest.source_dependencies, overflow_roots]) == nil
    assert LearningSources.expand(latest.source_dependencies ++ overflow_roots) == nil

    assert {:ok, omitted} = Learning.prepare([overflow.id], @policy)
    assert omitted.knowledge == []
    assert [%{"source_ref" => ref, "reason" => "source_capacity"}] = omitted.omissions
    assert ref == "knowledge:#{head.id}"
    assert Repo.aggregate(KnowledgeSource, :count) == 10_000
    assert Repo.get!(ConversationKnowledge, head.id).version == 10_000
  end

  for field <- ~w(source_ref version topic_key conversation_ref repository_ref reason) do
    test "a capacity omission with a different #{field} cannot replace a visible topic" do
      %{entry: entry, head: before, candidate: candidate} = saturated_topic!()
      assert {:ok, run} = Learning.prepare([entry.id], @policy)
      receipt = omission(before)

      forged =
        Map.update!(receipt, unquote(field), fn
          version when is_integer(version) -> version + 1
          value -> value <> "-different"
        end)

      Repo.update!(Ecto.Changeset.change(run, omissions: [forged]))
      assert_rejected_without_replacing!(run, candidate, before)
    end
  end

  test "a missing capacity omission cannot replace an existing visible topic" do
    %{entry: entry, head: before, candidate: candidate} = saturated_topic!()
    assert {:ok, run} = Learning.prepare([entry.id], @policy)
    Repo.update!(Ecto.Changeset.change(run, omissions: []))
    assert_rejected_without_replacing!(run, candidate, before)
  end

  defp assert_rejected_without_replacing!(run, candidate, head) do
    history = Knowledge.history("knowledge:#{head.id}")
    sources = source_rows(head)

    assert {:error, :learning_match_required} =
             Ryker.Fixtures.Learning.accept(run.id, candidate, %{})

    assert Repo.get!(ConversationKnowledge, head.id) == head
    assert Knowledge.history("knowledge:#{head.id}") == history
    assert source_rows(head) == sources
    assert Repo.aggregate(KnowledgeRevision, :count) == length(history)

    saved = Repo.get!(LearningRun, run.id)
    assert saved.status == :rejected
    assert saved.result == candidate
    assert saved.prompt == run.prompt
  end

  defp saturated_topic! do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    candidate = fixture["result"]
    assert CanonicalJSON.digest(candidate) == fixture["provenance"]["result_sha256"]
    # Adapt only the new host contract fields; keep the recorded file and prose unchanged.
    candidate =
      candidate
      |> Jason.decode!()
      |> Map.update!("updates", fn updates ->
        Enum.map(updates, &Map.merge(&1, %{"action" => "create", "anchors" => []}))
      end)
      |> Jason.encode!()

    entry = persist_input!(fixture["input"])

    # Only these old source identities/receipts are deterministic capacity setup.
    # Their content is copied unchanged from the harvested input. The seed topic
    # is a host fixture, not a claimed model judgment over 128 real messages.
    historical = Enum.map(1..128, &historical_source!(entry, &1))
    dependencies = historical |> Enum.map(&LearningSources.for_entry/1) |> LearningSources.merge()
    assert length(dependencies) == 128
    assert length(LearningSources.merge([dependencies, LearningSources.for_entry(entry)])) == 129

    [proposal] = Jason.decode!(candidate)["updates"]
    assert proposal["target_ref"] == nil
    assert proposal["expected_version"] == 0
    assert proposal["source_input_ids"] == [entry.id]

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Knowledge.record_sources_in_transaction(
                 [hd(historical)],
                 Map.drop(proposal, ~w(action source_input_ids)),
                 [],
                 %{
                   result_ref: "host-capacity-fixture",
                   source_dependencies: dependencies,
                   omissions: []
                 }
               )
             end)

    head = Repo.get_by!(ConversationKnowledge, topic_key: proposal["topic_key"])
    assert LearningSources.expand(head.source_dependencies) == dependencies
    assert [%{"version" => 1}] = Knowledge.context(entry, entry.repository_ref)
    %{entry: entry, head: head, candidate: candidate}
  end

  defp persist_input!(raw) do
    at = raw["occurred_at"] |> NaiveDateTime.from_iso8601!() |> DateTime.from_naive!("Etc/UTC")

    assert {:ok, %{episode: episode}} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: raw["id"],
                 episode_key: "ingress-input:#{raw["id"]}",
                 native_input_id: raw["native_input_id"],
                 revision: raw["revision"],
                 occurred_at: at,
                 turn_ref: "ingress-turn:#{raw["id"]}",
                 payload: raw["content"],
                 destination: %{
                   transport: raw["destination_transport"],
                   conversation_ref: raw["destination_conversation_ref"],
                   thread_ref: raw["destination_thread_ref"]
                 }
               })
             )

    fields =
      ~w(id dedupe_key event_ref event_fingerprint source_kind source_ref native_input_id source_item_ref actor_ref revision content source_capabilities destination_transport destination_conversation_ref destination_thread_ref repository_ref work_policy work_policy_digest decision_ref decision_fingerprint decision_document status event_kind actor_kind occurred_at_source execution_mode decision_action)a

    attrs = Map.new(fields, &{&1, raw[Atom.to_string(&1)]})

    attrs =
      Enum.reduce(
        ~w(status event_kind actor_kind occurred_at_source execution_mode decision_action)a,
        attrs,
        &Map.update!(&2, &1, fn value -> String.to_existing_atom(value) end)
      )

    entry =
      Repo.insert!(
        struct!(
          Entry,
          Map.merge(attrs, %{
            occurred_at: at,
            episode_id: episode.id
          })
        )
      )

    assert {:ok, :ok} = Repo.transaction(fn -> Observations.receive_in_transaction(entry) end)
    entry
  end

  defp historical_source!(entry, n) do
    identity = "host-capacity-#{n}"

    attrs =
      entry
      |> Map.from_struct()
      |> Map.take(Entry.__schema__(:fields))
      |> Map.merge(%{
        id: "00000000-0000-4000-8000-#{String.pad_leading(to_string(n), 12, "0")}",
        dedupe_key: identity,
        native_input_id: identity,
        source_item_ref: identity,
        event_ref: identity,
        decision_ref: "host-capacity-decision:#{n}",
        event_fingerprint: CanonicalJSON.digest(%{"fixture_identity" => identity}),
        occurred_at: DateTime.add(entry.occurred_at, -n, :second)
      })

    historical = Repo.insert!(struct!(Entry, attrs))

    assert {:ok, :ok} =
             Repo.transaction(fn -> Observations.receive_in_transaction(historical) end)

    historical
  end

  defp omission(head) do
    %{
      "source_ref" => "knowledge:#{head.id}",
      "version" => head.version,
      "topic_key" => head.topic_key,
      "conversation_ref" => head.conversation_ref,
      "repository_ref" => head.repository_ref,
      "reason" => "source_capacity"
    }
  end

  defp source_rows(head) do
    Repo.all(
      from(s in KnowledgeSource,
        where: s.knowledge_id == ^head.id and s.generation == ^head.source_generation,
        order_by: [asc: s.observation_id]
      )
    )
  end

  defp candidate_state(candidate),
    do:
      candidate
      |> Jason.decode!()
      |> Map.fetch!("updates")
      |> hd()
      |> Map.take(~w(title summary topics anchors))

  defp assert_bounded_source_scan({query, params}, root_count) do
    %{rows: [[[%{"Plan" => plan}]]]} =
      Repo.query!("EXPLAIN (ANALYZE, FORMAT JSON) " <> query, params)

    visited = source_query_work(plan)

    assert visited <= root_count * 10,
           "source retrieval performed #{visited} scan/recheck operations for #{root_count} roots; expected bounded linear work"
  end

  defp source_query_work(%{"Plans" => plans} = plan),
    do:
      Enum.sum(Enum.map(plans, &source_query_work/1)) +
        Map.get(plan, "Rows Removed by Join Filter", 0) * plan["Actual Loops"] +
        materialized_work(plan)

  defp source_query_work(%{"Node Type" => type} = plan)
       when type in ["Index Scan", "Index Only Scan", "Bitmap Index Scan", "Seq Scan"] do
    (plan["Actual Rows"] + Map.get(plan, "Rows Removed by Filter", 0)) * plan["Actual Loops"]
  end

  defp source_query_work(_plan), do: 0

  defp materialized_work(%{"Node Type" => "Materialize"} = plan),
    do: plan["Actual Rows"] * plan["Actual Loops"]

  defp materialized_work(_), do: 0

  def record_source_query(_event, _measurements, metadata, owner) do
    if self() == owner and
         String.starts_with?(metadata.query, "SELECT c0.\"knowledge_id\", c2.\"id\"") do
      Process.put(:knowledge_sources_query, {metadata.query, metadata.params})
    end
  end

  defp capture_source_query(fun) do
    handler = "knowledge-scan-work:#{Ecto.UUID.generate()}"

    :ok =
      :telemetry.attach(
        handler,
        [:ryker, :repo, :query],
        &__MODULE__.record_source_query/4,
        self()
      )

    try do
      result = fun.()
      {result, Process.get(:knowledge_sources_query)}
    after
      :telemetry.detach(handler)
      Process.delete(:knowledge_sources_query)
    end
  end

  defp stale_memory_statistics! do
    # The full gate left an empty 3,485-page observation heap. Its one-row
    # estimate made source joins revisit 100 million index entries for 10,000
    # roots, and learning exhausted its 15-second transaction deadline. Restore
    # all four observed relation statistics, not source/model prose or planner settings.
    # Fresh relations have unknown (-1) statistics, which choose different plans.
    # PostgreSQL 18 is pinned in compose.test.yml; Sandbox rollback undoes this.
    for {table, pages} <- [
          {"conversation_knowledge", 0},
          {"conversation_knowledge_revisions", 0},
          {"conversation_knowledge_sources", 0},
          {"conversation_observations", 3485}
        ] do
      assert %{rows: [[true]]} =
               Repo.query!(
                 """
                 SELECT pg_catalog.pg_restore_relation_stats(
                   'version', current_setting('server_version_num')::integer,
                   'schemaname', 'public', 'relname', $1::text,
                   'relpages', $2::integer, 'reltuples', 0::real,
                   'relallvisible', 0::integer, 'relallfrozen', 0::integer)
                 """,
                 [table, pages]
               )
    end
  end
end
