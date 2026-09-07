defmodule Responder.Polling do
  @moduledoc false

  require Logger

  @minimum_database_retry_ms 1_000

  @spec run(atom(), pos_integer(), (-> non_neg_integer())) :: non_neg_integer()
  def run(lane, interval_ms, cycle) do
    cycle.()
  rescue
    DBConnection.ConnectionError ->
      # Restarting every poller during a shared pool outage spends the supervisor
      # restart budget. Retry only on the next timer; durable claims still own work.
      delay = max(interval_ms, @minimum_database_retry_ms)

      Logger.warning(
        "database polling unavailable; retrying after backoff (#{lane}, #{delay} ms)"
      )

      delay
  end
end
