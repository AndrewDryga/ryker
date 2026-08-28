defmodule Responder.Work.CustodyConcurrencyTest do
  use Responder.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Responder.Episodes
  alias Responder.Episodes.{Episode, Event}
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Repo
  alias Responder.Work.{Custody, Session, Turn}

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "simultaneous workers cannot own the same logical turn" do
    # A process crash can release many queued episodes at once. Competing pool
    # workers must converge on one fenced owner without duplicating the turn.
    Sandbox.unboxed_run(Repo, fn ->
      command = create_episode!()
      parent = self()

      contenders =
        Enum.map(1..2, fn index ->
          unboxed_task(fn ->
            send(parent, {:ready, self()})

            receive do
              :claim -> Custody.claim_next("worker:#{index}", 60)
            end
          end)
        end)

      try do
        Enum.each(contenders, fn contender ->
          contender_pid = contender.pid
          assert_receive {:ready, ^contender_pid}, 5_000
        end)

        Enum.each(contenders, &send(&1.pid, :claim))
        results = Enum.map(contenders, &Task.await(&1, 5_000))

        claims = for {:ok, %{turn: claimed}} <- results, do: claimed

        assert length(claims) == 1
        assert Enum.count(results, &(&1 == {:ok, nil})) == 1
        assert Repo.aggregate(Turn, :count) == 1
        assert Repo.aggregate(Session, :count) == 1
      after
        stop_tasks(contenders)
        cleanup(command)
      end
    end)
  end

  defp create_episode! do
    suffix = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "work-concurrency:#{suffix}",
        native_input_id: "source:#{suffix}",
        occurred_at: @now,
        turn_ref: "turn:#{suffix}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(command.episode_id, "work-read-only", String.duplicate("a", 64))

    command
  end

  defp cleanup(command) do
    Repo.delete_all(from(turn in Turn, where: turn.episode_id == ^command.episode_id))
    Repo.delete_all(from(session in Session, where: session.episode_id == ^command.episode_id))
    Repo.delete_all(from(event in Event, where: event.episode_id == ^command.episode_id))
    Repo.delete_all(from(episode in Episode, where: episode.id == ^command.episode_id))
  end
end
