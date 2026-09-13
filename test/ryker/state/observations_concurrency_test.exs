defmodule Ryker.State.ObservationsConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Admission
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Slack.{ChannelFence, ChannelMembership, Input}
  alias Ryker.State.{ConversationObservation, Observations}

  test "recall rechecks destination privacy after waiting for its membership lock" do
    # A channel turning private must not inherit public cross-channel recall from a stale pre-lock read.
    Sandbox.unboxed_run(Repo, fn ->
      workspace = "TOBS#{System.unique_integer([:positive])}"
      now = DateTime.utc_now()

      for channel <- ["CSOURCE", "CTARGET"] do
        Repo.insert!(%ChannelMembership{
          id: Ecto.UUID.generate(),
          workspace_ref: workspace,
          channel_ref: channel,
          private: false,
          external_shared: false,
          generation: 1,
          status: :joined,
          joined_at: now
        })
      end

      id = Ecto.UUID.generate()

      Repo.insert!(%ConversationObservation{
        id: id,
        identity_key: id,
        source_input_id: id,
        transport: "slack",
        workspace_ref: "slack:#{workspace}",
        conversation_ref: "slack:#{workspace}:CSOURCE",
        visibility: :public,
        source_message_ref: "1787832000.000100",
        source_result_ref: "result",
        source_fingerprint: String.duplicate("a", 64),
        actor_ref: "U03EPT4RP5M",
        execution_mode: :shadow,
        revision: 1,
        occurred_at: now,
        note: %{
          "summary" =>
            "U03EPT4RP5M wants to keep `draft-ai-suggestions` and plans to look into it at an unspecified future time.",
          "topics" => ["draft-ai-suggestions"]
        }
      })

      {:ok, input} =
        Input.new(%{
          actor: %{kind: :user, ref: "U03EPT4RP5M"},
          channel_ref: "CTARGET",
          workspace_ref: workspace,
          message_ref: "1787832000.000101",
          thread_ref: nil,
          event_ref: id,
          revision: 1,
          event_kind: :message,
          occurred_at: now,
          content: %{"text" => "Why are we keeping that service?"}
        })

      {:ok, %{entry: target}} = Inbox.record(input)

      parent = self()

      blocker =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            :ok = ChannelFence.lock_in_transaction(workspace, "CTARGET")
            send(parent, {:locked, backend_pid()})

            receive do
              :make_private ->
                Repo.update_all(
                  from(m in ChannelMembership,
                    where: m.workspace_ref == ^workspace and m.channel_ref == "CTARGET"
                  ),
                  set: [private: true]
                )
            end
          end)
        end)

      assert_receive {:locked, blocker_backend}, 5_000

      reader =
        unboxed_task(fn ->
          send(parent, {:reader, backend_pid()})

          Admission.context(Inbox.ref(target),
            now: now,
            continuation_window: 1_800,
            history_window: 604_800,
            candidate_limit: 20
          )
        end)

      try do
        assert_receive {:reader, reader_backend}, 5_000
        await_blocked_by(reader_backend, blocker_backend)
        send(blocker.pid, :make_private)
        Task.await(blocker)
        assert Task.await(reader) == {:error, {:admission_rejected, :context_stale}}
        assert Observations.context(target, nil) == []
      after
        stop_tasks([blocker, reader])
        Repo.delete_all(from(n in ConversationObservation, where: n.id in ^[id, target.id]))
        delete_entries!(from(e in Entry, where: e.id == ^target.id))
        Repo.delete_all(from(m in ChannelMembership, where: m.workspace_ref == ^workspace))
      end
    end)
  end
end
