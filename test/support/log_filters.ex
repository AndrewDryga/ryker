defmodule Ryker.TestSupport.LogFilters do
  @moduledoc """
  What the test log leaves out (`test/test_helper.exs`).

  ExUnit ends a test by stopping what it started, and a worker stopped in the
  middle of a query makes DBConnection log the connection it dropped. Every
  database test that starts a polling worker could end that way: 39 lines a
  run, which buried the output that mattered and said nothing about the code
  under test (2026-10-04 review). Letting each worker finish its message
  first was tried and swapped one noise for another: a worker that outlives
  its test logs what it does next and calls fakes that died with the test.
  """

  @doc "A `:logger` filter that drops DBConnection's report of a stopped client."
  @spec dropped_client(:logger.log_event(), term()) :: :logger.filter_return()
  def dropped_client(%{msg: {:string, message}}, _extra) do
    text = IO.chardata_to_string(message)

    if text =~ ") disconnected: ** (DBConnection.ConnectionError) client #PID<" and
         String.ends_with?(text, "> exited"),
       do: :stop,
       else: :ignore
  end

  def dropped_client(_event, _extra), do: :ignore
end
