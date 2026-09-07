defmodule Responder.Publication.ExecutorCleanupTest do
  use ExUnit.Case, async: true

  alias Responder.Publication.{Executor, FollowupExecutor}

  defmodule HeldAPI do
    def get_session(observer, _session_id), do: hold(observer)
    def get_publication_status(observer, _repository, _number), do: hold(observer)
    def get_review_patch(_, _, _, _), do: {:error, :not_used}
    def run_review(_, _, _, _), do: {:error, :not_used}

    defp hold(observer) do
      send(observer, {:held_callback, self()})

      receive do
        :finish_callback -> {:error, :callback_finished}
      end
    end
  end

  defmodule RaisingCustody do
    def renew(_, _, _), do: unavailable()
    def renew_poll(_, _, _), do: unavailable()
    def renew_delivery(_, _, _), do: unavailable()
    def confirm_delivery(_, _, _), do: {:error, :not_used}
    def delivery_request(_), do: {:error, :not_used}
    def advance_review_generation(_, _, _), do: {:error, :not_used}
    def freeze_review_revision(_, _, _), do: {:error, :not_used}
    def store_publication(_, _, _), do: {:error, :not_used}
    def store_review(_, _, _, _, _), do: {:error, :not_used}
    def admit_wakeup(_, _), do: {:error, :not_used}
    def reconcile_verification(_, _, _), do: {:error, :not_used}
    def store_poll(_, _, _, _), do: {:error, :not_used}

    defp unavailable, do: raise(DBConnection.ConnectionError, "held lease renewal unavailable")
  end

  defmodule QueuedResultCustody do
    def renew(_, _, _), do: raise_after_result()
    def renew_poll(_, _, _), do: raise_after_result()
    defdelegate renew_delivery(ref, lease, seconds), to: RaisingCustody
    defdelegate confirm_delivery(ref, lease, receipt), to: RaisingCustody
    defdelegate delivery_request(event), to: RaisingCustody
    defdelegate advance_review_generation(ref, lease, generation), to: RaisingCustody
    defdelegate freeze_review_revision(ref, lease, revision), to: RaisingCustody
    defdelegate store_publication(ref, lease, receipt), to: RaisingCustody
    defdelegate store_review(ref, lease, generation, dossier, patch), to: RaisingCustody
    defdelegate admit_wakeup(ref, lease), to: RaisingCustody
    defdelegate reconcile_verification(ref, lease, interval), to: RaisingCustody
    defdelegate store_poll(ref, lease, status, interval), to: RaisingCustody

    defp raise_after_result do
      callback = receive do: ({:held_callback, pid} -> pid)
      monitor = Process.monitor(callback)
      send(callback, :finish_callback)
      receive do: ({:DOWN, ^monitor, :process, ^callback, _reason} -> :ok)

      # DOWN follows the callback's result signal. Both are now queued while
      # renewal still owns the caller, independently of scheduler timing.
      send(self(), {:held_callback, callback})
      RaisingCustody.renew(nil, nil, nil)
    end
  end

  defmodule Publisher do
    def publish(_, _), do: {:error, :not_used}
  end

  # The pool-outage guard now keeps pollers alive. A child left behind by a
  # raised renewal can still act and send unmatched messages to that survivor,
  # defeating the recovery fix. This is host fault injection, not model output.
  test "a publication callback is reaped before raised renewal reaches its surviving caller" do
    options =
      options() ++ [publisher: Publisher, publisher_binding: nil]

    assert_callback_reaped(fn -> Executor.run(publication_claim(), options) end)
  end

  test "a followup callback is reaped before raised renewal reaches its surviving caller" do
    assert_callback_reaped(fn -> FollowupExecutor.run_poll(followup_claim(), options()) end)
  end

  test "a publication result queued during raised renewal is drained without unrelated messages" do
    options =
      options(custody: QueuedResultCustody) ++ [publisher: Publisher, publisher_binding: nil]

    assert_callback_reaped(fn -> Executor.run(publication_claim(), options) end)
  end

  test "a followup result queued during raised renewal is drained without unrelated messages" do
    assert_callback_reaped(fn ->
      FollowupExecutor.run_poll(followup_claim(), options(custody: QueuedResultCustody))
    end)
  end

  defp assert_callback_reaped(operation) do
    monitors = Process.info(self(), :monitors)
    send(self(), {make_ref(), :unrelated_result})
    send(self(), {:DOWN, make_ref(), :process, self(), :unrelated_exit})
    messages = Process.info(self(), :messages)

    assert_raise DBConnection.ConnectionError, "held lease renewal unavailable", operation
    assert_receive {:held_callback, callback}

    try do
      refute Process.alive?(callback), "raised renewal left the leased callback running"
      assert Process.info(self(), :monitors) == monitors
      assert Process.info(self(), :messages) == messages
    after
      # Keep the intentionally failing pre-fix test from leaking its held child.
      Process.exit(callback, :kill)
    end
  end

  defp publication_claim do
    %{
      lease_ref: "publication-lease:cleanup",
      publication: %{ref: "publication:cleanup", status: :review_pending},
      session: %{coop_session_id: "session:cleanup"}
    }
  end

  defp followup_claim do
    %{
      lease_ref: "followup-lease:cleanup",
      followup: %{verification_event_ref: nil, verified_at: nil},
      publication: %{
        ref: "publication:cleanup",
        github_repository: "acme/responder",
        pull_request_number: 91
      }
    }
  end

  defp options(overrides \\ []) do
    [
      adapters: %{"slack" => :unused},
      api: HeldAPI,
      client: self(),
      custody: RaisingCustody,
      lease_seconds: 1
    ]
    |> Keyword.merge(overrides)
  end
end
