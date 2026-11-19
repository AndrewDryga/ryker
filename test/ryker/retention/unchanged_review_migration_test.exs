defmodule Ryker.Retention.UnchangedReviewMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL
  alias Ryker.Admission.ReadySessions
  alias Ryker.Work.Session

  @version 20_261_119_000_000

  # Automatic acceptance must never outlive its source fence: losing that
  # distinction would turn a retry into permission to discard new commits.
  test "existing custody stays unchanged and automatic acceptance always carries a valid fence" do
    assert {:ok, session} =
             ReadySessions.reserve(
               %{name: "admission-read-only", digest: String.duplicate("a", 64)},
               1
             )

    # Production down intentionally refuses to erase custody. Recreate the previous
    # column shape only inside this test's rolled-back sandbox transaction.
    SQL.query!(
      Repo,
      "ALTER TABLE episode_work_sessions DROP COLUMN discard_plan_unchanged_head",
      []
    )

    SQL.query!(Repo, "DELETE FROM schema_migrations WHERE version = $1", [@version])
    assert migrate_up(@version) == :ok

    assert Repo.get!(Session, session.id) == session

    for size <- [40, 64] do
      assert {:ok, stored} =
               session
               |> Session.Changeset.cleanup(%{
                 discard_plan_unchanged_head: String.duplicate("a", size),
                 discard_plan_accept_unmerged: true,
                 discard_plan_accept_dirty: false
               })
               |> Repo.update()

      assert stored.discard_plan_unchanged_head == String.duplicate("a", size)
    end

    for {head, unmerged, dirty} <- [
          {"invalid", true, false},
          {String.duplicate("a", 41), true, false},
          {String.duplicate("a", 40), false, false},
          {String.duplicate("a", 40), true, true}
        ] do
      current = Repo.get!(Session, session.id)

      assert {:error, changeset} =
               current
               |> Session.Changeset.cleanup(%{
                 discard_plan_unchanged_head: head,
                 discard_plan_accept_unmerged: unmerged,
                 discard_plan_accept_dirty: dirty
               })
               |> Repo.update(mode: :savepoint)

      assert changeset.errors[:discard_plan_unchanged_head] ==
               {"is invalid",
                [constraint: :check, constraint_name: "episode_work_session_unchanged_head_valid"]}

      assert Repo.get!(Session, session.id) == current
    end

    assert_raise RuntimeError,
                 "Restore the controller backup to preserve cleanup authorization",
                 fn ->
                   migrate_down(@version)
                 end

    assert Repo.get!(Session, session.id).discard_plan_unchanged_head == String.duplicate("a", 64)
  end
end
