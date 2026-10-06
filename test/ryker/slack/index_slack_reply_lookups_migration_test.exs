defmodule Ryker.Slack.IndexSlackReplyLookupsMigrationTest do
  use Ryker.MigrationCase

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Ryker.Delivery.RoutingResponse
  alias Ryker.Slack.{InteractionAudit, InteractionRepaint}

  @version 20_261_006_100_000
  @receipt_index "episode_work_turns_receipt_message"
  @thread_index "delivery_routing_responses_thread"

  # A repaint read every delivered turn's receipt as JSON to find one reply, and
  # each ambient threaded message read every routing response for its thread
  # (2026-10-04 review). The plans name the index once it exists, read with
  # sequential scans off so that a near-empty table does not hide whether the
  # query can use it.
  test "a reply's repaint and a thread's continuation each read an index" do
    audit = %InteractionAudit{
      workspace_ref: "T1",
      channel_ref: "C1",
      message_ref: "1787832001.000200",
      thread_ref: nil
    }

    # The routing half of `Ryker.Slack.Engagement.continuation?/1`.
    continuation =
      from(response in RoutingResponse,
        where:
          response.kind == :message and response.transport == "slack" and
            response.conversation_ref == "slack:T1:C1" and
            response.thread_ref == "1787832000.000100",
        select: response.id
      )

    assert :ok = migrate_down(@version)
    refute plan(InteractionRepaint.delivered_turn(audit)) =~ @receipt_index
    refute plan(continuation) =~ @thread_index

    assert :ok = migrate_up(@version)
    assert plan(InteractionRepaint.delivered_turn(audit)) =~ @receipt_index
    assert plan(continuation) =~ @thread_index
  end

  defp plan(query) do
    SQL.query!(Repo, "SET LOCAL enable_seqscan = off", [])
    SQL.explain(Repo, :all, query)
  end
end
