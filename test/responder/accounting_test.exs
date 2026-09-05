defmodule Responder.AccountingTest do
  use Responder.DataCase, async: true
  import Ecto.Query
  alias Responder.Work.SubmissionBuilder

  alias Responder.{Accounting, Episodes, Repo}
  alias Responder.Accounting.Execution
  alias Responder.Fixtures.Episodes, as: Fixtures
  alias Responder.Work.Custody

  test "polling and missing telemetry cannot duplicate or erase an unsuccessful execution's spend" do
    claim = claim!()

    remote = %{
      "id" => "remote-cost-turn",
      "state" => "running",
      "usage" => %{
        "input_tokens" => 1_200,
        "cached_input_tokens" => 800,
        "output_tokens" => 300,
        "reasoning_tokens" => 25,
        "cost_recorded" => true,
        "cost_usd" => 0.0125
      }
    }

    target = %{"target" => "claude:opus/high@work"}
    assert :ok = Accounting.observe_work(claim, remote, target)
    assert :ok = Accounting.observe_work(claim, remote, target)
    assert :ok = Accounting.observe_work(claim, %{"id" => remote["id"], "state" => "failed"})
    row = Repo.one!(Execution)
    assert row.status == "failed"
    assert row.usage_input_tokens == 1_200
    assert row.usage_cost_recorded
    assert Decimal.equal?(row.usage_cost_usd, Decimal.new("0.0125"))
    assert row.execution_target == target["target"]
    assert row.measurement_error_code == nil
    assert Repo.aggregate(Execution, :count) == 1
    assert :ok = Accounting.observe_work(claim, remote, target)
    assert Repo.one!(Execution).status == "failed"
  end

  test "a retry generation preserves its predecessor and fences the expired claimant" do
    claim = claim!()

    assert {:ok, session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "remote-cost-session"
             )

    claim = %{claim | session: session}
    assert {:ok, submission} = SubmissionBuilder.build(claim)

    assert {:ok, frozen} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    claim = %{claim | turn: frozen}

    assert :ok =
             Accounting.observe_work(claim, %{
               "state" => "failed",
               "usage" => %{"input_tokens" => 1200}
             })

    assert {:ok, turn} =
             Custody.advance_turn_submit(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.turn.submit_generation
             )

    assert {:error, :accounting_lease_lost} =
             Accounting.observe_work(claim, %{"state" => "completed"})

    assert :ok =
             Accounting.observe_work(%{claim | turn: turn}, %{
               "state" => "cancelled",
               "usage" => %{"input_tokens" => 300}
             })

    rows = Repo.all(from(e in Execution, order_by: e.generation))
    assert Enum.map(rows, & &1.usage_input_tokens) == [1200, 300]
    assert Enum.map(rows, & &1.status) == ["failed", "cancelled"]
  end

  test "compact accounting survives source artifact removal and separates shadow execution" do
    claim = claim!()

    assert :ok =
             Accounting.observe_work(claim, %{
               "state" => "cancelled",
               "usage" => %{"input_tokens" => 12}
             })

    [row] = Repo.all(Execution)

    Repo.insert!(%{
      row
      | id: Ecto.UUID.generate(),
        source_id: Ecto.UUID.generate(),
        execution_mode: "shadow"
    })

    Repo.delete!(claim.turn)
    assert Repo.aggregate(Execution, :count) == 2
    assert Repo.aggregate(Accounting.Query.executions(nil), :count) == 1
    assert Repo.aggregate(Accounting.Query.executions(nil, "shadow"), :count) == 1
    assert Repo.aggregate(Accounting.Query.executions(nil, "all"), :count) == 2
  end

  defp claim! do
    id = Ecto.UUID.generate()

    command =
      Fixtures.admit_input(%{
        episode_id: id,
        episode_key: "accounting:#{id}",
        native_input_id: "input:#{id}"
      })

    assert {:ok, transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(transition.episode.id, "accounting", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("accounting", 60, :work)
    claim
  end
end
