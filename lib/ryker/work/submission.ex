defmodule Ryker.Work.Submission do
  @moduledoc """
  Canonical, byte-stable input for one episode model turn.

  A retry must reuse this exact document. Session revisions and transport
  metadata are deliberately absent because they belong to the Coop operation,
  not to the model-visible turn.
  """

  alias Ryker.CanonicalJSON

  @context_bytes 160 * 1_024
  @prompt_bytes 256 * 1_024
  @schema_bytes 256 * 1_024
  @submission_bytes 640 * 1_024

  @type t :: map()

  @spec new(map(), String.t(), map(), String.t()) :: {:ok, t()} | {:error, term()}
  def new(context, prompt, output_schema, contract_version) do
    new(context, prompt, output_schema, contract_version, [])
  end

  @spec new(map(), String.t(), map(), String.t(), [String.t()]) ::
          {:ok, t()} | {:error, term()}
  def new(context, prompt, output_schema, contract_version, input_artifact_refs) do
    submission = %{
      "contract_version" => contract_version,
      "context" => context,
      "input_artifact_refs" => input_artifact_refs,
      "output_schema" => output_schema,
      "prompt" => prompt
    }

    with :ok <- text(contract_version, 128, :contract_version),
         :ok <- document(context, @context_bytes, :context),
         :ok <- artifact_refs(input_artifact_refs),
         :ok <- text(prompt, @prompt_bytes, :prompt),
         :ok <- document(output_schema, @schema_bytes, :output_schema),
         :ok <- canonical(submission, @submission_bytes, :submission) do
      {:ok, submission}
    end
  end

  @spec prepare(term()) :: {:ok, t()} | {:error, term()}
  def prepare(
        %{
          "contract_version" => contract_version,
          "context" => context,
          "input_artifact_refs" => input_artifact_refs,
          "output_schema" => output_schema,
          "prompt" => prompt
        } = submission
      )
      when map_size(submission) == 5 do
    new(context, prompt, output_schema, contract_version, input_artifact_refs)
  end

  def prepare(
        %{
          "contract_version" => contract_version,
          "context" => context,
          "output_schema" => output_schema,
          "prompt" => prompt
        } = submission
      )
      when map_size(submission) == 4,
      do: new(context, prompt, output_schema, contract_version)

  def prepare(_submission), do: {:error, {:invalid_work_submission, :fields}}

  @spec fingerprint(t()) :: String.t()
  def fingerprint(submission), do: CanonicalJSON.digest(submission)

  defp document(value, maximum, field) when is_map(value),
    do: canonical(value, maximum, field)

  defp document(_value, _maximum, field),
    do: {:error, {:invalid_work_submission, field}}

  defp canonical(value, maximum, field) do
    case CanonicalJSON.validate(value, max_bytes: maximum) do
      :ok -> :ok
      {:error, _reason} -> {:error, {:invalid_work_submission, field}}
    end
  end

  defp text(value, maximum, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, {:invalid_work_submission, field}}
  end

  defp artifact_refs(refs) when is_list(refs) do
    if length(refs) <= 5 and Enum.uniq(refs) == refs and Enum.all?(refs, &artifact_ref?/1),
      do: :ok,
      else: {:error, {:invalid_work_submission, :input_artifact_refs}}
  end

  defp artifact_refs(_refs), do: {:error, {:invalid_work_submission, :input_artifact_refs}}

  defp artifact_ref?(value) do
    is_binary(value) and byte_size(value) in 1..128 and
      String.starts_with?(value, "artifact:input:")
  end
end
