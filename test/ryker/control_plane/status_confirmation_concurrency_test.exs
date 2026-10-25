defmodule Ryker.ControlPlane.StatusConfirmationConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Behaviors
  alias Ryker.Fixtures.StatusConfirmations
  alias Ryker.Memories
  alias Ryker.Repo
  alias Ryker.Schedules

  # A revision read before POST or before waiting for a database lock cannot
  # authorize changing the definition an editor commits while that call waits.
  for kind <- [:guidance, :schedule] do
    test "a #{kind} edited while Delete waits retains its newer definition" do
      Sandbox.unboxed_run(Repo, fn ->
        context = StatusConfirmations.current!(unquote(kind), :active)
        observer = self()

        try do
          editor =
            unboxed_task(fn ->
              Repo.transaction(fn ->
                lock_entity!(context)
                send(observer, {:editor_locked, backend_pid()})
                receive do: (:replace -> :ok)
                StatusConfirmations.edit!(context)
                :ok
              end)
            end)

          try do
            assert_receive {:editor_locked, blocking}, 5_000

            changer =
              unboxed_task(fn ->
                send(observer, {:change_started, backend_pid()})
                delete(context)
              end)

            try do
              assert_receive {:change_started, backend}, 5_000
              await_blocked_by(backend, blocking)
              send(editor.pid, :replace)
              assert Task.await(editor, 5_000) == {:ok, :ok}
              result = Task.await(changer, 5_000)
              stored = StatusConfirmations.fetch!(context)

              assert stored.status == :active
              assert stored.revision == context.entity.revision + 1
              assert result == {:error, stale_reason(context.kind)}
            after
              stop_tasks([changer])
            end
          after
            send(editor.pid, :replace)
            stop_tasks([editor])
          end
        after
          StatusConfirmations.cleanup!(context)
        end
      end)
    end
  end

  defp lock_entity!(%{kind: :schedule, entity: schedule}) do
    query =
      schedule.ref
      |> Schedules.Schedule.Query.by_ref()
      |> Schedules.Schedule.Query.lock_for_update()

    true = Repo.exists?(query)
    :ok
  end

  defp lock_entity!(_context), do: Memories.lock_reviews_in_transaction()

  defp delete(%{kind: :schedule, entity: schedule}),
    do: Schedules.set_status(schedule.ref, :deleted, schedule.revision)

  defp delete(context),
    do: Behaviors.set_status(context.entity.ref, :deleted, context.entity.revision)

  defp stale_reason(:schedule), do: :schedule_revision_stale
  defp stale_reason(_kind), do: :behavior_revision_stale
end
