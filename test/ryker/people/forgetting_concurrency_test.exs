defmodule Ryker.People.ForgettingConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
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
