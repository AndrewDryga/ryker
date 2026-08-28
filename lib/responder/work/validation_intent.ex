defmodule Responder.Work.ValidationIntent do
  @moduledoc """
  The exact semantic verdict persisted before Responder mutates a Coop turn.

  A lost response or process restart reuses this document. It contains both the
  precise Coop verdict and, for acceptance, the exact host result that may later
  become a delivery intent.
  """

  alias Responder.CanonicalJSON
  alias Responder.Work.Result

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
    case normalize_violations(violations) do
      {:ok, normalized} ->
        {:ok, %{"result" => nil, "verdict" => "reject", "violations" => normalized}}

      :error ->
        {:error, {:invalid_work_validation_intent, :violations}}
    end
  end

  def new({:reject, _violations}, _result),
    do: {:error, {:invalid_work_validation_intent, :result}}

  def new(_verdict, _result), do: {:error, {:invalid_work_validation_intent, :verdict}}

  @spec prepare(term()) :: {:ok, t()} | {:error, term()}
  def prepare(%{} = intent) do
    if Map.keys(intent) |> Enum.sort() == @fields do
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

  defp normalize_violation(violation) when is_binary(violation) do
    normalized = String.trim(violation)

    if String.valid?(normalized) and byte_size(normalized) in 1..@maximum_violation_bytes and
         :binary.match(normalized, <<0>>) == :nomatch,
       do: normalized,
       else: nil
  end

  defp normalize_violation(_violation), do: nil
end
