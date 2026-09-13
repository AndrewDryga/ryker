defmodule Ryker.Evals.WorkCase do
  @moduledoc """
  Compiles the sanitized universal Work corpus into real model eval cases.

  The model receives the production Work prompt and final-result schema. Host
  validity is checked by `Ryker.Work.Validator`; the eval layer scores only
  the small behavioral expectation that remains, such as visible delivery or a
  material term from the recorded request.
  """

  alias Ryker.CanonicalJSON
  alias Ryker.Work.{Final, Prompt, Validator}

  @corpus_path "testdata/elixir-eval/work.jsonl"
  @fields ~w(context eval_id expectation now reason source validation_context)
  @deliveries ~w(reply none)
  @states ~w(complete waiting_for_input waiting_for_event)
  @expectation_fields ~w(delivery message_contains message_excludes state)
  @reference_regex ~r/\A[A-Za-z0-9_.:-]{1,256}\z/

  @enforce_keys [
    :eval_id,
    :expectation,
    :now,
    :prompt,
    :reason,
    :schema,
    :source,
    :source_document,
    :validation_context
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          eval_id: String.t(),
          expectation: map(),
          now: DateTime.t(),
          prompt: String.t(),
          reason: String.t(),
          schema: map(),
          source: map(),
          source_document: map(),
          validation_context: map()
        }

  @spec all(Path.t()) :: {:ok, [t()]} | {:error, term()}
  def all(path \\ @corpus_path) do
    with {:ok, contents} <- File.read(path),
         {:ok, cases} <- decode_lines(contents, path),
         :ok <- unique(cases) do
      {:ok, cases}
    else
      {:error, {:invalid_work_eval_file, _path, _line, _reason}} = error -> error
      {:error, {:invalid_work_eval_corpus, _reason}} = error -> error
      {:error, reason} -> {:error, {:invalid_work_eval_file, path, reason}}
    end
  end

  @spec compile(map()) :: {:ok, t()} | {:error, term()}
  def compile(%{} = document) do
    with :ok <- exact_fields(document, @fields, :fields),
         :ok <- reference(document["eval_id"], :eval_id),
         :ok <- bounded_text(document["reason"], 2_048, :reason),
         :ok <- canonical_map(document["source"], 16 * 1_024, :source),
         {:ok, now} <- datetime(document["now"]),
         :ok <- canonical_map(document["context"], 160 * 1_024, :context),
         {:ok, expectation} <- expectation(document["expectation"]),
         :ok <- validation_context(document["validation_context"], expectation, now) do
      {:ok,
       %__MODULE__{
         eval_id: document["eval_id"],
         expectation: expectation,
         now: now,
         prompt: Prompt.build(document["context"]),
         reason: document["reason"],
         schema: Final.json_schema(),
         source: document["source"],
         source_document: document,
         validation_context: document["validation_context"]
       }}
    end
  end

  def compile(_document), do: {:error, {:invalid_work_eval, :fields}}

  @spec document(t()) :: map()
  def document(%__MODULE__{} = eval) do
    %{
      "eval_id" => eval.eval_id,
      "expectation" => eval.expectation,
      "prompt" => Jason.decode!(eval.prompt),
      "reason" => eval.reason,
      "schema" => eval.schema,
      "source" => eval.source,
      "validation_context" => eval.validation_context
    }
  end

  @doc false
  @spec source_document(t()) :: map()
  def source_document(%__MODULE__{} = eval), do: eval.source_document

  @spec validate(t(), String.t()) :: Validator.outcome()
  def validate(%__MODULE__{} = eval, candidate) do
    Validator.validate(candidate, eval.validation_context, eval.now)
  end

  @spec assess(t(), Validator.accepted()) :: {:ok, Final.t()} | {:error, term()}
  def assess(%__MODULE__{} = eval, %{final: %Final{} = final}) do
    submitted = Final.document(final)
    message = String.downcase(final.message || "")

    missing =
      Enum.reject(eval.expectation["message_contains"], fn term ->
        String.contains?(message, String.downcase(term))
      end)

    forbidden =
      Enum.filter(eval.expectation["message_excludes"], fn term ->
        String.contains?(message, String.downcase(term))
      end)

    details =
      %{submitted: submitted}
      |> mismatch(
        :expected_delivery,
        Atom.to_string(final.delivery) != eval.expectation["delivery"],
        eval.expectation["delivery"]
      )
      |> mismatch(
        :expected_state,
        Atom.to_string(final.state) != eval.expectation["state"],
        eval.expectation["state"]
      )
      |> mismatch(:missing_message_terms, missing != [], missing)
      |> mismatch(:forbidden_message_terms, forbidden != [], forbidden)

    if map_size(details) == 1,
      do: {:ok, final},
      else: {:error, {:work_eval_mismatch, details}}
  end

  def assess(_eval, _accepted), do: {:error, {:invalid_work_eval, :accepted}}

  defp decode_lines(contents, path) do
    contents
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, &decode_line(&1, &2, path))
    |> case do
      {:ok, cases} ->
        {:ok, Enum.reverse(cases)}

      {:error, {line_number, reason}} ->
        {:error, {:invalid_work_eval_file, path, line_number, reason}}

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_line({line, line_number}, {:ok, cases}, path) do
    case String.trim(line) do
      "" -> {:cont, {:ok, cases}}
      "#" <> _comment -> {:cont, {:ok, cases}}
      encoded -> decode_encoded_line(encoded, line_number, cases, path)
    end
  end

  defp decode_encoded_line(encoded, line_number, cases, path) do
    case Jason.decode(encoded) do
      {:ok, %{} = document} -> compile_line(document, line_number, cases)
      {:ok, _other} -> invalid_json_object(path, line_number)
      {:error, reason} -> {:halt, {:error, {:invalid_work_eval_file, path, line_number, reason}}}
    end
  end

  defp compile_line(document, line_number, cases) do
    case compile(document) do
      {:ok, eval} -> {:cont, {:ok, [eval | cases]}}
      {:error, reason} -> {:halt, {:error, {line_number, reason}}}
    end
  end

  defp invalid_json_object(path, line_number) do
    {:halt, {:error, {:invalid_work_eval_file, path, line_number, :json_object_required}}}
  end

  defp unique(cases) do
    ids = Enum.map(cases, & &1.eval_id)

    if Enum.uniq(ids) == ids,
      do: :ok,
      else: {:error, {:invalid_work_eval_corpus, :duplicate_eval_id}}
  end

  defp expectation(%{} = expectation) do
    with :ok <- exact_fields(expectation, @expectation_fields, :expectation),
         true <- expectation["delivery"] in @deliveries,
         true <- expectation["state"] in @states,
         :ok <- terms(expectation["message_contains"]),
         :ok <- terms(expectation["message_excludes"]),
         true <-
           MapSet.disjoint?(
             normalized_terms(expectation["message_contains"]),
             normalized_terms(expectation["message_excludes"])
           ),
         true <- expectation["delivery"] == "reply" or expectation["message_contains"] == [] do
      {:ok, expectation}
    else
      _invalid -> {:error, {:invalid_work_eval, :expectation}}
    end
  end

  defp expectation(_expectation), do: {:error, {:invalid_work_eval, :expectation}}

  defp validation_context(context, expectation, now) when is_map(context) do
    probe =
      if expectation["delivery"] == "none" do
        %{
          "decision_reason" => "Eval validation probe.",
          "delivery" => "none",
          "message" => nil,
          "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
        }
      else
        %{
          "decision_reason" => nil,
          "delivery" => "reply",
          "message" => "Eval validation probe.",
          "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
        }
      end

    case Validator.validate(Jason.encode!(probe), context, now) do
      {:error, {:invalid_work_validation_context, _field}} ->
        {:error, {:invalid_work_eval, :validation_context}}

      {:error, _reason} ->
        {:error, {:invalid_work_eval, :validation_context}}

      {:accept, _accepted} ->
        :ok

      {:reject, _violations} ->
        :ok
    end
  end

  defp validation_context(_context, _expectation, _now),
    do: {:error, {:invalid_work_eval, :validation_context}}

  defp exact_fields(value, fields, field) do
    if Map.keys(value) |> Enum.sort() == Enum.sort(fields),
      do: :ok,
      else: {:error, {:invalid_work_eval, field}}
  end

  defp canonical_map(value, maximum, field) when is_map(value) and map_size(value) > 0 do
    case CanonicalJSON.validate(value, max_bytes: maximum) do
      :ok -> :ok
      {:error, _reason} -> {:error, {:invalid_work_eval, field}}
    end
  end

  defp canonical_map(_value, _maximum, field), do: {:error, {:invalid_work_eval, field}}

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> {:error, {:invalid_work_eval, :now}}
    end
  end

  defp datetime(_value), do: {:error, {:invalid_work_eval, :now}}

  defp terms(values) when is_list(values) and length(values) <= 20 do
    if Enum.uniq(values) == values and Enum.all?(values, &valid_term?/1),
      do: :ok,
      else: {:error, {:invalid_work_eval, :expectation}}
  end

  defp terms(_values), do: {:error, {:invalid_work_eval, :expectation}}

  defp normalized_terms(values), do: MapSet.new(values, &String.downcase/1)

  defp valid_term?(value), do: bounded_text(value, 256, :term) == :ok

  defp bounded_text(value, maximum, _field)
       when is_binary(value) and byte_size(value) in 1..maximum//1 do
    if String.valid?(value) and String.trim(value) != "" and
         :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_work_eval, :text}}
  end

  defp bounded_text(_value, _maximum, field), do: {:error, {:invalid_work_eval, field}}

  defp reference(value, _field) when is_binary(value) do
    if String.valid?(value) and Regex.match?(@reference_regex, value),
      do: :ok,
      else: {:error, {:invalid_work_eval, :reference}}
  end

  defp reference(_value, field), do: {:error, {:invalid_work_eval, field}}

  defp mismatch(details, _field, false, _value), do: details
  defp mismatch(details, field, true, value), do: Map.put(details, field, value)
end
