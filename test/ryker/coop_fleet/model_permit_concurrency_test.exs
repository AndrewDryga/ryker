defmodule Ryker.CoopFleet.ModelPermitConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.CoopFleet.{Certificate, ModelBucket, ModelGrants}
  alias Ryker.CoopFleet.{ModelPermit, ModelPermits, Placement, Worker}
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Repo
  alias Ryker.Work.Session

  # Supervised inference owners need their own physical connections, just as
  # production requests do; shared sandbox ownership would serialize the test.
  setup_all do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  setup do
    context = Ryker.Fixtures.ModelAccess.create!()
    session = context.session
    clean_up_on_exit(fn -> cleanup!(session) end)
    {:ok, grant} = ModelGrants.issue(context.certificate, session.external_ref, context.request)

    {:ok, binding} =
      ModelGrants.authorize(context.certificate, session.external_ref, "claude", grant["token"])

    {:ok, binding: binding}
  end

  test "simultaneous admissions on independent SQL connections cannot overbook one principal", %{
    binding: binding
  } do
    parent = self()

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :start -> :ok
          end

          result = ModelPermits.reserve(binding, fn -> {:ok, binding} end)
          send(parent, {:reserved, self(), result})

          receive do
            :finish -> :ok
          end

          case result do
            {:ok, lease} -> ModelPermits.cancel(lease)
            _limited -> :ok
          end
        end)
      end

    try do
      for _ <- tasks, do: assert_receive({:ready, _pid}, 5_000)
      for task <- tasks, do: send(task.pid, :start)

      results =
        for _ <- tasks do
          assert_receive {:reserved, _pid, result}, 5_000
          result
        end

      assert Enum.count(results, &match?({:ok, _lease}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, {:model_limited, :concurrency, nil}})) == 7
      assert {:ok, %{active: 1}} = ModelPermits.capacity("claude@work")
    after
      for task <- tasks, do: send(task.pid, :finish)
      for task <- tasks, do: Task.await(task, 5_000)
    end

    assert {:ok, %{active: 0}} = ModelPermits.capacity("claude@work")
  end

  test "activation waiting on a row lock cannot dispatch past its recorded deadline", %{
    binding: binding
  } do
    binding = %{binding | job: put_in(binding.job, ["limits", "turn_timeout_ms"], 1_000)}
    {:ok, lease} = ModelPermits.reserve(binding, fn -> {:ok, binding} end)
    permit = Repo.one!(ModelPermit.Query.held())
    parent = self()

    blocker =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.fetch!(ModelPermit.Query.by_id(permit.id) |> ModelPermit.Query.lock_for_update())
          send(parent, {:locked, backend_pid()})

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive {:locked, backend}, 5_000

    {:ok, upstream} =
      Task.start(fn ->
        result = ModelPermits.activate(lease, self())
        send(parent, {:activation_result, result})
      end)

    monitor = Process.monitor(upstream)
    lease_monitor = Process.monitor(lease)

    try do
      assert Ryker.TestHelpers.eventually(fn ->
               Repo.query!(
                 "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE $1::integer = ANY(pg_blocking_pids(pid)))",
                 [backend]
               ).rows == [[true]]
             end)

      # Crossing the persisted deadline while SQL is blocked is this test's behavior.
      assert Ryker.TestHelpers.eventually(fn ->
               DateTime.compare(Repo.now!(), permit.deadline) == :gt
             end)

      send(blocker.pid, :release)
      Task.await(blocker, 5_000)
      assert_receive {:DOWN, ^monitor, :process, ^upstream, :killed}, 5_000
      assert_receive {:DOWN, ^lease_monitor, :process, ^lease, :normal}, 5_000
      refute_received {:activation_result, {:ok, _remaining}}
      assert {:ok, %{active: 0}} = ModelPermits.capacity("claude@work")
    after
      send(blocker.pid, :release)
      if Process.alive?(blocker.pid), do: Task.shutdown(blocker, :brutal_kill)
      if Process.alive?(upstream), do: Process.exit(upstream, :kill)
      ModelPermits.cancel(lease)
    end
  end

  defp cleanup!(session) do
    Repo.delete_all(from(p in ModelPermit, where: p.job_ref == ^session.external_ref))
    Repo.delete_all(ModelBucket)
    Repo.delete_all(from(p in Placement, where: p.session_id == ^session.id))
    Repo.delete_all(from(s in Session, where: s.id == ^session.id))
    Repo.delete_all(from(e in Event, where: e.episode_id == ^session.episode_id))
    Repo.delete_all(from(e in Episode, where: e.id == ^session.episode_id))
    Repo.delete_all(from(c in Certificate, where: c.worker_id == "model-worker"))
    Repo.delete_all(from(w in Worker, where: w.id == "model-worker"))
    Repo.delete_all(from(e in Ryker.Credential.Event, where: e.name == "claude:work"))
    Repo.delete_all(from(c in Ryker.Credential, where: c.name == "claude:work"))
    :ok
  end
end
