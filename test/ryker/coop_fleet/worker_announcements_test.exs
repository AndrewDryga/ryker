defmodule Ryker.CoopFleet.WorkerAnnouncementsTest do
  @moduledoc """
  The pages that show the Coop fleet (Activity's worker line, whether Chat can
  run, Working copies' storage, the settings pages) and a request's Timeline,
  which shows what a worker reported about its session, hear of a change from
  the fleet itself.

  Until 2026-09-26 a trigger on every coop_* table redrew seven pages on each
  worker poll, every few seconds, whether or not anything they show had
  changed; and a worker that simply stopped polling changed no row at all, so
  only the pages' own five-second poll ever showed that it had gone.
  """
  use Ryker.DataCase, async: true
  import Ryker.TestHelpers, only: [digest: 1, eventually: 2]
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.ControlPlane.WorkerLiveness
  alias Ryker.CoopFleet.{ControlPlane, Worker}
  alias Ryker.CoopFleet.ControlPlane.Workers
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkerJob
  alias Ryker.Work.Custody

  @authority_digest String.duplicate("d", 64)
  @policy_digest String.duplicate("b", 64)
  @sandbox_digest String.duplicate("a", 64)

  test "a poll that changes what a page shows about a worker is announced, and a heartbeat is not" do
    worker_id = unique("worker")
    :ok = Workers.subscribe_workers()

    assert {:ok, _worker} =
             ControlPlane.authorize_worker(worker_id, "workspace-main", digest(worker_id))

    assert {:ok, _response} = ControlPlane.handle_poll(worker_id, poll(worker_id, "hello"))
    assert_received {:coop_worker_updated, ^worker_id}

    assert {:ok, _response} = ControlPlane.handle_poll(worker_id, poll(worker_id, "heartbeat"))
    refute_received {:coop_worker_updated, ^worker_id}

    assert {:ok, _response} =
             ControlPlane.handle_poll(worker_id, poll(worker_id, "busy", capacity: capacity(0)))

    assert_received {:coop_worker_updated, ^worker_id}
  end

  # A worker measures its storage as files come and go, so the bytes move on
  # almost every poll; announcing them would redraw six pages every few
  # seconds, the poll this replaced. Whether it takes new copies is what a
  # page decides on.
  test "a poll that re-measures storage is not announced, and one that refuses new copies is" do
    worker_id = unique("worker")
    :ok = Workers.subscribe_workers()

    assert {:ok, _worker} =
             ControlPlane.authorize_worker(worker_id, "workspace-main", digest(worker_id))

    assert {:ok, _response} =
             ControlPlane.handle_poll(worker_id, poll(worker_id, "measured", storage: storage()))

    assert_received {:coop_worker_updated, ^worker_id}

    remeasured = storage(free_bytes: 3_221_225_472, measured_at: "2026-09-11T09:31:00Z")

    assert {:ok, _response} =
             ControlPlane.handle_poll(
               worker_id,
               poll(worker_id, "remeasured", storage: remeasured)
             )

    refute_received {:coop_worker_updated, ^worker_id}

    refused = storage(allocation: "refused", refusal_reason: "reserve_exhausted")

    assert {:ok, _response} =
             ControlPlane.handle_poll(worker_id, poll(worker_id, "refused", storage: refused))

    assert_received {:coop_worker_updated, ^worker_id}
  end

  test "what a worker reports about a session reaches the session's request" do
    worker_id = unique("worker")

    assert {:ok, _worker} =
             ControlPlane.authorize_worker(worker_id, "workspace-main", digest(worker_id))

    assert {:ok, _response} = ControlPlane.handle_poll(worker_id, poll(worker_id, "hello"))
    session = session!()
    episode_id = session.episode_id

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

    :ok = Episodes.subscribe_episode(episode_id)

    batch = %{
      "after_sequence" => 0,
      "events" => [%{"kind" => "session", "payload" => %{"state" => "open"}, "sequence" => 1}],
      "placement_generation" => placement.generation,
      "session_ref" => session.id
    }

    assert {:ok, _response} =
             ControlPlane.handle_poll(
               worker_id,
               poll(worker_id, "events", event_batches: [batch])
             )

    assert_received {:episode_updated, ^episode_id}
  end

  test "a worker that stops reporting is announced once, when its heartbeat goes stale" do
    worker_id = insert_worker!()
    :ok = Workers.subscribe_workers()

    reporting = Workers.announce_quiet(MapSet.new())
    assert MapSet.member?(reporting, worker_id)
    refute_received {:coop_worker_updated, ^worker_id}

    silence!(worker_id)
    reporting = Workers.announce_quiet(reporting)
    refute MapSet.member?(reporting, worker_id)
    assert_received {:coop_worker_updated, ^worker_id}

    Workers.announce_quiet(reporting)
    refute_received {:coop_worker_updated, ^worker_id}
  end

  test "while the console runs, a worker that goes quiet is announced without anyone asking" do
    worker_id = insert_worker!()
    :ok = Workers.subscribe_workers()

    liveness = start_supervised!({WorkerLiveness, interval_ms: 50})
    Sandbox.allow(Repo, self(), liveness)

    # The first check learns who is reporting; only a later one can see a
    # worker leave that set.
    assert eventually(
             fn -> MapSet.member?(:sys.get_state(liveness).reporting, worker_id) end,
             1_000
           ),
           "the liveness clock never saw #{worker_id} reporting"

    silence!(worker_id)

    assert_receive {:coop_worker_updated, ^worker_id}, 1_000
  end

  defp insert_worker! do
    worker_id = unique("worker")
    now = Repo.now!()

    Repo.insert!(%Worker{
      id: worker_id,
      workspace_ref: "workspace-main",
      certificate_sha256: digest(worker_id),
      state: :eligible,
      last_seen_at: now,
      inserted_at: now,
      updated_at: now
    })

    worker_id
  end

  defp silence!(worker_id) do
    quiet_since = DateTime.add(Repo.now!(), -61, :second)

    Repo.update_all(from(worker in Worker, where: worker.id == ^worker_id),
      set: [last_seen_at: quiet_since]
    )
  end

  defp session! do
    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: unique("fleet-announced"),
        native_input_id: unique("source"),
        occurred_at: Repo.now!(),
        turn_ref: unique("turn")
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

    WorkerJob.pin!(session)
  end

  defp poll(worker_id, poll_ref, options \\ []) do
    %{
      "acknowledged_command_ids" => [],
      "command_results" => [],
      "event_batches" => Keyword.get(options, :event_batches, []),
      "poll_ref" => "poll:#{worker_id}:#{poll_ref}",
      "version" => 2,
      "worker" => %{
        "build_version" => "coop-abc123",
        "capabilities" => [%{"name" => "controller-tools", "version" => "1"}],
        "capacity" => Keyword.get(options, :capacity, capacity(2)),
        "clock_at" => DateTime.to_iso8601(Repo.now!()),
        "id" => worker_id,
        "protocol_version" => "2",
        "sandbox_digest" => @sandbox_digest,
        "state" => "eligible",
        "storage" => Keyword.get(options, :storage),
        "workspace_ref" => "workspace-main"
      }
    }
  end

  defp storage(overrides \\ []) do
    %{
      "allocation" => Keyword.get(overrides, :allocation, "open"),
      "capacity_bytes" => 536_870_912_000,
      "disposable_bytes" => 9_663_676_416,
      "free_bytes" => Keyword.get(overrides, :free_bytes, 4_294_967_296),
      "high_watermark_bytes" => 64_424_509_440,
      "low_watermark_bytes" => 48_318_382_080,
      "measured_at" => Keyword.get(overrides, :measured_at, "2026-09-11T09:30:00Z"),
      "protected_bytes" => 21_474_836_480,
      "refusal_reason" => Keyword.get(overrides, :refusal_reason),
      "reserve_bytes" => 5_368_709_120,
      "unattributed_bytes" => 1_073_741_824,
      "version" => 1
    }
  end

  defp capacity(free) do
    %{
      "cooldown_until" => nil,
      "session_slots_free" => free,
      "session_slots_total" => 4,
      "state" => "eligible",
      "turn_slots_free" => free,
      "turn_slots_total" => 4,
      "workspace_slots_free" => free,
      "workspace_slots_total" => 4
    }
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
