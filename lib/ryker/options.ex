defmodule Ryker.Options do
  @moduledoc """
  Shapes trusted configuration into a map before a module checks its values.

  A keyword list must not repeat a key. A map may hold only known fields and
  must hold every required one. Each refusal raises `ArgumentError` in the
  caller's own words, because an operator reads them when Ryker will not start.
  """

  @typedoc """
  One message for every refusal, or one each for a bad list, a bad map and
  anything that is neither.
  """
  @type messages :: String.t() | [list: String.t(), map: String.t(), other: String.t()]

  @spec normalize!(term(), [atom()], [atom()], messages()) :: map()
  def normalize!(options, known, required, messages) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options),
      do: options |> Map.new() |> normalize!(known, required, messages),
      else: raise(ArgumentError, message(messages, :list))
  end

  def normalize!(%{} = options, known, required, messages) do
    if Map.keys(options) -- known == [] and Enum.all?(required, &Map.has_key?(options, &1)),
      do: options,
      else: raise(ArgumentError, message(messages, :map))
  end

  def normalize!(_options, _known, _required, messages),
    do: raise(ArgumentError, message(messages, :other))

  defp message(message, _refusal) when is_binary(message), do: message
  defp message(messages, refusal), do: Keyword.fetch!(messages, refusal)
end
