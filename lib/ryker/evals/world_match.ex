defmodule Ryker.Evals.WorldMatch do
  @moduledoc """
  Strict matcher for important normalized model-world tool arguments.

  Ordinary maps are recursive subsets. `$one_of` makes finite source aliases
  or bounded text-pattern alternatives explicit. `$contains_all` lets a
  reviewed fixture name the bounded concepts that a free-form source query
  must contain without hiding one magic query string from the model.
  """

  @maximum_alternatives 32
  @maximum_contains_terms 16
  @maximum_contains_term_bytes 128

  @spec matches?(term(), term()) :: boolean()
  def matches?(%{"$one_of" => alternatives} = pattern, actual)
      when map_size(pattern) == 1 and is_list(alternatives) do
    Enum.any?(alternatives, &matches?(&1, actual))
  end

  def matches?(%{"$contains_all" => terms} = pattern, actual)
      when map_size(pattern) == 1 and is_list(terms) and is_binary(actual) do
    if Enum.all?(terms, &is_binary/1) do
      actual = String.downcase(actual)
      Enum.all?(terms, &String.contains?(actual, String.downcase(&1)))
    else
      false
    end
  end

  def matches?(expected, actual) when is_map(expected) and is_map(actual) do
    Enum.all?(expected, fn {key, value} ->
      Map.has_key?(actual, key) and matches?(value, actual[key])
    end)
  end

  def matches?(expected, actual) when is_list(expected) and is_list(actual) do
    length(expected) == length(actual) and
      expected
      |> Enum.zip(actual)
      |> Enum.all?(fn {expected_value, actual_value} ->
        matches?(expected_value, actual_value)
      end)
  end

  def matches?(expected, actual), do: expected == actual

  @spec valid?(term()) :: boolean()
  def valid?(%{"$one_of" => alternatives} = pattern) when map_size(pattern) == 1 do
    is_list(alternatives) and alternatives != [] and
      length(alternatives) <= @maximum_alternatives and
      Enum.uniq(alternatives) == alternatives and Enum.all?(alternatives, &valid_value?/1)
  end

  def valid?(%{"$contains_all" => terms} = pattern) when map_size(pattern) == 1 do
    is_list(terms) and terms != [] and length(terms) <= @maximum_contains_terms and
      Enum.all?(terms, &valid_contains_term?/1) and
      terms |> Enum.map(&String.downcase/1) |> then(&(Enum.uniq(&1) == &1))
  end

  def valid?(pattern) when is_map(pattern) do
    Enum.all?(pattern, fn
      {"$" <> _operator, _value} -> false
      {key, value} when is_binary(key) -> valid?(value)
      _invalid -> false
    end)
  end

  def valid?(pattern) when is_list(pattern), do: Enum.all?(pattern, &valid?/1)
  def valid?(pattern), do: valid_scalar?(pattern)

  defp valid_value?(%{"$contains_all" => _terms} = value), do: valid?(value)

  defp valid_value?(value) when is_map(value) do
    if Enum.any?(Map.keys(value), &match?("$" <> _operator, &1)),
      do: false,
      else: valid?(value)
  end

  defp valid_value?(value), do: valid?(value)

  defp valid_contains_term?(term) when is_binary(term) do
    String.valid?(term) and String.trim(term) == term and term != "" and
      byte_size(term) <= @maximum_contains_term_bytes and
      :binary.match(term, <<0>>) == :nomatch
  end

  defp valid_contains_term?(_term), do: false

  defp valid_scalar?(value),
    do: is_nil(value) or is_boolean(value) or is_binary(value) or is_number(value)
end
