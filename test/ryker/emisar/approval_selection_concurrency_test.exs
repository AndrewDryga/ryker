defmodule Ryker.Emisar.ApprovalSelectionConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.{CanonicalJSON, Emisar, Episodes, Records, Repo, Settings, Work}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions

  # A cursor holds the eligibility snapshot before a concurrent renewal and
  # fetches the later row after it commits. Locking must recheck the current
  # lease, or a stale candidate can be closed or leased by another observer.
  for {mode, change} <- [
        cleanup: :lease,
        cleanup: :closed,
        observation: :lease,
        observation: :closed,
        observation: :backoff
      ] do
    test "#{mode} selection refuses #{change} changes after its eligibility snapshot" do
      Sandbox.unboxed_run(Repo, fn ->
        connection = "selection-#{Ecto.UUID.generate()}"
        first_id = Ecto.UUID.generate()
        second_id = Ecto.UUID.generate()

        try do
          Repo.insert!(%Settings.EmisarConnection{
            ref: connection,
            display_name: "Selection test",
            rpc_url: "https://emisar.example/mcp",
            account_ref: connection,
            verified_at: Repo.now!()
          })

          first = watch!(connection, unquote(mode), first_id)
          second = watch!(connection, unquote(mode), second_id)
          reader = selection_reader(self(), unquote(mode), connection)

          try do
            assert_receive {:first_selected, selected_id}, 5_000
            assert selected_id == first.approval.id

            attributes = concurrent_change(unquote(change), second.approval.id, Repo.now!())

            second.approval
            |> Ecto.Changeset.change(attributes)
            |> Repo.update!()

            send(reader.pid, :continue)
            assert Task.await(reader, 5_000) == {:ok, [first.approval.id]}
          after
            send(reader.pid, :continue)
            stop_tasks([reader])
          end
        after
          cleanup!(first_id)
          cleanup!(second_id)
          Repo.delete_all(from(c in Settings.EmisarConnection, where: c.ref == ^connection))
        end
      end)
    end
  end

  defp concurrent_change(:lease, id, now),
    do: %{
      lease_ref: "renewed:#{id}",
      lease_owner: "in-flight-observer",
      lease_expires_at: DateTime.add(now, 60, :second)
    }

  defp concurrent_change(:closed, _id, now),
    do: %{status: :closed, closed_at: now, closed_reason: :wait_ended}

  defp concurrent_change(:backoff, _id, now),
    do: %{next_attempt_at: DateTime.add(now, 60, :second)}

  defp selection_reader(parent, mode, connection) do
    unboxed_task(fn ->
      Repo.transaction(fn -> read_selection(parent, mode, connection) end)
    end)
  end

  defp read_selection(parent, mode, connection) do
    # Expand the batch only to expose the snapshot/lock boundary;
    # the production predicate and locking clause stay unchanged.
    query = selection(mode, connection, Repo.now!())
    query = Ecto.Query.exclude(query, :limit)

    query
    |> Repo.stream(max_rows: 1)
    |> Enum.reduce([], fn approval, ids ->
      pause_after_first(ids, approval.id, parent)
      ids ++ [approval.id]
    end)
  end

  defp pause_after_first([], id, parent) do
    send(parent, {:first_selected, id})
    receive do: (:continue -> :ok)
  end

  defp pause_after_first(_ids, _id, _parent), do: :ok

  defp selection(:cleanup, connection, now), do: Emisar.Approval.Query.next_ended(connection, now)

  defp selection(:observation, connection, now),
    do: Emisar.Approval.Query.next_claimable(connection, now)

  # The run identity comes from the harvested approval lifecycle fixture;
  # ownership rows and isolation identifiers are structural host custody.
  defp watch!(connection, mode, id) do
    fixture =
      File.read!("test/ryker/emisar/fixtures/approval_finished_before_result.json")
      |> Jason.decode!()

    run = fixture["run"]

    assert {:ok, _} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: id,
                 episode_key: "approval-selection:#{id}",
                 native_input_id: "approval-selection:#{id}",
                 turn_ref: "approval-selection:#{id}"
               })
             )

    assert {:ok, _} =
             WorkSessions.pin_episode(id, "approval-selection", String.duplicate("a", 64))

    assert {:ok, claim} = Work.Custody.claim_next("approval-selection:#{id}", 60, :work)
    assert claim.episode.id == id
    turn = claim.turn
    ref = "record:emisar_approval:#{id}"

    record =
      %{
        id: Ecto.UUID.generate(),
        episode_id: id,
        turn_id: turn.id,
        ref: ref,
        operation_id: "selection:#{id}",
        kind: "emisar_approval",
        status: if(mode == :cleanup, do: :answered, else: :open),
        payload: run,
        payload_fingerprint: CanonicalJSON.digest(run)
      }
      |> Records.Record.Changeset.insert()
      |> Repo.insert!()

    approval =
      %{
        id: Ecto.UUID.generate(),
        episode_id: id,
        record_id: record.id,
        action_id: run["action_id"],
        connection_ref: connection,
        expires_at: ~U[2099-08-29 12:00:00.000000Z],
        operation_id: "selection:#{id}",
        pack_ref: run["pack_ref"],
        remote_status: "pending_approval",
        request_id: "apr-#{id}",
        run_id: "run-#{id}",
        runner_ref: run["runner_ref"],
        status: :monitoring,
        approval_url: "https://emisar.example/app/tenant/approvals/apr-#{id}"
      }
      |> Emisar.Approval.Changeset.insert()
      |> Repo.insert!()

    %{approval: approval, episode_id: id}
  end

  defp cleanup!(id) do
    Repo.delete_all(from(a in Emisar.Approval, where: a.episode_id == ^id))
    Repo.delete_all(from(r in Records.Record, where: r.episode_id == ^id))
    Repo.delete_all(from(t in Work.Turn, where: t.episode_id == ^id))
    Repo.delete_all(from(s in Work.Session, where: s.episode_id == ^id))
    Repo.delete_all(from(e in Episodes.Event, where: e.episode_id == ^id))
    Repo.delete_all(from(e in Episodes.Episode, where: e.id == ^id))
  end
end
