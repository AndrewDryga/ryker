defmodule Ryker.Publication.FollowupsConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Accounting.Execution
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.Ingress.Input
  alias Ryker.Publication.{Followups, LifecycleEvent, Publication}
  alias Ryker.Repo
  alias Ryker.Slack.TaskCard
  alias Ryker.State.{ConversationObservation, LearningSources, Record, Response}
  alias Ryker.Work.{Session, Turn}

  test "equivalent GitHub feedback under real publication lock contention retains one wakeup" do
    # Shared Sandbox ownership cannot prove this race: two independent default
    # READ COMMITTED connections must see the first committed immutable receipt.
    Sandbox.unboxed_run(Repo, fn ->
      suffix = "github-feedback-race-#{Ecto.UUID.generate()}"
      baseline = database_row_counts()

      %{episode: episode, publication: publication} =
        PublicationFixture.published!(suffix,
          github_repository: "octo/feedback-equivalence",
          pull_request_number: 74
        )

      try do
        input = feedback_input(suffix)
        results = contend_on_publication(publication, input)
        assert Enum.count(results, &match?({:ok, %{status: :recorded}}, &1)) == 1
        assert Enum.count(results, &match?({:ok, %{status: :duplicate}}, &1)) == 1

        {:ok, %{event: first}} = Enum.find(results, &match?({:ok, %{status: :recorded}}, &1))
        assert Enum.all?(results, &match?({:ok, %{event: %{id: id}}} when id == first.id, &1))

        assert [stored] =
                 Repo.all(
                   from(event in LifecycleEvent, where: event.publication_id == ^publication.id)
                 )

        assert stored == first
        source = Repo.get_by!(ConversationObservation, source_input_id: first.id)

        assert {:ok, claim} = Followups.claim_delivery(suffix, 60)
        assert claim.event.id == first.id
        assert {:ok, admitted} = Followups.admit_wakeup(first.ref, claim.lease_ref)
        assert admitted.wakeup_state == :admitted
        assert Repo.get!(ConversationObservation, source.id) == source

        turn_ref = "turn:publication-feedback:#{first.id}"

        assert [wake] =
                 Repo.all(
                   from(event in Event,
                     where:
                       event.episode_id == ^episode.id and event.kind == :input_admitted and
                         fragment("?::jsonb ->> 'turn_ref' = ?", event.payload, ^turn_ref)
                   )
                 )

        assert [receipt] = LearningSources.for_work_input(wake.payload["payload"])
        assert receipt["source_input_id"] == first.id
      after
        delete_fixture(episode.id)

        remaining =
          Map.reject(database_row_counts(), fn {table, count} ->
            count == Map.fetch!(baseline, table)
          end)

        assert remaining == %{}, "unboxed publication fixture left rows: #{inspect(remaining)}"
      end
    end)
  end

  defp contend_on_publication(publication, input) do
    parent = self()

    blocker =
      unboxed_task(fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from(row in Publication, where: row.id == ^publication.id, lock: "FOR UPDATE")
          )

          send(parent, {:publication_locked, backend_pid()})

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive {:publication_locked, blocking_backend}, 5_000

    contenders =
      for index <- 1..2 do
        unboxed_task(fn ->
          assert Repo.query!("SHOW transaction_isolation").rows == [["read committed"]]
          send(parent, {:feedback_ready, self(), backend_pid()})

          equivalent = %{
            input
            | event_ref: input.event_ref <> ":#{index}",
              content: Map.put(input.content, "delivery_ref", "delivery:#{index}")
          }

          Followups.observe_github_feedback(equivalent)
        end)
      end

    try do
      backends =
        Enum.map(contenders, fn contender ->
          pid = contender.pid
          assert_receive {:feedback_ready, ^pid, backend}, 5_000
          await_publication_lock(backend, blocking_backend)
          backend
        end)

      assert length(Enum.uniq([blocking_backend | backends])) == 3
      send(blocker.pid, :release)
      results = Enum.map(contenders, &Task.await(&1, 5_000))
      assert {:ok, :ok} = Task.await(blocker, 5_000)
      results
    after
      send(blocker.pid, :release)
      stop_tasks([blocker | contenders])
    end
  end

  defp await_publication_lock(
         backend,
         blocker,
         deadline \\ System.monotonic_time(:millisecond) + 5_000
       ) do
    # PostgreSQL queues the second tuple locker behind the first contender;
    # prove both wait chains end at our held publication, not just direct edges.
    query = """
    WITH RECURSIVE blockers(pid) AS (
      SELECT unnest(pg_blocking_pids($1::integer))
      UNION
      SELECT unnest(pg_blocking_pids(pid)) FROM blockers
    )
    SELECT EXISTS (SELECT 1 FROM blockers WHERE pid = $2::integer)
    """

    cond do
      Repo.query!(query, [backend, blocker]).rows == [[true]] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("feedback never waited on the publication lock")

      true ->
        await_publication_lock(backend, blocker, deadline)
    end
  end

  defp feedback_input(suffix) do
    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "lifecycle-actor"},
        content: %{
          "event_name" => "issue_comment",
          "payload" => %{
            "issue" => %{"number" => 74, "pull_request" => %{}},
            "repository" => %{"full_name" => "octo/feedback-equivalence"}
          }
        },
        destination: %{
          transport: "github",
          conversation_ref: "github:ryker-app:octo/feedback-equivalence:pull:74",
          thread_ref: nil
        },
        event_kind: :message,
        event_ref: "feedback:#{suffix}",
        native_input_id: "feedback-item:#{suffix}",
        occurred_at: ~U[2026-08-28 12:10:00.000000Z],
        occurred_at_source: :source,
        revision: 1,
        source: %{kind: "github", ref: "ryker-app"},
        source_capabilities: %{},
        source_item_ref: "github:issue_comment:#{suffix}"
      })

    input
  end

  defp database_row_counts do
    %{rows: tables} =
      Repo.query!("""
      SELECT table_name FROM information_schema.tables
      WHERE table_schema = current_schema() AND table_type = 'BASE TABLE'
        AND table_name <> 'schema_migrations'
      """)

    Map.new(tables, fn [table] ->
      quoted = ~s("#{String.replace(table, "\"", "\"\"")}")
      %{rows: [[count]]} = Repo.query!("SELECT COUNT(*) FROM #{quoted}")
      {table, count}
    end)
  end

  defp delete_fixture(episode_id) do
    # Accounting intentionally survives source-turn deletion. Leaving this
    # fixture's one ledger row broke usage totals and the disposable-world guard.
    Repo.delete_all(from(row in Execution, where: row.episode_id == ^episode_id))

    Repo.delete_all(
      from(row in ConversationObservation, where: row.source_episode_id == ^episode_id)
    )

    Repo.delete_all(from(row in Publication, where: row.episode_id == ^episode_id))
    Repo.delete_all(from(row in TaskCard, where: row.episode_id == ^episode_id))

    Repo.delete_all(
      from(row in Response,
        join: record in Record,
        on: row.record_id == record.id,
        where: record.episode_id == ^episode_id
      )
    )

    Repo.delete_all(from(row in Record, where: row.episode_id == ^episode_id))
    Repo.delete_all(from(row in Turn, where: row.episode_id == ^episode_id))
    Repo.delete_all(from(row in Session, where: row.episode_id == ^episode_id))
    Repo.delete_all(from(row in Event, where: row.episode_id == ^episode_id))
    Repo.delete_all(from(row in Episode, where: row.id == ^episode_id))
  end
end
