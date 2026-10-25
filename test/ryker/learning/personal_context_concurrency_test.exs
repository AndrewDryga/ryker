defmodule Ryker.Learning.PersonalContextConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.CanonicalJSON
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Fixtures.Personalization
  alias Ryker.Ingress
  alias Ryker.Learning
  alias Ryker.Learning.{Batch, Batches, Dispatcher, Executor, LearningRun, Observations}
  alias Ryker.Memories
  alias Ryker.People
  alias Ryker.Repo
  alias Ryker.Slack

  @policy %{policy: "recorded-read-only-policy", policy_digest: String.duplicate("a", 64)}
  @settings Map.merge(@policy, %{
              worker_ref: "profile-lock-test",
              quiet_seconds: 0,
              maximum_delay_seconds: 60,
              lease_seconds: 300,
              batch_size: 16,
              step_delay_seconds: 1,
              execution_timeout_seconds: 600
            })

  # A locked profile is temporarily unverifiable, not withdrawn. Retiring its
  # run here would spend the bounded learning budget without a model call.
  for started <- [false, true] do
    test "a busy profile yields a #{if started, do: "started", else: "prepared"} batch without spending a retry" do
      Sandbox.unboxed_run(Repo, fn ->
        {entry, fact, _run} = Personalization.learning_context!(@policy)

        try do
          assert {:ok, claim} = Batches.claim("profile-lock-test", @settings)
          assert {:ok, run} = Batches.prepare(claim)
          if unquote(started), do: assert({:ok, _} = Batches.begin_execution(claim, run.id))

          with_locked_fact(fact, fn ->
            assert Learning.prepare([entry.id], @policy) == {:error, :learning_context_busy}
            assert Executor.step(claim, run, @settings) == {:error, :learning_context_busy}
            assert {:ok, _} = Batches.yield(claim, 0)
            assert {:ok, batch} = Dispatcher.run_once(@settings)
            assert batch.status == :queued
            assert is_nil(batch.lease_ref)
            assert is_nil(batch.error_code)
            assert batch.start_count == if(unquote(started), do: 1, else: 0)
            assert DateTime.compare(batch.next_attempt_at, Repo.now!()) == :gt
            saved = Repo.fetch!(LearningRun.Query.by_id(run.id))
            assert saved.status == :prepared
            assert saved.reconcile_attempt_count == 0
            assert is_nil(saved.error_code)
          end)

          Repo.update_all(Batch.Query.by_id(claim.batch.id),
            set: [next_attempt_at: ~U[2000-01-01 00:00:00.000000Z]]
          )

          assert {:ok, resumed} = Batches.claim("profile-resume", @settings)
          assert resumed.batch.id == claim.batch.id
          assert {:ok, authorized} = Learning.authorize(run.id, resumed)
          assert authorized.id == run.id
        after
          Personalization.cleanup_learning!(entry)
        end
      end)
    end
  end

  test "candidate checking and application preserve a responded run while its profile is busy" do
    Sandbox.unboxed_run(Repo, fn ->
      {entry, fact, run} = Personalization.learning_context!(@policy)

      try do
        result =
          "testdata/learning/recorded-no-change-result.json"
          |> File.read!()
          |> Jason.decode!()
          |> Map.fetch!("result")

        run
        |> Ecto.Changeset.change(status: :responded, result: result, validation_receipt: %{})
        |> Repo.update!()

        with_locked_fact(fact, fn ->
          assert Learning.check_candidate(run.id) == {:error, :learning_context_busy}
          assert Repo.fetch!(LearningRun.Query.by_id(run.id)).status == :responded
          assert Learning.apply_result(run.id) == {:error, :learning_context_busy}
          assert Repo.fetch!(LearningRun.Query.by_id(run.id)).status == :responded
        end)
      after
        Personalization.cleanup_learning!(entry)
      end
    end)
  end

  test "profile authorization waits outside the fact rows channel deletion must erase" do
    Sandbox.unboxed_run(Repo, fn ->
      {entry, _fact, run} = Personalization.learning_context!(@policy)

      {:ok, workspace, channel} =
        Ryker.ConversationRef.parse_slack(entry.destination_conversation_ref)

      parent = self()

      deleter =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            Repo.query!("SET LOCAL deadlock_timeout = '50ms'")
            :ok = Slack.ChannelFence.lock_in_transaction(workspace, channel)
            send(parent, {:channel_locked, backend_pid()})
            receive do: (:redact -> :ok)
            :ok = Memories.Reviews.delete_slack_channel_in_transaction(workspace, channel)
            People.forget_conversation_in_transaction(entry.destination_conversation_ref)
          end)
        end)

      try do
        assert_receive {:channel_locked, blocking}, 5_000

        reader =
          unboxed_task(fn ->
            send(parent, {:reader_started, backend_pid()})
            Learning.authorize(run.id)
          end)

        try do
          assert_receive {:reader_started, backend}, 5_000
          await_blocked_by(backend, blocking)
          send(deleter.pid, :redact)
          assert Task.await(deleter, 5_000) == {:ok, :ok}
          assert Task.await(reader, 5_000) == {:error, :learning_source_stale}
        after
          stop_tasks([reader])
        end
      after
        send(deleter.pid, :redact)
        stop_tasks([deleter])
        Personalization.cleanup_learning!(entry)
      end
    end)
  end

  test "accepted judgments in different conversations can learn about the same author without deadlock" do
    Sandbox.unboxed_run(Repo, fn ->
      {entry, fact, _run} = Personalization.learning_context!(@policy)

      try do
        sibling = sibling_entry!(entry)

        try do
          public_channels!(entry, sibling)
          result = people_result()
          [birthday | _] = result["people"]

          fact
          |> Ecto.Changeset.change(private: false, key: birthday["key"], fact: birthday["fact"])
          |> Repo.update!()

          assert {:ok, run} = Learning.prepare([entry.id], @policy)
          assert {:ok, sibling_run} = Learning.prepare([sibling.id], @policy)
          parent = self()
          first = accepting_task(parent, :first, entry, run)

          try do
            assert_receive {:authorizing, :first, first_backend}, 5_000
            assert_receive {:profile_authorized, :first}, 5_000
            second = accepting_task(parent, :second, sibling, sibling_run)

            try do
              assert_receive {:authorizing, :second, second_backend}, 5_000
              await_authorized_or_waiting(second_backend, first_backend)
              send(first.pid, :apply_result)
              send(second.pid, :apply_result)
              assert {:ok, {:ok, %{status: :applied}}} = Task.await(first, 5_000)
              assert {:ok, {:ok, %{status: :applied}}} = Task.await(second, 5_000)
              assert length(People.facts(fact.person_ref)) == 4
            after
              stop_tasks([second])
            end
          after
            stop_tasks([first])
          end
        after
          Personalization.cleanup_learning!(sibling)
        end
      after
        Personalization.cleanup_learning!(entry)
      end
    end)
  end

  defp accepting_task(parent, role, entry, run) do
    # Preserve a captured well-formed judgment; only source identities are
    # rebound to the two isolated original inputs used by this host race.
    result = people_result()
    people = Enum.map(result["people"], &Map.put(&1, "source_input_id", entry.id))
    result = result |> Map.put("people", people) |> Jason.encode!()

    unboxed_task(fn ->
      try do
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL deadlock_timeout = '50ms'")
          send(parent, {:authorizing, role, backend_pid()})
          assert {:ok, _} = Learning.authorize(run.id)
          send(parent, {:profile_authorized, role})
          receive do: (:apply_result -> :ok)
          LearningFixtures.accept(run.id, result, %{})
        end)
      rescue
        error in Postgrex.Error -> {:error, error.postgres.code}
      end
    end)
  end

  defp people_result do
    "testdata/learning/retained-people-about-themselves.json"
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["recorded_result", "result"])
    |> Jason.decode!()
  end

  defp await_authorized_or_waiting(backend, blocking, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    receive do
      {:profile_authorized, :second} -> :ok
    after
      0 ->
        waiting =
          Repo.query!("SELECT $2::integer = ANY(pg_blocking_pids($1::integer))", [
            backend,
            blocking
          ]).rows == [[true]]

        cond do
          waiting ->
            :ok

          System.monotonic_time(:millisecond) > deadline ->
            flunk("the second authorization neither returned nor waited")

          true ->
            await_authorized_or_waiting(backend, blocking, deadline)
        end
    end
  end

  defp sibling_entry!(entry) do
    id = Ecto.UUID.generate()

    {:ok, workspace, _channel} =
      Ryker.ConversationRef.parse_slack(entry.destination_conversation_ref)

    attributes = entry |> Map.from_struct() |> Map.drop([:__meta__, :inserted_at, :updated_at])

    fingerprint = CanonicalJSON.digest(["sibling", id])

    attributes =
      Map.merge(attributes, %{
        id: id,
        decision_ref: "sibling:" <> id,
        dedupe_key: "sibling:" <> id,
        event_ref: "sibling:" <> id,
        event_fingerprint: fingerprint,
        native_input_id: "sibling:" <> id,
        source_item_ref: "sibling:" <> id,
        destination_conversation_ref: "slack:#{workspace}:CSIBLING"
      })

    sibling = Ingress.Inbox.Entry |> struct!(attributes) |> Repo.insert!()
    assert Repo.transaction(fn -> Observations.receive_in_transaction(sibling) end) == {:ok, :ok}
    sibling
  end

  defp public_channels!(entry, sibling) do
    now = Repo.now!()

    for conversation <- [entry.destination_conversation_ref, sibling.destination_conversation_ref] do
      {:ok, workspace, channel} = Ryker.ConversationRef.parse_slack(conversation)

      Repo.insert!(%Slack.ChannelMembership{
        workspace_ref: workspace,
        channel_ref: channel,
        status: :joined,
        private: false,
        external_shared: false,
        generation: 1,
        joined_at: now
      })
    end
  end

  defp with_locked_fact(fact, callback) do
    parent = self()

    locker =
      unboxed_task(fn ->
        Repo.transaction(fn ->
          fact.id
          |> People.PersonFact.Query.by_id()
          |> People.PersonFact.Query.lock_for_update()
          |> Repo.fetch!()

          send(parent, :fact_locked)
          receive do: (:release -> :ok)
        end)
      end)

    try do
      assert_receive :fact_locked, 5_000
      callback.()
    after
      send(locker.pid, :release)
      Task.await(locker, 5_000)
      stop_tasks([locker])
    end
  end
end
