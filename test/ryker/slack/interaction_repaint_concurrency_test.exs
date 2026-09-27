defmodule Ryker.Slack.InteractionRepaintConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.{CanonicalJSON, Episodes, Repo}
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Knowledge.KnowledgeSnapshot
  alias Ryker.Slack.{InteractionAudit, InteractionRepaint}
  alias Ryker.Work.{Custody, Session, Turn}

  @message "I rechecked, but Emisar's infrastructure checks still aren't available to me."

  defmodule API do
    def update_message(observer, channel, message, document, delivery) do
      send(observer, {:updated, channel, message, document, delivery})
      :ok
    end
  end

  # Found live 2026-09-27: Andrew typed the answer to Ryker's question in its
  # Slack thread. Recording the answer started the next turn on the same
  # session, and the question's repaint ran 0.3 s later, while that transaction
  # still held the session row. The source check read "busy" as "not public"
  # and replaced two of Ryker's replies in the thread with "This response is
  # unavailable until its source context can be checked."
  test "a reply is not replaced while its session is busy, and is repainted once it is free" do
    Sandbox.unboxed_run(Repo, fn ->
      id = Ecto.UUID.generate()
      parent = self()

      try do
        claim = fixture!(id)

        locker =
          unboxed_task(fn ->
            Repo.transaction(fn ->
              Repo.one!(from(s in Session, where: s.id == ^claim.session.id, lock: "FOR UPDATE"))
              send(parent, {:session_locked, self()})
              receive do: (:release -> :ok)
            end)
          end)

        Process.put(:locker, locker)
        assert_receive {:session_locked, pid} when pid == locker.pid, 5_000

        result = repaint(claim)
        refute_received {:updated, _, _, _, _}, "a busy session replaced the published reply"
        assert {:error, :work_derived_context_busy} = result

        send(locker.pid, :release)
        Task.await(locker)

        assert :ok = repaint(claim)
        assert_received {:updated, "CREPAINTLOCK", "1790522028.741419", document, _delivery}
        assert document == %{"message" => @message}
      after
        if locker = Process.get(:locker), do: stop_tasks([locker])
        cleanup(id)
      end
    end)
  end

  defp repaint(claim) do
    [_slack, workspace_ref, channel_ref] =
      String.split(claim.episode.destination_conversation_ref, ":")

    InteractionRepaint.repaint(
      %InteractionAudit{
        workspace_ref: workspace_ref,
        channel_ref: channel_ref,
        thread_ref: "repaint-lock",
        message_ref: "1790522028.741419"
      },
      %{api: API, client: self()}
    )
  end

  defp fixture!(id) do
    conversation = "slack:TREPAINTLOCK:CREPAINTLOCK"

    {:ok, _} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: id,
          episode_key: "repaint-lock:#{id}",
          native_input_id: "repaint-lock-input:#{id}",
          turn_ref: "repaint-lock-turn:#{id}",
          destination: %{
            transport: "slack",
            conversation_ref: conversation,
            thread_ref: "repaint-lock"
          }
        })
      )

    {:ok, _} = Custody.pin_episode(id, "fixture", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("worker:#{id}", 60)
    assert claim.episode.id == id
    assert :ok = KnowledgeSnapshot.expose(claim, [])

    delivery = %{"message" => @message}

    claim.turn
    |> Ecto.Changeset.change(
      status: :settled,
      candidate: Jason.encode!(delivery),
      candidate_sha256: CanonicalJSON.digest(delivery),
      candidate_attempt: 1,
      validation_intent: %{"verdict" => "accept"},
      validation_intent_fingerprint: String.duplicate("a", 64),
      validation_receipt: "repaint-lock-validation",
      continuation: %{"kind" => "complete"},
      lease_ref: nil,
      lease_owner: nil,
      lease_expires_at: nil,
      next_attempt_at: nil,
      result_ref: "repaint-lock-result:#{id}",
      delivery_ref: "repaint-lock-delivery:#{id}",
      delivery_document: delivery,
      delivery_fingerprint: CanonicalJSON.digest(delivery),
      external_receipt: %{
        "transport" => "slack",
        "conversation_ref" => conversation,
        "thread_ref" => "repaint-lock",
        "message_ref" => "1790522028.741419"
      },
      external_receipt_fingerprint: String.duplicate("a", 64),
      delivered_at: DateTime.utc_now(),
      accepted_at: DateTime.utc_now()
    )
    |> Repo.update!()

    claim
  end

  defp cleanup(id) do
    Repo.delete_all(from(t in Turn, where: t.episode_id == ^id))
    Repo.delete_all(from(s in Session, where: s.episode_id == ^id))
    Repo.delete_all(from(e in Event, where: e.episode_id == ^id))
    Repo.delete_all(from(e in Episode, where: e.id == ^id))
  end
end
