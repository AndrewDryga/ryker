defmodule Ryker.GitHub.OnboardingTest do
  use Ryker.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ryker.GitHub.{Onboarding, OnboardingWorker}
  alias Ryker.{Repo, RepositoryKnowledge, Settings}

  @actor "control-plane:local"
  @commit String.duplicate("a", 40)

  defmodule API do
    def pin(binding, repository) do
      send(self(), {:pin, binding.name, repository.github_repository})
      {:ok, String.duplicate("a", 40)}
    end
  end

  # Breaks the settings read after the "cloning" transition was saved, so the
  # block that follows the failure cannot be saved.
  defmodule PoisoningAPI do
    def pin(_binding, _repository) do
      Ryker.Repo.query!(
        "ALTER TABLE installation_settings RENAME TO installation_settings_broken"
      )

      {:error, :remote_failed}
    end
  end

  defmodule CrashingPinAPI do
    def pin(_binding, _repository), do: raise(ArgumentError, "unexpected ref object")
  end

  # Removes the repository while its setup reads it, as Remove on the
  # Repositories page does.
  defmodule RemovedDuringSetupAPI do
    def pin(_binding, _repository) do
      {:ok, _removed} =
        Ryker.IntegrationSetup.remove_repository("repo", "control-plane:local",
          storage_root: System.tmp_dir!()
        )

      {:ok, String.duplicate("a", 40)}
    end
  end

  defmodule UnknownFailureAPI do
    def pin(_binding, _repository), do: {:error, {:github_status, 502}}
  end

  setup do
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

    :ok
  end

  # Every step of a setup saved the repository by its ref, so a step that
  # finished after Remove saved it again, holding nothing but its setup
  # state (2026-09-27).
  test "a repository removed while it is being set up stays removed" do
    log =
      capture_log(fn ->
        assert {:error, :repository_removed} = Onboarding.run("repo", api: RemovedDuringSetupAPI)
      end)

    snapshot = Settings.fetch!()
    assert snapshot.repositories == []
    assert snapshot.github_bindings == []
    refute log =~ "could not be marked blocked"
    refute log =~ "setup raised"
  end

  # A block that could not be saved was swallowed whole: the repository read
  # "cloning" forever, and nothing in the log said why.
  test "a repository whose setup cannot be marked blocked says so in the log" do
    log =
      capture_log(fn ->
        assert {:error, :remote_failed} = Onboarding.run("repo", api: PoisoningAPI)
      end)

    Repo.query!("ALTER TABLE installation_settings_broken RENAME TO installation_settings")
    assert log =~ "could not be marked blocked"
    assert log =~ "Postgrex.Error"
  end

  # The worker's choice of the next repository swallowed every error into
  # "nothing to do", so a database outage looked like an idle queue.
  test "the onboarding worker backs off a database error instead of hiding it" do
    Repo.query!("ALTER TABLE installation_settings RENAME TO installation_settings_broken")
    state = OnboardingWorker.options!(%{api: API, interval_ms: 100})

    log =
      capture_log(fn ->
        assert {:noreply, ^state} = OnboardingWorker.handle_info(:poll, state)
        assert_receive :poll, 1_500
      end)

    Repo.query!("ALTER TABLE installation_settings_broken RENAME TO installation_settings")
    assert log =~ "database polling unavailable"
    assert log =~ "github_onboarding"
  end

  # Found live 2026-09-27: five repositories stopped in setup on a sentence
  # that named nothing, and the log said nothing either.

  # Found live 2026-09-27: a scan that raised crashed the setup worker, which
  # restarted, took the next repository and crashed again, about twice a second
  # for an hour; every repository sat in "scanning" and nothing was logged.
  test "a setup step that raises stops that repository with a logged reason, not the worker" do
    log =
      capture_log(fn ->
        assert {:error, {:setup_crashed, ArgumentError}} =
                 Onboarding.run("repo", api: CrashingPinAPI)
      end)

    repository = Enum.find(Settings.fetch!().repositories, &(&1.ref == "repo"))
    assert repository.onboarding_state == :blocked
    assert repository.onboarding_error =~ "stopped on an unexpected error"
    assert log =~ "unexpected ref object"
  end

  test "a setup failure Ryker has no sentence for is logged with its reason" do
    log =
      capture_log(fn ->
        assert {:error, {:github_status, 502}} = Onboarding.run("repo", api: UnknownFailureAPI)
      end)

    assert log =~ "repository repo setup stopped"
    assert log =~ "github_status"
  end

  # Setup scanned the file list once and opened a pull request of what it
  # found (Andrew, 2026-09-27: "those are pretty weak summaries"). It now
  # pins the default branch head and hands RYKER.md to the knowledge lane,
  # whose first check is due at once: a model reads the repository there.
  test "setup pins the default branch head and hands RYKER.md to the knowledge lane" do
    assert {:ok, :ready} = Onboarding.run("repo", api: API)
    assert_receive {:pin, "repo", "acme/repo"}

    repository = Enum.find(Settings.fetch!().repositories, &(&1.ref == "repo"))
    assert repository.onboarding_state == :ready
    assert repository.source_commit == @commit
    assert repository.onboarding_error == nil

    entry = RepositoryKnowledge.entry("repo")
    assert entry.phase == :idle
    assert DateTime.compare(entry.next_check_at, Repo.now!()) != :gt
  end
end
