defmodule Ryker.Work.PersonalizationSnapshotConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.{Behaviors, Memories, People, Repo, Slack}
  alias Ryker.Fixtures.Personalization
  alias Ryker.Knowledge.KnowledgeSnapshot

  # Personal context follows the same channel-before-source lock order as
  # deletion. Busy sources must yield without poisoning optional readers.
  for {fixture, kind} <- [personal_context!: :facts, preference_context!: :preferences] do
    test "busy #{kind} yield without losing native custody or aborting an outer transaction" do
      Sandbox.unboxed_run(Repo, fn ->
        {claim, source} = apply(Personalization, unquote(fixture), [])
        parent = self()

        try do
          assert KnowledgeSnapshot.expose_submission(claim) == :ok
          updater = source_locker(parent, unquote(kind), source)

          try do
            assert_receive :source_locked, 5_000

            assert KnowledgeSnapshot.authorize_submission(
                     claim.episode,
                     claim.session,
                     claim.turn.submission
                   ) == {:error, :work_derived_context_busy}

            assert Repo.transaction(fn ->
                     KnowledgeSnapshot.authorize_session(claim.episode, claim.session)
                   end) == {:ok, {:error, :work_derived_context_busy}}

            send(updater.pid, :release)
            assert Task.await(updater, 5_000) == {:ok, :ok}
            assert KnowledgeSnapshot.authorize_session(claim.episode, claim.session) == :ok
          after
            send(updater.pid, :release)
            stop_tasks([updater])
          end
        after
          Personalization.cleanup!(claim)
        end
      end)
    end

    test "#{kind} authorization waits outside the source rows channel deletion must erase" do
      Sandbox.unboxed_run(Repo, fn ->
        {claim, _source} = apply(Personalization, unquote(fixture), [])

        {:ok, workspace, channel} =
          Ryker.ConversationRef.parse_slack(claim.episode.destination_conversation_ref)

        parent = self()
        deleter = channel_deleter(parent, workspace, channel)

        try do
          assert_receive {:channel_locked, blocking}, 5_000
          reader = authorization_reader(parent, claim)

          try do
            assert_receive {:reader_started, backend}, 5_000
            await_blocked_by(backend, blocking)
            send(deleter.pid, :redact)
            assert Task.await(deleter, 5_000) == {:ok, :ok}
            assert Task.await(reader, 5_000) == {:error, :work_knowledge_context_stale}
          after
            stop_tasks([reader])
          end
        after
          send(deleter.pid, :redact)
          stop_tasks([deleter])
          Personalization.cleanup!(claim)
        end
      end)
    end
  end

  defp source_locker(parent, kind, source) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        lock_source!(kind, source.id)
        send(parent, :source_locked)
        receive do: (:release -> :ok)
      end)
    end)
  end

  defp lock_source!(:facts, id) do
    id
    |> People.PersonFact.Query.by_id()
    |> People.PersonFact.Query.lock_for_update()
    |> Repo.fetch!()
  end

  defp lock_source!(:preferences, id) do
    id
    |> Behaviors.Behavior.Query.by_id()
    |> Behaviors.Behavior.Query.lock_for_update()
    |> Repo.fetch!()
  end

  defp channel_deleter(parent, workspace, channel) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL deadlock_timeout = '50ms'")
        :ok = Slack.ChannelFence.lock_in_transaction(workspace, channel)
        send(parent, {:channel_locked, backend_pid()})
        receive do: (:redact -> :ok)
        :ok = Memories.Reviews.delete_slack_channel_in_transaction(workspace, channel)
        People.forget_conversation_in_transaction(Ryker.ConversationRef.slack(workspace, channel))
      end)
    end)
  end

  defp authorization_reader(parent, claim) do
    unboxed_task(fn ->
      send(parent, {:reader_started, backend_pid()})
      KnowledgeSnapshot.authorize_submission(claim.episode, claim.session, claim.turn.submission)
    end)
  end
end
