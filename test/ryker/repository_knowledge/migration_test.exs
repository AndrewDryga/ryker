defmodule Ryker.RepositoryKnowledge.MigrationTest do
  # The DDL runs inside this test's sandbox transaction, which takes the table
  # lock, so nothing else may run beside it.
  use Ryker.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Ryker.Settings

  @version 20_260_927_220_000
  @migration Ryker.Repo.Migrations.AddRepositoryKnowledge
  @file_name "20260927220000_add_repository_knowledge.exs"
  # The migrator's own lock holds the one sandboxed connection while its task
  # waits for that same connection, so it is skipped: nothing else migrates here.
  @options [log: false, migration_lock: false]
  @actor "control-plane:local"
  @commit String.duplicate("a", 40)

  # Setup no longer reads or publishes: RYKER.md is the knowledge lane's. A
  # repository the previous release left reading or opening its pull request
  # is set up when its commit was pinned, and starts over when it was not, so
  # none is stranded in a state nothing takes up again.
  test "a repository caught mid-setup is set up or starts over, and nothing is lost" do
    {:ok, snapshot} = Settings.initialize(@actor)

    snapshot =
      Enum.reduce(~w(pinned unpinned finished), snapshot, fn ref, current ->
        {:ok, saved} =
          Settings.put_repository(
            %{ref: ref, github_repository: "acme/#{ref}", onboarding_state: :ready},
            current.installation.revision,
            @actor
          )

        saved
      end)

    assert snapshot.installation.revision > 0
    assert :ok = Ecto.Migrator.down(Repo, @version, migration(), @options)

    set!("pinned", "publishing", @commit, "# RYKER.md\n")
    set!("unpinned", "scanning", nil, nil)
    set!("finished", "ready", @commit, "# RYKER.md\n")

    assert :ok = Ecto.Migrator.up(Repo, @version, migration(), @options)

    assert rows() == [
             {"finished", "ready", @commit, "# RYKER.md\n"},
             {"pinned", "ready", @commit, "# RYKER.md\n"},
             {"unpinned", "pending", nil, nil}
           ]

    # Reading and publishing are no setup states any more.
    assert_raise Postgrex.Error, ~r/repository_github_state_valid/, fn ->
      Repo.transaction(fn -> set!("finished", "scanning", @commit, nil) end)
    end
  end

  # A knowledge session reads one repository at one commit and nothing else;
  # the previous release has nowhere to keep one, so rolling back refuses
  # while one is kept.
  test "a knowledge session names its run, repository and commit, and holds a rollback" do
    run_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    SQL.query!(
      Repo,
      "INSERT INTO repository_knowledge (repository_ref, inserted_at, updated_at) VALUES ('api', $1, $1)",
      [now]
    )

    SQL.query!(
      Repo,
      """
      INSERT INTO repository_knowledge_runs
        (id, repository_ref, generation, status, source_commit, policy, policy_digest,
         transport, conversation_ref, prompt, prompt_sha256, output_schema, manifest,
         inserted_at, updated_at)
      VALUES ($1, 'api', 1, 'prepared', $2, 'ryker-repo-api-standard', $3, 'github',
              'github:api:repository:1', '{}', $3, '{}', '{}', $4, $4)
      """,
      [Ecto.UUID.dump!(run_id), @commit, String.duplicate("b", 64), now]
    )

    assert_raise Postgrex.Error, ~r/episode_work_session_owner_valid/, fn ->
      Repo.transaction(fn -> session!(run_id, nil) end)
    end

    session!(run_id, ~s({"kind":"commit","sha":"#{@commit}"}))

    # Last: the refusal aborts the sandbox transaction.
    assert_raise Postgrex.Error, ~r/repository knowledge sessions are kept/, fn ->
      Ecto.Migrator.down(Repo, @version, migration(), @options)
    end
  end

  defp session!(run_id, source) do
    SQL.query!(
      Repo,
      """
      INSERT INTO episode_work_sessions
        (id, execution_kind, knowledge_run_id, policy, policy_digest, repository_ref,
         repository_source, external_ref, inserted_at, updated_at)
      VALUES ($1, 'knowledge', $2, 'ryker-repo-api-standard', $3, 'api', $4, $5, $6, $6)
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(run_id),
        String.duplicate("b", 64),
        source,
        "ryker-knowledge:#{run_id}",
        DateTime.utc_now()
      ]
    )
  end

  defp set!(ref, state, commit, knowledge) do
    SQL.query!(
      Repo,
      """
      UPDATE repository_settings
      SET onboarding_state = $2, source_commit = $3, knowledge_content = $4,
          knowledge_status = CASE WHEN $4::text IS NULL THEN NULL ELSE 'proposed' END,
          knowledge_source_commit = CASE WHEN $4::text IS NULL THEN NULL ELSE $3 END,
          knowledge_sha256 = CASE WHEN $4::text IS NULL THEN NULL ELSE $5 END
      WHERE ref = $1
      """,
      [ref, state, commit, knowledge, String.duplicate("c", 64)]
    )
  end

  defp rows do
    SQL.query!(
      Repo,
      "SELECT ref, onboarding_state, source_commit, knowledge_content FROM repository_settings ORDER BY ref",
      []
    ).rows
    |> Enum.map(&List.to_tuple/1)
  end

  # `ecto.migrate` loads a migration only while it is pending, so a database
  # migrated by an earlier run leaves it for this test to load.
  defp migration do
    unless Code.ensure_loaded?(@migration) do
      :ryker
      |> Application.app_dir(Path.join("priv/repo/migrations", @file_name))
      |> Code.compile_file()
    end

    @migration
  end
end
