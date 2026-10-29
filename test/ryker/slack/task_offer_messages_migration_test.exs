defmodule Ryker.Slack.TaskOfferMessagesMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @version 20_261_029_233_000

  # A real Start task click had overwritten two offers with one progress card.
  # The upgrade must release only that shared message, rearm its real repaint,
  # and preserve source receipts and unrelated cards and denied interactions.
  test "shared task replies recover without rewriting delivered history" do
    in_scratch_schema("task_offer_messages", fn repo, prefix ->
      SQL.query!(
        repo,
        """
        CREATE TABLE #{prefix}.slack_task_cards (
          record_id text, episode_id uuid NOT NULL, message_ref text NOT NULL,
          thread_ref text NOT NULL, workspace_ref text, channel_ref text,
          card_checked_at timestamp, card_fingerprint text, status text,
          attempt_count integer, next_attempt_at timestamp, lease_owner text,
          lease_ref uuid, lease_expires_at timestamp, last_error_code text, last_error_detail text)
        """,
        []
      )

      SQL.query!(
        repo,
        """
        CREATE TABLE #{prefix}.slack_interaction_audit (
          action_id text, outcome text, repaint_status text, attempt_count integer,
          next_attempt_at timestamp, lease_owner text, lease_ref uuid,
          lease_expires_at timestamp, last_error_code text, last_error_detail text,
          repainted_at timestamp, workspace_ref text, channel_ref text, message_ref text, thread_ref text)
        """,
        []
      )

      SQL.query!(
        repo,
        "CREATE TABLE #{prefix}.episode_state_records (id text, turn_id text, kind text, payload text, ref text)",
        []
      )

      SQL.query!(
        repo,
        "CREATE TABLE #{prefix}.episode_work_turns (id text, external_receipt text, delivery_document text)",
        []
      )

      for {turn, refs, message, thread} <- [
            {"shared", ["first", "second"], "1.000001", "0.000001"},
            {"solo", ["solo"], "2.000001", "0.000001"},
            {"top", ["top-first", "top-second"], "3.000001", nil}
          ] do
        SQL.query!(repo, "INSERT INTO #{prefix}.episode_work_turns VALUES ($1, $2, $3)", [
          turn,
          Jason.encode!(%{"message_ref" => message, "thread_ref" => thread}),
          Jason.encode!(%{"outcome" => %{"record_refs" => refs}})
        ])

        for ref <- refs do
          SQL.query!(
            repo,
            "INSERT INTO #{prefix}.episode_state_records VALUES ($1, $2, 'task_offer', $3, $1)",
            [ref, turn, Jason.encode!(%{"kind" => "engineering"})]
          )
        end

        SQL.query!(
          repo,
          """
          INSERT INTO #{prefix}.slack_task_cards (record_id, episode_id, workspace_ref, channel_ref, thread_ref, message_ref)
          VALUES ($1, '00000000-0000-0000-0000-000000000001', 'T123', 'C456', $3, $2)
          """,
          [hd(refs), message, thread || message]
        )

        for outcome <- ["confirmed", "denied"] do
          SQL.query!(
            repo,
            """
            INSERT INTO #{prefix}.slack_interaction_audit (action_id, outcome, repaint_status, workspace_ref, channel_ref, thread_ref, message_ref)
            VALUES ('ryker_start_engineering_task', $1, 'settled', 'T123', 'C456', $3, $2)
            """,
            [outcome, message, thread]
          )
        end
      end

      originals =
        SQL.query!(
          repo,
          "SELECT id, external_receipt, delivery_document FROM #{prefix}.episode_work_turns ORDER BY id",
          []
        ).rows

      assert Ecto.Migrator.up(repo, @version, migration(@version), prefix: prefix, log: false) ==
               :ok

      assert %{rows: [["first", nil], ["solo", "2.000001"], ["top-first", nil]]} =
               SQL.query!(
                 repo,
                 "SELECT record_id, message_ref FROM #{prefix}.slack_task_cards ORDER BY record_id",
                 []
               )

      assert %{
               rows: [
                 ["1.000001", "confirmed", "pending"],
                 ["1.000001", "denied", "settled"],
                 ["2.000001", "confirmed", "settled"],
                 ["2.000001", "denied", "settled"],
                 ["3.000001", "confirmed", "pending"],
                 ["3.000001", "denied", "settled"]
               ]
             } =
               SQL.query!(
                 repo,
                 "SELECT message_ref, outcome, repaint_status FROM #{prefix}.slack_interaction_audit ORDER BY message_ref, outcome",
                 []
               )

      assert SQL.query!(
               repo,
               "SELECT id, external_receipt, delivery_document FROM #{prefix}.episode_work_turns ORDER BY id",
               []
             ).rows == originals

      assert %{num_rows: 1} =
               SQL.query!(
                 repo,
                 "INSERT INTO #{prefix}.slack_task_cards (record_id) VALUES ('second')",
                 []
               )
    end)
  end
end
