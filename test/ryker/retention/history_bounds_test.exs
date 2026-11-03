defmodule Ryker.Retention.HistoryBoundsTest do
  @moduledoc """
  Retention runs every minute and ages each kind of row out by one column. On
  the tenant install those columns had no index, and the cutoff was a volatile
  clock no index can bound, so every pass read every worker command, worker
  event, GitHub delivery and Slack status receipt ever kept: 245,272 commands
  and 196,188 deliveries on 2026-11-03, more each day. Each table's age bound
  must be an index condition, so a pass reads the rows it may remove.
  """
  use Ryker.DataCase, async: false
  import Ecto.Query
  import Ryker.TestHelpers, only: [digest: 1]
  alias Ryker.CoopFleet.{Command, Event, Placement}
  alias Ryker.Episodes
  alias Ryker.Fixtures.CoopWorkers
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.QueryWork
  alias Ryker.Retention.Data
  alias Ryker.Work.Session

  # Worker commands and events are aged out by their session too; the test
  # below plans them against statistics of a journal that holds them.
  @aged %{
    "github_repository_events" => "inserted_at",
    "slack_thread_status_receipts" => "inserted_at"
  }

  test "a retention pass bounds each table it ages out by an index on that age" do
    {result, statements} = QueryWork.statements(fn -> Data.prune(settings()) end)
    assert {:ok, %{}} = result

    for {table, age} <- @aged do
      aging = Enum.filter(statements, &(&1.sql =~ ~r/DELETE FROM #{table}\b/))
      assert aging != [], "no statement aged out #{table}"

      for statement <- aging do
        assert index_bound?(statement, table, age),
               "#{table} was read without an index bound on #{age}"
      end
    end
  end

  # Planned with the statistics of a journal that keeps every command of its
  # discarded sessions, a pass reads the old ones it removes. Joined to its
  # sessions, the read began from them and sorted every command they had.
  test "a retention pass reads the old commands and events of discarded sessions, not every one" do
    assert {:ok, _worker} =
             CoopWorkers.authorize("ryker-compose", "workspace-main", digest("ryker-compose"))

    session = discarded_session!()
    placement = placement!(session)
    commands!(session, placement, 300, Repo.now!())
    commands!(session, placement, 3, ~U[2020-01-01 00:00:00.000000Z])
    events!(session, placement, 1..300, Repo.now!())
    events!(session, placement, 301..303, ~U[2020-01-01 00:00:00.000000Z])
    Repo.query!("ANALYZE coop_worker_commands")
    Repo.query!("ANALYZE coop_worker_events")
    Repo.query!("ANALYZE episode_work_sessions")

    {result, statements} = QueryWork.statements(fn -> Data.prune(settings()) end)
    assert {:ok, %{worker_commands: 3, worker_events: 3}} = result
    assert Repo.aggregate(Command, :count) == 300
    assert Repo.aggregate(Event, :count) == 300

    for table <- ~w(coop_worker_commands coop_worker_events) do
      [statement] = Enum.filter(statements, &ages_out?(&1.sql, table))
      assert rows_read(statement, table) <= 10, "a pass read every #{table} row"
    end
  end

  defp discarded_session! do
    episode_id = Ecto.UUID.generate()

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "history-bounds:#{episode_id}",
                 native_input_id: "source:history-bounds:#{episode_id}",
                 occurred_at: Repo.now!(),
                 turn_ref: "turn:history-bounds:#{episode_id}"
               })
             )

    assert {:ok, session} =
             WorkSessions.pin_episode(episode_id, "work-read-only", String.duplicate("b", 64))

    {1, _rows} =
      Repo.update_all(from(s in Session, where: s.id == ^session.id),
        set: [cleanup_status: :discarded, coop_session_id: "coop-#{session.id}"]
      )

    session
  end

  defp placement!(session) do
    Repo.insert!(%Placement{
      session_id: session.id,
      worker_id: "ryker-compose",
      generation: 1,
      lease_ref: "lease:#{session.id}:1",
      lease_expires_at: DateTime.add(Repo.now!(), 60, :second),
      state: :retired,
      requirements: %{},
      requirements_fingerprint: digest("requirements:#{session.id}:1")
    })
  end

  defp commands!(session, placement, count, at) do
    rows =
      for _ <- 1..count do
        id = Ecto.UUID.generate()

        %{
          id: id,
          placement_id: placement.id,
          worker_id: "ryker-compose",
          session_id: session.id,
          placement_generation: placement.generation,
          kind: "get_session",
          payload: %{},
          payload_fingerprint: digest("payload:#{id}"),
          idempotency_key: "history-bounds:#{id}",
          status: :queued,
          inserted_at: at,
          updated_at: at
        }
      end

    {^count, _rows} = Repo.insert_all(Command, rows)
  end

  defp events!(session, placement, sequences, at) do
    rows =
      for sequence <- sequences do
        %{
          placement_id: placement.id,
          worker_id: "ryker-compose",
          session_id: session.id,
          placement_generation: placement.generation,
          sequence: sequence,
          kind: "turn",
          payload: %{},
          payload_fingerprint: digest("event:#{placement.id}:#{sequence}"),
          inserted_at: at
        }
      end

    count = Enum.count(sequences)
    {^count, _rows} = Repo.insert_all(Event, rows)
  end

  # The rows of `table` the statement read, as its own plan counts them,
  # planned as a table holding more than a test's few rows is (`Ryker.QueryWork`).
  defp rows_read(%{sql: sql, params: params}, table) do
    {:error, {:plan, plan}} =
      Repo.transact(fn ->
        Repo.query!("SET LOCAL enable_seqscan = off")

        %{rows: [[[%{"Plan" => plan}]]]} =
          Repo.query!("EXPLAIN (ANALYZE, FORMAT JSON) " <> sql, params)

        {:error, {:plan, plan}}
      end)

    plan
    |> nodes()
    |> Enum.filter(&(&1["Relation Name"] == table))
    |> Enum.map(
      &((&1["Actual Rows"] + Map.get(&1, "Rows Removed by Filter", 0)) * &1["Actual Loops"])
    )
    |> Enum.max(fn -> 0 end)
  end

  defp ages_out?(sql, table),
    do: sql =~ ~r/DELETE FROM #{table}\b/ and sql =~ "(SELECT clock_timestamp()"

  defp index_bound?(%{sql: sql, params: params}, table, age) do
    {:error, {:plan, plan}} =
      Repo.transact(fn ->
        Repo.query!("SET LOCAL enable_seqscan = off")
        forget_statistics()
        %{rows: [[[%{"Plan" => plan}]]]} = Repo.query!("EXPLAIN (FORMAT JSON) " <> sql, params)
        {:error, {:plan, plan}}
      end)

    plan |> nodes() |> Enum.any?(&age_bound?(&1, table, age))
  end

  # A test database's statistics describe tables its tests emptied; planned
  # against them, a join may start anywhere. As `Ryker.QueryWork` does, every
  # table reads as newly created, as on a fresh install, inside the rolled-back
  # transaction around the plan.
  defp forget_statistics do
    Repo.query!("""
    SELECT pg_clear_relation_stats('public', relname)
    FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind = 'r'
    """)
  end

  defp nodes(plan), do: [plan | Enum.flat_map(Map.get(plan, "Plans", []), &nodes/1)]

  defp age_bound?(node, table, age) do
    String.starts_with?(Map.get(node, "Index Name", ""), table <> "_") and
      Map.get(node, "Index Cond", "") =~ age
  end

  defp settings do
    %{
      audit_data_seconds: 60,
      closed_work_seconds: 60,
      conversation_memory_seconds: 60,
      episode_history_seconds: 60,
      operational_data_seconds: 60,
      routing_examples_enabled: false,
      routing_examples_seconds: 365 * 86_400,
      work_examples_enabled: false,
      work_examples_seconds: 365 * 86_400
    }
  end
end
