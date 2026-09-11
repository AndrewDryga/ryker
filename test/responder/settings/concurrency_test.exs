defmodule Responder.Settings.ConcurrencyTest do
  use Responder.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Responder.Repo
  alias Responder.Settings
  alias Responder.Settings.{Edit, Installation}

  @actor "control-plane:local"

  test "simultaneous first saves create exactly one installation identity" do
    # Two setup submissions racing through separate connections must agree on
    # one host_ref: a second identity would split lease owners and global facts.
    Sandbox.unboxed_run(Repo, fn ->
      clear!()

      try do
        results =
          1..4
          |> Enum.map(fn _ -> unboxed_task(fn -> Settings.initialize(@actor) end) end)
          |> Task.await_many(30_000)

        assert Enum.all?(results, &match?({:ok, _}, &1))
        host_refs = Enum.map(results, fn {:ok, snapshot} -> snapshot.installation.host_ref end)
        assert length(Enum.uniq(host_refs)) == 1
        assert Repo.aggregate(Installation, :count) == 1
        assert Repo.aggregate(Edit, :count) == 1
      after
        clear!()
      end
    end)
  end

  test "simultaneous edits at the same revision admit exactly one winner" do
    Sandbox.unboxed_run(Repo, fn ->
      clear!()

      try do
        {:ok, _} = Settings.initialize(@actor)

        results =
          1..4
          |> Enum.map(fn index ->
            unboxed_task(fn ->
              Settings.save_retention(%{audit_data_seconds: (30 + index) * 86_400}, 1, @actor)
            end)
          end)
          |> Task.await_many(30_000)

        assert Enum.count(results, &match?({:ok, _}, &1)) == 1
        assert Enum.count(results, &match?({:error, {:settings_conflict, _}}, &1)) == 3
        assert Repo.aggregate(Edit, :count) == 2
        assert Repo.one!(Installation).revision == 2
      after
        clear!()
      end
    end)
  end

  defp clear! do
    Repo.delete_all(Installation)
    Repo.delete_all(Edit)
  end
end
