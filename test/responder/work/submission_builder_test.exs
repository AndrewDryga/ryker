defmodule Responder.Work.SubmissionBuilderTest do
  use Responder.DataCase, async: true

  alias Responder.{Artifacts, Episodes}
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Responder.GitHub.SourceRef, as: GitHubSourceRef
  alias Responder.Slack.SourceRef
  alias Responder.State.{BehaviorChangeset, MemoryEntryChangeset, RecordChangeset, Records}
  alias Responder.State.{Continuity, ConversationObservation, KnowledgeSnapshot}
  alias Responder.Work.{Custody, DeliveryReceipt, Final, Result, Submission, SubmissionBuilder}

  @now ~U[2026-08-28 12:00:00.000000Z]

  for {text, offered?} <- [
        {"Why did the quasar billing subscription renew?", false},
        {"What did we decide about draft-ai-suggestions?", true}
      ] do
    test "Work selects knowledge for the active request #{inspect(text)}" do
      # Unrelated recent topic injection spread source lineage and filled the
      # memory budget even though the model had no reason to see that subject.
      claim = claim_episode!("topic-relevance", unquote(text))

      {_source, topic} =
        KnowledgeFixtures.learn!(claim.episode, claim.session.repository_ref)

      assert {:ok, submission} = SubmissionBuilder.build(claim)

      knowledge =
        get_in(submission, ["context", "operator_context", "continuity", "knowledge"]) || []

      assert Enum.any?(knowledge, &(&1["source_ref"] == topic["source_ref"])) == unquote(offered?)
    end
  end

  test "the first turn is a self-contained universal briefing with one attached final schema" do
    initial = String.duplicate("a", 1_500) <> " ORIGINAL_REQUEST_MARKER"
    claim = claim_episode!("full-briefing", initial)

    assert {:ok, submission} = SubmissionBuilder.build(claim)
    assert submission["context"]["mode"] == "full"
    assert submission["context"]["inputs"]["omitted_count"] == 0
    assert [current] = submission["context"]["inputs"]["items"]
    assert current["content"] == %{"text" => initial}
    assert current["source_ref"] == hd(claim.episode.active_input_refs)
    assert submission["output_schema"] == Final.json_schema()
    assert submission["contract_version"] == "work-final-v1"
    assert submission["prompt"] =~ "ORIGINAL_REQUEST_MARKER"
    refute submission["prompt"] =~ ~s("response_schema")
    refute submission["prompt"] =~ ~s("$schema")
  end

  test "a Slack briefing exposes an opaque exact message ref for source and action tools" do
    assert {:ok, _} =
             Responder.Instructions.save(
               {:channel, "TD0983425B9D3", "C456"},
               "Use channel context.",
               0,
               "operator:test"
             )

    id = Ecto.UUID.generate()

    payload = %{
      "actor" => %{"kind" => "user", "ref" => "U123"},
      "content" => %{"text" => "Please acknowledge this."},
      "destination" => %{
        "conversation_ref" => "slack:TD0983425B9D3:C456",
        "thread_ref" => "1787832000.000100",
        "transport" => "slack"
      },
      "event_kind" => "message",
      "event_ref" => "Ev-source-ref",
      "native_input_id" => "slack-message:source-ref",
      "occurred_at" => DateTime.to_iso8601(@now),
      "occurred_at_source" => "source",
      "revision" => 1,
      "source" => %{"kind" => "slack", "ref" => "TD0983425B9D3"},
      "source_capabilities" => %{"react" => %{"emoji_names" => nil}},
      "source_item_ref" => "1787832001.000200"
    }

    claim =
      claim_episode_payload!("slack-source-ref", payload,
        episode_id: id,
        destination: %{
          conversation_ref: "slack:TD0983425B9D3:C456",
          thread_ref: "1787832000.000100",
          transport: "slack"
        }
      )

    assert {:ok, submission} = SubmissionBuilder.build(claim)
    assert [input] = submission["context"]["inputs"]["items"]

    assert input["source_ref"] ==
             SourceRef.message("TD0983425B9D3", "C456", "1787832001.000200")

    assert submission["context"]["custom_instructions"]["channel"] == %{
             "scope" => "slack:TD0983425B9D3:C456",
             "revision" => 1,
             "text" => "Use channel context."
           }
  end

  test "a GitHub briefing exposes an opaque exact comment ref for native emoji actions" do
    id = Ecto.UUID.generate()

    payload = %{
      "actor" => %{"kind" => "user", "ref" => "github-user:42"},
      "content" => %{"payload" => %{"comment" => %{"body" => "Looks good."}}},
      "destination" => %{
        "conversation_ref" => "github:github-main:repository:2001",
        "thread_ref" => "github:github-main:pull:42",
        "transport" => "github"
      },
      "source" => %{"kind" => "github", "ref" => "github-main"},
      "source_capabilities" => %{
        "react" => %{"emoji_names" => ~w(+1 -1 confused eyes heart hooray laugh rocket)}
      },
      "source_item_ref" => "github:issue_comment:9001"
    }

    claim =
      claim_episode_payload!("github-source-ref", payload,
        episode_id: id,
        destination: %{
          conversation_ref: "github:github-main:repository:2001",
          thread_ref: "github:github-main:pull:42",
          transport: "github"
        }
      )

    assert {:ok, submission} = SubmissionBuilder.build(claim)
    assert [input] = submission["context"]["inputs"]["items"]

    assert input["source_ref"] == GitHubSourceRef.item("github-main", "issue_comment", 9_001)
    assert submission["context"]["offer_confirmation_supported"]

    assert "propose_automation" in submission["context"]["responder_state_tools"]
    assert "propose_memory" in submission["context"]["responder_state_tools"]
    assert "request_task" in submission["context"]["responder_state_tools"]

    assert "request_input" in submission["context"]["responder_state_tools"]
    assert "record_feedback" in submission["context"]["responder_state_tools"]
  end

  test "a Conversation Lab briefing exposes confirmable state offers through Work" do
    conversation_ref = "control-plane:lab:9a51fa43-977f-4b27-93f6-0c2ad3652ddc"

    claim =
      claim_episode_payload!("lab-confirmation-surface", %{"text" => "Plan this work."},
        destination: %{
          conversation_ref: conversation_ref,
          thread_ref: conversation_ref,
          transport: "control_plane"
        }
      )

    assert {:ok, submission} = SubmissionBuilder.build(claim)
    names = submission["context"]["responder_state_tools"]

    assert submission["context"]["offer_confirmation_supported"]
    assert "propose_automation" in names
    assert "propose_memory" in names
    assert "request_task" in names
  end

  test "passive emoji feedback is ordered context for the next model turn" do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: id,
        episode_key: "work-submission:reaction-feedback:#{id}",
        native_input_id: "source:reaction-feedback:#{id}",
        occurred_at: @now,
        payload: %{"text" => "Summarize the result."},
        turn_ref: "turn:reaction-feedback:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, reaction} =
             Episodes.apply(
               EpisodeFixtures.record_reaction(%{
                 actor_ref: "control-plane:operator",
                 emoji_name: "eyes",
                 episode_key: command.episode_key,
                 event_ref: "control-plane-reaction:feedback-1",
                 occurred_at: DateTime.add(@now, 1, :second),
                 source: %{kind: "control_plane", ref: "conversation-lab"},
                 target_delivery_ref: "delivery:previous-reply",
                 target_message_ref: "control-plane-message:previous-reply"
               })
             )

    assert reaction.episode.owner_ref == command.turn_ref

    assert {:ok, _second_reaction} =
             Episodes.apply(
               EpisodeFixtures.record_reaction(%{
                 actor_ref: "control-plane:teammate",
                 emoji_name: "eyes",
                 episode_key: command.episode_key,
                 event_ref: "control-plane-reaction:feedback-2",
                 occurred_at: DateTime.add(@now, 2, :second),
                 source: %{kind: "control_plane", ref: "conversation-lab"},
                 target_delivery_ref: "delivery:previous-reply",
                 target_message_ref: "control-plane-message:previous-reply"
               })
             )

    assert {:ok, _removed_reaction} =
             Episodes.apply(
               EpisodeFixtures.record_reaction(%{
                 action: :remove,
                 actor_ref: "control-plane:operator",
                 emoji_name: "eyes",
                 episode_key: command.episode_key,
                 event_ref: "control-plane-reaction:feedback-3",
                 occurred_at: DateTime.add(@now, 3, :second),
                 source: %{kind: "control_plane", ref: "conversation-lab"},
                 target_delivery_ref: "delivery:previous-reply",
                 target_message_ref: "control-plane-message:previous-reply"
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(command.episode_id, "work-read-only", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:reaction-feedback", 60)
    assert {:ok, submission} = SubmissionBuilder.build(claim)

    added = %{
      "action" => "add",
      "actor_ref" => "control-plane:operator",
      "emoji_name" => "eyes",
      "occurred_at" => DateTime.to_iso8601(DateTime.add(@now, 1, :second)),
      "target_delivery_ref" => "delivery:previous-reply",
      "target_message_ref" => "control-plane-message:previous-reply"
    }

    teammate = %{
      added
      | "actor_ref" => "control-plane:teammate",
        "occurred_at" => DateTime.to_iso8601(DateTime.add(@now, 2, :second))
    }

    removed = %{
      added
      | "action" => "remove",
        "occurred_at" => DateTime.to_iso8601(DateTime.add(@now, 3, :second))
    }

    assert submission["context"]["conversation_feedback"] == %{
             "current" => [
               %{
                 "actor_refs" => ["control-plane:teammate"],
                 "count" => 1,
                 "emoji_name" => "eyes",
                 "target_delivery_ref" => "delivery:previous-reply",
                 "target_message_ref" => "control-plane-message:previous-reply"
               }
             ],
             "events" => [added, teammate, removed]
           }
  end

  test "a frozen claim cannot see reaction feedback recorded for a later snapshot" do
    claim = claim_episode!("reaction-snapshot", "FIRST_TURN_ONLY")

    assert {:ok, _reaction} =
             Episodes.apply(
               EpisodeFixtures.record_reaction(%{
                 episode_key: claim.episode.key,
                 event_ref: "slack-reaction:after-claim",
                 occurred_at: DateTime.add(@now, 1, :second)
               })
             )

    assert {:ok, submission} = SubmissionBuilder.build(claim)

    assert submission["context"]["conversation_feedback"] == %{
             "current" => [],
             "events" => []
           }
  end

  test "the frozen briefing uses admission-pinned repository scope instead of event content" do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: id,
        episode_key: "work-submission:trusted-repository:#{id}",
        native_input_id: "source:trusted-repository:#{id}",
        occurred_at: @now,
        payload: %{
          "source" => %{"kind" => "github"},
          "content" => %{
            "payload" => %{"repository" => %{"full_name" => "attacker/untrusted"}}
          }
        },
        turn_ref: "turn:trusted-repository:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(
               command.episode_id,
               "work-read-only",
               String.duplicate("a", 64),
               "owner/trusted"
             )

    assert {:ok, claim} = Custody.claim_next("worker:trusted-repository", 60)
    assert {:ok, submission} = SubmissionBuilder.build(claim)
    assert submission["context"]["repository_ref"] == "owner/trusted"
    assert submission["prompt"] =~ "host owns destination, identity, repository scope"
  end

  test "the briefing names the fixed state tools without exposing the session binding" do
    claim = claim_episode!("state-tools", "Please prepare an engineering task.")
    assert {:ok, initial} = SubmissionBuilder.build(claim)

    assert :ok =
             KnowledgeSnapshot.expose_submission(%{
               claim
               | turn: %{claim.turn | submission: initial}
             })

    assert {:ok, record} =
             Records.create(Records.token(claim.turn), "task-1", "task_offer", %{
               "kind" => "engineering",
               "prompt" => "Implement the requested change and run focused tests.",
               "repository" => "responder",
               "title" => "Implement requested change"
             })

    assert {:ok, submission} = SubmissionBuilder.build(claim)

    assert submission["context"]["responder_state_tools"] ==
             ~w(get_work_state cite_source record_finding request_input wait_for list_automations get_automation propose_automation plan_goal update_goal request_task search_memory propose_memory update_conversation_summary record_feedback validate_final)

    refute Map.has_key?(submission["context"], "state_tools")
    refute submission["prompt"] =~ Records.token(claim.turn)

    assert [model_record] = submission["context"]["records"]
    assert model_record["ref"] == record.ref
    assert model_record["kind"] == "task_offer"
    assert model_record["payload"] == record.payload
    assert submission["prompt"] =~ "validate_final"
    assert submission["prompt"] =~ record.ref
  end

  test "the briefing names only state tools owned by the exact runtime and destination" do
    claim = claim_episode!("state-tool-capabilities", "Check the current state safely.")

    assert {:ok, unbound} =
             SubmissionBuilder.build(claim, state_tool_capabilities: nil)

    assert unbound["context"]["responder_state_tools"] == []

    assert {:ok, schedule_only} =
             SubmissionBuilder.build(claim, state_tool_capabilities: [:schedules])

    names = schedule_only["context"]["responder_state_tools"]
    refute "wait_for" in names
    assert "propose_automation" in names
    assert "validate_final" in names

    assert {:ok, governed} =
             SubmissionBuilder.build(claim,
               state_tool_capabilities: [:emisar_approvals, :event_waits]
             )

    assert "record_emisar_approval" in governed["context"]["responder_state_tools"]
  end

  test "an observe-only Slack briefing omits confirmation tools it cannot execute" do
    claim =
      claim_episode_payload!("shadow-state-tools", %{"text" => "Assess this without acting."},
        execution_mode: :shadow
      )

    assert {:ok, submission} = SubmissionBuilder.build(claim)
    names = submission["context"]["responder_state_tools"]

    refute submission["context"]["offer_confirmation_supported"]
    refute "propose_automation" in names
    refute "propose_memory" in names
    refute "request_task" in names
    assert "cite_source" in names
    assert "validate_final" in names
  end

  test "the frozen briefing names the exact connected platform capability tools" do
    claim = claim_episode!("platform-tools", "Find the earlier deploy and summarize it here.")

    assert {:ok, submission} =
             SubmissionBuilder.build(claim,
               platform_tools: [
                 %{"name" => "list_slack_channels"},
                 %{"name" => "search_slack"},
                 %{"name" => "read_slack_source"},
                 %{"name" => "set_slack_reaction"},
                 %{"name" => "post_slack_message"}
               ]
             )

    assert submission["context"]["source_and_action_tools"] == [
             "list_slack_channels",
             "search_slack",
             "read_slack_source",
             "set_slack_reaction",
             "post_slack_message"
           ]

    assert submission["prompt"] =~ "source_and_action_tools"
  end

  test "the frozen Lab briefing exposes generic and Slack-compatible local tools but not GitHub authority" do
    conversation_ref = "control-plane:lab:#{Ecto.UUID.generate()}"

    claim =
      claim_episode_payload!(
        "control-plane-tools",
        %{"text" => "Inspect Emisar and exercise the local Slack-compatible chat surface."},
        destination: %{
          conversation_ref: conversation_ref,
          thread_ref: conversation_ref,
          transport: "control_plane"
        }
      )

    assert {:ok, submission} =
             SubmissionBuilder.build(claim,
               platform_tools: [
                 "list_runners",
                 %{"name" => "list_slack_channels"},
                 %{"name" => "set_github_reaction"},
                 "find_actions"
               ]
             )

    assert submission["context"]["source_and_action_tools"] == [
             "list_runners",
             "list_slack_channels",
             "find_actions"
           ]
  end

  test "confirmed preferences and advisory guidance enter the frozen turn context" do
    claim = claim_episode!("operator-context", "Review the current Terraform plan.")

    assert {:ok, preference_offer} =
             Records.create(Records.token(claim.turn), "preference", "preference_offer", %{
               "expires_in" => "90d",
               "key" => "response_detail",
               "repository" => nil,
               "scope" => "operator",
               "value" => "concise"
             })

    assert {:ok, guidance_offer} =
             Records.create(Records.token(claim.turn), "guidance", "guidance_offer", %{
               "expires_in" => "30d",
               "repository" => nil,
               "scope" => "conversation",
               "subject" => "terraform-review",
               "summary" => "Lead with availability risk and drift.",
               "text" => "Explain availability and drift before resource counts.",
               "visibility" => "conversation"
             })

    assert {:ok, memory_offer} =
             Records.create(Records.token(claim.turn), "memory", "memory_offer", %{
               "expires_in" => "90d",
               "kind" => "repository_binding",
               "repository" => nil,
               "scope" => "conversation",
               "subject" => "primary_repository",
               "value" => "responder",
               "visibility" => "conversation"
             })

    insert_behavior!(preference_offer, :preference, :operator, "slack:user:U1", "response_detail")
    insert_behavior!(guidance_offer, :guidance, :conversation, "C-alerts", "terraform-review")
    insert_memory!(memory_offer, claim.episode)

    assert {:ok, submission} = SubmissionBuilder.build(claim)

    assert submission["context"]["operator_context"]["preferences"]["response_detail"] == %{
             "behavior_ref" => "behavior:preference",
             "scope" => "operator",
             "value" => "concise"
           }

    assert [guidance] = submission["context"]["operator_context"]["guidance"]
    assert guidance["behavior_ref"] == "behavior:guidance"
    assert guidance["text"] =~ "availability and drift"
    assert [memory] = submission["context"]["operator_context"]["memory"]
    assert memory["memory_ref"] == "memory:primary-repository"
    assert memory["subject"] == "primary_repository"
    assert memory["value"] == "responder"
    assert memory["source"]["conversation_ref"] == "C-alerts"
    assert submission["prompt"] =~ "Confirmed memory and guidance"
    assert submission["prompt"] =~ "not evidence or authority"
    assert submission["prompt"] =~ "potentially stale"
  end

  test "only attachments visible to this logical turn enter its frozen artifact manifest" do
    assert {:ok, current_artifact} =
             Artifacts.put(%{
               data: "current diagnostic",
               media_type: "text/plain",
               name: "current.txt",
               source_kind: "slack",
               source_ref: "TD0983425B9D3:F-current"
             })

    first =
      claim_episode_payload!("artifact-snapshot", %{
        "files" => [
          %{
            "artifact_ref" => current_artifact.ref,
            "status" => "available"
          }
        ],
        "text" => "Inspect the attached diagnostic."
      })

    assert {:ok, queued_artifact} =
             Artifacts.put(%{
               data: "future diagnostic",
               media_type: "text/plain",
               name: "future.txt",
               source_kind: "slack",
               source_ref: "TD0983425B9D3:F-future"
             })

    assert {:ok, _queued} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: destination(first),
                 episode_id: first.episode.id,
                 episode_key: first.episode.key,
                 native_input_id: "source:artifact-snapshot:future",
                 occurred_at: DateTime.add(@now, 1, :second),
                 payload: %{
                   "files" => [
                     %{"artifact_ref" => queued_artifact.ref, "status" => "available"}
                   ],
                   "text" => "This belongs to the next turn."
                 },
                 turn_ref: "unused:artifact-snapshot"
               })
             )

    reloaded = Responder.Repo.get!(Responder.Episodes.Episode, first.episode.id)
    assert {:ok, submission} = SubmissionBuilder.build(%{first | episode: reloaded})
    assert submission["input_artifact_refs"] == [current_artifact.ref]
    refute submission["prompt"] =~ queued_artifact.ref
  end

  test "a continuation in the same Coop session sends a delta instead of the briefing again" do
    alias Responder.Instructions

    assert {:ok, _} = Instructions.save(:global, "Explain assumptions.", 0, "operator:test")
    initial = String.duplicate("a", 1_500) <> " ORIGINAL_REQUEST_MARKER"
    first = claim_episode!("delta-continuation", initial)
    assert {:ok, first_submission} = SubmissionBuilder.build(first)

    assert first_submission["context"]["custom_instructions"] ==
             Instructions.snapshot(destination(first))

    bind_remote_turn!(first, first_submission)

    assert {:ok, _} = Instructions.save(:global, "", 1, "operator:test")
    frozen = Responder.Repo.get!(Responder.Work.Turn, first.turn.id)
    assert frozen.submission["prompt"] == first_submission["prompt"]

    assert {:ok, _queued} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: destination(first),
                 episode_id: first.episode.id,
                 episode_key: first.episode.key,
                 native_input_id: "source:delta-answer",
                 occurred_at: DateTime.add(@now, 1, :second),
                 payload: %{"text" => "NEW_INPUT_MARKER: continue with the safer option"},
                 turn_ref: "unused:queued"
               })
             )

    candidate = ~s({"delivery":"none","message":null})
    candidate_sha256 = digest(candidate)

    assert {:ok, _staged} =
             Custody.stage_candidate(
               first.episode.id,
               first.turn.turn_ref,
               first.lease_ref,
               nil,
               nil,
               candidate,
               candidate_sha256,
               1
             )

    assert {:ok, result} =
             Result.new(:none, nil, "The first turn is superseded by queued feedback.")

    assert {:ok, _intent} =
             Custody.prepare_validation(
               first.episode.id,
               first.turn.turn_ref,
               first.lease_ref,
               candidate_sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               first.episode.id,
               first.episode.key,
               first.turn.turn_ref,
               first.lease_ref,
               candidate_sha256,
               1,
               "validation:delta-first"
             )

    assert accepted.episode.owner_kind == :turn
    assert {:ok, second} = Custody.claim_next("worker:delta-second", 60)
    assert second.session.id == first.session.id

    assert {:ok, delta} = SubmissionBuilder.build(second)
    assert delta["context"]["mode"] == "continuation"

    assert delta["context"]["custom_instructions"]["global"] == %{
             "scope" => "global",
             "revision" => 2,
             "text" => ""
           }

    assert Jason.decode!(delta["prompt"])["work"]["custom_instructions"] ==
             delta["context"]["custom_instructions"]

    assert delta["context"]["parent_submission_ref"] == Submission.fingerprint(first_submission)
    assert delta["prompt"] =~ "NEW_INPUT_MARKER"
    refute delta["prompt"] =~ String.duplicate("a", 500)
    assert delta["context"]["continuity"]["first_input"]["content"]["truncated"]

    assert delta["context"]["continuity"]["first_input"]["source_ref"] ==
             first_submission["context"]["inputs"]["items"] |> hd() |> Map.fetch!("source_ref")

    assert byte_size(delta["prompt"]) < byte_size(first_submission["prompt"])

    assert {:ok, rotated} =
             Custody.rotate_session(
               second.episode.id,
               second.turn.turn_ref,
               second.lease_ref,
               second.session.generation
             )

    replacement = %{second | session: rotated.session, turn: rotated.turn}
    assert {:ok, replacement_submission} = SubmissionBuilder.build(replacement)
    assert replacement_submission["context"]["mode"] == "full"
    assert replacement_submission["prompt"] =~ "ORIGINAL_REQUEST_MARKER"
    assert replacement_submission["prompt"] =~ "NEW_INPUT_MARKER"

    assert replacement_submission["context"]["prior_outcome"]["submission_ref"] ==
             Submission.fingerprint(first_submission)
  end

  test "the builder rejects a value that is not a complete leased claim" do
    assert SubmissionBuilder.build(%{}) ==
             {:error, {:invalid_work_submission_builder, :claim}}
  end

  test "optional learned notes cannot crowd the exact current input out of a full briefing" do
    text = String.duplicate("CURRENT_REQUEST ", 3_000)
    claim = claim_episode!("notes-full-budget", text)
    seed_large_observations!(claim)
    assert_bounded_with_notes(claim, "inputs", text)
  end

  test "optional learned notes leave room for the current continuation and final workspace metadata" do
    first = claim_episode!("notes-continuation-budget", "initial")
    {:ok, submission} = SubmissionBuilder.build(first)
    bind_remote_turn!(first, submission)
    text = String.duplicate("CURRENT_REQUEST ", 3_000)

    {:ok, _} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          destination: destination(first),
          episode_id: first.episode.id,
          episode_key: first.episode.key,
          native_input_id: "source:notes-next",
          occurred_at: DateTime.add(@now, 1, :second),
          payload: %{"text" => text},
          turn_ref: "unused:notes-next"
        })
      )

    candidate = ~s({"delivery":"none","message":null})
    hash = digest(candidate)

    {:ok, _} =
      Custody.stage_candidate(
        first.episode.id,
        first.turn.turn_ref,
        first.lease_ref,
        nil,
        nil,
        candidate,
        hash,
        1
      )

    {:ok, result} = Result.new(:none, nil, "The first turn is superseded by queued feedback.")

    {:ok, _} =
      Custody.prepare_validation(
        first.episode.id,
        first.turn.turn_ref,
        first.lease_ref,
        hash,
        1,
        :accept,
        result
      )

    {:ok, _} =
      Custody.accept_result(
        first.episode.id,
        first.episode.key,
        first.turn.turn_ref,
        first.lease_ref,
        hash,
        1,
        "validation:notes-first"
      )

    {:ok, second} = Custody.claim_next("worker:notes-second", 60)
    assert second.session.id == first.session.id
    seed_large_observations!(second)
    assert_bounded_with_notes(second, "current_inputs", text)
  end

  defp assert_bounded_with_notes(claim, input_key, text) do
    instructions = String.duplicate("🌱", 2_000)
    assert {:ok, _} = Responder.Instructions.save(:global, instructions, 0, "operator:test")

    assert {:ok, submission} =
             SubmissionBuilder.build(claim,
               workspace: %{"description" => String.duplicate("w", 15_000)}
             )

    assert submission["context"]["custom_instructions"]["global"]["text"] == instructions

    assert [current] = submission["context"][input_key]["items"]
    assert current["content"] == %{"text" => text}

    assert length(
             get_in(submission, ["context", "operator_context", "continuity", "observations"]) ||
               []
           ) < 16

    assert byte_size(Responder.CanonicalJSON.encode!(submission["context"])) <= 160 * 1_024
    assert byte_size(submission["prompt"]) <= 256 * 1_024
  end

  defp seed_large_observations!(claim) do
    # Structural boundary mutation: legal multibyte notes, not a manufactured model behavior fixture.
    {:ok, scope} = Continuity.destination_context(claim.episode, claim.session.repository_ref)

    note = %{
      "summary" => String.duplicate("😀", 1_200),
      "topics" => Enum.map(1..8, &(to_string(&1) <> String.duplicate("😀", 79)))
    }

    for _ <- 1..16 do
      id = Ecto.UUID.generate()

      Repo.insert!(
        struct!(
          ConversationObservation,
          Map.merge(scope, %{
            id: id,
            identity_key: id,
            source_input_id: id,
            source_message_ref: "1787832000.000100",
            source_result_ref: "budget-test",
            source_fingerprint: String.duplicate("a", 64),
            actor_ref: "U123",
            execution_mode: :shadow,
            revision: 1,
            occurred_at: @now,
            note: note
          })
        )
      )
    end
  end

  test "a frozen claim cannot see input admitted for the following logical turn" do
    claim = claim_episode!("claim-snapshot", "FIRST_TURN_ONLY")

    assert {:ok, _queued} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: destination(claim),
                 episode_id: claim.episode.id,
                 episode_key: claim.episode.key,
                 native_input_id: "source:claim-snapshot:later",
                 occurred_at: DateTime.add(@now, 1, :second),
                 payload: %{"text" => "NEXT_TURN_ONLY"},
                 turn_ref: "unused:claim-snapshot"
               })
             )

    assert {:ok, submission} = SubmissionBuilder.build(claim)
    assert submission["prompt"] =~ "FIRST_TURN_ONLY"
    refute submission["prompt"] =~ "NEXT_TURN_ONLY"
  end

  test "queued future inputs never appear as truncated history in the current turn" do
    active_text = String.duplicate("CURRENT_REQUEST_MUST_REMAIN_EXACT ", 1_300)
    first = claim_episode!("bounded-history", active_text)

    Enum.each(1..45, fn index ->
      assert {:ok, _queued} =
               Episodes.apply(
                 EpisodeFixtures.admit_input(%{
                   destination: destination(first),
                   episode_id: first.episode.id,
                   episode_key: first.episode.key,
                   native_input_id: "source:history:#{index}",
                   occurred_at: DateTime.add(@now, index, :second),
                   payload: %{
                     "text" => "FUTURE_INPUT_#{index}:" <> String.duplicate("x", 5_000)
                   },
                   turn_ref: "unused:#{index}"
                 })
               )
    end)

    reloaded = Responder.Repo.get!(Responder.Episodes.Episode, first.episode.id)
    assert {:ok, submission} = SubmissionBuilder.build(%{first | episode: reloaded})

    items = submission["context"]["inputs"]["items"]
    assert [current] = items
    assert current["content"] == %{"text" => active_text}
    assert current["current"]
    assert current["occurred_at"] == DateTime.to_iso8601(@now)
    assert current["revision"] == 1
    assert submission["context"]["inputs"]["omitted_count"] == 0
    Enum.each(1..45, &refute(submission["prompt"] =~ "FUTURE_INPUT_#{&1}:"))
  end

  test "a continuation advances a large exact pair without losing the remainder" do
    first = claim_episode!("active-input-overflow", "initial")
    assert {:ok, first_submission} = SubmissionBuilder.build(first)
    bind_remote_turn!(first, first_submission)

    Enum.each(1..41, fn index ->
      text = String.duplicate("CURRENT_INSTRUCTION_#{index}_", 180)

      assert {:ok, _queued} =
               Episodes.apply(
                 EpisodeFixtures.admit_input(%{
                   destination: destination(first),
                   episode_id: first.episode.id,
                   episode_key: first.episode.key,
                   native_input_id: "source:active:#{index}",
                   occurred_at: DateTime.add(@now, index, :second),
                   payload: %{"text" => text},
                   turn_ref: "unused:active:#{index}"
                 })
               )
    end)

    before_delivery = Responder.Repo.get!(Responder.Episodes.Episode, first.episode.id)
    assert {:ok, still_first} = SubmissionBuilder.build(%{first | episode: before_delivery})
    assert still_first["context"]["inputs"]["omitted_count"] == 0
    refute still_first["prompt"] =~ "CURRENT_INSTRUCTION_1_"

    candidate = ~s({"delivery":"reply","message":"First result."})
    candidate_sha256 = digest(candidate)

    assert {:ok, _staged} =
             Custody.stage_candidate(
               first.episode.id,
               first.turn.turn_ref,
               first.lease_ref,
               nil,
               nil,
               candidate,
               candidate_sha256,
               1
             )

    assert {:ok, result} = Result.new(:reply, %{"message" => "First result."})

    assert {:ok, _intent} =
             Custody.prepare_validation(
               first.episode.id,
               first.turn.turn_ref,
               first.lease_ref,
               candidate_sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               first.episode.id,
               first.episode.key,
               first.turn.turn_ref,
               first.lease_ref,
               candidate_sha256,
               1,
               "validation:active-overflow"
             )

    assert {:ok, delivery} = Custody.claim_next("worker:active-overflow-delivery", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               first.episode.destination_transport,
               first.episode.destination_conversation_ref,
               first.episode.destination_thread_ref,
               "1787932807.004100"
             )

    assert {:ok, delivered} =
             Custody.confirm_delivery(
               first.episode.id,
               first.episode.key,
               first.turn.turn_ref,
               delivery.lease_ref,
               receipt
             )

    assert length(delivered.episode.active_input_refs) == 2
    assert length(delivered.episode.queued_input_refs) == 39
    assert {:ok, continuation} = Custody.claim_next("worker:active-overflow-next", 60, :work)

    assert {:ok, submission} = SubmissionBuilder.build(continuation)
    items = submission["context"]["current_inputs"]["items"]
    assert length(items) == 2
    assert Enum.all?(items, & &1["current"])

    assert Enum.map(items, & &1["content"]["text"]) ==
             Enum.map(1..2, &String.duplicate("CURRENT_INSTRUCTION_#{&1}_", 180))

    assert submission["context"]["current_inputs"]["omitted_count"] == 0
  end

  defp claim_episode!(suffix, text) do
    claim_episode_payload!(suffix, %{"text" => text})
  end

  defp claim_episode_payload!(suffix, payload, overrides \\ []) do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(
        %{
          episode_id: id,
          episode_key: "work-submission:#{suffix}:#{id}",
          native_input_id: "source:#{suffix}:#{id}",
          occurred_at: @now,
          payload: payload,
          turn_ref: "turn:#{suffix}:#{id}"
        }
        |> Map.merge(Map.new(overrides))
      )

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(command.episode_id, "work-read-only", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 60)
    claim
  end

  defp insert_behavior!(offer, kind, scope_kind, scope_ref, identity_key) do
    confirmed_at = @now

    assert {:ok, _confirmed} =
             offer
             |> RecordChangeset.confirm_resource(%{
               confirmed_at: confirmed_at,
               confirmed_by_actor_ref: "slack:user:U1",
               confirmation_ref: "interaction:#{identity_key}",
               status: :confirmed
             })
             |> Repo.update()

    payload = offer.payload
    ref = "behavior:#{if(kind == :preference, do: "preference", else: "guidance")}"

    assert {:ok, _behavior} =
             %{
               confirmed_at: confirmed_at,
               confirmed_by_actor_ref: "slack:user:U1",
               confirmation_ref: "interaction:#{identity_key}",
               expires_at: DateTime.add(confirmed_at, 30, :day),
               id: Ecto.UUID.generate(),
               identity_key: identity_key,
               kind: kind,
               offer_record_id: offer.id,
               payload: payload,
               ref: ref,
               scope_kind: scope_kind,
               scope_ref: scope_ref,
               source_conversation_ref: "C-alerts",
               source_message_ref: "1787832001.000200",
               source_thread_ref: "1787832000.000100",
               source_transport: "slack",
               status: :active,
               workspace_ref: "C-alerts"
             }
             |> BehaviorChangeset.insert()
             |> Repo.insert()
  end

  defp insert_memory!(offer, episode) do
    confirmed_at = @now
    payload = offer.payload

    assert {:ok, _confirmed} =
             offer
             |> RecordChangeset.confirm_resource(%{
               confirmed_at: confirmed_at,
               confirmed_by_actor_ref: "slack:user:U1",
               confirmation_ref: "interaction:memory",
               status: :confirmed
             })
             |> Repo.update()

    assert {:ok, _memory} =
             %{
               confirmation_ref: "interaction:memory",
               confirmed_at: confirmed_at,
               confirmed_by_actor_ref: "slack:user:U1",
               expires_at: DateTime.add(confirmed_at, 90, :day),
               id: Ecto.UUID.generate(),
               kind: :repository_binding,
               offer_record_id: offer.id,
               payload: payload,
               payload_fingerprint: Responder.CanonicalJSON.digest(payload),
               ref: "memory:primary-repository",
               scope_kind: :conversation,
               scope_ref: episode.destination_conversation_ref,
               source_conversation_ref: episode.destination_conversation_ref,
               source_message_ref: "1787832001.000200",
               source_thread_ref: episode.destination_thread_ref,
               source_transport: episode.destination_transport,
               status: :active,
               subject: payload["subject"],
               visibility: :conversation,
               workspace_ref: episode.destination_conversation_ref
             }
             |> MemoryEntryChangeset.insert()
             |> Repo.insert()
  end

  defp bind_remote_turn!(claim, submission) do
    assert {:ok, frozen} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert :ok = KnowledgeSnapshot.expose_submission(%{claim | turn: frozen})

    assert {:ok, session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:#{claim.episode.id}"
             )

    assert {:ok, _turn} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               frozen.submit_generation,
               "coop-turn:#{claim.turn.id}"
             )
  end

  defp destination(claim) do
    %{
      conversation_ref: claim.episode.destination_conversation_ref,
      thread_ref: claim.episode.destination_thread_ref,
      transport: claim.episode.destination_transport
    }
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
