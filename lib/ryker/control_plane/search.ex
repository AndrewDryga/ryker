defmodule Ryker.ControlPlane.Search do
  @moduledoc "One spelling of a free-text search as a bounded SQL `ILIKE` pattern."

  # Characters, which String.slice/3 counts, not bytes.
  @maximum_length 200

  @doc "The trimmed, bounded search a directory was asked for, or nil when it was asked for nothing."
  @spec term(term()) :: String.t() | nil
  def term(value) when is_binary(value) do
    search = value |> String.trim() |> String.slice(0, @maximum_length)
    if search != "", do: search
  end

  def term(_value), do: nil

  @doc """
  A list page's query: the search, and whether it shows current items or
  past ones ("past" only when asked for).
  """
  @spec current_or_past(map()) :: %{String.t() => String.t()}
  def current_or_past(params),
    do: %{
      "q" => term(params["q"]) || "",
      "view" => if(params["view"] == "past", do: "past", else: "current")
    }

  @doc "The one allowed status a filter names, or nil when it names none."
  @spec one_of(term(), [atom()]) :: atom() | nil
  def one_of(value, allowed) when is_binary(value) do
    Enum.find(allowed, &(Atom.to_string(&1) == String.trim(value)))
  end

  def one_of(_value, _allowed), do: nil

  @doc """
  Whether a string anywhere in the JSON `document` matches the `ILIKE`
  `pattern` (`contains/1`), the document's field names aside. Searching the
  document as text matched every row that had a field of the name searched
  for (2026-10-04 review).
  """
  defmacro json_text_matches(document, pattern) do
    quote do
      fragment(
        "EXISTS (SELECT 1 FROM jsonb_path_query((?)::jsonb, 'strict $.**') AS found(value) WHERE jsonb_typeof(found.value) = 'string' AND (found.value #>> '{}') ILIKE ?)",
        unquote(document),
        unquote(pattern)
      )
    end
  end

  @doc """
  The `ILIKE` pattern that matches text containing `text`, with the pattern
  characters in the search escaped so a `%` or `_` typed by a person matches
  itself.
  """
  @spec contains(String.t()) :: String.t()
  def contains(text) when is_binary(text) do
    escaped =
      text
      |> String.slice(0, @maximum_length)
      |> String.replace(["\\", "%", "_"], &("\\" <> &1))

    "%" <> escaped <> "%"
  end
end
