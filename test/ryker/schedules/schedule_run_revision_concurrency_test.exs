defmodule Ryker.Schedules.ScheduleRunRevisionConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Fixtures.StatusConfirmations
  alias Ryker.Operator
  alias Ryker.Repo
  alias Ryker.Schedules

  # A pre-lock read cannot authorize running the replacement an editor commits
  # while dispatch waits. Both operator entry points used the new definition.
  for surface <- [:console, :slack] do
    test "a #{surface} Run now waiting on an edit cannot dispatch the replacement" do
      Sandbox.unboxed_run(Repo, fn ->
        context = StatusConfirmations.current!(:schedule, :active)
        action_ref = "interaction:locked-run:#{Ecto.UUID.generate()}"
        parent = self()

        try do
          editor =
            unboxed_task(fn ->
              Repo.transaction(fn ->
                query =
                  context.entity.ref
                  |> Schedules.Schedule.Query.by_ref()
                  |> Schedules.Schedule.Query.lock_for_update()

                true = Repo.exists?(query)
                send(parent, {:editor_locked, backend_pid()})
                receive do: (:replace -> :ok)
                StatusConfirmations.edit!(context)
              end)
            end)

          try do
            assert_receive {:editor_locked, blocking}, 5_000

            runner =
              unboxed_task(fn ->
                send(parent, {:run_started, backend_pid()})
                run_now(unquote(surface), context, action_ref)
              end)

            try do
              assert_receive {:run_started, backend}, 5_000
              await_blocked_by(backend, blocking)
              send(editor.pid, :replace)
              assert {:ok, edited} = Task.await(editor, 5_000)
              result = Task.await(runner, 5_000)

              assert Repo.all(Schedules.ScheduleOccurrence.Query.running(context.entity.id)) == []
              refute Repo.exists?(Operator.Action.Query.by_action_ref(action_ref))
              assert StatusConfirmations.fetch!(context) == edited
              assert result == {:error, :schedule_revision_stale}
            after
              stop_tasks([runner])
            end
          after
            send(editor.pid, :replace)
            stop_tasks([editor])
          end
        after
          Repo.delete_all(Operator.Action.Query.by_action_ref(action_ref))
          StatusConfirmations.cleanup!(context)
        end
      end)
    end
  end

  defp run_now(:console, context, action_ref) do
    Schedules.run_now_for_operator(
      context.entity.ref,
      context.entity.revision,
      "control-plane:local",
      action_ref,
      &policy/1
    )
  end

  defp run_now(:slack, context, action_ref) do
    ["slack", workspace, _channel] = String.split(context.source.conversation_ref, ":")
    scope = %{conversation_prefix: "slack:#{workspace}:", transport: "slack"}

    Schedules.run_now(
      context.entity.ref,
      context.entity.revision,
      "slack:user:U123",
      action_ref,
      scope,
      &policy/1
    )
  end

  defp policy(_schedule),
    do: {:ok, %{digest: String.duplicate("c", 64), name: "scheduled-read"}}
end
