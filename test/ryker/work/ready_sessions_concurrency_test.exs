defmodule Ryker.Work.ReadySessionsConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Episodes.Episode
  alias Ryker.Repo
  alias Ryker.Work.{ReadySessions, Session}

  @policy "work-read-only"
  @digest String.duplicate("a", 64)

  # Messages that start conversations arrive together, and each conversation's
  # episode is pinned in its own transaction. Two of them taking the same
  # session kept ready would run two conversations in one Coop session; the
  # claim is the only thing standing between them.
  test "conversations pinned at the same moment never take the same session kept ready" do
    Sandbox.unboxed_run(Repo, fn ->
      episodes = Enum.map(1..2, &insert_episode!/1)
      ready = insert_ready!()
      parent = self()

      contenders =
        Enum.map(episodes, fn episode ->
          unboxed_task(fn ->
            send(parent, {:ready, self()})

            receive do
              :claim ->
                Repo.transaction(fn ->
                  ReadySessions.claim_in_transaction(episode.id, pin(), nil)
                end)
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

        assert [{:ok, {:ok, %Session{id: claimed}}}] =
                 Enum.filter(results, &match?({:ok, {:ok, _session}}, &1))

        assert claimed == ready.id
        assert Enum.count(results, &(&1 == {:ok, :none})) == 1

        assert %Session{ready_state: :claimed, episode_id: owner} = Repo.get!(Session, ready.id)
        assert owner in Enum.map(episodes, & &1.id)
      after
        stop_tasks(contenders)
        Repo.delete_all(from(session in Session, where: session.id == ^ready.id))

        Repo.delete_all(
          from(episode in Episode, where: episode.id in ^Enum.map(episodes, & &1.id))
        )
      end
    end)
  end

  defp pin do
    ReadySessions.pin(
      %{
        authority_digest: nil,
        environment_ref: nil,
        policy: @policy,
        policy_digest: @digest,
        repository_context: nil,
        repository_ref: nil,
        repository_source: nil
      },
      nil
    )
  end

  defp insert_ready! do
    id = Ecto.UUID.generate()
    now = Repo.now!()

    Repo.insert!(%Session{
      cleanup_status: :active,
      coop_session_id: "coop-work-ready-#{id}",
      execution_kind: :work,
      external_ref: ReadySessions.external_ref(id),
      generation: 1,
      id: id,
      inserted_at: now,
      policy: @policy,
      policy_digest: @digest,
      ready_state: :ready,
      updated_at: now
    })
  end

  defp insert_episode!(index) do
    now = Repo.now!()

    Repo.insert!(%Episode{
      id: Ecto.UUID.generate(),
      key: "ingress-input:work-ready-race-#{index}:#{Ecto.UUID.generate()}",
      state: :working,
      destination_transport: "slack",
      destination_conversation_ref: "slack:T123:C70#{index}",
      inserted_at: now,
      updated_at: now
    })
  end
end
