defmodule Ryker.Memories.CasesConcurrencyTest do
  @moduledoc """
  A person deletes a message at the moment retention keeps the case of the
  work it started.

  Retention keeps a case and reclaims the record of which messages joined the
  work in one transaction. Withdrawing the message looks for the work it
  joined first, and for cases already kept second. The other order misses the
  case whenever retention commits between the two looks: the first finds no
  case kept yet, the second no longer finds the work, and the case goes on
  quoting the deleted words, with no age limit.

  These commit for real, on connections of their own, and remove what they
  wrote.
  """
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Episodes
  alias Ryker.Episodes.{Command, Episode, Event, Origin, RoutingDigest}
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning.ConversationObservation
  alias Ryker.Memories.CaseRecord
  alias Ryker.Repo
  alias Ryker.Retention.Data
  alias Ryker.Slack.Input, as: SlackInput

  @workspace "TCASERACE"
  @channel "CCASERACE"
  @words "Postgres primary pgsql-prod-01 is unreachable and replication is stalled"
  @old ~U[2020-01-01 00:00:00.000000Z]

  test "a message deleted while retention keeps its work's case is withdrawn from it" do
    Sandbox.unboxed_run(Repo, fn ->
      message_ref = unique_message_ref()
      episode_id = Ecto.UUID.generate()

      try do
        finished_work!(message_ref, episode_id)
        parent = self()

        # Retention has written the case and reclaimed the work's history,
        # and has not committed.
        keeper =
          unboxed_task(fn ->
            pause!(
              parent,
              :history_reclaimed,
              &String.starts_with?(&1, "DELETE FROM episode_input_origins")
            )

            try do
              Data.prune(settings())
            after
              :telemetry.detach({__MODULE__, self()})
            end
          end)

        assert_receive {:history_reclaimed, _keeper_backend}, 5_000

        # The deletion has looked once, for the work or for a kept case.
        withdrawer =
          unboxed_task(fn ->
            pause!(parent, :withdrawal_looked, &withdrawal_look?/1)

            try do
              Inbox.record(said!(message_ref, :delete, 2))
            after
              :telemetry.detach({__MODULE__, self()})
            end
          end)

        assert_receive {:withdrawal_looked, _withdrawer_backend}, 5_000

        try do
          send(keeper.pid, :resume)
          assert {:ok, %{episode_histories: 1}} = Task.await(keeper, 10_000)

          send(withdrawer.pid, :resume)
          assert {:ok, %{status: :recorded}} = Task.await(withdrawer, 10_000)

          record = Repo.get_by!(CaseRecord, case_ref: "case:#{episode_id}")

          assert {record.status, record.problem, record.search_text} ==
                   {:deleted, "(deleted)", ""},
                 "the case kept as the message was deleted still quotes it: #{inspect(record.problem)}"
        after
          send(keeper.pid, :resume)
          send(withdrawer.pid, :resume)
          stop_tasks([keeper, withdrawer])
        end
      after
        clean!(message_ref, episode_id)
      end
    end)
  end

  # Where a withdrawal looks: the work a message joined, or the cases kept.
  defp withdrawal_look?(query),
    do: query =~ ~s("episode_input_origins") or query =~ ~s("episode_case_records")

  defp pause!(parent, signal, at?) do
    :ok =
      :telemetry.attach(
        {__MODULE__, self()},
        [:ryker, :repo, :query],
        &__MODULE__.pause/4,
        {self(), parent, signal, at?, backend_pid()}
      )
  end

  def pause(_event, _measurements, %{query: query}, {owner, parent, signal, at?, backend}) do
    if self() == owner and not Process.get(:paused?, false) and at?.(query) do
      Process.put(:paused?, true)
      :telemetry.detach({__MODULE__, owner})
      send(parent, {signal, backend})

      receive do
        :resume -> :ok
      after
        5_000 -> :ok
      end
    end
  end

  # Work a person's message started and finished long enough ago that
  # retention keeps its case and reclaims its history.
  defp finished_work!(message_ref, episode_id) do
    input = said!(message_ref, :message, 1)
    assert {:ok, %{status: :recorded}} = Inbox.record(input)

    assert {:ok, transition} =
             Episodes.apply(%Command.AdmitInput{
               actor_ref: Input.actor_ref(input),
               destination: input.destination,
               episode_id: episode_id,
               episode_key: "cases-race:#{episode_id}",
               linked_episode_id: nil,
               native_input_id: input.native_input_id,
               occurred_at: input.occurred_at,
               payload: Input.document(input),
               revision: 1,
               turn_ref: "turn:#{episode_id}"
             })

    assert {:ok, _settled} =
             Episodes.apply(%Command.AcceptResult{
               decision_reason: "The replica was promoted and reads recovered.",
               delivery: :none,
               delivery_ref: nil,
               episode_key: transition.episode.key,
               expected_turn_ref: transition.episode.owner_ref,
               next_turn_ref: nil,
               occurred_at: DateTime.utc_now(),
               result_ref: "result:#{episode_id}"
             })

    Repo.update_all(from(episode in Episode, where: episode.id == ^episode_id),
      set: [updated_at: @old]
    )
  end

  defp settings do
    %{
      audit_data_seconds: 10 * 365 * 86_400,
      closed_work_seconds: 60,
      conversation_memory_seconds: 60,
      episode_history_seconds: 60,
      operational_data_seconds: 60,
      routing_examples_enabled: false,
      routing_examples_seconds: 365 * 86_400,
      work_examples_enabled: false,
      work_examples_seconds: 365 * 86_400
    }
  end

  defp said!(message_ref, kind, revision) do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "UCASERACE"},
               channel_ref: @channel,
               content: %{"text" => if(kind == :delete, do: "", else: @words)},
               event_kind: kind,
               event_ref: "Ev-case-race-#{kind}-#{message_ref}",
               message_ref: message_ref,
               occurred_at: DateTime.add(DateTime.utc_now(), revision * 60 - 300, :second),
               revision: revision,
               thread_ref: nil,
               workspace_ref: @workspace
             })

    input
  end

  defp unique_message_ref,
    do: "1790500000." <> String.pad_leading("#{System.unique_integer([:positive])}", 6, "0")

  defp clean!(message_ref, episode_id) do
    Repo.delete_all(from(record in CaseRecord, where: record.episode_id == ^episode_id))
    Repo.delete_all(from(origin in Origin, where: origin.episode_id == ^episode_id))
    Repo.delete_all(from(digest in RoutingDigest, where: digest.episode_id == ^episode_id))
    Repo.delete_all(from(event in Event, where: event.episode_id == ^episode_id))
    Repo.delete_all(from(episode in Episode, where: episode.id == ^episode_id))

    delete_entries!(
      from(entry in Entry,
        where: entry.source_ref == @workspace and entry.source_item_ref == ^message_ref
      )
    )

    Repo.delete_all(
      from(note in ConversationObservation, where: note.workspace_ref == ^"slack:#{@workspace}")
    )
  end
end
