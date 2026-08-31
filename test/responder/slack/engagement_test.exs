defmodule Responder.Slack.EngagementTest do
  use Responder.DataCase, async: true

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Slack.{Engagement, Event}

  test "an ambient reply in an existing Slack thread remains engaged without a channel watch" do
    {:ok, _transition} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          destination: %{
            conversation_ref: "slack:T123:C456",
            thread_ref: "1787832000.000100",
            transport: "slack"
          },
          episode_id: Ecto.UUID.generate(),
          episode_key: "slack-thread-engagement",
          native_input_id: "slack-message:seed"
        })
      )

    assert {:ok, normalized} =
             Event.from_socket(thread_reply_envelope(), %{
               bot_ref: "B-BOT",
               bot_user_ref: "U-BOT",
               workspace_ref: "T123"
             })

    assert normalized.audience == :ambient
    assert Engagement.continuation?(normalized)
  end

  test "non-Slack and unrelated Slack inputs do not acquire thread engagement" do
    refute Engagement.continuation?(%{})

    refute Engagement.continuation?(%{
             input: %{
               destination: %{
                 conversation_ref: "github:owner/repository",
                 thread_ref: "issue:42",
                 transport: "github"
               }
             }
           })

    refute Engagement.continuation?(%{
             input: %{
               destination: %{
                 conversation_ref: "slack:T123:C456",
                 thread_ref: "1787832000.999999",
                 transport: "slack"
               }
             }
           })
  end

  defp thread_reply_envelope do
    %{
      "envelope_id" => "env-thread-reply",
      "payload" => %{
        "event" => %{
          "channel" => "C456",
          "event_ts" => "1787832002.000300",
          "text" => "here is the requested value",
          "thread_ts" => "1787832000.000100",
          "ts" => "1787832002.000300",
          "type" => "message",
          "user" => "U123"
        },
        "event_id" => "Ev-thread-reply",
        "team_id" => "T123",
        "type" => "event_callback"
      },
      "type" => "events_api"
    }
  end
end
