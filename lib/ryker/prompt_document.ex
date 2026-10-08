defmodule Ryker.PromptDocument do
  @moduledoc """
  The text admission, self-analysis and repository reading send a model: one
  JSON object with the instructions first and the context after them, the
  context's keys in the order the prompt reads best and any others after
  those, alphabetically. Canonical key order put the instructions last, where
  they could never be a cached prefix.

  A context that had to leave something out for length lists what in its
  `"omitted"` notes (`omit/2`).
  """
  alias Ryker.CanonicalJSON

  @doc "The prompt text: instructions first, then the context's keys in `order`, then the rest."
  @spec render(%{String.t() => term()}, [String.t()]) :: String.t()
  def render(%{"instructions" => instructions, "context" => context}, order) do
    keys =
      context
      |> Map.keys()
      |> Enum.sort_by(&{Enum.find_index(order, fn key -> key == &1 end) || length(order), &1})

    IO.iodata_to_binary([
      ~s({"instructions":),
      CanonicalJSON.encode!(instructions),
      ~s(,"context":{),
      Enum.map_intersperse(keys, ",", fn key ->
        [CanonicalJSON.encode!(key), ":", CanonicalJSON.encode!(context[key])]
      end),
      "}}"
    ])
  end

  @doc "`context` with `note` in its `\"omitted\"` list, once."
  @spec omit(%{String.t() => term()}, String.t()) :: %{String.t() => term()}
  def omit(context, note) do
    if note in context["omitted"],
      do: context,
      else: Map.update!(context, "omitted", &(&1 ++ [note]))
  end
end
