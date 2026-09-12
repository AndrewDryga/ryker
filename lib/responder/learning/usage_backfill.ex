defmodule Responder.Learning.UsageBackfill do
  @moduledoc """
  One-off recovery of the learning executions that ran before the ledger metered them.

  Learning turns only began writing `execution_usage` rows on 2026-09-11, so the
  learning runs that finished earlier spent tokens that nothing recorded. Coop
  still holds their turns, so the spend is recoverable rather than estimable: each
  unmetered run is re-observed from its own Coop turn through the same
  `Responder.Accounting.observe_learning_in_transaction/6` the live executor uses,
  and the `(kind, source_id, generation)` unique index makes a repeated run a
  no-op.

  Nothing is ever inferred. A run whose session or turn Coop can no longer
  produce is reported with its reason, and so is a turn Coop kept without usage —
  a failed learning turn reports no counters, and a row of zeroes would read as a
  free execution on `/usage`.
  """
  import Ecto.Query

  alias Responder.Accounting
  alias Responder.Accounting.Execution
  alias Responder.Learning.{Batch, Executor}
  alias Responder.Repo
  alias Responder.State.LearningRun
  alias Responder.Work.{Measurement, Session}

  @tokens [
    {"input", :usage_input_tokens},
    {"cached_input", :usage_cached_input_tokens},
    {"output", :usage_output_tokens},
    {"reasoning", :usage_reasoning_tokens}
  ]

  @doc """
  Re-observes every unmetered historical learning run and reports what it found.

  `:dry_run` reads Coop and writes nothing; its `recovered_runs` and
  `recovered_tokens` are exactly what `:apply` would record.
  """
  def reconcile(settings, mode) when mode in [:dry_run, :apply] do
    runs = Repo.all(unmetered())
    {:ok, report(runs, Enum.map(runs, &reconcile_run(&1, settings, mode)), mode)}
  end

  defp unmetered do
    from(r in LearningRun,
      as: :run,
      where: not is_nil(r.coop_turn_id),
      where:
        not exists(
          from(e in Execution,
            where:
              e.kind == "learning" and e.source_id == parent_as(:run).id and
                fragment("? = ?::text", e.generation, parent_as(:run).generation)
          )
        ),
      order_by: [asc: r.inserted_at, asc: r.id]
    )
  end

  defp reconcile_run(run, settings, mode) do
    with {:ok, batch} <- batch(run),
         {:ok, session} <- session(run),
         {:ok, remote_session} <- remote_session(settings, session),
         {:ok, turn} <- remote_turn(settings, session, run),
         {:ok, measurement} <- measured(turn, remote_session) do
      {:recovered, record(run, batch, session, turn, remote_session, measurement, mode)}
    else
      {:error, reason} -> {:skipped, run.id, reason(reason)}
    end
  end

  defp batch(%{batch_id: nil}), do: {:error, :learning_batch_unknown}

  defp batch(run) do
    case Repo.get(Batch, run.batch_id) do
      %Batch{} = batch -> {:ok, batch}
      nil -> {:error, :learning_batch_unknown}
    end
  end

  defp session(run) do
    case Repo.get_by(Session, execution_kind: :learning, learning_run_id: run.id) do
      %Session{coop_session_id: id} = session when is_binary(id) -> {:ok, session}
      _unbound -> {:error, :learning_session_unknown}
    end
  end

  defp remote_session(settings, session) do
    case settings.api.get_session(settings.client, session.coop_session_id) do
      {:ok, %{"id" => id} = remote} when id == session.coop_session_id -> {:ok, remote}
      {:ok, %{}} -> {:error, :learning_session_identity_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remote_turn(settings, session, run) do
    case settings.api.get_turn(settings.client, session.coop_session_id, run.coop_turn_id) do
      {:ok, %{} = turn} ->
        with :ok <- Executor.exact_turn(turn, session.coop_session_id, run.coop_turn_id),
             do: {:ok, turn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp measured(turn, remote_session) do
    case Measurement.prepare(turn, remote_session) do
      %{usage_recorded: true} = measurement -> {:ok, measurement}
      _unmeasured -> {:error, :learning_turn_usage_unrecorded}
    end
  end

  defp record(_run, _batch, _session, _turn, _remote_session, measurement, :dry_run),
    do: measurement

  defp record(run, batch, session, turn, remote_session, _measurement, :apply) do
    # These runs are historical, so no worker holds their batch lease to fence
    # this write. The ledger row itself is the fence: observing it takes
    # FOR UPDATE on the (kind, source_id, generation) row and merges counters by
    # maximum, so neither a repeat of this command nor a concurrent live
    # observation can count the same turn twice.
    {:ok, {:ok, saved}} =
      Repo.transaction(fn ->
        Accounting.observe_learning_in_transaction(
          batch,
          run,
          session.id,
          turn,
          remote_session,
          observed_at(run)
        )
      end)

    saved
  end

  # The host span and the ledger's usage day are measured at observation. A
  # reconciliation runs long after the fact, so it observes at the moment the
  # host recorded this run's terminal turn, not at its own clock.
  defp observed_at(run), do: run.remote_stopped_at || run.updated_at

  defp report(runs, results, mode) do
    recovered = for {:recovered, measured} <- results, do: measured

    %{
      "mode" => if(mode == :apply, do: "apply", else: "dry_run"),
      "unmetered_runs" => length(runs),
      "recovered_runs" => length(recovered),
      "recovered_tokens" =>
        Map.new(@tokens, fn {name, field} ->
          {name, Enum.reduce(recovered, 0, &((Map.get(&1, field) || 0) + &2))}
        end),
      "skipped_runs" => skipped(results)
    }
  end

  defp skipped(results) do
    grouped =
      for {:skipped, id, reason} <- results, reduce: %{} do
        acc -> Map.update(acc, reason, [id], &(&1 ++ [id]))
      end

    for {reason, ids} <- Enum.sort(grouped),
        do: %{"reason" => reason, "count" => length(ids), "run_ids" => ids}
  end

  # Operator output carries the stable tag, never a provider's own message or the
  # references a failure carries with it.
  defp reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason({:coop_error, status, code, _detail}) when is_integer(status) and is_binary(code),
    do: "coop_error:#{status}:#{code}"

  defp reason(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: Atom.to_string(elem(reason, 0))

  defp reason(_unexpected), do: "unexpected_error"
end
