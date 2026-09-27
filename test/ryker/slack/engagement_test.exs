defmodule Ryker.Slack.EngagementTest do
  use Ryker.DataCase, async: true

  # Admission reads its context at REPEATABLE READ.
  @moduletag isolation: "REPEATABLE READ"

  alias Ryker.Admission
  alias Ryker.Admission.Decision
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Slack.{Engagement, Event, Input}

  test "an ambient reply in an existing Slack thread remains engaged without a channel watch" do
    {:ok, _transition} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          destination: %{
            conversation_ref: "slack:T26585AFC9D10:C456",
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
               workspace_ref: "T26585AFC9D10"
             })

    assert normalized.audience == :ambient
    assert Engagement.continuation?(normalized)
  end

  # "@Ryker hi" gets "Hi! What can I help with?" from routing, with no work
  # started. The person answers in the thread without mentioning Ryker again;
  # engagement that only knew episodes dropped that answer as ambient chatter.
  test "a thread Ryker answered with a quick reply stays engaged" do
    workspace = "TQUICKENGAGE"
    now = ~U[2026-08-28 12:00:00.000000Z]

    assert {:ok, input} =
             Input.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "hi"},
               event_kind: :message,
               event_ref: "Ev-quick-engage",
               message_ref: "1787832000.000100",
               occurred_at: now,
               revision: 1,
               thread_ref: "1787832000.000100",
               workspace_ref: workspace
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)

    assert {:ok, context} =
             Admission.context(Inbox.ref(entry),
               now: now,
               continuation_window: 30 * 60,
               history_window: 30 * 24 * 60 * 60,
               candidate_limit: 8,
               lease_ref: nil
             )

    assert {:ok, decision} =
             Decision.parse(%{
               "action" => "quick_reply",
               "episode_ref" => nil,
               "messages" => ["Hi! What can I help with?"],
               "reactions" => nil,
               "relation" => "unrelated",
               "repository" => nil,
               "repository_source" => nil,
               "reason" => "A greeting needs a short answer, not work.",
               "work_class" => nil
             })

    assert {:ok, _applied} = Admission.commit(context, decision, "decision:quick-engage")

    assert {:ok, normalized} =
             Event.from_socket(thread_reply_envelope(workspace), %{
               bot_ref: "B-BOT",
               bot_user_ref: "U-BOT",
               workspace_ref: workspace
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
                 conversation_ref: "slack:T26585AFC9D10:C456",
                 thread_ref: "1787832000.999999",
                 transport: "slack"
               }
             }
           })
  end

  defp thread_reply_envelope(workspace \\ "T26585AFC9D10") do
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
        "team_id" => workspace,
        "type" => "event_callback"
      },
      "type" => "events_api"
    }
  end
end
