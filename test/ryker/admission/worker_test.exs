defmodule Ryker.Admission.WorkerTest do
  use Ryker.DataCase, async: false
  import Ryker.TestHelpers, only: [eventually: 1, eventually: 2]
  alias Ryker.Admission.Worker
  alias Ryker.Ingress.Inbox
  alias Ryker.Slack.Input
  alias Ryker.TestSupport.FakeCoopAPI

  @moduletag isolation: "REPEATABLE READ"

  @now ~U[2026-08-27 12:00:00.000000Z]

  test "polls the durable inbox and processes an input without an external nudge" do
    entry = record_input!("Ev-worker-success")
    {:ok, fake} = FakeCoopAPI.start_link([decision("reply")])

    worker = start_supervised!({Worker, worker_options(fake, "worker:success")})
    assert Process.alive?(worker)

    assert eventually(fn ->
             case Inbox.fetch(Inbox.ref(entry)) do
               {:ok, decided} -> decided.status == :decided and decided.lease_ref == nil
               :error -> false
             end
           end)

    assert FakeCoopAPI.state(fake).submit_count == 1
    assert stop_supervised(Worker) == :ok
  end

  test "keeps running after a transient Coop failure and leaves a durable retry" do
    entry = record_input!("Ev-worker-deferred")
    {:ok, fake} = FakeCoopAPI.start_link([decision("reply")], fail_create: true)

    worker = start_supervised!({Worker, worker_options(fake, "worker:deferred")})

    assert eventually(fn ->
             case Inbox.fetch(Inbox.ref(entry)) do
               {:ok, deferred} ->
                 deferred.status == :pending and deferred.attempt_count == 1 and
                   deferred.lease_ref == nil and deferred.last_error_code == "coop_unavailable"

               :error ->
                 false
             end
           end)

    assert Process.alive?(worker)
    assert stop_supervised(Worker) == :ok
  end

  test "keeps running after an input enters durable blocked custody" do
    entry = record_input!("Ev-worker-blocked")

    # A failed run blocks its input for a person at once; a stopped one is read
    # again by a fresh run instead, so it does not reach blocked custody here.
    {:ok, fake} =
      FakeCoopAPI.start_link([decision("reply")],
        fail_first_turn: true,
        first_turn_state: "failed"
      )

    worker = start_supervised!({Worker, worker_options(fake, "worker:blocked")})
    monitor_ref = Process.monitor(worker)

    assert eventually(fn ->
             case Inbox.fetch(Inbox.ref(entry)) do
               {:ok, blocked} -> blocked.status == :blocked and blocked.lease_ref == nil
               :error -> false
             end
           end)

    refute_receive {:DOWN, ^monitor_ref, :process, ^worker, _reason}, 100
    assert Process.alive?(worker)
    assert FakeCoopAPI.state(fake).submit_count == 1
    assert stop_supervised(Worker) == :ok
  end

  # On 2026-09-27 an idle install committed about 125 transactions a second,
  # the four routing slots alone polling the inbox every 250 ms. A slot now
  # sleeps until the inbox announces a message, so that announcement is all
  # that stands between a person and their answer.
  test "a message recorded while routing is idle is routed at once, not at the next timer" do
    {:ok, fake} = FakeCoopAPI.start_link([decision("reply")])

    worker =
      start_supervised!(
        {Worker,
         worker_options(fake, "worker:woken", poll_interval_ms: 60_000, idle_interval_ms: 60_000)}
      )

    # Its first poll found nothing, and its next timer is a minute away.
    _state = :sys.get_state(worker)
    entry = record_input!("Ev-worker-woken")

    # Routed long before the minute-long timer: only the announcement could
    # have woken it. A 500 ms budget measured the machine instead, and failed
    # two gates on 2026-10-07 under host load above 30.
    assert eventually(fn -> decided?(entry) end, 10_000)
  end

  # Only the clock makes a deferred message claimable again, and nothing
  # announces the clock: an idle slot that slept its whole safety-net interval
  # would answer a message whose retry fell due ten seconds late.
  test "a message whose retry falls due is routed then, not at the safety-net interval" do
    entry = record_input!("Ev-worker-due")
    input_ref = Inbox.ref(entry)
    now = DateTime.utc_now()
    {:ok, %{lease_ref: lease_ref}} = Inbox.claim_next("worker:earlier", now, 300)
    {:ok, _deferred} = Inbox.defer(input_ref, lease_ref, now, 300, "coop_unavailable", "down")
    {:ok, fake} = FakeCoopAPI.start_link([decision("reply")])

    options =
      fake
      |> worker_options("worker:due", poll_interval_ms: 60_000, idle_interval_ms: 60_000)
      |> put_in([:dispatcher_options, :now], &DateTime.utc_now/0)

    start_supervised!({Worker, options})

    assert eventually(fn -> decided?(entry) end, 1_500)
  end

  test "rejects a polling loop that would spin continuously" do
    Process.flag(:trap_exit, true)

    assert Worker.start_link(
             dispatcher_options: [],
             poll_interval_ms: 0
           ) == {:error, {:invalid_admission_worker, :options}}
  end

  defp decided?(entry) do
    case Inbox.fetch(Inbox.ref(entry)) do
      {:ok, decided} -> decided.status == :decided
      :error -> false
    end
  end

  defp worker_options(fake, worker_ref, intervals \\ [poll_interval_ms: 10]) do
    [
      dispatcher_options: [
        executor_options: [
          api: FakeCoopAPI,
          client: fake,
          max_polls: 10,
          now: fn -> @now end,
          policy: "admission-read-only",
          policy_digest: String.duplicate("a", 64),
          poll_interval_ms: 0,
          sleep: fn _milliseconds -> :ok end
        ],
        lease_seconds: 300,
        now: fn -> @now end,
        retry_base_ms: 1_000,
        retry_max_ms: 60_000,
        worker_ref: worker_ref
      ]
    ] ++ intervals
  end

  defp record_input!(event_ref) do
    assert {:ok, input} =
             Input.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Please answer this event"},
               event_kind: :message,
               event_ref: event_ref,
               message_ref: "1787832000.000100",
               occurred_at: @now,
               revision: 1,
               thread_ref: nil,
               workspace_ref: "T123"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  defp decision(action) do
    Jason.encode!(%{
      "action" => action,
      "episode_ref" => nil,
      "messages" => nil,
      "reactions" => nil,
      "relation" => "unrelated",
      "repository" => nil,
      "repository_source" => nil,
      "reason" => "The incoming request can receive an immediate answer.",
      "work_class" => if(action == "reply", do: "conversational", else: "standard")
    })
  end
end
