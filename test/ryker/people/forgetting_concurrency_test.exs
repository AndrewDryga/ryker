defmodule Ryker.People.ForgettingConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.AdvisoryLock
  alias Ryker.Fixtures.People, as: PeopleFixtures
  alias Ryker.People
  alias Ryker.Repo

  # Pause a real INSERT after its eligibility read using an uncommitted unique
  # index contender. It rolls back; the concurrent learn and forget are real.
  # A forget that only updated existing rows let the late insert resurrect a fact.
  for existing <- [false, true] do
    test "forgetting an #{if existing, do: "existing", else: "empty"} profile includes a fact already in flight" do
      Sandbox.unboxed_run(Repo, fn ->
        context = PeopleFixtures.retained_context!()

        try do
          [birthday | _] = context.items
          if unquote(existing), do: learn!(context, birthday)
          replay = Map.put(birthday, "key", "birth-date")
          parent = self()
          blocker = insert_barrier(parent, context, replay)

          try do
            assert_receive {:index_held, blocker_backend}, 5_000

            learner =
              unboxed_task(fn ->
                send(parent, {:learner_started, backend_pid()})
                Repo.transaction(fn -> People.learn_in_transaction([replay], context.entries) end)
              end)

            try do
              assert_receive {:learner_started, learner_backend}, 5_000
              await_blocked_by(learner_backend, blocker_backend)

              forgetter =
                unboxed_task(fn ->
                  send(parent, {:forget_started, backend_pid()})
                  People.forget_person(context.person)
                end)

              try do
                assert_receive {:forget_started, forget_backend}, 5_000
                await_finished_or_blocked(forgetter, forget_backend, learner_backend)
                send(blocker.pid, :release)
                assert Task.await(blocker, 5_000) == {:error, :insert_barrier}
                assert Task.await(learner, 5_000) == {:ok, :ok}
                assert {:ok, count} = Task.await(forgetter, 5_000)
                assert People.facts(context.person) == []
                assert count == if(unquote(existing), do: 2, else: 1)
              after
                stop_tasks([forgetter])
              end
            after
              stop_tasks([learner])
            end
          after
            send(blocker.pid, :release)
            stop_tasks([blocker])
          end
        after
          PeopleFixtures.cleanup!(context)
        end
      end)
    end
  end

  # Locking the selected row first would take the later key before its copy,
  # the reverse of source withdrawal, and deadlock the two privacy operations.
  test "forgetting identical sentences follows source withdrawal's row lock order" do
    Sandbox.unboxed_run(Repo, fn ->
      context = PeopleFixtures.retained_context!()

      try do
        [birthday | _] = context.items
        learn!(context, birthday)
        duplicate = Map.put(birthday, "key", "birth-date")
        learn!(context, duplicate)
        facts = People.facts(context.person)
        selected = Enum.find(facts, &(&1.key == "birthday"))
        earlier = Enum.find(facts, &(&1.key == "birth-date"))
        parent = self()

        withdrawer =
          unboxed_task(fn ->
            database_result(fn ->
              Repo.transaction(fn ->
                Repo.query!("SET LOCAL deadlock_timeout = '50ms'")

                earlier.id
                |> People.PersonFact.Query.by_id()
                |> People.PersonFact.Query.lock_for_update()
                |> Repo.fetch!()

                send(parent, {:earlier_key_locked, backend_pid()})
                receive do: (:withdraw -> :ok)
                People.forget_message_in_transaction(earlier.source_message_ref)
              end)
            end)
          end)

        try do
          assert_receive {:earlier_key_locked, blocking}, 5_000

          forgetter =
            unboxed_task(fn ->
              database_result(fn ->
                send(parent, {:forget_started, backend_pid()})
                People.forget_fact(selected.id)
              end)
            end)

          try do
            assert_receive {:forget_started, backend}, 5_000
            await_finished_or_blocked(forgetter, backend, blocking)
            send(withdrawer.pid, :withdraw)
            assert Task.await(withdrawer, 5_000) == {:ok, :ok}
            assert {:ok, _count} = Task.await(forgetter, 5_000)
            assert People.facts(context.person) == []
          after
            stop_tasks([forgetter])
          end
        after
          send(withdrawer.pid, :withdraw)
          stop_tasks([withdrawer])
        end
      after
        PeopleFixtures.cleanup!(context)
      end
    end)
  end

  # Source deletion may erase the selected row while Forget waits for the
  # person mutex. Losing that content hint left its independent copy usable.
  for all_copies <- [false, true] do
    test "source deletion of #{if all_copies, do: "all", else: "one"} copies cannot defeat a waiting Forget" do
      Sandbox.unboxed_run(Repo, fn ->
        context = PeopleFixtures.retained_context!()

        try do
          [birthday | _] = context.items
          original = Enum.find(context.entries, &(&1.id == birthday["source_input_id"]))
          selected_source = PeopleFixtures.later_entry!(context, original, 60)
          other_source = PeopleFixtures.later_entry!(context, original, -60)
          unlearned_source = PeopleFixtures.later_entry!(context, original, 30)
          selected_item = Map.put(birthday, "source_input_id", selected_source.id)

          duplicate =
            birthday
            |> Map.put("key", "birth-date")
            |> Map.put("source_input_id", other_source.id)

          selected_context = %{context | entries: [selected_source]}
          learn!(selected_context, selected_item)
          other_context = %{context | entries: [other_source]}
          learn!(other_context, duplicate)
          selected = Enum.find(People.facts(context.person), &(&1.key == "birthday"))
          parent = self()

          blocker =
            unboxed_task(fn ->
              Repo.transaction(fn ->
                AdvisoryLock.hold!("person-facts:" <> context.person)
                send(parent, {:person_locked, backend_pid()})
                receive do: (:release -> :ok)
              end)
            end)

          try do
            assert_receive {:person_locked, blocking}, 5_000

            forgetter =
              unboxed_task(fn ->
                send(parent, {:forget_started, backend_pid()})
                People.forget_fact(selected.id)
              end)

            try do
              assert_receive {:forget_started, backend}, 5_000
              await_blocked_by(backend, blocking)

              assert Repo.transaction(fn ->
                       People.forget_message_in_transaction(selected_source.native_input_id)

                       if unquote(all_copies),
                         do: People.forget_message_in_transaction(other_source.native_input_id)

                       :ok
                     end) == {:ok, :ok}

              if unquote(all_copies) do
                assert People.facts(context.person) == []
              else
                assert [%{key: "birth-date"}] = People.facts(context.person)
              end

              send(blocker.pid, :release)
              assert Task.await(blocker, 5_000) == {:ok, :ok}
              result = Task.await(forgetter, 5_000)
              assert People.facts(context.person) == []
              assert result == {:ok, if(unquote(all_copies), do: 0, else: 1)}

              # This source predates the selected statement but is ahead of the
              # database clock. Its first learning still belongs before Forget.
              replay =
                birthday
                |> Map.put("key", "archived-birthday")
                |> Map.put("source_input_id", unlearned_source.id)

              replay_context = %{context | entries: [unlearned_source]}
              learn!(replay_context, replay)
              assert People.facts(context.person) == []
            after
              stop_tasks([forgetter])
            end
          after
            send(blocker.pid, :release)
            stop_tasks([blocker])
          end
        after
          PeopleFixtures.cleanup!(context)
        end
      end)
    end
  end

  defp database_result(fun) do
    fun.()
  rescue
    error in Postgrex.Error -> {:error, error.postgres.code}
  end

  defp insert_barrier(parent, context, item) do
    source = Enum.find(context.entries, &(&1.id == item["source_input_id"]))

    unboxed_task(fn ->
      Repo.transaction(fn ->
        Repo.insert!(%People.PersonFact{
          person_ref: context.person,
          key: item["key"],
          fact: item["fact"],
          status: :kept,
          source_input_id: source.id,
          source_message_ref: source.native_input_id,
          conversation_ref: source.destination_conversation_ref,
          private: true,
          said_at: source.occurred_at
        })

        send(parent, {:index_held, backend_pid()})
        receive do: (:release -> Repo.rollback(:insert_barrier))
      end)
    end)
  end

  defp learn!(context, item) do
    assert Repo.transaction(fn ->
             People.learn_in_transaction([item], context.entries)
           end) == {:ok, :ok}
  end
end
