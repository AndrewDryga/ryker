defmodule Responder.Slack.ThreadStatusWorkerTest do
  alias Responder.Slack.ThreadStatusReceipts
  use Responder.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  alias Responder.Repo
  alias Responder.Slack.{ThreadStatus, ThreadStatuses, ThreadStatusWorker}

  defmodule FakeAPI do
    def set_thread_status(agent, channel_ref, thread_ref, status) do
      Agent.get_and_update(agent, fn state ->
        result = Map.get(state, :result, :ok)
        {result, Map.update!(state, :writes, &(&1 ++ [{channel_ref, thread_ref, status}]))}
      end)
    end
  end

  test "durable generations pace semantic changes and make a terminal clear win" do
    {:ok, client} = Agent.start_link(fn -> %{writes: []} end)
    {:ok, projection} = Agent.start_link(fn -> [target(:queued, "is queued...")] end)
    options = options(client, projection)

    assert {:ok, %{failed: 0, written: 1}} = ThreadStatusWorker.run_once(options)
    assert %ThreadStatus{generation: 1, delivered_generation: 1, status: :delivered} = status!()

    Agent.update(projection, fn _ -> [target(:working, "is working...")] end)
    assert {:ok, %{failed: 0, written: 0}} = ThreadStatusWorker.run_once(options)

    assert %ThreadStatus{generation: 2, delivered_generation: 1, status: :pending} =
             paced =
             status!()

    assert paced.next_attempt_at
    make_due!(paced.id)
    assert {:ok, %{failed: 0, written: 1}} = ThreadStatusWorker.run_once(options)

    Agent.update(projection, fn _ -> [target(:clear, "")] end)
    assert {:ok, %{failed: 0, written: 0}} = ThreadStatusWorker.run_once(options)
    make_due!(status!().id)
    assert {:ok, %{failed: 0, written: 1}} = ThreadStatusWorker.run_once(options)

    assert %ThreadStatus{generation: 3, delivered_generation: 3, desired_text: ""} = status!()

    assert Agent.get(client, & &1.writes) == [
             {"C456", "1787832000.000100", "is queued..."},
             {"C456", "1787832000.000100", "is working..."},
             {"C456", "1787832000.000100", ""}
           ]

    # The mutable status row previously erased both starts when the final clear arrived.
    receipts =
      ThreadStatusReceipts.for_thread("T123", "C456", "1787832000.000100")

    assert Enum.map(receipts, & &1.text) == ["is queued...", "is working...", ""]
    assert Enum.all?(receipts, & &1.acknowledged_at)
  end

  test "a Slack failure leaves a durable retry that a restarted worker honors" do
    {:ok, client} =
      Agent.start_link(fn -> %{result: {:error, :slack_unavailable}, writes: []} end)

    {:ok, projection} = Agent.start_link(fn -> [target(:queued, "is queued...")] end)
    options = options(client, projection)

    assert {:ok, %{failed: 1, written: 0}} = ThreadStatusWorker.run_once(options)

    assert %ThreadStatus{status: :pending, attempt_count: 1, next_attempt_at: %DateTime{}} =
             status!()

    assert {:ok, %{failed: 0, written: 0}} = ThreadStatusWorker.run_once(options)
    assert length(Agent.get(client, & &1.writes)) == 1
  end

  test "a newer durable generation fences confirmation of an older in-flight write" do
    assert {:ok, _statuses} =
             ThreadStatuses.reconcile(
               "T123",
               [target(:working, "is working...")],
               3_000,
               90_000
             )

    assert {:ok, claimed} = ThreadStatuses.claim_next("status:test", "T123", 30)
    assert claimed.generation == 1

    assert {:ok, _statuses} =
             ThreadStatuses.reconcile("T123", [target(:clear, "")], 3_000, 90_000)

    assert ThreadStatuses.confirm(claimed.id, claimed.lease_ref, claimed.generation) ==
             {:error, :slack_thread_status_lease_lost}

    # Slack may acknowledge the old write after a newer clear was queued.
    # Keep that observation without falsely confirming the newer desired state.
    assert {:ok, _} = ThreadStatusReceipts.record(claimed, :ok)
    assert {:ok, _} = ThreadStatusReceipts.record(claimed, :ok)

    assert [receipt] =
             ThreadStatusReceipts.for_thread("T123", "C456", "1787832000.000100")

    assert receipt.generation == 1
    assert receipt.text == "is working..."

    assert %ThreadStatus{generation: 2, desired_text: "", status: :pending} = status!()
  end

  test "a disappeared active projection becomes a newer durable clear" do
    assert {:ok, _statuses} =
             ThreadStatuses.reconcile(
               "T123",
               [target(:working, "is working...")],
               3_000,
               90_000
             )

    assert {:ok, claimed} = ThreadStatuses.claim_next("status:test", "T123", 30)

    assert {:ok, _delivered} =
             ThreadStatuses.confirm(claimed.id, claimed.lease_ref, claimed.generation)

    assert {:ok, [%ThreadStatus{desired_text: "", generation: 2, phase: :clear}]} =
             ThreadStatuses.reconcile("T123", [], 3_000, 90_000)
  end

  test "a restart can durably queue a clear without prior local status memory" do
    assert {:ok, [%ThreadStatus{desired_text: "", phase: :clear, status: :pending}]} =
             ThreadStatuses.reconcile("T123", [target(:clear, "")], 3_000, 90_000)
  end

  test "an active status is durably refreshed before Slack expires it" do
    {:ok, client} = Agent.start_link(fn -> %{writes: []} end)
    {:ok, projection} = Agent.start_link(fn -> [target(:working, "is working...")] end)
    options = options(client, projection)

    assert {:ok, %{failed: 0, written: 1}} = ThreadStatusWorker.run_once(options)
    old = DateTime.add(DateTime.utc_now(), -91, :second)
    Repo.update_all(from(status in ThreadStatus), set: [delivered_at: old])

    assert {:ok, %{failed: 0, written: 1}} = ThreadStatusWorker.run_once(options)

    assert %ThreadStatus{generation: 2, delivered_generation: 2, status: :delivered} = status!()
    assert length(Agent.get(client, & &1.writes)) == 2
  end

  test "the supervised worker advances its independent reconciliation loop" do
    parent = self()
    {:ok, client} = Agent.start_link(fn -> %{writes: []} end)

    options = %{
      api: FakeAPI,
      client: client,
      snapshot: fn "T123" ->
        send(parent, :status_snapshot)
        {:ok, []}
      end,
      worker_ref: "slack-status:T123",
      workspace_ref: "T123"
    }

    assert {:ok, pid} = start_supervised({ThreadStatusWorker, options})
    assert_receive :status_snapshot
    assert Process.alive?(pid)
  end

  test "a failed supervised cycle is visible and schedules the next attempt" do
    {:ok, client} = Agent.start_link(fn -> %{writes: []} end)

    options =
      ThreadStatusWorker.options!(%{
        api: FakeAPI,
        client: client,
        interval_ms: 50,
        snapshot: fn _workspace -> {:error, :projection_unavailable} end,
        worker_ref: "slack-status:T123",
        workspace_ref: "T123"
      })

    log =
      capture_log(fn ->
        assert {:noreply, ^options} = ThreadStatusWorker.handle_info(:work, options)
        assert_receive :work, 100
      end)

    assert log =~ "Slack thread-status worker failed: :projection_unavailable"
  end

  test "malformed status custody and worker configuration fail closed" do
    duplicate = [target(:queued, "is queued..."), target(:working, "is working...")]

    assert ThreadStatuses.reconcile("", [], 3_000, 90_000) ==
             {:error, {:invalid_slack_thread_status, :workspace_ref}}

    assert ThreadStatuses.reconcile("T123", duplicate, 3_000, 90_000) ==
             {:error, {:invalid_slack_thread_status, :targets}}

    assert ThreadStatuses.reconcile("T123", [], 0, 90_000) ==
             {:error, {:invalid_slack_thread_status, :minimum_interval_ms}}

    assert ThreadStatuses.claim_next("", "T123", 30) ==
             {:error, {:invalid_slack_thread_status, :worker_ref}}

    assert ThreadStatuses.claim_next("status:test", "T123", 4) ==
             {:error, {:invalid_slack_thread_status, :lease_seconds}}

    assert ThreadStatuses.confirm(Ecto.UUID.generate(), Ecto.UUID.generate(), 1) ==
             {:error, :slack_thread_status_not_found}

    assert_raise ArgumentError, fn -> ThreadStatusWorker.options!(invalid: true) end
    assert_raise ArgumentError, fn -> ThreadStatusWorker.options!(api: FakeAPI, api: FakeAPI) end
    assert_raise ArgumentError, fn -> ThreadStatusWorker.options!(:invalid) end

    {:ok, client} = Agent.start_link(fn -> %{writes: []} end)

    valid_keyword_options = [
      api: FakeAPI,
      client: client,
      snapshot: fn _workspace -> {:error, :unavailable} end,
      worker_ref: "status:test",
      workspace_ref: "T123"
    ]

    assert %{worker_ref: "status:test"} = ThreadStatusWorker.options!(valid_keyword_options)
    assert ThreadStatusWorker.run_once(valid_keyword_options) == {:error, :unavailable}
  end

  defp options(client, projection) do
    ThreadStatusWorker.options!(%{
      api: FakeAPI,
      client: client,
      interval_ms: 1_000,
      lease_seconds: 30,
      maximum_writes: 10,
      minimum_interval_ms: 3_000,
      refresh_interval_ms: 90_000,
      retry_base_ms: 1_000,
      snapshot: fn _workspace_ref -> {:ok, Agent.get(projection, & &1)} end,
      worker_ref: "slack-status:T123",
      workspace_ref: "T123"
    })
  end

  defp target(phase, status) do
    %{
      channel_ref: "C456",
      phase: phase,
      status: status,
      thread_ref: "1787832000.000100"
    }
  end

  defp status!, do: Repo.one!(from(status in ThreadStatus))

  defp make_due!(id) do
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    Repo.update_all(from(status in ThreadStatus, where: status.id == ^id),
      set: [next_attempt_at: past]
    )
  end
end
