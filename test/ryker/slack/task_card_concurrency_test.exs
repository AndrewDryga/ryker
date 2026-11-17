defmodule Ryker.Slack.TaskCardConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.{Episodes, Records, Repo}
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.{TaskOffer, WorkSessions}
  alias Ryker.Knowledge.KnowledgeSnapshot
  alias Ryker.Records.Record
  alias Ryker.Slack.{InteractionAudit, InteractionRepaint, Renderer, TaskCard, TaskCardWorker}
  alias Ryker.Work.{Custody, Session, Turn}

  @captured Jason.decode!(File.read!("testdata/learning/recorded-private-source-citation.json"))

  defmodule API do
    def update_message(observer, _channel, _message, document, _ref) do
      {:ok, _} = Renderer.render(document)
      send(observer, {:updated, document})
      :ok
    end
  end

  # November 17: a complete task card became seven unknown stages and
  # "Repository details unavailable" during a refresh. Source custody uses
  # SKIP LOCKED; another transaction holding either source session is a wait,
  # not a withdrawal. Reuse the captured source text, with host-owned lifecycle.
  for owner <- [:producer, :task] do
    test "a busy #{owner} keeps the published task card and resumes without spending attempts" do
      Sandbox.unboxed_run(Repo, fn ->
        producer_id = Ecto.UUID.generate()
        task_id = Ecto.UUID.generate()

        try do
          fixture = fixture!(producer_id, task_id)
          options = options()
          assert {:ok, {:updated, _}} = TaskCardWorker.run_once(options)
          assert_received {:updated, before}
          assert before["task_card"]["title"] == @captured["arguments"]["subject"]
          refute before["task_card"]["repository"] == "Repository details unavailable"

          published = Repo.get!(TaskCard, fixture.card.id)
          parent = self()
          session_id = fixture[unquote(owner)].session.id

          locker =
            unboxed_task(fn ->
              Repo.transaction(fn ->
                Repo.one!(from(s in Session, where: s.id == ^session_id, lock: "FOR UPDATE"))
                send(parent, {:session_locked, self()})
                receive do: (:release -> :ok)
              end)
            end)

          try do
            assert_receive {:session_locked, pid} when pid == locker.pid, 5_000

            for _attempt <- 1..3 do
              make_due!(fixture.card)
              started_at = Repo.now!()
              result = TaskCardWorker.run_once(options)
              refute_received {:updated, _}, "a busy source replaced the published task card"
              assert result == {:ok, {:deferred, fixture.card.ref}}
              waiting = Repo.get!(TaskCard, fixture.card.id)
              assert waiting.status == :active
              assert waiting.attempt_count == 0
              assert waiting.card_fingerprint == published.card_fingerprint
              assert waiting.card_ui_revision == published.card_ui_revision
              assert waiting.message_ref == published.message_ref
              assert waiting.lease_ref == nil
              assert DateTime.compare(waiting.next_attempt_at, started_at) == :gt
            end

            assert InteractionRepaint.repaint(audit(fixture.card), options) ==
                     {:error, :work_derived_context_busy}

            refute_received {:updated, _}, "an interaction erased the busy task card"
            send(locker.pid, :release)
            assert Task.await(locker) == {:ok, :ok}

            assert InteractionRepaint.repaint(audit(fixture.card), options) == :ok
            assert_received {:updated, ^before}
            make_due!(fixture.card)
            assert {:ok, {:updated, _}} = TaskCardWorker.run_once(options)
            refute_received {:updated, _}, "an unchanged card was needlessly sent again"
            assert Repo.get!(TaskCard, fixture.card.id).last_error_code == nil
          after
            stop_tasks([locker])
          end
        after
          cleanup([producer_id, task_id])
        end
      end)
    end
  end

  defp fixture!(producer_id, task_id) do
    conversation = "slack:TCARDLOCK:CCARDLOCK"
    producer = claim!(producer_id, conversation)
    task = claim!(task_id, conversation)

    assert {:ok, offer} =
             Records.create(
               Records.token(producer.turn),
               "captured-offer",
               "task_offer",
               TaskOffer.payload(%{
                 "title" => @captured["arguments"]["subject"],
                 "prompt" => @captured["arguments"]["observation"]
               })
             )

    offer
    |> Ecto.Changeset.change(
      status: :confirmed,
      confirmed_episode_id: task_id,
      confirmed_at: DateTime.utc_now(),
      confirmed_by_actor_ref: "slack:user:fixture",
      confirmation_ref: "card-lock-confirmation:#{task_id}"
    )
    |> Repo.update!()

    assert {:ok, _} =
             Records.create(Records.token(task.turn), "captured-progress", "progress", %{
               "phase" => "working",
               "summary" => @captured["arguments"]["observation"]
             })

    card =
      Repo.insert!(%TaskCard{
        id: Ecto.UUID.generate(),
        record_id: offer.id,
        episode_id: task_id,
        ref: "task-card:#{offer.id}",
        workspace_ref: "TCARDLOCK",
        channel_ref: "CCARDLOCK",
        thread_ref: task.episode.destination_thread_ref,
        message_ref: "1787832001.000200"
      })

    %{producer: producer, task: task, card: card}
  end

  defp claim!(id, conversation) do
    assert {:ok, _} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: id,
                 episode_key: "card-lock:#{id}",
                 native_input_id: "card-lock-input:#{id}",
                 turn_ref: "card-lock-turn:#{id}",
                 destination: %{
                   transport: "slack",
                   conversation_ref: conversation,
                   thread_ref: id
                 }
               })
             )

    assert {:ok, _} = WorkSessions.pin_episode(id, "fixture", String.duplicate("a", 64))
    assert {:ok, claim} = Custody.claim_next("worker:#{id}", 60)
    assert claim.episode.id == id
    assert KnowledgeSnapshot.expose(claim, []) == :ok
    claim
  end

  defp audit(card),
    do: %InteractionAudit{
      workspace_ref: card.workspace_ref,
      channel_ref: card.channel_ref,
      thread_ref: card.thread_ref,
      message_ref: card.message_ref
    }

  defp options,
    do: %{
      api: API,
      client: self(),
      worker_ref: "task-card-concurrency",
      lease_seconds: 300,
      retry_base_seconds: 1,
      check_interval_seconds: 1,
      max_attempts: 1
    }

  defp make_due!(card) do
    past = DateTime.add(Repo.now!(), -3_600, :second)

    Repo.update_all(from(c in TaskCard, where: c.id == ^card.id),
      set: [next_attempt_at: past, card_checked_at: past]
    )
  end

  defp cleanup(ids) do
    Repo.delete_all(from(c in TaskCard, where: c.episode_id in ^ids))
    Repo.delete_all(from(r in Record, where: r.episode_id in ^ids))
    Repo.delete_all(from(t in Turn, where: t.episode_id in ^ids))
    Repo.delete_all(from(s in Session, where: s.episode_id in ^ids))
    Repo.delete_all(from(e in Event, where: e.episode_id in ^ids))
    Repo.delete_all(from(e in Episode, where: e.id in ^ids))
  end
end
