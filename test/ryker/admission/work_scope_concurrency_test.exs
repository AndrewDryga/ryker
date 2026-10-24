defmodule Ryker.Admission.WorkScopeConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Admission
  alias Ryker.Admission.Decision
  alias Ryker.Episodes
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.Repo
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.Work.Session

  @fixture Path.expand("fixtures/history_authorization/cross_channel_health_check.json", __DIR__)

  test "a concurrent account refresh cannot change a validated continuation's scope" do
    # The misrouted health check reused another account. A retry refreshes an
    # unstarted session under its episode lock; admission must recheck after
    # obtaining that lock, even if its earlier validation already succeeded.
    Sandbox.unboxed_run(Repo, fn ->
      fixture = @fixture |> File.read!() |> Jason.decode!()
      workspace = "TSCOPE#{System.unique_integer([:positive])}"
      original = input!(fixture["active"], workspace)
      document = Map.put(fixture["incoming"], "channel_ref", fixture["active"]["channel_ref"])
      incoming = input!(document, workspace)
      assert {:ok, %{entry: entry}} = Inbox.record(incoming)
      id = Repo.generate_id()

      command =
        EpisodeFixtures.admit_input(%{
          actor_ref: Input.actor_ref(original),
          destination: original.destination,
          episode_id: id,
          episode_key: "scope-race:#{id}",
          native_input_id: original.native_input_id,
          occurred_at: original.occurred_at,
          payload: Input.document(original),
          revision: original.revision,
          turn_ref: "scope-turn:#{id}"
        })

      assert {:ok, _transition} = Episodes.apply(command)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from(session in Session, where: session.episode_id == ^id))
          Repo.delete_all(from(event in Event, where: event.episode_id == ^id))
          Repo.delete_all(from(episode in Episode, where: episode.id == ^id))
          delete_entries!(from(entry_row in Inbox.Entry, where: entry_row.id == ^entry.id))
        end)
      end)

      session =
        Repo.insert!(%Session{
          episode_id: id,
          external_ref: "scope-race-session:#{id}",
          policy: "recorded-scope",
          policy_digest: String.duplicate("a", 64)
        })

      assert {:ok, context} =
               Admission.context(Inbox.ref(entry),
                 now: incoming.occurred_at,
                 continuation_window: 1_800,
                 history_window: 2_592_000,
                 candidate_limit: 8
               )

      assert candidate = Enum.find(context.candidates, &(&1.episode.id == id))

      assert {:ok, decision} =
               fixture["decision"] |> Map.put("episode_ref", candidate.ref) |> Decision.parse()

      parent = self()

      blocker =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            :ok = Episodes.ConversationLock.lock(incoming.destination)
            send(parent, {:conversation_locked, backend_pid()})

            receive do
              :release -> :ok
            end
          end)
        end)

      admission =
        unboxed_task(fn ->
          receive do
            :admit -> :ok
          end

          send(parent, {:admitting, backend_pid()})
          Admission.commit(context, decision, "scope-race-commit")
        end)

      try do
        assert_receive {:conversation_locked, blocking_backend}, 5_000
        send(admission.pid, :admit)
        assert_receive {:admitting, admission_backend}, 5_000
        await_blocked_by(admission_backend, blocking_backend)

        assert Repo.transaction(fn ->
                 assert {:ok, _episode} =
                          Episodes.fetch_and_lock_current_in_transaction(command.episode_key)

                 session
                 |> Ecto.Changeset.change(emisar_connection_ref: "refreshed-account")
                 |> Repo.update!()
               end)
               |> elem(0) == :ok

        send(blocker.pid, :release)
        assert Task.await(blocker, 5_000) == {:ok, :ok}

        assert Task.await(admission, 5_000) ==
                 {:error, {:admission_rejected, :work_scope_not_allowed}}

        assert Repo.get!(Inbox.Entry, entry.id).status == :pending
        assert Repo.aggregate(from(event in Event, where: event.episode_id == ^id), :count) == 1
      after
        send(blocker.pid, :release)
        stop_tasks([blocker, admission])
      end
    end)
  end

  defp input!(document, workspace) do
    {:ok, occurred_at, 0} = DateTime.from_iso8601(document["occurred_at"])

    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: document["actor"]["ref"]},
               channel_ref: document["channel_ref"],
               content: document["content"],
               event_kind: :message,
               event_ref: document["event_ref"],
               message_ref: document["message_ref"],
               occurred_at: occurred_at,
               revision: document["revision"],
               thread_ref: document["thread_ref"],
               workspace_ref: workspace
             })

    input
  end
end
