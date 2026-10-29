defmodule Ryker.Charts do
  @moduledoc "Local, consistently styled charts from bounded inline observations."
  alias Ryker.Charts.{Local, Spec}

  @doc "Render a chart description as PNG bytes, without fetching data or running supplied code."
  @spec render(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def render(arguments, options \\ []) do
    with {:ok, spec} <- Spec.build(arguments), do: Local.render(spec, options)
  end
end
