defmodule Ryker.Improvement.AnalysesConcurrencyTest do
  @moduledoc """
  A person deleting their message races Ryker freezing evidence about it.

  An analysis prompt and an accepted case copy the person's words out of
  their message, and a deletion erases every copy it finds by the keys the
  copy saved. So a copy must read after the deletion committed, or save its
  keys before the deletion looks for them. Neither held for one that read
  the words while the deletion was committing: the deletion found no copy
  yet, and the copy then saved the words, ready to send them to the model
  (found in review, 2026-09-28).

  These commit for real, on connections of their own, and remove what they
  wrote.
  """
  use Ryker.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Feedback
  alias Ryker.Feedback.Signal
  alias Ryker.Improvement
  alias Ryker.Improvement.{Analyses, AnalysisRun, Candidate}
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Slack.Input, as: SlackInput

  @workspace "TIMPROVERACE"
  @channel "CIMPROVERACE"
  @words "Why is the staging deploy stuck on the migration again?"
  @settings %{
    enabled: true,
    lease_seconds: 300,
    policy: "ryker-learning",
    policy_digest: String.duplicate("a", 64),
    quiet_seconds: 0
  }

  test "a message deleted while its analysis is prepared never reaches the prompt" do
    Sandbox.unboxed_run(Repo, fn ->
      message_ref = unique_message_ref()

      try do
        candidate = unhappy_request!(message_ref)
        assert {:ok, %{candidate: %{id: claimed}} = claim} = Analyses.claim("race", @settings)
        assert claimed == candidate.id

        race_deletion(message_ref, fn -> Analyses.prepare(claim, @settings) end)

        prompts =
          Repo.all(
            from(run in AnalysisRun, where: run.candidate_id == ^candidate.id, select: run.prompt)
          )

        refute Enum.any?(prompts, &(is_binary(&1) and String.contains?(&1, @words))),
               "a prompt waiting to be sent quotes the message the person deleted"
      after
        clean!(message_ref)
      end
    end)
  end

  test "a message deleted while its case is accepted never reaches the case" do
    Sandbox.unboxed_run(Repo, fn ->
      message_ref = unique_message_ref()

      try do
        candidate = unhappy_request!(message_ref)

        race_deletion(message_ref, fn ->
          Improvement.accept(candidate.id, "control-plane:local")
        end)

        evidence = Repo.get!(Candidate, candidate.id).case_evidence

        refute is_map(evidence) and Jason.encode!(evidence) =~ @words,
               "the accepted case keeps the words of the message the person deleted"
      after
        clean!(message_ref)
      end
    end)
  end

  # Runs `freeze` on a connection of its own until it has read the evidence
  # and is about to save what it froze. The person deletes the message then,
  # and `freeze` saves once the deletion has committed or is waiting on it.
  defp race_deletion(message_ref, freeze) do
    parent = self()

    freezer =
      unboxed_task(fn ->
        pause_before_saving!(parent)

        try do
          freeze.()
        after
          :telemetry.detach({__MODULE__, self()})
        end
      end)

    assert_receive {:evidence_read, freezer_backend}, 5_000

    deleter =
      unboxed_task(fn ->
        send(parent, {:deleter_ready, backend_pid()})
        Inbox.record(deletion!(message_ref))
      end)

    assert_receive {:deleter_ready, deleter_backend}, 5_000

    try do
      deletion = committed_or_waiting(deleter, deleter_backend, freezer_backend)
      send(freezer.pid, :save)
      assert {:ok, _frozen} = Task.await(freezer, 5_000)

      assert {:ok, %{status: :recorded}} =
               if(deletion == :waiting, do: Task.await(deleter, 5_000), else: deletion)
    after
      stop_tasks([freezer, deleter])
    end
  end

  # Whether the deletion committed at once, or waits on the transaction that
  # is freezing the evidence.
  defp committed_or_waiting(deleter, deleter_backend, freezer_backend, deadline \\ deadline()) do
    case Task.yield(deleter, 10) do
      {:ok, recorded} ->
        recorded

      nil ->
        cond do
          Repo.query!("SELECT $2::integer = ANY(pg_blocking_pids($1::integer))", [
            deleter_backend,
            freezer_backend
          ]).rows == [[true]] ->
            :waiting

          System.monotonic_time(:millisecond) > deadline ->
            flunk("the deletion neither committed nor waited on the freezing")

          true ->
            committed_or_waiting(deleter, deleter_backend, freezer_backend, deadline)
        end
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000

  defp pause_before_saving!(parent) do
    :ok =
      :telemetry.attach(
        {__MODULE__, self()},
        [:ryker, :repo, :query],
        &__MODULE__.pause/4,
        {self(), parent, backend_pid()}
      )
  end

  # The first time the freezing process writes to its candidate, it has read
  # the evidence and is about to save what it froze.
  def pause(_event, _measurements, %{query: query}, {freezer, parent, backend}) do
    if self() == freezer and not Process.get(:paused?, false) and
         String.starts_with?(query, ~s(UPDATE "improvement_candidates")) do
      Process.put(:paused?, true)
      :telemetry.detach({__MODULE__, freezer})
      send(parent, {:evidence_read, backend})

      receive do
        :save -> :ok
      after
        5_000 -> :ok
      end
    end
  end

  # A person's question in Slack, and their thumbs down on the answer.
  defp unhappy_request!(message_ref) do
    assert {:ok, %{entry: entry}} = Inbox.record(message!(message_ref))

    assert {:ok, %{status: :recorded}} =
             Feedback.record(%{
               kind: :reaction_added,
               value: "-1",
               note: nil,
               actor_ref: "UIMPROVERACE",
               source: "slack",
               source_ref: "slack-event:race-#{message_ref}",
               occurred_at: DateTime.add(DateTime.utc_now(), -60, :second),
               request: {:input, entry.id}
             })

    Improvement.for_request({:input, entry.id})
  end

  defp message!(message_ref), do: slack_input!(message_ref, :message, @words, 1)
  defp deletion!(message_ref), do: slack_input!(message_ref, :delete, "", 2)

  defp slack_input!(message_ref, kind, text, revision) do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "UIMPROVERACE"},
               channel_ref: @channel,
               content: %{"text" => text},
               event_kind: kind,
               event_ref: "Ev-improvement-race-#{kind}-#{message_ref}",
               message_ref: message_ref,
               occurred_at: DateTime.add(DateTime.utc_now(), revision * 60 - 300, :second),
               revision: revision,
               thread_ref: nil,
               workspace_ref: @workspace
             })

    input
  end

  defp unique_message_ref,
    do: "1790200000." <> String.pad_leading("#{System.unique_integer([:positive])}", 6, "0")

  defp clean!(message_ref) do
    entries =
      from(entry in Entry,
        where: entry.source_ref == @workspace and entry.source_item_ref == ^message_ref
      )

    ids = Repo.all(from(entry in entries, select: entry.id))
    candidates = Repo.all(from(c in Candidate, where: c.input_id in ^ids, select: c.id))

    Repo.delete_all(from(run in AnalysisRun, where: run.candidate_id in ^candidates))
    Repo.delete_all(from(c in Candidate, where: c.id in ^candidates))
    Repo.delete_all(from(signal in Signal, where: signal.input_id in ^ids))
    delete_entries!(entries)
  end
end
