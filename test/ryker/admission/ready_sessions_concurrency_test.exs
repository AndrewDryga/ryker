defmodule Ryker.Admission.ReadySessionsConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Admission.ReadySessions
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.Work.Session

  @policy %{name: "admission-read-only", digest: String.duplicate("a", 64)}

  # Four routing slots claim at once whenever messages arrive together. Two
  # of them taking the same ready session would run two conversations in one
  # Coop session; the claim is the only thing standing between them.
  test "routing runs claiming at the same moment never take the same ready session" do
    Sandbox.unboxed_run(Repo, fn ->
      entries = Enum.map(1..3, &record_input!/1)
      ready = Enum.map(1..2, &insert_ready!/1)
      parent = self()

      contenders =
        Enum.map(entries, fn entry ->
          unboxed_task(fn ->
            send(parent, {:ready, self()})

            receive do
              :claim -> ReadySessions.claim(entry, @policy)
            end
          end)
        end)

      try do
        Enum.each(contenders, fn contender ->
          contender_pid = contender.pid
          assert_receive {:ready, ^contender_pid}, 5_000
        end)

        Enum.each(contenders, &send(&1.pid, :claim))
        results = Enum.map(contenders, &Task.await(&1, 5_000))

        claimed = for {:ok, %Session{id: id}, :claimed} <- results, do: id
        assert Enum.sort(claimed) == Enum.sort(Enum.map(ready, & &1.id))
        assert Enum.count(results, &(&1 == :none)) == 1

        owners =
          Repo.all(
            from(session in Session,
              where: session.id in ^Enum.map(ready, & &1.id),
              select: session.admission_input_id
            )
          )

        assert length(Enum.uniq(owners)) == 2
        assert Enum.all?(owners, &(&1 in Enum.map(entries, fn entry -> entry.id end)))
      after
        stop_tasks(contenders)

        Repo.delete_all(from(session in Session, where: session.id in ^Enum.map(ready, & &1.id)))

        delete_entries!(from(entry in Entry, where: entry.id in ^Enum.map(entries, & &1.id)))
      end
    end)
  end

  defp insert_ready!(index) do
    id = Ecto.UUID.generate()
    now = Repo.now!()

    Repo.insert!(%Session{
      cleanup_status: :active,
      coop_session_id: "coop-ready-#{id}",
      execution_kind: :admission,
      external_ref: ReadySessions.external_ref(id),
      generation: 1,
      id: id,
      inserted_at: DateTime.add(now, index, :microsecond),
      policy: @policy.name,
      policy_digest: @policy.digest,
      ready_state: :ready,
      updated_at: now
    })
  end

  defp record_input!(index) do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C70#{index}",
               content: %{"text" => "hi"},
               event_kind: :message,
               event_ref: "Ev-ready-race-#{index}-#{Ecto.UUID.generate()}",
               message_ref: "1787832000.00070#{index}",
               occurred_at: ~U[2026-08-30 12:00:00.000000Z],
               revision: 1,
               thread_ref: nil,
               workspace_ref: "T123"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end
end
