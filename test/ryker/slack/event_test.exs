defmodule Ryker.Slack.EventTest do
  use ExUnit.Case, async: true

  alias Ryker.Ingress.Input
  alias Ryker.Slack.{Event, SourceRef}

  test "attachment-only notifications retain the exact bot identity for automation filters" do
    # This real HCP Terraform notification was invisible to the confirmed rule.
    # Its text is empty and dropping bot_id prevents a narrow source filter.
    message =
      "testdata/slack/hcp-terraform-planning.json" |> File.read!() |> Jason.decode!()

    assert {:ok, %{input: input}} = Event.from_socket(events_api(message), identity())
    assert input.content["bot_id"] == message["bot_id"]
    assert input.content["text"] == ""
    assert input.content["attachments"] == message["attachments"]

    app_message = Map.put(message, "app_id", "A123")
    assert {:ok, %{input: app_input}} = Event.from_socket(events_api(app_message), identity())
    assert app_input.content["bot_id"] == message["bot_id"]
    assert app_input.content["app_id"] == "A123"
    assert app_input.actor == %{kind: :app, ref: "A123"}
  end

  test "an authenticated mention becomes one generic Slack input" do
    envelope =
      events_api(%{
        "action_token" => "xact-user-turn-secret",
        "blocks" => [%{"type" => "rich_text"}],
        "channel" => "C456",
        "event_ts" => "1787832001.000200",
        "files" => [%{"id" => "F123", "name" => "trace.txt"}],
        "text" => "<@U-BOT> investigate checkout errors",
        "thread_ts" => "1787832000.000100",
        "ts" => "1787832001.000200",
        "type" => "app_mention",
        "user" => "U123"
      })

    assert {:ok,
            %{
              action_token: "xact-user-turn-secret",
              audience: :mention,
              input: %Input{} = input
            }} =
             Event.from_socket(envelope, identity())

    assert input.actor == %{kind: :user, ref: "U123"}
    assert input.event_kind == :message
    assert input.event_ref == "Ev-1"
    assert input.source == %{kind: "slack", ref: "T123"}
    assert input.source_item_ref == "1787832001.000200"
    assert input.destination.conversation_ref == "slack:T123:C456"
    assert input.destination.thread_ref == "1787832000.000100"
    assert input.content["text"] == "<@U-BOT> investigate checkout errors"
    assert input.content["files"] == [%{"id" => "F123", "name" => "trace.txt"}]
    refute Map.has_key?(input.content, "action_token")
    refute Input.document(input) |> Jason.encode!() |> String.contains?("xact-user-turn-secret")

    # The raw record is the event as Slack sent it minus transport credentials.
    assert {:ok, %{source_envelope: envelope}} = Event.from_socket(envelope, identity())
    assert envelope["type"] == "app_mention"
    assert envelope["blocks"] == [%{"type" => "rich_text"}]
    refute Map.has_key?(envelope, "action_token")
    refute Jason.encode!(envelope) =~ "xact-user-turn-secret"
  end

  test "signed private file URLs never enter the raw source record" do
    envelope =
      events_api(%{
        "channel" => "C456",
        "event_ts" => "1787832001.000200",
        "files" => [
          %{
            "id" => "F123",
            "name" => "trace.txt",
            "url_private" => "https://files.slack.com/private/secret",
            "url_private_download" => "https://files.slack.com/private/secret?download=1",
            "thumb_360" => "https://files.slack.com/thumb/secret"
          }
        ],
        "text" => "<@U-BOT> look at this",
        "ts" => "1787832001.000200",
        "type" => "app_mention",
        "user" => "U123"
      })

    assert {:ok, %{source_envelope: raw}} = Event.from_socket(envelope, identity())
    assert [%{"id" => "F123", "name" => "trace.txt"} = file] = raw["files"]
    refute Enum.any?(Map.keys(file), &String.starts_with?(&1, "url_private"))
    refute Jason.encode!(raw) =~ "files.slack.com"
  end

  test "edits and deletes preserve one stable message identity and advance revisions" do
    created =
      events_api(%{
        "channel" => "C456",
        "event_ts" => "1787832001.000200",
        "text" => "first",
        "ts" => "1787832001.000200",
        "type" => "message",
        "user" => "U123"
      })

    edited =
      events_api(
        %{
          "channel" => "C456",
          "event_ts" => "1787832010.000300",
          "message" => %{
            "edited" => %{"ts" => "1787832010.000300", "user" => "U123"},
            "text" => "second",
            "ts" => "1787832001.000200",
            "user" => "U123"
          },
          "subtype" => "message_changed",
          "type" => "message"
        },
        "Ev-2"
      )

    deleted =
      events_api(
        %{
          "channel" => "C456",
          "deleted_ts" => "1787832001.000200",
          "event_ts" => "1787832020.000400",
          "previous_message" => %{
            "text" => "second",
            "ts" => "1787832001.000200",
            "user" => "U123"
          },
          "subtype" => "message_deleted",
          "type" => "message"
        },
        "Ev-3"
      )

    assert {:ok, %{input: first}} = Event.from_socket(created, identity())
    assert {:ok, %{input: second}} = Event.from_socket(edited, identity())
    assert {:ok, %{input: third}} = Event.from_socket(deleted, identity())

    assert first.native_input_id == second.native_input_id
    assert second.native_input_id == third.native_input_id
    assert first.revision < second.revision
    assert second.revision < third.revision
    assert second.event_kind == :edit
    assert second.content["text"] == "second"
    assert third.event_kind == :delete
    assert third.source_capabilities == %{}
  end

  test "only an exact affirmative post instruction creates a destination grant" do
    channel = SourceRef.channel("T123", "C789")

    assert {:ok, %{input: granted}} =
             Event.from_socket(
               events_api(%{
                 "channel" => "C456",
                 "event_ts" => "1787832030.000100",
                 "text" => "<@U-BOT> post to <#C789|backend-ops>: share the final summary",
                 "ts" => "1787832030.000100",
                 "type" => "app_mention",
                 "user" => "U123"
               }),
               identity()
             )

    assert granted.source_capabilities == %{
             "post_slack_message" => %{"destination_refs" => [channel]},
             "react" => %{"emoji_names" => nil}
           }

    for {event_ref, text} <- [
          {"Ev-negated", "<@U-BOT> do not post to <#C789|backend-ops>"},
          {"Ev-quoted", "> <@U-BOT> post to <#C789|backend-ops>: copied instructions"},
          {"Ev-prose", "<@U-BOT> maybe share this with <#C789|backend-ops>"},
          {"Ev-wrong-bot", "<@U-OTHER> post to <#C789|backend-ops>: share this"}
        ] do
      envelope =
        events_api(
          %{
            "channel" => "C456",
            "event_ts" => "1787832031.000100",
            "text" => text,
            "ts" => "1787832031.000100",
            "type" => "app_mention",
            "user" => "U123"
          },
          event_ref
        )

      assert {:ok, %{input: ungranted}} = Event.from_socket(envelope, identity())
      refute Map.has_key?(ungranted.source_capabilities, "post_slack_message")
    end
  end

  test "an exact Slack permalink grants only its thread" do
    assert {:ok, %{input: granted}} =
             Event.from_socket(
               events_api(%{
                 "channel" => "C456",
                 "event_ts" => "1787832040.000100",
                 "text" =>
                   "<@U-BOT> post to <https://example.slack.com/archives/G789/p1787832000000100|this thread>: share the review",
                 "ts" => "1787832040.000100",
                 "type" => "app_mention",
                 "user" => "U123"
               }),
               identity()
             )

    assert get_in(granted.source_capabilities, ["post_slack_message", "destination_refs"]) ==
             [SourceRef.thread("T123", "G789", "1787832000.000100")]
  end

  test "direct messages and configured external apps remain distinguishable" do
    direct =
      events_api(%{
        "channel" => "D456",
        "event_ts" => "1787832001.000200",
        "text" => "hello",
        "ts" => "1787832001.000200",
        "type" => "message",
        "user" => "U123"
      })

    app =
      events_api(
        %{
          "app_id" => "A123",
          "bot_id" => "B123",
          "channel" => "C456",
          "event_ts" => "1787832002.000200",
          "subtype" => "bot_message",
          "text" => "alert firing",
          "ts" => "1787832002.000200",
          "type" => "message"
        },
        "Ev-app"
      )

    assert {:ok, %{audience: :direct, input: direct_input}} =
             Event.from_socket(direct, identity())

    assert direct_input.actor.kind == :user

    assert {:ok, %{audience: :ambient, input: app_input}} =
             Event.from_socket(app, identity())

    assert app_input.actor == %{kind: :app, ref: "A123"}
  end

  test "foreign workspaces, self-authored messages, and unsupported subtypes are ignored" do
    foreign = put_in(events_api(message()), ["payload", "team_id"], "T999")
    assert Event.from_socket(foreign, identity()) == :ignore

    self_authored = put_in(events_api(message()), ["payload", "event", "user"], "U-BOT")
    assert Event.from_socket(self_authored, identity()) == :ignore

    unsupported = put_in(events_api(message()), ["payload", "event", "subtype"], "channel_topic")
    assert Event.from_socket(unsupported, identity()) == :ignore

    assert Event.from_socket(%{"type" => "hello"}, identity()) == :ignore
  end

  for lifecycle <- [:message, :edit, :delete] do
    test "our app's #{lifecycle} never enters admission when app identity masks its bot identity" do
      # Harvested from the Emisar #test specimen on 2026-09-05. One post and its
      # update consumed two classifier calls because app_id hid the self check.
      message = own_card_message()
      own_identity = %{identity() | bot_ref: message["bot_id"], bot_user_ref: message["user"]}

      for author <- [message, Map.delete(message, "user"), Map.delete(message, "bot_id")] do
        envelope = events_api(card_lifecycle(author, unquote(lifecycle)))
        assert Event.from_socket(envelope, own_identity) == :ignore
      end
    end
  end

  test "app identity alone does not suppress another bot's message or edit" do
    for lifecycle <- [:message, :edit] do
      envelope = events_api(card_lifecycle(own_card_message(), lifecycle))

      assert {:ok, %{input: input}} = Event.from_socket(envelope, identity())
      assert input.actor == %{kind: :app, ref: "A0BL6UCCBGR"}
    end
  end

  defp own_card_message do
    "testdata/slack/card-lab-own-message.json"
    |> File.read!()
    |> Jason.decode!()
  end

  defp card_lifecycle(message, :message), do: Map.put(message, "channel", "C0BLU1GACKC")

  defp card_lifecycle(message, :edit) do
    %{
      "channel" => "C0BLU1GACKC",
      "event_ts" => message["edited"]["ts"],
      "message" => message,
      "subtype" => "message_changed",
      "type" => "message"
    }
  end

  defp card_lifecycle(message, :delete) do
    %{
      "channel" => "C0BLU1GACKC",
      "deleted_ts" => message["ts"],
      "event_ts" => message["edited"]["ts"],
      "previous_message" => message,
      "subtype" => "message_deleted",
      "type" => "message"
    }
  end

  defp identity do
    %{bot_ref: "B-BOT", bot_user_ref: "U-BOT", workspace_ref: "T123"}
  end

  defp events_api(event, event_id \\ "Ev-1") do
    %{
      "envelope_id" => "env-#{event_id}",
      "payload" => %{
        "event" => event,
        "event_id" => event_id,
        "event_time" => 1_787_832_001,
        "team_id" => "T123",
        "type" => "event_callback"
      },
      "type" => "events_api"
    }
  end

  defp message do
    %{
      "channel" => "C456",
      "event_ts" => "1787832001.000200",
      "text" => "hello",
      "ts" => "1787832001.000200",
      "type" => "message",
      "user" => "U123"
    }
  end
end
