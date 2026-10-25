defmodule Ryker.Behaviors.GuidanceSnapshotConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.{Behaviors, Episodes, Ingress, Memories, Records, Repo, Slack, Work}
  alias Ryker.Fixtures.Corrections
  alias Ryker.Knowledge.KnowledgeSnapshot
  alias Ryker.Records.DerivedContext
  alias Ryker.StateTools.FixedTools

  # A saved workspace rule may come from another channel. Fencing only its
  # destination leaves the source row locked before a later source check,
  # reversing channel deletion's order when preferences share that source.
  test "cross-channel guidance fences its source before taking behavior rows" do
    Sandbox.unboxed_run(Repo, fn ->
      {correction, claim, saved} = guidance!()
      workspace = correction.entry.source_ref
      origin = Ryker.ConversationRef.slack(workspace, "C2")
      behavior = saved["behavior_ref"] |> Behaviors.Behavior.Query.by_ref() |> Repo.fetch!()

      payload =
        Map.merge(behavior.payload, %{"scope" => "workspace", "visibility" => "workspace"})

      behavior =
        behavior
        |> Ecto.Changeset.change(
          scope_kind: :workspace,
          scope_ref: behavior.workspace_ref,
          source_conversation_ref: origin,
          payload: payload
        )
        |> Repo.update!()

      document = Behaviors.Recall.guidance_document(behavior)
      submission = %{"context" => %{"operator_context" => %{"guidance" => [document]}}}
      claim = %{claim | turn: %{claim.turn | submission: submission}}
      parent = self()

      deleter =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            :ok = Slack.ChannelFence.lock_in_transaction(workspace, "C2")
            send(parent, {:source_locked, backend_pid()})
            receive do: (:redact -> :ok)
            Memories.Reviews.delete_slack_channel_in_transaction(workspace, "C2")
          end)
        end)

      try do
        assert_receive {:source_locked, blocking}, 5_000

        reader =
          unboxed_task(fn ->
            send(parent, {:reader_started, backend_pid()})

            KnowledgeSnapshot.authorize_submission(
              claim.episode,
              claim.session,
              claim.turn.submission
            )
          end)

        try do
          assert_receive {:reader_started, backend}, 5_000
          assert await_finished_or_blocked(reader, backend, blocking) == :waiting
          send(deleter.pid, :redact)
          assert Task.await(deleter, 5_000) == {:ok, :ok}
          # Explicit workspace guidance remains a saved copy when its source
          # channel goes; synchronization must not revoke that separate scope.
          assert Task.await(reader, 5_000) == :ok
        after
          stop_tasks([reader])
        end
      after
        send(deleter.pid, :redact)
        stop_tasks([deleter])
        Repo.delete_all(Behaviors.Behavior.Query.by_id(behavior.id))
        cleanup!(correction)
      end
    end)
  end

  # Review found that a saved guidance read could hold Behavior while waiting
  # for channel deletion, which held the channel while waiting for Behavior.
  test "guidance authorization waits outside the rows a channel deletion must redact" do
    Sandbox.unboxed_run(Repo, fn ->
      {correction, claim, _saved} = guidance!()
      parent = self()

      deleter =
        unboxed_task(fn ->
          safely(fn ->
            Repo.transaction(fn ->
              Repo.query!("SET LOCAL deadlock_timeout = '50ms'")
              workspace = correction.entry.source_ref
              :ok = Slack.ChannelFence.lock_in_transaction(workspace, "C1")
              send(parent, {:channel_locked, backend_pid()})
              receive do: (:redact -> :ok)
              Memories.Reviews.delete_slack_channel_in_transaction(workspace, "C1")
            end)
          end)
        end)

      assert_receive {:channel_locked, deleter_backend}, 5_000

      reader =
        unboxed_task(fn ->
          send(parent, {:reader_started, backend_pid()})

          safely(fn ->
            KnowledgeSnapshot.authorize_submission(
              claim.episode,
              claim.session,
              claim.turn.submission
            )
          end)
        end)

      try do
        assert_receive {:reader_started, reader_backend}, 5_000
        await_blocked_by(reader_backend, deleter_backend)
        send(deleter.pid, :redact)
        assert Task.await(deleter, 5_000) == {:ok, :ok}
        assert Task.await(reader, 5_000) == {:error, :work_knowledge_context_stale}
      after
        send(deleter.pid, :redact)
        stop_tasks([deleter, reader])
        cleanup!(correction)
      end
    end)
  end

  # A recall's accounting update must make optional history yield, not abort
  # its outer transaction or make a frozen/native transcript look withdrawn.
  test "busy guidance yields optional history and preserves the native session" do
    Sandbox.unboxed_run(Repo, fn ->
      {correction, claim, saved} = guidance!()
      assert KnowledgeSnapshot.expose_submission(claim) == :ok
      offer = Repo.fetch!(Records.Record.Query.by_ref(saved["record_ref"]))

      assert {:ok, record} =
               Records.create(
                 Records.token(claim.turn),
                 "guidance-history",
                 "guidance_offer",
                 offer.payload
               )

      document = record |> Records.Record.document() |> DerivedContext.record()
      parent = self()

      updater =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            saved["behavior_ref"]
            |> Behaviors.Behavior.Query.by_ref()
            |> Behaviors.Behavior.Query.lock_for_update()
            |> Repo.fetch!()

            send(parent, :guidance_locked)
            receive do: (:release -> :ok)
          end)
        end)

      try do
        assert_receive :guidance_locked, 5_000

        assert KnowledgeSnapshot.authorize_submission(
                 claim.episode,
                 claim.session,
                 claim.turn.submission
               ) ==
                 {:error, :work_derived_context_busy}

        assert KnowledgeSnapshot.authorize_session(claim.episode, claim.session) ==
                 {:error, :work_derived_context_busy}

        assert Records.model_records(claim.episode, claim.session) == []

        assert Repo.transaction(fn ->
                 DerivedContext.resolve(
                   [document],
                   claim.episode,
                   claim.session.repository_ref,
                   claim.session
                 )
               end) == {:ok, {:error, :work_derived_context_busy}}

        send(updater.pid, :release)
        assert Task.await(updater, 5_000) == {:ok, :ok}
        assert KnowledgeSnapshot.authorize_session(claim.episode, claim.session) == :ok
        assert Records.model_records(claim.episode, claim.session) != []
      after
        send(updater.pid, :release)
        stop_tasks([updater])
        cleanup!(correction)
      end
    end)
  end

  defp guidance! do
    correction = Corrections.correction!()

    assert {:ok, saved} =
             FixedTools.call("remember_correction", correction.arguments,
               binding: correction.binding,
               answer_authorizer: fn _ -> true end
             )

    claim = Corrections.later!(correction)
    guidance = get_in(claim.turn.submission, ["context", "operator_context", "guidance"])
    submission = %{"context" => %{"operator_context" => %{"guidance" => guidance}}}
    {correction, %{claim | turn: %{claim.turn | submission: submission}}, saved}
  end

  defp safely(fun) do
    fun.()
  rescue
    error in Postgrex.Error -> {:database_error, error.postgres.code}
  end

  defp cleanup!(correction) do
    conversation = correction.entry.destination_conversation_ref

    ids =
      Repo.all(
        from(e in Episodes.Episode,
          where: e.destination_conversation_ref == ^conversation,
          select: e.id
        )
      )

    Repo.delete_all(
      from(b in Behaviors.Behavior, where: b.source_conversation_ref == ^conversation)
    )

    Repo.delete_all(from(r in Records.Record, where: r.episode_id in ^ids))

    delete_entries!(
      from(e in Ingress.Inbox.Entry, where: e.destination_conversation_ref == ^conversation)
    )

    Repo.delete_all(from(t in Work.Turn, where: t.episode_id in ^ids))
    Repo.delete_all(from(s in Work.Session, where: s.episode_id in ^ids))
    Repo.delete_all(from(e in Episodes.Event, where: e.episode_id in ^ids))
    Repo.delete_all(from(e in Episodes.Episode, where: e.id in ^ids))

    Repo.delete_all(
      from(m in Slack.ChannelMembership, where: m.workspace_ref == ^correction.entry.source_ref)
    )
  end
end
