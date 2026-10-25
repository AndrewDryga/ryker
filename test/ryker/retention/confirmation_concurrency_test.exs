defmodule Ryker.Retention.ConfirmationConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.ControlPlane.Actions
  alias Ryker.Fixtures.RetainedWork
  alias Ryker.Operator
  alias Ryker.Repo
  alias Ryker.Work

  # Confirming the earlier plan while its row is locked used to authorize the
  # replacement once that lock was released, including its uncommitted work.
  for kind <- [:dirty, :unmerged] do
    test "a #{kind} deletion waiting on a plan replacement keeps the newer plan" do
      Sandbox.unboxed_run(Repo, fn ->
        context = RetainedWork.current!(unquote(kind))
        parent = self()

        try do
          editor =
            unboxed_task(fn ->
              Repo.transaction(fn ->
                query =
                  context.session.id
                  |> Work.Session.Query.by_id()
                  |> Work.Session.Query.lock_for_update()

                true = Repo.exists?(query)
                send(parent, {:editor_locked, backend_pid()})
                receive do: (:replace -> :ok)
                RetainedWork.replace!(context)
              end)
            end)

          try do
            assert_receive {:editor_locked, blocking}, 5_000

            confirmer =
              unboxed_task(fn ->
                send(parent, {:confirmation_started, backend_pid()})
                discard(context)
              end)

            try do
              assert_receive {:confirmation_started, backend}, 5_000
              await_blocked_by(backend, blocking)
              send(editor.pid, :replace)
              assert {:ok, replacement} = Task.await(editor, 5_000)
              result = Task.await(confirmer, 5_000)
              stored = RetainedWork.fetch!(context)
              assert stored.cleanup_status == :retained
              assert stored == replacement

              refute Repo.exists?(
                       from(action in Operator.RetentionAction,
                         where: action.session_id == ^context.session.id
                       )
                     )

              assert result == {:error, :retention_discard_plan_stale}
            after
              stop_tasks([confirmer])
            end
          after
            send(editor.pid, :replace)
            stop_tasks([editor])
          end
        after
          RetainedWork.cleanup!(context)
        end
      end)
    end
  end

  defp discard(%{kind: :dirty} = context) do
    Actions.callbacks().discard_retention_changes.(
      context.session.external_ref,
      context.session.discard_plan_fingerprint,
      nil
    )
  end

  defp discard(context) do
    Actions.callbacks().discard_retention.(
      context.session.external_ref,
      context.session.discard_plan_fingerprint,
      nil
    )
  end
end
