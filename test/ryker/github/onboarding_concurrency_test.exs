defmodule Ryker.GitHub.OnboardingConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.GitHub.Onboarding
  alias Ryker.{Repo, Settings}
  alias Ryker.RepositoryKnowledge.Entry
  alias Ryker.Settings.{Edit, GitHubBinding, Installation, Repository}

  @actor "control-plane:local"

  defmodule API do
    def pin(_binding, _repository), do: {:ok, String.duplicate("a", 40)}
  end

  # A setup step read the settings, then saved at the revision it had read. A
  # save landing in between, from a person or another worker, moved the
  # revision on, and the conflict blocked the repository with "Repository
  # setup could not finish" over someone else's change (2026-10-04 review).
  test "a setup step that meets another settings save is saved, not blocked" do
    Sandbox.unboxed_run(Repo, fn ->
      clear!()
      test = self()

      try do
        add_repository!()

        saver =
          unboxed_task(fn ->
            Repo.transaction(fn ->
              {:ok, _snapshot} =
                Settings.save_retention(%{audit_data_seconds: 31 * 86_400}, :current, @actor)

              send(test, {:saving, backend_pid()})
              receive do: (:commit -> :ok)
            end)
          end)

        assert_receive {:saving, saver_backend}, 5_000

        setup =
          unboxed_task(fn ->
            send(test, {:setting_up, backend_pid()})
            Onboarding.run("repo", api: API)
          end)

        assert_receive {:setting_up, setup_backend}, 5_000
        await_blocked_by(setup_backend, saver_backend)
        send(saver.pid, :commit)
        assert {:ok, _committed} = Task.await(saver)

        assert Task.await(setup) == {:ok, :ready}
        repository = Enum.find(Settings.fetch!().repositories, &(&1.ref == "repo"))
        assert repository.onboarding_state == :ready
        assert repository.onboarding_error == nil
      after
        clear!()
      end
    end)
  end

  defp add_repository! do
    {:ok, snapshot} = Settings.initialize(@actor)

    {:ok, snapshot} =
      Settings.put_repository(
        %{
          ref: "repo",
          display_name: "acme/repo",
          github_repository: "acme/repo",
          base_branch: "main"
        },
        snapshot.installation.revision,
        @actor
      )

    {:ok, _snapshot} =
      Settings.put_github_binding(
        %{
          name: "repo",
          repository_ref: "repo",
          installation_id: 10,
          repository_id: 20,
          ryker_actor_id: 30
        },
        snapshot.installation.revision,
        @actor
      )
  end

  defp clear! do
    Repo.delete_all(Entry)
    Repo.delete_all(GitHubBinding)
    Repo.delete_all(Repository)
    Repo.delete_all(Installation)
    Repo.delete_all(Edit)
  end
end
