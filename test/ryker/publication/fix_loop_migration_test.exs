defmodule Ryker.Publication.FixLoopMigrationTest do
  @moduledoc """
  Andrew's request, 2026-09-28: Ryker fixes and re-checks a refused change on
  its own, a bounded number of times per publication
  (`Ryker.Publication.FixLoop`). The counts are added to the publications an
  installation already has: each keeps what it had and starts with no round
  spent, no count can go below zero or name a review that never happened, and
  what was kept of a gate's output belongs to a review.
  """
  # The migrator runs inside this test's sandbox transaction.
  use Ryker.DataCase, async: false

  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.Publication.Publication

  @version 20_260_928_180_000
  @migration Ryker.Repo.Migrations.AddPublicationFixLoop
  @file_name "20260928180000_add_publication_fix_loop.exs"
  # The migrator's own lock holds the one sandboxed connection while its task
  # waits for that same connection, so it is skipped: nothing else migrates here.
  @options [log: false, migration_lock: false]

  test "every publication keeps what it had and starts with no automatic round spent" do
    %{publication: published} = PublicationFixture.published!("fix-loop-migration")
    %{publication: requested} = PublicationFixture.review_requested!("fix-loop-unreviewed")

    assert :ok = Ecto.Migrator.down(Repo, @version, migration(), @options)
    assert :ok = Ecto.Migrator.up(Repo, @version, migration(), @options)

    migrated = Repo.get!(Publication, published.id)

    assert {migrated.status, migrated.pull_request_number, migrated.review_generation} ==
             {:published, 91, published.review_generation}

    assert {migrated.fix_rounds, migrated.recheck_rounds, migrated.fix_review_generation} ==
             {0, 0, nil}

    assert migrated.review_gate_output == nil
    lost = %{"reason" => "the job's log was removed", "status" => "lost"}

    assert %Publication{review_gate_output: ^lost} =
             migrated |> Ecto.Changeset.change(review_gate_output: lost) |> Repo.update!()

    # What was kept of a gate's output belongs to a review; none, none kept.
    assert_raise Ecto.ConstraintError, ~r/episode_publication_fix_loop_valid/, fn ->
      Repo.transaction(fn ->
        Publication
        |> Repo.get!(requested.id)
        |> Ecto.Changeset.change(review_gate_output: lost)
        |> Repo.update!()
      end)
    end

    assert %Publication{fix_rounds: 3, fix_review_generation: generation} =
             migrated
             |> Ecto.Changeset.change(
               fix_rounds: 3,
               fix_review_generation: migrated.review_generation
             )
             |> Repo.update!()

    assert generation == migrated.review_generation

    for invalid <- [
          [fix_rounds: -1],
          [recheck_rounds: -1],
          [fix_review_generation: 0],
          [fix_review_generation: migrated.review_generation + 1]
        ] do
      assert_raise Ecto.ConstraintError, ~r/episode_publication_fix_loop_valid/, fn ->
        Repo.transaction(fn ->
          migrated |> Ecto.Changeset.change(invalid) |> Repo.update!()
        end)
      end
    end
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
