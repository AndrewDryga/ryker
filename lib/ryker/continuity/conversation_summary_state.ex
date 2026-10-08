defmodule Ryker.Continuity.ConversationSummaryState do
  @moduledoc false
  alias Ryker.CanonicalJSON
  alias Ryker.JSONSchema
  alias Ryker.Maps
  alias Ryker.Reference

  @fields ~w(active_topics decisions evidence_refs goal open_loops participants purpose situation topology unresolved_questions)
  @list_fields ~w(active_topics decisions evidence_refs open_loops participants topology unresolved_questions)
  @reference_fields ~w(evidence_refs)
  @maximum_bytes 32 * 1_024
  @maximum_items 20
  @maximum_text 2_000
  @maximum_reference 1_024

  @spec fields() :: [String.t()]
  def fields, do: @fields

  @spec list_fields() :: [String.t()]
  def list_fields, do: @list_fields

  @spec prepare(term()) :: {:ok, map()} | {:error, term()}
  def prepare(%{} = state) do
    with :ok <- exact_fields(state),
         :ok <- optional_text(state["goal"], "goal"),
         :ok <- optional_text(state["purpose"], "purpose"),
         :ok <- optional_text(state["situation"], "situation"),
         :ok <- lists(state),
         :ok <- canonical(state) do
      {:ok, state}
    end
  end

  def prepare(_state), do: {:error, {:invalid_conversation_summary, :state}}

  @spec json_schema() :: map()
  def json_schema do
    text = %{"maxLength" => @maximum_text, "minLength" => 1, "type" => "string"}
    nullable_text = JSONSchema.nullable(text)

    properties = %{
      "active_topics" => text_array(text),
      "decisions" => text_array(text),
      "evidence_refs" => text_array(reference_schema()),
      "goal" => nullable_text,
      "open_loops" => text_array(text),
      "participants" => text_array(text),
      "purpose" => nullable_text,
      "situation" => nullable_text,
      "topology" => text_array(text),
      "unresolved_questions" => text_array(text)
    }

    %{
      "additionalProperties" => false,
      "properties" => properties,
      "required" => @fields,
      "type" => "object"
    }
  end

  defp exact_fields(state) do
    if Maps.exact_keys?(state, @fields),
      do: :ok,
      else: {:error, {:invalid_conversation_summary, :fields}}
  end

  # Text is held to the characters its schema promises (code points), so a
  # summary written in Ukrainian may be as long as one in English; a
  # reference is ASCII and is held in bytes.
  defp lists(state) do
    Enum.reduce_while(@list_fields, :ok, fn field, :ok ->
      valid? =
        if field in @reference_fields,
          do: &Reference.valid?(&1, @maximum_reference),
          else: &Reference.text?(&1, @maximum_text)

      case text_list(state[field], valid?) do
        :ok -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, {:invalid_conversation_summary, field}}}
      end
    end)
  end

  defp text_list(values, valid?)
       when is_list(values) and length(values) <= @maximum_items do
    if values == Enum.uniq(values) and Enum.all?(values, valid?),
      do: :ok,
      else: {:error, :invalid}
  end

  defp text_list(_values, _valid?), do: {:error, :invalid}

  defp optional_text(nil, _field), do: :ok

  defp optional_text(value, field) do
    if Reference.text?(value, @maximum_text),
      do: :ok,
      else: {:error, {:invalid_conversation_summary, field}}
  end

  defp canonical(state) do
    case CanonicalJSON.validate(state, max_bytes: @maximum_bytes) do
      :ok -> :ok
      {:error, _reason} -> {:error, {:invalid_conversation_summary, :bytes}}
    end
  end

  defp text_array(item),
    do: %{
      "items" => item,
      "maxItems" => @maximum_items,
      "minItems" => 0,
      "type" => "array",
      "uniqueItems" => true
    }

  defp reference_schema do
    %{
      "maxLength" => @maximum_reference,
      "minLength" => 1,
      "pattern" => "^[A-Za-z0-9_.:/-]+$",
      "type" => "string"
    }
  end
end
