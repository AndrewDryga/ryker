defmodule Responder.State.AnswerMemoryConcurrencyTest do
  use Responder.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Responder.Episodes.{Episode, Event}
  alias Responder.Fixtures.AnswerMemory
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Repo
  alias Responder.Slack.Input
  alias Responder.State.{ConversationObservation, Memories, MemoryEntry, Record, Response}
  alias Responder.Work.{Session, Turn}

  for {first, second} <- [{:save, :revision}, {:revision, :save}] do
    @first first
    @second second
    test "concurrent save and source revision leave no stale fact when #{@first} commits first" do
      # An answer can be edited while resumed Work is saving it. Both commit
      # orders must revoke the old mapping, not leave a race-dependent default.
      Sandbox.unboxed_run(Repo, fn ->
        answer = AnswerMemory.answered!("portal-old", DateTime.utc_now())
        parent = self()
        first = @first
        second = @second

        writer =
          unboxed_task(fn ->
            Repo.transaction(fn ->
              result = perform(first, answer)
              send(parent, {:writer_held, backend_pid()})

              receive do
                :release -> result
              end
            end)
          end)

        assert_receive {:writer_held, writer_backend}, 5_000

        contender =
          unboxed_task(fn ->
            send(parent, {:contender_started, backend_pid()})
            perform(second, answer)
          end)

        try do
          assert_receive {:contender_started, contender_backend}, 5_000
          await_blocked_by(contender_backend, writer_backend)
          send(writer.pid, :release)
          assert {:ok, {:ok, _}} = Task.await(writer, 5_000)

          assert_contender(second, Task.await(contender, 5_000))

          refute Repo.exists?(
                   from(m in MemoryEntry,
                     where:
                       m.source_conversation_ref == ^answer.entry.destination_conversation_ref and
                         m.status == :active
                   )
                 )

          assert perform(:save, answer) == {:error, :answer_memory_unauthorized}
        after
          send(writer.pid, :release)
          stop_tasks([writer, contender])
          cleanup!(answer)
        end
      end)
    end
  end

  defp assert_contender(:save, result),
    do: assert(result == {:error, :answer_memory_unauthorized})

  defp assert_contender(:revision, result), do: assert({:ok, _} = result)

  defp perform(:save, answer),
    do: Memories.confirm_answer(answer.claim, answer.record.ref, "portal-old", fn _ -> true end)

  defp perform(:revision, answer) do
    {:ok, revised} =
      answer.input
      |> Map.merge(%{
        content: %{"text" => "That answer was incorrect."},
        event_kind: :edit,
        event_ref: "revision:#{answer.entry.id}",
        revision: 2
      })
      |> Input.new()

    Inbox.record(revised)
  end

  defp cleanup!(answer) do
    episode_id = answer.claim.episode.id
    workspace = answer.entry.source_ref
    conversation = answer.entry.destination_conversation_ref
    Repo.delete_all(from(m in MemoryEntry, where: m.source_conversation_ref == ^conversation))
    Repo.delete_all(from(r in Response, where: r.record_id == ^answer.record.id))
    Repo.delete_all(from(r in Record, where: r.episode_id == ^episode_id))

    Repo.delete_all(
      from(o in ConversationObservation, where: o.conversation_ref == ^conversation)
    )

    delete_entries!(from(e in Entry, where: e.source_ref == ^workspace))
    Repo.delete_all(from(t in Turn, where: t.episode_id == ^episode_id))
    Repo.delete_all(from(s in Session, where: s.episode_id == ^episode_id))
    Repo.delete_all(from(e in Event, where: e.episode_id == ^episode_id))
    Repo.delete_all(from(e in Episode, where: e.id == ^episode_id))
  end
end
