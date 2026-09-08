defmodule Responder.Learning.RetentionTest do
  use Responder.DataCase, async: false
  alias Responder.Fixtures.Learning, as: Fixtures
  alias Responder.Learning.FleetSession
  alias Responder.Retention.Custody
  alias Responder.State.Learning

  test "cleanup cannot claim a learning session before its remote turn is proven stopped" do
    {run, session} = prepared!()
    assert {:ok, nil} = Custody.claim_next("cleanup", 60, 0)
    # Constructed custody input; stop-proof validation belongs to Learning tests.
    run
    |> Ecto.Changeset.change(
      remote_stopped_at: DateTime.utc_now(),
      stop_receipt: %{"kind" => "terminal_turn", "state" => "completed"}
    )
    |> Repo.update!()

    assert {:ok, claim} = Custody.claim_next("cleanup", 60, 0)
    assert claim.session.id == session.id
    assert {:ok, nil} = Custody.claim_next("other-cleanup", 60, 0)
    assert {:error, :retention_lease_lost} = Custody.freeze_close_revision(session.id, "lost", 1)
    assert {:ok, _} = Custody.freeze_close_revision(session.id, claim.lease_ref, 1)
    assert {:ok, _} = Custody.mark_closed(session.id, claim.lease_ref, 0)
    assert {:ok, claim} = Custody.claim_next("cleanup", 60, 0)
    assert claim.session.cleanup_status == :plan_pending

    assert {:ok, discarded} =
             Custody.settle_remote_discarded(session.id, claim.lease_ref, session.coop_session_id)

    assert discarded.cleanup_status == :discarded
    assert discarded.cleanup_receipt["kind"] == "already_discarded"
  end

  test "an unbound learning owner is reclaimable only after exact absence was established" do
    {run, session} = prepared!(false)
    assert {:ok, nil} = Custody.claim_next("cleanup", 60, 0)

    run
    |> Ecto.Changeset.change(
      remote_stopped_at: DateTime.utc_now(),
      stop_receipt: %{"kind" => "fenced_absence"}
    )
    |> Repo.update!()

    assert {:ok, claim} = Custody.claim_next("cleanup", 60, 0)
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
end
