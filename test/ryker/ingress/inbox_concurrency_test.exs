defmodule Ryker.Ingress.InboxConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Admission
  alias Ryker.Admission.Decision
  alias Ryker.Behaviors.StandingRuleInventory
  alias Ryker.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Knowledge.ConversationKnowledge
  alias Ryker.Learning.ConversationObservation
  alias Ryker.Memories.Forgetting
  alias Ryker.Repo
  alias Ryker.Slack.ChannelMembership
  alias Ryker.Slack.Input, as: SlackInput

  @learned_workspace "TLOCKORDER"
  @learned_channel "CLOCKORDER"

  test "simultaneous Slack retries converge on one inbox record" do
    Sandbox.unboxed_run(Repo, fn ->
      event_ref = "Ev-#{Ecto.UUID.generate()}"
      input = input!(event_ref)
      parent = self()
      blocker = lock_task(Input.dedupe_key(input), parent)
      assert_receive {:source_locked, blocker_backend}, 5_000

      contenders =
        Enum.map(1..2, fn _index ->
          unboxed_task(fn ->
            send(parent, {:contender_ready, self(), backend_pid()})
            Inbox.record(input)
          end)
        end)

      contender_backends =
        Enum.map(contenders, fn contender ->
          contender_pid = contender.pid
          assert_receive {:contender_ready, ^contender_pid, backend}, 5_000
          backend
        end)

      try do
        Enum.each(contender_backends, &await_blocked_by(&1, blocker_backend))
        send(blocker.pid, :release)

        statuses =
          contenders
          |> Enum.map(&Task.await(&1, 5_000))
          |> Enum.map(fn {:ok, receipt} -> receipt.status end)
          |> Enum.sort()

        assert statuses == [:duplicate, :recorded]

        assert Repo.aggregate(from(entry in Entry, where: entry.event_ref == ^event_ref), :count) ==
                 1
      after
        send(blocker.pid, :release)
        stop_tasks([blocker | contenders])
        delete_inputs!([event_ref])
      end
    end)
  end

  # Slack sends a message that mentions Ryker as app_mention and as a channel
  # message, under different event ids, and the two can be handled at once.
  # Both were recorded on 2026-09-26, and "Hi @Ryker" got two replies.
  test "two events for one message recorded at the same time are one input" do
    Sandbox.unboxed_run(Repo, fn ->
      refs = Enum.map(["mention", "message"], &"Ev-#{&1}-#{Ecto.UUID.generate()}")
      message_ref = unique_message_ref()
      [first, second] = Enum.map(refs, &input!(&1, message_ref: message_ref))
      parent = self()
      blocker = lock_task(Inbox.revision_lock(first), parent)
      assert_receive {:source_locked, blocker_backend}, 5_000

      contenders =
        Enum.map([first, second], fn input ->
          unboxed_task(fn ->
            send(parent, {:contender_ready, self(), backend_pid()})
            Inbox.record(input, one_input_per_revision: true)
          end)
        end)

      contender_backends =
        Enum.map(contenders, fn contender ->
          contender_pid = contender.pid
          assert_receive {:contender_ready, ^contender_pid, backend}, 5_000
          backend
        end)

      try do
        Enum.each(contender_backends, &await_blocked_by(&1, blocker_backend))
        send(blocker.pid, :release)

        receipts = Enum.map(contenders, &Task.await(&1, 5_000))

        assert receipts |> Enum.map(fn {:ok, receipt} -> receipt.status end) |> Enum.sort() ==
                 [:duplicate, :recorded]

        assert receipts
               |> Enum.map(fn {:ok, receipt} -> receipt.entry.id end)
               |> Enum.uniq()
               |> length() == 1

        assert Repo.aggregate(from(entry in Entry, where: entry.event_ref in ^refs), :count) == 1
      after
        send(blocker.pid, :release)
        stop_tasks([blocker | contenders])
        delete_inputs!(refs)
      end
    end)
  end

  test "simultaneous executors cannot claim the same input" do
    Sandbox.unboxed_run(Repo, fn ->
      event_ref = "Ev-claim-#{Ecto.UUID.generate()}"
      input = input!(event_ref)
      assert {:ok, %{entry: entry}} = Inbox.record(input)
      parent = self()

      contenders =
        Enum.map(1..2, fn index ->
          unboxed_task(fn ->
            send(parent, {:claim_ready, self()})

            receive do
              :claim ->
                Inbox.claim_next("executor:#{index}", ~U[2026-08-27 12:00:00Z], 60)
            end
          end)
        end)

      try do
        Enum.each(contenders, fn contender ->
          contender_pid = contender.pid
          assert_receive {:claim_ready, ^contender_pid}, 5_000
        end)

        Enum.each(contenders, &send(&1.pid, :claim))
        results = Enum.map(contenders, &Task.await(&1, 5_000))

        claims = for {:ok, %{entry: claimed}} <- results, do: claimed
        idle = Enum.count(results, &(&1 == {:ok, nil}))

        assert Enum.map(claims, & &1.id) == [entry.id]
        assert idle == 1
      after
        stop_tasks(contenders)
        delete_inputs!([event_ref])
      end
    end)
  end

  defp lock_task(dedupe_key, parent) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [dedupe_key])
        send(parent, {:source_locked, backend_pid()})

        receive do
          :release -> :ok
        end
      end)
    end)
  end

  test "simultaneous slots do not claim two pending inputs from the same conversation" do
    Sandbox.unboxed_run(Repo, fn ->
      refs = Enum.map(1..2, fn _ -> "Ev-ordered-#{Ecto.UUID.generate()}" end)

      entries =
        Enum.map(refs, fn ref ->
          {:ok, %{entry: entry}} = Inbox.record(input!(ref))
          entry
        end)

      parent = self()

      contenders =
        Enum.map(1..2, fn index ->
          unboxed_task(fn ->
            send(parent, {:ordered_ready, self()})

            receive do
              :claim -> Inbox.claim_next("ordered-slot:#{index}", DateTime.utc_now(), 60)
            end
          end)
        end)

      try do
        Enum.each(contenders, fn task ->
          pid = task.pid
          assert_receive {:ordered_ready, ^pid}, 5_000
        end)

        Enum.each(contenders, &send(&1.pid, :claim))
        results = Enum.map(contenders, &Task.await(&1, 5_000))
        claims = for {:ok, %{entry: claimed}} <- results, do: claimed.id
        assert claims == [hd(entries).id]
        assert Enum.count(results, &(&1 == {:ok, nil})) == 1
      after
        stop_tasks(contenders)
        delete_inputs!(refs)
      end
    end)
  end

  test "cleaning up a committed input leaves none of its evidence behind" do
    # The rule inventory is written after custody commits and has no foreign
    # key, so a test that deleted only the entry stranded it for every later
    # test that requires an empty database.
    Sandbox.unboxed_run(Repo, fn ->
      event_ref = "Ev-#{Ecto.UUID.generate()}"
      assert {:ok, %{entry: entry}} = Inbox.record(input!(event_ref))
      ref = Inbox.ref(entry)

      assert Repo.exists?(
               from(inventory in StandingRuleInventory, where: inventory.source_input_ref == ^ref)
             )

      delete_inputs!([event_ref])

      refute Repo.exists?(
               from(inventory in StandingRuleInventory, where: inventory.source_input_ref == ^ref)
             )

      refute Repo.exists?(from(row in Entry, where: row.id == ^entry.id))
    end)
  end

  # A person edits or deletes their message while someone forgets a topic
  # learned from it. Forgetting holds the message's note and then takes the
  # lock every forgetting takes; recording the edit or deletion took that lock
  # and then the note. Each waited on the other until the database cancelled
  # one: the edit or deletion was not recorded, or the forgetting failed
  # (found in review, 2026-09-28).
  for {kind, revision} <- [edit: "an edit", delete: "a deletion"] do
    test "#{revision} recorded while a topic learned from its message is forgotten waits instead of deadlocking" do
      Sandbox.unboxed_run(Repo, fn ->
        message_ref = unique_message_ref()

        try do
          topic = learned_topic!(message_ref)
          parent = self()

          forgetter =
            unboxed_task(fn ->
              pause_after_holding_the_note!(parent)

              try do
                safely(fn -> Forgetting.forget_topic(topic.id) end)
              after
                :telemetry.detach({__MODULE__, self()})
              end
            end)

          assert_receive {:note_held, forgetter_backend}, 5_000

          recorder =
            unboxed_task(fn ->
              send(parent, {:recorder_ready, backend_pid()})
              safely(fn -> Inbox.record(revision!(message_ref, unquote(kind))) end)
            end)

          try do
            assert_receive {:recorder_ready, recorder_backend}, 5_000
            await_blocked_by(recorder_backend, forgetter_backend)
            send(forgetter.pid, :resume)

            recorded = Task.await(recorder, 10_000)
            forgotten = Task.await(forgetter, 10_000)

            assert match?({:ok, %{status: :recorded}}, recorded),
                   "#{unquote(revision)} was not recorded: #{inspect(recorded)}"

            assert match?({:ok, %{forgotten: [_ | _]}}, forgotten),
                   "the topic was not forgotten: #{inspect(forgotten)}"
          after
            send(forgetter.pid, :resume)
            stop_tasks([forgetter, recorder])
          end
        after
          clean_learned!(message_ref)
        end
      end)
    end
  end

  # A deadlock is raised in the transaction the database cancels.
  defp safely(fun) do
    fun.()
  rescue
    error in Postgrex.Error -> {:raised, error.postgres[:code]}
  end

  defp pause_after_holding_the_note!(parent) do
    :ok =
      :telemetry.attach(
        {__MODULE__, self()},
        [:ryker, :repo, :query],
        &__MODULE__.pause_forgetting/4,
        {self(), parent, backend_pid()}
      )
  end

  # The first time forgetting writes a note, it holds the notes it forgets
  # and is about to take the lock every forgetting takes.
  def pause_forgetting(_event, _measurements, %{query: query}, {forgetter, parent, backend}) do
    if self() == forgetter and not Process.get(:paused?, false) and
         String.starts_with?(query, ~s(UPDATE "conversation_observations")) do
      Process.put(:paused?, true)
      :telemetry.detach({__MODULE__, forgetter})
      send(parent, {:note_held, backend})

      receive do
        :resume -> :ok
      after
        5_000 -> :ok
      end
    end
  end

  # A person's message, routed and learned from: routing kept a note of it,
  # and a topic was learned from that note.
  defp learned_topic!(message_ref) do
    assert {:ok, %{entry: entry}} = Inbox.record(learned_input!(message_ref, :message, 1))

    assert {:ok, context} =
             Admission.context(Inbox.ref(entry),
               now: DateTime.utc_now(),
               continuation_window: 1_800,
               history_window: 2_592_000,
               candidate_limit: 8
             )

    assert {:ok, decision} =
             Decision.parse(%{
               "action" => "ignore",
               "episode_ref" => nil,
               "messages" => nil,
               "reactions" => nil,
               "relation" => "unrelated",
               "repository" => nil,
               "repository_source" => nil,
               "reason" => "The person shared where the staging account lives.",
               "work_class" => nil
             })

    assert {:ok, %{entry: decided}} = Admission.commit(context, decision, "decision:#{entry.id}")

    proposal = %{
      "topic_key" => "staging-account",
      "title" => "Staging account",
      "summary" => "The staging account is acme-staging, as the message said.",
      "topics" => ["staging-account"],
      "anchors" => [],
      "target_ref" => nil,
      "expected_version" => 0
    }

    assert {:ok, :ok} =
             Repo.transaction(fn -> KnowledgeFixtures.record_topic(decided, proposal, []) end)

    Repo.one!(
      from(topic in ConversationKnowledge,
        where:
          topic.workspace_ref == ^"slack:#{@learned_workspace}" and
            topic.topic_key == "staging-account"
      )
    )
  end

  defp revision!(message_ref, :edit),
    do: learned_input!(message_ref, :edit, 2, "the staging account is acme-stg")

  defp revision!(message_ref, :delete), do: learned_input!(message_ref, :delete, 2, "")

  defp learned_input!(message_ref, kind, revision, text \\ "the staging account is acme-staging") do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "ULOCKORDER"},
               channel_ref: @learned_channel,
               content: %{"text" => text},
               event_kind: kind,
               event_ref: "Ev-lock-order-#{kind}-#{message_ref}",
               message_ref: message_ref,
               occurred_at: DateTime.add(DateTime.utc_now(), revision * 60 - 300, :second),
               revision: revision,
               thread_ref: nil,
               workspace_ref: @learned_workspace
             })

    input
  end

  defp clean_learned!(message_ref) do
    scope = "slack:#{@learned_workspace}"
    Repo.delete_all(from(topic in ConversationKnowledge, where: topic.workspace_ref == ^scope))
    Repo.delete_all(from(note in ConversationObservation, where: note.workspace_ref == ^scope))

    delete_entries!(
      from(entry in Entry,
        where: entry.source_ref == @learned_workspace and entry.source_item_ref == ^message_ref
      )
    )

    Repo.delete_all(
      from(membership in ChannelMembership, where: membership.workspace_ref == @learned_workspace)
    )
  end

  defp delete_inputs!(refs),
    do: delete_entries!(from(entry in Entry, where: entry.event_ref in ^refs))

  defp unique_message_ref,
    do: "1787832000." <> String.pad_leading("#{System.unique_integer([:positive])}", 6, "0")

  defp input!(event_ref, options \\ []) do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :app, ref: "A123"},
               channel_ref: "C456",
               content: %{"text" => "A concurrently delivered Slack event"},
               event_kind: :message,
               event_ref: event_ref,
               message_ref: Keyword.get(options, :message_ref, "1787832000.000100"),
               occurred_at: ~U[2026-08-27 12:00:00Z],
               revision: 1,
               thread_ref: nil,
               workspace_ref: "T123"
             })

    input
  end
end
