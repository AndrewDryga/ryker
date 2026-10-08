defmodule Ryker.Memories.GlobalMemoriesTest do
  use Ryker.DataCase, async: false
  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{FactsPage, MemoryProjection}
  alias Ryker.Episodes
  alias Ryker.Episodes.Episode
  alias Ryker.Fixtures.AnswerMemory
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.MemoryPages
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Inspectors
  alias Ryker.Memories
  alias Ryker.Memories.MemoryEntry
  alias Ryker.Memories.Recall
  alias Ryker.Memories.Reviews
  alias Ryker.Records
  alias Ryker.Records.Record
  alias Ryker.Records.Response
  alias Ryker.Retention.Data
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.StateTools.{Router, Tools}
  alias Ryker.Work.{Custody, Session, Turn}

  @expired %{
    audit_data_seconds: 120,
    closed_work_seconds: 60,
    conversation_memory_seconds: 60,
    episode_history_seconds: 60,
    operational_data_seconds: 60,
    routing_examples_enabled: false,
    routing_examples_seconds: 365 * 86_400,
    work_examples_enabled: false,
    work_examples_seconds: 365 * 86_400
  }

  test "an answer-confirmed global fact is recalled without disclosing its private source" do
    entry = insert_fact!("Production portal in AndrewDryga/emisar", "portal-prod")

    context = %{
      conversation_ref: "slack:TSECOND:COTHER",
      repository: nil,
      workspace_ref: "slack:TSECOND"
    }

    assert [fact] = Recall.recall(context)
    assert fact["memory_ref"] == entry.ref
    assert fact["scope"] == "global"
    assert fact["value"] == "portal-prod"
    assert fact["applicability"] == "Production portal in AndrewDryga/emisar"
    assert is_nil(fact["expires_at"])
    refute Map.has_key?(fact, "source")
    refute Map.has_key?(fact, "source_read")
    refute inspect(fact) =~ "CPRIVATE"
    assert [^fact] = MemoryPages.facts(context, "portal-prod", "global", 20)
  end

  test "different environments remain separate and explicit forgetting removes the saved value" do
    production = insert_fact!("Production portal", "portal-prod")
    staging = insert_fact!("Staging portal", "portal-stage")

    context = %{
      conversation_ref: "control-plane:lab:another",
      repository: nil,
      workspace_ref: "control-plane:lab:another"
    }

    assert length(Recall.recall(context)) == 2
    assert {:ok, forgotten} = Memories.forget(production.ref)
    assert forgotten.status == :deleted
    refute inspect(forgotten.payload) =~ "portal-prod"
    assert [%{"memory_ref" => ref}] = Recall.recall(context)
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
               audit_data_seconds: 120,
               routing_examples_enabled: false,
               routing_examples_seconds: 365 * 86_400,
               work_examples_enabled: false,
               work_examples_seconds: 365 * 86_400
             })

    assert Repo.get(MemoryEntry, entry.id),
           "global facts must not expire with conversation history"

    assert [review] = Inspectors.memory_reviews("installation")
    assert review["kind"] == "stale"
  end

  test "the existing memory controls show the global value and applicability for inspection and forgetting" do
    entry = insert_fact!("Production portal", "portal-prod")
    snapshot = MemoryProjection.fetch()
    assert [item] = snapshot.memories
    assert item.ref == entry.ref

    body =
      %{memories: snapshot.memories, reviews: []}
      |> FactsPage.html()
      |> IO.iodata_to_binary()

    assert body =~ "portal-prod"
    assert body =~ "Production portal"
    assert body =~ "Everywhere"
    assert body =~ "/actions/memory/#{entry.id}/forget"
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

  # Slack reports a link's preview arriving as an edit with the words
  # untouched. Every edit revoked an answer-confirmed fact, and any newer
  # revision kept the answer from being saved, so an answer with a link was
  # forgotten as soon as Slack previewed it (2026-10-04 review).
  test "a link preview of an answer neither revokes its saved fact nor blocks saving it" do
    saved =
      AnswerMemory.answered!("portal-prod, see https://console.example.com", DateTime.utc_now())

    assert {:ok, %{memory: memory}} = remember(saved, "portal-prod")
    preview!(saved)
    assert Repo.get!(MemoryEntry, memory.id).status == :active

    unsaved =
      AnswerMemory.answered!("portal-prod, see https://console.example.com", DateTime.utc_now())

    preview!(unsaved)
    assert {:ok, %{memory: _memory}} = remember(unsaved, "portal-prod")
  end

  defp preview!(answer) do
    assert {:ok, revision} =
             answer.input
             |> Map.merge(%{
               event_kind: :edit,
               event_ref: "preview:#{answer.entry.id}",
               revision: 2,
               content: Map.put(answer.input.content, "attachments", [%{"title" => "Console"}])
             })
             |> SlackInput.new()

    assert {:ok, _receipt} = Inbox.record(revision)
  end

  test "reviewed correction preserves global applicability and records the new actor and value" do
    entry = insert_fact!("Production portal", "portal-old")
    old = DateTime.add(DateTime.utc_now(), -120, :second)
    Repo.update_all(MemoryEntry, set: [updated_at: old, confirmed_at: old])
    assert {:ok, %{created: 1}} = Reviews.refresh_reviews("installation", 60)
    assert [review] = Inspectors.memory_reviews("installation")

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
             Recall.recall(%{
               conversation_ref: "slack:TOTHER:CNEW",
               workspace_ref: "slack:TOTHER",
               repository: nil
             })

    refute inspect(changed.payload) =~ "portal-old"
  end

  test "explicit source-channel deletion revokes its global facts as well as conversation memory" do
    entry = insert_fact!("Production portal", "portal-prod")

    assert Repo.transaction(fn ->
             Memories.delete_slack_channel_in_transaction("TORIGINAL", "CPRIVATE")
           end) == {:ok, :ok}

    assert Repo.get!(MemoryEntry, entry.id).status == :deleted
  end

  test "a delayed answer cannot replace a more recent answer for the same global mapping" do
    # Different conversations may resume at different speeds. Processing order
    # must not turn a previously answered project question into a rollback.
    now = DateTime.add(DateTime.utc_now(), -10, :second)
    older = AnswerMemory.answered!("portal-old", now)
    newer = AnswerMemory.answered!("portal-current", DateTime.add(now, 1, :second))

    assert {:ok, %{memory: current}} = remember(newer, "portal-current")
    assert remember(older, "portal-old") == {:error, :answer_memory_conflict}
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
    assert remember(older, "portal-old") == {:error, :answer_memory_conflict}
  end

  # remember_answer saved whatever value the model passed as an
  # installation-wide fact credited to the person who answered, without
  # checking that the answer said it (2026-10-04 review). The value may trim
  # the answer to the fact, never add to it.
  # An answer becomes a fact every conversation recalls. One given in a
  # private channel was recalled everywhere, its source hidden but its words
  # not (2026-10-04 review). A memory offered for a whole workspace or
  # repository was already held to a public channel.
  test "an answer given in a private channel is not remembered for every conversation" do
    answer = AnswerMemory.answered!("portal-private", DateTime.utc_now(), private: true)

    assert remember(answer, "portal-private") == {:error, :answer_memory_private_source}
    assert Repo.aggregate(MemoryEntry, :count) == 0

    public = AnswerMemory.answered!("portal-public", DateTime.utc_now())

    assert {:ok, %{memory: %MemoryEntry{scope_kind: :global}}} =
             remember(public, "portal-public")
  end

  test "only words the person's answer says can be remembered as their answer" do
    answer =
      AnswerMemory.answered!("It is portal-prod, the one in us-central1.", DateTime.utc_now())

    assert remember(answer, "portal-staging") == {:error, :answer_memory_not_in_answer}
    assert remember(answer, "portal-prod in europe") == {:error, :answer_memory_not_in_answer}
    assert Repo.aggregate(MemoryEntry, :count) == 0

    assert {:ok, %{memory: memory}} = remember(answer, "Portal-Prod")
    assert memory.payload["value"] == "Portal-Prod"
  end

  # Every refusal read answer_memory_unauthorized, so the model could not tell
  # a question it named wrongly from an answer it may not save (2026-10-04
  # review).
  test "remember_answer says why it refused an answer" do
    answer = AnswerMemory.answered!("portal-reasons", DateTime.utc_now())
    allow = fn _entry -> true end

    assert Memories.confirm_answer(answer.claim, "record:missing", "portal-reasons", allow) ==
             {:error, :answer_memory_question_not_found}

    assert Memories.confirm_answer(answer.claim, answer.record.ref, "portal-reasons", fn _ ->
             false
           end) == {:error, :answer_memory_unauthorized}

    plain = AnswerMemory.answered!("portal-plain", DateTime.utc_now(), remember: nil)

    assert Memories.confirm_answer(plain.claim, plain.record.ref, "portal-plain", allow) ==
             {:error, :answer_memory_not_requested}

    assert Repo.aggregate(MemoryEntry, :count) == 0
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
    assert remember(answer, "portal-old") == {:error, :answer_memory_revised}
    assert Repo.aggregate(MemoryEntry, :count) == 0
  end

  test "an unsaved answer cannot undo a later explicit forgetting of that mapping" do
    now = DateTime.add(DateTime.utc_now(), -10, :second)
    original = AnswerMemory.answered!("portal-original", now)
    queued = AnswerMemory.answered!("portal-queued", DateTime.add(now, 1, :second))
    assert {:ok, %{memory: memory}} = remember(original, "portal-original")
    assert {:ok, _} = Memories.forget(memory.ref)

    assert remember(queued, "portal-queued") == {:error, :answer_memory_conflict}
    assert Repo.get!(MemoryEntry, memory.id).status == :deleted
    assert Repo.aggregate(MemoryEntry, :count) == 1
  end

  test "an unsaved answer cannot undo a later reviewed correction" do
    now = DateTime.add(DateTime.utc_now(), -120, :second)
    original = AnswerMemory.answered!("portal-original", now)
    queued = AnswerMemory.answered!("portal-queued", DateTime.add(now, 1, :second))
    assert {:ok, %{memory: memory}} = remember(original, "portal-original")
    Repo.update_all(MemoryEntry, set: [updated_at: now])
    assert {:ok, %{created: 1}} = Reviews.refresh_reviews("installation", 60)
    assert [review] = Inspectors.memory_reviews("installation")

    assert {:ok, _} =
             Memories.resolve_review(
               review["review_ref"],
               :edit,
               "local-operator",
               "installation",
               %{"subject" => "GCP project", "value" => "portal-corrected"}
             )

    assert remember(queued, "portal-queued") == {:error, :answer_memory_conflict}
    assert Repo.get!(MemoryEntry, memory.id).payload["value"] == "portal-corrected"
    assert Repo.aggregate(MemoryEntry, :count) == 1
  end

  test "an answer-confirmed mapping outlives its own transcript and a fresh worker session" do
    # The reported deployment review stopped at an unknown GCP project. Asking
    # once only pays for itself if ordinary transcript cleanup and a restart
    # cannot quietly drop the answer; otherwise the next review asks again and
    # the whole question flow is theatre.
    answer = AnswerMemory.answered!("emisar-project-qa", answered_at())
    assert {:ok, %{memory: memory}} = remember(answer, "emisar-project-qa")

    expire_raw_history!()

    assert Repo.aggregate(Response, :count) == 0, "the answer response must expire with history"
    assert Repo.aggregate(Record, :count) == 0, "the question record must expire with history"
    assert Repo.aggregate(Entry, :count) == 0, "the answering message must expire with history"

    saved = Repo.get!(MemoryEntry, memory.id)
    assert saved.status == :active
    assert is_nil(saved.expires_at)

    # Nothing in this process may carry the answer: the recall below runs on a
    # brand-new episode, session and turn in another channel and reads only the
    # database, which is what a restarted worker sees.
    assert {:ok, %{"memories" => [recalled]}} = search_global!("emisar")
    assert recalled["memory_ref"] == memory.ref
    assert recalled["value"] == "emisar-project-qa"
    assert recalled["applicability"] == "Production portal"
    refute Map.has_key?(recalled, "source")
    refute inspect(recalled) =~ answer.entry.destination_conversation_ref
  end

  test "correction, forgetting and source revocation each end recall after that expiry" do
    # A remembered mapping that cannot be corrected or withdrawn is worse than
    # no memory at all, and the revocation paths must keep working once the
    # originating transcript is gone.
    for revoke <- [:correct, :forget, :revoke_source] do
      answer = AnswerMemory.answered!("emisar-project-old", answered_at())
      assert {:ok, %{memory: memory}} = remember(answer, "emisar-project-old")
      expire_raw_history!()
      assert {:ok, %{"memories" => [_recalled]}} = search_global!("emisar")

      case revoke do
        :correct ->
          stale = DateTime.add(Ryker.Repo.now!(), -120, :second)

          Repo.update_all(MemoryEntry,
            set: [
              updated_at: stale,
              confirmed_at: stale,
              last_recalled_at: stale,
              last_reviewed_at: stale
            ]
          )

          assert {:ok, %{created: 1}} = Reviews.refresh_reviews("installation", 60)
          assert [review] = Inspectors.memory_reviews("installation")

          assert {:ok, _} =
                   Memories.resolve_review(
                     review["review_ref"],
                     :edit,
                     "local-operator",
                     "installation",
                     %{"subject" => "GCP project", "value" => "emisar-project-current"}
                   )

          assert {:ok, %{"memories" => [corrected]}} = search_global!("emisar")
          assert corrected["value"] == "emisar-project-current"
          assert {:ok, %{"memories" => []}} = search_global!("emisar-project-old")

        :forget ->
          assert {:ok, _} = Memories.forget(memory.ref)
          assert {:ok, %{"memories" => []}} = search_global!("emisar")

        :revoke_source ->
          assert {:ok, revision} =
                   answer.input
                   |> Map.merge(%{
                     event_kind: :delete,
                     event_ref: "revoked:#{memory.id}",
                     revision: 2,
                     content: %{"text" => ""}
                   })
                   |> SlackInput.new()

          assert {:ok, _} = Inbox.record(revision)
          assert Repo.get!(MemoryEntry, memory.id).status == :deleted
          assert {:ok, %{"memories" => []}} = search_global!("emisar")
      end

      Repo.delete_all(MemoryEntry)
    end
  end

  # A real answer is a source event that already happened; taking the offset
  # from the database clock keeps that true however far the host clock has run.
  defp answered_at, do: DateTime.add(Ryker.Repo.now!(), -60, :second)

  defp expire_raw_history! do
    old = DateTime.add(DateTime.utc_now(), -30 * 86_400)

    Repo.update_all(Turn,
      set: [
        status: :superseded,
        lease_ref: nil,
        lease_owner: nil,
        lease_expires_at: nil,
        next_attempt_at: nil,
        updated_at: old
      ]
    )

    Repo.update_all(Session, set: [cleanup_status: :discarded, updated_at: old])
    Repo.update_all(Record, set: [updated_at: old])
    Repo.update_all(Entry, set: [updated_at: old])

    Repo.update_all(Episode,
      set: [
        state: :complete,
        owner_kind: nil,
        owner_ref: nil,
        active_input_refs: [],
        queued_input_refs: [],
        queued_input_order_keys: [],
        updated_at: old
      ]
    )

    assert {:ok, _} = Data.prune(@expired)
    assert Repo.aggregate(Episode, :count, :id) == 0, "the source episode must expire"
  end

  defp search_global!(query) do
    id = Ecto.UUID.generate()

    destination = %{
      conversation_ref: "slack:TRECALL:CRECALL",
      thread_ref: "1789041000.000001",
      transport: "slack"
    }

    {:ok, _transition} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          destination: destination,
          episode_id: id,
          episode_key: "global-recall:#{id}",
          native_input_id: "global-recall:#{id}",
          occurred_at: DateTime.utc_now(),
          turn_ref: "global-recall:#{id}"
        })
      )

    {:ok, _} = WorkSessions.pin_episode(id, "global-recall", String.duplicate("b", 64))
    {:ok, claim} = Custody.claim_next("global-recall:#{id}", 60, :work)

    options =
      Router.init(
        cursor_secret: Ryker.Secret.new("global-recall-cursor-secret"),
        binding: Map.put(claim, :state_token, Records.token(claim.turn))
      )

    Tools.call(
      "search_memory",
      %{
        "query" => query,
        "scope" => "global",
        "kinds" => ["fact"],
        "limit" => 5,
        "cursor" => nil,
        "after" => nil,
        "before" => nil,
        "time_basis" => "changed"
      },
      options
    )
  end

  defp remember(answer, value),
    do: Memories.confirm_answer(answer.claim, answer.record.ref, value, fn _ -> true end)

  defp insert_fact!(applicability, value) do
    id = Ecto.UUID.generate()
    # PostgreSQL owns the search cutoff. Stamping a fixture with the host clock
    # made this file fail on roughly one seed in three, because a row confirmed
    # after the database's clock_timestamp() is recalled but never searched.
    now = Ryker.Repo.now!()
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

    changeset = MemoryEntry.Changeset.insert(attributes)
    assert changeset.valid?, inspect(changeset.errors)
    assert {:ok, %MemoryEntry{} = entry} = Repo.insert(changeset)
    Repo.update_all(MemoryEntry, set: [inserted_at: now, updated_at: now])
    Repo.get!(MemoryEntry, entry.id)
  end
end
