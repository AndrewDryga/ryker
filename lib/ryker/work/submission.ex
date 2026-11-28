defmodule Ryker.Work.Submission do
  @moduledoc """
  Canonical, byte-stable input for one episode model turn.

  A retry must reuse this exact document. Session revisions and transport
  metadata are deliberately absent because they belong to the Coop operation,
  not to the model-visible turn.
  """
  alias Ryker.Artifacts
  alias Ryker.CanonicalJSON
  alias Ryker.Crypto
  alias Ryker.Maps

  @context_bytes 160 * 1_024
  @prompt_bytes 256 * 1_024
  @schema_bytes 256 * 1_024
  @submission_bytes 640 * 1_024

  @type t :: map()

  @spec new(map(), String.t(), map(), String.t(), [String.t()], map()) ::
          {:ok, t()} | {:error, term()}
  def new(
        context,
        prompt,
        output_schema,
        contract_version,
        input_artifact_refs \\ [],
        skill_documents \\ %{}
      ) do
    submission = %{
      "contract_version" => contract_version,
      "context" => context,
      "input_artifact_refs" => input_artifact_refs,
      "output_schema" => output_schema,
      "prompt" => prompt
    }

    submission =
      if skill_documents == %{},
        do: submission,
        else: Map.put(submission, "skill_documents", skill_documents)

    with :ok <- text(contract_version, 128, :contract_version),
         :ok <- document(context, @context_bytes, :context),
         :ok <- skill_pins(context, skill_documents),
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
      ) do
    if Maps.exact_keys?(
         submission,
         ~w(contract_version context input_artifact_refs output_schema prompt),
         ~w(skill_documents)
       ) do
      new(
        context,
        prompt,
        output_schema,
        contract_version,
        input_artifact_refs,
        Map.get(submission, "skill_documents", %{})
      )
    else
      {:error, {:invalid_work_submission, :fields}}
    end
  end

  def prepare(_submission), do: {:error, {:invalid_work_submission, :fields}}

  @spec fingerprint(t()) :: String.t()
  def fingerprint(submission), do: CanonicalJSON.digest(submission)

  # Verify the saved bytes against the descriptors in this turn, independently
  # of which revision of Ryker is now reading or retrying it.
  defp skill_pins(context, documents) when is_map(context) and is_map(documents) do
    entries = Map.get(context, "skills", [])

    if is_list(entries) and length(entries) == map_size(documents) and
         Enum.all?(entries, &pinned_skill?(&1, documents)) and
         Enum.uniq_by(entries, & &1["name"]) == entries do
      :ok
    else
      {:error, {:invalid_work_submission, :skills}}
    end
  end

  defp skill_pins(_context, _documents), do: {:error, {:invalid_work_submission, :skills}}

  defp pinned_skill?(%{"name" => name, "sha256" => digest}, documents) do
    document = Map.get(documents, name)
    is_binary(document) and Crypto.sha256_hex(document) == digest
  end

  defp pinned_skill?(_entry, _documents), do: false

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
    if length(refs) <= 5 and Enum.uniq(refs) == refs and
         Enum.all?(refs, &Artifacts.References.input_ref?/1),
       do: :ok,
       else: {:error, {:invalid_work_submission, :input_artifact_refs}}
  end

  defp artifact_refs(_refs), do: {:error, {:invalid_work_submission, :input_artifact_refs}}
end
