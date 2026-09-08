defmodule Responder.Learning.OperatorTest do
  use Responder.DataCase, async: false
  alias Responder.Fixtures.Learning, as: Fixtures
  alias Responder.Learning.{Batch, Batches, InputMembership, Operator}
  alias Responder.State.Learning

  @settings %{
    policy: "recorded-read-only-policy",
    policy_digest: String.duplicate("a", 64),
    quiet_seconds: 0,
    maximum_delay_seconds: 60,
    lease_seconds: 300,
    batch_size: 16
  }

  test "audited retry grants one extra start without resetting spent starts or duplicating the grant" do
    inputs!()

    for _ <- 1..3 do
      assert {:ok, claim} = Batches.claim("operator-test", @settings)
      assert {:ok, run} = Batches.prepare(claim)
      assert {:ok, _} = Batches.begin_execution(claim, run.id)
      reject_and_stop(run, claim)
      assert {:ok, _} = Batches.release(claim, :invalid_learning_result, 0)
    end

    [batch] = Repo.all(Batch)
    assert batch.status == :deferred
    assert batch.start_count == 3
    assert {:ok, receipt} = Operator.retry(batch.id, 0, "operator:andrew", "learning-retry:first")
    assert receipt.outcome["start_count"] == 3
    assert receipt.outcome["start_limit"] == 4

    assert {:ok, duplicate} =
             Operator.retry(batch.id, 0, "operator:andrew", "learning-retry:first")

    assert duplicate.status == :duplicate
    assert duplicate.outcome == receipt.outcome

    assert {:error, :learning_retry_conflict} =
             Operator.retry(batch.id, 0, "operator:andrew", "learning-retry:stale-form")

    assert Repo.aggregate(Responder.Operator.Action, :count) == 1

    assert {:ok, claim} = Batches.claim("operator-test", @settings)
    assert {:ok, run} = Batches.prepare(claim)
    assert run.generation == 4
    assert {:ok, _} = Batches.begin_execution(claim, run.id)
    assert Repo.get!(Batch, batch.id).start_count == 4
    reject_and_stop(run, claim)
    assert {:ok, terminal} = Batches.release(claim, :invalid_learning_result, 0)
    assert terminal.status == :deferred
    assert terminal.error_code == "learning_retry_exhausted"
    assert {:ok, :idle} = Batches.claim("operator-test", @settings)
  end

  test "operator retry cannot buy a second turn while remote custody is unresolved" do
    inputs!()
    assert {:ok, claim} = Batches.claim("operator-test", @settings)
    assert {:ok, run} = Batches.prepare(claim)
    assert {:ok, _} = Batches.begin_execution(claim, run.id)
    assert {:ok, _} = Batches.release(claim, :learning_remote_unresolved, 0)

    assert {:error, :learning_remote_outstanding} =
             Operator.retry(claim.batch.id, 0, "operator:andrew", "learning-retry:unsafe")

    assert Repo.aggregate(Responder.Operator.Action, :count) == 0
    assert Repo.get!(Batch, claim.batch.id).start_limit == 3
  end

  @tag :recovery
  test "withdrawal of every source rejects a grant before changing membership or recording success" do
    entries = inputs!()
    assert {:ok, claim} = Batches.claim("operator-test", @settings)
    assert {:ok, _} = Batches.finish(claim, :deferred, "learning_capacity_exceeded")

    Enum.each(entries, fn entry ->
      Repo.update!(
        Ecto.Changeset.change(entry,
          content: %{"retention" => "pruned"},
          operational_pruned_at: DateTime.utc_now()
        )
      )
    end)

    assert {:error, :learning_source_stale} =
             Operator.retry(claim.batch.id, 0, "operator:andrew", "learning-retry:withdrawn")

    assert Repo.aggregate(Responder.Operator.Action, :count) == 0
    assert Repo.get!(Batch, claim.batch.id).status == :deferred
    assert Repo.get!(Batch, claim.batch.id).start_limit == 3
  end

  for retired_before_retry <- [true, false] do
    @tag :recovery
    test "retry reopens only learnable siblings when invalid membership was already retired: #{retired_before_retry}" do
      # A source-unavailable member must neither block the surviving input's
      # explicit grant nor be resurrected by resetting every terminal reason.
      [invalid, survivor] = inputs!()
      assert {:ok, claim} = Batches.claim("mixed-source-retry", @settings)
      assert {:ok, _} = Batches.finish(claim, :deferred, "learning_capacity_exceeded")
      Repo.update!(Ecto.Changeset.change(invalid, operational_pruned_at: DateTime.utc_now()))

      if unquote(retired_before_retry) do
        invalid.id
        |> then(&Repo.get!(InputMembership, &1))
        |> Ecto.Changeset.change(terminal_reason: "source_unavailable")
        |> Repo.update!()
      end

      assert {:ok, receipt} =
               Operator.retry(claim.batch.id, 0, "operator:andrew", "learning-retry:survivor")

      assert receipt.outcome["start_count"] == 0
      assert receipt.outcome["start_limit"] == 1
      assert Repo.get!(InputMembership, invalid.id).terminal_reason == "source_unavailable"
      assert Repo.get!(InputMembership, survivor.id).terminal_reason == nil
      assert {:ok, reopened} = Batches.claim("retry-survivor", @settings)
      assert Enum.map(reopened.inputs, & &1.id) == [survivor.id]
      assert reopened.batch.id == claim.batch.id
      assert {:ok, run} = Batches.prepare(reopened)
      assert {:ok, _} = Batches.begin_execution(reopened, run.id)
      assert Repo.get!(Batch, claim.batch.id).start_count == 1
    end
  end

  test "retrying an early deferral permits one start, not the old unused allowance plus another" do
    inputs!()
    assert {:ok, claim} = Batches.claim("operator-test", @settings)
    assert {:ok, run} = Batches.prepare(claim)
    assert {:ok, _} = Batches.begin_execution(claim, run.id)
    reject_and_stop(run, claim)
    assert {:ok, _} = Batches.release(claim, :knowledge_target_unavailable, 0)

    assert {:ok, receipt} =
             Operator.retry(claim.batch.id, 0, "operator:andrew", "learning-retry:early")

    assert receipt.outcome["start_count"] == 1
    assert receipt.outcome["start_limit"] == 2
    assert receipt.outcome["budget_version"] == 1
    assert {:ok, claim} = Batches.claim("operator-test", @settings)
    assert {:ok, run} = Batches.prepare(claim)
    assert {:ok, _} = Batches.begin_execution(claim, run.id)
    reject_and_stop(run, claim)

    assert {:ok, %{status: :deferred, start_count: 2}} =
             Batches.release(claim, :invalid_learning_result, 0)
  end

  defp reject_and_stop(run, claim) do
    # Reuse the harvested invalid public response; this is transport custody
    # coverage, not an invented answer presented as model evaluation evidence.
    body =
      "testdata/learning/retained-output-contract-failure.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("public_responses")
      |> hd()
      |> Map.fetch!("text")

    assert {:error, :invalid_learning_result} = Fixtures.accept(run.id, body, %{})

    assert {:ok, _} =
             Learning.record_stop(
               run.id,
               %{
                 "id" => "host-contract-turn:#{run.id}",
                 "session_id" => "host-contract-session:#{run.id}",
                 "state" => "cancelled"
               },
               claim
             )
  end

  defp inputs! do
    entries = Fixtures.inputs!()
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    Repo.update_all(Responder.Ingress.Inbox.Entry, set: [inserted_at: now, updated_at: now])
    entries
  end
end
