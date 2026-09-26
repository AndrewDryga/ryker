defmodule Ryker.TestHelpers do
  @moduledoc """
  Helpers that test suites each used to define for themselves (codebase
  wave 4): 31 copies of the SHA-256 digest and 6 of `eventually`, with waits
  from half a second to two.
  """

  @doc "Lowercase hex SHA-256 of a binary, as fixtures and receipts write it."
  @spec digest(iodata()) :: String.t()
  def digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  @doc """
  Whether `check` becomes true within `within_ms`, polling every 10 ms.

  For state another process changes on its own time; a message is better
  awaited with `assert_receive`.
  """
  @spec eventually((-> as_boolean(term())), pos_integer()) :: boolean()
  def eventually(check, within_ms \\ 2_000) when is_function(check, 0) do
    poll(check, System.monotonic_time(:millisecond) + within_ms)
  end

  defp poll(check, deadline) do
    cond do
      check.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        poll(check, deadline)
    end
  end
end
