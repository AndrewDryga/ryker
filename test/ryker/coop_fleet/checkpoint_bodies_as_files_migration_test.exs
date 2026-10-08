defmodule Ryker.CoopFleet.CheckpointBodiesAsFilesMigrationTest do
  @moduledoc """
  Version-1 checkpoints kept their bodies in three columns nothing has read or
  written since 2026-09-26. The migration drops them, and stops instead while a
  row still keeps its body there: removing an old interface never deletes
  history.
  """
  # The migrator runs inside this test's sandbox transaction.
  use Ryker.MigrationCase
  import Ryker.TestHelpers, only: [digest: 1]
  alias Ryker.CoopFleet.ControlPlane
  alias Ryker.Episodes
  alias Ryker.Fixtures.CoopWorkers
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkerJob
  alias Ryker.Fixtures.WorkSessions

  @version 20_261_004_120_000
  @authority_digest String.duplicate("d", 64)
  @policy_digest String.duplicate("b", 64)
  @sandbox_digest String.duplicate("a", 64)

  test "a checkpoint body kept in the database stops the migration; without one its columns go" do
    command = command!()
    assert migrate_down(@version) == :ok
    assert column?("ciphertext")

    body = :binary.copy(<<3>>, 16)
    digest = digest(body)

    Repo.query!(
      """
      INSERT INTO coop_worker_workspace_checkpoints
        (id, command_id, worker_id, checkpoint_ref, session_ref, placement_generation,
         repository_ref, descriptor, bundle_sha256, bundle_byte_size, encryption_key_sha256,
         encryption_nonce, encryption_tag, ciphertext, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'checkpoint:version-1', 'session-1', 1, 'ryker', '{"version":1}',
              $4, 16, $4, $5, $6, $7, now(), now())
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(command.id),
        command.worker_id,
        digest,
        :binary.copy(<<1>>, 12),
        :binary.copy(<<2>>, 16),
        body
      ]
    )

    assert_raise Postgrex.Error, ~r/still keeps its body in the database/, fn ->
      migrate_up(@version)
    end

    assert Repo.query!("SELECT ciphertext FROM coop_worker_workspace_checkpoints").rows == [
             [body]
           ]

    Repo.query!("DELETE FROM coop_worker_workspace_checkpoints")
    assert migrate_up(@version) == :ok

    refute column?("ciphertext")
    refute column?("encryption_nonce")
    refute column?("encryption_tag")
    assert nullable?("body_command_id") == false
  end

  defp column?(name), do: columns(name) != []

  defp nullable?(name), do: columns(name) == [["YES"]]

  defp columns(name) do
    Repo.query!(
      """
      SELECT is_nullable FROM information_schema.columns
      WHERE table_schema = current_schema()
        AND table_name = 'coop_worker_workspace_checkpoints' AND column_name = $1
      """,
      [name]
    ).rows
  end

  defp command! do
    worker = "migration-worker-#{System.unique_integer([:positive])}"
    certificate = digest(worker)
    assert {:ok, _worker} = CoopWorkers.authorize(worker, "workspace-main", certificate)
    assert {:ok, _response} = ControlPlane.handle_poll_certificate(worker, poll(worker))

    admitted =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "checkpoint-migration:#{Ecto.UUID.generate()}",
        native_input_id: "source:checkpoint:#{Ecto.UUID.generate()}",
        occurred_at: Repo.now!(),
        turn_ref: "turn:checkpoint:#{Ecto.UUID.generate()}"
      })

    assert {:ok, _transition} = Episodes.apply(admitted)

    assert {:ok, session} =
             WorkSessions.pin_episode(admitted.episode_id, "work-read-only", @policy_digest,
               authority_digest: @authority_digest,
               repository_ref: "ryker"
             )

    session = WorkerJob.pin!(session)

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: ["controller-tools"],
                 repository_ref: "ryker",
                 workspace_ref: "workspace-main"
               },
               60
             )

    assert {:ok, command} =
             ControlPlane.enqueue_command(
               placement.id,
               "get_session",
               %{"coop_session_id" => "coop-checkpoint"},
               "ryker:test:checkpoint:#{placement.id}"
             )

    command
  end

  defp poll(worker) do
    %{
      "acknowledged_command_ids" => [],
      "command_results" => [],
      "event_batches" => [],
      "poll_ref" => "poll:#{worker}:hello",
      "version" => 2,
      "worker" => %{
        "build_version" => "coop-abc123",
        "capabilities" => [%{"name" => "controller-tools", "version" => "1"}],
        "capacity" => %{
          "cooldown_until" => nil,
          "session_slots_free" => 4,
          "session_slots_total" => 4,
          "state" => "eligible",
          "turn_slots_free" => 4,
          "turn_slots_total" => 4,
          "workspace_slots_free" => 4,
          "workspace_slots_total" => 4
        },
        "clock_at" => DateTime.to_iso8601(Repo.now!()),
        "id" => worker,
        "protocol_version" => "2",
        "sandbox_digest" => @sandbox_digest,
        "state" => "eligible",
        "workspace_ref" => "workspace-main"
      }
    }
  end
end
