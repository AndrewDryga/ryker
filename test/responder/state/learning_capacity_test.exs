defmodule Responder.State.LearningCapacityTest do
  use Responder.DataCase, async: false
  import Ecto.Query

  alias Responder.{CanonicalJSON, Episodes}
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Ingress.Inbox.Entry

  alias Responder.State.{
    ConversationKnowledge,
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

  test "a saturated learning topic rebases only from disclosed raw input and preserves its history" do
    # The real backfill reached 114 inherited receipts on a brand-new topic.
    # Learning must preserve history at the 129th-root boundary, not get stuck
    # retrying or retain old prose without the roots disclosed with that prose.
    %{entry: entry, head: before, candidate: candidate} = saturated_topic!()
    history = Knowledge.history("knowledge:#{before.id}")
    old_sources = source_rows(before)

    assert {:ok, run} = Learning.prepare([entry.id], @policy)
    assert run.knowledge == []
    assert run.omissions == [omission(before)]
    assert Repo.get!(LearningRun, run.id).omissions == run.omissions
    assert run.source_dependencies == LearningSources.for_entry(entry)

    prompt = Jason.decode!(run.prompt)
    assert prompt["knowledge"] == []
    assert [input] = prompt["inputs"]
    assert input["source_input_id"] == entry.id
    assert input["content"] == entry.content
    refute run.prompt =~ before.state["summary"]
    assert {:ok, ^run} = Learning.authorize(run.id)

    assert {:ok, %{status: :applied} = applied} = Learning.accept(run.id, candidate, %{})
    assert applied.result == candidate
    assert applied.prompt == run.prompt
    assert applied.omissions == run.omissions

    after_update = Repo.get!(ConversationKnowledge, before.id)
    assert after_update.id == before.id
    assert after_update.topic_key == before.topic_key
    assert after_update.version == before.version + 1
    assert after_update.source_generation == before.source_generation + 1
    assert after_update.source_dependencies == run.source_dependencies
    assert after_update.source_input_id == entry.id
    assert after_update.state == candidate_state(candidate)
    assert source_rows(before) == old_sources

    assert [old, latest] = Knowledge.history("knowledge:#{before.id}")
    assert [old] == history
    assert length(old.source_dependencies) == 128
    assert latest.source_dependencies == run.source_dependencies
    assert latest.source_generation == after_update.source_generation

    assert latest.source_result_ref ==
             "learning:#{run.id}:#{CanonicalJSON.digest(candidate)}"

    assert [visible] = Knowledge.context(entry, entry.repository_ref)
    assert visible["source_ref"] == "knowledge:#{before.id}"
    assert visible["version"] == after_update.version
    assert visible["source_count"] == 1
  end

  for field <- ~w(source_ref version topic_key conversation_ref repository_ref reason) do
    test "a capacity omission with a different #{field} cannot replace a visible topic" do
      %{entry: entry, head: before, candidate: candidate} = saturated_topic!()
      assert {:ok, run} = Learning.prepare([entry.id], @policy)
      [receipt] = run.omissions

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
    assert {:error, :learning_context_stale} = Learning.accept(run.id, candidate, %{})
    assert Repo.get!(ConversationKnowledge, head.id) == head
    assert Knowledge.history("knowledge:#{head.id}") == history
    assert source_rows(head) == sources
    assert Repo.aggregate(KnowledgeRevision, :count) == length(history)

    saved = Repo.get!(LearningRun, run.id)
    assert saved.status == :stale
    assert saved.result == candidate
    assert saved.prompt == run.prompt
  end

  defp saturated_topic! do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    candidate = fixture["result"]
    assert CanonicalJSON.digest(candidate) == fixture["provenance"]["result_sha256"]
    entry = persist_input!(fixture["input"])

    # Only these old source identities/receipts are deterministic capacity setup.
    # Their content is copied unchanged from the harvested input. The seed topic
    # is a host fixture, not a claimed model judgment over 128 real messages.
    historical = Enum.map(1..128, &historical_source!(entry, &1))
    dependencies = historical |> Enum.map(&LearningSources.for_entry/1) |> LearningSources.merge()
    assert length(dependencies) == 128
    assert LearningSources.merge([dependencies, LearningSources.for_entry(entry)]) == nil

    [proposal] = Jason.decode!(candidate)["updates"]
    assert proposal["target_ref"] == nil
    assert proposal["expected_version"] == 0
    assert proposal["source_input_ids"] == [entry.id]

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Knowledge.record_sources_in_transaction(
                 [hd(historical)],
                 Map.delete(proposal, "source_input_ids"),
                 [],
                 %{
                   result_ref: "host-capacity-fixture",
                   source_dependencies: dependencies,
                   omissions: []
                 }
               )
             end)

    head = Repo.get_by!(ConversationKnowledge, topic_key: proposal["topic_key"])
    assert head.source_dependencies == dependencies
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
      |> Map.take(~w(title summary topics))
end
