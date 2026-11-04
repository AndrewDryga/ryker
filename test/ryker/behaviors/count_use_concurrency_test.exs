defmodule Ryker.Behaviors.CountUseConcurrencyTest do
  # A count waited on the share locks turns hold on the rules they read, for as long as a turn's
  # snapshot takes (2026-11-03). The count only feeds the review of rules nobody uses, and a rule
  # a turn holds is in use.
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Behaviors
  alias Ryker.Behaviors.Behavior
  alias Ryker.Fixtures.Personalization
  alias Ryker.Repo

  test "a rule a turn holds misses one count rather than making the next turn wait" do
    Sandbox.unboxed_run(Repo, fn ->
      {claim, rule} = Personalization.preference_context!()
      parent = self()
      counted = Repo.get!(Behavior, rule.id).use_count

      holder =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            rule.id |> Behavior.Query.by_id() |> Behavior.Query.lock_for_share() |> Repo.one!()
            send(parent, :held)
            receive do: (:release -> :ok)
          end)
        end)

      try do
        assert_receive :held, 5_000
        assert Behaviors.count_use([rule.id]) == :ok
        assert Repo.get!(Behavior, rule.id).use_count == counted

        send(holder.pid, :release)
        assert Task.await(holder, 5_000) == {:ok, :ok}
        assert Behaviors.count_use([rule.id]) == :ok
        assert Repo.get!(Behavior, rule.id).use_count == counted + 1
      after
        send(holder.pid, :release)
        stop_tasks([holder])
        Personalization.cleanup!(claim)
      end
    end)
  end
end
