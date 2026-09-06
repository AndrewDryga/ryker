defmodule Responder.Admission.FleetSessionConcurrencyTest do
  use Responder.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Responder.Admission.FleetSession
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Repo
  alias Responder.Slack.Input, as: SlackInput
  alias Responder.State.ConversationObservation
  alias Responder.Work.Session

  @policy %{name: "admission-read-only", digest: String.duplicate("a", 64)}

  test "simultaneous admission preparation converges on one fleet session" do
    # Two fleet admission workers can recover the same unbound execution after
    # a lease handoff. The loser must reload the exact winning authority rather
    # than crash the admission queue on the partial unique index.
    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, input} =
               SlackInput.new(%{
                 actor: %{kind: :user, ref: "U123"},
                 channel_ref: "C456",
                 content: %{"text" => "Classify this once."},
                 event_kind: :message,
                 event_ref: "Ev-fleet-concurrency-#{Ecto.UUID.generate()}",
                 message_ref: "1787832000.000200",
                 occurred_at: ~U[2026-08-30 12:00:00.000000Z],
                 revision: 1,
                 thread_ref: nil,
                 workspace_ref: "T123"
               })

      assert {:ok, %{entry: entry}} = Inbox.record(input)
      parent = self()

      contenders =
        Enum.map(1..2, fn _index ->
          unboxed_task(fn ->
            send(parent, {:ready, self()})

            receive do
              :ensure -> FleetSession.ensure(entry, @policy)
            end
          end)
        end)

      try do
        Enum.each(contenders, fn contender ->
          contender_pid = contender.pid
          assert_receive {:ready, ^contender_pid}, 5_000
        end)

        Enum.each(contenders, &send(&1.pid, :ensure))

        sessions =
          contenders
          |> Enum.map(&Task.await(&1, 5_000))
          |> Enum.map(fn {:ok, session} -> session end)

        assert Enum.uniq_by(sessions, & &1.id) |> length() == 1

        assert Repo.aggregate(
                 from(session in Session,
                   where: session.external_ref == ^List.first(sessions).external_ref
                 ),
                 :count
               ) == 1
      after
        stop_tasks(contenders)
        Repo.delete_all(from(session in Session, where: session.execution_kind == :admission))
        Repo.delete_all(from(candidate in Entry, where: candidate.id == ^entry.id))

        Repo.delete_all(
          from(note in ConversationObservation, where: note.source_input_id == ^entry.id)
        )
      end
    end)
  end
end
