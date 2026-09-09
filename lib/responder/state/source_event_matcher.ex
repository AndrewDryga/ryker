defmodule Responder.State.SourceEventMatcher do
  @moduledoc """
  Recursive content matching shared by source-event automations and waits.

  Object filters require every named field. Nonempty lists of object filters
  require each object to match one actual element, regardless of order or extra
  fields/elements. Fields from separate elements cannot satisfy one object.
  Empty lists, scalar lists, and scalar values retain exact equality.
  """

  @spec matches?(term(), term()) :: boolean()
  def matches?(expected, actual) when is_map(expected) and is_map(actual) do
    Enum.all?(expected, fn {key, value} ->
      case Map.fetch(actual, key) do
        {:ok, actual_value} -> matches?(value, actual_value)
        :error -> false
      end
    end)
  end

  def matches?([_ | _] = expected, actual) when is_list(actual) do
    if Enum.all?(expected, &is_map/1) do
      Enum.all?(expected, fn filter -> Enum.any?(actual, &matches?(filter, &1)) end)
    else
      expected == actual
    end
  end

  def matches?(expected, actual), do: expected == actual
end
