defmodule Responder.Slack.InteractionTest do
  use ExUnit.Case, async: true

  alias Responder.Slack.Interaction

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "normalizes one host-owned task button from its exact Slack message" do
    assert {:ok, interaction} = Interaction.from_socket(envelope(), "T123", @now)

    assert interaction.action_id == "responder_start_engineering_task"
    assert interaction.action_value == "record:task_offer:abc123"
    assert interaction.actor_ref == "U123"
    assert interaction.channel_ref == "C456"
    assert interaction.event_ref == "interaction:env-1"
    assert interaction.message_ref == "1787832001.000200"
    assert interaction.thread_ref == "1787832000.000100"
    assert interaction.workspace_ref == "T123"
  end

  test "foreign, ephemeral, unknown, and malformed actions are ignored" do
    assert Interaction.from_socket(envelope(), "T999", @now) == :ignore

    ephemeral = put_in(envelope(), ["payload", "container", "is_ephemeral"], true)
    assert Interaction.from_socket(ephemeral, "T123", @now) == :ignore

    unknown =
      put_in(
        envelope(),
        ["payload", "actions", Access.at(0), "action_id"],
        "model_invented_action"
      )

    assert Interaction.from_socket(unknown, "T123", @now) == :ignore

    malformed = put_in(envelope(), ["payload", "actions"], [])
    assert Interaction.from_socket(malformed, "T123", @now) == :ignore
  end

  test "normalizes only a host-encoded durable question choice" do
    envelope =
      envelope()
      |> put_in(
        ["payload", "actions", Access.at(0), "action_id"],
        "responder_answer_input_1"
      )
      |> put_in(
        ["payload", "actions", Access.at(0), "value"],
        "record:input_request:def456|1"
      )

    assert {:ok, interaction} = Interaction.from_socket(envelope, "T123", @now)
    assert interaction.action_id == "responder_answer_input"
    assert interaction.action_value == "record:input_request:def456|1"

    invalid = put_in(envelope, ["payload", "actions", Access.at(0), "value"], "arbitrary|1")
    assert Interaction.from_socket(invalid, "T123", @now) == :ignore
  end

  test "only explicit submit accepts the current question's native selection" do
    ref = "record:input_request:def456"

    submit =
      put_in(envelope(), ["payload", "actions"], [
        %{"type" => "button", "action_id" => "responder_submit_input", "value" => ref}
      ])

    selected =
      put_in(submit, ["payload", "state"], %{
        "values" => %{
          ref => %{
            "responder_question_choice" => %{
              "type" => "radio_buttons",
              "selected_option" => %{"value" => "#{ref}|6"}
            }
          }
        }
      })

    assert {:ok, interaction} = Interaction.from_socket(selected, "T123", @now)
    assert interaction.action_id == "responder_answer_input"
    assert interaction.action_value == "#{ref}|6"
    assert interaction.actor_ref == "U123"
    assert {:ok, missing} = Interaction.from_socket(submit, "T123", @now)
    assert missing.action_id == "responder_submit_input"
    assert missing.action_value == ref

    changed =
      put_in(
        selected,
        [
          "payload",
          "state",
          "values",
          ref,
          "responder_question_choice",
          "selected_option",
          "value"
        ],
        "record:input_request:other|6"
      )

    assert Interaction.from_socket(changed, "T123", @now) == :ignore

    staged =
      put_in(selected, ["payload", "actions"], [
        %{
          "type" => "radio_buttons",
          "action_id" => "responder_question_choice",
          "selected_option" => %{"value" => "#{ref}|6"}
        }
      ])

    assert Interaction.from_socket(staged, "T123", @now) == :ignore
    other_actor = submit |> put_in(["payload", "user", "id"], "U456")
    assert {:ok, missing_other} = Interaction.from_socket(other_actor, "T123", @now)
    assert missing_other.action_id == "responder_submit_input"
    assert missing_other.actor_ref == "U456"
  end

  test "a rendered additional-post confirmation is accepted from the socket" do
    # The button was rendered and handled but missing from the socket allowlist,
    # so every real "Post this message" click was silently ignored. The handler
    # test built the struct by hand and never noticed.
    post =
      envelope()
      |> put_in(["payload", "actions", Access.at(0), "action_id"], "responder_confirm_slack_post")
      |> put_in(["payload", "actions", Access.at(0), "value"], "record:slack_post_offer:abc123")

    assert {:ok, interaction} = Interaction.from_socket(post, "T123", @now)
    assert interaction.action_id == "responder_confirm_slack_post"
    assert interaction.action_value == "record:slack_post_offer:abc123"
  end

  test "normalizes only the host-owned publication controls" do
    review =
      envelope()
      |> put_in(
        ["payload", "actions", Access.at(0), "action_id"],
        "responder_review_publication"
      )
      |> put_in(
        ["payload", "actions", Access.at(0), "value"],
        "record:publication_offer:abc123"
      )

    assert {:ok, interaction} = Interaction.from_socket(review, "T123", @now)
    assert interaction.action_value == "record:publication_offer:abc123"

    publish =
      review
      |> put_in(
        ["payload", "actions", Access.at(0), "action_id"],
        "responder_publish_draft"
      )
      |> put_in(
        ["payload", "actions", Access.at(0), "value"],
        "publication:abc123"
      )

    assert {:ok, interaction} = Interaction.from_socket(publish, "T123", @now)
    assert interaction.action_value == "publication:abc123"

    check =
      put_in(
        publish,
        ["payload", "actions", Access.at(0), "action_id"],
        "responder_check_publication"
      )

    assert {:ok, interaction} = Interaction.from_socket(check, "T123", @now)
    assert interaction.action_value == "publication:abc123"
  end

  test "normalizes only host-owned work buttons and record overflow selections" do
    stop =
      envelope()
      |> put_in(
        ["payload", "actions", Access.at(0), "action_id"],
        "responder_stop_work"
      )
      |> put_in(
        ["payload", "actions", Access.at(0), "value"],
        "task-card:abc123"
      )

    assert {:ok, interaction} = Interaction.from_socket(stop, "T123", @now)
    assert interaction.action_id == "responder_stop_work"
    assert interaction.action_value == "task-card:abc123"

    record =
      stop
      |> put_in(
        ["payload", "actions"],
        [
          %{
            "action_id" => "responder_work_record",
            "selected_option" => %{
              "value" => "incident-room:82208f8f-2ef4-4f1b-a011-626aabdc9342|postmortem"
            },
            "type" => "overflow"
          }
        ]
      )

    assert {:ok, interaction} = Interaction.from_socket(record, "T123", @now)
    assert interaction.action_id == "responder_work_record"

    assert interaction.action_value ==
             "incident-room:82208f8f-2ef4-4f1b-a011-626aabdc9342|postmortem"

    forged =
      put_in(
        record,
        ["payload", "actions", Access.at(0), "selected_option", "value"],
        "task-card:abc123|delete_everything"
      )

    assert Interaction.from_socket(forged, "T123", @now) == :ignore
  end

  # Diff reading moved to the web on 2026-09-09. A retained Slack message still
  # carries the old buttons, so every historical envelope keeps arriving after
  # the cut; the parser must drop them rather than reach a handler that no
  # longer exists.
  test "a retired Slack diff control never becomes an interaction" do
    digest = String.duplicate("a", 64)

    page =
      envelope()
      |> put_in(
        ["payload", "actions", Access.at(0), "action_id"],
        "responder_diff_page"
      )
      |> put_in(
        ["payload", "actions", Access.at(0), "value"],
        "task-card:abc123|#{digest}|2400"
      )

    assert Interaction.from_socket(page, "T123", @now) == :ignore

    view =
      envelope()
      |> put_in(["payload", "actions", Access.at(0), "action_id"], "responder_view_diff")
      |> put_in(["payload", "actions", Access.at(0), "value"], "task-card:abc123")

    assert Interaction.from_socket(view, "T123", @now) == :ignore
  end

  test "normalizes only an exact task and publication pair" do
    publish =
      envelope()
      |> put_in(
        ["payload", "actions", Access.at(0), "action_id"],
        "responder_task_publish"
      )
      |> put_in(
        ["payload", "actions", Access.at(0), "value"],
        "task-card:abc123|publication:def456"
      )

    assert {:ok, interaction} = Interaction.from_socket(publish, "T123", @now)
    assert interaction.action_value == "task-card:abc123|publication:def456"

    readiness =
      publish
      |> put_in(
        ["payload", "actions", Access.at(0), "action_id"],
        "responder_task_readiness"
      )
      |> put_in(
        ["payload", "actions", Access.at(0), "value"],
        "task-card:abc123|record:publication_offer:def456"
      )

    # Tasks repeatedly stalled behind this redundant permission click. Old
    # buttons are inert now that acceptance itself queues the checks.
    assert Interaction.from_socket(readiness, "T123", @now) == :ignore

    crossed =
      put_in(
        publish,
        ["payload", "actions", Access.at(0), "value"],
        "incident-room:abc123|publication:def456"
      )

    assert Interaction.from_socket(crossed, "T123", @now) == :ignore

    recovery =
      publish
      |> put_in(
        ["payload", "actions", Access.at(0), "action_id"],
        "responder_task_update_publication"
      )
      |> put_in(
        ["payload", "actions", Access.at(0), "value"],
        "task-card:abc123|publication:def456|42"
      )

    assert {:ok, interaction} = Interaction.from_socket(recovery, "T123", @now)
    assert interaction.action_value == "task-card:abc123|publication:def456|42"

    assert recovery
           |> put_in(
             ["payload", "actions", Access.at(0), "value"],
             "task-card:abc123|publication:def456|0"
           )
           |> Interaction.from_socket("T123", @now) == :ignore
  end

  test "setup controls carry only the durable setup id" do
    session_ref = Ecto.UUID.generate()

    setup =
      envelope()
      |> put_in(
        ["payload", "actions", Access.at(0), "action_id"],
        "responder_setup_repository_12"
      )
      |> put_in(["payload", "actions", Access.at(0), "value"], session_ref)

    assert {:ok, interaction} = Interaction.from_socket(setup, "T123", @now)
    assert interaction.action_value == session_ref
    assert Interaction.setup_action?(interaction.action_id)

    crossed = put_in(setup, ["payload", "actions", Access.at(0), "value"], "backend")
    assert Interaction.from_socket(crossed, "T123", @now) == :ignore

    for retired <-
          ~w(responder_setup_safe_defaults responder_setup_be_proactive responder_setup_customize) do
      assert setup
             |> put_in(["payload", "actions", Access.at(0), "action_id"], retired)
             |> Interaction.from_socket("T123", @now) == :ignore
    end
  end

  test "welcome controls carry the exact configuration revision they were rendered from" do
    configuration_ref = Ecto.UUID.generate()

    welcome =
      envelope()
      |> put_in(
        ["payload", "actions", Access.at(0), "action_id"],
        "responder_welcome_be_proactive"
      )
      |> put_in(["payload", "actions", Access.at(0), "value"], "#{configuration_ref}|3")

    assert {:ok, interaction} = Interaction.from_socket(welcome, "T123", @now)
    assert interaction.action_value == "#{configuration_ref}|3"
    assert Interaction.setup_action?(interaction.action_id)

    for value <- [
          configuration_ref,
          "#{configuration_ref}|0",
          "backend|3",
          "#{configuration_ref}|3|1"
        ] do
      assert welcome
             |> put_in(["payload", "actions", Access.at(0), "value"], value)
             |> Interaction.from_socket("T123", @now) == :ignore
    end
  end

  # Configure channel also lives on the private `/responder status` reply. Its
  # value names the channel configuration, not the message it was clicked in,
  # so it is the one control an ephemeral container may deliver.
  test "only Configure channel is accepted from an ephemeral settings reply" do
    configuration_ref = Ecto.UUID.generate()

    ephemeral =
      envelope()
      |> put_in(["payload", "container", "is_ephemeral"], true)
      |> put_in(["payload", "actions", Access.at(0), "action_id"], "responder_welcome_configure")
      |> put_in(["payload", "actions", Access.at(0), "value"], "#{configuration_ref}|3")

    assert {:ok, interaction} = Interaction.from_socket(ephemeral, "T123", @now)
    assert interaction.action_id == "responder_welcome_configure"

    for action_id <-
          ~w(responder_welcome_be_proactive responder_welcome_mentions_only responder_setup_save) do
      assert ephemeral
             |> put_in(["payload", "actions", Access.at(0), "action_id"], action_id)
             |> Interaction.from_socket("T123", @now) == :ignore
    end

    assert ephemeral
           |> put_in(["payload", "actions", Access.at(0), "action_id"], "responder_stop_work")
           |> put_in(["payload", "actions", Access.at(0), "value"], "task-card:abc123")
           |> Interaction.from_socket("T123", @now) == :ignore
  end

  defp envelope do
    %{
      "envelope_id" => "env-1",
      "payload" => %{
        "actions" => [
          %{
            "action_id" => "responder_start_engineering_task",
            "type" => "button",
            "value" => "record:task_offer:abc123"
          }
        ],
        "container" => %{
          "channel_id" => "C456",
          "is_ephemeral" => false,
          "message_ts" => "1787832001.000200",
          "thread_ts" => "1787832000.000100",
          "type" => "message"
        },
        "team" => %{"id" => "T123"},
        "type" => "block_actions",
        "user" => %{"id" => "U123"}
      },
      "type" => "interactive"
    }
  end
end
