defmodule Ryker.Learning.RetentionTest do
  use Ryker.DataCase, async: false
  alias Ryker.Fixtures.Learning, as: Fixtures
  alias Ryker.Learning.FleetSession
  alias Ryker.Retention.{Custody, Dispatcher}
  alias Ryker.State.Learning

  test "terminal learning sessions clean up through the learning execution client" do
    # The internal component runs Work through the fleet but learning directly. Cleanup sent
    # learning sessions to the fleet, where no worker owned that policy, and left them stuck.
    {run, _session} = prepared!()

    run
    |> Ecto.Changeset.change(
      remote_stopped_at: DateTime.utc_now(),
      stop_receipt: %{"kind" => "terminal_turn", "state" => "completed"}
    )
    |> Repo.update!()

    assert {:ok, {:executed, %{phase: :routed}}} =
             Dispatcher.run_once(
               api: __MODULE__.WorkAPI,
               client: {:work, self()},
               learning_api: __MODULE__.LearningAPI,
               learning_client: {:learning, self()},
               closed_session_grace_seconds: 0,
               executor: __MODULE__.RoutingExecutor,
               lease_seconds: 60,
               max_attempts: 8,
               retry_base_seconds: 1,
               retry_max_seconds: 60,
               worker_ref: "cleanup:learning-routing"
             )

    assert_receive {:cleanup_adapter, __MODULE__.LearningAPI, {:learning, _pid}}
    refute_receive {:cleanup_adapter, __MODULE__.WorkAPI, {:work, _pid}}
  end

  test "cleanup cannot claim a learning session before its remote turn is proven stopped" do
    {run, session} = prepared!()
    assert {:ok, nil} = Custody.claim_next("cleanup", 60)
    # Constructed custody input; stop-proof validation belongs to Learning tests.
    run
    |> Ecto.Changeset.change(
      remote_stopped_at: DateTime.utc_now(),
      stop_receipt: %{"kind" => "terminal_turn", "state" => "completed"}
    )
    |> Repo.update!()

    assert {:ok, claim} = Custody.claim_next("cleanup", 60)
    assert claim.session.id == session.id
    assert {:ok, nil} = Custody.claim_next("other-cleanup", 60)
    assert {:error, :retention_lease_lost} = Custody.freeze_close_revision(session.id, "lost", 1)
    assert {:ok, _} = Custody.freeze_close_revision(session.id, claim.lease_ref, 1)
    assert {:ok, _} = Custody.mark_closed(session.id, claim.lease_ref, 0)
    assert {:ok, claim} = Custody.claim_next("cleanup", 60)
    assert claim.session.cleanup_status == :plan_pending

    assert {:ok, discarded} =
             Custody.settle_remote_discarded(session.id, claim.lease_ref, session.coop_session_id)

    assert discarded.cleanup_status == :discarded
    assert discarded.cleanup_receipt["kind"] == "already_discarded"
  end

  test "an unbound learning owner is reclaimable only after exact absence was established" do
    {run, session} = prepared!(false)
    assert {:ok, nil} = Custody.claim_next("cleanup", 60)

    run
    |> Ecto.Changeset.change(
      remote_stopped_at: DateTime.utc_now(),
      stop_receipt: %{"kind" => "fenced_absence"}
    )
    |> Repo.update!()

    assert {:ok, claim} = Custody.claim_next("cleanup", 60)
    assert {:ok, discarded} = Custody.settle_absent(session.id, claim.lease_ref)
    assert discarded.cleanup_receipt["kind"] == "never_bound"
  end

  defp prepared!(bind \\ true) do
    assert {:ok, run} =
             Learning.prepare(Enum.map(Fixtures.inputs!(), & &1.id), %{
               policy: "recorded-read-only-policy",
               policy_digest: String.duplicate("a", 64)
             })

    assert {:ok, session} = FleetSession.ensure(run)

    if bind do
      assert {:ok, session} = FleetSession.bind(run, "host-contract-remote")
      {run, session}
    else
      {run, session}
    end
  end

  defmodule WorkAPI do
    @moduledoc false
  end

  defmodule LearningAPI do
    @moduledoc false
  end

  defmodule RoutingExecutor do
    @moduledoc false

    def run(_claim, options) do
      client = Keyword.fetch!(options, :client)
      {_kind, test_pid} = client
      send(test_pid, {:cleanup_adapter, Keyword.fetch!(options, :api), client})
      {:ok, %{phase: :routed}}
    end
  end
end
