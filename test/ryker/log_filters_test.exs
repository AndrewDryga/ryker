defmodule Ryker.TestSupport.LogFiltersTest do
  use ExUnit.Case, async: true

  alias Ryker.TestSupport.LogFilters

  # Built the way DBConnection.Connection logs a disconnect, from its own
  # exception, so a change to its wording fails here rather than quietly
  # letting the lines back into every run.
  test "the test log drops DBConnection's report of a stopped client, and nothing else" do
    stopped = %DBConnection.ConnectionError{message: "client #PID<0.2482.0> exited"}
    assert LogFilters.dropped_client(disconnected(stopped), nil) == :stop

    for other <- [
          %DBConnection.ConnectionError{message: "tcp recv (idle): closed"},
          %DBConnection.ConnectionError{message: "client #PID<0.2482.0> exited: shutdown"},
          %RuntimeError{message: "client #PID<0.2482.0> exited"}
        ] do
      assert LogFilters.dropped_client(disconnected(other), nil) == :ignore
    end

    assert LogFilters.dropped_client(%{msg: {:report, %{label: :anything}}}, nil) == :ignore
  end

  defp disconnected(error) do
    message = [
      inspect(Postgrex.Protocol),
      ?\s,
      ?(,
      "#PID<0.385.0>",
      ") disconnected: " | Exception.format_banner(:error, error, [])
    ]

    %{level: :error, meta: %{}, msg: {:string, message}}
  end
end
