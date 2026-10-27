defmodule Ryker.Work.RetireCompletionReviewMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @version 20_261_027_070_000

  test "retiring the executor refuses unfinished custody and preserves all settled history" do
    # Removing the only child canceller while a reviewer still ran would leave
    # remote work unowned. A finished child can also have a pending correction.
    in_scratch_schema("retire_reviews", fn repo, prefix ->
      SQL.query!(
        repo,
        "CREATE TABLE #{prefix}.episode_work_turns (id uuid PRIMARY KEY, status text)"
      )

      SQL.query!(
        repo,
        "CREATE TABLE #{prefix}.work_completion_reviews (id uuid PRIMARY KEY, turn_id uuid, remote_stopped_at timestamptz, result text)"
      )

      id = Ecto.UUID.generate()

      SQL.query!(
        repo,
        "INSERT INTO #{prefix}.episode_work_turns VALUES ($1::text::uuid, 'settled')",
        [id]
      )

      SQL.query!(
        repo,
        "INSERT INTO #{prefix}.work_completion_reviews VALUES ($1::text::uuid, $1::text::uuid, NULL, 'retained answer')",
        [id]
      )

      assert_refused(repo, prefix)
      SQL.query!(repo, "UPDATE #{prefix}.work_completion_reviews SET remote_stopped_at = now()")

      for status <- ["pending", "cancel_pending"] do
        SQL.query!(repo, "UPDATE #{prefix}.episode_work_turns SET status = $1", [status])
        assert_refused(repo, prefix)
      end

      SQL.query!(repo, "UPDATE #{prefix}.episode_work_turns SET status = 'settled'")

      assert Ecto.Migrator.up(repo, @version, migration(@version), prefix: prefix, log: false) ==
               :ok

      assert %{rows: [[^id, true, "retained answer"]]} =
               SQL.query!(
                 repo,
                 "SELECT id::text, remote_stopped_at IS NOT NULL, result FROM #{prefix}.work_completion_reviews"
               )
    end)
  end

  defp assert_refused(repo, prefix) do
    assert_raise Postgrex.Error, ~r/Completion reviews must drain on the previous release/, fn ->
      Ecto.Migrator.up(repo, @version, migration(@version), prefix: prefix, log: false)
    end
  end
end
