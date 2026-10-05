defmodule Ryker.Settings.ConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Settings.{Edit, GitHubBinding, Installation, Repository}

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

  # The snapshot is fourteen reads, and outside a transaction each saw what
  # had committed before it: a fetch while a repository and its binding were
  # imported could return the binding without its repository, and the runtime
  # built from it ran without GitHub (2026-10-04 review). The import here
  # commits right after the fetch has read the repositories.
  test "a snapshot read during an import holds the whole import or none of it" do
    Sandbox.unboxed_run(Repo, fn ->
      clear!()
      handler = "settings-snapshot-#{System.unique_integer([:positive])}"

      try do
        {:ok, _snapshot} = Settings.initialize(@actor)
        reader = self()

        :ok =
          :telemetry.attach(
            handler,
            [:ryker, :repo, :query],
            fn _event, _measurements, metadata, _config ->
              if self() == reader and metadata.source == "repository_settings" and
                   is_nil(Process.get(:importer)) do
                importer = unboxed_task(&import!/0)
                Process.put(:importer, {importer, Task.yield(importer, 1_000)})
              end
            end,
            nil
          )

        snapshot = Settings.fetch!()
        :telemetry.detach(handler)

        assert {:ok, _imported} =
                 (case Process.get(:importer) do
                    {_importer, {:ok, imported}} -> imported
                    {importer, nil} -> Task.await(importer, 5_000)
                  end)

        repositories = MapSet.new(snapshot.repositories, & &1.ref)

        assert Enum.all?(
                 snapshot.github_bindings,
                 &MapSet.member?(repositories, &1.repository_ref)
               )

        assert Enum.map(Settings.fetch!().github_bindings, & &1.name) == ["imported"]
      after
        :telemetry.detach(handler)
        clear!()
      end
    end)
  end

  defp import! do
    Settings.atomically(fn ->
      with {:ok, _snapshot} <-
             Settings.put_repository(
               %{
                 ref: "imported",
                 display_name: "acme/imported",
                 github_repository: "acme/imported",
                 base_branch: "main"
               },
               :current,
               @actor
             ) do
        Settings.put_github_binding(
          %{
            name: "imported",
            repository_ref: "imported",
            installation_id: 10,
            repository_id: 20,
            ryker_actor_id: 30
          },
          :current,
          @actor
        )
      end
    end)
  end

  defp clear! do
    Repo.delete_all(GitHubBinding)
    Repo.delete_all(Repository)
    Repo.delete_all(Installation)
    Repo.delete_all(Edit)
  end
end
