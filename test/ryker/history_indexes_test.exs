defmodule Ryker.HistoryIndexesTest do
  @moduledoc """
  Reads that run every second or minute, which on the tenant install read
  every row their table ever kept (2026-11-03): the ready pools' look for
  stranded and failed starts (two full scans of 8,914 sessions a second),
  the minute-by-minute monitoring sweep's latest refresh per reply (about 200
  scans of the audit table a minute), and recall's directly supporting topic
  sources (a scan of 22,986 rows for 660). Each reads what it needs, planned
  as a table holding more than a test's few rows is.
  """
  use Ryker.DataCase, async: false
  import Ecto.Query
  import Ryker.TestHelpers, only: [digest: 1]
  alias Ryker.Admission.ReadySessions
  alias Ryker.CanonicalJSON
  alias Ryker.CoopFleet.{Command, Placement}
  alias Ryker.Episodes
  alias Ryker.Fixtures.CoopWorkers
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Knowledge.KnowledgeSource
  alias Ryker.Observability.Fleet
  alias Ryker.QueryWork
  alias Ryker.Retention.Cleanup
  alias Ryker.Slack
  alias Ryker.Slack.InteractionAudit
  alias Ryker.Work.ActivityEvent
  alias Ryker.Work.Custody
  alias Ryker.Work.Session

  setup do
    Repo.query!("SET LOCAL enable_seqscan = off")
    :ok
  end

  # Planned with the statistics of a pool that keeps every session it retired.
  test "the routing pool reads its stranded and newest sessions, not every one it retired" do
    now = Repo.now!()

    retired =
      for second <- 1..60,
          do: pool_session(:retired, DateTime.add(now, -3_600 - second, :second))

    {61, _rows} =
      Repo.insert_all(Session, [
        pool_session(:starting, DateTime.add(now, -7_200, :second)) | retired
      ])

    Repo.query!("ANALYZE episode_work_sessions")

    {stranded, reads} = QueryWork.statements(fn -> ReadySessions.stranded(60) end)
    assert [%Session{ready_state: :starting}] = stranded
    assert sessions_read(reads) <= 2

    {_failed, reads} = QueryWork.statements(fn -> ReadySessions.failed_starts() end)
    assert sessions_read(reads) <= 17
  end

  # Readiness and every cleanup claim asked which sessions were eligible, and one arm of the
  # question, for receipts no install holds any more, read every session ever discarded: 17 scans a
  # minute of 9,160 rows on the tenant install (2026-11-04).
  test "cleanup eligibility reads the sessions still in play, not every one discarded" do
    now = Repo.now!()

    discarded =
      for second <- 1..60 do
        at = DateTime.add(now, -3_600 - second, :second)
        pool_session(:retired, at) |> Map.merge(%{cleanup_status: :discarded, discarded_at: at})
      end

    {60, _rows} = Repo.insert_all(Session, discarded)
    Repo.query!("ANALYZE episode_work_sessions")

    {_oldest, reads} =
      QueryWork.statements(fn ->
        now |> Cleanup.Query.eligible() |> Cleanup.Query.select_oldest_eligible_at() |> Repo.one()
      end)

    assert sessions_read(reads) <= 5
  end

  # An episode page's Slack status steps read every thread's receipts to find
  # its own: the episode's messages were a subquery under an `OR`.
  test "an episode's Slack status steps read its own receipts, not every thread's" do
    mine = claim!()
    receipts!("episode", fn -> mine.episode.id end, 2)
    receipts!("input", &Ecto.UUID.generate/0, 80)
    Repo.query!("ANALYZE slack_thread_status_receipts")

    {steps, reads} =
      QueryWork.statements(fn -> Slack.ThreadStatusReceipts.for_episode(mine.episode.id) end)

    assert length(steps) == 2
    assert rows_read(reads, "slack_thread_status_receipts") <= 4
  end

  # Every Slack reply and repaint asked which activity had expired by building
  # that set over every episode's activity, input and turn.
  test "a reply's sources read its own episode's activity, not every episode's" do
    mine = claim!()
    other = claim!()
    activity!(mine, 2)
    activity!(other, 80)
    Repo.query!("ANALYZE episode_work_activity")

    {calls, reads} =
      QueryWork.statements(fn ->
        mine.episode.id
        |> ActivityEvent.Query.returned_urls(["https://example.test/run"])
        |> Repo.all()
      end)

    assert length(calls) == 2
    assert rows_read(reads, "episode_work_activity") <= 4
  end

  # Readiness, metrics and every Activity redraw counted every worker command
  # and placement ever kept, by status and state (2026-11-03).
  test "readiness counts the worker commands and placements in play, not every one kept" do
    assert {:ok, _worker} =
             CoopWorkers.authorize("ryker-compose", "workspace-main", digest("ryker-compose"))

    live = claim!()
    current = placement!(live.session, 1, :active)
    commands!(live.session, current, :queued, 1)

    for _ <- 1..30 do
      done = claim!()
      commands!(done.session, placement!(done.session, 1, :retired), :succeeded, 2)
    end

    Repo.query!("ANALYZE coop_worker_commands")
    Repo.query!("ANALYZE coop_session_placements")

    {{:ok, fleet}, reads} = QueryWork.statements(fn -> Fleet.snapshot(Repo.now!()) end)
    assert fleet.commands == %{queued: 1}
    assert fleet.placements == %{active: 1}
    assert rows_read(reads, "coop_worker_commands") <= 3
    assert rows_read(reads, "coop_session_placements") <= 3
  end

  test "a reply's latest monitoring refresh is found through its own index" do
    query = InteractionAudit.Query.latest_monitoring("T1", "C1", "1.000100")
    assert plan(query) =~ "slack_interaction_audit_latest_monitoring"
  end

  test "the topics' directly supporting sources are found through their own index" do
    eligible =
      from(k in "conversation_knowledge",
        where: k.workspace_ref == "T1",
        select: %{id: k.id, source_generation: k.source_generation}
      )

    assert plan(KnowledgeSource.Query.direct_observation_ids(eligible)) =~
             "conversation_knowledge_sources_direct_support"
  end

  defp pool_session(state, at) do
    id = Ecto.UUID.generate()

    %{
      id: id,
      execution_kind: :admission,
      policy: "admission-read-only",
      policy_digest: String.duplicate("a", 64),
      external_ref: "ready-admission:#{id}",
      ready_state: state,
      inserted_at: at,
      updated_at: at
    }
  end

  defp claim! do
    id = Ecto.UUID.generate()

    {:ok, started} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: id,
          episode_key: id,
          native_input_id: id,
          turn_ref: id
        })
      )

    {:ok, session} =
      WorkSessions.pin_episode(started.episode.id, "policy:history", String.duplicate("a", 64))

    {:ok, claim} = Custody.claim_next("history:#{id}", 60, :work)
    turn = Repo.update!(Ecto.Changeset.change(claim.turn, coop_turn_id: "remote:#{id}"))
    %{episode: started.episode, session: session, turn: turn}
  end

  # Receipts of `kind`'s writes, each for the origin `origin` names.
  defp placement!(session, generation, state) do
    Repo.insert!(%Placement{
      session_id: session.id,
      worker_id: "ryker-compose",
      generation: generation,
      lease_ref: "lease:#{session.id}:#{generation}",
      lease_expires_at: DateTime.add(Repo.now!(), 60, :second),
      state: state,
      requirements: %{},
      requirements_fingerprint: digest("requirements:#{session.id}:#{generation}")
    })
  end

  defp commands!(session, placement, status, count) do
    now = Repo.now!()

    rows =
      for _ <- 1..count do
        id = Ecto.UUID.generate()

        settled =
          if status == :succeeded,
            do: %{
              operation_key: "operation:#{id}",
              result: %{},
              result_fingerprint: digest("result:#{id}"),
              completed_at: now
            },
            else: %{}

        Map.merge(settled, %{
          id: id,
          placement_id: placement.id,
          worker_id: "ryker-compose",
          session_id: session.id,
          placement_generation: placement.generation,
          kind: "get_session",
          payload: %{},
          payload_fingerprint: digest("payload:#{id}"),
          idempotency_key: "history:#{id}",
          status: status,
          inserted_at: now,
          updated_at: now
        })
      end

    {^count, _rows} = Repo.insert_all(Command, rows)
  end

  defp receipts!(kind, origin, count) do
    rows =
      for step <- 1..count do
        %{
          id: Ecto.UUID.generate(),
          workspace_ref: "T1",
          channel_ref: "C1",
          thread_ref: "1.000100",
          generation: 1,
          lease_ref: Ecto.UUID.generate(),
          origin_kind: kind,
          origin_id: origin.(),
          phase: "working",
          text: "Working on step #{step}.",
          inserted_at: Repo.now!()
        }
      end

    {^count, _rows} = Repo.insert_all(Slack.ThreadStatusReceipt, rows)
  end

  defp activity!(claim, count) do
    rows =
      for sequence <- 1..count do
        payload = %{"status" => "completed", "output" => "https://example.test/run"}

        %{
          id: Ecto.UUID.generate(),
          episode_id: claim.episode.id,
          session_id: claim.session.id,
          remote_event_id: Ecto.UUID.generate(),
          remote_session_id: claim.session.id,
          coop_turn_id: claim.turn.coop_turn_id,
          sequence: sequence,
          kind: "tool.completed",
          version: 1,
          occurred_at: Repo.now!(),
          payload: payload,
          payload_fingerprint: CanonicalJSON.digest(payload),
          inserted_at: Repo.now!()
        }
      end

    {^count, _rows} = Repo.insert_all(ActivityEvent, rows)
  end

  defp sessions_read(statements), do: rows_read(statements, "episode_work_sessions")

  # The most rows of `table` one statement read, as its own plan counts them.
  defp rows_read(statements, table) do
    statements
    |> Enum.filter(&(&1.sql =~ ~s("#{table}")))
    |> Enum.map(fn %{sql: sql, params: params} ->
      %{rows: [[[%{"Plan" => plan}]]]} =
        Repo.query!("EXPLAIN (ANALYZE, FORMAT JSON) " <> sql, params)

      plan
      |> nodes()
      |> Enum.filter(&(&1["Relation Name"] == table))
      |> Enum.map(
        &((&1["Actual Rows"] + Map.get(&1, "Rows Removed by Filter", 0)) * &1["Actual Loops"])
      )
      |> Enum.sum()
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp nodes(plan), do: [plan | Enum.flat_map(Map.get(plan, "Plans", []), &nodes/1)]

  defp plan(query) do
    {sql, params} = Repo.to_sql(:all, query)
    %{rows: rows} = Repo.query!("EXPLAIN " <> sql, params)
    rows |> List.flatten() |> Enum.join("\n")
  end
end
