defmodule Responder.Slack.InteractionHandlerTest do
  use ExUnit.Case, async: true

  alias Responder.Slack.{Interaction, InteractionHandler}

  defmodule Directory do
    @behaviour Responder.Slack.MemberDirectory

    @impl true
    def user_allowed(%{allowed: allowed}, user_ref, workspace_ref) do
      send(allowed.observer, {:membership_checked, user_ref, workspace_ref})
      {:ok, MapSet.member?(allowed.users, user_ref)}
    end
  end

  defmodule Records do
    def fetch_many(["record:task_offer:engineering"]) do
      {:ok,
       [
         %{
           kind: "task_offer",
           payload: %{"kind" => "engineering", "repository" => "responder"},
           ref: "record:task_offer:engineering"
         }
       ]}
    end

    def fetch_many(["record:task_offer:incident"]) do
      {:ok,
       [
         %{
           kind: "task_offer",
           payload: %{"kind" => "incident", "repository" => nil},
           ref: "record:task_offer:incident"
         }
       ]}
    end

    def fetch_many(["record:input_request:question"]) do
      {:ok,
       [
         %{
           kind: "input_request",
           status: :open,
           payload: %{"choices" => ["One percent", "Stop"], "question" => "Choose"},
           ref: "record:input_request:question"
         }
       ]}
    end

    def fetch_many(["record:publication_offer:ready"]) do
      {:ok,
       [
         %{
           kind: "publication_offer",
           payload: %{
             "body" => "Implements the requested fix.",
             "title" => "Fix retries"
           },
           ref: "record:publication_offer:ready"
         }
       ]}
    end

    def fetch_many(["record:schedule_offer:daily"]) do
      {:ok,
       [
         %{
           kind: "schedule_offer",
           payload: %{
             "authority" => "read_only",
             "catch_up" => "latest",
             "expires_at" => nil,
             "recurrence" => %{"kind" => "daily", "time" => "09:00:00"},
             "repository" => nil,
             "task" => "Inspect current service health.",
             "timezone" => "Etc/UTC",
             "title" => "Daily service health"
           },
           ref: "record:schedule_offer:daily"
         }
       ]}
    end

    def fetch_many(["record:slack_post_offer:exact"]) do
      {:ok,
       [
         %{
           kind: "slack_post_offer",
           payload: %{
             "destination_ref" => "slack-source:v1:T123:C789:thread:1787832888.000300",
             "message" => "The deployment is healthy.",
             "requested_by_actor_ref" => "slack:user:U123"
           },
           ref: "record:slack_post_offer:exact"
         }
       ]}
    end

    def fetch_many(_refs), do: {:error, :state_record_not_found}
  end

  test "an active full member confirms engineering work under the trusted repository policy" do
    interaction = interaction("responder_start_engineering_task", "engineering")
    options = options(["U123"])

    assert {:ok, %{episode_id: "episode-1", outcome: :confirmed}} =
             InteractionHandler.handle(interaction, options)

    assert_receive {:membership_checked, "U123", "T123"}

    assert_receive {:task_confirmed, confirmation}
    assert confirmation.actor_ref == "slack:user:U123"

    assert confirmation.policy == %{
             digest: String.duplicate("b", 64),
             name: "responder-contributor"
           }

    assert confirmation.record_ref == "record:task_offer:engineering"

    assert confirmation.target == %{
             conversation_ref: "slack:T123:C456",
             message_ref: "1787832001.000200",
             thread_ref: "1787832000.000100",
             transport: "slack"
           }
  end

  test "channel setup rechecks full membership and configured operator authority" do
    interaction = %Interaction{
      action_id: "responder_setup_participation_proactive",
      action_value: Ecto.UUID.generate(),
      actor_ref: "U123",
      channel_ref: "C456",
      event_ref: "interaction:setup",
      message_ref: "1787832001.000200",
      occurred_at: ~U[2026-08-28 12:00:00.000000Z],
      thread_ref: nil,
      workspace_ref: "T123"
    }

    callback = fn selected ->
      send(self(), {:configuration_selected, selected})
      {:ok, %{outcome: :advanced, session_ref: selected.action_value}}
    end

    denied = Map.put(options(["U123"]), :configure_channel, callback)
    assert InteractionHandler.handle(interaction, denied) == {:ok, %{outcome: :denied}}

    allowed = %{denied | operators: MapSet.new(["U123"])}

    assert {:ok, %{outcome: :advanced, session_ref: session_ref}} =
             InteractionHandler.handle(interaction, allowed)

    assert session_ref == interaction.action_value
    assert_received {:configuration_selected, ^interaction}

    welcome = %{
      interaction
      | action_id: "responder_welcome_configure",
        action_value: "#{Ecto.UUID.generate()}|2",
        event_ref: "interaction:welcome"
    }

    assert InteractionHandler.handle(welcome, denied) == {:ok, %{outcome: :denied}}
    assert {:ok, %{outcome: :advanced}} = InteractionHandler.handle(welcome, allowed)
    assert_received {:configuration_selected, ^welcome}

    stale =
      Map.put(allowed, :configure_channel, fn _ -> {:error, :configuration_revision_stale} end)

    assert InteractionHandler.handle(welcome, stale) == {:ok, %{outcome: :invalid}}
  end

  test "guests cannot start tasks and incidents additionally require a configured operator" do
    assert {:ok, %{outcome: :denied}} =
             InteractionHandler.handle(
               interaction("responder_start_engineering_task", "engineering"),
               options([])
             )

    refute_received {:task_confirmed, _confirmation}

    assert {:ok, %{outcome: :denied}} =
             InteractionHandler.handle(
               interaction("responder_open_incident", "incident"),
               options(["U123"])
             )

    refute_received {:task_confirmed, _confirmation}

    assert {:ok, %{outcome: :requested, room_ref: "incident-room:1"}} =
             InteractionHandler.handle(
               interaction("responder_open_incident", "incident"),
               %{options(["U123"]) | operators: MapSet.new(["U123"])}
             )

    assert_receive {:incident_requested, confirmation}
    assert confirmation.policy.name == "incident-investigate"

    # Investigate shares the offer identity, the operator gate and the incident
    # policy with Create incident room; it never touches a repository.
    assert {:ok, %{outcome: :denied}} =
             InteractionHandler.handle(
               interaction("responder_investigate_incident", "incident"),
               options(["U123"])
             )

    refute_received {:incident_investigated, _attributes}

    assert {:ok, %{outcome: :confirmed, episode_id: "episode-incident"}} =
             InteractionHandler.handle(
               interaction("responder_investigate_incident", "incident"),
               %{options(["U123"]) | operators: MapSet.new(["U123"])}
             )

    assert_receive {:incident_investigated, investigation}

    assert investigation.policy == %{
             digest: String.duplicate("c", 64),
             name: "incident-investigate"
           }

    assert investigation.record_ref == "record:task_offer:incident"
    assert investigation.workspace_ref == "T123"
    assert investigation.target.thread_ref == "1787832000.000100"

    assert {:ok, %{outcome: :invalid}} =
             InteractionHandler.handle(
               interaction("responder_investigate_incident", "engineering"),
               %{options(["U123"]) | operators: MapSet.new(["U123"])}
             )

    refute_received {:incident_investigated, _attributes}
  end

  test "cross-kind controls and missing repository authority fail closed" do
    crossed = interaction("responder_open_incident", "engineering")
    assert InteractionHandler.handle(crossed, options(["U123"])) == {:ok, %{outcome: :invalid}}

    options = put_in(options(["U123"]), [:repositories], %{})

    assert InteractionHandler.handle(
             interaction("responder_start_engineering_task", "engineering"),
             options
           ) == {:error, {:slack_task_policy_not_configured, "responder"}}
  end

  test "an authenticated question choice becomes host-recorded generic input" do
    interaction = %{
      interaction("responder_start_engineering_task", "engineering")
      | action_id: "responder_answer_input",
        action_value: "record:input_request:question|1"
    }

    assert InteractionHandler.handle(interaction, options(["U123"])) ==
             {:ok, %{input_ref: "ingress-input:choice", outcome: :recorded}}

    assert_receive {:input_answered, answer}
    assert answer.actor_ref == "U123"
    assert answer.choice_index == 1
    assert answer.record_ref == "record:input_request:question"
    assert answer.response_ref == "interaction:engineering"
  end

  test "submit without a choice asks for a selection without answering the question" do
    missing = %{
      interaction("responder_start_engineering_task", "engineering")
      | action_id: "responder_submit_input",
        action_value: "record:input_request:question"
    }

    assert InteractionHandler.handle(missing, options(["U123"])) ==
             {:ok, %{outcome: :selection_required}}

    refute_received {:input_answered, _}
  end

  test "only a configured operator can queue review and approve the exact delivered review" do
    review = %{
      interaction("responder_start_engineering_task", "engineering")
      | action_id: "responder_review_publication",
        action_value: "record:publication_offer:ready",
        event_ref: "interaction:review"
    }

    assert InteractionHandler.handle(review, options(["U123"])) ==
             {:ok, %{outcome: :denied}}

    operator_options = %{options(["U123"]) | operators: MapSet.new(["U123"])}

    assert InteractionHandler.handle(review, operator_options) ==
             {:ok, %{publication_ref: "publication:1", outcome: :requested}}

    assert_receive {:publication_review_requested, request}
    assert request.record_ref == "record:publication_offer:ready"
    assert request.actor_ref == "slack:user:U123"

    publish = %{
      review
      | action_id: "responder_publish_draft",
        action_value: "publication:1",
        event_ref: "interaction:publish"
    }

    assert InteractionHandler.handle(publish, operator_options) ==
             {:ok, %{publication_ref: "publication:1", outcome: :approved}}

    assert_receive {:publication_approved, approval}
    assert approval.publication_ref == "publication:1"
    assert approval.target.message_ref == publish.message_ref
  end

  test "an authorized member can refresh exact publication delivery without mutation authority" do
    check = %{
      interaction("responder_start_engineering_task", "engineering")
      | action_id: "responder_check_publication",
        action_value: "publication:1",
        event_ref: "interaction:check-publication"
    }

    assert InteractionHandler.handle(check, options(["U123"])) ==
             {:ok, %{publication_ref: "publication:1", outcome: :requested}}

    assert_receive {:publication_checked, "publication:1", "interaction:check-publication"}
  end

  test "only a configured operator can confirm the exact delivered schedule" do
    schedule = %{
      interaction("responder_start_engineering_task", "engineering")
      | action_id: "responder_confirm_schedule",
        action_value: "record:schedule_offer:daily",
        event_ref: "interaction:schedule"
    }

    assert InteractionHandler.handle(schedule, options(["U123"])) ==
             {:ok, %{outcome: :denied}}

    operator_options = %{options(["U123"]) | operators: MapSet.new(["U123"])}

    assert InteractionHandler.handle(schedule, operator_options) ==
             {:ok, %{outcome: :confirmed, schedule_ref: "schedule:1"}}

    assert_receive {:schedule_confirmed, confirmation}
    assert confirmation.actor_ref == "slack:user:U123"
    assert confirmation.record_ref == "record:schedule_offer:daily"
    assert confirmation.confirmation_ref == "interaction:schedule"

    assert confirmation.target == %{
             conversation_ref: "slack:T123:C456",
             message_ref: "1787832001.000200",
             thread_ref: "1787832000.000100",
             transport: "slack"
           }
  end

  test "only a configured operator can apply an exact delivered automation change" do
    automation = %{
      interaction("responder_start_engineering_task", "engineering")
      | action_id: "responder_confirm_automation",
        action_value: "record:automation_change_offer:pause",
        event_ref: "interaction:automation-pause"
    }

    assert InteractionHandler.handle(automation, options(["U123"])) ==
             {:ok, %{outcome: :denied}}

    operator_options = %{options(["U123"]) | operators: MapSet.new(["U123"])}

    assert InteractionHandler.handle(automation, operator_options) ==
             {:ok, %{automation_id: "schedule:daily-health", outcome: :confirmed}}

    assert_receive {:automation_confirmed, confirmation}
    assert confirmation.actor_ref == "slack:user:U123"
    assert confirmation.record_ref == "record:automation_change_offer:pause"
    assert confirmation.confirmation_ref == "interaction:automation-pause"
  end

  test "the original full member can confirm one exact delivered Slack post offer" do
    interaction = %{
      interaction("responder_start_engineering_task", "engineering")
      | action_id: "responder_confirm_slack_post",
        action_value: "record:slack_post_offer:exact",
        event_ref: "interaction:slack-post"
    }

    assert InteractionHandler.handle(interaction, options(["U123"])) ==
             {:ok, %{action_ref: "platform-action:exact", outcome: :confirmed}}

    assert_receive {:slack_post_confirmed, confirmation}
    assert confirmation.actor_ref == "slack:user:U123"
    assert confirmation.confirmation_ref == "interaction:slack-post"
    assert confirmation.record_ref == "record:slack_post_offer:exact"
    assert confirmation.target.message_ref == interaction.message_ref
  end

  test "only a configured operator can confirm an exact delivered behavior offer" do
    behavior = %{
      interaction("responder_start_engineering_task", "engineering")
      | action_id: "responder_confirm_behavior",
        action_value: "record:guidance_offer:team-convention",
        event_ref: "interaction:behavior"
    }

    assert InteractionHandler.handle(behavior, options(["U123"])) ==
             {:ok, %{outcome: :denied}}

    operator_options = %{options(["U123"]) | operators: MapSet.new(["U123"])}

    assert InteractionHandler.handle(behavior, operator_options) ==
             {:ok, %{behavior_ref: "behavior:1", outcome: :confirmed}}

    assert_receive {:behavior_confirmed, confirmation}
    assert confirmation.actor_ref == "slack:user:U123"
    assert confirmation.record_ref == "record:guidance_offer:team-convention"
    assert confirmation.confirmation_ref == "interaction:behavior"
    assert confirmation.target.message_ref == behavior.message_ref
  end

  test "only a configured operator can confirm exact delivered operational memory" do
    memory = %{
      interaction("responder_start_engineering_task", "engineering")
      | action_id: "responder_confirm_memory",
        action_value: "record:memory_offer:primary-repository",
        event_ref: "interaction:memory"
    }

    assert InteractionHandler.handle(memory, options(["U123"])) ==
             {:ok, %{outcome: :denied}}

    operator_options = %{options(["U123"]) | operators: MapSet.new(["U123"])}

    assert InteractionHandler.handle(memory, operator_options) ==
             {:ok, %{memory_ref: "memory:1", outcome: :confirmed}}

    assert_receive {:memory_confirmed, confirmation}
    assert confirmation.actor_ref == "slack:user:U123"
    assert confirmation.record_ref == "record:memory_offer:primary-repository"
    assert confirmation.confirmation_ref == "interaction:memory"
    assert confirmation.target.message_ref == memory.message_ref
  end

  test "operators own destructive work controls while full members can inspect work" do
    stop =
      interaction("responder_stop_work", "stop")
      |> Map.put(:action_value, "task-card:abc123")

    member_options = options(["U123"])

    assert InteractionHandler.handle(stop, member_options) == {:ok, %{outcome: :denied}}
    refute_received {:work_stopped, _attributes}

    operator_options = %{member_options | operators: MapSet.new(["U123"])}

    assert InteractionHandler.handle(stop, operator_options) ==
             {:ok, %{outcome: :stopping, work_ref: "task-card:abc123"}}

    assert_receive {:work_stopped, stop_attributes}
    assert stop_attributes.actor_ref == "slack:user:U123"
    assert stop_attributes.request_ref == "interaction:stop"
    assert stop_attributes.target.message_ref == stop.message_ref

    close = %{stop | action_id: "responder_close_work", event_ref: "interaction:close"}

    assert InteractionHandler.handle(close, operator_options) ==
             {:ok, %{outcome: :closing, work_ref: "task-card:abc123"}}

    assert_receive {:work_closed, %{request_ref: "interaction:close"}}

    record = %{
      stop
      | action_id: "responder_work_record",
        action_value: "task-card:abc123|timeline",
        event_ref: "interaction:record"
    }

    assert InteractionHandler.handle(record, member_options) ==
             {:ok, %{outcome: :shown, record_kind: :timeline, work_ref: "task-card:abc123"}}

    assert_receive {:work_record_shown, %{request_ref: "interaction:record"}}
  end

  # A saved-entity card's Delete/Forget control names one exact resource and the
  # revision it was rendered from. A copied, stale or non-operator click must
  # never be reported as a deletion.
  test "message-surface removal controls resolve their exact resource and cannot claim a stale deletion" do
    observer = self()
    schedule_id = Ecto.UUID.generate()

    options =
      Map.merge(options(["U123", "U456"]), %{
        delete_behavior: fn ref, revision, actor_ref, workspace_ref, action_ref ->
          send(observer, {:behavior_deleted, ref, revision, actor_ref, workspace_ref, action_ref})
          {:ok, %{outcome: %{"status" => "deleted"}}}
        end,
        delete_schedule: fn ref, revision, _actor_ref, _workspace_ref, _action_ref ->
          send(observer, {:schedule_deleted, ref, revision})

          if revision == 2,
            do: {:ok, %{outcome: %{"status" => "deleted"}}},
            else: {:error, :schedule_revision_stale}
        end,
        forget_memory: fn ref, actor_ref, workspace_ref ->
          send(observer, {:memory_forgotten, ref, actor_ref, workspace_ref})
          {:ok, %{ref: ref}}
        end,
        operators: MapSet.new(["U123"])
      })

    delete = %{
      interaction("responder_delete_schedule", "schedule")
      | action_value: "schedule-control:schedule:#{schedule_id}:2",
        event_ref: "interaction:delete-schedule"
    }

    assert InteractionHandler.handle(delete, options) ==
             {:ok,
              %{outcome: :deleted, resource_ref: "schedule-control:schedule:#{schedule_id}:2"}}

    assert_received {:schedule_deleted, "schedule:" <> ^schedule_id, 2}

    stale = %{delete | action_value: "schedule-control:schedule:#{schedule_id}:1"}
    assert InteractionHandler.handle(stale, options) == {:ok, %{outcome: :invalid}}
    assert_received {:schedule_deleted, _ref, 1}

    member = %{delete | actor_ref: "U456"}
    assert InteractionHandler.handle(member, options) == {:ok, %{outcome: :denied}}
    refute_received {:schedule_deleted, _ref, _revision}

    guest = %{delete | actor_ref: "U999"}
    assert InteractionHandler.handle(guest, options) == {:ok, %{outcome: :denied}}

    malformed = %{delete | action_value: "schedule-control:schedule:#{schedule_id}"}
    assert InteractionHandler.handle(malformed, options) == {:ok, %{outcome: :invalid}}
    refute_received {:schedule_deleted, _ref, _revision}

    behavior = %{
      delete
      | action_id: "responder_delete_behavior",
        action_value: "behavior-control:behavior:#{schedule_id}:3",
        event_ref: "interaction:delete-behavior"
    }

    assert {:ok, %{outcome: :deleted}} = InteractionHandler.handle(behavior, options)

    assert_received {:behavior_deleted, "behavior:" <> ^schedule_id, 3, "U123", "T123",
                     "interaction:delete-behavior"}

    forget = %{
      delete
      | action_id: "responder_forget_memory",
        action_value: "memory:#{schedule_id}"
    }

    assert {:ok, %{outcome: :forgotten}} = InteractionHandler.handle(forget, options)
    assert_received {:memory_forgotten, "memory:" <> ^schedule_id, "U123", "T123"}

    offline =
      Map.put(options, :forget_memory, fn _ref, _actor_ref, _workspace_ref ->
        {:error, :store_offline}
      end)

    assert InteractionHandler.handle(forget, offline) == {:error, :store_offline}
  end

  test "a record overflow selection dispatches one bounded host projection" do
    interaction =
      interaction("responder_work_record", "record")
      |> Map.put(
        :action_value,
        "incident-room:82208f8f-2ef4-4f1b-a011-626aabdc9342|evidence"
      )

    assert InteractionHandler.handle(interaction, options(["U123"])) ==
             {:ok,
              %{
                outcome: :shown,
                record_kind: :evidence,
                work_ref: "incident-room:82208f8f-2ef4-4f1b-a011-626aabdc9342"
              }}

    assert_receive {:work_record_shown,
                    %{
                      record_kind: :evidence,
                      request_ref: "interaction:record",
                      work_ref: "incident-room:82208f8f-2ef4-4f1b-a011-626aabdc9342"
                    }}
  end

  test "task publication controls are bound to the task card and operator authority" do
    publish =
      interaction("responder_task_publish", "task-publish")
      |> Map.put(:action_value, "task-card:abc123|publication:def456")

    member_options = options(["U123"])
    assert InteractionHandler.handle(publish, member_options) == {:ok, %{outcome: :denied}}

    operator_options = %{member_options | operators: MapSet.new(["U123"])}

    assert InteractionHandler.handle(publish, operator_options) ==
             {:ok, %{outcome: :approved, publication_ref: "publication:def456"}}

    assert_receive {:task_publication_approved,
                    %{
                      publication_ref: "publication:def456",
                      work_ref: "task-card:abc123"
                    }}

    check = %{
      publish
      | action_id: "responder_task_check",
        event_ref: "interaction:task-check"
    }

    assert InteractionHandler.handle(check, member_options) ==
             {:ok, %{outcome: :requested, publication_ref: "publication:def456"}}

    recovery = %{
      publish
      | action_id: "responder_task_update_publication",
        action_value: "task-card:abc123|publication:def456|4",
        event_ref: "interaction:task-update"
    }

    assert InteractionHandler.handle(recovery, member_options) == {:ok, %{outcome: :denied}}

    assert InteractionHandler.handle(recovery, operator_options) ==
             {:ok, %{outcome: :review_pending, publication_ref: "publication:def456"}}

    assert_receive {:task_publication_recovered,
                    %{
                      expected_generation: 4,
                      publication_ref: "publication:def456",
                      work_ref: "task-card:abc123"
                    }, :update}
  end

  defp interaction(action_id, kind) do
    %Interaction{
      action_id: action_id,
      action_value: "record:task_offer:#{kind}",
      actor_ref: "U123",
      channel_ref: "C456",
      event_ref: "interaction:#{kind}",
      message_ref: "1787832001.000200",
      occurred_at: ~U[2026-08-28 12:00:00.000000Z],
      thread_ref: "1787832000.000100",
      workspace_ref: "T123"
    }
  end

  defp options(allowed_users) do
    observer = self()

    %{
      answer_input_request: fn attributes ->
        send(observer, {:input_answered, attributes})
        {:ok, %{input_ref: "ingress-input:choice", status: :recorded}}
      end,
      check_publication: fn publication_ref, request_ref ->
        send(observer, {:publication_checked, publication_ref, request_ref})
        {:ok, %{status: :requested}}
      end,
      client: %{allowed: %{observer: self(), users: MapSet.new(allowed_users)}},
      confirm_automation: fn attributes ->
        send(observer, {:automation_confirmed, attributes})

        {:ok,
         %{
           automation: %{"automation_id" => "schedule:daily-health"},
           status: :confirmed
         }}
      end,
      confirm_behavior: fn attributes ->
        send(observer, {:behavior_confirmed, attributes})
        {:ok, %{behavior: %{ref: "behavior:1"}, status: :confirmed}}
      end,
      confirm_memory: fn attributes ->
        send(observer, {:memory_confirmed, attributes})
        {:ok, %{memory: %{ref: "memory:1"}, status: :confirmed}}
      end,
      confirm_slack_post: fn attributes ->
        send(observer, {:slack_post_confirmed, attributes})
        {:ok, %{action: %{action_ref: "platform-action:exact"}, status: :confirmed}}
      end,
      confirm_schedule: fn attributes ->
        send(observer, {:schedule_confirmed, attributes})
        {:ok, %{schedule: %{ref: "schedule:1"}, status: :confirmed}}
      end,
      confirm_task_offer: fn attributes ->
        send(observer, {:task_confirmed, attributes})
        {:ok, %{episode: %{id: "episode-1"}, status: :confirmed}}
      end,
      close_work: fn attributes ->
        send(observer, {:work_closed, attributes})
        {:ok, %{outcome: :closing, work_ref: attributes.work_ref}}
      end,
      investigate_incident: fn attributes ->
        send(observer, {:incident_investigated, attributes})
        {:ok, %{episode: %{id: "episode-incident"}, status: :confirmed}}
      end,
      request_incident_room: fn attributes ->
        send(observer, {:incident_requested, attributes})
        {:ok, %{room: %{ref: "incident-room:1"}, status: :requested}}
      end,
      request_publication_review: fn attributes ->
        send(observer, {:publication_review_requested, attributes})
        {:ok, %{publication: %{ref: "publication:1"}, status: :requested}}
      end,
      show_work_record: fn attributes ->
        send(observer, {:work_record_shown, attributes})

        {:ok,
         %{
           outcome: :shown,
           record_kind: attributes.record_kind,
           work_ref: attributes.work_ref
         }}
      end,
      stop_work: fn attributes ->
        send(observer, {:work_stopped, attributes})
        {:ok, %{outcome: :stopping, work_ref: attributes.work_ref}}
      end,
      approve_task_publication: fn attributes ->
        send(observer, {:task_publication_approved, attributes})
        {:ok, %{outcome: :approved, publication_ref: attributes.publication_ref}}
      end,
      check_task_publication: fn attributes ->
        send(observer, {:task_publication_checked, attributes})
        {:ok, %{outcome: :requested, publication_ref: attributes.publication_ref}}
      end,
      recover_task_publication: fn attributes, action ->
        send(observer, {:task_publication_recovered, attributes, action})
        {:ok, %{outcome: :review_pending, publication_ref: attributes.publication_ref}}
      end,
      approve_publication: fn attributes ->
        send(observer, {:publication_approved, attributes})
        {:ok, %{publication: %{ref: attributes.publication_ref}, status: :approved}}
      end,
      directory: Directory,
      incident_policy: %{digest: String.duplicate("c", 64), name: "incident-investigate"},
      operators: MapSet.new(),
      records: Records,
      repositories: %{
        "responder" => %{
          contributor_policy: %{
            digest: String.duplicate("b", 64),
            name: "responder-contributor"
          }
        }
      }
    }
  end
end
