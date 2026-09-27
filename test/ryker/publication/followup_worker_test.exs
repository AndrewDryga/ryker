defmodule Ryker.Publication.FollowupWorkerTest do
  use Ryker.DataCase, async: false

  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.Publication.{Followups, FollowupWorker}

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

  defmodule OpenPullRequest do
    def get_publication_status(%{status: status, test_pid: test_pid}, repository, number) do
      send(test_pid, {:status_requested, repository, number})
      {:ok, status}
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

  # An open pull request is checked every ten minutes, and nothing but the
  # clock says a check is due: a worker sleeping its safety-net interval would
  # check each one up to ten seconds late.
  test "a follow-up whose check falls due is polled then, not at the safety-net interval" do
    %{publication: %{ref: ref}} = PublicationFixture.published!("followup-worker-due")
    {:ok, claim} = Followups.claim_poll("followup:earlier", 60)
    {:ok, _deferred} = Followups.defer_poll(ref, claim.lease_ref, 1, :github_unavailable)

    start_supervised!({FollowupWorker, sleeping_options()})

    refute_receive {:followup_polled, ^ref}, 500
    assert_receive {:followup_polled, ^ref}, 1_500
  end

  # Where no GitHub webhook reaches Ryker, the ten-minute check is the only
  # thing that brings an open pull request back, and only the clock says it is
  # due. The worker learns when from a database aggregate that comes back
  # without a zone; reading one of those crashed every worker on 2026-09-27.
  test "after checking an open pull request the worker sleeps until its next check, not its safety net" do
    %{publication: publication} = PublicationFixture.published!("followup-worker-recheck")
    {:ok, state} = FollowupWorker.setup(checking_options(publication))

    # The first cycle checks the new pull request: open, checks pending.
    assert FollowupWorker.poll(state) == 0
    assert_received {:status_requested, "acme/ryker", 91}

    # Nothing else is due, so the worker sleeps until that check comes round.
    sleep_ms = FollowupWorker.poll(state)
    assert_in_delta sleep_ms, 600_000, 5_000, "the worker sleeps #{sleep_ms} ms"
  end

  defp checking_options(publication) do
    [
      dispatcher_options: [
        executor_options: [
          adapters: %{"slack" => :unused},
          api: OpenPullRequest,
          client: %{status: open_status(publication), test_pid: self()}
        ],
        lease_seconds: 60,
        worker_ref: "publication-followup:recheck"
      ],
      idle_interval_ms: 3_600_000,
      poll_interval_ms: 60_000
    ]
  end

  defp open_status(publication) do
    %{
      "base_ref" => "main",
      "checks_failed" => 0,
      "checks_passed" => 0,
      "checks_state" => "pending",
      "checks_total" => 2,
      "checks_url" => "#{publication.pull_request_url}/checks",
      "draft" => true,
      "head_ref" => String.replace_prefix(publication.branch_ref, "refs/heads/", ""),
      "head_sha" => publication.commit_sha,
      "merge_sha" => nil,
      "merged" => false,
      "merged_at" => nil,
      "number" => publication.pull_request_number,
      "state" => "open",
      "url" => publication.pull_request_url
    }
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
