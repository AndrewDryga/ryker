defmodule Ryker.Admission.Attempts do
  @moduledoc "Fenced request artifacts and observed milestones for each admission execution generation."
  alias Ecto.Changeset
  alias Ryker.Admission.Attempt
  alias Ryker.CanonicalJSON
  alias Ryker.Ingress
  alias Ryker.Lease
  alias Ryker.Repo
  alias Ryker.Work

  @phases ~w(context_prepared execution_requested request_frozen provider_queued provider_running response_received host_validation committed)
  # The most refused answers one attempt keeps, the latest: Coop gives a
  # routing turn a handful of candidates, so this bound never decides what is
  # kept in practice.
  @kept_rejections 10
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
              Work.Measurement.prepare(%{}, %{"target" => settings[:execution_target]}),
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
    observations = Map.take(attributes, @observations)

    locked(entry, settings, &persist(&1, observations, phase, settings.now.()))
    |> case do
      {:ok, _attempt} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Keeps an answer host validation is about to send back, and why, on the
  attempt (`rejections`): each turn observed after it replaces `response`,
  so this is the only place the refused answer stays. `rejection` names the
  candidate's `attempt` and `sha256`, its `answer`, the `reason` code
  (`Ryker.Admission.refusal/1`) and the `correction` sent back. The same
  candidate again, as a retried validation sends it, is kept once.
  """
  @spec reject(Ingress.Inbox.Entry.t(), map(), map()) :: :ok | {:error, term()}
  def reject(
        %Ingress.Inbox.Entry{} = entry,
        %{"attempt" => number, "sha256" => sha256} = rejection,
        settings
      ) do
    locked(entry, settings, fn attempt ->
      kept = List.wrap(attempt.rejections)

      if Enum.any?(kept, &(&1["attempt"] == number and &1["sha256"] == sha256)),
        do: attempt,
        else:
          attempt
          |> Changeset.change(rejections: Enum.take(kept ++ [rejection], -@kept_rejections))
          |> Repo.update!()
    end)
    |> case do
      {:ok, _attempt} -> :ok
      {:error, reason} -> {:error, reason}
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
    measured = Work.Measurement.prepare(turn, %{"target" => settings[:execution_target]})

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
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Called inside the transaction which commits the input decision."
  def committed(%Ingress.Inbox.Entry{} = entry) do
    :ok = Ryker.Accounting.attach_admission_in_transaction(entry)

    case Repo.fetch(query(entry)) do
      {:error, :not_found} ->
        :ok

      {:ok, attempt} ->
        persist(attempt, %{}, "committed", entry.updated_at)
        :ok
    end
  end

  defp locked(entry, settings, action) do
    Repo.transaction(fn ->
      current =
        entry.id
        |> Ingress.Inbox.Entry.Query.by_id()
        |> Ingress.Inbox.Entry.Query.lock_for_update()
        |> Repo.peek()

      if is_nil(current) or current.status != :pending or
           not Lease.held?(current, settings.lease_ref, settings.now.()) or
           current.execution_generation != entry.execution_generation do
        Repo.rollback(:admission_attempt_lease_lost)
      end

      attempt =
        Repo.peek(query(entry)) ||
          Repo.insert!(%Attempt{
            input_id: entry.id,
            generation: entry.execution_generation,
            policy: settings.policy,
            policy_digest: settings.policy_digest,
            milestones: %{"context_prepared" => DateTime.to_iso8601(settings.now.())}
          })

      Ingress.Inbox.broadcast_input_updated(current)
      action.(attempt)
    end)
  end

  defp query(entry), do: Attempt.Query.by_generation(entry.id, entry.execution_generation)

  defp persist(attempt, attributes, phase, at) do
    # A reconciliation poll must not move the visible phase backwards or reset
    # its first-observed time. No percent-complete or private reasoning is inferred.
    phase = if rank(phase) > rank(attempt.phase), do: phase, else: attempt.phase
    milestones = Map.put_new(attempt.milestones, phase, DateTime.to_iso8601(at))

    attributes = Map.merge(attributes, %{phase: phase, milestones: milestones})
    changeset = Changeset.change(attempt, attributes)

    if changeset.changes == %{}, do: attempt, else: Repo.update!(changeset)
  end

  defp rank(phase), do: Enum.find_index(@phases, &(&1 == phase)) || -1
  defp measurement_value(%Decimal{} = value), do: Decimal.to_string(value)
  defp measurement_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp measurement_value(value), do: value
end
