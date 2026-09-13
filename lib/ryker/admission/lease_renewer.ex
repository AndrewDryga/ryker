defmodule Ryker.Admission.LeaseRenewer do
  @moduledoc false

  @spec new(DateTime.t(), pos_integer(), (-> DateTime.t()), (DateTime.t() ->
                                                               :ok | {:error, term()})) ::
          (-> :ok | {:error, term()})
  def new(%DateTime{} = claimed_at, lease_seconds, now, renew)
      when is_integer(lease_seconds) and lease_seconds > 0 and is_function(now, 0) and
             is_function(renew, 1) do
    cadence_ms = max(div(lease_seconds * 1_000, 3), 1)
    next_due = :atomics.new(1, signed: true)
    :atomics.put(next_due, 1, unix_milliseconds(claimed_at) + cadence_ms)

    fn -> maybe_renew(next_due, cadence_ms, now, renew) end
  end

  defp maybe_renew(next_due, cadence_ms, now, renew) do
    renewed_at = now.()
    current_ms = unix_milliseconds(renewed_at)

    if current_ms < :atomics.get(next_due, 1) do
      :ok
    else
      case renew.(renewed_at) do
        :ok ->
          :atomics.put(next_due, 1, current_ms + cadence_ms)
          :ok

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp unix_milliseconds(datetime), do: DateTime.to_unix(datetime, :millisecond)
end
