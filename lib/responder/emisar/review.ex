defmodule Responder.Emisar.Review do
  @moduledoc """
  The trusted Emisar review receipt, validated and projected for one card.

  Emisar decides; Responder only carries what it decided. Every number here is
  Emisar's own — the distinct-approver tally is never recounted from the history,
  so a replayed or duplicated vote cannot manufacture a quorum — and every
  reviewer, reason and override comes from a recorded decision rather than from
  the run's status. An override is an explicit authoritative event: it is never
  inferred from a short tally, never becomes a vote, and cannot be rendered
  without the reason Emisar requires for it.

  A document that does not validate is refused whole. The card then keeps the
  last receipt it could prove instead of showing a decision nobody made.
  """

  alias Responder.CanonicalJSON

  @statuses ~w(pending approved denied expired cancelled)
  @decisions ~w(approve deny)
  @command_kinds ~w(preview executed)
  @required ~w(approved_count decisions request_id required_approvals status)
  @optional ~w(argument_count command decisions_omitted evidence expected override reason)
  @decision_required ~w(decided_at decision)
  @decision_optional ~w(actor reason)
  @override_required ~w(approved_count decided_at reason required_approvals waived_approvals)
  @override_optional ~w(actor)
  @command_required ~w(kind text truncated)
  @maximum_decisions 20
  @maximum_actor_bytes 255
  @maximum_reason_bytes 2_000
  @maximum_evidence_bytes 4_000
  @maximum_command_bytes 2_000
  # Emisar's own ceiling for a snapshotted approval requirement. A host bound
  # below it would fail a legitimate receipt closed and freeze the card.
  @maximum_count 2_147_483_647

  @spec prepare(term()) :: {:ok, map() | nil} | {:error, term()}
  def prepare(nil), do: {:ok, nil}

  def prepare(%{} = review) do
    with :ok <- fields(review, @required, @optional),
         :ok <- reference(review["request_id"], 80),
         true <- review["status"] in @statuses,
         :ok <- count(review["required_approvals"], 1),
         :ok <- count(review["approved_count"], 0),
         true <- review["approved_count"] <= review["required_approvals"],
         :ok <- optional_count(review["argument_count"], 0),
         :ok <- optional_count(review["decisions_omitted"], 1),
         :ok <- optional_text(review["reason"], @maximum_reason_bytes),
         :ok <- optional_text(review["evidence"], @maximum_evidence_bytes),
         :ok <- optional_text(review["expected"], @maximum_reason_bytes),
         :ok <- command(review["command"]),
         :ok <- decisions(review["decisions"]),
         :ok <- override(review["override"]) do
      {:ok, review}
    else
      _invalid -> {:error, {:invalid_emisar_review, :document}}
    end
  end

  def prepare(_review), do: {:error, {:invalid_emisar_review, :document}}

  @doc """
  The stable digest of one presented receipt, or `nil` for a run no human
  reviewed.

  It is what lets the monitor repaint on a real review change — a vote, a
  decision, an override — without repainting on every poll of an unchanged one.
  """
  @spec digest(map() | nil) :: String.t() | nil
  def digest(nil), do: nil
  def digest(%{} = review), do: CanonicalJSON.digest(review)

  @doc """
  The card's current status line and its decision history, oldest first.

  The summary states the outcome once; the history names each recorded decision
  on its own line. A single terminal decision IS the whole history, so it is
  stated once with its actor and reason and no duplicate event.
  """
  @spec summary(map()) :: %{summary: String.t(), history: [String.t()]}
  def summary(%{} = review) do
    history = Enum.map(review["decisions"], &decision_line/1)

    case review["override"] do
      nil -> stated(review, history)
      override -> overridden(review, override, history)
    end
  end

  # One terminal decision IS the whole history: state its actor and reason once,
  # with no duplicate event under it and no empty history gap.
  defp stated(%{"status" => "approved", "decisions" => [%{"decision" => "approve"} = only]}, _),
    do: %{summary: decision_line(only), history: []}

  defp stated(%{"status" => "denied", "decisions" => [%{"decision" => "deny"} = only]}, _),
    do: %{summary: decision_line(only), history: []}

  defp stated(review, history), do: %{summary: outcome(review), history: history}

  defp overridden(review, override, history) do
    %{
      summary:
        "✓ Review granted#{attributed(override["actor"])}#{tally_clause(review)}; remaining reviews were overridden.",
      history:
        history ++
          [
            "⚠ Review granted#{attributed(override["actor"])} · admin override.#{reason_clause(override["reason"])}"
          ]
    }
  end

  defp outcome(%{"status" => "pending"} = review), do: "◷ #{tally(review)}."

  # A terminal denial states its decider and carries no approval-only counter,
  # which would read as progress toward a release that will never happen.
  defp outcome(%{"status" => "denied"} = review),
    do: "✕ Review denied#{attributed(actor(review, "deny"))}."

  # A quorum grant belongs to the group, so it credits the count rather than one
  # name; the history below it names each reviewer.
  defp outcome(%{"status" => "approved", "required_approvals" => 1} = review),
    do: "✓ Review granted#{attributed(actor(review, "approve"))}."

  defp outcome(%{"status" => "approved"} = review),
    do: "✓ Review granted#{tally_clause(review)}."

  defp outcome(%{"status" => "expired"} = review),
    do: "◷ Review window expired. #{tally(review)}."

  defp outcome(%{"status" => "cancelled"} = review),
    do: "■ Review cancelled. #{tally(review)}."

  defp decision_line(decision) do
    verdict = if decision["decision"] == "deny", do: "✕ Review denied", else: "✓ Review granted"
    "#{verdict}#{attributed(decision["actor"])}.#{reason_clause(decision["reason"])}"
  end

  # Decisions arrive oldest first, so the terminal one is the last of its kind.
  defp actor(review, decision) do
    review["decisions"]
    |> Enum.filter(&(&1["decision"] == decision))
    |> List.last()
    |> case do
      nil -> nil
      terminal -> terminal["actor"]
    end
  end

  defp tally(review),
    do: "#{review["approved_count"]} of #{review["required_approvals"]} reviews received"

  defp tally_clause(review), do: "; #{tally(review)}"

  defp attributed(nil), do: ""
  defp attributed(actor), do: " by #{actor}"

  defp reason_clause(nil), do: ""

  defp reason_clause(reason) do
    case String.trim(reason) do
      "" -> ""
      trimmed -> " Reason: #{trimmed}"
    end
  end

  defp decisions(values) when is_list(values) and length(values) <= @maximum_decisions do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case decision(value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp decisions(_values), do: {:error, :decisions}

  defp decision(%{} = decision) do
    with :ok <- fields(decision, @decision_required, @decision_optional),
         true <- decision["decision"] in @decisions,
         :ok <- timestamp(decision["decided_at"]),
         :ok <- optional_text(decision["actor"], @maximum_actor_bytes),
         :ok <- optional_text(decision["reason"], @maximum_reason_bytes) do
      :ok
    else
      _invalid -> {:error, :decision}
    end
  end

  defp decision(_decision), do: {:error, :decision}

  defp override(nil), do: :ok

  defp override(%{} = override) do
    with :ok <- fields(override, @override_required, @override_optional),
         # An override without its mandatory reason is an unexplained release.
         :ok <- reference(override["reason"], @maximum_reason_bytes),
         :ok <- count(override["required_approvals"], 1),
         :ok <- count(override["approved_count"], 0),
         :ok <- count(override["waived_approvals"], 0),
         :ok <- optional_text(override["actor"], @maximum_actor_bytes),
         :ok <- timestamp(override["decided_at"]) do
      :ok
    else
      _invalid -> {:error, :override}
    end
  end

  defp override(_override), do: {:error, :override}

  defp command(nil), do: :ok

  defp command(%{} = command) do
    with :ok <- fields(command, @command_required, []),
         true <- command["kind"] in @command_kinds,
         :ok <- reference(command["text"], @maximum_command_bytes),
         true <- is_boolean(command["truncated"]) do
      :ok
    else
      _invalid -> {:error, :command}
    end
  end

  defp command(_command), do: {:error, :command}

  defp fields(document, required, optional) do
    keys = Map.keys(document)

    if Enum.all?(required, &(&1 in keys)) and Enum.all?(keys, &(&1 in (required ++ optional))),
      do: :ok,
      else: {:error, :fields}
  end

  defp count(value, minimum)
       when is_integer(value) and value >= minimum and value <= @maximum_count,
       do: :ok

  defp count(_value, _minimum), do: {:error, :count}

  defp optional_count(nil, _minimum), do: :ok
  defp optional_count(value, minimum), do: count(value, minimum)

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, 0} -> :ok
      _invalid -> {:error, :timestamp}
    end
  end

  defp timestamp(_value), do: {:error, :timestamp}

  defp optional_text(nil, _maximum), do: :ok
  defp optional_text(value, maximum), do: reference(value, maximum)

  defp reference(value, maximum) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, :reference}
  end
end
