defmodule Ryker.Adapter do
  @moduledoc """
  Whether a module a caller configured can stand in for a collaborator: a
  Coop API, an HTTP requester, a presenter, a transcriber. Runtimes check it
  before they start, so a wrong module fails at configuration rather than on
  its first call.
  """

  @doc "Whether `module` loads and exports every one of `functions` (`name: arity`)."
  @spec implements?(term(), [{atom(), non_neg_integer()}]) :: boolean()
  def implements?(module, functions) when is_atom(module) and is_list(functions) do
    Code.ensure_loaded?(module) and
      Enum.all?(functions, fn {name, arity} -> function_exported?(module, name, arity) end)
  end

  def implements?(_module, _functions), do: false
end
