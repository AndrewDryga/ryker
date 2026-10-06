defmodule Ryker.AccountingTest do
  use Ryker.DataCase, async: true
  import Ecto.Query
  alias Ryker.{Accounting, Episodes, Repo}
  alias Ryker.Accounting.Execution
  alias Ryker.Fixtures.Episodes, as: Fixtures
  alias Ryker.Work.Custody
  alias Ryker.Work.SubmissionBuilder

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

  # The Usage page and a request's page show what each execution cost. Until
  # 2026-09-26 they learned of it from a trigger's NOTIFY and a five-second
  # poll; the ledger now says so itself once the snapshot commits.
  test "a recorded execution's usage reaches the usage page and its request's page" do
    claim = claim!()
    episode_id = claim.episode.id
    :ok = Accounting.subscribe_usage()
    :ok = Episodes.subscribe_episode(episode_id)

    remote = %{
      "id" => "remote-usage-turn",
      "state" => "running",
      "usage" => %{"input_tokens" => 10}
    }

    assert :ok = Accounting.observe_work(claim, remote, %{"target" => "claude:opus/high@work"})

    execution_id = Repo.one!(from(execution in Execution, select: execution.id))
    assert_received {:usage_recorded, ^execution_id}
    assert_received {:episode_updated, ^episode_id}
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

  # Every lease custody writes comes from the database's clock, and every other
  # fence compares against it. This one read the host's, so a host running
  # ahead of its database refused usage for leases the database still held,
  # and one running behind accounted for leases custody had already given
  # away. The two clocks agree on one machine, which is why nothing caught it.
  test "the accounting fence reads the database clock, not the host's" do
    claim = claim!()
    shadow_database_clock!(3_600)

    assert {:error, :accounting_lease_lost} =
             Accounting.observe_work(claim, %{"state" => "completed"})

    assert Repo.aggregate(Execution, :count) == 0
  end

  # `pg_catalog` is searched after the shadow schema, so every unqualified
  # `clock_timestamp()` this connection issues answers `offset_seconds` ahead
  # of the real clock. SET and DDL are transactional: the sandbox rollback
  # removes both without touching any other test.
  defp shadow_database_clock!(offset_seconds) do
    schema = "accounting_clock_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{schema}")

    Repo.query!("""
    CREATE FUNCTION #{schema}.clock_timestamp() RETURNS timestamptz LANGUAGE sql STABLE AS $$
      SELECT pg_catalog.clock_timestamp() + #{offset_seconds} * interval '1 second'
    $$
    """)

    Repo.query!("SET search_path TO #{schema}, pg_catalog, public")
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
