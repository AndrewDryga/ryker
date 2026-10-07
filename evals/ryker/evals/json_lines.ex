defmodule Ryker.Evals.JsonLines do
  @moduledoc """
  Reads an export of one JSON document a line, as the routing and improvement
  replays take them. Each replay had its own copy (2026-10-04 review).
  """

  @doc """
  Each non-blank line decoded and given to `new`, which answers `{:ok, case}`
  or `{:error, reason}`: the cases in file order, and every line that could
  not become one with its 1-based number and why.
  """
  @spec read(Path.t(), (map() -> {:ok, term()} | {:error, term()})) ::
          {:ok, [term()], [%{line: pos_integer(), reason: String.t()}]} | {:error, :not_found}
  def read(path, new) when is_binary(path) and is_function(new, 1) do
    if File.regular?(path) do
      {cases, skipped} =
        path
        |> File.stream!(:line)
        |> Stream.map(&String.trim/1)
        |> Stream.reject(&(&1 == ""))
        |> Stream.with_index(1)
        |> Enum.map(fn {line, number} -> {number, decode(line, new)} end)
        |> Enum.split_with(&match?({_number, {:ok, _case}}, &1))

      {:ok, Enum.map(cases, fn {_number, {:ok, item}} -> item end),
       Enum.map(skipped, fn {number, {:error, reason}} ->
         %{line: number, reason: inspect(reason)}
       end)}
    else
      {:error, :not_found}
    end
  end

  defp decode(line, new) do
    case Jason.decode(line) do
      {:ok, document} -> new.(document)
      {:error, _reason} -> {:error, :unreadable_line}
    end
  end
end
