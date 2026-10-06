defmodule Ryker.PeopleConcurrencyTest do
  @moduledoc """
  Two learning passes that keep one person's fact at the same time.

  A pass read the person's fact under `FOR UPDATE`, which locks nothing when
  the row does not exist yet, so the second pass inserted the same
  `(person_ref, key)` and crashed on the unique index after the first
  committed. The crash rolled back that whole learning pass and spent one of
  its attempts (2026-10-04 review). The cap on kept facts was checked the same
  way.

  These commit for real, on connections of their own, and delete what they
  wrote.
  """
  use Ryker.ConcurrencyCase, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.People
  alias Ryker.People.PersonFact
  alias Ryker.Repo

  test "two passes keeping one person's fact at once both commit, and the later statement wins" do
    actor = "UPEOPLE#{System.unique_integer([:positive])}"
    person = "slack:user:" <> actor

    # A crashed pass takes this process with it, so cleanup cannot wait for an
    # `after`: a left row shows in every other test that lists people.
    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(f in PersonFact, where: f.person_ref == ^person))
      end)
    end)

    Sandbox.unboxed_run(Repo, fn ->
      now = Repo.now!()
      earlier = entry(actor, "earlier", DateTime.add(now, -60, :second))
      later = entry(actor, "later", now)
      parent = self()

      holder =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            :ok = People.learn_in_transaction([item(earlier, "Works on Kyiv time.")], [earlier])
            send(parent, {:holding, backend_pid()})

            receive do
              :release -> :ok
            after
              5_000 -> :ok
            end
          end)
        end)

      assert_receive {:holding, holder_backend}, 5_000

      contender =
        unboxed_task(fn ->
          send(parent, {:contending, backend_pid()})

          Repo.transaction(fn ->
            People.learn_in_transaction([item(later, "Works on Lisbon time.")], [later])
          end)
        end)

      try do
        assert_receive {:contending, contender_backend}, 5_000
        assert :ok = await_blocked_by(contender_backend, holder_backend)

        send(holder.pid, :release)
        assert {:ok, :ok} = Task.await(holder, 5_000)
        assert {:ok, :ok} = Task.await(contender, 5_000)

        assert [%PersonFact{fact: "Works on Lisbon time.", status: :kept}] =
                 Repo.all(from(f in PersonFact, where: f.person_ref == ^person))
      after
        stop_tasks([holder, contender])
      end
    end)
  end

  defp entry(actor, message, occurred_at) do
    %Entry{
      id: Ecto.UUID.generate(),
      actor_kind: :user,
      actor_ref: actor,
      destination_conversation_ref: "slack:TPEOPLE:CPEOPLE",
      native_input_id: "slack-message:people-concurrency:#{actor}:#{message}",
      occurred_at: occurred_at,
      source_kind: "slack"
    }
  end

  defp item(%Entry{id: id}, fact),
    do: %{"source_input_id" => id, "key" => "time-zone", "fact" => fact}
end
