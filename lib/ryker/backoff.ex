defmodule Ryker.Backoff do
  @moduledoc """
  How long to wait before trying again: `base` after the first try, twice as
  long after each further one, never longer than `maximum`. The unit is the
  caller's own: seconds for a dispatcher's retry, milliseconds for a
  reconnect.
  """

  @doc "Whether `base` and `maximum` bound a backoff: both positive, the maximum no smaller."
  @spec valid?(term(), term()) :: boolean()
  def valid?(base, maximum),
    do: is_integer(base) and base > 0 and is_integer(maximum) and maximum >= base

  @doc """
  The wait after `attempt` tries (the first waits `base`), doubling at most
  `doublings` times and never past `maximum`.
  """
  @spec delay(integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def delay(attempt, base, maximum, doublings \\ 20)
      when is_integer(attempt) and is_integer(base) and base >= 0 and is_integer(maximum) and
             maximum >= 0 and is_integer(doublings) and doublings >= 0 do
    exponent = (attempt - 1) |> max(0) |> min(doublings)
    min(base * Integer.pow(2, exponent), maximum)
  end
end
