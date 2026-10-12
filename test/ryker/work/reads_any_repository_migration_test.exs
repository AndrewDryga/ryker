defmodule Ryker.Work.ReadsAnyRepositoryMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @before_version 20_261_011_230_000
  @version 20_261_012_210_000
  @digest String.duplicate("a", 64)

  # Work that only reads runs in its environment's default placement and stays about the
  # repository it chose, so one session kept ready serves a conversation about any repository of
  # the environment (Andrew, 2026-10-12: "any session should be able to serve any repo"). The
  # check lets a session be about any repository it mounts and nothing more: one outside the
  # mounted set, or a working copy also mounted read-only, is still refused, and a rollback must
  # not leave a row the earlier check refuses.
  test "a session may be about any repository it mounts, and only those" do
    in_scratch_schema("work_reads_mounted", fn repo, prefix ->
      assert @before_version in migrate!(repo, prefix, @before_version)

      assert_raise Postgrex.Error, ~r/episode_work_session_repository_context_valid/, fn ->
        insert_session!(repo, prefix, "docs", ["docs"])
      end

      assert migrate!(repo, prefix, @version) == [@version]

      _working_copy = insert_session!(repo, prefix, "app", ["docs"])
      mounted = insert_session!(repo, prefix, "docs", ["docs"])

      for {repository, read_only} <- [{"elsewhere", ["docs"]}, {"docs", ["app", "docs"]}] do
        assert_raise Postgrex.Error, ~r/episode_work_session_repository_context_valid/, fn ->
          insert_session!(repo, prefix, repository, read_only)
        end
      end

      assert_raise Postgrex.Error, ~r/mounted beside their working copy are still recorded/, fn ->
        rollback!(repo, prefix)
      end

      SQL.query!(
        repo,
        "DELETE FROM #{prefix}.episode_work_sessions WHERE id = $1::text::uuid",
        [mounted]
      )

      assert rollback!(repo, prefix) == [@version]
    end)
  end

  # A Work session kept ready, with "app" as its working copy and `read_only` beside it.
  defp insert_session!(repo, prefix, repository_ref, read_only) do
    id = Ecto.UUID.generate()

    context =
      Jason.encode!(%{
        "context_ref" => "platform",
        "parallel_goal_limit" => 2,
        "primary_repository" => "app",
        "read_only_repositories" => read_only
      })

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_work_sessions (
        id, policy, policy_digest, external_ref, execution_kind, coop_session_id, ready_state,
        repository_ref, repository_context, inserted_at, updated_at
      ) VALUES (
        $1::text::uuid, 'work-read-only', $2, $3, 'work', $4, 'ready', $5, $6, now(), now()
      )
      """,
      [id, @digest, "ryker-work-ready:#{id}", "coop-#{id}", repository_ref, context]
    )

    id
  end
end
