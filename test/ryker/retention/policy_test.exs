defmodule Ryker.Retention.PolicyTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  alias Ryker.Fixtures.Learning, as: Fixtures
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning
  alias Ryker.Learning.{Batch, Batches, InputMembership}
  alias Ryker.Learning.LearningRun
  alias Ryker.RetentionPolicies

  test "every migrated table has one explained retention owner" do
    policies = RetentionPolicies.all()
    policy_tables = Enum.map(policies, & &1.table)

    assert policy_tables == Enum.uniq(policy_tables)
    assert coverage_gaps() == %{unowned: [], stale: []}

    assert Enum.all?(
             policies,
             &(&1.class in [
                 :operational,
                 :conversation_memory,
                 :closed_work,
                 :episode_history,
                 :audit,
                 :cascade,
                 :kept,
                 :routing_examples,
                 :work_examples
               ])
           )

    assert Enum.all?(policies, &(is_binary(&1.why) and String.trim(&1.why) != ""))
  end

  # The registry said finished schedules were kept for good while retention
  # deleted them at the history horizon (2026-10-04 review). A table
  # retention deletes from or clears is never registered as kept.
  test "no table retention prunes is registered as kept" do
    source = File.read!(Path.expand("../../../lib/ryker/retention/data.ex", __DIR__))

    pruned =
      [
        ~r/table: "([a-z_]+)"/,
        ~r/DELETE FROM ([a-z_]+)/,
        ~r/\{"([a-z_]+)", "/,
        ~r/UPDATE ([a-z_]+)/
      ]
      |> Enum.flat_map(&Regex.scan(&1, source, capture: :all_but_first))
      |> List.flatten()
      |> Enum.uniq()

    assert pruned != []

    kept =
      for table <- pruned, {:ok, %{class: :kept}} <- [RetentionPolicies.fetch(table)], do: table

    assert kept == [], "retention prunes tables registered as kept: #{Enum.join(kept, ", ")}"
  end

  test "a new table without a retention rule fails the coverage check" do
    # The coverage check above is what stops a new table from quietly keeping
    # its rows forever. It has to see a table created in the migrated schema,
    # so a filter that hid new tables would make it pass on nothing.
    Repo.query!("CREATE TABLE retention_coverage_probe (id uuid PRIMARY KEY)")

    assert coverage_gaps() == %{unowned: ["retention_coverage_probe"], stale: []}
  end

  test "expiring a learning prompt cannot erase spent starts or permit its inputs to be assigned again" do
    # A retention whitelist alone would miss the dangerous behavior: deleting
    # execution-budget custody makes the same old message buy fresh model starts.
    inputs = Fixtures.inputs!()
    ids = Enum.map(inputs, & &1.id)
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    Repo.update_all(from(e in Entry, where: e.id in ^ids), set: [updated_at: now])

    settings = %{
      policy: "recorded-read-only-policy",
      policy_digest: String.duplicate("a", 64),
      quiet_seconds: 0,
      maximum_delay_seconds: 60,
      lease_seconds: 300,
      batch_size: 16
    }

    assert {:ok, claim} = Batches.claim("retention-owner", settings)
    assert {:ok, run} = Batches.prepare(claim)
    assert {:ok, _} = Batches.begin_execution(claim, run.id)
    before_batch = Repo.get!(Batch, claim.batch.id)
    before_assignments = Repo.all(from(m in InputMembership, order_by: m.input_id))
    assert before_batch.start_count == 1
    assert length(before_assignments) == length(inputs)

    Repo.update_all(from(e in Entry, where: e.id in ^ids), set: [operational_pruned_at: now])
    assert Repo.transaction(fn -> Learning.prune_in_transaction(3600) end) == {:ok, 1}
    assert Repo.get!(LearningRun, run.id).prompt == nil
    assert Repo.get!(LearningRun, run.id).pruned_at != nil
    assert Repo.get!(Batch, claim.batch.id) == before_batch
    assert Repo.all(from(m in InputMembership, order_by: m.input_id)) == before_assignments
    assert Batches.claim("after-retention", settings) == {:ok, :idle}
    assert {:ok, %{class: :kept}} = RetentionPolicies.fetch("conversation_learning_batches")
  end

  test "learning input assignment has real source and batch cascade owners" do
    assert {:ok, %{class: :cascade}} = RetentionPolicies.fetch("conversation_learning_inputs")

    assert %{
             rows: [
               ["conversation_learning_batches", "c"],
               ["ingress_inbox_entries", "c"]
             ]
           } =
             Repo.query!("""
             SELECT target.relname, constraint_row.confdeltype::text
             FROM pg_constraint constraint_row
             JOIN pg_class source ON source.oid = constraint_row.conrelid
             JOIN pg_class target ON target.oid = constraint_row.confrelid
             JOIN pg_namespace namespace ON namespace.oid = source.relnamespace
             WHERE namespace.nspname = current_schema()
               AND source.relname = 'conversation_learning_inputs'
               AND constraint_row.contype = 'f'
             ORDER BY target.relname
             """)
  end

  # Migrated tables without a policy, and policies that name no migrated table.
  defp coverage_gaps do
    tables =
      Repo.query!("""
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = current_schema() AND table_type = 'BASE TABLE'
      ORDER BY table_name
      """)
      |> Map.fetch!(:rows)
      |> List.flatten()

    policy_tables = Enum.map(RetentionPolicies.all(), & &1.table)
    %{unowned: tables -- policy_tables, stale: Enum.sort(policy_tables -- tables)}
  end
end
