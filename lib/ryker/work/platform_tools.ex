defmodule Ryker.Work.PlatformTools do
  @moduledoc """
  The source and action tools Work is assembled with
  (`Ryker.Runtime.Assembly`), each a name or a `%{"name" => name}` tool.

  The Work runtime refused names the executor and the briefing took, because
  each checked the list its own way (2026-10-04 review); all three read it
  here.
  """

  @maximum_tools 256

  @doc "The tools' names, when the list holds at most 256 unique, bounded names."
  @spec names(term()) :: {:ok, [String.t()]} | :error
  def names(nil), do: {:ok, []}

  def names(tools) when is_list(tools) and length(tools) <= @maximum_tools do
    names = Enum.map(tools, &name/1)

    if Enum.all?(names, &valid_name?/1) and names == Enum.uniq(names),
      do: {:ok, names},
      else: :error
  end

  def names(_tools), do: :error

  defp name(%{"name" => name}), do: name
  defp name(name), do: name

  defp valid_name?(name) when is_binary(name) do
    String.valid?(name) and byte_size(name) in 1..256 and
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]*\z/, name)
  end

  defp valid_name?(_name), do: false
end
