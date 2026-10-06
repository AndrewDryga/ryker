defmodule Ryker.CoopFleet.RetireDiscardedPlacementsMigrationTest do
  @moduledoc """
  Found live 2026-09-27: 133 of the worker's 136 active placements belonged to
  sessions retention had already discarded, and every poll of the worker
  renewed each of them, 122 placement rows a second on an idle install.
  Retention now retires a session's placements as it discards it; the
  migration retires the ones left behind by the releases before that, fails
  what was still queued on them as a retired placement's commands always
  fail, and leaves every live session's placement alone.
  """
  # The migrator runs inside this test's sandbox transaction.
  use Ryker.MigrationCase
  import Ryker.TestHelpers, only: [digest: 1]
  import Ecto.Query
  alias Ryker.CanonicalJSON
  alias Ryker.CoopFleet.{Command, ControlPlane, Placement}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkerJob
  alias Ryker.Work.{Custody, Session}

  @version 20_260_927_110_000
  @authority_digest String.duplicate("d", 64)
  @policy_digest String.duplicate("b", 64)
  @sandbox_digest String.duplicate("a", 64)

  test "a discarded session's leftover placement is retired and its queued command failed, a live one is kept" do
    worker = "migration-worker-#{System.unique_integer([:positive])}"
    certificate = digest(worker)
    assert {:ok, _worker} = ControlPlane.authorize_worker(worker, "workspace-main", certificate)
    assert {:ok, _response} = ControlPlane.handle_poll(worker, poll(worker))

    leaked = place!("leaked")
    live = place!("live")

    assert {:ok, queued} =
             ControlPlane.enqueue_command(
               leaked.id,
               "get_session",
               %{"coop_session_id" => "coop-leaked"},
               "ryker:test:leaked:#{leaked.id}"
             )

    # What the releases before the fix left: the session discarded, its
    # placement still active.
    {1, nil} =
      Repo.update_all(from(session in Session, where: session.id == ^leaked.session_id),
        set: [cleanup_status: :discarded, discarded_at: Repo.now!()]
      )

    assert :ok = migrate_down(@version)
    assert :ok = migrate_up(@version)

    assert Repo.get!(Placement, leaked.id).state == :retired
    assert Repo.get!(Placement, live.id).state == :active

    failed = Repo.get!(Command, queued.id)
    assert failed.status == :failed
    assert failed.error["code"] == "operation_not_enqueued"
    assert failed.operation_key == queued.idempotency_key
    assert failed.completed_at

    assert failed.result_fingerprint ==
             CanonicalJSON.digest(%{
               "command_id" => queued.id,
               "error" => failed.error,
               "operation_key" => queued.idempotency_key,
               "resource" => nil,
               "state" => "failed"
             })
  end

  defp place!(suffix) do
    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "fleet-migration:#{suffix}:#{Ecto.UUID.generate()}",
        native_input_id: "source:#{suffix}:#{Ecto.UUID.generate()}",
        occurred_at: Repo.now!(),
        turn_ref: "turn:#{suffix}:#{Ecto.UUID.generate()}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, session} =
             Custody.pin_episode(
               command.episode_id,
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

    placement
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
