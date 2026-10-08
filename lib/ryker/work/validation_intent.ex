defmodule Ryker.Work.ValidationIntent do
  @moduledoc """
  The exact semantic verdict persisted before Ryker mutates a Coop turn.

  A lost response or process restart reuses this document. It contains both the
  precise Coop verdict and, for acceptance, the exact host result that may later
  become a delivery intent.
  """
  alias Ryker.{CanonicalJSON, Maps, Text}
  alias Ryker.Work.Result

  @fields ~w(result verdict violations)
  @maximum_violations 20
  @maximum_violation_bytes 4_096

  @type t :: map()

  @spec new(:accept | {:reject, [String.t()]}, Result.t() | nil) ::
          {:ok, t()} | {:error, term()}
  def new(:accept, %Result{} = result) do
    case Result.prepare(result) do
      {:ok, result} ->
        {:ok,
         %{
           "result" => Result.document(result),
           "verdict" => "accept",
           "violations" => []
         }}

      {:error, _reason} ->
        {:error, {:invalid_work_validation_intent, :result}}
    end
  end

  def new(:accept, _result), do: {:error, {:invalid_work_validation_intent, :result}}

  def new({:reject, violations}, nil) do
    with {:ok, normalized} <- normalize_rejection(violations),
         {:ok, fitted} <- normalize_violations(fit(normalized)) do
      {:ok, %{"result" => nil, "verdict" => "reject", "violations" => fitted}}
    else
      :error -> {:error, {:invalid_work_validation_intent, :violations}}
    end
  end

  def new({:reject, _violations}, _result),
    do: {:error, {:invalid_work_validation_intent, :result}}

  def new(_verdict, _result), do: {:error, {:invalid_work_validation_intent, :verdict}}

  @spec prepare(term()) :: {:ok, t()} | {:error, term()}
  def prepare(%{} = intent) do
    if Maps.exact_keys?(intent, @fields) do
      prepare_shape(intent)
    else
      {:error, {:invalid_work_validation_intent, :fields}}
    end
  end

  def prepare(_intent), do: {:error, {:invalid_work_validation_intent, :document}}

  @spec fingerprint(t()) :: String.t()
  def fingerprint(intent), do: CanonicalJSON.digest(intent)

  @spec result(t()) :: {:ok, Result.t() | nil} | {:error, term()}
  def result(%{"result" => nil, "verdict" => "reject"}), do: {:ok, nil}

  def result(%{"result" => document, "verdict" => "accept"}),
    do: Result.prepare_document(document)

  def result(_intent), do: {:error, {:invalid_work_validation_intent, :result}}

  defp prepare_shape(%{"result" => result, "verdict" => "accept", "violations" => []}) do
    case Result.prepare_document(result) do
      {:ok, prepared} -> new(:accept, prepared)
      {:error, _reason} -> {:error, {:invalid_work_validation_intent, :result}}
    end
  end

  defp prepare_shape(%{"result" => nil, "verdict" => "reject", "violations" => violations}),
    do: new({:reject, violations}, nil)

  defp prepare_shape(_intent), do: {:error, {:invalid_work_validation_intent, :shape}}

  defp normalize_violations(violations)
       when is_list(violations) and length(violations) in 1..@maximum_violations do
    normalized = Enum.map(violations, &normalize_violation/1)

    if Enum.all?(normalized, &is_binary/1) and
         Enum.sum(Enum.map(normalized, &(byte_size(&1) + 1))) <= @maximum_violation_bytes do
      {:ok, normalized}
    else
      :error
    end
  end

  defp normalize_violations(_violations), do: :error

  defp normalize_rejection([_one | _rest] = violations) do
    normalized = Enum.map(violations, &normalize_violation(&1, :unbounded))
    if Enum.all?(normalized, &is_binary/1), do: {:ok, normalized}, else: :error
  end

  defp normalize_rejection(_violations), do: :error

  # A candidate can have more problems than Coop takes back with a rejection:
  # twenty, 4 KiB in all. A longer list was refused outright, and the turn
  # blocked for a person instead of going back to the model (2026-10-04
  # review). The first problems go back in order, with how many more there
  # were.
  defp fit([single]), do: [Text.cut(single, @maximum_violation_bytes - 1)]

  defp fit(violations) do
    if fits?(violations), do: violations, else: shortened(violations, length(violations))
  end

  defp shortened(violations, total) do
    (min(total, @maximum_violations) - 1)..1//-1
    |> Enum.map(&(Enum.take(violations, &1) ++ [more(total - &1)]))
    |> Enum.find(&fits?/1) || first_and_more(violations, total)
  end

  defp first_and_more([first | _rest], total) do
    more = more(total - 1)
    [Text.cut(first, @maximum_violation_bytes - byte_size(more) - 2), more]
  end

  defp fits?(violations) do
    length(violations) <= @maximum_violations and
      Enum.sum(Enum.map(violations, &(byte_size(&1) + 1))) <= @maximum_violation_bytes
  end

  defp more(1), do: "1 more problem was found; fix these first and it is checked again."

  defp more(count),
    do: "#{count} more problems were found; fix these first and they are checked again."

  defp normalize_violation(violation, bound \\ @maximum_violation_bytes)

  defp normalize_violation(violation, bound) when is_binary(violation) do
    normalized = String.trim(violation)

    if String.valid?(normalized) and normalized != "" and within?(normalized, bound) and
         :binary.match(normalized, <<0>>) == :nomatch,
       do: normalized,
       else: nil
  end

  defp normalize_violation(_violation, _bound), do: nil

  defp within?(_text, :unbounded), do: true
  defp within?(text, bound), do: byte_size(text) <= bound
end
