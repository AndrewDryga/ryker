defmodule Ryker.Learning.DecisionsTest do
  use Ryker.DataCase, async: true
  import Ecto.Query
  alias Ryker.Admission.{Decision, Executor}
  alias Ryker.CanonicalJSON
  alias Ryker.Fixtures.SavedEntities
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.WorkProfile
  alias Ryker.Learning.LearningInput
  alias Ryker.Learning.Observations
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Schedules
  alias Ryker.TestSupport.FakeCoopAPI, as: FakeAPI

  # Routing reads its context at REPEATABLE READ, which a test's sandbox has to open with.
  @moduletag isolation: "REPEATABLE READ"
  @now ~U[2026-10-11 11:46:53.000000Z]

  # Learning reads what people said, and a decision made with a button says nothing. On
  # 2026-10-11 a topic still said a memory offer "remains pending" four minutes after it was
  # confirmed (topic lantern-api-fictional-qa-ownership: last source 11:42:45, confirmed by a
  # button at 11:46:53), and another called a reminder's pause "unverified" after the reminder
  # was paused (qa-weekday-reminder: last source 16:12:11, paused at 16:17:59). Each decision
  # now reaches the conversation's learning as Ryker's own message, which routing settles
  # without a model or any work.
  test "a confirmed offer reaches the conversation's learning, and routing spends no model on it" do
    conversation = "slack:T0DECIDE:C#{System.unique_integer([:positive])}"
    source = SavedEntities.source!(conversation)
    asked = person_message!(source.episode, "Remember that Dana owns QA for lantern-api.")

    payload = %{
      "expires_in" => "30d",
      "kind" => "entity_relationship",
      "repository" => nil,
      "scope" => "conversation",
      "subject" => "QA owner of lantern-api",
      "value" => "Dana",
      "visibility" => "conversation"
    }

    {:ok, offer} =
      Records.create(Records.token(source.turn), "offer:qa-owner", "memory_offer", payload)

    assert {:ok, {:ok, _confirmed}} =
             Repo.transaction(fn ->
               Records.confirm_offer(offer, %{
                 actor_ref: "slack:user:U123",
                 confirmation_ref: "interaction:qa-owner",
                 occurred_at: @now
               })
             end)

    receipt = receipt!(conversation)

    assert receipt.content == %{
             "decision" => "confirmed",
             "kind" => "decision_receipt",
             "record_ref" => offer.ref,
             "text" =>
               "The offer was confirmed (to remember something): QA owner of lantern-api: Dana"
           }

    assert receipt.occurred_at == @now
    assert {receipt.repository_ref, receipt.execution_mode} == {"ryker", :live}
    assert {receipt.repository_ref, receipt.execution_mode} == {asked.repository_ref, :live}

    {:ok, fake} = FakeAPI.start_link([])

    assert {:ok, %{entry: claimed, lease_ref: lease_ref}} =
             Inbox.claim_next("decisions", @now, 300)

    assert claimed.id == receipt.id
    assert {:ok, _settled} = Executor.run(Inbox.ref(receipt), executor_options(fake, lease_ref))

    assert %Entry{status: :decided, decision_action: :ignore, episode_id: nil} =
             Repo.get!(Entry, receipt.id)

    # No routing session was opened and no prompt sent.
    assert %{sessions: sessions, turn_keys: []} = state = FakeAPI.state(fake)
    assert sessions == %{}
    refute Map.has_key?(state, :submitted_prompt)

    # The conversation's next learning pass reads it with the conversation's messages.
    learnable =
      LearningInput.Query.pending()
      |> LearningInput.Query.by_scope(%{
        transport: "slack",
        conversation_ref: conversation,
        repository_ref: "ryker",
        execution_mode: :live
      })
      |> LearningInput.Query.processable(Repo.now!(), nil)
      |> select([e], e.id)
      |> Repo.all()

    assert receipt.id in learnable
  end

  test "pausing and resuming an automation reaches the conversation's learning" do
    conversation = "slack:T0DECIDE:C#{System.unique_integer([:positive])}"
    source = SavedEntities.source!(conversation)
    _asked = person_message!(source.episode, "Pause the weekday QA reminder for now.")
    schedule = SavedEntities.schedule!(source, "QA weekday reminder", 1)

    assert {:ok, paused} = Schedules.set_status(schedule.ref, :paused)
    assert {:ok, _resumed} = Schedules.set_status(schedule.ref, :active)

    assert %{"paused" => paused_receipt, "active" => resumed_receipt} =
             Map.new(receipts(conversation), &{&1.content["decision"], &1})

    assert paused_receipt.content["text"] == ~s(The automation "QA weekday reminder" was paused.)

    assert paused_receipt.native_input_id ==
             "decision:automation-paused:#{schedule.ref}:#{paused.revision}"

    assert resumed_receipt.content["text"] ==
             ~s(The automation "QA weekday reminder" was resumed.)
  end

  # A person's message that started `episode`, as admission keeps one, in a
  # conversation about the ryker repository.
  defp person_message!(episode, text) do
    id = Ecto.UUID.generate()

    {:ok, profile} =
      WorkProfile.new(%{
        policy: "work-read-only",
        policy_digest: String.duplicate("a", 64),
        repository_ref: "ryker"
      })

    {:ok, decision} =
      Decision.parse(%{
        "action" => "start_episode",
        "episode_ref" => nil,
        "messages" => nil,
        "reactions" => nil,
        "relation" => "unrelated",
        "repository" => nil,
        "repository_source" => nil,
        "reason" => "A new request.",
        "work_class" => "standard"
      })

    entry =
      %Entry{
        id: id,
        status: :pending,
        dedupe_key: "asked:#{id}",
        event_ref: "asked:#{id}",
        event_fingerprint: CanonicalJSON.digest(["asked", id]),
        source_kind: "slack",
        source_ref: "T0DECIDE",
        native_input_id: "asked:#{id}",
        source_item_ref: "asked:#{id}",
        actor_kind: :user,
        actor_ref: "slack:user:U123",
        revision: 1,
        event_kind: :message,
        content: %{"text" => text},
        occurred_at: DateTime.add(@now, -248, :second),
        occurred_at_source: :source,
        execution_mode: episode.execution_mode,
        destination_transport: episode.destination_transport,
        destination_conversation_ref: episode.destination_conversation_ref,
        destination_thread_ref: episode.destination_thread_ref,
        repository_ref: "ryker",
        source_capabilities: %{},
        work_profile: WorkProfile.document(profile),
        work_policy: profile.policy,
        work_policy_digest: profile.policy_digest
      }
      |> Entry.Changeset.decide(decision, "asked:#{id}", episode.id)
      |> Repo.insert!()

    {:ok, :ok} = Repo.transaction(fn -> Observations.record_excerpt_in_transaction(entry) end)
    entry
  end

  defp receipt!(conversation) do
    assert [receipt] = receipts(conversation)
    receipt
  end

  defp receipts(conversation) do
    Repo.all(
      from(e in Entry,
        where: e.destination_conversation_ref == ^conversation and e.source_kind == "system",
        order_by: [asc: e.inserted_at, asc: e.native_input_id]
      )
    )
  end

  defp executor_options(fake, lease_ref) do
    [
      api: FakeAPI,
      client: fake,
      lease_ref: lease_ref,
      max_polls: 10,
      now: fn -> @now end,
      policy: "admission-read-only",
      policy_digest: String.duplicate("a", 64),
      poll_interval_ms: 0,
      renew_lease: fn -> :ok end,
      sleep: fn _milliseconds -> :ok end
    ]
  end
end
