defmodule Ryker.BundledCoopConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.BundledCoop
  alias Ryker.CoopFleet.EnrollmentToken
  alias Ryker.Repo

  test "concurrent reconciliations publish one token and preserve the same token on retry" do
    Sandbox.unboxed_run(Repo, fn ->
      worker = "bundled-#{Ecto.UUID.generate()}"
      shared = Path.join(System.tmp_dir!(), worker)
      parent = self()

      previous =
        for {name, value} <- [
              {"RYKER_BUNDLED_COOP_SHARED", shared},
              {"RYKER_BUNDLED_COOP_WORKER_ID", worker},
              {"RYKER_BUNDLED_COOP_WORKSPACE", worker}
            ] do
          previous = System.get_env(name)
          System.put_env(name, value)
          {name, previous}
        end

      holder =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
              "bundled-coop-enrollment:#{worker}"
            ])

            send(parent, {:holding, backend_pid()})
            receive do: (:release -> :ok)
          end)
        end)

      contenders =
        for index <- 1..2 do
          unboxed_task(fn ->
            send(parent, {:contender, index, backend_pid()})
            receive do: (:reconcile -> BundledCoop.ensure_enrollment_file!())
          end)
        end

      try do
        assert_receive {:holding, holder_backend}, 5_000

        for {contender, index} <- Enum.with_index(contenders, 1) do
          assert_receive {:contender, ^index, contender_backend}, 5_000
          send(contender.pid, :reconcile)
          assert await_blocked_by(contender_backend, holder_backend) == :ok
        end

        send(holder.pid, :release)
        assert Task.await(holder, 5_000) == {:ok, :ok}
        for contender <- contenders, do: assert(Task.await(contender, 5_000) == :ok)

        assert Repo.aggregate(from(t in EnrollmentToken, where: t.worker_id == ^worker), :count) ==
                 1

        path = Path.join(shared, "enrollment-token")
        original = File.read!(path)
        assert BundledCoop.ensure_enrollment_file!() == :ok
        assert File.read!(path) == original
      after
        stop_tasks([holder | contenders])
        Repo.delete_all(from(t in EnrollmentToken, where: t.worker_id == ^worker))
        File.rm_rf!(shared)

        for {name, value} <- previous do
          if value, do: System.put_env(name, value), else: System.delete_env(name)
        end
      end
    end)
  end
end
