defmodule Ryker.Evals.SessionCleanup do
  @moduledoc """
  Drains the Coop sessions an evaluation made through Ryker's own retention
  custody, pass by pass, until each is discarded.

  The world eval, the learning eval and its probe each had a copy of this loop,
  and an idle pass meant something different in each (2026-10-04 review).
  """
  import Ecto.Query
  alias Ryker.Repo
  alias Ryker.Retention.Dispatcher
  alias Ryker.Work.Session

  @doc """
  Runs retention passes with `options` (`Ryker.Retention.Dispatcher.run_once/1`;
  a closed session has no grace period) until a pass finds nothing to do, at
  most `passes` of them, and says whether every session is discarded.
  """
  @spec drain(keyword(), pos_integer()) :: :ok | {:error, term()}
  def drain(options, passes) when is_integer(passes) and passes > 0 do
    options
    |> Keyword.put_new(:closed_session_grace_seconds, 0)
    |> drain_passes(passes)
  end

  defp drain_passes(_options, 0), do: {:error, :session_cleanup_did_not_drain}

  defp drain_passes(options, left) do
    case Dispatcher.run_once(options) do
      {:ok, :idle} -> all_discarded()
      {:ok, {:executed, _execution}} -> drain_passes(options, left - 1)
      {:ok, {:deferred, reason}} -> {:error, {:session_cleanup_deferred, reason}}
      {:ok, {:blocked, reason}} -> {:error, {:session_cleanup_blocked, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp all_discarded do
    pending = from(session in Session, where: session.cleanup_status != :discarded)

    case Repo.aggregate(pending, :count) do
      0 -> :ok
      pending -> {:error, {:session_cleanup_incomplete, pending}}
    end
  end
end
