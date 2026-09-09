defmodule Responder.Slack.SourceAuditsTest do
  use Responder.DataCase, async: true

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Slack.{ActionTokens, CapabilityTools, SourceAudit, SourceAudits, SourceRef}
  alias Responder.Work.Custody

  @now ~U[2026-08-29 12:00:00.000000Z]

  defmodule RecordedNotificationAPI do
    def search_context(_, _, _), do: raise("unexpected search")
    def list_conversations(_, _), do: raise("unexpected channel listing")
    def list_bookmarks(_, _), do: raise("unexpected bookmark listing")
    def file_info(_, _), do: raise("unexpected file read")

    def conversation_info(_client, channel_ref) do
      {:ok,
       %{
         "id" => channel_ref,
         "is_archived" => false,
         "is_ext_shared" => false,
         "is_private" => String.starts_with?(channel_ref, "G")
       }}
    end

    def read_messages(observer, _channel_ref, _thread_ref, _document) do
      send(observer, :notification_read)
      message = "testdata/slack/hcp-terraform-planning.json" |> File.read!() |> Jason.decode!()
      {:ok, %{"cursor" => "", "messages" => [message]}}
    end
  end

  test "bot-triggered reads retain audit attribution without widening private-channel access" do
    # The recovered live Terraform episode read Slack successfully, then lost
    # the entire result because the audit accepted only a human requester.
    message = "testdata/slack/hcp-terraform-planning.json" |> File.read!() |> Jason.decode!()
    assert_audited_notification_read("slack:bot:" <> message["bot_id"])
  end

  test "a durable fallback can read Slack under its real system actor without widening access" do
    # The same live episode next wakes as EventWaits' system poll actor. It must
    # not lose authorized Slack evidence merely because no human input is active.
    assert_audited_notification_read("system:system:event-wait-poll_fallback")
  end

  defp assert_audited_notification_read(actor_ref) do
    episode_id = Ecto.UUID.generate()
    message = "testdata/slack/hcp-terraform-planning.json" |> File.read!() |> Jason.decode!()

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "bot-source-audit:#{episode_id}",
                 native_input_id: "bot-source-audit:#{episode_id}",
                 actor_ref: actor_ref,
                 destination: %{
                   transport: "slack",
                   conversation_ref: "slack:T123:C456",
                   thread_ref: message["ts"]
                 },
                 payload: message,
                 occurred_at: @now,
                 turn_ref: "bot-source-audit:turn:#{episode_id}"
               })
             )

    assert {:ok, _} = Custody.pin_episode(episode_id, "read-only", String.duplicate("a", 64))
    assert {:ok, claim} = Custody.claim_next("bot-source-audit", 60)
    binding = %{episode: transition.episode, turn: claim.turn}

    options =
      CapabilityTools.options!(%{
        workspace_ref: "T123",
        action_tokens: {ActionTokens, ActionTokens},
        api: RecordedNotificationAPI,
        client: self()
      })

    arguments = %{
      "source_ref" => SourceRef.message("T123", "C456", message["ts"]),
      "view" => "surrounding",
      "limit" => 20
    }

    assert {:ok, %{"messages" => [_]}} =
             CapabilityTools.call("read_slack_source", arguments, binding, options)

    assert_received :notification_read
    assert Repo.one!(SourceAudit).requester_ref == actor_ref

    private = Map.put(arguments, "source_ref", SourceRef.message("T123", "GOTHER", message["ts"]))

    assert {:error, "unauthorized"} =
             CapabilityTools.call("read_slack_source", private, binding, options)

    refute_received :notification_read
    assert Repo.aggregate(SourceAudit, :count) == 1
  end

  test "source audits retain metadata and digests without Slack query or result content" do
    episode_id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: episode_id,
        episode_key: "slack-source-audit:#{episode_id}",
        native_input_id: "slack-source-audit:input:#{episode_id}",
        occurred_at: @now,
        turn_ref: "slack-source-audit:turn:#{episode_id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "work-read-only", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("slack-source-audit-worker", 60)

    assert :ok =
             SourceAudits.record(%{
               authorized: true,
               capability: "assistant.search.context",
               channel_ref: nil,
               complete: false,
               episode_id: episode_id,
               range: %{"after" => nil, "before" => nil, "cursor" => "next"},
               request: %{"query" => "secret incident phrase"},
               requester_ref: "slack:user:U123",
               result_count: 3,
               source_ref: nil,
               tool: :search_slack,
               turn_id: claim.turn.id,
               workspace_ref: "T123"
             })

    audit = Repo.one!(SourceAudit)
    assert audit.episode_id == episode_id
    assert audit.turn_id == claim.turn.id
    assert audit.requester_ref == "slack:user:U123"
    assert audit.result_count == 3
    assert audit.complete == false
    assert byte_size(audit.request_fingerprint) == 64
    assert byte_size(audit.range_fingerprint) == 64
    refute inspect(audit) =~ "secret incident phrase"
    refute Map.has_key?(Map.from_struct(audit), :result_body)
    refute Map.has_key?(Map.from_struct(audit), :action_token)
  end

  test "invalid source-audit identity is rejected before persistence" do
    assert SourceAudits.record(%{}) == {:error, {:invalid_slack_source_audit, :fields}}
    assert Repo.aggregate(SourceAudit, :count) == 0
  end
end
