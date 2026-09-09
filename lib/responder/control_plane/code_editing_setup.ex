defmodule Responder.ControlPlane.CodeEditingSetup do
  @moduledoc "Read-only setup facts; connection support is not proof of worker readiness."

  def checkpoint_supported? do
    work = Application.get_env(:responder, :work) || %{}
    api = if is_map(work), do: work[:api], else: Keyword.get(work, :api)

    is_atom(api) and not is_nil(api) and Code.ensure_loaded?(api) and
      function_exported?(api, :checkpoint_workspace, 4)
  end
end
