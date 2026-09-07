defmodule Responder.Slack.GatewayTest do
  use Responder.DataCase, async: true

  alias Responder.Ingress.Inbox
  alias Responder.Slack.Gateway

  defmodule Directory do
    @behaviour Responder.Slack.MemberDirectory

    @impl true
    def user_allowed(%{allowed: allowed}, user_ref, _workspace_ref),
      do: {:ok, MapSet.member?(allowed, user_ref)}
  end

  defmodule InteractionHandler do
    def handle(interaction, %{observer: observer, result: result}) do
      send(observer, {:handled_interaction, interaction})
      result
    end
  end

  defmodule CommandHandler do
    def handle(command, %{observer: observer, result: result}) do
      send(observer, {:handled_command, command})
      result
    end
  end

  defmodule SetupHandler do
    def handle_membership(transition, %{observer: observer}) do
      send(observer, {:handled_membership, transition})
      {:ok, %{status: :joined}}
    end

    def handle_message(normalized, %{observer: observer, result: result}) do
      send(observer, {:checked_setup_message, normalized})
      result
    end
  end

  defmodule HomeHandler do
    def handle(event, %{observer: observer, result: result}) do
      send(observer, {:handled_home, event})
      result
    end
  end

  defmodule HomeInteractionHandler do
    def handle(interaction, %{observer: observer, result: result}) do
      send(observer, {:handled_home_interaction, interaction})
      result
    end
  end

  defmodule ConflictInbox do
    def record(_input, _options), do: {:error, {:input_conflict, %{field: :fingerprint}}}
  end

  defmodule UnavailableInbox do
    def record(_input, _options), do: {:error, :database_unavailable}
  end

  defmodule AttachmentIngestor do
    def ingest(normalized, %{observer: observer} = options) do
      send(observer, {:attachments_ingested, normalized.input.content["files"]})
      {:ok, %{normalized | audience: Map.get(options, :audience, normalized.audience)}}
    end
  end

  test "a Slack event is durably recorded before its envelope becomes acknowledgeable" do
    settings =
      settings()
      |> Map.put(:action_tokens, fn event_ref, token ->
        send(self(), {:action_token_remembered, event_ref, token})
        :ok
      end)

    envelope =
      message_envelope("Ev-1", "app_mention")
      |> put_in(["payload", "event", "action_token"], "xact-user-turn-secret")

    assert {:ack, {:recorded, input_ref}} =
             Gateway.handle_envelope(envelope, settings)

    assert_received {:action_token_remembered, "Ev-1", "xact-user-turn-secret"}

    assert {:ok, entry} = Inbox.fetch(input_ref)
    assert entry.source_kind == "slack"
    assert entry.actor_ref == "U123"
    assert entry.status == :pending
    assert Map.get(entry, :slack_audience) == :mention
    assert Map.get(entry, :slack_bot_user_ref) == "UBOT"

    assert {:ack, {:duplicate, ^input_ref}} =
             Gateway.handle_envelope(envelope, settings)
  end

  test "the advertised investigate shortcut is durable before Slack is acknowledged" do
    envelope = shortcut_envelope()

    assert {:ack, {:recorded, input_ref}} =
             Gateway.handle_envelope(envelope, settings())

    assert {:ok, entry} = Inbox.fetch(input_ref)
    assert entry.source_kind == "slack"
    assert entry.event_ref == "shortcut:env-shortcut"
    assert entry.actor_ref == "U123"
    assert entry.event_kind == :event
    assert entry.source_item_ref == "1787832001.000200"
    assert entry.destination_thread_ref == "1787832000.000100"
    assert entry.content["slack_event_kind"] == "shortcut"
    assert entry.content["text"] == "investigate this failure"
    assert entry.content["files"] == []
    assert entry.status == :pending
    assert Map.get(entry, :slack_audience) == :direct
    assert Map.get(entry, :slack_bot_user_ref) == "UBOT"

    assert {:ack, {:duplicate, ^input_ref}} =
             Gateway.handle_envelope(envelope, settings())

    unavailable = Map.put(settings(), :inbox, UnavailableInbox)

    assert Gateway.handle_envelope(shortcut_envelope("env-shortcut-retry"), unavailable) ==
             {:retry, :database_unavailable}

    unsupported =
      put_in(
        envelope,
        ["payload", "callback_id"],
        "foreign_message_shortcut"
      )

    assert Gateway.handle_envelope(unsupported, settings()) ==
             {:ack, {:ignored, :unsupported_interaction}}
  end

  test "an authorized App Home open is published before acknowledgement" do
    configured =
      settings()
      |> Map.put(:home_handler, HomeHandler)
      |> Map.put(:home_options, %{
        observer: self(),
        result: {:ok, %{access: :operator, outcome: :published}}
      })

    assert Gateway.handle_envelope(home_envelope(), configured) ==
             {:ack, {:app_home, :published}}

    assert_received {:handled_home, event}
    assert event.actor_ref == "U123"
    assert event.workspace_ref == "T74CADB5B58F9"
  end

  test "a transient App Home publication failure leaves the envelope retryable" do
    configured =
      settings()
      |> Map.put(:home_handler, HomeHandler)
      |> Map.put(:home_options, %{observer: self(), result: {:error, :slack_unavailable}})

    assert Gateway.handle_envelope(home_envelope(), configured) ==
             {:retry, :slack_unavailable}
  end

  test "an App Home lifecycle control is handled before message controls" do
    configured =
      settings()
      |> Map.put(:home_interaction_handler, HomeInteractionHandler)
      |> Map.put(:home_interaction_options, %{
        observer: self(),
        result: {:ok, %{outcome: :paused}}
      })

    assert Gateway.handle_envelope(home_interaction_envelope(), configured) ==
             {:ack, {:app_home_control, :paused}}

    assert_received {:handled_home_interaction, interaction}
    assert interaction.action == :pause_schedule
    assert interaction.resource_ref == "schedule-control:schedule:abc:4"
  end

  test "pre-upgrade App Home lifecycle controls are settled as stale" do
    configured =
      settings()
      |> Map.put(:home_interaction_handler, HomeInteractionHandler)
      |> Map.put(:home_interaction_options, %{
        observer: self(),
        result: {:ok, %{outcome: :invalid}}
      })

    for {action_id, value, action} <- [
          {"responder_home_disable_behavior", "behavior:pre-upgrade", :disable_behavior},
          {"responder_home_pause_schedule", "schedule:pre-upgrade", :pause_schedule}
        ] do
      envelope =
        home_interaction_envelope()
        |> put_in(["payload", "actions", Access.at(0), "action_id"], action_id)
        |> put_in(["payload", "actions", Access.at(0), "value"], value)

      assert Gateway.handle_envelope(envelope, configured) ==
               {:ack, {:app_home_control, :invalid}}

      assert_received {:handled_home_interaction, interaction}
      assert interaction.action == action
      assert interaction.resource_ref == value
    end
  end

  test "an App Home modal submission uses the same authorized control boundary" do
    configured =
      settings()
      |> Map.put(:home_interaction_handler, HomeInteractionHandler)
      |> Map.put(:home_interaction_options, %{
        observer: self(),
        result: {:ok, %{outcome: :edit}}
      })

    assert Gateway.handle_envelope(home_submission_envelope(), configured) ==
             {:ack, {:app_home_control, :edit}}

    assert_received {:handled_home_interaction, submission}
    assert submission.action == :edit_memory_review
    assert submission.resource_ref == "memory-review:abc"
    assert submission.replacement["value"] == "Use verified production evidence."
  end

  test "an invalid App Home modal value is acknowledged with a field error" do
    envelope =
      home_submission_envelope()
      |> Map.put("accepts_response_payload", true)
      |> put_in(
        ["payload", "view", "state", "values", "memory_value", "value", "value"],
        "   "
      )

    assert Gateway.handle_envelope(envelope, settings()) ==
             {:ack, {:app_home_control, :invalid},
              %{
                "errors" => %{
                  "memory_value" => "Enter non-empty guidance of at most 4000 characters."
                },
                "response_action" => "errors"
              }}
  end

  test "bot membership opens durable setup before Slack acknowledgement" do
    configured =
      settings()
      |> Map.put(:setup_handler, SetupHandler)
      |> Map.put(:setup_options, %{observer: self(), result: :not_setup})

    envelope =
      message_envelope("Ev-join", "message")
      |> put_in(["payload", "event"], %{
        "channel" => "C456",
        "event_ts" => "1787832001.000200",
        "inviter" => "U123",
        "type" => "member_joined_channel",
        "user" => "UBOT"
      })

    assert Gateway.handle_envelope(envelope, configured) == {:ack, {:membership, :joined}}
    assert_received {:handled_membership, transition}
    assert transition.kind == :joined
    assert transition.actor_ref == "U123"
  end

  test "managed incident-room lifecycle bypasses channel setup before acknowledgement" do
    configured =
      settings()
      |> Map.put(:setup_handler, SetupHandler)
      |> Map.put(:setup_options, %{observer: self(), result: :not_setup})
      |> Map.put(:incident_lifecycle, fn transition ->
        send(self(), {:handled_incident_lifecycle, transition})
        {:ok, %{room: %{ref: "incident-room:1"}, status: :applied}}
      end)

    envelope =
      message_envelope("Ev-incident-join", "message")
      |> put_in(["payload", "event"], %{
        "channel" => "CINCIDENT",
        "event_ts" => "1787832001.000200",
        "inviter" => "U123",
        "type" => "member_joined_channel",
        "user" => "UBOT"
      })

    assert Gateway.handle_envelope(envelope, configured) == {:ack, {:incident_room, :applied}}
    assert_received {:handled_incident_lifecycle, transition}
    assert transition.channel_ref == "CINCIDENT"
    refute_received {:handled_membership, _transition}
  end

  test "unmanaged archive events are acknowledged without creating channel setup" do
    configured =
      settings()
      |> Map.put(:setup_handler, SetupHandler)
      |> Map.put(:setup_options, %{observer: self(), result: :not_setup})
      |> Map.put(:incident_lifecycle, fn _transition ->
        {:ok, %{room: nil, status: :not_incident_room}}
      end)

    envelope =
      message_envelope("Ev-unmanaged-archive", "message")
      |> put_in(["payload", "event"], %{
        "channel" => "C456",
        "event_ts" => "1787832001.000200",
        "type" => "channel_archive",
        "user" => "U123"
      })

    assert Gateway.handle_envelope(envelope, configured) ==
             {:ack, {:ignored, :unmanaged_channel_lifecycle}}

    refute_received {:handled_membership, _transition}
  end

  test "an active setup answer is consumed before ordinary engagement" do
    configured =
      settings()
      |> Map.put(:setup_handler, SetupHandler)
      |> Map.put(
        :setup_options,
        %{observer: self(), result: {:ok, %{outcome: :advanced}}}
      )

    assert Gateway.handle_envelope(message_envelope("Ev-setup", "message"), configured) ==
             {:ack, {:configuration, :advanced}}

    assert_received {:checked_setup_message, _normalized}
    assert Repo.aggregate(Responder.Ingress.Inbox.Entry, :count) == 0
  end

  test "a managed artifact channel bypasses generic setup and enters normal admission" do
    configured =
      settings()
      |> Map.put(:setup_handler, SetupHandler)
      |> Map.put(
        :setup_options,
        %{observer: self(), result: {:ok, %{outcome: :must_not_run}}}
      )
      |> Map.put(:setup_allowed, fn "T74CADB5B58F9", "slack:T74CADB5B58F9:C456" ->
        {:ok, false}
      end)
      |> Map.put(:effective_settings, fn "T74CADB5B58F9", "slack:T74CADB5B58F9:C456" ->
        %{
          proactive: %{source: :incident_room, value: true},
          shadow: %{source: :incident_room, value: false}
        }
      end)

    assert {:ack, {:recorded, input_ref}} =
             Gateway.handle_envelope(message_envelope("Ev-managed-room", "message"), configured)

    assert {:ok, _entry} = Inbox.fetch(input_ref)
    refute_received {:checked_setup_message, _normalized}
  end

  test "membership and engagement are host checks before ambient content enters admission" do
    denied = put_in(settings(), [:client, :allowed], MapSet.new())

    assert Gateway.handle_envelope(message_envelope("Ev-denied", "app_mention"), denied) ==
             {:ack, {:ignored, :actor_not_authorized}}

    assert Gateway.handle_envelope(message_envelope("Ev-unwatched", "message"), settings()) ==
             {:ack, {:ignored, :not_engaged}}

    watched = %{settings() | watch_channels: MapSet.new(["C456"])}

    assert {:ack, {:recorded, _input_ref}} =
             Gateway.handle_envelope(message_envelope("Ev-watched", "message"), watched)

    configured =
      Map.put(settings(), :effective_settings, fn "T74CADB5B58F9", "slack:T74CADB5B58F9:C456" ->
        %{
          proactive: %{source: :channel, value: true},
          shadow: %{source: :deployment, value: false}
        }
      end)

    assert {:ack, {:recorded, _input_ref}} =
             Gateway.handle_envelope(message_envelope("Ev-configured", "message"), configured)

    unavailable =
      Map.put(settings(), :effective_settings, fn _workspace_ref, _conversation_ref ->
        {:error, :database_unavailable}
      end)

    assert Gateway.handle_envelope(message_envelope("Ev-setting-retry", "message"), unavailable) ==
             {:retry, :database_unavailable}
  end

  test "source content cannot forge the retained audience or host-configured bot identity" do
    # This is a host-normalization fixture, not a claimed historical provider envelope.
    for {channel, type, expected} <- [
          {"C456", "message", :ambient},
          {"D456", "message", :direct},
          {"C456", "app_mention", :mention}
        ] do
      envelope =
        message_envelope("Ev-addressing-#{expected}", type)
        |> put_in(["payload", "event", "channel"], channel)
        |> put_in(["payload", "event", "text"], "<@UOTHER> can you check this?")
        |> put_in(["payload", "event", "slack_audience"], "mention")
        |> put_in(["payload", "event", "slack_bot_user_ref"], "UOTHER")
        |> put_in(["payload", "event", "blocks"], [
          %{"audience" => "mention", "responder_user_ref" => "UOTHER"}
        ])

      watched = %{settings() | watch_channels: MapSet.new([channel])}
      assert {:ack, {:recorded, ref}} = Gateway.handle_envelope(envelope, watched)
      assert {:ok, entry} = Inbox.fetch(ref)
      assert Map.get(entry, :slack_audience) == expected
      assert Map.get(entry, :slack_bot_user_ref) == "UBOT"
      assert entry.content["text"] == "<@UOTHER> can you check this?"
      assert hd(entry.content["blocks"])["responder_user_ref"] == "UOTHER"
    end
  end

  test "shadow engages ambient and addressed traffic but freezes it as observe-only" do
    shadowed =
      Map.put(settings(), :effective_settings, fn "T74CADB5B58F9", "slack:T74CADB5B58F9:C456" ->
        %{
          proactive: %{source: :workspace, value: false},
          shadow: %{source: :channel, value: true}
        }
      end)

    assert {:ack, {:recorded, ambient_ref}} =
             Gateway.handle_envelope(message_envelope("Ev-shadow-ambient", "message"), shadowed)

    assert {:ok, ambient} = Inbox.fetch(ambient_ref)
    assert ambient.execution_mode == :shadow

    assert {:ack, {:recorded, mention_ref}} =
             Gateway.handle_envelope(
               message_envelope("Ev-shadow-mention", "app_mention"),
               shadowed
             )

    assert {:ok, mention} = Inbox.fetch(mention_ref)
    assert mention.execution_mode == :shadow

    live =
      Map.put(settings(), :effective_settings, fn "T74CADB5B58F9", "slack:T74CADB5B58F9:C456" ->
        %{
          proactive: %{source: :channel, value: true},
          shadow: %{source: :deployment, value: false}
        }
      end)

    assert {:ack, {:recorded, live_ref}} =
             Gateway.handle_envelope(message_envelope("Ev-live", "message"), live)

    assert {:ok, live_entry} = Inbox.fetch(live_ref)
    assert live_entry.execution_mode == :live
  end

  test "trusted channel placement is frozen beside the Slack input before acknowledgement" do
    placed =
      settings()
      |> Map.put(:work_profile, fn "T74CADB5B58F9", "slack:T74CADB5B58F9:C456" ->
        {:ok,
         %{
           policy: "incident-read-only",
           policy_digest: String.duplicate("c", 64),
           repository_ref: "owner/infrastructure"
         }}
      end)

    assert {:ack, {:recorded, input_ref}} =
             Gateway.handle_envelope(message_envelope("Ev-placement", "app_mention"), placed)

    assert {:ok, entry} = Inbox.fetch(input_ref)
    assert entry.work_policy == "incident-read-only"
    assert entry.work_policy_digest == String.duplicate("c", 64)
    assert entry.repository_ref == "owner/infrastructure"
  end

  test "authorization and engagement run before authenticated file download" do
    envelope =
      message_envelope("Ev-file", "app_mention")
      |> put_in(["payload", "event", "files"], [%{"id" => "F123"}])

    denied =
      settings()
      |> put_in([:client, :allowed], MapSet.new())
      |> Map.put(:attachment_ingestor, AttachmentIngestor)
      |> Map.put(:attachment_options, %{observer: self()})

    assert Gateway.handle_envelope(envelope, denied) ==
             {:ack, {:ignored, :actor_not_authorized}}

    refute_received {:attachments_ingested, _files}

    allowed =
      settings()
      |> Map.put(:attachment_ingestor, AttachmentIngestor)
      |> Map.put(:attachment_options, %{observer: self(), audience: :ambient})

    assert {:ack, {:recorded, ref}} = Gateway.handle_envelope(envelope, allowed)
    assert_received {:attachments_ingested, [%{"id" => "F123"}]}
    assert {:ok, entry} = Inbox.fetch(ref)
    assert Map.get(entry, :slack_audience) == :mention
    assert Map.get(entry, :slack_bot_user_ref) == "UBOT"
  end

  test "a host control is handled before acknowledgement and transient failure is retried" do
    settings =
      settings()
      |> Map.put(:interaction_handler, InteractionHandler)
      |> Map.put(:interaction_options, %{observer: self(), result: {:ok, %{outcome: :confirmed}}})

    assert Gateway.handle_envelope(interaction_envelope(), settings) ==
             {:ack, {:interaction, :confirmed}}

    assert_receive {:handled_interaction, interaction}
    assert interaction.action_value == "record:task_offer:abc123"

    retry = put_in(settings, [:interaction_options, :result], {:error, :database_unavailable})

    assert Gateway.handle_envelope(interaction_envelope("env-2"), retry) ==
             {:retry, :database_unavailable}
  end

  test "denied and stale controls are audited and receive a private explanation" do
    audit = fn interaction, outcome ->
      send(self(), {:audited_interaction, interaction.event_ref, outcome})
      {:ok, %{status: :recorded}}
    end

    denied =
      settings()
      |> Map.put(:interaction_handler, InteractionHandler)
      |> Map.put(:interaction_options, %{observer: self(), result: {:ok, %{outcome: :denied}}})
      |> Map.put(:interaction_audit, audit)

    assert {:ack, {:interaction, :denied}, denied_payload} =
             Gateway.handle_envelope(interaction_envelope("env-denied"), denied)

    assert denied_payload == %{
             "response_type" => "ephemeral",
             "text" => "You don't have permission to use that Responder control."
           }

    assert_received {:audited_interaction, "interaction:env-denied", :denied}

    invalid = put_in(denied, [:interaction_options, :result], {:ok, %{outcome: :invalid}})

    assert {:ack, {:interaction, :invalid}, invalid_payload} =
             Gateway.handle_envelope(interaction_envelope("env-stale"), invalid)

    assert invalid_payload == %{
             "response_type" => "ephemeral",
             "text" => "That control is no longer current. Use the refreshed message instead."
           }

    assert_received {:audited_interaction, "interaction:env-stale", :invalid}
  end

  test "an unavailable interaction audit leaves the envelope retryable" do
    settings =
      settings()
      |> Map.put(:interaction_handler, InteractionHandler)
      |> Map.put(:interaction_options, %{observer: self(), result: {:ok, %{outcome: :invalid}}})
      |> Map.put(:interaction_audit, fn _interaction, _outcome ->
        {:error, :database_unavailable}
      end)

    assert Gateway.handle_envelope(interaction_envelope("env-audit-retry"), settings) ==
             {:retry, :database_unavailable}
  end

  test "a slash command is handled before a private Socket Mode acknowledgement payload" do
    payload = %{"response_type" => "ephemeral", "text" => "Responder is passive."}

    settings =
      settings()
      |> Map.put(:command_handler, CommandHandler)
      |> Map.put(:command_options, %{observer: self(), result: {:ok, payload}})

    envelope = command_envelope()

    assert Gateway.handle_envelope(envelope, settings) ==
             {:ack, {:command, :handled}, payload}

    assert_receive {:handled_command, command}
    assert command.text == "status"

    assert Gateway.acknowledgement(envelope, {:ack, {:command, :handled}, payload}) == %{
             "envelope_id" => "env-command",
             "payload" => payload
           }
  end

  test "unsupported and malformed authenticated envelopes are acknowledged without queueing" do
    unsupported = %{
      "envelope_id" => "unsupported",
      "payload" => %{
        "event" => %{"type" => "reaction_added"},
        "event_id" => "Ev-unsupported",
        "team_id" => "T74CADB5B58F9",
        "type" => "event_callback"
      },
      "type" => "events_api"
    }

    assert Gateway.handle_envelope(unsupported, settings()) ==
             {:ack, {:ignored, :invalid_reaction_event}}

    invalid =
      put_in(message_envelope("Ev-invalid", "app_mention"), ["payload", "event", "user"], nil)

    assert Gateway.handle_envelope(invalid, settings()) ==
             {:ack, {:ignored, :invalid_event}}

    assert Gateway.handle_envelope(%{"envelope_id" => "unknown"}, settings()) ==
             {:ack, {:ignored, :unsupported_envelope}}

    assert Gateway.handle_envelope(%{"type" => "hello"}, settings()) == :ignore
    assert Gateway.handle_envelope(%{}, settings()) == :ignore

    unsupported_interaction =
      interaction_envelope()
      |> put_in(["payload", "actions", Access.at(0), "action_id"], "foreign_action")

    assert Gateway.handle_envelope(unsupported_interaction, settings()) ==
             {:ack, {:ignored, :unsupported_interaction}}
  end

  test "authorized reactions on Responder replies become passive episode feedback" do
    settings =
      Map.put(settings(), :reaction_feedback, fn reaction ->
        send(self(), {:reaction_feedback, reaction})
        {:ok, %{status: :applied}}
      end)

    assert Gateway.handle_envelope(reaction_envelope(), settings) ==
             {:ack, {:reaction, :applied}}

    assert_receive {:reaction_feedback,
                    %{
                      action: :add,
                      actor_ref: "U123",
                      emoji_name: "eyes",
                      event_ref: "Ev-reaction",
                      target: %{
                        conversation_ref: "slack:T74CADB5B58F9:C456",
                        message_ref: "1787832000.000100",
                        transport: "slack"
                      }
                    }}
  end

  test "reaction custody is retried only for transient failures" do
    unavailable =
      Map.put(settings(), :reaction_feedback, fn _reaction ->
        {:error, :database_unavailable}
      end)

    assert Gateway.handle_envelope(reaction_envelope(), unavailable) ==
             {:retry, :database_unavailable}

    missing =
      Map.put(settings(), :reaction_feedback, fn _reaction ->
        {:error, :conversation_reaction_target_not_found}
      end)

    assert Gateway.handle_envelope(reaction_envelope(), missing) ==
             {:ack, {:ignored, :reaction_target_not_found}}

    denied = put_in(reaction_envelope(), ["payload", "event", "user"], "U-DENIED")

    assert Gateway.handle_envelope(denied, unavailable) ==
             {:ack, {:ignored, :actor_not_authorized}}
  end

  test "event conflicts are terminal but unavailable durable custody remains retryable" do
    conflict = %{settings() | inbox: ConflictInbox}

    assert Gateway.handle_envelope(message_envelope("Ev-conflict", "app_mention"), conflict) ==
             {:ack, {:ignored, :event_conflict}}

    unavailable = %{settings() | inbox: UnavailableInbox}

    assert Gateway.handle_envelope(message_envelope("Ev-retry", "app_mention"), unavailable) ==
             {:retry, :database_unavailable}
  end

  test "trusted app events use watch or exact continuation without user membership authority" do
    app_event =
      message_envelope("Ev-app", "message")
      |> update_in(["payload", "event"], fn event ->
        event
        |> Map.delete("user")
        |> Map.put("app_id", "A123")
        |> Map.put("subtype", "bot_message")
      end)

    watched = %{settings() | watch_channels: MapSet.new(["C456"])}
    assert {:ack, {:recorded, _ref}} = Gateway.handle_envelope(app_event, watched)

    continuation = Map.put(settings(), :continuation, fn _normalized -> true end)

    bot_event =
      message_envelope("Ev-bot", "message")
      |> update_in(["payload", "event"], fn event ->
        event
        |> Map.delete("user")
        |> Map.put("bot_id", "B123")
        |> Map.put("subtype", "bot_message")
      end)

    assert {:ack, {:recorded, _ref}} = Gateway.handle_envelope(bot_event, continuation)
  end

  test "an exact confirmed standing assignment can admit only its ambient match" do
    matching =
      Map.put(settings(), :standing_matcher, fn input ->
        input.content["text"] == "<@UBOT> investigate"
      end)

    assert {:ack, {:recorded, _ref}} =
             Gateway.handle_envelope(message_envelope("Ev-assigned", "message"), matching)

    nonmatching = Map.put(settings(), :standing_matcher, fn _input -> false end)

    assert Gateway.handle_envelope(message_envelope("Ev-unassigned", "message"), nonmatching) ==
             {:ack, {:ignored, :not_engaged}}
  end

  defp settings do
    %{
      client: %{allowed: MapSet.new(["U123"])},
      directory: Directory,
      identity: %{bot_ref: "B-BOT", bot_user_ref: "UBOT", workspace_ref: "T74CADB5B58F9"},
      inbox: Inbox,
      interaction_handler: Responder.Slack.InteractionHandler,
      interaction_options: %{},
      watch_channels: MapSet.new()
    }
  end

  defp message_envelope(event_ref, type) do
    event = %{
      "channel" => "C456",
      "event_ts" => "1787832001.000200",
      "text" => "<@UBOT> investigate",
      "ts" => "1787832001.000200",
      "type" => type,
      "user" => "U123"
    }

    %{
      "envelope_id" => "env-#{event_ref}",
      "payload" => %{
        "event" => event,
        "event_id" => event_ref,
        "event_time" => 1_787_832_001,
        "team_id" => "T74CADB5B58F9",
        "type" => "event_callback"
      },
      "type" => "events_api"
    }
  end

  defp reaction_envelope do
    %{
      "envelope_id" => "env-reaction",
      "payload" => %{
        "event" => %{
          "event_ts" => "1787832001.000200",
          "item" => %{
            "channel" => "C456",
            "ts" => "1787832000.000100",
            "type" => "message"
          },
          "item_user" => "UBOT",
          "reaction" => "eyes",
          "type" => "reaction_added",
          "user" => "U123"
        },
        "event_id" => "Ev-reaction",
        "team_id" => "T74CADB5B58F9",
        "type" => "event_callback"
      },
      "type" => "events_api"
    }
  end

  defp interaction_envelope(envelope_ref \\ "env-1") do
    %{
      "envelope_id" => envelope_ref,
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
        "team" => %{"id" => "T74CADB5B58F9"},
        "type" => "block_actions",
        "user" => %{"id" => "U123"}
      },
      "type" => "interactive"
    }
  end

  defp shortcut_envelope(envelope_ref \\ "env-shortcut") do
    %{
      "envelope_id" => envelope_ref,
      "payload" => %{
        "callback_id" => "responder_investigate_message",
        "channel" => %{"id" => "C456"},
        "message" => %{
          "files" => [],
          "text" => "investigate this failure",
          "thread_ts" => "1787832000.000100",
          "ts" => "1787832001.000200",
          "user" => "U999"
        },
        "team" => %{"id" => "T74CADB5B58F9"},
        "type" => "message_action",
        "user" => %{"id" => "U123"}
      },
      "type" => "interactive"
    }
  end

  defp home_envelope do
    %{
      "envelope_id" => "env-home-1",
      "payload" => %{
        "event" => %{
          "event_ts" => "1787832001.000200",
          "tab" => "home",
          "type" => "app_home_opened",
          "user" => "U123"
        },
        "event_id" => "Ev-home-1",
        "team_id" => "T74CADB5B58F9",
        "type" => "event_callback"
      },
      "type" => "events_api"
    }
  end

  defp home_interaction_envelope do
    %{
      "envelope_id" => "env-home-control",
      "payload" => %{
        "actions" => [
          %{
            "action_id" => "responder_home_pause_schedule",
            "type" => "button",
            "value" => "schedule-control:schedule:abc:4"
          }
        ],
        "container" => %{"type" => "view", "view_id" => "V123"},
        "team" => %{"id" => "T74CADB5B58F9"},
        "type" => "block_actions",
        "user" => %{"id" => "U123"},
        "view" => %{"id" => "V123", "type" => "home"}
      },
      "type" => "interactive"
    }
  end

  defp home_submission_envelope do
    %{
      "envelope_id" => "env-home-edit",
      "payload" => %{
        "team" => %{"id" => "T74CADB5B58F9"},
        "type" => "view_submission",
        "user" => %{"id" => "U123"},
        "view" => %{
          "callback_id" => "responder_home_edit_memory_review",
          "private_metadata" => Jason.encode!(%{"review_ref" => "memory-review:abc"}),
          "state" => %{
            "values" => %{
              "memory_subject" => %{
                "subject" => %{"type" => "plain_text_input", "value" => "production-proof"}
              },
              "memory_value" => %{
                "value" => %{
                  "type" => "plain_text_input",
                  "value" => "Use verified production evidence."
                }
              }
            }
          },
          "type" => "modal"
        }
      },
      "type" => "interactive"
    }
  end

  defp command_envelope do
    %{
      "accepts_response_payload" => true,
      "envelope_id" => "env-command",
      "payload" => %{
        "channel_id" => "C456",
        "command" => "/responder",
        "response_url" => "https://hooks.slack.com/commands/secret",
        "team_id" => "T74CADB5B58F9",
        "text" => "status",
        "trigger_id" => "trigger-1",
        "user_id" => "U123"
      },
      "type" => "slash_commands"
    }
  end
end
