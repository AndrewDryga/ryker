defmodule Responder.Evals.WorldConcurrencyTest do
  use Responder.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Responder.Accounting.Execution
  alias Responder.Delivery.Adapters
  alias Responder.Delivery.Dispatcher, as: DeliveryDispatcher
  alias Responder.Episodes
  alias Responder.Episodes.{Command, Episode, Event}
  alias Responder.Evals.{SlackDeliveryPublisher, WorldCase}
  alias Responder.Repo
  alias Responder.TestSupport.{FakeWorkCoopAPI, WorldHostReplay}
  alias Responder.Work.{Custody, Session, Submission, Turn}
  alias Responder.Work.Dispatcher, as: WorkDispatcher

  @policy_digest String.duplicate("a", 64)

  test "concurrent human feedback becomes one exact serialized continuation" do
    # Human replies often cross on a busy task. Both replies must survive the
    # write race and enter one next model turn, not create two sessions or let
    # either instruction leak into the already-running turn.
    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, scenario} = WorldCase.fetch("concurrent-human-feedback-serializes")
      [initial, feedback_a, feedback_b] = scenario.events
      episode_id = Ecto.UUID.generate()
      episode_key = "eval:concurrent-feedback:#{episode_id}"

      try do
        assert {:ok, first} =
                 Episodes.apply(input_command(initial, episode_id, episode_key, 1))

        assert {:ok, _session} =
                 Custody.pin_episode(
                   first.episode.id,
                   "world-eval-read-only",
                   @policy_digest,
                   nil
                 )

        assert {:ok, first_claim} =
                 Custody.claim_next("world-worker:concurrent:first", 300, :work)

        queued_refs = concurrently_admit!([feedback_a, feedback_b], episode_id, episode_key)
        stored = Repo.get!(Episode, episode_id)

        assert stored.active_input_refs == [
                 Command.dedupe_key(input_command(initial, episode_id, episode_key, 1))
               ]

        assert MapSet.new(stored.queued_input_refs) == MapSet.new(queued_refs)

        {:ok, fake} = FakeWorkCoopAPI.start_link([])
        {:ok, deliveries} = Agent.start_link(fn -> [] end)

        FakeWorkCoopAPI.update(fake, fn state ->
          put_in(state, [:session, "id"], "remote_concurrent_#{episode_id}")
        end)

        try do
          assert {:ok, before_execute} = WorldHostReplay.before_execute(scenario, fake)
          assert {:ok, adapters} = delivery_adapters(deliveries)

          # The MCP binding resolves current durable episode state at call time;
          # mirror that here even though the work claim itself is the frozen
          # first-turn snapshot.
          current_first_claim = %{first_claim | episode: Repo.get!(Episode, episode_id)}
          assert :ok = before_execute.(current_first_claim, scenario)

          assert {:ok, {:executed, first_execution}} =
                   WorkDispatcher.run_claim(
                     first_claim,
                     work_dispatcher_options(fake, "concurrent:first")
                   )

          assert first_execution.turn.status == :delivery_pending
          assert {:ok, {:delivered, :message, _ref}} = deliver_once(adapters, "first")

          assert {:ok, second_claim} =
                   Custody.claim_next("world-worker:concurrent:second", 300, :work)

          assert second_claim.episode.active_input_refs |> MapSet.new() == MapSet.new(queued_refs)
          assert second_claim.episode.queued_input_refs == []
          assert :ok = before_execute.(second_claim, scenario)

          assert {:ok, {:executed, second_execution}} =
                   WorkDispatcher.run_claim(
                     second_claim,
                     work_dispatcher_options(fake, "concurrent:second")
                   )

          assert second_execution.turn.status == :delivery_pending
          assert {:ok, {:delivered, :message, _ref}} = deliver_once(adapters, "second")
          assert {:ok, nil} = Custody.claim_next("world-worker:concurrent:idle", 300, :work)

          first_turn = Repo.get!(Turn, first_claim.turn.id)
          second_turn = Repo.get!(Turn, second_claim.turn.id)

          assert get_in(first_turn.submission, ["context", "mode"]) == "full"
          assert get_in(second_turn.submission, ["context", "mode"]) == "continuation"

          assert get_in(second_turn.submission, ["context", "parent_submission_ref"]) ==
                   Submission.fingerprint(first_turn.submission)

          feedback_texts =
            second_turn.submission
            |> get_in(["context", "current_inputs", "items"])
            |> Enum.map(&get_in(&1, ["content", "text"]))

          assert MapSet.new(feedback_texts) ==
                   MapSet.new([
                     feedback_a["payload"]["text"],
                     feedback_b["payload"]["text"]
                   ])

          assert FakeWorkCoopAPI.state(fake).create_count == 1
          assert FakeWorkCoopAPI.state(fake).submit_count == 2
          assert length(Agent.get(deliveries, & &1)) == 2
        after
          if Process.alive?(fake), do: Agent.stop(fake)
          if Process.alive?(deliveries), do: Agent.stop(deliveries)
        end
      after
        # Accounting deliberately survives operational deletion. Unboxed
        # fixtures must remove their own ledger or every later world replay
        # correctly refuses this no-longer-empty disposable database.
        Repo.delete_all(from(usage in Execution, where: usage.episode_id == ^episode_id))
        Repo.delete_all(from(turn in Turn, where: turn.episode_id == ^episode_id))
        Repo.delete_all(from(session in Session, where: session.episode_id == ^episode_id))
        Repo.delete_all(from(event in Event, where: event.episode_id == ^episode_id))
        Repo.delete_all(from(episode in Episode, where: episode.id == ^episode_id))
      end

      refute Repo.exists?(from(usage in Execution, where: usage.episode_id == ^episode_id))
    end)
  end

  defp concurrently_admit!(events, episode_id, episode_key) do
    parent = self()
    blocker = source_lock_task(episode_key, parent)
    assert_receive {:source_locked, blocker_backend}, 5_000

    commands =
      events
      |> Enum.with_index(2)
      |> Enum.map(fn {event, index} -> input_command(event, episode_id, episode_key, index) end)

    contenders = Enum.map(commands, &apply_task(&1, parent))

    contender_backends =
      Enum.map(contenders, fn contender ->
        contender_pid = contender.pid
        assert_receive {:contender_ready, ^contender_pid, backend}, 5_000
        backend
      end)

    try do
      Enum.each(contender_backends, fn contender_backend ->
        possible_blockers = [blocker_backend | List.delete(contender_backends, contender_backend)]
        await_blocked_by_any(contender_backend, possible_blockers)
      end)

      send(blocker.pid, :release)

      assert Enum.all?(Enum.map(contenders, &Task.await(&1, 5_000)), fn
               {:ok, %{status: :applied}} -> true
               _result -> false
             end)

      Enum.map(commands, &Command.dedupe_key/1)
    after
      send(blocker.pid, :release)
      stop_tasks([blocker | contenders])
    end
  end

  defp source_lock_task(episode_key, parent) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [episode_key])
        send(parent, {:source_locked, backend_pid()})

        receive do
          :release -> :ok
        end
      end)
    end)
  end

  defp apply_task(command, parent) do
    unboxed_task(fn ->
      send(parent, {:contender_ready, self(), backend_pid()})
      Episodes.apply(command)
    end)
  end

  defp await_blocked_by_any(blocked_backend, possible_blockers, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    %{rows: [[blocking_backends]]} =
      Repo.query!("SELECT pg_blocking_pids($1::integer)", [blocked_backend])

    cond do
      Enum.any?(blocking_backends, &(&1 in possible_blockers)) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("concurrent feedback writer never reached the serialized input lock chain")

      true ->
        await_blocked_by_any(blocked_backend, possible_blockers, deadline)
    end
  end

  defp input_command(event, episode_id, episode_key, index) do
    {:ok, occurred_at, 0} = DateTime.from_iso8601(event["occurred_at"])

    %Command.AdmitInput{
      actor_ref: event["actor_ref"],
      destination: %{
        conversation_ref: event["destination"]["conversation_ref"],
        thread_ref: event["destination"]["thread_ref"],
        transport: event["destination"]["transport"]
      },
      episode_id: episode_id,
      episode_key: episode_key,
      execution_mode: :live,
      native_input_id: "eval-input:concurrent-feedback:#{index}",
      occurred_at: occurred_at,
      payload: event["payload"],
      revision: 1,
      turn_ref: "eval-turn:concurrent-feedback:#{index}"
    }
  end

  defp delivery_adapters(deliveries) do
    Adapters.new(%{
      "slack" => %{
        binding: deliveries,
        message_publisher: SlackDeliveryPublisher,
        reaction_publisher: SlackDeliveryPublisher
      }
    })
  end

  defp deliver_once(adapters, suffix) do
    DeliveryDispatcher.run_once(
      adapters: adapters,
      kind: :message,
      lease_seconds: 60,
      max_attempts: 1,
      retry_base_seconds: 1,
      retry_max_seconds: 1,
      worker_ref: "world-worker:concurrent:delivery:#{suffix}"
    )
  end

  defp work_dispatcher_options(fake, suffix) do
    [
      executor_options: [
        api: FakeWorkCoopAPI,
        client: fake,
        state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
        state_tools_secret: "world-eval-state-tools-secret"
      ],
      lease_seconds: 300,
      max_attempts: 4,
      retry_base_seconds: 1,
      retry_max_seconds: 1,
      worker_ref: "world-worker:#{suffix}"
    ]
  end
end
