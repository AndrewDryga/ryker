defmodule Ryker.GitHub.OnboardingTest do
  use Ryker.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ryker.GitHub.{Onboarding, OnboardingWorker}
  alias Ryker.{Repo, Settings}

  @actor "control-plane:local"
  @commit String.duplicate("a", 40)

  defmodule API do
    def pin(binding, repository) do
      send(self(), {:pin, binding.name, repository.github_repository})
      {:ok, String.duplicate("a", 40)}
    end

    def scan(binding, repository, commit) do
      send(self(), {:scan, binding.name, repository.github_repository, commit})
      {:ok, %{content: "# RYKER.md\n", status: :proposed}}
    end

    def publish(binding, repository, commit, content) do
      send(self(), {:publish, binding.name, repository.github_repository, commit, content})
      {:ok, %{url: "https://github.com/acme/repo/pull/7"}}
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

    def scan(_binding, _repository, _commit), do: flunk("must not scan")
    def publish(_binding, _repository, _commit, _content), do: flunk("must not publish")
  end

  defmodule ExistingAPI do
    def pin(_binding, _repository), do: {:ok, String.duplicate("a", 40)}

    def scan(_binding, _repository, _commit),
      do: {:ok, %{content: "# Human repository knowledge\n", status: :accepted}}

    def publish(_binding, _repository, _commit, _content), do: flunk("must not publish")
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

  test "pins, scans and publishes one resumable repository knowledge proposal" do
    assert {:ok, :pull_request_opened} = Onboarding.run("repo", api: API)
    assert_receive {:pin, "repo", "acme/repo"}
    assert_receive {:scan, "repo", "acme/repo", @commit}
    assert_receive {:publish, "repo", "acme/repo", @commit, "# RYKER.md\n"}

    repository = Enum.find(Settings.fetch!().repositories, &(&1.ref == "repo"))
    assert repository.onboarding_state == :ready
    assert repository.source_commit == @commit
    assert repository.knowledge_pull_request_url == "https://github.com/acme/repo/pull/7"
    assert repository.knowledge_content == "# RYKER.md\n"
    assert repository.knowledge_status == :proposed
    assert repository.knowledge_source_commit == @commit

    assert repository.knowledge_sha256 ==
             :crypto.hash(:sha256, "# RYKER.md\n") |> Base.encode16(case: :lower)

    assert repository.onboarding_error == nil
  end

  test "an existing human knowledge file is kept without opening a pull request" do
    assert {:ok, :already_present} = Onboarding.run("repo", api: ExistingAPI)
    repository = Enum.find(Settings.fetch!().repositories, &(&1.ref == "repo"))
    assert repository.onboarding_state == :ready
    assert repository.knowledge_pull_request_url == nil
    assert repository.knowledge_status == :accepted
    assert repository.knowledge_content == "# Human repository knowledge\n"
  end
end
