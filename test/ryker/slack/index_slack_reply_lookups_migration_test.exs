defmodule Ryker.Slack.IndexSlackReplyLookupsMigrationTest do
  use Ryker.MigrationCase
  import Ecto.Query
  alias Ecto.Adapters.SQL
  alias Ryker.Delivery.RoutingResponse
  alias Ryker.TestMigrations
  alias Ryker.Work.Turn

  @version 20_261_006_100_000
  @receipt_index "episode_work_turns_receipt_message"
  @thread_index "delivery_routing_responses_thread"

  # A repaint read every delivered turn's receipt as JSON to find one reply, and
  # each ambient threaded message read every routing response for its thread
  # (2026-10-04 review). The plans name the index once it exists, read with
  # sequential scans off so that a near-empty table does not hide whether the
  # query can use it.
  #
  # The migration ran inside the test's own transaction at first, and it turned
  # the gate red on 2026-10-07: an index built over rows that earlier tests
  # updated, while another transaction could still see their old versions,
  # cannot be used by the transaction that built it. A scratch schema starts
  # with empty tables and commits each migration, as a deployment does.
  test "a reply's repaint and a thread's continuation each read an index" do
    # The lookup `Ryker.Slack.InteractionRepaint` repaints a reply by.
    delivered = Turn.Query.delivered_slack_message("T1", "C1", "1787832001.000200", nil)

    # The routing half of `Ryker.Slack.Engagement.continuation?/1`.
    continuation =
      RoutingResponse.Query.messages_in_thread("slack", "slack:T1:C1", "1787832000.000100")

    in_scratch_schema("reply_lookups", fn repo, prefix ->
      migrate!(repo, prefix, TestMigrations.version_before(@version))
      refute plan(repo, prefix, delivered) =~ @receipt_index
      refute plan(repo, prefix, continuation) =~ @thread_index

      assert @version in migrate!(repo, prefix, @version)
      assert plan(repo, prefix, delivered) =~ @receipt_index
      assert plan(repo, prefix, continuation) =~ @thread_index
    end)
  end

  # `SET LOCAL` holds for the transaction around the plan.
  defp plan(repo, prefix, query) do
    {:ok, plan} =
      repo.transact(fn ->
        SQL.query!(repo, "SET LOCAL enable_seqscan = off", [])
        SQL.explain(repo, :all, put_query_prefix(query, prefix), wrap_in_transaction: false)
      end)

    plan
  end
end
