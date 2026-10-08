defmodule Ryker.Observability.Reads do
  @moduledoc """
  The reads every observability projection shares.

  Ecto raises when the database drops a connection or refuses a statement,
  and the pool exits when it is gone. A probe has to answer "unavailable"
  rather than crash, so each read here returns that failure as an error where
  it happens, and every projection stops at the first one.

  Ages are whole seconds from a timestamp to one database clock reading, so a
  projection never mixes the VM's clock with PostgreSQL's.
  """
  alias Ryker.Observability.Projection
  alias Ryker.Repo

  @type failure ::
          {:observability_query_failed, String.t()}
          | {:observability_query_failed, :exit, String.t()}

  @doc "Runs one read that raises on a database failure, answering with the failure instead."
  @spec read((-> value)) :: {:ok, value} | {:error, failure()} when value: term()
  def read(read) do
    {:ok, read.()}
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, {:observability_query_failed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:observability_query_failed, :exit, inspect(reason)}}
  end

  @spec one(Ecto.Queryable.t()) :: {:ok, term()} | {:error, failure()}
  def one(query), do: read(fn -> Repo.one(query) end)

  @spec all(Ecto.Queryable.t()) :: {:ok, [term()]} | {:error, failure()}
  def all(query), do: read(fn -> Repo.all(query) end)

  @spec count(Ecto.Queryable.t()) :: {:ok, non_neg_integer()} | {:error, failure()}
  def count(query), do: read(fn -> Repo.aggregate(query, :count, :id) end)

  @doc "Rows of `queryable` counted by the value of one field."
  @spec counts(Ecto.Queryable.t(), atom()) ::
          {:ok, %{optional(term()) => pos_integer()}} | {:error, failure()}
  def counts(queryable, field) do
    with {:ok, rows} <- all(Projection.Query.counts_by(queryable, field)),
         do: {:ok, Map.new(rows)}
  end

  @doc """
  One raw statement. The driver already answers a refused statement or a lost
  connection with its own error; only a pool that is gone has to be caught.
  """
  @spec sql(String.t(), [term()]) ::
          {:ok, Postgrex.Result.t()} | {:error, Exception.t() | failure()}
  def sql(statement, params \\ []) do
    with {:ok, answer} <- read(fn -> Repo.query(statement, params, log: false) end), do: answer
  end

  @doc "The rows of one raw statement, with a refusal reported like any other failed read."
  @spec rows(String.t(), [term()]) :: {:ok, [[term()]]} | {:error, failure()}
  def rows(statement, params \\ []) do
    case sql(statement, params) do
      {:ok, %Postgrex.Result{rows: rows}} ->
        {:ok, rows}

      {:error, %{__exception__: true} = error} ->
        {:error, {:observability_query_failed, Exception.message(error)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Reads each item in order with `read`, stopping at the first failure."
  @spec collect([item], (item -> {:ok, value} | {:error, term()})) ::
          {:ok, [value]} | {:error, term()}
        when item: term(), value: term()
  def collect(items, read) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, values} ->
      case read.(item) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Whole seconds from `datetime` to the database clock reading `now`, never
  negative; nothing to age is zero.

  A timestamp stored without a zone comes back naive and is aged in naive
  time, which counts the whole-second boundaries between the two readings.
  """
  @spec age_seconds(DateTime.t(), DateTime.t() | NaiveDateTime.t() | nil) :: non_neg_integer()
  def age_seconds(_now, nil), do: 0

  def age_seconds(%DateTime{} = now, %NaiveDateTime{} = datetime),
    do: max(NaiveDateTime.diff(DateTime.to_naive(now), datetime, :second), 0)

  def age_seconds(now, datetime), do: max(DateTime.diff(now, datetime, :second), 0)
end
