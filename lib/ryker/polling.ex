defmodule Ryker.Polling do
  @moduledoc false

  require Logger

  @minimum_database_retry_ms 1_000

  @spec run(atom(), pos_integer(), (-> non_neg_integer())) :: non_neg_integer()
  def run(lane, interval_ms, cycle) do
    cycle.()
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      # Restarting every poller during a shared pool outage spends the supervisor
      # restart budget. Retry only on the next timer; durable claims still own work.
      # A statement the database refused is the same outage seen one step later;
      # its code names the refusal without the statement or its parameters.
      delay = max(interval_ms, @minimum_database_retry_ms)

      Logger.warning(
        "database polling unavailable; retrying after backoff (#{lane}, #{delay} ms#{refusal(error)})"
      )

      delay
  end

  defp refusal(%Postgrex.Error{postgres: %{code: code}}) when is_atom(code) and not is_nil(code),
    do: ", #{code}"

  defp refusal(_error), do: ""
end
