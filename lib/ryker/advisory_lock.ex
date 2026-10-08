defmodule Ryker.AdvisoryLock do
  @moduledoc """
  PostgreSQL advisory locks, the way Ryker serializes work no row lock
  covers: a message's dedupe key before its row exists, a conversation's
  admissions, the settings revision. A lock has a name, hashed to its 64-bit
  key (`hashtextextended`), so callers agree on a name and never on a number;
  an integer is a key itself.

  A transaction lock (`hold/2`, `hold!/2`) lasts until the transaction ends.
  A session lock (`try_session?/1`) lasts until `release_session/1`.
  """
  alias Ryker.Repo

  @type key :: String.t() | integer()
  @type mode :: :exclusive | :shared

  @doc "Holds `key` until the transaction ends, alone or `:shared` with other readers."
  @spec hold!(key(), mode()) :: :ok
  # The statement is one of four fixed strings; the key is a bound parameter.
  # sobelow_skip ["SQL.Query"]
  def hold!(key, mode \\ :exclusive) do
    Repo.query!(statement(key, mode), [key])
    :ok
  end

  @doc "`hold!/2`, answering a refused statement instead of raising."
  @spec hold(key(), mode()) :: :ok | {:error, term()}
  # The statement is one of four fixed strings; the key is a bound parameter.
  # sobelow_skip ["SQL.Query"]
  def hold(key, mode \\ :exclusive) do
    case Repo.query(statement(key, mode), [key]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Takes session lock `key` when no session holds it, answering whether it did."
  @spec try_session?(integer()) :: boolean()
  def try_session?(key) when is_integer(key) do
    %{rows: [[locked]]} = Repo.query!("SELECT pg_try_advisory_lock($1)", [key])
    locked
  end

  @doc "Releases session lock `key`, which this session holds."
  @spec release_session(integer()) :: :ok
  def release_session(key) when is_integer(key) do
    %{rows: [[true]]} = Repo.query!("SELECT pg_advisory_unlock($1)", [key])
    :ok
  end

  defp statement(key, :exclusive) when is_binary(key),
    do: "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))"

  defp statement(key, :shared) when is_binary(key),
    do: "SELECT pg_advisory_xact_lock_shared(hashtextextended($1, 0))"

  defp statement(key, :exclusive) when is_integer(key), do: "SELECT pg_advisory_xact_lock($1)"
  defp statement(key, :shared) when is_integer(key), do: "SELECT pg_advisory_xact_lock_shared($1)"
end
