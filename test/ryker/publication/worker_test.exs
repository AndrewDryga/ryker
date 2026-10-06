defmodule Ryker.Publication.WorkerTest do
  use Ryker.DataCase, async: false
  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.Publication.{Custody, Worker}

  defmodule RecordingExecutor do
    def run(claim, options) do
      send(Keyword.fetch!(options, :test_pid), {:publication_claimed, claim.publication.ref})
      {:ok, %{}}
    end
  end

  # On 2026-09-27 an idle install committed about 125 transactions a second;
  # the two publication slots polled every 250 ms and read
  # episode_publications 28 times a second with nothing to publish. A slot now
  # sleeps until a publication or its request is announced, so a review
  # someone asks for has to wake it.
  test "a review requested while the pool is idle starts at once, not at the next timer" do
    worker = start_supervised!({Worker, sleeping_options()})
    # Its first poll found nothing, and its next timer is a minute away.
    _state = :sys.get_state(worker)

    %{publication: %{ref: ref}} = PublicationFixture.review_requested!("worker-woken")
    assert_receive {:publication_claimed, ^ref}, 500
  end

  # A failed review or publish step is retried after a backoff, and only the
  # clock says when: a slot sleeping its whole safety-net interval would retry
  # up to ten seconds late.
  test "a publication whose retry falls due is taken then, not at the safety-net interval" do
    %{publication: %{ref: ref}} = PublicationFixture.review_requested!("worker-due")
    {:ok, claim} = Custody.claim_next("publication:earlier", 60)
    {:ok, _deferred} = Custody.defer(ref, claim.lease_ref, 1, "coop_unavailable", "retry")

    start_supervised!({Worker, sleeping_options()})

    refute_receive {:publication_claimed, ^ref}, 500
    assert_receive {:publication_claimed, ^ref}, 1_500
  end

  defp sleeping_options do
    [
      dispatcher_options: [
        executor: RecordingExecutor,
        executor_options: [test_pid: self()],
        lease_seconds: 60,
        worker_ref: "publication-worker:test"
      ],
      idle_interval_ms: 60_000,
      poll_interval_ms: 60_000
    ]
  end
end
