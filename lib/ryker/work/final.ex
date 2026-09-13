defmodule Ryker.Work.Final do
  @moduledoc """
  The small universal result contract for one episode turn.

  Human prose stays in `message`. Durable questions, waits, evidence, memory,
  tasks, and artifacts are referenced by their host-issued record IDs rather
  than copied into a large result envelope.
  """

  @deliveries [:reply, :none]
  @states [:complete, :waiting_for_input, :waiting_for_event]
  @fields ~w(decision_reason delivery message outcome)
  @outcome_fields ~w(artifact_refs record_refs state)
  @nonblank_pattern "^[^\\x00]*[^\\s\\x00][^\\x00]*$"
  @reference_pattern "^[A-Za-z0-9_.:-]{1,256}$"
  @reference_regex ~r/\A[A-Za-z0-9_.:-]{1,256}\z/

  @enforce_keys [:artifact_refs, :decision_reason, :delivery, :message, :record_refs, :state]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          artifact_refs: [String.t()],
          decision_reason: String.t() | nil,
          delivery: :reply | :none,
          message: String.t() | nil,
          record_refs: [String.t()],
          state: :complete | :waiting_for_input | :waiting_for_event
        }

  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(%{} = document) do
    with :ok <- exact_fields(document, @fields, :fields),
         {:ok, delivery} <- enum(document["delivery"], @deliveries, :delivery),
         :ok <- delivery_shape(delivery, document["message"], document["decision_reason"]),
         {:ok, outcome} <- outcome(document["outcome"]),
         :ok <- state_delivery(delivery, outcome) do
      {:ok,
       %__MODULE__{
         artifact_refs: outcome.artifact_refs,
         decision_reason: document["decision_reason"],
         delivery: delivery,
         message: document["message"],
         record_refs: outcome.record_refs,
         state: outcome.state
       }}
    end
  end

  def parse(_document), do: {:error, {:invalid_work_final, :type}}

  @spec document(t()) :: map()
  def document(%__MODULE__{} = final) do
    %{
      "decision_reason" => final.decision_reason,
      "delivery" => Atom.to_string(final.delivery),
      "message" => final.message,
      "outcome" => %{
        "artifact_refs" => final.artifact_refs,
        "record_refs" => final.record_refs,
        "state" => Atom.to_string(final.state)
      }
    }
  end

  @spec json_schema() :: map()
  def json_schema do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "additionalProperties" => false,
      "oneOf" => [
        %{
          "properties" => %{
            "decision_reason" => %{"type" => "null"},
            "delivery" => %{"const" => "reply"},
            "message" => bounded_string_schema(20_000)
          }
        },
        %{
          "properties" => %{
            "decision_reason" => bounded_string_schema(240),
            "delivery" => %{"const" => "none"},
            "message" => %{"type" => "null"}
          }
        }
      ],
      "properties" => %{
        "decision_reason" => %{
          "anyOf" => [bounded_string_schema(240), %{"type" => "null"}]
        },
        "delivery" => %{"enum" => Enum.map(@deliveries, &Atom.to_string/1)},
        "message" => %{
          "anyOf" => [bounded_string_schema(20_000), %{"type" => "null"}]
        },
        "outcome" => %{
          "additionalProperties" => false,
          "properties" => %{
            "artifact_refs" => reference_array_schema(5),
            "record_refs" => reference_array_schema(64),
            "state" => %{"enum" => Enum.map(@states, &Atom.to_string/1)}
          },
          "required" => @outcome_fields,
          "type" => "object"
        }
      },
      "required" => @fields,
      "title" => "Ryker episode result",
      "type" => "object"
    }
  end

  defp outcome(%{} = value) do
    with :ok <- exact_fields(value, @outcome_fields, :outcome),
         {:ok, state} <- enum(value["state"], @states, :state),
         :ok <- references(value["record_refs"], 64, :record_refs),
         :ok <- references(value["artifact_refs"], 5, :artifact_refs) do
      {:ok,
       %{
         artifact_refs: value["artifact_refs"],
         record_refs: value["record_refs"],
         state: state
       }}
    end
  end

  defp outcome(_value), do: {:error, {:invalid_work_final, :outcome}}

  defp delivery_shape(:reply, message, nil) do
    if bounded_text?(message, 20_000),
      do: :ok,
      else: {:error, {:invalid_work_final, :message}}
  end

  defp delivery_shape(:none, nil, reason) do
    if bounded_text?(reason, 240),
      do: :ok,
      else: {:error, {:invalid_work_final, :decision_reason}}
  end

  defp delivery_shape(_delivery, _message, _reason),
    do: {:error, {:invalid_work_final, :delivery_shape}}

  defp state_delivery(:none, %{state: :complete}), do: :ok

  defp state_delivery(:none, %{state: :waiting_for_event, record_refs: [_ | _]}), do: :ok

  defp state_delivery(:none, _outcome),
    do: {:error, {:invalid_work_final, :state_requires_visible_reply}}

  defp state_delivery(:reply, %{state: :complete}), do: :ok

  defp state_delivery(:reply, %{record_refs: [_first | _rest]}), do: :ok

  defp state_delivery(:reply, _outcome),
    do: {:error, {:invalid_work_final, :waiting_state_requires_record}}

  defp references(value, maximum, field)
       when is_list(value) and length(value) <= maximum do
    if Enum.uniq(value) == value and Enum.all?(value, &reference?/1),
      do: :ok,
      else: {:error, {:invalid_work_final, field}}
  end

  defp references(_value, _maximum, field),
    do: {:error, {:invalid_work_final, field}}

  defp enum(value, allowed, field) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_work_final, field}}
      parsed -> {:ok, parsed}
    end
  end

  defp enum(_value, _allowed, field), do: {:error, {:invalid_work_final, field}}

  defp exact_fields(value, fields, field) do
    if Map.keys(value) |> Enum.sort() == Enum.sort(fields),
      do: :ok,
      else: {:error, {:invalid_work_final, field}}
  end

  defp bounded_text?(value, maximum) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != "" and String.length(value) <= maximum
  end

  defp bounded_string_schema(maximum) do
    %{
      "maxLength" => maximum,
      "minLength" => 1,
      "pattern" => @nonblank_pattern,
      "type" => "string"
    }
  end

  defp reference_array_schema(maximum) do
    %{
      "items" => %{
        "maxLength" => 256,
        "minLength" => 1,
        "pattern" => @reference_pattern,
        "type" => "string"
      },
      "maxItems" => maximum,
      "type" => "array",
      "uniqueItems" => true
    }
  end

  defp reference?(value),
    do: is_binary(value) and String.valid?(value) and Regex.match?(@reference_regex, value)
end
