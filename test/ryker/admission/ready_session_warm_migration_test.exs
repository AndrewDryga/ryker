defmodule Ryker.Admission.ReadySessionWarmMigrationTest do
  @moduledoc """
  A routing session kept ready now records until when Coop keeps its agent
  running. The column is added to rows every installation already has: each
  must keep every value it had, and only a session kept ready may carry one.
  """
  # The migrator runs inside this test's sandbox transaction.
  use Ryker.MigrationCase
  alias Ryker.Admission.ReadySessions
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Work.Session

  @version 20_260_927_160_000
  @policy %{name: "admission-read-only", digest: String.duplicate("a", 64)}

  test "a session kept ready keeps every value, and only such a session may be warm" do
    assert {:ok, reserved} = ReadySessions.reserve(@policy, 1)
    assert {:ok, ready} = ReadySessions.mark_ready(reserved, "coop-warm-migration")
    work = work_session!()

    assert migrate_down(@version) == :ok
    assert migrate_up(@version) == :ok

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
             WorkSessions.pin_episode(
               command.episode_id,
               "work-read-only",
               String.duplicate("b", 64),
               authority_digest: String.duplicate("d", 64),
               repository_ref: "ryker"
             )

    session
  end
end
