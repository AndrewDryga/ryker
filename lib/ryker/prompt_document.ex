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
  alias Ryker.Text

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

  @doc """
  `context` made smaller by each of `steps` in turn until the prompt of
  `instructions` and `context` fits in `max_bytes` once encoded. A step that
  changes nothing more is done with, whether or not the prompt fits yet.
  """
  @spec fit(term(), map(), pos_integer(), [(map() -> map())]) :: map()
  def fit(instructions, context, max_bytes, steps),
    do: Enum.reduce(steps, context, &until_fits(instructions, &2, max_bytes, &1))

  @doc "Whether the prompt of `instructions` and `context` is at most `max_bytes` once encoded."
  @spec fits?(term(), map(), pos_integer()) :: boolean()
  def fits?(instructions, context, max_bytes) do
    encoded = CanonicalJSON.encode!(%{"instructions" => instructions, "context" => context})
    byte_size(encoded) <= max_bytes
  end

  defp until_fits(instructions, context, max_bytes, step) do
    if fits?(instructions, context, max_bytes),
      do: context,
      else: smaller(instructions, context, max_bytes, step, step.(context))
  end

  defp smaller(_instructions, context, _max_bytes, _step, context), do: context

  defp smaller(instructions, _context, max_bytes, step, next),
    do: until_fits(instructions, next, max_bytes, step)

  @cut_marker " …[cut]"

  @doc """
  The start of `text` within `max_bytes`, never splitting a character, and a
  marker after it that tells the model the rest was cut.
  """
  @spec cut(String.t(), non_neg_integer()) :: String.t()
  def cut(text, max_bytes) when is_binary(text), do: Text.bytes(text, max_bytes) <> @cut_marker

  @doc "`context` with `note` in its `\"omitted\"` list, once."
  @spec omit(%{String.t() => term()}, String.t()) :: %{String.t() => term()}
  def omit(context, note) do
    if note in context["omitted"],
      do: context,
      else: Map.update!(context, "omitted", &(&1 ++ [note]))
  end
end
