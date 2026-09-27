defmodule Ryker.GitHub.OnboardingWorkerTest do
  use Ryker.DataCase, async: false

  alias Ryker.GitHub.OnboardingWorker
  alias Ryker.PollingWorker

  defmodule API do
    def pin(_binding, _repository), do: {:error, :not_used}
    def scan(_binding, _repository, _commit), do: {:error, :not_used}
    def publish(_binding, _repository, _commit, _content), do: {:error, :not_used}
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
end
