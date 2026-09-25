defmodule Ryker.ControlPlane.ConversationLabEndToEndTest do
  use Ryker.DataCase, async: true

  @moduletag isolation: "REPEATABLE READ"

  import Ecto.Query

  alias Ryker.Admission.Dispatcher, as: AdmissionDispatcher
  alias Ryker.CanonicalJSON

  alias Ryker.ControlPlane.{
    Actions,
    CapabilityTools,
    ConversationLab,
    HTML,
    Projection,
    Publisher
  }

  alias Ryker.Delivery.{Adapters, PlatformAction, Reaction}

  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.WorkProfile
  alias Ryker.Repo
  alias Ryker.Retention.Dispatcher, as: RetentionDispatcher
  alias Ryker.State.{Record, Records}
  alias Ryker.TestSupport.{FakeCoopAPI, FakeWorkCoopAPI}

  alias Ryker.Work.{
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
  @now ~U[2026-08-30 18:00:00.000000Z]
  @digest String.duplicate("a", 64)

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
                   "match" => %{"run_id" => "run-okjyXsDYXyMqqBYY"},
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
        "I’m waiting for the next update on Terraform run run-okjyXsDYXyMqqBYY (va1-postgres). I’ll check again by 12:01 UTC and report any unverified outcome at the 12:26 UTC deadline."
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

      assert {:ok, conversation} = Projection.lab_conversation(@conversation_id)
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

    assert {:ok, conversation} = Projection.lab_conversation(@conversation_id)

    assert Enum.map(conversation.messages, &{&1.actor, &1.text}) == [
             {:operator, "Explain what the durable runtime knows about this request."},
             {:ryker, "The first durable response is ready."},
             {:operator, "Use the previous answer and tell me what persisted across the turn."},
             {:ryker, "The follow-up continued the same episode and Coop session."}
           ]

    assert [%{id: @conversation_id, message_count: 2}] = Projection.lab_index()
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

    assert %Reaction{status: :pending, document: %{"emoji_name" => "eyes"}} =
             Repo.get_by!(Reaction, input_id: admitted.result.entry.id)

    assert {:ok, {:delivered, :reaction, delivery_ref}} =
             Ryker.Delivery.Dispatcher.run_once(delivery_options("reaction", :reaction))

    assert %Reaction{status: :delivered} =
             Repo.get_by!(Reaction, input_id: admitted.result.entry.id)

    assert {:ok, conversation} = Projection.lab_conversation(@conversation_id)
    assert [message] = Enum.filter(conversation.messages, &(&1.actor == :operator))

    assert message.reactions == [
             %{delivery_ref: delivery_ref, emoji_name: "eyes", status: :delivered}
           ]

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

    assert {:ok, conversation} = Projection.lab_conversation(@conversation_id)

    assert [%{attachments: [attachment]}] =
             Enum.filter(conversation.messages, &(&1.actor == :ryker))

    assert attachment.name == "service-health.png"
    assert attachment.media_type == "image/png"
    assert attachment.bytes == byte_size(data)

    assert {:ok, artifact} =
             Projection.lab_artifact(@conversation_id, turn.id, artifact_ref)

    assert artifact.data == data
    assert artifact.sha256 == sha256

    assert [%{generated_files: [generated]}] =
             Enum.filter(conversation.messages, &(&1.actor == :ryker))

    assert generated.name == "generated-1.png"

    assert {:ok, %{data: ^unselected_data}} =
             Projection.lab_artifact(@conversation_id, turn.id, unselected["id"])

    assert Projection.lab_artifact(Ecto.UUID.generate(), turn.id, unselected["id"]) == :not_found

    assert Projection.lab_artifact(Ecto.UUID.generate(), turn.id, artifact_ref) == :not_found

    assert Projection.lab_artifact(@conversation_id, Ecto.UUID.generate(), artifact_ref) ==
             :not_found

    assert Projection.lab_artifact(@conversation_id, turn.id, "artifact_missing") == :not_found
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

    assert {:ok, conversation} = Projection.lab_conversation(@conversation_id)
    [operator, ryker] = conversation.messages

    assert operator.reactions == [
             %{delivery_ref: reaction_ref, emoji_name: "eyes", status: :delivered}
           ]

    assert [%{action: :confirm_post, kind: "slack_post_offer", ref: ^post_ref}] =
             ryker.cards

    actions = Actions.callbacks(profile(), %{})

    assert {:ok, %{action: %PlatformAction{action_ref: post_action_ref}, status: :confirmed}} =
             actions.act_on_lab_record.(@conversation_id, post_ref, :confirm_post, nil)

    assert {:ok, {:delivered, :action, ^post_action_ref}} =
             Ryker.Delivery.Dispatcher.run_once(delivery_options("capability-post", :action))

    assert {:ok, updated} = Projection.lab_conversation(@conversation_id)

    assert Enum.map(updated.messages, &{&1.actor, &1.text}) == [
             {:operator, "React to this, then offer a second local message for my confirmation."},
             {:ryker, "I prepared one additional local message for confirmation."},
             {:ryker, "This is the confirmed local follow-up."}
           ]

    assert %Turn{status: :settled} = Repo.get!(Turn, accepted.turn.id)
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
      "reaction" => nil,
      "relation" => "unrelated",
      "repository_source" => nil,
      "reason" => "The first local message starts one durable conversation episode.",
      "work_class" => "standard"
    })
  end

  defp decision(:continue_episode, candidate_ref) do
    Jason.encode!(%{
      "action" => "continue_episode",
      "episode_ref" => candidate_ref,
      "reaction" => nil,
      "relation" => "same_work",
      "repository_source" => nil,
      "reason" => "The local follow-up explicitly depends on the prior answer in this thread.",
      "work_class" => "standard"
    })
  end

  defp decision(:react, nil) do
    Jason.encode!(%{
      "action" => "react",
      "episode_ref" => nil,
      "reaction" => %{"emoji_name" => "eyes"},
      "relation" => "unrelated",
      "repository_source" => nil,
      "reason" => "A nonverbal acknowledgement is sufficient for this local message.",
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

  defp conversation_ref, do: "control-plane:lab:#{@conversation_id}"
end
