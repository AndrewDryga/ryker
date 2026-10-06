defmodule Ryker.QueryWork do
  @moduledoc """
  What a read costs the database, from PostgreSQL's own account of running it.

  `statements/1` records the statements a function sends from the calling
  process. `rows_read/2` and `most_rows_read/2` run them again under
  `EXPLAIN ANALYZE` and count the rows their scans of one table produced or
  filtered away, over every loop. Sequential scans are off while they do, so
  the plan is the one the table gets once it holds more than a test's few
  rows. A test holds a page to the rows it shows this way, which a timing
  could not do on a loaded machine.
  """

  alias Ryker.Repo

  @type statement :: %{
          sql: String.t(),
          params: list(),
          rows: non_neg_integer(),
          bytes: non_neg_integer()
        }

  @doc """
  Runs `fun` and returns its result with every statement sent while it ran,
  in order: by the calling process, or by the process `from:` names, such as
  a LiveView's.
  """
  @spec statements((-> result), keyword()) :: {result, [statement()]} when result: term()
  def statements(fun, options \\ []) when is_function(fun, 0) do
    handler = "query-work-#{System.unique_integer([:positive])}"
    source = Keyword.get(options, :from, self())

    :ok =
      :telemetry.attach(
        handler,
        [:ryker, :repo, :query],
        &__MODULE__.record/4,
        {source, self(), handler}
      )

    try do
      result = fun.()
      {result, collect(handler, [])}
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  def record(_event, _measurements, metadata, {source, owner, handler}) do
    if self() == source do
      rows =
        case metadata.result do
          {:ok, %{rows: rows}} when is_list(rows) -> rows
          _no_rows -> []
        end

      send(
        owner,
        {handler,
         %{
           sql: metadata.query,
           params: metadata.params,
           rows: length(rows),
           bytes: :erlang.external_size(rows)
         }}
      )
    end
  end

  defp collect(handler, statements) do
    receive do
      {^handler, statement} -> collect(handler, [statement | statements])
    after
      0 -> Enum.reverse(statements)
    end
  end

  @doc "How many of the statements read `table`."
  @spec count([statement()], String.t()) :: non_neg_integer()
  def count(statements, table), do: statements |> reading(table) |> length()

  @doc "The rows the statements that read `table` returned, in all."
  @spec rows_returned([statement()], String.t()) :: non_neg_integer()
  def rows_returned(statements, table),
    do: statements |> reading(table) |> Enum.sum_by(& &1.rows)

  @doc "The bytes the statements that read `table` returned, in all."
  @spec bytes_returned([statement()], String.t()) :: non_neg_integer()
  def bytes_returned(statements, table),
    do: statements |> reading(table) |> Enum.sum_by(& &1.bytes)

  @doc "The rows of `table` the statements scanned, summed over all of them."
  @spec rows_read([statement()], String.t()) :: non_neg_integer()
  def rows_read(statements, table),
    do: statements |> reading(table) |> Enum.sum_by(&statement_rows_read(&1, table))

  @doc "The most rows of `table` any one of the statements scanned."
  @spec most_rows_read([statement()], String.t()) :: non_neg_integer()
  def most_rows_read(statements, table) do
    statements
    |> reading(table)
    |> Enum.map(&statement_rows_read(&1, table))
    |> Enum.max(fn -> 0 end)
  end

  defp reading(statements, table),
    do: Enum.filter(statements, &String.contains?(&1.sql, ~s("#{table}")))

  defp statement_rows_read(%{sql: sql, params: params}, table) do
    {:error, {:plan, plan}} =
      Repo.transact(fn ->
        Repo.query!("SET LOCAL enable_seqscan = off")

        %{rows: [[[%{"Plan" => plan}]]]} =
          Repo.query!("EXPLAIN (ANALYZE, FORMAT JSON) " <> sql, params)

        {:error, {:plan, plan}}
      end)

    plan |> scanned(table) |> round()
  end

  defp scanned(plan, table) do
    own =
      if plan["Relation Name"] == table do
        (plan["Actual Rows"] + Map.get(plan, "Rows Removed by Filter", 0) +
           Map.get(plan, "Rows Removed by Index Recheck", 0)) * plan["Actual Loops"]
      else
        0
      end

    own + Enum.sum_by(Map.get(plan, "Plans", []), &scanned(&1, table))
  end
end
