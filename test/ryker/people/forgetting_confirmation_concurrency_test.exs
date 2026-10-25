defmodule Ryker.People.ForgettingConfirmationConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.AdvisoryLock
  alias Ryker.CanonicalJSON
  alias Ryker.Fixtures.People, as: PeopleFixtures
  alias Ryker.People
  alias Ryker.Repo

  # Checking the quoted row before waiting is insufficient: learning can
  # replace its words while holding the person lock that Forget needs next.
  test "a replacement committed while Forget waits keeps its unconfirmed words" do
    Sandbox.unboxed_run(Repo, fn ->
      context = PeopleFixtures.retained_context!()

      try do
        [original, replacement | _] = context.items
        source = Enum.find(context.entries, &(&1.id == replacement["source_input_id"]))
        later = PeopleFixtures.later_entry!(context, source, 60)

        replacement =
          replacement |> Map.put("key", original["key"]) |> Map.put("source_input_id", later.id)

        assert Repo.transaction(fn ->
                 People.learn_in_transaction([original], context.entries)
               end) == {:ok, :ok}

        [selected] = People.facts(context.person)
        parent = self()

        learner =
          unboxed_task(fn ->
            Repo.transaction(fn ->
              AdvisoryLock.hold!("person-facts:" <> context.person)
              send(parent, {:person_locked, backend_pid()})
              receive do: (:replace -> :ok)
              People.learn_in_transaction([replacement], [later])
            end)
          end)

        try do
          assert_receive {:person_locked, blocking}, 5_000

          forgetter =
            unboxed_task(fn ->
              send(parent, {:forget_started, backend_pid()})
              expected_digest = CanonicalJSON.digest(selected.fact)
              People.forget_fact(selected.id, expected_digest)
            end)

          try do
            assert_receive {:forget_started, backend}, 5_000
            await_blocked_by(backend, blocking)
            send(learner.pid, :replace)
            assert Task.await(learner, 5_000) == {:ok, :ok}
            result = Task.await(forgetter, 5_000)

            assert People.about(context.person, context.conversation) == [replacement["fact"]]
            assert result == {:error, :confirmation_stale}
          after
            stop_tasks([forgetter])
          end
        after
          send(learner.pid, :replace)
          stop_tasks([learner])
        end
      after
        PeopleFixtures.cleanup!(context)
      end
    end)
  end
end
