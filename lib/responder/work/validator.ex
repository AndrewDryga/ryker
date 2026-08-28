defmodule Responder.Work.Validator do
  @moduledoc """
  Deterministic semantic admission for one universal final candidate.

  This validator gates only host-owned facts: references exist, an explicit
  human request is not silently dropped, and a waiting outcome names the exact
  durable wait that will resume it. It deliberately does not grade arbitrary
  prose, infer cause, or impose alert-specific checklists.
  """

  alias Responder.Work.{Final, Result}

  @context_fields ~w(artifact_refs records visible_reply_required)
  @reference_regex ~r/\A[A-Za-z0-9_.:-]{1,256}\z/

  @type accepted :: %{final: Final.t(), result: Result.t()}
  @type outcome :: {:accept, accepted()} | {:reject, [String.t()]} | {:error, term()}

  @spec validate(String.t(), map(), DateTime.t()) :: outcome()
  def validate(candidate, context, %DateTime{} = now) do
    with {:ok, context} <- prepare_context(context),
         {:ok, final} <- parse_candidate(candidate) do
      violations = semantic_violations(final, context, now)

      case violations do
        [] -> accept(final, context, now)
        [_first | _rest] -> {:reject, violations}
      end
    else
      {:reject, _violations} = rejection -> rejection
      {:error, _reason} = error -> error
    end
  end

  def validate(_candidate, _context, _now),
    do: {:error, {:invalid_work_validation_context, :now}}

  defp parse_candidate(candidate) when is_binary(candidate) do
    case Jason.decode(candidate) do
      {:ok, %{} = document} ->
        parse_final(document)

      {:ok, _other} ->
        reject(
          "Return one JSON object matching the attached output schema; the candidate is not a JSON object."
        )

      {:error, _reason} ->
        reject(
          "Return one JSON object matching the attached output schema; the candidate is not valid JSON."
        )
    end
  end

  defp parse_candidate(_candidate) do
    reject(
      "Return one JSON object matching the attached output schema; the candidate is not valid JSON."
    )
  end

  defp parse_final(document) do
    case Final.parse(document) do
      {:ok, final} -> {:ok, final}
      {:error, {:invalid_work_final, field}} -> reject(final_violation(field))
    end
  end

  defp semantic_violations(final, context, now) do
    []
    |> visibility_violations(final, context)
    |> missing_record_violations(final, context)
    |> missing_artifact_violations(final, context)
    |> continuation_violations(final, context, now)
    |> Enum.reverse()
  end

  defp visibility_violations(violations, %{delivery: :none}, %{
         visible_reply_required: true
       }) do
    [
      "Set delivery to reply and answer the user: an explicit human request cannot be silently discarded."
      | violations
    ]
  end

  defp visibility_violations(violations, _final, _context), do: violations

  defp missing_record_violations(violations, final, context) do
    Enum.reduce(final.record_refs, violations, fn ref, accumulated ->
      if Map.has_key?(context.records, ref) do
        accumulated
      else
        [
          "Remove outcome.record_refs entry #{inspect(ref)} or create that durable record first; no record with that host-issued reference exists in this episode."
          | accumulated
        ]
      end
    end)
  end

  defp missing_artifact_violations(violations, final, context) do
    Enum.reduce(final.artifact_refs, violations, fn ref, accumulated ->
      if MapSet.member?(context.artifact_refs, ref) do
        accumulated
      else
        [
          "Remove outcome.artifact_refs entry #{inspect(ref)} or create that artifact first; no deliverable artifact with that host-issued reference exists in this episode."
          | accumulated
        ]
      end
    end)
  end

  defp continuation_violations(violations, final, context, now) do
    waits = referenced_waits(final, context)

    case {final.state, waits} do
      {:complete, []} ->
        violations

      {:complete, [_first | _rest]} ->
        [
          "Set outcome.state to the matching waiting state or omit the wait record; complete cannot reference a pending durable wait."
          | violations
        ]

      {:waiting_for_input, [record]} ->
        validate_wait(violations, record, :input, now)

      {:waiting_for_event, [record]} ->
        validate_wait(violations, record, :event, now)

      {:waiting_for_input, []} ->
        [
          "outcome.state waiting_for_input requires exactly one referenced durable input wait created with request_input; no input wait was referenced."
          | violations
        ]

      {:waiting_for_event, []} ->
        [
          "outcome.state waiting_for_event requires exactly one referenced durable event wait created with wait_for; no event wait was referenced."
          | violations
        ]

      {:waiting_for_input, waits} ->
        [
          "outcome.state waiting_for_input must reference exactly one durable input wait, but #{length(waits)} wait records were referenced."
          | violations
        ]

      {:waiting_for_event, waits} ->
        [
          "outcome.state waiting_for_event must reference exactly one durable event wait, but #{length(waits)} wait records were referenced."
          | violations
        ]
    end
  end

  defp validate_wait(violations, %{continuation: continuation, ref: ref}, expected_kind, now) do
    actual_kind = continuation_kind(continuation)

    cond do
      actual_kind != expected_kind ->
        [
          "outcome.state waiting_for_#{expected_kind} must reference an #{expected_kind} wait, but #{inspect(ref)} is an #{actual_kind || :invalid} wait."
          | violations
        ]

      expected_kind == :event and elapsed?(continuation, now) ->
        [
          "The event wait #{inspect(ref)} has an elapsed or invalid deadline; create a new wait with wait_for or finish the response now."
          | violations
        ]

      true ->
        violations
    end
  end

  defp referenced_waits(final, context) do
    final.record_refs
    |> Enum.flat_map(fn ref ->
      case context.records[ref] do
        %{continuation: continuation} when is_map(continuation) ->
          [%{continuation: continuation, ref: ref}]

        _not_a_wait ->
          []
      end
    end)
  end

  defp accept(final, context, now) do
    continuation = accepted_continuation(final, context)

    result =
      case final.delivery do
        :reply -> Result.new(:reply, Final.document(final), nil, continuation)
        :none -> Result.new(:none, nil, final.decision_reason, continuation)
      end

    with {:ok, result} <- result,
         :ok <- Result.validate_at(result, now) do
      {:accept, %{final: final, result: result}}
    else
      {:error, reason} -> {:error, {:work_validator_result_invalid, reason}}
    end
  end

  defp accepted_continuation(%{state: :complete}, _context), do: %{"kind" => "complete"}

  defp accepted_continuation(final, context) do
    [%{continuation: continuation}] = referenced_waits(final, context)
    continuation
  end

  defp prepare_context(%{} = context) do
    with :ok <- exact_context_fields(context),
         true <- is_boolean(context["visible_reply_required"]),
         {:ok, artifacts} <- prepare_artifacts(context["artifact_refs"]),
         {:ok, records} <- prepare_records(context["records"]) do
      {:ok,
       %{
         artifact_refs: artifacts,
         records: records,
         visible_reply_required: context["visible_reply_required"]
       }}
    else
      false -> {:error, {:invalid_work_validation_context, :visible_reply_required}}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_context(_context), do: {:error, {:invalid_work_validation_context, :type}}

  defp exact_context_fields(context) do
    if Map.keys(context) |> Enum.sort() == @context_fields,
      do: :ok,
      else: {:error, {:invalid_work_validation_context, :fields}}
  end

  defp prepare_artifacts(refs) when is_list(refs) do
    if Enum.uniq(refs) == refs and Enum.all?(refs, &reference?/1),
      do: {:ok, MapSet.new(refs)},
      else: {:error, {:invalid_work_validation_context, :artifact_refs}}
  end

  defp prepare_artifacts(_refs),
    do: {:error, {:invalid_work_validation_context, :artifact_refs}}

  defp prepare_records(records) when is_map(records) do
    Enum.reduce_while(records, {:ok, %{}}, fn {ref, record}, {:ok, prepared} ->
      case prepare_record(ref, record) do
        {:ok, record} -> {:cont, {:ok, Map.put(prepared, ref, record)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp prepare_records(_records), do: {:error, {:invalid_work_validation_context, :records}}

  defp prepare_record(ref, %{"continuation" => continuation, "kind" => kind} = record)
       when map_size(record) == 2 do
    with true <- reference?(ref),
         true <- reference?(kind),
         {:ok, continuation} <- prepare_record_continuation(continuation) do
      {:ok, %{continuation: continuation, kind: kind}}
    else
      false -> {:error, {:invalid_work_validation_context, :record}}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_record(_ref, _record),
    do: {:error, {:invalid_work_validation_context, :record}}

  defp prepare_record_continuation(nil), do: {:ok, nil}

  defp prepare_record_continuation(continuation) when is_map(continuation) do
    case Result.new(:reply, %{"message" => "validation"}, nil, continuation) do
      {:ok, result} -> {:ok, result.continuation}
      {:error, _reason} -> {:error, {:invalid_work_validation_context, :continuation}}
    end
  end

  defp prepare_record_continuation(_continuation),
    do: {:error, {:invalid_work_validation_context, :continuation}}

  defp continuation_kind(%{"kind" => "wait", "wait_kind" => "input"}), do: :input
  defp continuation_kind(%{"kind" => "wait", "wait_kind" => "event"}), do: :event
  defp continuation_kind(_continuation), do: nil

  defp elapsed?(%{"deadline_at" => deadline_at}, now) do
    case DateTime.from_iso8601(deadline_at) do
      {:ok, deadline, 0} -> DateTime.compare(deadline, now) != :gt
      _invalid -> true
    end
  end

  defp reject(violation), do: {:reject, [violation]}

  defp final_violation(:type),
    do: "Return one JSON object matching the attached output schema."

  defp final_violation(:fields),
    do:
      "The top-level object must contain exactly decision_reason, delivery, message, and outcome; remove unknown fields and add missing fields."

  defp final_violation(:delivery),
    do: "delivery must be exactly reply or none."

  defp final_violation(:message),
    do:
      "For delivery reply, message must be nonblank text with no NUL character and at most 20,000 Unicode characters."

  defp final_violation(:decision_reason),
    do:
      "For delivery none, decision_reason must be nonblank text with no NUL character and at most 240 Unicode characters."

  defp final_violation(:delivery_shape),
    do:
      "For delivery reply, provide message and set decision_reason to null; for delivery none, set message to null and provide decision_reason."

  defp final_violation(:outcome),
    do:
      "outcome must contain exactly artifact_refs, record_refs, and state using the attached output schema."

  defp final_violation(:state),
    do: "outcome.state must be complete, waiting_for_input, or waiting_for_event."

  defp final_violation(:record_refs),
    do:
      "outcome.record_refs must contain at most 64 unique host-issued references using only letters, numbers, underscore, dot, colon, or hyphen, each at most 256 characters."

  defp final_violation(:artifact_refs),
    do:
      "outcome.artifact_refs must contain at most 5 unique host-issued references using only letters, numbers, underscore, dot, colon, or hyphen, each at most 256 characters."

  defp final_violation(:state_requires_visible_reply),
    do: "A waiting outcome requires delivery reply; delivery none may be used only with complete."

  defp final_violation(:waiting_state_requires_record),
    do:
      "A waiting outcome must reference the durable request_input or wait_for record that will resume it."

  defp reference?(value),
    do: is_binary(value) and String.valid?(value) and Regex.match?(@reference_regex, value)
end
