defmodule Ryker.CoopFleet.CheckpointBodiesAsFilesMigrationTest do
  @moduledoc """
  Version-1 checkpoints kept their bodies in three columns nothing has read or
  written since 2026-09-26. The migration drops them, and stops instead while a
  row still keeps its body there: removing an old interface never deletes
  history.
  """
  # The migrator runs inside this test's sandbox transaction.
  use Ryker.DataCase, async: false

  alias Ryker.CoopFleet.ControlPlane
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkerJob
  alias Ryker.Work.Custody

  @version 20_261_004_120_000
  @migration Ryker.Repo.Migrations.KeepCheckpointBodiesOnlyAsFiles
  @file_name "20261004120000_keep_checkpoint_bodies_only_as_files.exs"
  # The migrator's own lock holds the one sandboxed connection while its task
  # waits for that same connection, so it is skipped: nothing else migrates here.
  @options [log: false, migration_lock: false]
  @authority_digest String.duplicate("d", 64)
  @policy_digest String.duplicate("b", 64)
  @sandbox_digest String.duplicate("a", 64)

  test "a checkpoint body kept in the database stops the migration; without one its columns go" do
    command = command!()
    assert :ok = Ecto.Migrator.down(Repo, @version, migration(), @options)
    assert column?("ciphertext")

    body = :binary.copy(<<3>>, 16)
    digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

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
      Ecto.Migrator.up(Repo, @version, migration(), @options)
    end

    assert Repo.query!("SELECT ciphertext FROM coop_worker_workspace_checkpoints").rows == [
             [body]
           ]

    Repo.query!("DELETE FROM coop_worker_workspace_checkpoints")
    assert :ok = Ecto.Migrator.up(Repo, @version, migration(), @options)

    refute column?("ciphertext")
    refute column?("encryption_nonce")
    refute column?("encryption_tag")
    assert nullable?("body_command_id") == false
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
    certificate = :crypto.hash(:sha256, worker) |> Base.encode16(case: :lower)
    assert {:ok, _worker} = ControlPlane.authorize_worker(worker, "workspace-main", certificate)
    assert {:ok, _response} = ControlPlane.handle_poll(worker, poll(worker))

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
             Custody.pin_episode(
               admitted.episode_id,
               "work-read-only",
               @policy_digest,
               @authority_digest,
               "ryker"
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
