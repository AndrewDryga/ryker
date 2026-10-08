defmodule Ryker.Wording do
  @moduledoc """
  The few English words Ryker builds rather than writes out: a count and its
  noun ("1 message", "3 entries"), a whole number with thousands separators,
  a list in a sentence ("a, b and c"), and a capital first letter. The
  console, Slack cards, the weekly report, repository notes and the model's
  tool errors all say these the same way.

  A phrase whose plural is not its noun's regular one passes both forms:
  `count(n, "worker is", "workers are")`.
  """

  @doc ~s(The count and its noun: "1 entry", "3 entries". Without `many`, the regular plural of `one`.)
  @spec count(integer(), String.t(), String.t() | nil) :: String.t()
  def count(count, one, many \\ nil) when is_integer(count),
    do: "#{count} #{word(count, one, many)}"

  @doc ~s(The noun alone, singular only for exactly one: "entry", "entries".)
  @spec word(integer(), String.t(), String.t() | nil) :: String.t()
  def word(count, one, many \\ nil)
  def word(1, one, _many), do: one
  def word(_count, one, nil), do: plural(one)
  def word(_count, _one, many), do: many

  @doc ~s(The regular English plural of `noun`: "entry" → "entries", "day" → "days", "box" → "boxes".)
  @spec plural(String.t()) :: String.t()
  def plural(noun) when is_binary(noun) do
    cond do
      String.ends_with?(noun, ~w(ay ey oy uy)) -> noun <> "s"
      String.ends_with?(noun, "y") -> String.slice(noun, 0..-2//1) <> "ies"
      String.ends_with?(noun, ~w(s x z ch sh)) -> noun <> "es"
      true -> noun <> "s"
    end
  end

  @doc ~s(A whole number with thousands separators: "12,345".)
  @spec number(integer()) :: String.t()
  def number(number) when is_integer(number),
    do: number |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")

  @doc ~s(Items in a sentence: "a", "a and b", "a, b and c".)
  @spec list([String.t(), ...]) :: String.t()
  def list([only]), do: only

  def list([_first | _rest] = items) do
    {leading, [last]} = Enum.split(items, -1)
    Enum.join(leading, ", ") <> " and " <> last
  end

  @doc """
  `text` with its first letter in capitals and the rest as written, so a name
  or a Slack mention inside keeps its case (`String.capitalize/1` lowers the
  rest, and Slack could not resolve a lowered id).
  """
  @spec capitalize(String.t()) :: String.t()
  def capitalize(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  def capitalize(text) when is_binary(text), do: text

  @doc "`text` as a sentence: a capital first letter and a full stop; empty text stays empty."
  @spec sentence(String.t()) :: String.t()
  def sentence(""), do: ""
  def sentence(text) when is_binary(text), do: capitalize(text) <> "."
end
