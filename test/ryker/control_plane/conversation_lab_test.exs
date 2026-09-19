defmodule Ryker.ControlPlane.ConversationLabTest do
  use Ryker.DataCase, async: true

  @moduletag isolation: "REPEATABLE READ"

  import Ecto.Query

  alias Ryker.Admission.Attempts
  alias Ryker.ControlPlane.Activity

  alias Ryker.Admission
  alias Ryker.Admission.Decision
  alias Ryker.Artifacts
  alias Ryker.Artifacts.Artifact
  alias Ryker.ControlPlane.{Actions, ConversationLab, Projection}
  alias Ryker.ControlPlane.WorkChanges
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.WorkProfile
  alias Ryker.Repo
  alias Ryker.State.{Behavior, Records, Schedule}
  alias Ryker.TestSupport.FakeWorkCoopAPI

  alias Ryker.Work.{
    Cancellation,
    Custody,
    DeliveryReceipt,
    Result,
    Session,
    SubmissionBuilder
  }

  @conversation_id "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"
  @event_id "018f3ef7-1f62-7ee0-a83c-0c12f21d83e7"
  @now ~U[2026-08-30 18:00:00.000000Z]
  @task_policy_digest String.duplicate("b", 64)

  test "a local message enters ordinary ingress with host-owned routing and authority" do
    profile = profile()

    assert {:ok, %{status: :recorded, entry: entry}} =
             ConversationLab.send_message(
               @conversation_id,
               "Explain what this episode currently knows.",
               profile,
               id_generator: fn -> @event_id end,
               now: fn -> @now end
             )

    assert entry.source_kind == "control_plane"
    assert entry.source_ref == "local"
    assert entry.actor_kind == :user
    assert entry.actor_ref == "local-operator"
    assert entry.content == %{"text" => "Explain what this episode currently knows."}

    assert entry.source_capabilities == %{
             "post_slack_message" => %{
               "destination_refs" => ["control-plane:lab:#{@conversation_id}"]
             },
             "react" => %{"emoji_names" => nil}
           }

    assert entry.destination_transport == "control_plane"

    assert entry.destination_conversation_ref ==
             "control-plane:lab:#{@conversation_id}"

    assert entry.destination_thread_ref == entry.destination_conversation_ref
    assert entry.work_policy == profile.policy
    assert entry.work_policy_digest == profile.policy_digest
    assert entry.repository_ref == nil
    assert {:ok, ^entry} = Inbox.fetch(Inbox.ref(entry))
  end

  test "the Lab explains admission before an episode exists and links the frozen request" do
    {:ok, %{entry: entry}} =
      ConversationLab.send_message(@conversation_id, "Show admission progress", profile())

    assert {:ok, queued} = Projection.lab_conversation(@conversation_id)
    assert [waiting] = queued.admission_progress
    assert waiting.phase =~ "Queued"
    assert waiting.href == "/timeline/ingress-input%3A#{entry.id}"
    assert queued.episodes == []

    now = DateTime.utc_now()
    {:ok, claim} = Inbox.claim_next("progress-test", now, 60)

    settings = %{
      lease_ref: claim.lease_ref,
      now: fn -> now end,
      policy: "admission",
      policy_digest: String.duplicate("a", 64)
    }

    {:ok, _} = Attempts.prepare(claim.entry, settings)

    :ok =
      Attempts.observe(
        claim.entry,
        "provider_running",
        %{execution_target: "recorded-target"},
        settings
      )

    assert {:ok, running} = Projection.lab_conversation(@conversation_id)
    assert [observed] = running.admission_progress
    assert observed.phase == "Provider running"
    assert observed.target == "recorded-target"
    assert observed.generation == 1
    assert observed.claims == 1
    refute inspect(running.admission_progress) =~ claim.lease_ref
  end

  # An attachment-only message is allowed, and its text is the empty string.
  # Admission progress named the row after that text, so the queue beside the
  # message showed a blank title where "Incoming event" belonged.
  test "an attachment-only message's admission progress still has a title" do
    assert {:ok, _receipt} =
             ConversationLab.send_message(@conversation_id, "", profile(),
               attachments: [%{data: "first", media_type: "text/plain", name: "note.txt"}]
             )

    assert {:ok, queued} = Projection.lab_conversation(@conversation_id)
    assert [waiting] = queued.admission_progress
    assert waiting.title == "Incoming event"
  end

  test "a Lab incident offer starts a linked local incident with the configured chat authority" do
    conversation_ref = "control-plane:lab:#{@conversation_id}"
    source_episode_id = Ecto.UUID.generate()
    source_turn_ref = "turn:conversation-lab:incident-source:#{source_episode_id}"

    assert {:ok, source} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: conversation_ref,
                   thread_ref: conversation_ref,
                   transport: "control_plane"
                 },
                 episode_id: source_episode_id,
                 episode_key: "conversation-lab:incident-source:#{@conversation_id}",
                 native_input_id: "control-plane-message:incident-source",
                 occurred_at: @now,
                 payload: %{"text" => "Investigate the current service incident."},
                 turn_ref: source_turn_ref
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(
               source.episode.id,
               profile().policy,
               profile().policy_digest
             )

    assert {:ok, claim} = Custody.claim_next("conversation-lab:incident-offer", 60, :work)
    assert {:ok, submission} = SubmissionBuilder.build(claim)

    assert {:ok, _turn} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:conversation-lab-incident-source"
             )

    assert {:ok, _turn} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:conversation-lab-incident-source"
             )

    assert {:ok, incident_offer} =
             Records.create(Records.token(claim.turn), "lab-incident", "task_offer", %{
               "kind" => "incident",
               "prompt" =>
                 "Inspect current evidence, contain impact, and report verified status.",
               "repository" => nil,
               "title" => "Investigate service health"
             })

    document = %{
      "message" => "I prepared a local incident investigation for confirmation.",
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [incident_offer.ref],
        "state" => "complete"
      }
    }

    candidate = Jason.encode!(document)
    sha256 = :crypto.hash(:sha256, candidate) |> Base.encode16(case: :lower)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               sha256,
               1
             )

    assert {:ok, result} = Result.new(:reply, document)

    assert {:ok, _turn} =
             Custody.prepare_validation(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               "validation-receipt:conversation-lab-incident"
             )

    assert {:ok, delivery_claim} =
             Custody.claim_next("conversation-lab:incident-offer-delivery", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               "control_plane",
               conversation_ref,
               conversation_ref,
               "control-plane-message:lab-incident-offer"
             )

    assert {:ok, _settled} =
             Custody.confirm_delivery(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               delivery_claim.lease_ref,
               receipt
             )

    assert {:ok, before_confirmation} = Projection.lab_conversation(@conversation_id)
    [offer_card] = before_confirmation.messages |> List.last() |> Map.fetch!(:cards)
    assert offer_card.label == "Local incident"
    assert offer_card.action == :open_incident

    actions = Actions.callbacks(profile(), %{})

    assert {:ok, confirmation} =
             actions.act_on_lab_record.(
               @conversation_id,
               incident_offer.ref,
               :open_incident,
               nil
             )

    assert confirmation.status == :confirmed
    assert confirmation.episode.linked_episode_id == source.episode.id
    assert confirmation.episode.destination_transport == "control_plane"
    assert confirmation.episode.destination_conversation_ref == conversation_ref
    assert confirmation.episode.destination_thread_ref == conversation_ref
    assert confirmation.session.policy == profile().policy
    assert confirmation.session.policy_digest == profile().policy_digest
    assert confirmation.session.repository_ref == nil

    assert {:ok, after_confirmation} = Projection.lab_conversation(@conversation_id)
    [incident_card] = after_confirmation.messages |> List.last() |> Map.fetch!(:cards)
    assert incident_card.label == "Local incident"
    assert incident_card.kind == "task"
    # Same: the linked incident episode has no turn yet at this point.
    assert incident_card.status == "queued"
    assert :view_postmortem in incident_card.actions

    assert {:ok, postmortem} =
             actions.view_lab_task_record.(
               @conversation_id,
               incident_offer.ref,
               :postmortem,
               %{}
             )

    assert postmortem.title == "Incident postmortem"
    assert postmortem.body =~ "Postmortem draft"
    assert postmortem.body =~ "human review is required"
  end

  test "Lab edits and deletes are ordered revisions of one durable source item" do
    edited_event_id = "018f3ef7-1f62-7ee0-a83c-0c12f21d83e8"
    deleted_event_id = "018f3ef7-1f62-7ee0-a83c-0c12f21d83e9"

    assert {:ok, %{entry: original}} =
             ConversationLab.send_message(
               @conversation_id,
               "Inspect the old service name.",
               profile(),
               id_generator: fn -> @event_id end,
               now: fn -> @now end
             )

    assert {:ok, %{entry: edited}} =
             ConversationLab.edit_message(
               @conversation_id,
               @event_id,
               "Inspect the renamed service and keep the attachment scope.",
               profile(),
               id_generator: fn -> edited_event_id end,
               now: fn -> DateTime.add(@now, 1, :second) end
             )

    assert {:ok, %{entry: deleted}} =
             ConversationLab.delete_message(
               @conversation_id,
               @event_id,
               profile(),
               id_generator: fn -> deleted_event_id end,
               now: fn -> DateTime.add(@now, 2, :second) end
             )

    assert Enum.map([original, edited, deleted], & &1.event_kind) == [:message, :edit, :delete]
    assert Enum.map([original, edited, deleted], & &1.revision) == [1, 2, 3]

    assert Enum.uniq(Enum.map([original, edited, deleted], & &1.native_input_id)) == [
             "control-plane-message:#{@event_id}"
           ]

    assert Enum.uniq(Enum.map([original, edited, deleted], & &1.source_item_ref)) == [
             "control-plane-item:#{@event_id}"
           ]

    assert edited.content == %{
             "text" => "Inspect the renamed service and keep the attachment scope."
           }

    assert edited.source_capabilities == original.source_capabilities
    assert deleted.content == %{"text" => edited.content["text"]}
    assert deleted.source_capabilities == %{}

    native_input_id = original.native_input_id

    assert Repo.all(
             from(entry in Entry,
               where: entry.native_input_id == ^native_input_id,
               order_by: entry.revision,
               select: entry.event_ref
             )
           ) == [
             "control-plane-event:#{@event_id}",
             "control-plane-event:#{edited_event_id}",
             "control-plane-event:#{deleted_event_id}"
           ]

    assert ConversationLab.edit_message(
             @conversation_id,
             @event_id,
             "A deleted message cannot be resurrected.",
             profile()
           ) == {:error, {:invalid_conversation_lab, :message_deleted}}
  end

  test "each projected message carries the exact provenance its inspection link needs" do
    # lab_inputs/1 selected Entry.id and then dropped it; lab_reply_message/4
    # dropped episode_id and turn_id. Without them the page could only guess a
    # target from the newest episode, which is wrong for any message routed
    # into an earlier one. The id is the current revision's, so an edit that is
    # still pending admission links its own request, not the original's.
    assert {:ok, %{entry: original}} =
             ConversationLab.send_message(
               @conversation_id,
               "Which revision is this?",
               profile(),
               id_generator: fn -> @event_id end,
               now: fn -> @now end
             )

    assert {:ok, sent} = Projection.lab_conversation(@conversation_id)
    assert [message] = sent.messages
    assert message.input_id == original.id
    assert message.native_input_id == original.native_input_id
    assert message.episode_id == nil
    assert message.decision_action == nil
    assert [%{id: progress_id, native_input_id: progress_input}] = sent.admission_progress
    assert progress_id == original.id
    assert progress_input == original.native_input_id

    assert {:ok, %{entry: edited}} =
             ConversationLab.edit_message(
               @conversation_id,
               @event_id,
               "Which revision is this, exactly?",
               profile(),
               id_generator: fn -> Ecto.UUID.generate() end,
               now: fn -> DateTime.add(@now, 1, :second) end
             )

    assert edited.id != original.id
    assert {:ok, revised} = Projection.lab_conversation(@conversation_id)
    assert [%{input_id: input_id, native_input_id: native_input_id}] = revised.messages
    assert input_id == edited.id
    assert native_input_id == original.native_input_id
  end

  test "the Lab projects only the current revision of an edited or deleted message" do
    assert {:ok, %{entry: _original}} =
             ConversationLab.send_message(
               @conversation_id,
               "Original wording",
               profile(),
               id_generator: fn -> @event_id end,
               now: fn -> @now end
             )

    assert {:ok, %{entry: _edited}} =
             ConversationLab.edit_message(
               @conversation_id,
               @event_id,
               "Corrected wording",
               profile(),
               id_generator: fn -> Ecto.UUID.generate() end,
               now: fn -> DateTime.add(@now, 1, :second) end
             )

    assert {:ok, edited} = Projection.lab_conversation(@conversation_id)
    assert [%{actor: :operator} = message] = edited.messages
    assert message.text == "Corrected wording"
    assert message.event_kind == :edit
    assert message.item_id == @event_id
    assert message.editable == true
    assert Enum.all?(edited.admission_progress, &(&1.title == "Corrected wording"))
    assert [%{message_count: 1, title: "Corrected wording"}] = Projection.lab_index()

    assert Enum.all?(
             Activity.list(%{}).items,
             &(&1.title == "Corrected wording")
           )

    assert {:ok, %{entry: _deleted}} =
             ConversationLab.delete_message(
               @conversation_id,
               @event_id,
               profile(),
               id_generator: fn -> Ecto.UUID.generate() end,
               now: fn -> DateTime.add(@now, 2, :second) end
             )

    assert {:ok, deleted} = Projection.lab_conversation(@conversation_id)
    assert [%{actor: :operator} = message] = deleted.messages
    assert message.text == "Message deleted"
    assert message.event_kind == :delete
    assert message.editable == false
    assert message.attachments == []
    assert Enum.all?(deleted.admission_progress, &(&1.title == "Message deleted"))
    assert [%{message_count: 1, title: "Message deleted"}] = Projection.lab_index()

    assert Enum.all?(
             Activity.list(%{}).items,
             &(&1.title == "Message deleted")
           )
  end

  test "the Lab reports queue custody across every message revision" do
    assert {:ok, %{entry: original}} =
             ConversationLab.send_message(
               @conversation_id,
               "Original request",
               profile(),
               id_generator: fn -> @event_id end,
               now: fn -> @now end
             )

    assert {:ok, %{entry: _edited}} =
             ConversationLab.edit_message(
               @conversation_id,
               @event_id,
               "Corrected request",
               profile(),
               id_generator: fn -> Ecto.UUID.generate() end,
               now: fn -> DateTime.add(@now, 1, :second) end
             )

    assert {:ok, claim} =
             Inbox.claim_next(
               "conversation-lab:revision-custody",
               DateTime.add(@now, 2, :second),
               60
             )

    assert claim.entry.id == original.id

    assert {:ok, _blocked} =
             Inbox.block(
               Inbox.ref(original),
               claim.lease_ref,
               "test_blocked_revision",
               "The older revision needs operator reconciliation."
             )

    assert {:ok, conversation} = Projection.lab_conversation(@conversation_id)
    assert conversation.blocked
    assert conversation.live
    assert conversation.pending == 1
    assert [%{actor: :operator, text: "Corrected request", revision: 2}] = conversation.messages
  end

  test "a reaction to an earlier revision remains attached to the current Lab message" do
    assert {:ok, %{entry: original}} =
             ConversationLab.send_message(
               @conversation_id,
               "Please acknowledge this request.",
               profile(),
               id_generator: fn -> @event_id end,
               now: fn -> @now end
             )

    assert {:ok, context} =
             Admission.context(Inbox.ref(original),
               now: DateTime.add(@now, 1, :second),
               continuation_window: 30 * 60,
               history_window: 30 * 24 * 60 * 60,
               candidate_limit: 8,
               lease_ref: nil
             )

    assert {:ok, decision} =
             Decision.parse(%{
               "action" => "react",
               "episode_ref" => nil,
               "reaction" => %{"emoji_name" => "eyes"},
               "relation" => "unrelated",
               "repository_source" => nil,
               "reason" => "A nonverbal acknowledgement is sufficient.",
               "work_class" => nil
             })

    assert {:ok, _applied} = Admission.commit(context, decision, "decision:lab-reaction")

    assert {:ok, %{entry: _edited}} =
             ConversationLab.edit_message(
               @conversation_id,
               @event_id,
               "Please acknowledge the corrected request.",
               profile(),
               id_generator: fn -> Ecto.UUID.generate() end,
               now: fn -> DateTime.add(@now, 2, :second) end
             )

    assert {:ok, conversation} = Projection.lab_conversation(@conversation_id)

    assert [message] = conversation.messages
    assert message.text == "Please acknowledge the corrected request."
    assert [%{emoji_name: "eyes", status: :pending}] = message.reactions
  end

  test "invalid conversation IDs and empty or oversized messages fail before persistence" do
    assert ConversationLab.send_message("not-a-uuid", "hello", profile()) ==
             {:error, {:invalid_conversation_lab, :conversation_id}}

    assert ConversationLab.send_message(@conversation_id, "   ", profile()) ==
             {:error, {:invalid_conversation_lab, :message}}

    assert ConversationLab.send_message(
             @conversation_id,
             String.duplicate("x", 20_001),
             profile()
           ) == {:error, {:invalid_conversation_lab, :message}}
  end

  test "local attachments use the same immutable artifact path as platform chat" do
    assert {:ok, %{status: :recorded, entry: entry}} =
             ConversationLab.send_message(
               @conversation_id,
               "Read both attached files before answering.",
               profile(),
               attachments: [
                 %{
                   data: "first line\nsecond line\n",
                   media_type: "text/plain",
                   name: "notes.txt"
                 },
                 %{
                   data: ~s({"service":"emisar","healthy":true}),
                   media_type: "application/json",
                   name: "status.json"
                 }
               ],
               id_generator: fn -> @event_id end,
               now: fn -> @now end
             )

    assert %{"files" => files, "text" => "Read both attached files before answering."} =
             entry.content

    assert Enum.map(files, &Map.take(&1, ["bytes", "media_type", "name", "status"])) == [
             %{
               "bytes" => 23,
               "media_type" => "text/plain",
               "name" => "notes.txt",
               "status" => "available"
             },
             %{
               "bytes" => 35,
               "media_type" => "application/json",
               "name" => "status.json",
               "status" => "available"
             }
           ]

    refs = Enum.map(files, & &1["artifact_ref"])
    assert {:ok, artifacts} = Artifacts.fetch_many(refs)

    assert Enum.map(artifacts, &{&1.name, &1.data}) == [
             {"notes.txt", "first line\nsecond line\n"},
             {"status.json", ~s({"service":"emisar","healthy":true})}
           ]

    assert {:ok, conversation} = Projection.lab_conversation(@conversation_id)
    assert [%{attachments: projected}] = conversation.messages

    assert Enum.map(projected, &Map.take(&1, [:bytes, :media_type, :name, :status])) == [
             %{bytes: 23, media_type: "text/plain", name: "notes.txt", status: "available"},
             %{
               bytes: 35,
               media_type: "application/json",
               name: "status.json",
               status: "available"
             }
           ]

    assert ConversationLab.send_message(@conversation_id, "too many", profile(),
             attachments:
               Enum.map(1..3, fn index ->
                 %{data: "file #{index}", media_type: "text/plain", name: "#{index}.txt"}
               end)
           ) == {:error, {:invalid_conversation_lab, :attachments}}
  end

  test "attachment validation and ingress conflicts roll back as one durable submission" do
    unsupported = %{
      data: "executable bytes",
      media_type: "application/octet-stream",
      name: "payload.bin"
    }

    assert ConversationLab.send_message(@conversation_id, "Inspect it", profile(),
             attachments: [unsupported]
           ) == {:error, {:invalid_conversation_lab, :attachments}}

    assert Repo.aggregate(Artifact, :count) == 0

    options = [
      attachments: [%{data: "first", media_type: "text/plain", name: "note.txt"}],
      id_generator: fn -> @event_id end,
      now: fn -> @now end
    ]

    assert {:ok, %{status: :recorded}} =
             ConversationLab.send_message(@conversation_id, "Read it", profile(), options)

    changed =
      Keyword.replace(options, :attachments, [
        %{data: "changed", media_type: "text/plain", name: "note.txt"}
      ])

    assert ConversationLab.send_message(@conversation_id, "Read it", profile(), changed) ==
             {:error, {:invalid_conversation_lab, :attachments}}

    assert Repo.aggregate(Artifact, :count) == 1
  end

  test "local routing and generators fail closed without widening the configured profile" do
    assert ConversationLab.conversation_ref(@conversation_id) ==
             {:ok, "control-plane:lab:#{@conversation_id}"}

    assert ConversationLab.conversation_ref("not-a-uuid") ==
             {:error, {:invalid_conversation_lab, :conversation_id}}

    assert ConversationLab.send_message(@conversation_id, "hello", %{}) ==
             {:error, {:invalid_conversation_lab, :work_profile}}

    assert ConversationLab.send_message(@conversation_id, "contains\0null", profile()) ==
             {:error, {:invalid_conversation_lab, :message}}

    for invalid_options <- [
          :not_options,
          [unknown: true],
          [now: fn -> @now end, now: fn -> @now end],
          [id_generator: :not_a_function],
          [now: :not_a_function]
        ] do
      assert ConversationLab.send_message(
               @conversation_id,
               "hello",
               profile(),
               invalid_options
             ) == {:error, {:invalid_conversation_lab, :options}}
    end

    assert ConversationLab.send_message(@conversation_id, "hello", profile(),
             id_generator: fn -> "not-a-uuid" end
           ) == {:error, {:invalid_conversation_lab, :event_id}}

    assert ConversationLab.send_message(@conversation_id, "hello", profile(),
             now: fn -> ~N[2026-08-30 18:00:00] end
           ) == {:error, {:invalid_conversation_lab, :now}}
  end

  test "the lab projects only its durable operator inputs and accepted visible replies" do
    assert {:ok, %{status: :recorded}} =
             ConversationLab.send_message(
               @conversation_id,
               "What changed in this conversation?",
               profile(),
               id_generator: fn -> @event_id end,
               now: fn -> @now end
             )

    conversation_ref = "control-plane:lab:#{@conversation_id}"
    episode_id = Ecto.UUID.generate()
    turn_ref = "turn:conversation-lab:#{episode_id}"

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 actor_ref: ConversationLab.operator_actor_ref(),
                 destination: %{
                   conversation_ref: conversation_ref,
                   thread_ref: conversation_ref,
                   transport: "control_plane"
                 },
                 episode_id: episode_id,
                 episode_key: "conversation-lab:#{@conversation_id}",
                 native_input_id: "control-plane-message:projected",
                 occurred_at: @now,
                 payload: %{"text" => "What changed in this conversation?"},
                 turn_ref: turn_ref
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(
               transition.episode.id,
               profile().policy,
               profile().policy_digest
             )

    assert {:ok, claim} = Custody.claim_next("conversation-lab:projection", 60, :work)
    assert {:ok, submission} = SubmissionBuilder.build(claim)

    assert {:ok, _turn} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:conversation-lab"
             )

    assert {:ok, _turn} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:conversation-lab"
             )

    assert {:ok, task_offer} =
             Records.create(Records.token(claim.turn), "lab-task", "task_offer", %{
               "kind" => "engineering",
               "prompt" => "Implement the approved Conversation Lab parity slice.",
               "repository" => "ryker",
               "title" => "Finish Lab parity"
             })

    assert {:ok, memory_offer} =
             Records.create(Records.token(claim.turn), "lab-memory", "memory_offer", %{
               "expires_in" => "90d",
               "kind" => "alias",
               "repository" => nil,
               "scope" => "conversation",
               "subject" => "primary service",
               "value" => "The API is the primary service in this conversation.",
               "visibility" => "conversation"
             })

    assert {:ok, schedule_offer} =
             Records.create(Records.token(claim.turn), "lab-schedule", "schedule_offer", %{
               "authority" => "read_only",
               "expires_at" => nil,
               "recurrence" => %{"kind" => "daily", "time" => "09:00:00"},
               "repository" => nil,
               "task" => "Review the current Emisar workspace health.",
               "timezone" => "Etc/UTC",
               "title" => "Daily Emisar health"
             })

    assert {:ok, preference_offer} =
             Records.create(
               Records.token(claim.turn),
               "lab-preference",
               "preference_offer",
               %{
                 "expires_in" => "90d",
                 "key" => "response_detail",
                 "repository" => nil,
                 "scope" => "operator",
                 "value" => "detailed"
               }
             )

    early_actions =
      Actions.callbacks(profile(), %{
        "ryker" => %{
          name: "ryker-contributor",
          digest: @task_policy_digest
        }
      })

    assert early_actions.act_on_lab_record.(
             @conversation_id,
             task_offer.ref,
             :confirm_task,
             nil
           ) == {:error, :conversation_lab_record_mismatch}

    delivery_document = %{
      "message" => "The durable path is working.",
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [
          task_offer.ref,
          memory_offer.ref,
          schedule_offer.ref,
          preference_offer.ref
        ],
        "state" => "complete"
      }
    }

    candidate = Jason.encode!(delivery_document)
    sha256 = :crypto.hash(:sha256, candidate) |> Base.encode16(case: :lower)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               sha256,
               1
             )

    assert {:ok, result} = Result.new(:reply, delivery_document)

    assert {:ok, _turn} =
             Custody.prepare_validation(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               "validation-receipt:conversation-lab"
             )

    assert [%{id: @conversation_id, message_count: 1}] = Projection.lab_index()

    assert {:ok, conversation} = Projection.lab_conversation(@conversation_id)
    assert conversation.live
    assert conversation.pending == 1

    assert Enum.map(conversation.messages, &{&1.actor, &1.text}) == [
             {:operator, "What changed in this conversation?"},
             {:ryker, "The durable path is working."}
           ]

    ryker = Enum.find(conversation.messages, &(&1.actor == :ryker))
    # The reply names the turn that produced it and that turn's episode, so its
    # inspection link cannot drift to a newer episode of the same conversation.
    assert ryker.turn_id == accepted.turn.id
    assert ryker.episode_ref == transition.episode.key

    assert Enum.map(ryker.cards, &{&1.kind, &1.ref}) == [
             {"task_offer", task_offer.ref},
             {"memory_offer", memory_offer.ref},
             {"schedule_offer", schedule_offer.ref},
             {"preference_offer", preference_offer.ref}
           ]

    assert [task_card, memory_card, schedule_card, preference_card] = ryker.cards
    assert task_card.title == "Finish Lab parity"
    assert task_card.action == :confirm_task
    assert {"Repository", "ryker"} in task_card.details
    assert memory_card.title == "primary service"
    assert memory_card.action == :confirm_memory
    assert memory_card.summary == "The API is the primary service in this conversation."
    assert schedule_card.action == :confirm_schedule
    assert schedule_card.title == "Daily Emisar health"
    assert preference_card.action == :confirm_behavior
    assert preference_card.title == "Response detail"

    assert {:ok, delivery_claim} =
             Custody.claim_next("conversation-lab:projection-delivery", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               "control_plane",
               conversation_ref,
               conversation_ref,
               "control-plane-message:lab-projection"
             )

    assert {:ok, _settled} =
             Custody.confirm_delivery(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               delivery_claim.lease_ref,
               receipt
             )

    reaction_event_id = Ecto.UUID.generate()

    reaction_options = [
      id_generator: fn -> reaction_event_id end,
      now: fn -> DateTime.add(@now, 4, :second) end
    ]

    turn_count = Repo.aggregate(Ryker.Work.Turn, :count)

    assert {:ok, reaction} =
             ConversationLab.react_to_message(
               @conversation_id,
               "control-plane-message:lab-projection",
               :add,
               "heart",
               reaction_options
             )

    assert reaction.event.kind == :reaction_recorded
    assert reaction.episode.owner_kind == nil
    assert reaction.episode.state == :complete
    assert Repo.aggregate(Ryker.Work.Turn, :count) == turn_count

    assert {:ok, duplicate_reaction} =
             ConversationLab.react_to_message(
               @conversation_id,
               "control-plane-message:lab-projection",
               :add,
               "heart",
               reaction_options
             )

    assert duplicate_reaction.status == :duplicate

    assert {:ok, reacted_conversation} = Projection.lab_conversation(@conversation_id)

    assert [%{actor_ref: "control-plane:user:local-operator", emoji_name: "heart"}] =
             reacted_conversation.messages
             |> Enum.find(&(&1.actor == :ryker))
             |> Map.fetch!(:feedback_reactions)

    assert {:ok, removed} =
             ConversationLab.react_to_message(
               @conversation_id,
               "control-plane-message:lab-projection",
               :remove,
               "heart",
               id_generator: &Ecto.UUID.generate/0,
               now: fn -> DateTime.add(@now, 5, :second) end
             )

    assert removed.event.payload["action"] == "remove"
    assert {:ok, unreacted_conversation} = Projection.lab_conversation(@conversation_id)

    assert [] ==
             unreacted_conversation.messages
             |> Enum.find(&(&1.actor == :ryker))
             |> Map.fetch!(:feedback_reactions)

    assert ConversationLab.react_to_message(
             @conversation_id,
             "control-plane-message:missing",
             :add,
             "eyes"
           ) == {:error, :conversation_reaction_target_not_found}

    actions =
      Actions.callbacks(profile(), %{
        "ryker" => %{
          name: "ryker-contributor",
          digest: @task_policy_digest
        }
      })

    assert actions.act_on_lab_record.(
             @conversation_id,
             "record:missing",
             :confirm_memory,
             nil
           ) == {:error, :conversation_lab_record_not_found}

    assert actions.act_on_lab_record.(
             @conversation_id,
             task_offer.ref,
             :confirm_task,
             1
           ) == {:error, :conversation_lab_record_action_invalid}

    assert Actions.callbacks(profile(), %{}).act_on_lab_record.(
             @conversation_id,
             task_offer.ref,
             :confirm_task,
             nil
           ) == {:error, :conversation_lab_task_policy_not_configured}

    assert actions.act_on_lab_record.(
             @conversation_id,
             memory_offer.ref,
             :confirm_schedule,
             nil
           ) == {:error, :conversation_lab_record_action_mismatch}

    assert actions.act_on_lab_record.(
             "018f3ef7-1f62-7ee0-a83c-0c12f21d83e7",
             task_offer.ref,
             :confirm_task,
             nil
           ) == {:error, :conversation_lab_record_mismatch}

    assert {:ok, confirmation} =
             actions.act_on_lab_record.(
               @conversation_id,
               task_offer.ref,
               :confirm_task,
               nil
             )

    assert confirmation.status == :confirmed
    assert confirmation.episode.linked_episode_id == claim.episode.id
    assert confirmation.episode.destination_transport == "control_plane"
    assert confirmation.episode.destination_conversation_ref == conversation_ref
    assert confirmation.episode.destination_thread_ref == conversation_ref

    assert %Session{
             policy: "ryker-contributor",
             policy_digest: @task_policy_digest,
             repository_ref: "ryker"
           } = confirmation.session

    assert {:ok, updated_conversation} = Projection.lab_conversation(@conversation_id)
    updated_ryker = Enum.find(updated_conversation.messages, &(&1.actor == :ryker))

    assert [task_status, _memory_offer, _schedule_offer, _preference_offer] =
             updated_ryker.cards

    assert task_status.kind == "task"
    # A confirmed task with no turn yet is queued; it was reported as working
    # until 2026-09-12.
    assert task_status.status == "queued"
    assert task_status.title == "Finish Lab parity"
    assert task_status.summary =~ "Conversation Lab parity"
    assert {"Repository", "ryker"} in task_status.details
    assert {"Session", "1"} in task_status.details
    assert task_status.action == nil

    assert {:ok, remembered} =
             actions.act_on_lab_record.(
               @conversation_id,
               memory_offer.ref,
               :confirm_memory,
               nil
             )

    assert remembered.status == :confirmed
    assert remembered.memory.scope_ref == conversation_ref

    assert remembered.memory.payload["value"] ==
             "The API is the primary service in this conversation."

    assert {:ok, scheduled} =
             actions.act_on_lab_record.(
               @conversation_id,
               schedule_offer.ref,
               :confirm_schedule,
               nil
             )

    assert scheduled.status == :confirmed
    assert %Schedule{} = scheduled.schedule
    assert scheduled.schedule.destination_transport == "control_plane"
    assert scheduled.schedule.destination_conversation_ref == conversation_ref
    assert scheduled.schedule.destination_thread_ref == conversation_ref
    assert scheduled.schedule.authority == :read_only

    assert {:ok, preferred} =
             actions.act_on_lab_record.(
               @conversation_id,
               preference_offer.ref,
               :confirm_behavior,
               nil
             )

    assert preferred.status == :confirmed
    assert %Behavior{} = preferred.behavior
    assert preferred.behavior.scope_kind == :operator
    assert preferred.behavior.scope_ref == ConversationLab.operator_actor_ref()
    assert preferred.behavior.confirmed_by_actor_ref == ConversationLab.operator_actor_ref()
    assert preferred.behavior.payload["value"] == "detailed"

    assert {:ok, duplicate} =
             actions.act_on_lab_record.(
               @conversation_id,
               task_offer.ref,
               :confirm_task,
               nil
             )

    assert duplicate.status == :duplicate

    assert {:ok, task_claim} = Custody.claim_next("conversation-lab:task-work", 60, :work)
    assert task_claim.episode.id == confirmation.episode.id

    assert {:ok, _evidence} =
             Records.create(Records.token(task_claim.turn), "lab-task-evidence", "evidence", %{
               "claim_id" => "conversation-lab.parity",
               "confidence" => "high",
               "observation" => "The confirmed task retained its exact child episode.",
               "source_name" => "Conversation Lab host test",
               "source_type" => "repository"
             })

    patch = "diff --git a/lib/ryker.ex b/lib/ryker.ex\n+task view\n"
    page_boundary = byte_size(patch) - 1

    first_page =
      patch
      |> workspace_changes()
      |> Map.merge(%{
        "patch" => Base.encode64(binary_part(patch, 0, page_boundary)),
        "patch_has_more" => true,
        "patch_next_offset" => page_boundary
      })

    final_page =
      patch
      |> workspace_changes()
      |> Map.merge(%{
        "patch" => Base.encode64(binary_part(patch, page_boundary, 1)),
        "patch_offset" => page_boundary
      })

    coop =
      start_supervised!(%{
        id: {:conversation_lab_task_view, Ecto.UUID.generate()},
        start:
          {FakeWorkCoopAPI, :start_link, [[], [changes: [first_page, final_page, first_page]]]}
      })

    remote_id = FakeWorkCoopAPI.state(coop).session["id"]

    unbound_view =
      Actions.callbacks(
        profile(),
        %{},
        %{coop_api: FakeWorkCoopAPI, coop_client: coop}
      ).view_lab_task_record

    assert unbound_view.(
             @conversation_id,
             task_offer.ref,
             :diff,
             %{offset: 0, snapshot_digest: nil}
           ) == {:error, :conversation_lab_work_changes_not_available}

    assert {:ok, _bound_task_session} =
             Custody.bind_session(
               task_claim.episode.id,
               task_claim.turn.turn_ref,
               task_claim.lease_ref,
               task_claim.session.generation,
               task_claim.session.create_generation,
               remote_id
             )

    view_actions =
      Actions.callbacks(
        profile(),
        %{
          "ryker" => %{
            name: "ryker-contributor",
            digest: @task_policy_digest
          }
        },
        %{coop_api: FakeWorkCoopAPI, coop_client: coop}
      )

    assert {:ok, working_conversation} = Projection.lab_conversation(@conversation_id)
    working_ryker = Enum.find(working_conversation.messages, &(&1.actor == :ryker))

    assert [working_task, _memory_offer, _schedule_offer, _preference_offer] =
             working_ryker.cards

    assert working_task.actions == [
             :stop_task,
             :view_diff,
             :close_task,
             :view_timeline,
             :view_evidence,
             :view_handoff
           ]

    assert {:ok, timeline} =
             view_actions.view_lab_task_record.(
               @conversation_id,
               task_offer.ref,
               :timeline,
               %{}
             )

    assert timeline.title == "Task timeline"
    assert timeline.body =~ "Input admitted"
    assert timeline.navigation == []

    assert {:ok, evidence} =
             view_actions.view_lab_task_record.(
               @conversation_id,
               task_offer.ref,
               :evidence,
               %{}
             )

    assert evidence.title == "Task evidence"
    assert evidence.body =~ "The confirmed task retained its exact child episode."

    assert {:ok, handoff} =
             view_actions.view_lab_task_record.(
               @conversation_id,
               task_offer.ref,
               :handoff,
               %{}
             )

    assert handoff.title == "Task handoff"
    assert handoff.body =~ task_offer.ref
    assert handoff.body =~ "State: working"

    assert view_actions.view_lab_task_record.(
             @conversation_id,
             memory_offer.ref,
             :timeline,
             %{}
           ) == {:error, :conversation_lab_task_mismatch}

    assert view_actions.view_lab_task_record.(
             @conversation_id,
             task_offer.ref,
             :unknown,
             %{}
           ) == {:error, :conversation_lab_task_view_invalid}

    assert view_actions.view_lab_task_record.(
             @conversation_id,
             task_offer.ref,
             :diff,
             %{offset: -1, snapshot_digest: nil}
           ) == {:error, :conversation_lab_task_view_invalid}

    unconfigured_views = Actions.callbacks(profile()).view_lab_task_record

    assert unconfigured_views.(
             @conversation_id,
             task_offer.ref,
             :diff,
             %{offset: 0, snapshot_digest: nil}
           ) == {:error, :conversation_lab_work_changes_not_configured}

    assert {:ok, diff} =
             view_actions.view_lab_task_record.(
               @conversation_id,
               task_offer.ref,
               :diff,
               %{offset: 0, snapshot_digest: nil}
             )

    assert diff.title == "Workspace diff"
    assert diff.body =~ "+task view"
    assert diff.body =~ workspace_changes(patch)["patch_digest"]

    assert diff.navigation == [
             %{
               label: "Next",
               offset: page_boundary,
               snapshot_digest: workspace_changes(patch)["patch_digest"]
             }
           ]

    assert {:ok, final_diff} =
             view_actions.view_lab_task_record.(
               @conversation_id,
               task_offer.ref,
               :diff,
               %{
                 offset: page_boundary,
                 snapshot_digest: workspace_changes(patch)["patch_digest"]
               }
             )

    assert final_diff.navigation == [
             %{
               label: "Previous",
               offset: 0,
               snapshot_digest: workspace_changes(patch)["patch_digest"]
             }
           ]

    assert view_actions.view_lab_task_record.(
             @conversation_id,
             task_offer.ref,
             :diff,
             %{offset: 0, snapshot_digest: String.duplicate("f", 64)}
           ) == {:error, :work_diff_snapshot_changed}

    assert FakeWorkCoopAPI.state(coop).changes_page_requests == [
             {remote_id, 0, WorkChanges.page_bytes()},
             {remote_id, page_boundary, WorkChanges.page_bytes()},
             {remote_id, 0, WorkChanges.page_bytes()}
           ]

    assert view_actions.view_lab_task_record.(
             "018f3ef7-1f62-7ee0-a83c-0c12f21d83e7",
             task_offer.ref,
             :timeline,
             %{}
           ) == {:error, :conversation_lab_record_mismatch}

    assert {:ok, stopping} =
             actions.act_on_lab_record.(
               @conversation_id,
               task_offer.ref,
               :stop_task,
               nil
             )

    assert stopping.status == :pending
    assert stopping.turn.status == :cancel_pending

    refute inspect(conversation) =~ candidate
    assert Projection.lab_conversation("not-a-uuid") == :not_found
  end

  test "blocked work stops live polling and tells the operator it needs attention" do
    conversation_ref = "control-plane:lab:#{@conversation_id}"
    episode_id = Ecto.UUID.generate()
    turn_ref = "turn:conversation-lab:blocked:#{episode_id}"

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: conversation_ref,
                   thread_ref: conversation_ref,
                   transport: "control_plane"
                 },
                 episode_id: episode_id,
                 episode_key: "conversation-lab:blocked:#{@conversation_id}",
                 native_input_id: "control-plane-message:blocked",
                 occurred_at: @now,
                 payload: %{"text" => "Check the current infrastructure health."},
                 turn_ref: turn_ref
               })
             )

    assert {:ok, session} =
             Custody.pin_episode(
               transition.episode.id,
               profile().policy,
               profile().policy_digest
             )

    assert {:ok, claim} = Custody.claim_next("conversation-lab:blocked", 60, :work)

    assert {:ok, %{status: :pending}} =
             Custody.request_block(
               transition.episode.id,
               transition.episode.key,
               turn_ref,
               claim.lease_ref,
               "manual recovery required"
             )

    assert {:ok, cancellation_claim} =
             Custody.claim_next("conversation-lab:blocked-cancellation", 60, :work)

    assert {:ok, cancellation_receipt} =
             Cancellation.absent_receipt(
               "ryker:work:create:#{session.id}:g#{session.create_generation}",
               nil,
               nil,
               nil,
               nil
             )

    assert {:ok, %{turn: %{status: :blocked}}} =
             Custody.settle_cancellation(
               transition.episode.id,
               transition.episode.key,
               turn_ref,
               cancellation_claim.lease_ref,
               cancellation_receipt
             )

    assert {:ok, conversation} = Projection.lab_conversation(@conversation_id)
    assert conversation.blocked
    refute conversation.live
    assert [%{next_action: "operator_recovery", work_status: :blocked}] = conversation.episodes
  end

  test "an event wait keeps the Lab live until its asynchronous trigger settles" do
    conversation_ref = "control-plane:lab:#{@conversation_id}"
    episode_id = Ecto.UUID.generate()
    turn_ref = "turn:conversation-lab:event-wait:#{episode_id}"

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: conversation_ref,
                   thread_ref: conversation_ref,
                   transport: "control_plane"
                 },
                 episode_id: episode_id,
                 episode_key: "conversation-lab:event-wait:#{@conversation_id}",
                 native_input_id: "control-plane-message:event-wait",
                 occurred_at: @now,
                 payload: %{"text" => "Wait for the exact verification event."},
                 turn_ref: turn_ref
               })
             )

    assert {:ok, _waiting} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 deadline_at: DateTime.add(@now, 600, :second),
                 episode_key: transition.episode.key,
                 expected_turn_ref: turn_ref,
                 kind: :event,
                 wait_ref: "wait:event:#{episode_id}"
               })
             )

    assert {:ok, conversation} = Projection.lab_conversation(@conversation_id)
    assert conversation.live
    assert [%{next_action: "external_event", state: :waiting_for_event}] = conversation.episodes
  end

  test "the Lab opens on its latest page and every older message stays reachable" do
    # Until 2026-09-13 this test pinned a 200-message window; message 0 of a
    # 201-message conversation was simply gone from the page. The page is now
    # a window with a boundary cursor, never a cap on retained history.
    Enum.each(0..200, fn index ->
      assert {:ok, %{status: :recorded}} =
               ConversationLab.send_message(
                 @conversation_id,
                 "Bounded transcript message #{index}",
                 profile(),
                 id_generator: fn -> Ecto.UUID.generate() end,
                 now: fn -> DateTime.add(@now, index, :microsecond) end
               )
    end)

    assert {:ok, conversation} = Projection.lab_conversation(@conversation_id)
    assert length(conversation.messages) == 50
    assert List.last(conversation.messages).text == "Bounded transcript message 200"
    assert hd(conversation.messages).text == "Bounded transcript message 151"
    assert conversation.history.exhausted == false

    assert {:ok, older} = Projection.lab_history(@conversation_id, conversation.history.before)
    assert hd(older.messages).text == "Bounded transcript message 101"
    assert List.last(older.messages).text == "Bounded transcript message 150"

    assert {:ok, oldest} =
             Enum.reduce_while(1..10, older, fn _step, page ->
               if page.exhausted,
                 do: {:halt, {:ok, page}},
                 else: {:cont, elem(Projection.lab_history(@conversation_id, page.before), 1)}
             end)

    assert hd(oldest.messages).text == "Bounded transcript message 0"
    assert oldest.before == nil
  end

  defp profile do
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "conversation-read",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    profile
  end

  defp workspace_changes(patch) do
    bytes = byte_size(patch)

    %{
      "base_commit" => String.duplicate("a", 40),
      "committed" => [%{"path" => "lib/ryker.ex", "status" => "modified"}],
      "conflicts" => [],
      "fork_head" => String.duplicate("b", 40),
      "fork_tree" => String.duplicate("c", 40),
      "parent_head" => String.duplicate("d", 40),
      "parent_divergence" => %{
        "ahead" => 1,
        "base_to_fork" => 1,
        "base_to_parent" => 0,
        "behind" => 0,
        "diverged" => false
      },
      "patch" => Base.encode64(patch),
      "patch_bytes" => bytes,
      "patch_digest" => :crypto.hash(:sha256, patch) |> Base.encode16(case: :lower),
      "patch_has_more" => false,
      "patch_next_offset" => bytes,
      "patch_offset" => 0,
      "staged" => [],
      "truncated" => false,
      "unstaged" => [],
      "untracked" => []
    }
  end
end
