defmodule Ryker.ControlPlane.ConversationLabEndToEndTest do
  use Ryker.DataCase, async: true

  @moduletag isolation: "REPEATABLE READ"

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Ryker.Admission.Dispatcher, as: AdmissionDispatcher
  alias Ryker.CanonicalJSON

  alias Ryker.ControlPlane.{
    Actions,
    CapabilityTools,
    ConversationLab,
    ConversationProjection,
    EpisodePage,
    EpisodeProjection,
    HTML,
    LabControls,
    LabPage,
    ModelRequests,
    Projection,
    Publisher
  }

  alias Ryker.Delivery.{Adapters, PlatformAction, RoutingResponse}

  alias Ryker.ControlPlane.EpisodeTrace.{Input, Maintenance, ToolActivity}
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.WorkProfile
  alias Ryker.Records
  alias Ryker.Records.Record
  alias Ryker.Repo
  alias Ryker.Retention.Dispatcher, as: RetentionDispatcher
  alias Ryker.StateTools.WorkStateTools
  alias Ryker.TestSupport.{FakeCoopAPI, FakeWorkCoopAPI}

  alias Ryker.Work.{
    ActivityEvent,
    Custody,
    Executor,
    Result,
    Session,
    SubmissionBuilder,
    Turn
  }

  @conversation_id "018f3ef7-1f62-7ee0-a83c-0c12f21dc2e6"
  @first_event_id "018f3ef7-1f62-7ee0-a83c-0c12f21dc2e7"
  @second_event_id "018f3ef7-1f62-7ee0-a83c-0c12f21dc2e8"
  @reaction_event_id "018f3ef7-1f62-7ee0-a83c-0c12f21dc2e9"
  @artifact_event_id "018f3ef7-1f62-7ee0-a83c-0c12f21dc2ea"
  @capability_event_id "018f3ef7-1f62-7ee0-a83c-0c12f21dc2eb"
  @edit_event_id "018f3ef7-1f62-7ee0-a83c-0c12f21dc2ec"
  @quick_reply_event_id "018f3ef7-1f62-7ee0-a83c-0c12f21dc2ed"
  @several_event_id "018f3ef7-1f62-7ee0-a83c-0c12f21dc2ee"
  @update_event_id "018f3ef7-1f62-7ee0-a83c-0c12f21dc2ef"
  @reactions_event_id "018f3ef7-1f62-7ee0-a83c-0c12f21dc2f0"
  @now ~U[2026-08-30 18:00:00.000000Z]
  @digest String.duplicate("a", 64)
  @first_question "Is checkout readiness failing?"
  @first_reply "Readiness failed for four minutes after 08:00."
  @follow_up_reply "The deploy is the leading suspect for the 08:04 alert."
  @edited_follow_up "Did the 08:00 deploy cause the 08:06 alert?"
  @edited_reply "With the alert at 08:06, the deploy is still the leading suspect."

  for {field, value, phrase} <- [
        {"source_kind", String.duplicate("x", 121), "source identifier"},
        {"cursor", %{"value" => String.duplicate("x", 16_373)}, "16 KiB"}
      ] do
    test "Lab retains a non-actionable scheduling diagnostic for an invalid saved #{field}" do
      # The reconciler retained the error, but Card.project silently hid it from Lab.
      assert {:ok, %{status: :recorded}} =
               send_message(@first_event_id, @now, "Wait for the run.")

      {:ok, admission} = FakeCoopAPI.start_link([decision(:start_episode, nil)])

      assert {:ok, {:decided, _admitted}} =
               AdmissionDispatcher.run_once(admission_options(admission, @now))

      assert {:ok, claim} = Custody.claim_next("lab-retained-wait", 60, :work)

      assert {:ok, record} =
               Records.create(Records.token(claim.turn), "lab-wait", "event_wait", %{
                 "deadline_at" => "2099-09-07T12:26:12Z",
                 "event_matcher" => %{
                   "type" => "source_event",
                   "source_kind" => "slack",
                   "match" => %{"run_id" => "run-5gvASLsVavas4TRg"},
                   "poll_after" => "2099-09-07T12:01:12Z",
                   "on_timeout" => "Report the unverified outcome."
                 },
                 "kind" => "source_event",
                 "verification" =>
                   "Verify the next lifecycle update for this exact Terraform run."
               })

      # Accepted first-turn reply harvested from Terraform capture 1788782169504;
      # only the record reference is rebound to this isolated Lab fixture.
      candidate =
        "I’m waiting for the next update on Terraform run run-5gvASLsVavas4TRg (va1-postgres). I’ll check again by 12:01 UTC and report any unverified outcome at the 12:26 UTC deadline."
        |> work_reply()
        |> Jason.decode!()
        |> put_in(["outcome", "record_refs"], [record.ref])
        |> put_in(["outcome", "state"], "waiting_for_event")
        |> Jason.encode!()

      {:ok, work} = FakeWorkCoopAPI.start_link([candidate])

      assert {:ok, %{status: :accepted}} =
               Executor.run(claim, work_options(work, "wait")[:executor_options])

      assert {:ok, {:delivered, :message, _delivery_ref}} =
               Ryker.Delivery.Dispatcher.run_once(delivery_options("wait"))

      # Restore a formerly accepted shape and its current host scheduling error.
      payload =
        put_in(record.payload, ["event_matcher", unquote(field)], unquote(Macro.escape(value)))

      Repo.update_all(from(saved in Record, where: saved.id == ^record.id),
        set: [
          payload: payload,
          payload_fingerprint: CanonicalJSON.digest(payload),
          wait_error: unquote(field)
        ]
      )

      assert {:ok, conversation} = ConversationProjection.fetch(@conversation_id)
      assert [%{cards: [card]}] = Enum.filter(conversation.messages, &(&1.actor == :ryker))
      assert card.ref == record.ref
      assert card.wait_warning =~ unquote(phrase)
      assert card.action == nil
      html = HTML.lab_message_extras(%{cards: [card]}) |> IO.iodata_to_binary()
      assert html =~ "Current scheduling status:"
      assert html =~ unquote(phrase)
      refute html =~ "Verify the next lifecycle update"
      refute html =~ String.duplicate("x", 121)
      refute html =~ "<form"
    end
  end

  test "a local conversation uses the complete durable product path and continues one session" do
    assert {:ok, %{status: :recorded}} =
             send_message(
               @first_event_id,
               @now,
               "Explain what the durable runtime knows about this request.",
               attachments: [
                 %{
                   data: "source=conversation-lab\nstatus=durable\n",
                   media_type: "text/plain",
                   name: "runtime.txt"
                 }
               ]
             )

    {:ok, admission} = FakeCoopAPI.start_link([decision(:start_episode, nil)])

    assert {:ok, {:decided, first_admission}} =
             AdmissionDispatcher.run_once(admission_options(admission, @now))

    episode = first_admission.result.episode
    assert episode.destination_transport == "control_plane"
    assert episode.destination_conversation_ref == conversation_ref()
    assert episode.destination_thread_ref == conversation_ref()

    {:ok, work} =
      FakeWorkCoopAPI.start_link(
        [
          work_reply("The first durable response is ready."),
          work_reply("The follow-up continued the same episode and Coop session.")
        ],
        on_validation_reject: fn violations ->
          raise "unexpected conversation-lab semantic rejection: #{inspect(violations)}"
        end
      )

    assert {:ok, {:executed, first_execution}} =
             Ryker.Work.Dispatcher.run_once(work_options(work, "first"))

    assert first_execution.status == :accepted
    assert first_execution.turn.status == :delivery_pending
    first_session_id = first_execution.turn.session_id

    assert [%{artifacts: [submitted_artifact]}] = FakeWorkCoopAPI.state(work).submissions
    assert submitted_artifact["data"] == "source=conversation-lab\nstatus=durable\n"
    assert submitted_artifact["media_type"] == "text/plain"
    assert submitted_artifact["name"] == "runtime.txt"

    assert %Session{
             policy: "conversation-read",
             policy_digest: @digest,
             repository_ref: nil
           } = Repo.get!(Session, first_session_id)

    assert {:ok, {:delivered, :message, first_delivery_ref}} =
             Ryker.Delivery.Dispatcher.run_once(delivery_options("first"))

    assert %Turn{status: :settled, external_receipt: first_receipt} =
             Repo.get!(Turn, first_execution.turn.id)

    assert first_receipt["delivery_ref"] == first_delivery_ref
    assert first_receipt["transport"] == "control_plane"
    assert first_receipt["conversation_ref"] == conversation_ref()

    # Production, 2026-09-20: cleanup closed the remote session before starting
    # the advertised follow-up window. The next message therefore had to create
    # another session even though it arrived eight seconds later. Cleanup between
    # turns must keep the same remote session open until the window expires.
    # Routing has its own earlier cleanup item. A separate worker holds it while
    # this single-session fake exercises the conversation's follow-up window.
    assert {:ok, %{session: %{execution_kind: :admission}}} =
             Ryker.Retention.Custody.claim_next("conversation-lab-routing-cleanup", 300)

    assert {:ok, {:executed, %{phase: :grace}}} =
             RetentionDispatcher.run_once(retention_options(work, "between-turns"))

    assert %Session{cleanup_status: :grace, closed_at: nil} =
             Repo.get!(Session, first_session_id)

    assert FakeWorkCoopAPI.state(work).session["state"] == "open"

    assert {:ok, %{status: :applied}} =
             ConversationLab.react_to_message(
               @conversation_id,
               first_receipt["message_ref"],
               :add,
               "eyes",
               id_generator: fn -> Ecto.UUID.generate() end,
               now: fn -> DateTime.add(@now, 30, :second) end
             )

    assert {:ok, %{status: :recorded}} =
             send_message(
               @second_event_id,
               DateTime.add(@now, 60, :second),
               "Use the previous answer and tell me what persisted across the turn."
             )

    candidate_ref =
      "candidate:" <>
        binary_part(CanonicalJSON.digest(["ingress-admission-candidate", episode.id]), 0, 12)

    {:ok, follow_up_admission} =
      FakeCoopAPI.start_link([decision(:continue_episode, candidate_ref)])

    assert {:ok, {:decided, second_admission}} =
             AdmissionDispatcher.run_once(
               admission_options(follow_up_admission, DateTime.add(@now, 60, :second))
             )

    assert second_admission.result.entry.decision_action == :continue_episode
    assert second_admission.result.episode.id == episode.id

    assert %Session{cleanup_status: :active} = Repo.get!(Session, first_session_id)

    assert {:ok, {:executed, second_execution}} =
             Ryker.Work.Dispatcher.run_once(work_options(work, "second"))

    assert second_execution.status == :accepted
    assert second_execution.turn.session_id == first_session_id

    assert {:ok, {:delivered, :message, _second_delivery_ref}} =
             Ryker.Delivery.Dispatcher.run_once(delivery_options("second"))

    assert {:ok, conversation} = ConversationProjection.fetch(@conversation_id)

    assert Enum.map(conversation.messages, &{&1.actor, &1.text}) == [
             {:operator, "Explain what the durable runtime knows about this request."},
             {:ryker, "The first durable response is ready."},
             {:operator, "Use the previous answer and tell me what persisted across the turn."},
             {:ryker, "The follow-up continued the same episode and Coop session."}
           ]

    assert [%{id: @conversation_id, message_count: 2}] = ConversationProjection.index()
    refute conversation.live
    assert conversation.pending == 0

    turns =
      Repo.all(
        from(turn in Turn,
          where: turn.episode_id == ^episode.id,
          order_by: [asc: turn.inserted_at, asc: turn.id]
        )
      )

    assert [first_turn, second_turn] = turns
    assert first_turn.submission["context"]["mode"] == "full"
    assert second_turn.submission["context"]["mode"] == "continuation"

    assert second_turn.submission["context"]["conversation_feedback"]["current"] == [
             %{
               "actor_refs" => ["control-plane:user:local-operator"],
               "count" => 1,
               "emoji_name" => "eyes",
               "target_delivery_ref" => first_delivery_ref,
               "target_message_ref" => first_receipt["message_ref"]
             }
           ]

    assert second_turn.submission["context"]["parent_submission_ref"] ==
             first_turn.submission_fingerprint

    assert Repo.aggregate(
             from(session in Session, where: session.episode_id == ^episode.id),
             :count
           ) ==
             1

    assert %Episode{state: :complete} = Repo.get!(Episode, episode.id)
    assert FakeWorkCoopAPI.state(work).submit_count == 2
    assert FakeCoopAPI.state(admission).submit_count == 1
    assert FakeCoopAPI.state(follow_up_admission).submit_count == 1
  end

  test "a local nonverbal acknowledgment uses generic reaction custody and renders on its input" do
    assert {:ok, %{status: :recorded}} =
             send_message(
               @reaction_event_id,
               @now,
               "Acknowledge this without starting work when a reaction is sufficient."
             )

    {:ok, admission} = FakeCoopAPI.start_link([decision(:react, nil)])

    assert {:ok, {:decided, admitted}} =
             AdmissionDispatcher.run_once(admission_options(admission, @now))

    assert admitted.result.entry.decision_action == :react

    assert %RoutingResponse{
             kind: :reaction,
             status: :pending,
             document: %{"emoji_name" => "eyes"}
           } =
             Repo.get_by!(RoutingResponse, input_id: admitted.result.entry.id)

    assert {:ok, {:delivered, :routing, delivery_ref}} =
             Ryker.Delivery.Dispatcher.run_once(delivery_options("reaction", :routing))

    assert %RoutingResponse{status: :delivered} =
             Repo.get_by!(RoutingResponse, input_id: admitted.result.entry.id)

    assert {:ok, conversation} = ConversationProjection.fetch(@conversation_id)
    assert [message] = Enum.filter(conversation.messages, &(&1.actor == :operator))

    assert message.reactions == [
             %{delivery_ref: delivery_ref, emoji_name: "eyes", status: :delivered}
           ]

    refute conversation.live
  end

  # "hi" used to start a whole Work session, a minute of model time to say
  # hello back. Routing now answers a simple message itself; the answer must
  # reach the Chat as Ryker's message under the one it answered, with no
  # request behind it, and link the decision that wrote it.
  test "routing answers a simple Chat message itself and the answer shows under it" do
    assert {:ok, %{status: :recorded}} = send_message(@quick_reply_event_id, @now, "hi")

    {:ok, admission} =
      FakeCoopAPI.start_link([quick_answer("Hi! What can I help with?")])

    assert {:ok, {:decided, admitted}} =
             AdmissionDispatcher.run_once(admission_options(admission, @now))

    assert admitted.result.entry.decision_action == :quick_reply
    assert admitted.result.episode == nil

    assert {:ok, waiting} = ConversationProjection.fetch(@conversation_id)
    assert waiting.live

    assert {:ok, {:delivered, :routing, delivery_ref}} =
             Ryker.Delivery.Dispatcher.run_once(delivery_options("quick-reply", :routing))

    assert {:ok, conversation} = ConversationProjection.fetch(@conversation_id)

    assert [
             %{actor: :operator, text: "hi"},
             %{actor: :ryker, text: "Hi! What can I help with?", ref: ^delivery_ref} = answer
           ] = conversation.messages

    assert conversation.episodes == []
    refute conversation.live

    assert LabPage.timeline_href(answer) ==
             "/timeline/ingress-input%3A#{admitted.result.entry.id}"

    # Manual test, 2026-09-26: that page's heading said "Couldn't start" for
    # every message that did not become work, including one routing had just
    # answered, one it reacted to and one it rightly left alone.
    assert {:ok, request} = ModelRequests.project_input(admitted.result.entry.id, %{})

    page =
      render_component(&EpisodePage.message_page/1, view: request)
      |> LazyHTML.from_fragment()

    header = page |> LazyHTML.query(".episode-page-intro") |> LazyHTML.text()
    assert header =~ "Answered right away"
    refute header =~ "Couldn"

    # The page's help promises the answer as the last stage; a quick reply's
    # page ended at the routing decision and never said what was sent.
    answer = LazyHTML.query(page, ".phase-answer")
    assert LazyHTML.text(answer) =~ "Answer"
    assert LazyHTML.text(answer) =~ "Hi! What can I help with?"
    assert LazyHTML.text(answer) =~ "Sent"
  end

  # Andrew, 2026-09-26: "Now both reply and add a reaction" started a whole
  # work run, because routing could answer with one message or one emoji.
  # In Chat, routing's messages must appear under the person's message in
  # the order it wrote them, each once, with its emoji on that message, and
  # the conversation stops showing Ryker at work only when all have arrived.
  test "routing's several messages and emoji reach the Chat once each, in the order it wrote them" do
    assert {:ok, %{status: :recorded}} =
             send_message(@several_event_id, @now, "Now both reply and add a reaction")

    {:ok, admission} =
      FakeCoopAPI.start_link([
        quick_answer(["Hi again!", "Want me to check anything else?"], ["thumbsup"])
      ])

    assert {:ok, {:decided, admitted}} =
             AdmissionDispatcher.run_once(admission_options(admission, @now))

    assert admitted.result.entry.decision_action == :quick_reply
    assert admitted.result.episode == nil

    delivered =
      Enum.map(1..3, fn step ->
        assert {:ok, waiting} = ConversationProjection.fetch(@conversation_id)
        assert waiting.live

        assert {:ok, {:delivered, :routing, ref}} =
                 Ryker.Delivery.Dispatcher.run_once(delivery_options("several-#{step}", :routing))

        ref
      end)

    assert {:ok, :idle} =
             Ryker.Delivery.Dispatcher.run_once(delivery_options("several-done", :routing))

    assert {:ok, conversation} = ConversationProjection.fetch(@conversation_id)
    [first_ref, second_ref, reaction_ref] = delivered

    assert [
             %{actor: :operator, text: "Now both reply and add a reaction", reactions: reactions},
             %{actor: :ryker, text: "Hi again!", ref: ^first_ref},
             %{actor: :ryker, text: "Want me to check anything else?", ref: ^second_ref}
           ] = conversation.messages

    assert reactions == [
             %{delivery_ref: reaction_ref, emoji_name: "thumbsup", status: :delivered}
           ]

    assert conversation.episodes == []
    refute conversation.live
  end

  test "a generated artifact is delivered and retrievable only through its exact Lab turn" do
    assert {:ok, %{status: :recorded}} =
             send_message(
               @artifact_event_id,
               @now,
               "Return the generated service chart in this conversation."
             )

    {:ok, admission} = FakeCoopAPI.start_link([decision(:start_episode, nil)])

    assert {:ok, {:decided, _admitted}} =
             AdmissionDispatcher.run_once(admission_options(admission, @now))

    data = <<137, 80, 78, 71, 13, 10, 26, 10, "lab-chart">>
    sha256 = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
    artifact_ref = "artifact_#{binary_part(sha256, 0, 24)}"

    metadata = %{
      "bytes" => byte_size(data),
      "id" => artifact_ref,
      "media_type" => "image/png",
      "name" => "service-health.png",
      "sha256" => sha256
    }

    # The cat and RPS chart existed in Coop, but an earlier preflight made the model
    # omit them from its reply. Lab must still expose verified files from that turn.
    unselected_data = data <> "-generated"

    unselected = %{
      metadata
      | "id" => "artifact_generated_but_not_attached",
        "name" => "generated-1.png",
        "bytes" => byte_size(unselected_data),
        "sha256" => :crypto.hash(:sha256, unselected_data) |> Base.encode16(case: :lower)
    }

    candidate =
      work_reply("The generated service chart is attached.")
      |> Jason.decode!()
      |> put_in(["outcome", "artifact_refs"], [artifact_ref])
      |> Jason.encode!()

    {:ok, work} =
      FakeWorkCoopAPI.start_link([candidate],
        output_artifact_metadata: [metadata, unselected],
        output_artifacts: %{
          artifact_ref => Map.put(metadata, "data", data),
          unselected["id"] => Map.put(unselected, "data", unselected_data)
        }
      )

    assert {:ok, {:executed, %{status: :accepted, turn: turn}}} =
             Ryker.Work.Dispatcher.run_once(work_options(work, "artifact"))

    assert {:ok, {:delivered, :message, _delivery_ref}} =
             Ryker.Delivery.Dispatcher.run_once(delivery_options("artifact"))

    assert {:ok, conversation} = ConversationProjection.fetch(@conversation_id)

    assert [%{attachments: [attachment]}] =
             Enum.filter(conversation.messages, &(&1.actor == :ryker))

    assert attachment.name == "service-health.png"
    assert attachment.media_type == "image/png"
    assert attachment.bytes == byte_size(data)

    assert {:ok, artifact} =
             ConversationProjection.artifact(@conversation_id, turn.id, artifact_ref)

    assert artifact.data == data
    assert artifact.sha256 == sha256

    assert [%{generated_files: [generated]}] =
             Enum.filter(conversation.messages, &(&1.actor == :ryker))

    assert generated.name == "generated-1.png"

    assert {:ok, %{data: ^unselected_data}} =
             ConversationProjection.artifact(@conversation_id, turn.id, unselected["id"])

    assert ConversationProjection.artifact(Ecto.UUID.generate(), turn.id, unselected["id"]) ==
             :not_found

    assert ConversationProjection.artifact(Ecto.UUID.generate(), turn.id, artifact_ref) ==
             :not_found

    assert ConversationProjection.artifact(@conversation_id, Ecto.UUID.generate(), artifact_ref) ==
             :not_found

    assert ConversationProjection.artifact(@conversation_id, turn.id, "artifact_missing") ==
             :not_found
  end

  test "Slack-compatible model actions stay local, render, and require the same host confirmation" do
    assert {:ok, %{status: :recorded}} =
             send_message(
               @capability_event_id,
               @now,
               "React to this, then offer a second local message for my confirmation."
             )

    {:ok, admission} = FakeCoopAPI.start_link([decision(:start_episode, nil)])

    assert {:ok, {:decided, admitted}} =
             AdmissionDispatcher.run_once(admission_options(admission, @now))

    assert {:ok, claim} = Custody.claim_next("conversation-lab-capabilities", 60, :work)
    assert claim.episode.id == admitted.result.episode.id

    binding = %{
      episode: claim.episode,
      session: claim.session,
      state_token: Records.token(claim.turn),
      turn: claim.turn
    }

    [input_ref] = claim.episode.active_input_refs

    assert {:ok, %{"action_ref" => reaction_ref, "status" => "pending"}} =
             CapabilityTools.call(
               "set_slack_reaction",
               %{"action" => "add", "emoji" => "eyes", "message_ref" => input_ref},
               binding
             )

    assert {:ok,
            %{
              "kind" => "slack_post_offer",
              "record_ref" => post_ref,
              "status" => "open"
            }} =
             CapabilityTools.call(
               "post_slack_message",
               %{
                 "destination_ref" => conversation_ref(),
                 "instruction_ref" => input_ref,
                 "message" => "This is the confirmed local follow-up."
               },
               binding
             )

    assert {:ok, {:delivered, :action, ^reaction_ref}} =
             Ryker.Delivery.Dispatcher.run_once(delivery_options("capability-reaction", :action))

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
               "coop-session:conversation-lab-capabilities"
             )

    assert {:ok, _turn} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:conversation-lab-capabilities"
             )

    document = %{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "I prepared one additional local message for confirmation.",
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [post_ref],
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
               "validation-receipt:conversation-lab-capabilities"
             )

    assert {:ok, {:delivered, :message, _delivery_ref}} =
             Ryker.Delivery.Dispatcher.run_once(delivery_options("capability-reply"))

    assert {:ok, conversation} = ConversationProjection.fetch(@conversation_id)
    [operator, ryker] = conversation.messages

    assert operator.reactions == [
             %{delivery_ref: reaction_ref, emoji_name: "eyes", status: :delivered}
           ]

    assert [%{action: :confirm_post, kind: "slack_post_offer", ref: ^post_ref}] =
             ryker.cards

    actions = Actions.callbacks(%{environments: %{}, fallback_work_profile: profile()}, %{})

    assert {:ok, %{action: %PlatformAction{action_ref: post_action_ref}, status: :confirmed}} =
             actions.act_on_lab_record.(@conversation_id, post_ref, :confirm_post, nil)

    assert {:ok, {:delivered, :action, ^post_action_ref}} =
             Ryker.Delivery.Dispatcher.run_once(delivery_options("capability-post", :action))

    assert {:ok, updated} = ConversationProjection.fetch(@conversation_id)

    assert Enum.map(updated.messages, &{&1.actor, &1.text}) == [
             {:operator, "React to this, then offer a second local message for my confirmation."},
             {:ryker, "I prepared one additional local message for confirmation."},
             {:ryker, "This is the confirmed local follow-up."}
           ]

    assert %Turn{status: :settled} = Repo.get!(Turn, accepted.turn.id)
  end

  # Andrew, 2026-09-26: "Sometimes it's even helpful to let model to do that
  # mid-conversation to make it really live (via MCP tools?)". The Work model
  # may post a short update into its conversation while it works. In Chat the
  # updates appear in the order posted and before the answer, on the Chat and
  # on the request's timeline; a turn posts only a few, and its answer is not
  # accepted while an update is still on its way.
  test "Ryker says what it is doing before it answers, in order, in Chat and on the timeline" do
    assert {:ok, %{status: :recorded}} =
             send_message(@update_event_id, @now, "Check the deploy and tell me how it goes.")

    {:ok, admission} = FakeCoopAPI.start_link([decision(:start_episode, nil)])

    assert {:ok, {:decided, admitted}} =
             AdmissionDispatcher.run_once(admission_options(admission, @now))

    assert {:ok, claim} = Custody.claim_next("conversation-lab-updates", 60, :work)
    assert claim.episode.id == admitted.result.episode.id

    binding = %{
      episode: claim.episode,
      session: claim.session,
      state_token: Records.token(claim.turn),
      turn: claim.turn
    }

    updates = ["Looking at the deploy now.", "The rollout is at 40%.", "Error rate is flat."]

    refs =
      Enum.map(updates, fn message ->
        assert {:ok, %{"action_ref" => ref, "status" => "pending"}} =
                 CapabilityTools.call("post_slack_update", %{"message" => message}, binding)

        ref
      end)

    assert {:error, "update_limit_reached: " <> _correction} =
             CapabilityTools.call("post_slack_update", %{"message" => "And one more."}, binding)

    answer = "The deploy finished and the error rate stayed flat."

    candidate = %{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => answer,
      "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"},
      "title" => nil
    }

    # The answer waits while an update has not reached the conversation.
    assert {:ok, %{"accepted" => false, "violations" => [waiting]}} =
             WorkStateTools.validate_final(%{"candidate" => candidate}, binding)

    assert waiting =~ "Do not complete while platform actions are unresolved"

    for ref <- refs do
      assert {:ok, {:delivered, :action, ^ref}} =
               Ryker.Delivery.Dispatcher.run_once(delivery_options("update-#{ref}", :action))
    end

    assert {:ok, %{"accepted" => true}} =
             WorkStateTools.validate_final(%{"candidate" => candidate}, binding)

    accept_reply!(claim, candidate, "conversation-lab-updates")

    assert {:ok, {:delivered, :message, _delivery_ref}} =
             Ryker.Delivery.Dispatcher.run_once(delivery_options("update-answer"))

    assert {:ok, conversation} = ConversationProjection.fetch(@conversation_id)

    assert Enum.map(conversation.messages, &{&1.actor, &1.text}) ==
             [
               {:operator, "Check the deploy and tell me how it goes."}
               | Enum.map(updates, &{:ryker, &1})
             ] ++ [{:ryker, answer}]

    {:ok, detail} = EpisodeProjection.fetch(claim.episode.key)
    {:ok, timeline} = ModelRequests.timeline(claim.episode.key, %{})

    html =
      render_component(&EpisodePage.render/1,
        snapshot: detail,
        timeline: timeline,
        requests: nil,
        params: %{}
      )

    sent =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("article.ui-message[data-author=ryker] .ui-message-body")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    assert sent == updates ++ [answer]
  end

  # Andrew, 2026-09-26: "allow even quick model to send multiple reply
  # events, some messages, some emojis (and normal model should be able to do
  # that too)". In Chat a second reaction from the Work model came back
  # "temporarily_unavailable". A turn now adds up to three, each shown on the
  # person's message in the order asked; the same one again is the same
  # reaction, a fourth is refused in words the model can act on, and the
  # answer waits until every reaction is delivered.
  test "Ryker's several reactions in one turn each show on the person's message in Chat" do
    assert {:ok, %{status: :recorded}} =
             send_message(@reactions_event_id, @now, "Ship it! 🚀 Can you check the deploy?")

    {:ok, admission} = FakeCoopAPI.start_link([decision(:start_episode, nil)])

    assert {:ok, {:decided, admitted}} =
             AdmissionDispatcher.run_once(admission_options(admission, @now))

    assert {:ok, claim} = Custody.claim_next("conversation-lab-reactions", 60, :work)
    assert claim.episode.id == admitted.result.episode.id

    binding = %{
      episode: claim.episode,
      session: claim.session,
      state_token: Records.token(claim.turn),
      turn: claim.turn
    }

    [input_ref] = claim.episode.active_input_refs

    react = fn emoji ->
      CapabilityTools.call(
        "set_slack_reaction",
        %{"action" => "add", "emoji" => emoji, "message_ref" => input_ref},
        binding
      )
    end

    refs =
      for emoji <- ~w(eyes rocket white_check_mark) do
        assert {:ok, %{"action_ref" => ref, "status" => "pending"}} = react.(emoji)
        ref
      end

    assert {:ok, %{"action_ref" => same}} = react.("eyes")
    assert same == hd(refs)

    assert {:error, "reaction_limit_reached: " <> _correction} = react.("tada")

    candidate = %{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "The deploy is healthy.",
      "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"},
      "title" => nil
    }

    assert {:ok, %{"accepted" => false, "violations" => [waiting]}} =
             WorkStateTools.validate_final(%{"candidate" => candidate}, binding)

    assert waiting =~ "Do not complete while platform actions are unresolved"

    for ref <- refs do
      assert {:ok, {:delivered, :action, ^ref}} =
               Ryker.Delivery.Dispatcher.run_once(delivery_options("reaction-#{ref}", :action))
    end

    assert {:ok, %{"accepted" => true}} =
             WorkStateTools.validate_final(%{"candidate" => candidate}, binding)

    assert {:ok, conversation} = ConversationProjection.fetch(@conversation_id)
    assert [message] = Enum.filter(conversation.messages, &(&1.actor == :operator))

    assert message.reactions ==
             Enum.zip_with(refs, ~w(eyes rocket white_check_mark), fn ref, emoji ->
               %{delivery_ref: ref, emoji_name: emoji, status: :delivered}
             end)

    # Live 2026-09-27: they read ":eyes:" in Chat instead of the emoji.
    chips = message |> HTML.lab_message_extras() |> IO.iodata_to_binary()
    assert chips =~ "👀"
    assert chips =~ "🚀"
    assert chips =~ "✅"
    refute chips =~ ">:eyes:<"
  end

  test "a Chat request's timeline reads in the reader's words and shows its reply once" do
    # QA 2026-09-25 read this page as "Episode", "Local operator", "Accepted
    # candidate on attempt 1", "Episode title" and a "Maintenance" section,
    # found the reply three times, and two header links to the same Chat.
    reply = "Ryker investigates alerts and answers questions about your systems."

    assert {:ok, %{status: :recorded}} =
             send_message(@first_event_id, @now, "What does this system do?")

    {:ok, admission} = FakeCoopAPI.start_link([decision(:start_episode, nil)])

    assert {:ok, {:decided, %{result: %{episode: episode}}}} =
             AdmissionDispatcher.run_once(admission_options(admission, @now))

    {:ok, work} = FakeWorkCoopAPI.start_link([work_reply(reply, "What Ryker does")])

    assert {:ok, {:executed, %{status: :accepted}}} =
             Ryker.Work.Dispatcher.run_once(work_options(work, "timeline-words"))

    assert {:ok, {:delivered, :message, _delivery_ref}} =
             Ryker.Delivery.Dispatcher.run_once(delivery_options("timeline-words"))

    # Cleanup afterwards: the worker session closed and its copy removed.
    receipt = %{"kind" => "discarded"}

    Repo.update_all(from(session in Session, where: session.episode_id == ^episode.id),
      set: [
        cleanup_status: :discarded,
        cleanup_receipt: receipt,
        cleanup_receipt_fingerprint: CanonicalJSON.digest(receipt),
        closed_at: DateTime.add(@now, 60, :second),
        discarded_at: DateTime.add(@now, 90, :second)
      ]
    )

    {:ok, detail} = EpisodeProjection.fetch(episode.key)
    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})

    html =
      render_component(&EpisodePage.render/1,
        snapshot: detail,
        timeline: timeline,
        requests: nil,
        params: %{}
      )

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(document, ".episode-initial-label") |> LazyHTML.text() == "Request"

    assert document
           |> LazyHTML.query("article.ui-message[data-author=person] .ui-message-header strong")
           |> Enum.map(&LazyHTML.text/1)
           |> Enum.uniq() == ["You"]

    assert document
           |> LazyHTML.query(".episode-location a[href='/conversations/#{@conversation_id}']")
           |> Enum.count() == 1

    assert document
           |> LazyHTML.query(".ui-message-body")
           |> Enum.count(&(LazyHTML.text(&1) =~ reply)) == 1

    for words <- ["Local operator", "Accepted candidate", "Episode title", "Maintenance"] do
      refute html =~ words
    end

    assert document |> LazyHTML.query(".chapter-heading h3") |> LazyHTML.text() =~ "Cleanup"
  end

  # QA 2026-09-25, conversation e08ccca1: ask, reply, follow-up, reply, then
  # edit the follow-up. While Ryker worked on the edited question, "Ryker is
  # working on a reply" sat under the first message as well, because every
  # message of the request took the request's state. And once the new answer
  # arrived, the earlier reply still sat under the edited question with nothing
  # saying it answered the words that were no longer there.
  test "while Ryker answers an edited message, only that message says Ryker is working" do
    edited_conversation!()

    articles = chat_articles()
    working = Enum.filter(articles, &(LazyHTML.query(&1, ".lab-typing-indicator") |> Enum.any?()))

    assert [edited] = working
    assert LazyHTML.text(edited) =~ @edited_follow_up
    refute Enum.any?(working, &(LazyHTML.text(&1) =~ @first_question))

    # The same holds when that run stops: "Model work stopped" and its Retry sat
    # under both questions in the same QA pass.
    {:ok, claim} = Custody.claim_next("edited-conversation", 60, :work)

    Repo.update_all(from(turn in Turn, where: turn.id == ^claim.turn.id),
      set: [status: :blocked, lease_ref: nil, lease_owner: nil, lease_expires_at: nil]
    )

    stopped = Enum.filter(chat_articles(), &(LazyHTML.text(&1) =~ "Model work stopped"))
    assert [edited] = stopped
    assert LazyHTML.text(edited) =~ @edited_follow_up
  end

  test "a reply to the words a message had before it was edited says so" do
    work = edited_conversation!()

    # The edit makes the session's history stale, so Work starts a new one. A
    # real worker names a new session; this double does once the old is closed.
    Agent.update(work, &put_in(&1, [:session, "state"], "closed"))

    assert {:ok, {:executed, %{status: :accepted}}} =
             Ryker.Work.Dispatcher.run_once(work_options(work, "after-edit"))

    assert {:ok, {:delivered, :message, _ref}} =
             Ryker.Delivery.Dispatcher.run_once(delivery_options("after-edit"))

    articles = chat_articles()
    refute Enum.any?(articles, &(LazyHTML.query(&1, ".lab-typing-indicator") |> Enum.any?()))

    marked =
      Enum.filter(articles, &(LazyHTML.text(&1) =~ "Answered your earlier wording"))

    assert [earlier] = marked
    assert LazyHTML.text(earlier) =~ @follow_up_reply

    assert Enum.count(articles, &(LazyHTML.text(&1) =~ @edited_reply)) == 1
  end

  # Manual test, 2026-10-01, conversation e38c2c16: the work on Andrew's message
  # stopped, he edited the message, and the edit brought the work back with both
  # versions of it. The first version's source had moved to the edit, so each
  # briefing was refused as stale before Coop saw it: "Model work stopped" again,
  # and again after every Retry. The earlier words are withdrawn; the edit is answered.
  test "editing a message whose work stopped gets an answer to the new words" do
    assert {:ok, %{status: :recorded}} = send_message(@first_event_id, @now, @first_question)
    {:ok, admission} = FakeCoopAPI.start_link([decision(:start_episode, nil)])

    assert {:ok, {:decided, %{result: %{episode: episode}}}} =
             AdmissionDispatcher.run_once(admission_options(admission, @now))

    {:ok, claim} = Custody.claim_next("stopped-before-edit", 60, :work)

    assert {:ok, _stopped} =
             Custody.request_block(
               episode.id,
               episode.key,
               claim.turn.turn_ref,
               claim.lease_ref,
               "The model run failed."
             )

    edited_at = DateTime.add(@now, 60, :second)
    edited_question = "Has checkout readiness failed since 08:06?"

    assert {:ok, _receipt} =
             ConversationLab.edit_message(
               @conversation_id,
               @first_event_id,
               edited_question,
               profile(),
               id_generator: fn -> @edit_event_id end,
               now: fn -> edited_at end
             )

    candidate_ref =
      "candidate:" <>
        binary_part(CanonicalJSON.digest(["ingress-admission-candidate", episode.id]), 0, 12)

    {:ok, edit} = FakeCoopAPI.start_link([decision(:continue_episode, candidate_ref)])

    assert {:ok, {:decided, _resumed}} =
             AdmissionDispatcher.run_once(admission_options(edit, edited_at))

    {:ok, work} = FakeWorkCoopAPI.start_link([work_reply(@edited_reply)])

    # The stopped run hands the work on with both versions of the message.
    assert {:ok, {:executed, %{status: :transferred}}} =
             Ryker.Work.Dispatcher.run_once(work_options(work, "stopped-before-edit"))

    assert length(Repo.get!(Episode, episode.id).active_input_refs) == 2

    assert {:ok, {:executed, %{status: :accepted}}} =
             Ryker.Work.Dispatcher.run_once(work_options(work, "after-stopped-edit"))

    assert [submitted] = FakeWorkCoopAPI.state(work).submissions
    items = submitted.prompt |> Jason.decode!() |> get_in(["work", "inputs", "items"])

    assert [%{"content" => %{"content" => %{"text" => ^edited_question}}}] =
             Enum.filter(items, & &1["current"])

    assert %{"unavailable" => "source_not_current"} in Enum.map(items, & &1["content"])

    assert {:ok, {:delivered, :message, _ref}} =
             Ryker.Delivery.Dispatcher.run_once(delivery_options("after-stopped-edit"))

    articles = chat_articles()
    refute Enum.any?(articles, &(LazyHTML.text(&1) =~ "Model work stopped"))
    assert Enum.count(articles, &(LazyHTML.text(&1) =~ @edited_reply)) == 1

    # The run saw both versions and answered the new one. Live, the reply still
    # read "Answered your earlier wording" once it arrived.
    refute Enum.any?(articles, &(LazyHTML.text(&1) =~ "Answered your earlier wording"))
  end

  test "an edit reaches the earlier reply on a refresh, though the reply itself did not change" do
    # A refresh patches the latest page and every row changed since the last
    # one. The earlier reply's own rows are old; only its message was edited,
    # so a refresh must still bring it back to say what it answered.
    edited_conversation!()
    hour_ago = DateTime.add(DateTime.utc_now(), -3_600, :second)
    Repo.update_all(Turn, set: [updated_at: hour_ago])
    Repo.update_all(Record, set: [updated_at: hour_ago])

    since = DateTime.add(DateTime.utc_now(), -60, :second)
    assert {:ok, changed} = ConversationProjection.changes(@conversation_id, since)

    assert [%{text: @follow_up_reply}] =
             Enum.filter(changed, &(&1.actor == :ryker and &1[:answered_earlier]))
  end

  # QA 2026-09-25 read a timeline headed "Turn 3 · Selected inputs not
  # recorded · Continues Turn 2", "Owner transferred", "Wait resumed", "Episode
  # setup" and "Related episode history": the engine's words, which a person
  # reading what happened to their request cannot map to anything they did.
  # Every heading, badge and label a person reads says it in their words; the
  # engine's names stay in the code and the logs.
  test "no person-facing timeline heading says turn, owner, episode or lease" do
    work = edited_conversation!()
    Agent.update(work, &put_in(&1, [:session, "state"], "closed"))

    assert {:ok, {:executed, %{status: :accepted}}} =
             Ryker.Work.Dispatcher.run_once(work_options(work, "headings"))

    assert {:ok, {:delivered, :message, _ref}} =
             Ryker.Delivery.Dispatcher.run_once(delivery_options("headings"))

    [entry | _rest] =
      Repo.all(from(entry in Entry, order_by: entry.inserted_at))

    {:ok, detail} = EpisodeProjection.fetch("ingress-input:" <> entry.id)
    {:ok, timeline} = ModelRequests.timeline(detail.episode.ref, %{})

    # The real request, and every step the timeline can show that this one
    # conversation did not produce.
    snapshot = put_in(detail, [:trace, :steps], detail.trace.steps ++ every_step_kind(detail))

    document =
      render_component(&EpisodePage.render/1,
        snapshot: snapshot,
        timeline: timeline,
        requests: nil,
        params: %{}
      )
      |> LazyHTML.from_fragment()

    headings =
      document
      |> LazyHTML.query(
        "h1, h2, h3, h4, h5, h6, .turn-association, .timeline-index a, .event-state, " <>
          ".phase-summary, .ui-eyebrow, .case-card-heading-detail, .lab-message-state"
      )
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
      |> Enum.reject(&(&1 == ""))

    assert "Run 3 · Continues Run 2" in headings
    assert "Handed to a new run" in headings
    assert "Picked up again after waiting" in headings

    assert Enum.filter(headings, &(&1 =~ ~r/\b(turns?|owners?|episodes?|leases?)\b/i)) == []
  end

  # One step of every kind the timeline draws that the conversation above did
  # not record: each kernel transition, the variants of starting again, each
  # cleanup outcome, and the worker's activity frames.
  defp every_step_kind(detail) do
    at = DateTime.add(@now, 400, :second)

    kernel =
      Enum.with_index(
        [
          {:input_admitted, %{}},
          {:owner_transferred, %{"transfer_ref" => "transfer:resume-blocked:a:v2"}},
          {:owner_transferred,
           %{"transfer_ref" => "transfer:resume-blocked:b:v3", "required_input_ref" => "input:b"}},
          {:owner_transferred, %{"transfer_ref" => "transfer:resume-destination:c:v4"}},
          {:input_wait_started, %{}},
          {:event_wait_started, %{}},
          {:wait_resumed, %{}},
          {:result_accepted, %{}},
          {:delivery_confirmed, %{}},
          {:episode_cancelled, %{}},
          {:reaction_recorded, %{}}
        ],
        1
      )
      |> Enum.map(fn {{kind, payload}, index} ->
        %Event{
          kind: kind,
          sequence: 1_000 + index,
          dedupe_key: "synthetic:#{index}",
          payload: payload,
          occurred_at: DateTime.add(at, index, :second)
        }
      end)
      |> Input.kernel_steps(%{})

    sessions =
      for {status, receipt, reason} <- [
            {:discarded, "discarded", nil},
            {:discarded, "never_bound", nil},
            {:discarded, "already_discarded", nil},
            {:discarded, "remote_absent", nil},
            {:discarded, "worker_removed", nil},
            {:retained, nil, "dirty"},
            {:blocked, nil, nil}
          ] do
        %Session{
          id: Ecto.UUID.generate(),
          cleanup_status: status,
          cleanup_receipt: receipt && %{"kind" => receipt},
          retained_reason: reason,
          closed_at: at,
          discarded_at: at,
          updated_at: at,
          repository_ref: "checkout-api"
        }
      end

    activity =
      for {kind, payload, index} <- [
            {"tool.started", %{"tool_call_id" => "t1", "title" => "Read file"}, 1},
            {"tool.completed", %{"tool_call_id" => "t1", "status" => "failed"}, 2},
            {"model.plan", %{"step_count" => 2}, 3},
            {"model.progress", %{"text" => "Checking the deploy."}, 4},
            {"permission.decided", %{"outcome" => "cancelled", "tool_call_id" => "t2"}, 5},
            {"activity.elided", %{"dropped" => 3}, 6},
            {"provider.backoff", %{"target" => "standard", "retry_after_seconds" => 5}, 7},
            {"provider.alive", %{"frames" => 3}, 8},
            {"network", %{"denials" => []}, 9}
          ] do
        %ActivityEvent{
          id: Ecto.UUID.generate(),
          kind: kind,
          payload: payload,
          occurred_at: DateTime.add(at, 100 + index, :second),
          session_id: "synthetic-session",
          coop_turn_id: "synthetic-turn",
          remote_event_id: "synthetic-#{index}"
        }
      end

    kernel ++
      Maintenance.steps(sessions) ++
      ToolActivity.steps(activity, detail.trace.causality, MapSet.new())
  end

  # Ask, reply, follow up, reply, then edit the follow-up and route the edit
  # into the same request, which is left working on it.
  defp edited_conversation! do
    assert {:ok, %{status: :recorded}} = send_message(@first_event_id, @now, @first_question)
    {:ok, admission} = FakeCoopAPI.start_link([decision(:start_episode, nil)])

    assert {:ok, {:decided, %{result: %{episode: episode}}}} =
             AdmissionDispatcher.run_once(admission_options(admission, @now))

    {:ok, work} =
      FakeWorkCoopAPI.start_link([
        work_reply(@first_reply),
        work_reply(@follow_up_reply),
        work_reply(@edited_reply)
      ])

    assert {:ok, {:executed, %{status: :accepted}}} =
             Ryker.Work.Dispatcher.run_once(work_options(work, "first"))

    assert {:ok, {:delivered, :message, _}} =
             Ryker.Delivery.Dispatcher.run_once(delivery_options("first"))

    follow_up_at = DateTime.add(@now, 60, :second)

    assert {:ok, %{status: :recorded}} =
             send_message(@second_event_id, follow_up_at, "Did the 08:00 deploy cause it?")

    candidate_ref =
      "candidate:" <>
        binary_part(CanonicalJSON.digest(["ingress-admission-candidate", episode.id]), 0, 12)

    {:ok, follow_up} = FakeCoopAPI.start_link([decision(:continue_episode, candidate_ref)])

    assert {:ok, {:decided, _}} =
             AdmissionDispatcher.run_once(admission_options(follow_up, follow_up_at))

    assert {:ok, {:executed, %{status: :accepted}}} =
             Ryker.Work.Dispatcher.run_once(work_options(work, "second"))

    assert {:ok, {:delivered, :message, _}} =
             Ryker.Delivery.Dispatcher.run_once(delivery_options("second"))

    edited_at = DateTime.add(@now, 120, :second)

    assert {:ok, _receipt} =
             ConversationLab.edit_message(
               @conversation_id,
               @second_event_id,
               @edited_follow_up,
               profile(),
               id_generator: fn -> @edit_event_id end,
               now: fn -> edited_at end
             )

    edit_decision =
      candidate_ref
      |> then(&decision(:continue_episode, &1))
      |> Jason.decode!()
      |> Map.put("reason", "The edit corrects the follow-up this request already answered.")
      |> Jason.encode!()

    {:ok, edit} = FakeCoopAPI.start_link([edit_decision])

    assert {:ok, {:decided, %{result: %{episode: %{state: :working}}}}} =
             AdmissionDispatcher.run_once(admission_options(edit, edited_at))

    work
  end

  defp chat_articles do
    options = %{projection: Projection.callbacks(), csrf_secret: String.duplicate("s", 32)}
    {:ok, snapshot, token} = LabControls.snapshot(@conversation_id, options)

    render_component(&LabPage.render/1,
      snapshot: snapshot,
      token: token,
      items: ConversationProjection.index(),
      messages: Enum.map(snapshot.messages, &{"lab-message-#{&1.ref}", &1}),
      history: %{before: nil, exhausted: true, failed: false, page_size: 50},
      announcement: "",
      now: DateTime.add(@now, 300, :second)
    )
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("article.lab-chat-message")
    |> Enum.to_list()
  end

  defp send_message(event_id, now, message, options \\ []) do
    ConversationLab.send_message(@conversation_id, message, profile(),
      attachments: Keyword.get(options, :attachments, []),
      id_generator: fn -> event_id end,
      now: fn -> now end
    )
  end

  defp profile do
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "conversation-read",
        policy_digest: @digest,
        repository_ref: nil
      })

    profile
  end

  defp admission_options(fake, now) do
    [
      executor_options: [
        api: FakeCoopAPI,
        client: fake,
        max_polls: 10,
        now: fn -> now end,
        policy: "admission-read-only",
        policy_digest: @digest,
        poll_interval_ms: 0,
        sleep: fn _milliseconds -> :ok end
      ],
      lease_seconds: 300,
      now: fn -> now end,
      retry_base_ms: 1_000,
      retry_max_ms: 60_000,
      worker_ref: "conversation-lab-admission:#{DateTime.to_unix(now)}"
    ]
  end

  defp work_options(fake, suffix) do
    [
      executor_options: [
        api: FakeWorkCoopAPI,
        client: fake,
        max_block_ms: 1_000,
        max_polls: 20,
        monotonic_ms: fn -> 0 end,
        now: fn -> @now end,
        poll_interval_ms: 0,
        sleep: fn _milliseconds -> :ok end
      ],
      lease_seconds: 60,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "conversation-lab-work:#{suffix}"
    ]
  end

  defp delivery_options(suffix, kind \\ :message) do
    {:ok, adapters} =
      Adapters.new(%{
        "control_plane" => %{
          binding: nil,
          message_publisher: Publisher,
          reaction_publisher: Publisher
        }
      })

    [
      adapters: adapters,
      kind: kind,
      lease_seconds: 60,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "conversation-lab-delivery:#{suffix}"
    ]
  end

  defp retention_options(fake, suffix) do
    [
      api: FakeWorkCoopAPI,
      client: fake,
      closed_session_grace_seconds: 900,
      lease_seconds: 60,
      max_attempts: 8,
      retained_recheck_seconds: 21_600,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "conversation-lab-retention:#{suffix}"
    ]
  end

  defp decision(:start_episode, nil) do
    Jason.encode!(%{
      "action" => "start_episode",
      "episode_ref" => nil,
      "messages" => nil,
      "reactions" => nil,
      "relation" => "unrelated",
      "repository" => nil,
      "repository_source" => nil,
      "reason" => "The first local message starts one durable conversation episode.",
      "work_class" => "standard"
    })
  end

  defp decision(:continue_episode, candidate_ref) do
    Jason.encode!(%{
      "action" => "continue_episode",
      "episode_ref" => candidate_ref,
      "messages" => nil,
      "reactions" => nil,
      "relation" => "same_work",
      "repository" => nil,
      "repository_source" => nil,
      "reason" => "The local follow-up explicitly depends on the prior answer in this thread.",
      "work_class" => "standard"
    })
  end

  defp decision(:react, nil) do
    Jason.encode!(%{
      "action" => "react",
      "episode_ref" => nil,
      "messages" => nil,
      "reactions" => ["eyes"],
      "relation" => "unrelated",
      "repository" => nil,
      "repository_source" => nil,
      "reason" => "A nonverbal acknowledgement is sufficient for this local message.",
      "work_class" => nil
    })
  end

  # Freezes, binds and accepts one reply on a manually claimed turn, the way
  # the Work executor does once Coop returns the candidate.
  defp accept_reply!(claim, document, suffix) do
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
               "coop-session:#{suffix}"
             )

    assert {:ok, _turn} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:#{suffix}"
             )

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

    assert {:ok, result} = Result.new(:reply, Map.delete(document, "title"))

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
               "validation-receipt:#{suffix}"
             )

    accepted
  end

  defp quick_answer(messages, reactions \\ nil) do
    Jason.encode!(%{
      "action" => "quick_reply",
      "episode_ref" => nil,
      "messages" => List.wrap(messages),
      "reactions" => reactions,
      "relation" => "unrelated",
      "repository" => nil,
      "repository_source" => nil,
      "reason" => "A greeting needs a short answer, not work.",
      "work_class" => nil
    })
  end

  defp work_reply(message) do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => message,
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [],
        "state" => "complete"
      }
    })
  end

  defp work_reply(message, title) do
    message |> work_reply() |> Jason.decode!() |> Map.put("title", title) |> Jason.encode!()
  end

  defp conversation_ref, do: "control-plane:lab:#{@conversation_id}"
end
