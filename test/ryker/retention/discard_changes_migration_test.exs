defmodule Ryker.Retention.DiscardChangesMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @previous_version 20_261_010_030_000
  @version 20_261_010_040_000
  @digest String.duplicate("a", 64)

  # The audited operator action gains a name, and every session a column the dispatcher reads;
  # existing sessions must read "not accepted", and a rollback must not lose a recorded action.
  test "discarding a copy's changes is recorded by name, and existing sessions accept none" do
    in_scratch_schema("discard_changes", fn repo, prefix ->
      assert migrate!(repo, prefix, @previous_version) |> List.last() == @previous_version
      input_id = insert_input!(repo, prefix)
      session_id = insert_session!(repo, prefix, input_id)

      assert_raise Postgrex.Error, ~r/retention_operator_action_valid/, fn ->
        insert_action!(repo, prefix, session_id, "discard_changes")
      end

      assert migrate!(repo, prefix, @version) == [@version]

      assert %{rows: [[false]]} =
               SQL.query!(
                 repo,
                 "SELECT discard_plan_accept_dirty FROM #{prefix}.episode_work_sessions WHERE id = $1::text::uuid",
                 [session_id]
               )

      action_id = insert_action!(repo, prefix, session_id, "discard_changes")

      assert_raise Postgrex.Error, ~r/retention_operator_action_valid/, fn ->
        rollback!(repo, prefix)
      end

      SQL.query!(
        repo,
        "DELETE FROM #{prefix}.retention_operator_actions WHERE id = $1::text::uuid",
        [action_id]
      )

      assert rollback!(repo, prefix) == [@version]

      assert %{rows: [[false]]} =
               SQL.query!(
                 repo,
                 """
                 SELECT EXISTS (
                   SELECT 1 FROM information_schema.columns
                   WHERE table_schema = $1 AND table_name = 'episode_work_sessions'
                     AND column_name = 'discard_plan_accept_dirty'
                 )
                 """,
                 [prefix]
               )
    end)
  end

  defp insert_input!(repo, prefix) do
    id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.ingress_inbox_entries (
        id, dedupe_key, event_fingerprint, source_kind, source_ref, event_ref, event_kind,
        native_input_id, actor_kind, actor_ref, destination_transport,
        destination_conversation_ref, revision, occurred_at, content, status, inserted_at,
        updated_at, source_capabilities
      ) VALUES (
        $1::text::uuid, 'dedupe:changes', $2, 'slack', 'T123', 'Ev-changes', 'message',
        'native-changes', 'user', 'U123', 'slack', 'slack:T123:C456', 1, now(), '{}', 'pending',
        now(), now(), '{}'
      )
      """,
      [id, @digest]
    )

    id
  end

  defp insert_session!(repo, prefix, input_id) do
    id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_work_sessions (
        id, policy, policy_digest, external_ref, generation, execution_kind, admission_input_id,
        inserted_at, updated_at
      ) VALUES (
        $1::text::uuid, 'ryker-admission', $2, $3, 1, 'admission', $4::text::uuid, now(), now()
      )
      """,
      [id, @digest, "ryker-admission:#{input_id}:g1", input_id]
    )

    id
  end

  defp insert_action!(repo, prefix, session_id, action) do
    id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.retention_operator_actions (
        id, session_id, action_ref, request_fingerprint, actor_ref, action, previous_status,
        result_status, occurred_at, inserted_at, updated_at
      ) VALUES (
        $1::text::uuid, $2::text::uuid, $3, $4, 'operator:test', $5, 'retained', 'plan_pending',
        now(), now(), now()
      )
      """,
      [id, session_id, "retention-action:#{id}", @digest, action]
    )

    id
  end
end
