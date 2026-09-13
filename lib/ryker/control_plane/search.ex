defmodule Ryker.ControlPlane.Search do
  @moduledoc "One spelling of a free-text search as a bounded SQL `ILIKE` pattern."

  @maximum_bytes 200

  @doc "The trimmed, bounded search a directory was asked for, or nil when it was asked for nothing."
  @spec term(term()) :: String.t() | nil
  def term(value) when is_binary(value) do
    case value |> String.trim() |> String.slice(0, @maximum_bytes) do
      "" -> nil
      search -> search
    end
  end

  def term(_value), do: nil

  @doc "The one allowed status a filter names, or nil when it names none."
  @spec one_of(term(), [atom()]) :: atom() | nil
  def one_of(value, allowed) when is_binary(value) do
    Enum.find(allowed, &(Atom.to_string(&1) == String.trim(value)))
  end

  def one_of(_value, _allowed), do: nil

  @doc """
  The `ILIKE` pattern that matches text containing `text`, with the pattern
  characters in the search escaped so a `%` or `_` typed by a person matches
  itself.
  """
  @spec contains(String.t()) :: String.t()
  def contains(text) when is_binary(text) do
    escaped =
      text
      |> String.slice(0, @maximum_bytes)
      |> String.replace(["\\", "%", "_"], &("\\" <> &1))

    "%" <> escaped <> "%"
  end
end
