defmodule Ryker.ControlPlane.Search do
  @moduledoc "One spelling of a free-text search as a bounded SQL `ILIKE` pattern."

  @maximum_bytes 200

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
