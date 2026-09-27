defmodule Ryker.Admission.ReadySessionsMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :ryker,
      adapter: Ecto.Adapters.Postgres
  end

  @baseline_version 20_260_926_100_000
  @ready_sessions_version 20_260_926_120_000
  @migrations_path Path.expand("../../../priv/repo/migrations", __DIR__)
  @digest String.duplicate("a", 64)

  # Routing sessions kept ready add a setting and a custody state to rows
  # every installation already has: the saved work settings and every routing
  # session. The upgrade must keep both as they were, and a rollback must not
  # strand a started session that no message claimed, since without its state
  # nothing would ever close it on the worker.
  test "ready routing sessions keep existing settings and sessions and refuse to strand one" do
    repo = start_migration_repo!()
    prefix = "ready_sessions_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      assert Ecto.Migrator.run(repo, @migrations_path, :up,
               to: @baseline_version,
               prefix: prefix,
               log: false
             ) == [@baseline_version]

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

      input_id = insert_input!(repo, prefix)
      first = insert_admission_session!(repo, prefix, input_id, 1)
      second = insert_admission_session!(repo, prefix, input_id, 2)

      assert Ecto.Migrator.run(repo, @migrations_path, :up,
               to: @ready_sessions_version,
               prefix: prefix,
               log: false
             ) == [20_260_926_101_000, 20_260_926_111_000, @ready_sessions_version]

      # The saved settings keep every value and read one ready session.
      assert %{rows: [["workers", "codex:gpt-5.6-sol/medium@default", 1]]} =
               SQL.query!(
                 repo,
                 "SELECT workspace_ref, routing_model, ready_routing_sessions FROM #{prefix}.work_settings",
                 []
               )

      assert_raise Postgrex.Error, ~r/work_settings_ready_routing_sessions_valid/, fn ->
        SQL.query!(repo, "UPDATE #{prefix}.work_settings SET ready_routing_sessions = 6", [])
      end

      # Routing sessions routing created itself are untouched and stay out of
      # the ready pool.
      assert %{rows: rows} =
               SQL.query!(
                 repo,
                 "SELECT id::text, external_ref, generation, ready_state FROM #{prefix}.episode_work_sessions ORDER BY generation",
                 []
               )

      assert rows == [
               [first, "ryker-admission:#{input_id}:g1", 1, nil],
               [second, "ryker-admission:#{input_id}:g2", 2, nil]
             ]

      # One routing generation has one session, whichever way it got it.
      assert_raise Postgrex.Error, ~r/episode_work_sessions_admission_generation_index/, fn ->
        insert_admission_session!(repo, prefix, input_id, 1, "ryker-admission-ready:second")
      end

      ready = insert_ready_session!(repo, prefix)

      assert_raise Postgrex.Error, ~r/routing sessions kept ready are still open/, fn ->
        Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, prefix: prefix, log: false)
      end

      SQL.query!(
        repo,
        "UPDATE #{prefix}.episode_work_sessions SET cleanup_status = 'discarded' WHERE id = $1::text::uuid",
        [ready]
      )

      assert Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, prefix: prefix, log: false) ==
               [@ready_sessions_version]

      refute column_exists?(repo, prefix, "work_settings", "ready_routing_sessions")
      refute column_exists?(repo, prefix, "episode_work_sessions", "ready_state")

      assert %{rows: [["workers"]]} =
               SQL.query!(repo, "SELECT workspace_ref FROM #{prefix}.work_settings", [])

      assert %{rows: [[3]]} =
               SQL.query!(
                 repo,
                 "SELECT count(*)::integer FROM #{prefix}.episode_work_sessions",
                 []
               )
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
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
        $1::text::uuid, 'dedupe:ready', $2, 'slack', 'T123', 'Ev-ready', 'message',
        'native-ready', 'user', 'U123', 'slack', 'slack:T123:C456', 1, now(), '{}', 'pending',
        now(), now(), '{}'
      )
      """,
      [id, @digest]
    )

    id
  end

  defp insert_admission_session!(repo, prefix, input_id, generation, external_ref \\ nil) do
    id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_work_sessions (
        id, policy, policy_digest, external_ref, generation, execution_kind, admission_input_id,
        inserted_at, updated_at
      ) VALUES (
        $1::text::uuid, 'ryker-admission', $2, $3, $4, 'admission', $5::text::uuid, now(), now()
      )
      """,
      [
        id,
        @digest,
        external_ref || "ryker-admission:#{input_id}:g#{generation}",
        generation,
        input_id
      ]
    )

    id
  end

  defp insert_ready_session!(repo, prefix) do
    id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_work_sessions (
        id, policy, policy_digest, external_ref, execution_kind, coop_session_id, ready_state,
        inserted_at, updated_at
      ) VALUES (
        $1::text::uuid, 'ryker-admission', $2, $3, 'admission', 'coop-ready', 'ready', now(), now()
      )
      """,
      [id, @digest, "ryker-admission-ready:#{id}"]
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

  defp start_migration_repo! do
    config =
      Ryker.Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({MigrationRepo, config})
    MigrationRepo
  end
end
