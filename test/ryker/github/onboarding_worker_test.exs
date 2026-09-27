defmodule Ryker.GitHub.OnboardingWorkerTest do
  use Ryker.DataCase, async: false

  alias Ryker.GitHub.OnboardingWorker
  alias Ryker.PollingWorker
  alias Ryker.Settings

  @actor "control-plane:local"

  defmodule API do
    def pin(_binding, _repository), do: {:error, :not_used}
  end

  defmodule PinningAPI do
    def pin(_binding, repository) do
      send(:onboarding_worker_test, {:pin, repository.github_repository})
      {:error, :remote_failed}
    end
  end

  # Every GitHub event nudges the onboarding worker to poll at once. Each nudge
  # also armed a timer beside the one already waiting, so every event since
  # 2026-09-20 left one more loop re-reading the whole settings snapshot every
  # two seconds for as long as Ryker ran. Found while merging the polling
  # loops, before it was measured in production.
  test "nudging the onboarding worker polls at once without adding a loop" do
    worker = start_supervised!({OnboardingWorker, api: API, interval_ms: 100})
    :ok = :sys.statistics(worker, true)

    for _event <- 1..5,
        do: assert(:ok = PollingWorker.poll_now(worker))

    Process.sleep(550)
    {:ok, statistics} = :sys.statistics(worker, :get)

    # Five polls for the five events, then one each interval: about ten. Six
    # loops side by side poll about thirty-five times in the same window.
    assert statistics[:messages_in] <= 12,
           "the onboarding worker polled #{statistics[:messages_in]} times in 550 ms"
  end

  # On 2026-09-27 an idle install committed about 125 transactions a second;
  # the onboarding worker read the whole settings snapshot every two seconds
  # with no repository to set up. It now sleeps until settings are saved, so
  # a repository someone adds, or retries, has to wake it.
  test "a repository whose setup is asked for while the worker is idle starts at once" do
    Process.register(self(), :onboarding_worker_test)
    {:ok, snapshot} = Settings.initialize(@actor)
    snapshot = put_repository!(snapshot, :ready)

    {:ok, snapshot} =
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

    worker =
      start_supervised!(
        {OnboardingWorker, api: PinningAPI, idle_interval_ms: 60_000, interval_ms: 60_000}
      )

    # Its first poll found nothing to set up, and its next timer is a minute away.
    _state = :sys.get_state(worker)

    put_repository!(snapshot, :pending)
    assert_receive {:pin, "acme/repo"}, 500
  end

  defp put_repository!(snapshot, onboarding_state) do
    {:ok, snapshot} =
      Settings.put_repository(
        %{
          ref: "repo",
          display_name: "acme/repo",
          github_repository: "acme/repo",
          base_branch: "main",
          onboarding_state: onboarding_state
        },
        snapshot.installation.revision,
        @actor
      )

    snapshot
  end
end
