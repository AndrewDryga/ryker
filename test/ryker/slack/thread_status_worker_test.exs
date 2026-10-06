defmodule Ryker.Slack.ThreadStatusWorkerTest do
  alias Ryker.Slack.ThreadStatusReceipts
  use Ryker.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query
  import Ryker.TestHelpers, only: [eventually: 2]

  alias Ryker.ControlPlane.{FailureExplanation, FailureProjection}
  alias Ryker.Episodes.Episode
  alias Ryker.Operator.Failures
  alias Ryker.Repo
  alias Ryker.Slack.{ThreadStatus, ThreadStatuses, ThreadStatusProjection, ThreadStatusWorker}
  alias Ryker.Work.{Activity, Session, Turn}

  defmodule FakeAPI do
    def set_thread_status(agent, channel_ref, thread_ref, status) do
      Agent.get_and_update(agent, fn state ->
        result = Map.get(state, :result, :ok)
        {result, Map.update!(state, :writes, &(&1 ++ [{channel_ref, thread_ref, status}]))}
      end)
    end
  end

  # Failures lists a thread status Slack keeps refusing, and a request's
  # Timeline shows what its thread says. Until 2026-09-26 they heard of a
  # written or confirmed status from a trigger's NOTIFY and a five-second
  # poll; the context now announces it once the write commits.
  test "a status written and confirmed in a thread reaches the pages that show it" do
    {:ok, client} = Agent.start_link(fn -> %{writes: []} end)
    {:ok, projection} = Agent.start_link(fn -> [target(:queued, "is queued...")] end)
    :ok = ThreadStatuses.subscribe_thread_statuses()

    assert {:ok, %{failed: 0, written: 1}} =
             ThreadStatusWorker.run_once(options(client, projection))

    %ThreadStatus{id: id} = status!()
    assert_received {:thread_status_updated, ^id}
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

  # A status whose channel Slack said was gone was written again every minute
  # for as long as the thread existed, and nothing listed it; the only cap on
  # its attempts was the backoff ceiling.
  test "a thread status Slack says is gone stops retrying and is listed on Failures" do
    {:ok, client} =
      Agent.start_link(fn ->
        %{result: {:error, {:slack_api_error, "channel_not_found"}}, writes: []}
      end)

    {:ok, projection} = Agent.start_link(fn -> [target(:working, "is working...")] end)
    options = options(client, projection)

    assert {:ok, %{failed: 1, written: 0}} = ThreadStatusWorker.run_once(options)

    assert %ThreadStatus{status: :blocked, attempt_count: 1, next_attempt_at: nil} =
             blocked = status!()

    assert blocked.last_error_code == "slack_api_error"
    assert blocked.lease_ref == nil

    # Nothing claims it again.
    assert {:ok, %{failed: 0, written: 0}} = ThreadStatusWorker.run_once(options)
    assert length(Agent.get(client, & &1.writes)) == 1

    assert {:ok, failures} = FailureProjection.list(%{})
    assert %{} = row = Enum.find(failures, &(&1.ref == blocked.id))
    assert row.kind == "slack_thread_status"
    assert row.action == :rearm
    assert row.destination == "slack:T123:C456 / 1787832000.000100"
    assert row.provider_error == "channel_not_found"
    assert FailureExplanation.explain(row).outlook == :stuck

    assert {:ok, %{outcome: %{"status" => "pending"}}} =
             Failures.retry("slack_thread_status", blocked.id,
               actor_ref: "control-plane:local",
               action_ref: "control-plane:retry:#{Ecto.UUID.generate()}"
             )

    assert %ThreadStatus{status: :pending, attempt_count: 0, last_error_code: nil} = status!()
    assert FailureProjection.fetch("slack_thread_status", blocked.id) == :not_found
    assert {:error, :slack_thread_status_not_blocked} = ThreadStatuses.rearm(blocked.id)

    Agent.update(client, &%{&1 | result: :ok})
    assert {:ok, %{failed: 0, written: 1}} = ThreadStatusWorker.run_once(options)
    assert %ThreadStatus{status: :delivered, delivered_generation: 1} = status!()
  end

  # A status Slack keeps refusing for other reasons blocks after its attempts.
  # The next thing Ryker wants to show in that thread is a new write with its
  # own budget, so the blocked row clears itself and leaves Failures.
  test "a thread status that keeps failing blocks after its attempts and a newer status starts fresh" do
    {:ok, client} =
      Agent.start_link(fn -> %{result: {:error, :slack_unavailable}, writes: []} end)

    {:ok, projection} = Agent.start_link(fn -> [target(:queued, "is queued...")] end)
    options = options(client, projection, %{max_attempts: 2})

    assert {:ok, %{failed: 1, written: 0}} = ThreadStatusWorker.run_once(options)
    assert %ThreadStatus{status: :pending, attempt_count: 1} = status!()
    make_due!(status!().id)
    assert {:ok, %{failed: 1, written: 0}} = ThreadStatusWorker.run_once(options)
    assert %ThreadStatus{status: :blocked, attempt_count: 2} = blocked = status!()
    assert {:ok, %{status: :blocked}} = FailureProjection.fetch("slack_thread_status", blocked.id)

    Agent.update(projection, fn _ -> [target(:working, "is working...")] end)
    assert {:ok, %{failed: 1, written: 0}} = ThreadStatusWorker.run_once(options)

    assert %ThreadStatus{status: :pending, attempt_count: 1, generation: 2} = status!()
    assert FailureProjection.fetch("slack_thread_status", blocked.id) == :not_found
  end

  # Slack asking Ryker to slow down is its pace, not a failed write. Each 429 spent one of
  # the status's attempts, so a busy workspace blocked statuses Slack would have taken a
  # minute later (2026-10-04 review). It waits the time Slack names, attempts untouched.
  test "a rate-limited status waits as long as Slack asks without using an attempt" do
    limited = {:error, {:delivery_rate_limited, 30, {:slack_http_error, 429, "slow down"}}}
    {:ok, client} = Agent.start_link(fn -> %{result: limited, writes: []} end)
    {:ok, projection} = Agent.start_link(fn -> [target(:queued, "is queued...")] end)
    options = options(client, projection, %{max_attempts: 2})

    for _attempt <- 1..3 do
      assert {:ok, %{failed: 1, written: 0}} = ThreadStatusWorker.run_once(options)
      assert %ThreadStatus{status: :pending, attempt_count: 0} = status = status!()
      assert DateTime.diff(status.next_attempt_at, DateTime.utc_now(), :second) in 25..31
      make_due!(status.id)
    end

    Agent.update(client, &Map.put(&1, :result, :ok))
    assert {:ok, %{failed: 0, written: 1}} = ThreadStatusWorker.run_once(options)
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

  # A status that left before Slack ever showed it was turned into a clear, a write to a thread
  # showing nothing; and a clear Slack refused stayed blocked for good, one more for every
  # thread (2026-10-04 review). A status lapses by itself once Ryker stops refreshing it.
  test "a status that leaves unshown is dropped, and so is a clear Slack refused" do
    assert {:ok, _statuses} =
             ThreadStatuses.reconcile("T123", [target(:working, "is working...")], 3_000, 90_000)

    assert {:ok, []} = ThreadStatuses.reconcile("T123", [], 3_000, 90_000)
    assert Repo.aggregate(ThreadStatus, :count) == 0

    assert {:ok, _statuses} =
             ThreadStatuses.reconcile("T123", [target(:working, "is working...")], 3_000, 90_000)

    assert {:ok, shown} = ThreadStatuses.claim_next("status:test", "T123", 30)
    assert {:ok, _delivered} = ThreadStatuses.confirm(shown.id, shown.lease_ref, shown.generation)

    assert {:ok, [%ThreadStatus{id: id, phase: :clear}]} =
             ThreadStatuses.reconcile("T123", [], 3_000, 90_000)

    make_due!(id)
    assert {:ok, %ThreadStatus{} = clear} = ThreadStatuses.claim_next("status:test", "T123", 30)

    assert {:ok, %ThreadStatus{status: :blocked}} =
             ThreadStatuses.block(clear.id, clear.lease_ref, clear.generation, :channel_not_found)

    assert {:ok, []} = ThreadStatuses.reconcile("T123", [], 3_000, 90_000)
    assert Repo.aggregate(ThreadStatus, :count) == 0
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
    old = DateTime.add(Repo.now!(), -91, :second)
    Repo.update_all(from(status in ThreadStatus), set: [delivered_at: old])

    assert {:ok, %{failed: 0, written: 1}} = ThreadStatusWorker.run_once(options)

    assert %ThreadStatus{generation: 2, delivered_generation: 2, status: :delivered} = status!()
    assert length(Agent.get(client, & &1.writes)) == 2
  end

  for phase <- [:waiting_for_event, :waiting_for_input] do
    test "working to #{phase} clears once and never refreshes a working indicator" do
      # The Terraform wait kept Slack looking busy for an entire day.
      {:ok, client} = Agent.start_link(fn -> %{writes: []} end)
      {:ok, projection} = Agent.start_link(fn -> [target(:working, "is working...")] end)
      options = options(client, projection)
      assert {:ok, %{failed: 0, written: 1}} = ThreadStatusWorker.run_once(options)
      Agent.update(projection, fn _ -> [target(unquote(phase), "")] end)
      assert {:ok, %{failed: 0, written: 0}} = ThreadStatusWorker.run_once(options)
      make_due!(status!().id)
      assert {:ok, %{failed: 0, written: 1}} = ThreadStatusWorker.run_once(options)
      old = DateTime.add(DateTime.utc_now(), -3600, :second)
      Repo.update_all(from(status in ThreadStatus), set: [delivered_at: old])
      assert {:ok, %{failed: 0, written: 0}} = ThreadStatusWorker.run_once(options)
      assert status!().phase == unquote(phase)

      assert Agent.get(client, & &1.writes) == [
               {"C456", "1787832000.000100", "is working..."},
               {"C456", "1787832000.000100", ""}
             ]

      assert Enum.map(
               ThreadStatusReceipts.for_thread("T123", "C456", "1787832000.000100"),
               & &1.text
             ) == ["is working...", ""]
    end
  end

  # The status line follows every tool the running turn starts, and a
  # tool-heavy investigation starts hundreds: fifty Slack searches in a row, or
  # a search and then a channel list that read the same to a person. Writing
  # each one would spend a Slack call per tool on text that did not change;
  # only a different phrase is written, paced as before, and an unchanged one
  # waits for the refresh that keeps Slack from expiring it.
  test "an unchanged phrase is not written again before the refresh, and a new one is written once" do
    {:ok, client} = Agent.start_link(fn -> %{writes: []} end)
    options = options(client, nil, %{snapshot: &ThreadStatusProjection.snapshot/1})
    turn = running_turn!()

    narrate!(turn, 1, "tool.started", state_tool("search", "search_slack"))
    assert {:ok, %{failed: 0, written: 1}} = ThreadStatusWorker.run_once(options)

    # Well past the three-second pacing, well inside the refresh.
    settle_delivery!(-30)
    narrate!(turn, 2, "tool.completed", %{"status" => "completed", "tool_call_id" => "search"})
    narrate!(turn, 3, "tool.started", state_tool("channels", "list_slack_channels"))
    assert {:ok, %{failed: 0, written: 0}} = ThreadStatusWorker.run_once(options)
    assert %ThreadStatus{generation: 1, status: :delivered} = status!()

    narrate!(turn, 4, "tool.started", state_tool("memory", "search_memory"))
    assert {:ok, %{failed: 0, written: 1}} = ThreadStatusWorker.run_once(options)
    assert {:ok, %{failed: 0, written: 0}} = ThreadStatusWorker.run_once(options)

    settle_delivery!(-91)
    assert {:ok, %{failed: 0, written: 1}} = ThreadStatusWorker.run_once(options)

    assert Agent.get(client, & &1.writes) == [
             {"C456", "1787832000.000100", "is searching Slack…"},
             {"C456", "1787832000.000100", "is searching what it knows…"},
             {"C456", "1787832000.000100", "is searching what it knows…"}
           ]
  end

  # On 2026-09-27 an idle install committed about 125 transactions a second;
  # the thread-status worker rebuilt its projection every second. It now
  # sleeps until a message, a request or a status is announced, so a running
  # turn's next step has to wake it for the thread to say what it is doing.
  test "a step a running turn takes while the worker is idle reaches its thread at once" do
    {:ok, client} = Agent.start_link(fn -> %{writes: []} end)

    options =
      options(client, nil, %{
        idle_interval_ms: 300_000,
        interval_ms: 300_000,
        snapshot: &ThreadStatusProjection.snapshot/1
      })

    worker = start_supervised!({ThreadStatusWorker, options})
    # Its first poll found nothing, and its next timer is five minutes away.
    _state = :sys.get_state(worker)

    narrate!(running_turn!(), 1, "tool.started", state_tool("search", "search_slack"))

    assert eventually(
             fn ->
               Agent.get(client, & &1.writes) == [
                 {"C456", "1787832000.000100", "is searching Slack…"}
               ]
             end,
             500
           )
  end

  # Slack lets a thread status lapse after two minutes, so a shown one is
  # written again every ninety seconds, and only the clock says when: a
  # worker sleeping its safety-net interval would refresh it late.
  test "a shown status whose refresh falls due is written then, not at the safety-net interval" do
    {:ok, client} = Agent.start_link(fn -> %{writes: []} end)
    {:ok, projection} = Agent.start_link(fn -> [target(:working, "is working...")] end)
    options = options(client, projection, %{idle_interval_ms: 300_000, interval_ms: 300_000})

    assert {:ok, %{failed: 0, written: 1}} = ThreadStatusWorker.run_once(options)
    settle_delivery!(-89)
    start_supervised!({ThreadStatusWorker, options})

    refute eventually(fn -> length(Agent.get(client, & &1.writes)) == 2 end, 500)
    assert eventually(fn -> length(Agent.get(client, & &1.writes)) == 2 end, 1_500)
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
        assert {:noreply, ^options} = ThreadStatusWorker.handle_info(:poll, options)
        assert_receive :poll, 100
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

  defp options(client, projection, overrides \\ %{}) do
    ThreadStatusWorker.options!(
      Map.merge(
        %{
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
        },
        overrides
      )
    )
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

  defp settle_delivery!(seconds) do
    Repo.update_all(from(status in ThreadStatus),
      set: [delivered_at: DateTime.add(Repo.now!(), seconds, :second)]
    )
  end

  defp running_turn! do
    episode =
      Repo.insert!(%Episode{
        destination_conversation_ref: "slack:T123:C456",
        destination_thread_ref: "1787832000.000100",
        destination_transport: "slack",
        execution_mode: :live,
        id: Ecto.UUID.generate(),
        key: "thread-status:paced-progress",
        owner_kind: :turn,
        owner_ref: "turn:thread-status:paced-progress",
        state: :working
      })

    session =
      Repo.insert!(%Session{
        coop_session_id: "remote-session:#{Ecto.UUID.generate()}",
        episode_id: episode.id,
        external_ref: "session:thread-status:paced-progress",
        id: Ecto.UUID.generate(),
        policy: "ryker-work",
        policy_digest: String.duplicate("a", 64)
      })

    turn =
      Repo.insert!(%Turn{
        coop_turn_id: "remote-turn:#{Ecto.UUID.generate()}",
        episode_id: episode.id,
        id: Ecto.UUID.generate(),
        session_id: session.id,
        status: :pending,
        turn_ref: episode.owner_ref
      })

    %{session: session, turn: turn}
  end

  defp state_tool(call, tool) do
    %{
      "input" => %{"server" => "controller-tools", "tool" => tool},
      "kind" => "execute",
      "tool_call_id" => call
    }
  end

  defp narrate!(%{session: session, turn: turn}, sequence, type, payload) do
    assert {:ok, %{inserted: 1}} =
             Activity.ingest(session.id, [
               %{
                 "id" => "#{session.coop_session_id}:#{sequence}",
                 "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
                 "payload" => payload,
                 "sequence" => sequence,
                 "session_id" => session.coop_session_id,
                 "turn_id" => turn.coop_turn_id,
                 "type" => type,
                 "version" => 1
               }
             ])
  end

  # Due by the database's clock, which the worker claims with; a host-clock
  # "one second ago" can still be ahead of a trailing database clock.
  defp make_due!(id) do
    past = DateTime.add(Repo.now!(), -3_600, :second)

    Repo.update_all(from(status in ThreadStatus, where: status.id == ^id),
      set: [next_attempt_at: past]
    )
  end
end
