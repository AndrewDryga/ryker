defmodule Ryker.Accounting do
  @moduledoc "Durable execution-level usage snapshots, independent of acceptance and prompt retention."
  import Ecto.Query
  alias Ecto.Changeset
  alias Ryker.Accounting.Execution
  alias Ryker.Repo
  alias Ryker.Work.{Measurement, Turn}

  @terminal ~w(completed failed interrupted budget_exhausted cancelled)
  @states ~w(requested queued starting running awaiting_validation completed failed interrupted budget_exhausted cancelled)
  @token_fields ~w(usage_input_tokens usage_cached_input_tokens usage_output_tokens usage_reasoning_tokens)a
  @timing_fields ~w(remote_queued_at remote_started_at remote_finished_at usage_queued_ms usage_provider_ms usage_host_ms)a
  @measurement_fields @token_fields ++
                        @timing_fields ++
                        ~w(execution_target usage_recorded usage_cost_recorded usage_cost_usd timing_recorded measurement_error_code)a

  def measurement_fields, do: @measurement_fields

  def observe_work(claim, remote_turn, remote_session \\ %{}) do
    Repo.transaction(fn ->
      current = Repo.one(from(t in Turn, where: t.id == ^claim.turn.id, lock: "FOR UPDATE"))
      now = DateTime.utc_now()

      session_generation =
        Repo.one(
          from(s in Ryker.Work.Session,
            where: s.id == ^claim.session.id,
            select: s.generation
          )
        )

      if is_nil(current) or current.lease_ref != claim.lease_ref or
           current.session_id != claim.session.id or
           session_generation != claim.session.generation or
           current.submit_generation != claim.turn.submit_generation or
           is_nil(current.lease_expires_at) or
           DateTime.compare(current.lease_expires_at, now) != :gt do
        Repo.rollback(:accounting_lease_lost)
      end

      record(
        work_identity(claim),
        remote_turn,
        Measurement.prepare(remote_turn, remote_session),
        now
      )
    end)
    |> result()
  end

  @doc "The caller already owns the input lock and exact execution generation."
  def observe_admission_in_transaction(entry, remote_turn, measurement, now) do
    saved =
      record(
        %{
          kind: "admission",
          source_id: entry.id,
          generation: to_string(entry.execution_generation),
          episode_id: entry.episode_id,
          session_id: nil,
          transport: entry.destination_transport,
          conversation_ref: entry.destination_conversation_ref,
          repository_ref: entry.repository_ref,
          execution_mode: to_string(entry.execution_mode)
        },
        remote_turn,
        measurement,
        now
      )

    {:ok, saved}
  end

  @doc "The caller already owns the learning batch lease; one ledger row per frozen learning attempt."
  def observe_learning_in_transaction(batch, run, session_id, remote_turn, remote_session, now) do
    measurement = Measurement.prepare(remote_turn, remote_session)

    measurement =
      if remote_turn["state"] == "completed",
        do: Measurement.acceptance_attributes(measurement, now),
        else: measurement

    {:ok,
     record(
       %{
         kind: "learning",
         source_id: run.id,
         generation: to_string(run.generation),
         episode_id: nil,
         session_id: session_id,
         transport: batch.transport,
         conversation_ref: batch.conversation_ref,
         repository_ref: batch.repository_ref,
         execution_mode: to_string(batch.execution_mode)
       },
       remote_turn,
       measurement,
       now
     )}
  end

  @doc "Records host acceptance timing in the same transaction as result acceptance."
  def accepted_in_transaction(episode, session, turn) do
    record(
      work_identity(%{episode: episode, session: session, turn: turn}),
      %{"id" => turn.coop_turn_id, "state" => "completed"},
      Map.take(turn, @measurement_fields),
      turn.accepted_at
    )

    :ok
  end

  def attach_admission_in_transaction(entry) do
    Repo.update_all(
      from(e in Execution,
        where: e.kind == "admission" and e.source_id == ^entry.id and is_nil(e.episode_id)
      ),
      set: [episode_id: entry.episode_id]
    )

    :ok
  end

  defp work_identity(claim) do
    %{
      kind: "work",
      source_id: claim.turn.id,
      generation: "#{claim.session.generation}:#{claim.turn.submit_generation}",
      episode_id: claim.episode.id,
      session_id: claim.session.id,
      transport: claim.episode.destination_transport,
      conversation_ref: claim.episode.destination_conversation_ref,
      repository_ref: claim.session.repository_ref,
      execution_mode: to_string(claim.episode.execution_mode)
    }
  end

  defp record(identity, remote_turn, measurement, now) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "accounting requires an owner transaction")

    existing =
      Repo.one(
        from(e in Execution,
          where:
            e.kind == ^identity.kind and e.source_id == ^identity.source_id and
              e.generation == ^identity.generation,
          lock: "FOR UPDATE"
        )
      )

    current = existing || struct!(Execution, Map.put(identity, :recorded_at, now))

    attributes =
      merge_measurement(current, measurement)
      |> Map.merge(%{
        status: observed_status(current.status, remote_turn["state"]),
        remote_ref: current.remote_ref || remote_turn["id"]
      })

    changeset = Changeset.change(current, attributes)

    save(existing, changeset)
  end

  defp observed_status(current, _observed) when current in @terminal, do: current
  defp observed_status(_current, observed) when observed in @states, do: observed
  defp observed_status(nil, _observed), do: "requested"
  defp observed_status(current, _observed), do: current
  defp save(nil, changeset), do: Repo.insert!(changeset)
  defp save(current, %{changes: changes}) when map_size(changes) == 0, do: current
  defp save(_current, changeset), do: Repo.update!(changeset)

  # Coop reports cumulative turn counters, including its repair turns. Replays
  # and stale/partial observations never add that same cumulative amount again.
  # A missing observation cannot erase measurements already obtained.
  def merge_measurement(current, measurement) do
    target = measurement[:execution_target] || current.execution_target

    errors =
      String.split(measurement[:measurement_error_code] || "", ",", trim: true)
      |> Enum.reject(&(&1 == "invalid_target" and not is_nil(target)))

    %{
      execution_target: target,
      measurement_error_code: if(errors != [], do: Enum.join(errors, ","))
    }
    |> merge_tokens(current, measurement)
    |> merge_cost(current, measurement)
    |> merge_timing(current, measurement)
  end

  defp merge_tokens(attributes, current, %{usage_recorded: true} = measurement) do
    Enum.reduce(@token_fields, Map.put(attributes, :usage_recorded, true), fn key, acc ->
      Map.put(acc, key, max(measurement[key] || 0, Map.get(current, key) || 0))
    end)
  end

  defp merge_tokens(attributes, _current, _measurement), do: attributes

  defp merge_cost(attributes, current, %{usage_cost_recorded: true} = measurement) do
    cost = measurement.usage_cost_usd
    known = current.usage_cost_usd

    attributes
    |> Map.put(:usage_cost_recorded, true)
    |> Map.put(
      :usage_cost_usd,
      if(known && Decimal.compare(known, cost) == :gt, do: known, else: cost)
    )
  end

  defp merge_cost(attributes, _current, _measurement), do: attributes

  defp merge_timing(attributes, current, %{timing_recorded: true} = measurement) do
    timing =
      Map.take(measurement, @timing_fields) |> Map.reject(fn {_key, value} -> is_nil(value) end)

    # The host span is measured once, when the host first sees the finished turn.
    timing = if current.usage_host_ms, do: Map.delete(timing, :usage_host_ms), else: timing

    attributes |> Map.merge(timing) |> Map.put(:timing_recorded, true)
  end

  defp merge_timing(attributes, _current, _measurement), do: attributes

  defp result({:ok, _}), do: :ok
  defp result({:error, _} = error), do: error
end
