defmodule Ryker.Admission.Attempts do
  @moduledoc "Fenced request artifacts and observed milestones for each admission execution generation."
  import Ecto.Query
  alias Ecto.Changeset
  alias Ryker.Admission.Attempt
  alias Ryker.CanonicalJSON
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Work.Measurement

  @phases ~w(context_prepared execution_requested request_frozen provider_queued provider_running response_received host_validation committed)
  @observations [:session_ref, :turn_ref, :execution_target, :measurements, :response]

  def prepare(entry, settings), do: locked(entry, settings, & &1)

  def freeze(entry, submission, settings) do
    with :ok <- CanonicalJSON.validate(submission, max_bytes: 320 * 1_024) do
      locked(entry, settings, fn
        %Attempt{submission: nil} = attempt ->
          {:ok, _} =
            Ryker.Accounting.observe_admission_in_transaction(
              entry,
              %{"state" => "requested"},
              Measurement.prepare(%{}, %{"target" => settings[:execution_target]}),
              settings.now.()
            )

          persist(
            attempt,
            %{submission: submission, submission_fingerprint: CanonicalJSON.digest(submission)},
            "request_frozen",
            settings.now.()
          )

        attempt ->
          attempt
      end)
    end
  end

  def observe(entry, phase, attributes, settings) when phase in @phases and is_map(attributes) do
    locked(entry, settings, fn attempt ->
      persist(attempt, Map.take(attributes, @observations), phase, settings.now.())
    end)
    |> case do
      {:ok, _attempt} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def observe_turn(entry, turn, settings) do
    phase =
      case turn["state"] do
        state when state in ~w(queued starting) -> "provider_queued"
        "running" -> "provider_running"
        _terminal_or_candidate -> "response_received"
      end

    response =
      Map.take(
        turn,
        ~w(state assistant_message candidate validation_attempt validation_candidate_sha256 validation_receipt error_code)
      )

    # Measurement.prepare validates the provider's counters; malformed optional
    # telemetry is marked missing and cannot reject a valid admission decision.
    measured = Measurement.prepare(turn, %{"target" => settings[:execution_target]})

    locked(entry, settings, fn attempt ->
      {:ok, recorded} =
        Ryker.Accounting.observe_admission_in_transaction(
          entry,
          turn,
          measured,
          settings.now.()
        )

      measurement =
        recorded
        |> Map.take(Ryker.Accounting.measurement_fields())
        |> Map.new(fn {key, value} -> {Atom.to_string(key), measurement_value(value)} end)

      persist(
        attempt,
        %{turn_ref: turn["id"], response: response, measurements: measurement},
        phase,
        settings.now.()
      )
    end)
    |> case do
      {:ok, _attempt} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Called inside the transaction which commits the input decision."
  def committed(%Entry{} = entry) do
    :ok = Ryker.Accounting.attach_admission_in_transaction(entry)

    case Repo.one(query(entry)) do
      nil ->
        :ok

      attempt ->
        persist(attempt, %{}, "committed", entry.updated_at)
        :ok
    end
  end

  defp locked(entry, settings, action) do
    Repo.transaction(fn ->
      current = Repo.one(from(input in Entry, where: input.id == ^entry.id, lock: "FOR UPDATE"))

      if is_nil(current) or current.status != :pending or current.lease_ref != settings.lease_ref or
           current.execution_generation != entry.execution_generation or
           is_nil(current.lease_expires_at) or
           DateTime.compare(current.lease_expires_at, settings.now.()) != :gt do
        Repo.rollback(:admission_attempt_lease_lost)
      end

      attempt =
        Repo.one(query(entry)) ||
          Repo.insert!(%Attempt{
            input_id: entry.id,
            generation: entry.execution_generation,
            policy: settings.policy,
            policy_digest: settings.policy_digest,
            milestones: %{"context_prepared" => DateTime.to_iso8601(settings.now.())}
          })

      action.(attempt)
    end)
  end

  defp query(entry),
    do:
      from(attempt in Attempt,
        where: attempt.input_id == ^entry.id and attempt.generation == ^entry.execution_generation
      )

  defp persist(attempt, attributes, phase, at) do
    # A reconciliation poll must not move the visible phase backwards or reset
    # its first-observed time. No percent-complete or private reasoning is inferred.
    phase = if rank(phase) > rank(attempt.phase), do: phase, else: attempt.phase
    milestones = Map.put_new(attempt.milestones, phase, DateTime.to_iso8601(at))

    changeset =
      Changeset.change(attempt, Map.merge(attributes, %{phase: phase, milestones: milestones}))

    if changeset.changes == %{}, do: attempt, else: Repo.update!(changeset)
  end

  defp rank(phase), do: Enum.find_index(@phases, &(&1 == phase)) || -1
  defp measurement_value(%Decimal{} = value), do: Decimal.to_string(value)
  defp measurement_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp measurement_value(value), do: value
end
