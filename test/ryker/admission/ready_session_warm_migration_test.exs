defmodule Ryker.Admission.ReadySessionWarmMigrationTest do
  @moduledoc """
  A routing session kept ready now records until when Coop keeps its agent
  running. The column is added to rows every installation already has: each
  must keep every value it had, and only a session kept ready may carry one.
  """
  # The migrator runs inside this test's sandbox transaction.
  use Ryker.DataCase, async: false

  alias Ryker.Admission.ReadySessions
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Work.{Custody, Session}

  @version 20_260_927_160_000
  @migration Ryker.Repo.Migrations.AddReadySessionWarmUntil
  @file_name "20260927160000_add_ready_session_warm_until.exs"
  # The migrator's own lock holds the one sandboxed connection while its task
  # waits for that same connection, so it is skipped: nothing else migrates here.
  @options [log: false, migration_lock: false]
  @policy %{name: "admission-read-only", digest: String.duplicate("a", 64)}

  test "a session kept ready keeps every value, and only such a session may be warm" do
    assert {:ok, reserved} = ReadySessions.reserve(@policy, 1)
    assert {:ok, ready} = ReadySessions.mark_ready(reserved, "coop-warm-migration")
    work = work_session!()

    assert :ok = Ecto.Migrator.down(Repo, @version, migration(), @options)
    assert :ok = Ecto.Migrator.up(Repo, @version, migration(), @options)

    kept = Repo.get!(Session, ready.id)
    assert {kept.ready_state, kept.coop_session_id} == {:ready, "coop-warm-migration"}
    assert {kept.policy, kept.policy_digest} == {@policy.name, @policy.digest}
    assert is_nil(kept.warm_until)

    ready
    |> Ecto.Changeset.change(warm_until: Repo.now!())
    |> Repo.update!()

    assert_raise Ecto.ConstraintError, ~r/episode_work_session_warm_until_valid/, fn ->
      work |> Ecto.Changeset.change(warm_until: Repo.now!()) |> Repo.update!()
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

  defp work_session! do
    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "warm-migration:#{Ecto.UUID.generate()}",
        native_input_id: "source:warm-migration:#{Ecto.UUID.generate()}",
        occurred_at: Repo.now!(),
        turn_ref: "turn:warm-migration:#{Ecto.UUID.generate()}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, session} =
             Custody.pin_episode(
               command.episode_id,
               "work-read-only",
               String.duplicate("b", 64),
               String.duplicate("d", 64),
               "ryker"
             )

    session
  end
end
