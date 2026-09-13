defmodule Ryker.State.DerivedContextConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.{Episodes, Repo}
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.State.KnowledgeSnapshot
  alias Ryker.Work.{Custody, Session, Turn}

  test "reciprocal producer reads yield while busy without deadlocking or invalidating custody" do
    # Two reopened episodes may recall each other's history. Holding the
    # receiver UPDATE lock and waiting on a producer SHARE lock would cycle.
    Sandbox.unboxed_run(Repo, fn ->
      left = fixture!()
      right = fixture!()
      parent = self()
      readers = [reader(parent, left, right), reader(parent, right, left)]

      try do
        for task <- readers,
            do: assert_receive({:receiver_locked, pid} when pid == task.pid, 5_000)

        Enum.each(readers, &send(&1.pid, :read_producer))

        for task <- readers do
          assert_receive {:producer_result, pid, {:error, :work_derived_context_busy}}
                         when pid == task.pid,
                         5_000
        end

        Enum.each(readers, &send(&1.pid, :release))
        Enum.each(readers, &Task.await/1)

        for claim <- [left, right] do
          assert {:ok, []} =
                   Repo.transaction(fn ->
                     KnowledgeSnapshot.producer_sources(
                       claim.episode,
                       Repo.get!(Session, claim.session.id)
                     )
                   end)

          assert :ok = KnowledgeSnapshot.authorize_session(claim.episode, claim.session)
          assert Repo.get!(Session, claim.session.id).source_exposure_count == 0
        end
      after
        stop_tasks(readers)
        cleanup(left)
        cleanup(right)
      end
    end)
  end

  defp reader(parent, receiver, producer) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        Repo.one!(from(s in Session, where: s.id == ^receiver.session.id, lock: "FOR UPDATE"))
        send(parent, {:receiver_locked, self()})
        receive do: (:read_producer -> :ok)

        result =
          KnowledgeSnapshot.producer_sources(
            receiver.episode,
            Repo.get!(Session, producer.session.id)
          )

        send(parent, {:producer_result, self(), result})
        receive do: (:release -> :ok)
      end)
    end)
  end

  defp fixture! do
    id = Ecto.UUID.generate()

    {:ok, _} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: id,
          episode_key: "derived-lock:#{id}",
          native_input_id: "derived-lock-input:#{id}",
          turn_ref: "derived-lock-turn:#{id}"
        })
      )

    {:ok, _} = Custody.pin_episode(id, "fixture", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("worker:#{id}", 60)
    assert claim.episode.id == id
    assert :ok = KnowledgeSnapshot.expose(claim, [])
    claim
  end

  defp cleanup(claim) do
    Repo.delete_all(from(t in Turn, where: t.episode_id == ^claim.episode.id))
    Repo.delete_all(from(s in Session, where: s.episode_id == ^claim.episode.id))
    Repo.delete_all(from(e in Event, where: e.episode_id == ^claim.episode.id))
    Repo.delete_all(from(e in Episode, where: e.id == ^claim.episode.id))
  end
end
