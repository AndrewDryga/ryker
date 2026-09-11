defmodule Responder.State.GlobalMemoriesTest do
  use Responder.DataCase, async: false

  alias Responder.CanonicalJSON
  alias Responder.ControlPlane.{HTML, Projection}
  alias Responder.Fixtures.AnswerMemory
  alias Responder.Ingress.Inbox
  alias Responder.Retention.Data
  alias Responder.Slack.Input, as: SlackInput
  alias Responder.State.{Memories, MemoryEntry, MemoryEntryChangeset}

  test "an answer-confirmed global fact is recalled without disclosing its private source" do
    entry = insert_fact!("Production portal in AndrewDryga/emisar", "portal-prod")

    context = %{
      conversation_ref: "slack:TSECOND:COTHER",
      repository: nil,
      workspace_ref: "slack:TSECOND"
    }

    assert [fact] = Memories.recall(context)
    assert fact["memory_ref"] == entry.ref
    assert fact["scope"] == "global"
    assert fact["value"] == "portal-prod"
    assert fact["applicability"] == "Production portal in AndrewDryga/emisar"
    assert is_nil(fact["expires_at"])
    refute Map.has_key?(fact, "source")
    refute Map.has_key?(fact, "source_read")
    refute inspect(fact) =~ "CPRIVATE"
    assert [^fact] = Memories.search(context, "portal-prod", "global", 20)
  end

  test "different environments remain separate and explicit forgetting removes the saved value" do
    production = insert_fact!("Production portal", "portal-prod")
    staging = insert_fact!("Staging portal", "portal-stage")

    context = %{
      conversation_ref: "control-plane:lab:another",
      repository: nil,
      workspace_ref: "control-plane:lab:another"
    }

    assert length(Memories.recall(context)) == 2
    assert {:ok, forgotten} = Memories.forget(production.ref)
    assert forgotten.status == :deleted
    refute inspect(forgotten.payload) =~ "portal-prod"
    assert [%{"memory_ref" => ref}] = Memories.recall(context)
    assert ref == staging.ref
  end

  test "ordinary transcript retention keeps an active global answer available for review and reuse" do
    # Project routing is a confirmed setting-like fact, not an expiring transcript.
    # Requiring the user to answer again after cleanup defeats the question flow.
    entry = insert_fact!("Production portal", "portal-prod")
    old = ~U[2020-01-01 00:00:00.000000Z]
    Repo.update_all(MemoryEntry, set: [confirmed_at: old, inserted_at: old, updated_at: old])

    assert {:ok, _} =
             Data.prune(%{
               operational_data_seconds: 60,
               closed_work_seconds: 60,
               episode_history_seconds: 60,
               conversation_memory_seconds: 60,
               audit_data_seconds: 120
             })

    assert Repo.get(MemoryEntry, entry.id),
           "global facts must not expire with conversation history"

    assert [review] = Memories.list_reviews("installation")
    assert review["kind"] == "stale"
  end

  test "the existing memory controls show the global value and applicability for inspection and forgetting" do
    entry = insert_fact!("Production portal", "portal-prod")
    snapshot = Projection.memory()
    assert [item] = snapshot.memories
    assert item.ref == entry.ref

    body =
      HTML.memory(
        %{memories: snapshot.memories, reviews: []},
        "test-secret"
      )
      |> IO.iodata_to_binary()

    assert body =~ "portal-prod"
    assert body =~ "Production portal"
    assert body =~ "Global"
    assert body =~ "/actions/memory/#{URI.encode(entry.ref, &URI.char_unreserved?/1)}/forget"
    refute body =~ entry.scope_ref
  end

  test "an explicit answer edit or deletion revokes its saved fact without saving replacement prose" do
    for {kind, revision} <- [edit: 2, delete: 3] do
      entry = insert_fact!("Production portal", "portal-prod")

      assert {:ok, input} =
               SlackInput.new(%{
                 actor: %{kind: :user, ref: "UOPERATOR"},
                 channel_ref: "CPRIVATE",
                 content: %{"text" => "That old project answer is no longer correct."},
                 event_kind: kind,
                 event_ref: "revised-answer:#{revision}",
                 message_ref: entry.source_message_ref,
                 occurred_at: DateTime.utc_now(),
                 revision: revision,
                 thread_ref: entry.source_thread_ref,
                 workspace_ref: "TORIGINAL"
               })

      assert {:ok, _} = Inbox.record(input)
      revoked = Repo.get!(MemoryEntry, entry.id)
      assert revoked.status == :deleted
      refute inspect(revoked.payload) =~ "portal-prod"
      refute inspect(revoked.payload) =~ "no longer correct"
    end
  end

  test "reviewed correction preserves global applicability and records the new actor and value" do
    entry = insert_fact!("Production portal", "portal-old")
    old = DateTime.add(DateTime.utc_now(), -120, :second)
    Repo.update_all(MemoryEntry, set: [updated_at: old, confirmed_at: old])
    assert {:ok, %{created: 1}} = Memories.refresh_reviews("installation", 60)
    assert [review] = Memories.list_reviews("installation")

    assert {:ok, _} =
             Memories.resolve_review(
               review["review_ref"],
               :edit,
               "local-operator",
               "installation",
               %{"subject" => "GCP project", "value" => "portal-current"}
             )

    changed = Repo.get!(MemoryEntry, entry.id)
    assert changed.scope_kind == :global
    assert changed.scope_ref == entry.scope_ref
    assert changed.payload["applicability"] == "Production portal"
    assert changed.edited_by_actor_ref == "local-operator"
    assert changed.edit_review_ref == review["review_ref"]
    assert changed.answer_provenance == entry.answer_provenance

    assert [%{"value" => "portal-current", "applicability" => "Production portal"}] =
             Memories.recall(%{
               conversation_ref: "slack:TOTHER:CNEW",
               workspace_ref: "slack:TOTHER",
               repository: nil
             })

    refute inspect(changed.payload) =~ "portal-old"
  end

  test "explicit source-channel deletion revokes its global facts as well as conversation memory" do
    entry = insert_fact!("Production portal", "portal-prod")

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Memories.delete_slack_channel_in_transaction("TORIGINAL", "CPRIVATE")
             end)

    assert Repo.get!(MemoryEntry, entry.id).status == :deleted
  end

  test "a delayed answer cannot replace a more recent answer for the same global mapping" do
    # Different conversations may resume at different speeds. Processing order
    # must not turn a previously answered project question into a rollback.
    now = DateTime.add(DateTime.utc_now(), -10, :second)
    older = AnswerMemory.answered!("portal-old", now)
    newer = AnswerMemory.answered!("portal-current", DateTime.add(now, 1, :second))

    assert {:ok, %{memory: current}} = remember(newer, "portal-current")
    assert {:error, :answer_memory_conflict} = remember(older, "portal-old")
    assert Repo.get!(MemoryEntry, current.id).status == :active
    assert Repo.aggregate(MemoryEntry, :count) == 1
  end

  test "a newer answer explicitly replaces an older mapping and erases the old value" do
    now = DateTime.add(DateTime.utc_now(), -10, :second)
    older = AnswerMemory.answered!("portal-old", now)
    newer = AnswerMemory.answered!("portal-current", DateTime.add(now, 1, :second))

    assert {:ok, %{memory: old}} = remember(older, "portal-old")
    assert {:ok, %{memory: current}} = remember(newer, "portal-current")
    replaced = Repo.get!(MemoryEntry, old.id)
    assert replaced.status == :superseded
    refute inspect(replaced.payload) =~ "portal-old"
    assert current.answer_provenance["answer_ref"] == newer.entry.event_ref
    assert {:error, :answer_memory_conflict} = remember(older, "portal-old")
  end

  test "an answer revised before saving cannot become a globally remembered fact" do
    answer = AnswerMemory.answered!("portal-old", DateTime.utc_now())

    assert {:ok, revision} =
             answer.input
             |> Map.merge(%{
               event_kind: :edit,
               event_ref: "revision:#{answer.entry.id}",
               revision: 2,
               content: %{"text" => "That answer was incorrect."}
             })
             |> SlackInput.new()

    assert {:ok, _} = Inbox.record(revision)
    assert {:error, :answer_memory_unauthorized} = remember(answer, "portal-old")
    assert Repo.aggregate(MemoryEntry, :count) == 0
  end

  test "an unsaved answer cannot undo a later explicit forgetting of that mapping" do
    now = DateTime.add(DateTime.utc_now(), -10, :second)
    original = AnswerMemory.answered!("portal-original", now)
    queued = AnswerMemory.answered!("portal-queued", DateTime.add(now, 1, :second))
    assert {:ok, %{memory: memory}} = remember(original, "portal-original")
    assert {:ok, _} = Memories.forget(memory.ref)

    assert {:error, :answer_memory_conflict} = remember(queued, "portal-queued")
    assert Repo.get!(MemoryEntry, memory.id).status == :deleted
    assert Repo.aggregate(MemoryEntry, :count) == 1
  end

  test "an unsaved answer cannot undo a later reviewed correction" do
    now = DateTime.add(DateTime.utc_now(), -120, :second)
    original = AnswerMemory.answered!("portal-original", now)
    queued = AnswerMemory.answered!("portal-queued", DateTime.add(now, 1, :second))
    assert {:ok, %{memory: memory}} = remember(original, "portal-original")
    Repo.update_all(MemoryEntry, set: [updated_at: now])
    assert {:ok, %{created: 1}} = Memories.refresh_reviews("installation", 60)
    assert [review] = Memories.list_reviews("installation")

    assert {:ok, _} =
             Memories.resolve_review(
               review["review_ref"],
               :edit,
               "local-operator",
               "installation",
               %{"subject" => "GCP project", "value" => "portal-corrected"}
             )

    assert {:error, :answer_memory_conflict} = remember(queued, "portal-queued")
    assert Repo.get!(MemoryEntry, memory.id).payload["value"] == "portal-corrected"
    assert Repo.aggregate(MemoryEntry, :count) == 1
  end

  defp remember(answer, value),
    do: Memories.confirm_answer(answer.claim, answer.record.ref, value, fn _ -> true end)

  defp insert_fact!(applicability, value) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()
    payload = %{"value" => value, "applicability" => applicability}

    attributes = %{
      id: id,
      ref: "memory:#{id}",
      kind: :entity_relationship,
      status: :active,
      workspace_ref: "installation",
      scope_kind: :global,
      scope_ref: "installation:#{CanonicalJSON.digest(applicability)}",
      visibility: :global,
      subject: "GCP project",
      payload: payload,
      payload_fingerprint: CanonicalJSON.digest(payload),
      confirmed_by_actor_ref: "slack:user:UOPERATOR",
      confirmation_ref: "answer:#{id}",
      confirmed_at: now,
      source_transport: "slack",
      source_conversation_ref: "slack:TORIGINAL:CPRIVATE",
      source_thread_ref: "1789038000.000001",
      source_message_ref: "1789038001.000001",
      answer_provenance: %{
        "question_ref" => "record:input_request:#{id}",
        "question_sha256" => CanonicalJSON.digest("Which project?"),
        "answer_ref" => "answer:#{id}",
        "source_revision" => 1,
        "answer_sha256" => CanonicalJSON.digest(value)
      }
    }

    changeset = MemoryEntryChangeset.insert(attributes)
    assert changeset.valid?, inspect(changeset.errors)
    assert {:ok, %MemoryEntry{} = entry} = Repo.insert(changeset)
    entry
  end
end
