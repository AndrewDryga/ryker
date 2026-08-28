defmodule Responder.Admission.WorkerTest do
  use Responder.DataCase, async: false

  @moduletag isolation: "REPEATABLE READ"

  alias Responder.Admission.Worker
  alias Responder.Ingress.Inbox
  alias Responder.Slack.Input
  alias Responder.TestSupport.FakeCoopAPI

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
    assert :ok = stop_supervised(Worker)
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
    assert :ok = stop_supervised(Worker)
  end

  test "keeps running after an input enters durable blocked custody" do
    entry = record_input!("Ev-worker-blocked")

    {:ok, fake} =
      FakeCoopAPI.start_link([decision("reply")],
        fail_first_turn: true,
        first_turn_state: "interrupted"
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
    assert :ok = stop_supervised(Worker)
  end

  test "rejects a polling loop that would spin continuously" do
    Process.flag(:trap_exit, true)

    assert {:error, {:invalid_admission_worker, :options}} =
             Worker.start_link(
               dispatcher_options: [],
               poll_interval_ms: 0
             )
  end

  defp worker_options(fake, worker_ref) do
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
      ],
      poll_interval_ms: 10
    ]
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
      "reaction" => nil,
      "relation" => "unrelated",
      "reason" => "The incoming request can receive an immediate answer."
    })
  end

  defp eventually(predicate, attempts \\ 100)
  defp eventually(_predicate, 0), do: false

  defp eventually(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(5)
      eventually(predicate, attempts - 1)
    end
  end
end
