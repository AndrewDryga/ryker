defmodule Ryker.Publication.FollowupWorkerTest do
  use Ryker.DataCase, async: false

  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.Publication.{FollowupWorker, Followups}

  defmodule RecordingExecutor do
    def run_poll(claim, options) do
      send(Keyword.fetch!(options, :test_pid), {:followup_polled, claim.publication.ref})
      {:ok, %{phase: :poll}}
    end

    def run_delivery(claim, options) do
      send(Keyword.fetch!(options, :test_pid), {:followup_delivered, claim.event.ref})
      {:ok, %{phase: :delivery}}
    end
  end

  # On 2026-09-27 an idle install committed about 125 transactions a second,
  # the follow-up worker among the pollers reading every 250 ms. It now sleeps
  # until a publication is announced, so a pull request that is published has
  # to wake it for its first check.
  test "a pull request published while follow-ups are idle is checked at once" do
    worker = start_supervised!({FollowupWorker, sleeping_options()})
    # Its first poll found nothing, and its next timer is a minute away.
    _state = :sys.get_state(worker)

    %{publication: %{ref: ref}} = PublicationFixture.published!("followup-worker-woken")
    assert_receive {:followup_polled, ^ref}, 500
  end

  # A published pull request is checked every two minutes, and nothing but
  # the clock says a check is due: a worker sleeping its safety-net interval
  # would check each one up to ten seconds late.
  test "a follow-up whose check falls due is polled then, not at the safety-net interval" do
    %{publication: %{ref: ref}} = PublicationFixture.published!("followup-worker-due")
    {:ok, claim} = Followups.claim_poll("followup:earlier", 60)
    {:ok, _deferred} = Followups.defer_poll(ref, claim.lease_ref, 1, :github_unavailable)

    start_supervised!({FollowupWorker, sleeping_options()})

    refute_receive {:followup_polled, ^ref}, 500
    assert_receive {:followup_polled, ^ref}, 1_500
  end

  defp sleeping_options do
    [
      dispatcher_options: [
        executor: RecordingExecutor,
        executor_options: [test_pid: self()],
        lease_seconds: 60,
        worker_ref: "publication-followup:test"
      ],
      idle_interval_ms: 60_000,
      poll_interval_ms: 60_000
    ]
  end
end
