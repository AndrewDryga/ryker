defmodule Ryker.Work.ReadySessionsMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @before_version 20_261_011_090_000
  @ready_version 20_261_011_230_000
  @digest String.duplicate("a", 64)

  # Work sessions kept ready add a setting to the saved work settings and let a
  # Work session wait with no episode. The upgrade must keep the settings as
  # they were, allow no episode only to a session kept ready and unclaimed, and
  # a rollback must not strand one still open, since without its state nothing
  # would ever close it on the worker.
  test "Work sessions kept ready keep existing settings, allow only unclaimed ones without an episode, and refuse to strand one" do
    in_scratch_schema("work_ready", fn repo, prefix ->
      assert @before_version in migrate!(repo, prefix, @before_version)

      SQL.query!(
        repo,
        """
        INSERT INTO #{prefix}.installation_settings (host_ref, revision, saved_by, saved_at, inserted_at)
        VALUES ('host-ready', 1, 'operator:test', now(), now())
        """,
        []
      )

      SQL.query!(
        repo,
        "INSERT INTO #{prefix}.work_settings (id, workspace_ref) VALUES ('host-ready', 'workers')",
        []
      )

      assert_raise Postgrex.Error, ~r/episode_work_session_owner_valid/, fn ->
        insert_work_session!(repo, prefix, "ready")
      end

      assert migrate!(repo, prefix, @ready_version) == [@ready_version]

      assert %{rows: [["workers", 1, 2]]} =
               SQL.query!(
                 repo,
                 "SELECT workspace_ref, ready_routing_sessions, ready_work_sessions FROM #{prefix}.work_settings",
                 []
               )

      assert_raise Postgrex.Error, ~r/work_settings_ready_work_sessions_valid/, fn ->
        SQL.query!(repo, "UPDATE #{prefix}.work_settings SET ready_work_sessions = 6", [])
      end

      ready = insert_work_session!(repo, prefix, "ready")
      _starting = insert_work_session!(repo, prefix, "starting", nil)

      # Only a session kept ready and unclaimed waits without an episode.
      for state <- [nil, "claimed"] do
        assert_raise Postgrex.Error, ~r/episode_work_session_(owner|ready_state)_valid/, fn ->
          insert_work_session!(repo, prefix, state)
        end
      end

      assert_raise Postgrex.Error, ~r/episode_work_session_owner_valid/, fn ->
        insert_work_session!(repo, prefix, "ready", "coop-task", ~s({"offer_ref":"offer:1"}))
      end

      assert_raise Postgrex.Error, ~r/Work sessions kept ready are still open/, fn ->
        rollback!(repo, prefix)
      end

      SQL.query!(
        repo,
        "UPDATE #{prefix}.episode_work_sessions SET cleanup_status = 'discarded' WHERE execution_kind = 'work'",
        []
      )

      assert rollback!(repo, prefix) == [@ready_version]
      refute column_exists?(repo, prefix, "work_settings", "ready_work_sessions")

      assert %{rows: [[0]]} =
               SQL.query!(
                 repo,
                 "SELECT count(*)::integer FROM #{prefix}.episode_work_sessions WHERE id = $1::text::uuid",
                 [ready]
               )
    end)
  end

  defp insert_work_session!(repo, prefix, ready_state, coop_session_id \\ :default, task \\ nil) do
    id = Ecto.UUID.generate()
    coop_session_id = if coop_session_id == :default, do: "coop-#{id}", else: coop_session_id

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_work_sessions (
        id, policy, policy_digest, external_ref, execution_kind, coop_session_id, ready_state,
        workspace_task, inserted_at, updated_at
      ) VALUES (
        $1::text::uuid, 'work-read-only', $2, $3, 'work', $4, $5, $6, now(), now()
      )
      """,
      [id, @digest, "ryker-work-ready:#{id}", coop_session_id, ready_state, task]
    )

    id
  end

  defp column_exists?(repo, prefix, table, column) do
    %{rows: [[exists?]]} =
      SQL.query!(
        repo,
        """
        SELECT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
        )
        """,
        [prefix, table, column]
      )

    exists?
  end
end
