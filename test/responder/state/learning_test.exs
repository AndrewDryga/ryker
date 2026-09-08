defmodule Responder.State.LearningTest do
  use Responder.DataCase, async: false
  alias Responder.CanonicalJSON
  alias Responder.Episodes.{Episode, Event}
  alias Responder.Fixtures.Learning, as: Fixtures
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Ingress.RecallText
  alias Responder.Repo
  alias Responder.Retention.Data
  alias Responder.Slack.ChannelMembership

  alias Responder.State.{
    ConversationObservation,
    Knowledge,
    KnowledgeRevision,
    Learning,
    LearningRun,
    LearningSources,
    Observations
  }

  alias Responder.Work.Turn

  @policy %{policy: "recorded-read-only-policy", policy_digest: String.duplicate("a", 64)}

  test "the frozen learning input preserves the original conversation and reply identities" do
    # Fortnite replay fortnite_b.json, run 380c7761-2ed8-4f66-a084-8d6519c96bef,
    # deferred the concern below because its prompt omitted the actual reply/thread
    # identity. The release topic was offered, but the host hid their relationship.
    raw =
      "testdata/learning/retained-fortnite-manual-correction.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("inputs")
      |> Enum.find(&(&1["id"] == "d60fa803-de87-49a4-9672-cd7561176f1d"))

    entry = Fixtures.retained_input!(raw, @policy)
    assert {:ok, run} = Learning.prepare([entry.id], @policy)
    assert [input] = Jason.decode!(run.prompt)["inputs"]

    assert input["destination"] == %{
             "transport" => raw["destination_transport"],
             "conversation_ref" => raw["destination_conversation_ref"],
             "thread_ref" => raw["destination_thread_ref"]
           }

    assert input["native_input_id"] == raw["native_input_id"]
    assert input["source_item_ref"] == raw["source_item_ref"]
    assert input["source_input_id"] == raw["id"]
    assert input["content"] == raw["content"]
    assert input["source"] == %{"kind" => raw["source_kind"], "ref" => raw["source_ref"]}
    assert input["actor"] == %{"kind" => raw["actor_kind"], "ref" => raw["actor_ref"]}
    assert input["revision"] == raw["revision"]
    assert input["occurred_at"] == DateTime.to_iso8601(entry.occurred_at)
    assert {:ok, ^run} = Learning.prepare([entry.id], @policy)
    assert {:ok, ^run} = Learning.authorize(run.id)
  end

  test "topic identity instructions permit current titles and distinguish colliding occurrence keys" do
    # Live consolidation kept a deletion-question title after an explicit keep
    # decision; create-check retries must also explain how distinct subjects can remain distinct.
    first = hd(Fixtures.inputs!())
    assert {:ok, run} = Learning.prepare([first.id], @policy)
    instructions = Jason.decode!(run.prompt)["instructions"]
    assert instructions =~ "The title may change to reflect the current state"
    assert instructions =~ "A create must use an unused topic_key"
    assert instructions =~ "Preserve who made material decisions or corrections"
    assert instructions =~ "An occurrence-specific topic must not absorb a different occurrence"
    assert instructions =~ "complete subject-identifying URLs or standalone identifier tokens"

    assert instructions =~
             "Never use actor, source, source_input_id, native_input_id, source_item_ref"

    assert instructions =~ "revision or occurred_at metadata as anchors"
    assert instructions =~ "Any unsourced anchor rejects the whole result"
  end

  # Replaying all 1,034 decided inputs must not reroute them or create another
  # delivery. The actual firing/resolved pair is harvested from the private replay.
  test "learning batches preserve source and execution history and reference their own saved result" do
    entries = Fixtures.inputs!()
    before = protected_rows()
    assert {:ok, run} = Learning.prepare(Enum.map(entries, & &1.id), @policy)
    assert run.status == :prepared
    prompt = Jason.decode!(run.prompt)
    assert Enum.map(prompt["inputs"], & &1["source_input_id"]) == Enum.map(entries, & &1.id)
    assert Enum.map(prompt["inputs"], & &1["content"]) == Enum.map(entries, & &1.content)
    assert prompt["knowledge"] == []
    assert {:ok, ^run} = Learning.authorize(run.id)
    candidate = result(entries)

    assert {:ok, applied} =
             Fixtures.accept(run.id, candidate, %{
               "model" => "host-contract-test-provider",
               "turn_id" => "host-contract-test-turn"
             })

    assert applied.status == :applied
    assert applied.result == candidate
    assert applied.prompt == run.prompt
    assert applied.result_sha256 == CanonicalJSON.digest(candidate)
    assert [revision] = Repo.all(KnowledgeRevision)
    assert revision.source_result_ref == "learning:#{run.id}:#{applied.result_sha256}"
    assert [item] = Knowledge.context(hd(entries), "blitz-infra")
    assert item["source_count"] == 2
    assert protected_rows() == before

    assert {:ok, ^applied} = Learning.prepare(Enum.reverse(Enum.map(entries, & &1.id)), @policy)

    assert {:ok, ^applied} =
             Fixtures.accept(run.id, candidate, applied.producer)

    assert Repo.aggregate(KnowledgeRevision, :count) == 1
    assert protected_rows() == before
  end

  test "no useful learning is a recorded outcome not a manufactured memory" do
    entries = Fixtures.inputs!()
    before = protected_rows()
    assert {:ok, run} = Learning.prepare(Enum.map(entries, & &1.id), @policy)
    candidate = Jason.encode!(%{"updates" => [], "reason" => "No new durable information."})
    assert {:ok, %{status: :applied}} = Fixtures.accept(run.id, candidate, %{})
    assert Repo.aggregate(KnowledgeRevision, :count) == 0
    assert protected_rows() == before
  end

  test "the batch identity includes the actual prompt contract not a fixed version label" do
    entries = Fixtures.inputs!()
    assert {:ok, run} = Learning.prepare(Enum.map(entries, & &1.id), @policy)

    old_key =
      CanonicalJSON.digest(%{
        "inputs" => run.inputs,
        "policy" => run.policy,
        "policy_digest" => run.policy_digest,
        "contract" => "conversation-learning-v1"
      })

    # Following a clean topic reset, old applied receipts must not suppress
    # relearning under the new schema. This is a host identity regression.
    refute run.batch_key == old_key
    prompt = Jason.decode!(run.prompt)

    assert run.batch_key ==
             CanonicalJSON.digest(%{
               "inputs" => run.inputs,
               "policy" => run.policy,
               "policy_digest" => run.policy_digest,
               "contract" =>
                 CanonicalJSON.digest(%{
                   "instructions" => prompt["instructions"],
                   "schema" => run.output_schema
                 })
             })
  end

  test "learning does not coalesce live and shadow inputs even in one conversation" do
    [first, second] = Fixtures.inputs!()
    Repo.update!(Ecto.Changeset.change(second, execution_mode: :live))
    assert {:error, :learning_source_stale} = Learning.prepare([first.id, second.id], @policy)
  end

  test "uncertain identity can be explicitly deferred without inventing or changing knowledge" do
    entries = Fixtures.inputs!()
    assert {:ok, run} = Learning.prepare(Enum.map(entries, & &1.id), @policy)

    document = %{
      "updates" => [
        %{
          "action" => "defer",
          "source_input_ids" => Enum.map(entries, & &1.id),
          "reason" => "The sources do not establish whether this is the same occurrence."
        }
      ],
      "reason" => "Keep the uncertainty for review."
    }

    assert {:ok, ^document} = JSV.validate(document, JSV.build!(run.output_schema), cast: false)
    candidate = Jason.encode!(document)
    assert {:ok, saved} = Fixtures.accept(run.id, candidate, %{})
    assert saved.result == candidate
    assert Repo.aggregate(KnowledgeRevision, :count) == 0
  end

  test "action and target must agree" do
    entries = Fixtures.inputs!()
    assert {:ok, run} = Learning.prepare(Enum.map(entries, & &1.id), @policy)
    document = Jason.decode!(result(entries))
    invalid = hd(document["updates"]) |> Map.put("action", "update")
    document = %{document | "updates" => [invalid]}
    assert {:error, _} = JSV.validate(document, JSV.build!(run.output_schema), cast: false)

    assert {:error, :invalid_learning_result} =
             Fixtures.accept(run.id, Jason.encode!(document), %{})

    assert Repo.aggregate(KnowledgeRevision, :count) == 0
  end

  test "exact source identities retrieve a renamed subject and unsupported anchors are rejected" do
    entries = Fixtures.inputs!()
    [first, second] = entries
    anchor = "311e38f3-a17c-7d1b-1235-05c256ba3c39"
    assert {:ok, run} = Learning.prepare([first.id], @policy)
    document = Jason.decode!(result([first]))
    proposal = hd(document["updates"]) |> Map.put("anchors", [anchor])

    assert {:ok, _} =
             Fixtures.accept(
               run.id,
               Jason.encode!(%{document | "updates" => [proposal]}),
               %{}
             )

    assert [topic] = Knowledge.context(first, first.repository_ref, {:anchors, [anchor]})
    assert topic["anchors"] == [anchor]
    assert Knowledge.context(first, first.repository_ref, {:anchors, ["unknown-identity"]}) == []

    assert {:ok, next} = Learning.prepare([second.id], @policy)

    update =
      proposal
      |> Map.merge(%{
        "action" => "update",
        "target_ref" => topic["source_ref"],
        "expected_version" => topic["version"],
        "source_input_ids" => [second.id],
        "anchors" => ["forged:unrelated-deployment"]
      })

    assert {:error, :knowledge_anchor_not_sourced} =
             Fixtures.accept(
               next.id,
               Jason.encode!(%{document | "updates" => [update]}),
               %{}
             )

    assert Repo.aggregate(KnowledgeRevision, :count) == 1

    # The live draft-keep replay spent repeated starts on the same unsupported
    # sender anchor: a fresh judgment was never told what the host rejected.
    assert {:ok, retry} = Learning.prepare([second.id], @policy)
    feedback = Jason.decode!(retry.prompt)["previous_attempt_error"]
    assert feedback["code"] == "knowledge_anchor_not_sourced"
    assert feedback["instruction"] =~ "message content"
    refute retry.prompt =~ "forged:unrelated-deployment"
  end

  test "an anchor beyond the recall excerpt remains valid in the full submitted message" do
    # Structural padding of the retained alert, not a captured model answer.
    # The model saw the whole input but host validation used only 512 characters.
    original = hd(Fixtures.inputs!())
    identity = Ecto.UUID.generate()

    content = %{
      "text" =>
        String.duplicate("header ", 100) <>
          RecallText.from(original.content),
      "blocks" => [%{"url" => "https://github.com/Acme/Api/pull/42?tab=files"}]
    }

    entry =
      original
      |> Map.from_struct()
      |> Map.take(Entry.__schema__(:fields))
      |> Map.merge(%{
        id: identity,
        dedupe_key: identity,
        native_input_id: identity,
        decision_ref: "host-source-padding:#{identity}",
        content: content,
        event_fingerprint: CanonicalJSON.digest(content)
      })
      |> then(&Repo.insert!(struct!(Entry, &1)))

    assert {:ok, :ok} = Repo.transaction(fn -> Observations.receive_in_transaction(entry) end)
    assert {:ok, run} = Learning.prepare([entry.id], @policy)
    document = Jason.decode!(result([entry]))

    proposal =
      hd(document["updates"]) |> Map.put("anchors", ["https://github.com/acme/api/pull/42"])

    assert {:ok, _} =
             Fixtures.accept(
               run.id,
               Jason.encode!(%{document | "updates" => [proposal]}),
               %{}
             )
  end

  test "renaming an unavailable subject with the same exact anchor cannot create a duplicate" do
    [first, second] = Fixtures.inputs!()
    assert {:ok, initial} = Learning.prepare([first.id], @policy)
    document = Jason.decode!(result([first]))

    proposal =
      hd(document["updates"]) |> Map.put("anchors", ["311e38f3-a17c-7d1b-1235-05c256ba3c39"])

    assert {:ok, _} =
             Fixtures.accept(
               initial.id,
               Jason.encode!(%{document | "updates" => [proposal]}),
               %{}
             )

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Observations.receive_in_transaction(%{
                 first
                 | id: Ecto.UUID.generate(),
                   revision: first.revision + 1,
                   event_kind: :delete
               })
             end)

    assert {:ok, fresh} = Learning.prepare([second.id], @policy)
    assert fresh.knowledge == []

    renamed =
      Map.merge(proposal, %{"topic_key" => "another-name", "source_input_ids" => [second.id]})

    assert {:error, :knowledge_target_unavailable} =
             Fixtures.accept(
               fresh.id,
               Jason.encode!(%{document | "updates" => [renamed]}),
               %{}
             )

    assert Repo.aggregate(KnowledgeRevision, :count) == 1
  end

  test "the result receipt accepts the complete bounded batch contract including Unicode" do
    # Sixteen valid topic updates exceeded the old 32 KiB receipt cap, leaving
    # a successful model response unsaved and impossible to resume safely.
    entries = Fixtures.inputs!()
    assert {:ok, run} = Learning.prepare(Enum.map(entries, & &1.id), @policy)
    document = Jason.decode!(result(entries))
    template = hd(document["updates"])

    updates =
      for n <- 1..16 do
        Map.merge(template, %{
          "topic_key" => "topic-#{n}",
          "summary" => String.duplicate("界", 1200)
        })
      end

    candidate = Jason.encode!(%{document | "updates" => updates})
    assert byte_size(candidate) > 32_768

    assert {:ok, %{status: :applied} = saved} =
             Fixtures.accept(run.id, candidate, %{})

    assert saved.result == candidate
    assert Repo.aggregate(KnowledgeRevision, :count) == 16
    assert {:ok, ^saved} = Fixtures.accept(run.id, candidate, %{})

    assert {:error, :invalid_learning_result} =
             Fixtures.accept(run.id, String.duplicate("x", 524_289), %{})
  end

  test "a source changed after freezing rejects the saved result without refreshing its prompt" do
    entries = Fixtures.inputs!()
    assert {:ok, run} = Learning.prepare(Enum.map(entries, & &1.id), @policy)
    entry = hd(entries)

    edited = %{
      entry
      | id: Ecto.UUID.generate(),
        revision: entry.revision + 1,
        event_kind: :edit,
        event_fingerprint: String.duplicate("c", 64)
    }

    assert {:ok, :ok} = Repo.transaction(fn -> Observations.receive_in_transaction(edited) end)
    assert {:error, :learning_source_stale} = Learning.authorize(run.id)
    candidate = result(entries)

    assert {:error, :learning_source_stale} =
             Fixtures.accept(run.id, candidate, %{})

    saved = Repo.get!(LearningRun, run.id)
    assert saved.prompt == run.prompt
    assert saved.result == candidate
    assert saved.status == :stale
    assert Repo.aggregate(KnowledgeRevision, :count) == 0
  end

  test "a failure in a later proposed update rolls back every knowledge change" do
    entries = Fixtures.inputs!()
    assert {:ok, run} = Learning.prepare(Enum.map(entries, & &1.id), @policy)
    document = Jason.decode!(result(entries))

    invalid =
      hd(document["updates"])
      |> Map.put("topic_key", "unoffered-topic")
      |> Map.put("target_ref", "knowledge:" <> Ecto.UUID.generate())
      |> Map.put("action", "update")
      |> Map.put("expected_version", 1)

    candidate = Jason.encode!(%{document | "updates" => document["updates"] ++ [invalid]})

    assert {:error, :learning_context_stale} =
             Fixtures.accept(run.id, candidate, %{})

    assert Repo.aggregate(KnowledgeRevision, :count) == 0
    assert Repo.get!(LearningRun, run.id).result == candidate
  end

  test "a finished stale attempt cannot consume its old response again" do
    entries = Fixtures.inputs!()
    assert {:ok, run} = Learning.prepare(Enum.map(entries, & &1.id), @policy)
    candidate = result(entries)

    Repo.update!(
      Ecto.Changeset.change(run,
        status: :stale,
        result: candidate,
        result_sha256: CanonicalJSON.digest(candidate)
      )
    )

    assert {:error, :learning_attempt_finished} =
             Fixtures.accept(run.id, candidate, %{})

    assert Repo.aggregate(KnowledgeRevision, :count) == 0
    assert {:ok, fresh} = Learning.prepare(Enum.map(entries, & &1.id), @policy)
    assert fresh.generation == run.generation + 1
    assert fresh.id != run.id
    assert fresh.result == nil
  end

  test "learning prompt and result copies expire with inherited sources without erasing receipts" do
    entries = Fixtures.inputs!()
    assert {:ok, run} = Learning.prepare(Enum.map(entries, & &1.id), @policy)
    assert {:ok, applied} = Fixtures.accept(run.id, result(entries), %{})
    expired = DateTime.add(DateTime.utc_now(), -3601) |> DateTime.to_iso8601()
    dependencies = Enum.map(applied.source_dependencies, &Map.put(&1, "retained_at", expired))
    Repo.update!(Ecto.Changeset.change(applied, source_dependencies: dependencies))
    assert {:ok, 1} = Repo.transaction(fn -> Learning.prune_in_transaction(3600) end)
    saved = Repo.get!(LearningRun, run.id)
    assert saved.prompt == nil
    assert saved.result == nil
    assert saved.knowledge == []
    assert saved.status == :applied
    assert saved.prompt_sha256 == run.prompt_sha256
    assert saved.result_sha256 == applied.result_sha256
    assert saved.source_dependencies == dependencies
    assert saved.pruned_at != nil
    assert {:error, :learning_source_stale} = Learning.authorize(run.id)
  end

  test "a late model result cannot resurrect an already pruned learning attempt" do
    # A late response used to repopulate a pruned row that retention would skip forever.
    entries = Fixtures.inputs!()
    assert {:ok, run} = Learning.prepare(Enum.map(entries, & &1.id), @policy)
    expired = DateTime.add(DateTime.utc_now(), -3601) |> DateTime.to_iso8601()
    dependencies = Enum.map(run.source_dependencies, &Map.put(&1, "retained_at", expired))
    Repo.update!(Ecto.Changeset.change(run, source_dependencies: dependencies))
    assert {:ok, 1} = Repo.transaction(fn -> Learning.prune_in_transaction(3600) end)

    assert {:error, :learning_source_stale} =
             Fixtures.accept(run.id, result(entries), %{
               "detail" => "late-response"
             })

    saved = Repo.get!(LearningRun, run.id)
    assert saved.result == nil
    assert saved.result_sha256 == nil
    assert saved.producer == %{}
    assert {:ok, 0} = Repo.transaction(fn -> Learning.prune_in_transaction(3600) end)
    assert Repo.aggregate(KnowledgeRevision, :count) == 0
  end

  test "the supporting subset cannot omit other raw messages from derived-source expiry" do
    entries = Fixtures.inputs!()
    assert {:ok, run} = Learning.prepare(Enum.map(entries, & &1.id), @policy)
    document = Jason.decode!(result(entries))
    update = hd(document["updates"]) |> Map.put("source_input_ids", [hd(entries).id])

    assert {:ok, _} =
             Fixtures.accept(
               run.id,
               Jason.encode!(%{document | "updates" => [update]}),
               %{}
             )

    [revision] = Repo.all(KnowledgeRevision)

    assert LearningSources.expand(revision.source_dependencies) ==
             LearningSources.expand(run.source_dependencies)

    second = List.last(entries)

    edited = %{
      second
      | id: Ecto.UUID.generate(),
        revision: second.revision + 1,
        event_kind: :edit,
        event_fingerprint: String.duplicate("c", 64)
    }

    assert {:ok, :ok} = Repo.transaction(fn -> Observations.receive_in_transaction(edited) end)
    assert Knowledge.context(hd(entries), "blitz-infra") == []
  end

  test "operational source pruning also removes the learning copy in the same retention pass" do
    entries = Fixtures.inputs!()
    assert {:ok, run} = Learning.prepare(Enum.map(entries, & &1.id), @policy)
    assert {:ok, _} = Fixtures.accept(run.id, result(entries), %{})
    old = DateTime.add(DateTime.utc_now(), -120)
    Repo.update_all(Entry, set: [updated_at: old])

    assert {:ok, _} =
             Data.prune(%{
               operational_data_seconds: 60,
               closed_work_seconds: 3600,
               conversation_memory_seconds: 3600,
               episode_history_seconds: 3600,
               audit_data_seconds: 3600
             })

    assert Repo.get!(LearningRun, run.id).prompt == nil
    assert Repo.get!(LearningRun, run.id).result == nil
  end

  test "a prepared batch is reusable but conflicting saved results are not" do
    entries = Fixtures.inputs!()
    ids = Enum.map(entries, & &1.id)
    assert {:ok, run} = Learning.prepare(ids, @policy)
    assert {:ok, ^run} = Learning.prepare(ids, @policy)
    candidate = result(entries)

    Repo.update!(
      Ecto.Changeset.change(run,
        status: :responded,
        result: candidate,
        result_sha256: CanonicalJSON.digest(candidate)
      )
    )

    assert {:ok, saved} = Learning.prepare(ids, @policy)
    assert saved.result == candidate
    assert {:ok, _} = Fixtures.accept(run.id, candidate, %{})

    assert {:error, :learning_result_conflict} =
             Fixtures.accept(run.id, "{}", %{})

    assert Repo.aggregate(KnowledgeRevision, :count) == 1
  end

  test "invalid and oversized batches fail without creating attempts" do
    entries = Fixtures.inputs!()
    ids = Enum.map(entries, & &1.id)
    assert {:error, :invalid_learning_inputs} = Learning.prepare([], @policy)
    assert {:error, :invalid_learning_inputs} = Learning.prepare(ids ++ ids, @policy)
    assert {:error, :invalid_learning_inputs} = Learning.prepare(["not-an-id"], @policy)
    assert {:error, :learning_source_stale} = Learning.prepare([Ecto.UUID.generate()], @policy)
    assert {:error, :invalid_learning_inputs} = Learning.prepare(ids, %{@policy | policy: ""})

    assert {:error, :invalid_learning_inputs} =
             Learning.prepare(ids, %{@policy | policy_digest: "x"})

    Repo.update!(
      Ecto.Changeset.change(hd(entries), content: %{"text" => String.duplicate("x", 65_537)})
    )

    assert {:error, :learning_capacity_exceeded} = Learning.prepare(ids, @policy)
    assert Repo.aggregate(LearningRun, :count) == 0
  end

  test "a deleted source channel denies preparation without crashing or saving a prompt" do
    entries = Fixtures.inputs!()

    Repo.insert!(%ChannelMembership{
      id: Ecto.UUID.generate(),
      workspace_ref: "T01J1LW4DF1",
      channel_ref: "C08MMETA3U3",
      private: false,
      external_shared: false,
      generation: 1,
      status: :deleted,
      joined_at: DateTime.utc_now(),
      deleted_at: DateTime.utc_now()
    })

    assert {:error, :learning_source_stale} =
             Learning.prepare(Enum.map(entries, & &1.id), @policy)

    assert Repo.aggregate(LearningRun, :count) == 0
  end

  test "invalid output is retained as a rejected attempt and cannot write knowledge" do
    entries = Fixtures.inputs!()
    assert {:ok, run} = Learning.prepare(Enum.map(entries, & &1.id), @policy)

    assert {:error, :invalid_learning_result} =
             Fixtures.accept(run.id, "not-json", %{})

    assert Repo.get!(LearningRun, run.id).status == :rejected
    assert Repo.get!(LearningRun, run.id).result == "not-json"
    assert {:error, :learning_attempt_finished} = Learning.authorize(run.id)

    assert {:error, :invalid_learning_result} =
             Fixtures.accept(run.id, String.duplicate("x", 524_289), %{})

    assert {:error, :learning_run_not_found} = Learning.authorize("invalid")
    assert {:error, :learning_run_not_found} = Learning.authorize(Ecto.UUID.generate())
    assert Repo.aggregate(KnowledgeRevision, :count) == 0
  end

  test "later messages update the offered topic and stale judgments require a fresh version" do
    [first, second] = entries = Fixtures.inputs!()
    assert {:ok, initial} = Learning.prepare([first.id], @policy)
    assert {:ok, _} = Fixtures.accept(initial.id, result([first]), %{})
    assert {:ok, waiting} = Learning.prepare([second.id], @policy)
    assert [offered] = waiting.knowledge
    assert offered["version"] == 1
    assert {:ok, other} = Learning.prepare(Enum.map(entries, & &1.id), @policy)

    assert {:ok, _} =
             Fixtures.accept(other.id, update_result(entries, offered), %{})

    assert {:error, :learning_context_stale} = Learning.authorize(waiting.id)
    assert {:ok, fresh} = Learning.prepare([second.id], @policy)
    assert fresh.generation == 2
    assert Repo.get!(LearningRun, waiting.id).status == :stale
    assert [current] = fresh.knowledge
    assert current["version"] == 2

    assert {:ok, _} =
             Fixtures.accept(fresh.id, update_result([second], current), %{})

    assert [head] = Knowledge.context(second, "blitz-infra")
    assert head["version"] == 3
    assert head["source_count"] == 2
    assert Repo.aggregate(KnowledgeRevision, :count) == 3
  end

  test "an unoffered topic collision prepares a fresh judgment with that exact authorized head" do
    # Search is bounded, not omniscient. A valid existing topic key must not
    # trap the same retained batch in an identical failed briefing forever.
    [first, second] = Fixtures.inputs!()
    assert {:ok, initial} = Learning.prepare([first.id], @policy)
    document = Jason.decode!(result([first]))

    opaque =
      Map.merge(hd(document["updates"]), %{
        "topic_key" => "previous-initiative",
        "title" => "Earlier initiative",
        "summary" => "Keep the prior decision.",
        "topics" => ["Earlier initiative"]
      })

    assert {:ok, _} =
             Fixtures.accept(
               initial.id,
               Jason.encode!(%{document | "updates" => [opaque]}),
               %{}
             )

    for n <- 1..33 do
      proposal =
        opaque
        |> Map.drop(~w(action source_input_ids))
        |> Map.merge(%{
          "topic_key" => "other-#{n}",
          "title" => "Another project #{n}",
          "summary" => "An unrelated project discussion.",
          "topics" => ["Another project"]
        })

      assert {:ok, :ok} =
               Repo.transaction(fn ->
                 Knowledge.record_sources_in_transaction([second], proposal, [], %{
                   result_ref: "host-contract-test:#{n}",
                   source_dependencies: LearningSources.for_entry(second),
                   omissions: []
                 })
               end)
    end

    assert {:ok, missing} = Learning.prepare([second.id], @policy)
    refute Enum.any?(missing.knowledge, &(&1["topic_key"] == "previous-initiative"))
    proposal = Map.put(opaque, "source_input_ids", [second.id])
    candidate = Jason.encode!(%{document | "updates" => [proposal]})

    assert {:error, :learning_match_required} =
             Fixtures.accept(missing.id, candidate, %{})

    assert {:ok, fresh} = Learning.prepare([second.id], @policy)
    assert fresh.id != missing.id
    assert fresh.result == nil
    assert fresh.generation == missing.generation + 1
    assert [head | _] = fresh.knowledge
    assert head["topic_key"] == "previous-initiative"
    assert head["can_update"]

    proposal =
      Map.merge(proposal, %{
        "target_ref" => head["source_ref"],
        "action" => "update",
        "expected_version" => head["version"]
      })

    assert {:ok, _} =
             Fixtures.accept(
               fresh.id,
               Jason.encode!(%{document | "updates" => [proposal]}),
               %{}
             )

    assert Repo.get!(LearningRun, missing.id).result == candidate
  end

  test "a renamed create is checked against unoffered existing subjects before it writes" do
    # Host-contract mutation of the recorded lifecycle inputs: the subject is
    # unchanged but the proposed key differs. This isolates matching, not model quality.
    [first, second] = Fixtures.inputs!()
    document = Jason.decode!(result([first]))

    proposal =
      Map.merge(hd(document["updates"]), %{
        "topic_key" => "previous-initiative",
        "title" => "Earlier initiative",
        "summary" => "Keep the prior decision.",
        "topics" => ["Earlier initiative"]
      })

    assert {:ok, initial} = Learning.prepare([first.id], @policy)

    assert {:ok, _} =
             Fixtures.accept(
               initial.id,
               Jason.encode!(%{document | "updates" => [proposal]}),
               %{}
             )

    [head] = Knowledge.context(first, first.repository_ref)
    assert {:ok, missing} = Learning.prepare([second.id], @policy)
    assert missing.knowledge == []

    renamed =
      Map.merge(proposal, %{
        "topic_key" => "renamed-initiative",
        "source_input_ids" => [second.id]
      })

    candidate = Jason.encode!(%{document | "updates" => [renamed]})

    assert {:error, :learning_match_required} =
             Fixtures.accept(missing.id, candidate, %{})

    assert Repo.aggregate(KnowledgeRevision, :count) == 1
    assert {:ok, fresh} = Learning.prepare([second.id], @policy)
    assert fresh.knowledge == [head]
    assert fresh.generation == missing.generation + 1
  end

  defp update_result(entries, offered) do
    document = Jason.decode!(result(entries))

    update =
      hd(document["updates"])
      |> Map.put("target_ref", offered["source_ref"])
      |> Map.put("action", "update")
      |> Map.put("expected_version", offered["version"])

    Jason.encode!(%{document | "updates" => [update]})
  end

  defp result(entries) do
    # Constructed host-contract output, not a recorded model judgment. These
    # tests prove transactional custody; the separate live replay proves learning quality.
    Jason.encode!(%{
      "reason" => "Maintain the reported alert lifecycle with uncertainty.",
      "updates" => [
        %{
          "source_input_ids" => Enum.map(entries, & &1.id),
          "action" => "create",
          "topic_key" => "website-haproxy-edge-oom",
          "title" => "Website HAProxy memory limit",
          "summary" =>
            "Grafana reported this OOM warning resolved; application recovery remains unverified.",
          "topics" => ["website", "haproxy-edge", "OOM"],
          "target_ref" => nil,
          "anchors" => [],
          "expected_version" => 0
        }
      ]
    })
  end

  defp protected_rows,
    do: Enum.map([Entry, ConversationObservation, Episode, Event, Turn], &Repo.all/1)
end
